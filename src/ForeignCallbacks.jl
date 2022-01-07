module ForeignCallbacks

import Base: Libc

struct Node{T}
    next::Ptr{Node{T}} # needs to be first field
    data::T
end
Node(data::T) where T = Node{T}(C_NULL, data)

function calloc(::Type{T}) where T 
    ptr = Libc.malloc(sizeof(T))
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), ptr, 0, sizeof(T))
    return convert(Ptr{T}, ptr)
end

mutable struct LockfreeQueue{T}
    @atomic head::Ptr{Node{T}}
    @atomic tail::Ptr{Node{T}}
    function LockfreeQueue{T}() where T
        tmp = calloc(Node{T})
        new{T}(tmp, tmp)
    end
end

# Notes:
# We require at-least one node in the queue.
# When we dequeue, we discard the head node and return the data
# from the new head.

function enqueue!(q::LockfreeQueue{T}, data::T) where T
    node = Node(data)
    p_node = convert(Ptr{Node{T}}, Libc.malloc(sizeof(Node{T})))
    Base.unsafe_store!(p_node, node)

    # Update the tail node in queue
    p_tail = @atomicswap :acquire_release q.tail = p_node

    # Link former tail to new tail
    Core.Intrinsics.atomic_pointerset(convert(Ptr{Ptr{Node{T}}}, p_tail), p_node, :release)
    return nothing
end

# Manual implementation of `enqueue!` since `unsafe_pointer_to_objref(ptr)::T` creates a gcframe
function unsafe_enqueue!(ptr::Ptr{Cvoid}, data::T) where T
    node = Node(data)
    p_node = convert(Ptr{Node{T}}, Libc.malloc(sizeof(Node{T})))
    Base.unsafe_store!(p_node, node)

    # Update the tail node in queue
    ptr += fieldoffset(ForeignCallbacks.LockfreeQueue{T}, 2)
    p_tail = Core.Intrinsics.atomic_pointerswap(convert(Ptr{Ptr{Node{T}}}, ptr), p_node, :acquire_release)

    # Link former tail to new tail
    Core.Intrinsics.atomic_pointerset(convert(Ptr{Ptr{Node{T}}}, p_tail), p_node, :release)
    return nothing
end

function dequeue!(q::LockfreeQueue{T}) where T
    p_head = @atomic :acquire q.head

    success = false
    p_new_head = convert(Ptr{Node{T}}, C_NULL)
    while !success
        # Load new head
        p_new_head = Core.Intrinsics.atomic_pointerref(convert(Ptr{Ptr{Node{T}}}, p_head), :acquire)
        if p_new_head == convert(Ptr{Node{T}}, C_NULL)
            return nothing # never remove the last node, queue is empty
        end
        # Attempt replacement of current head with new head
        p_head, success = @atomicreplace :acquire_release :monotonic q.head p_head => p_new_head
    end
    
    # We have atomically advanced head and claimed a node.
    # We return the data from the new head
    # The lists starts of with a temporary node, which we will now free.
    head = unsafe_load(p_new_head) # p_head is now valid to free
    # TODO: Is there a potential race between `free(p_head)` and `unsafe_load(p_head)`
    #       on the previous `dequeue!`?
    #       As long as we only have one consumer this is fine. 
    Libc.free(p_head)
    return Some(head.data)
end

mutable struct ForeignCallback{T}
    queue::LockfreeQueue{T}
    cond::Base.AsyncCondition

    function ForeignCallback{T}(callback) where T
        queue = LockfreeQueue{T}()

        cond = Base.AsyncCondition() do _
            data = dequeue!(queue)
            while data !== nothing
                Base.errormonitor(Threads.@spawn callback(something($data)))
                data = dequeue!(queue)
            end
            return
        end
        this = new{T}(queue, cond)
        finalizer(this) do this
            close(this.cond)
            # TODO: free queue we are leaking at least one node here
        end
    end
end

struct ForeignToken
    handle::Ptr{Cvoid}
    queue::Ptr{Cvoid}
end

"""
    Create a foreign token for a callback.

Note that the passed `ForeignCallback` must be GC preserved while this token is being used by
the foreign code. The user can pass the token around and use it to invoke the callback with the data
by calling `notify!`.
"""
ForeignToken(fc::ForeignCallback) = ForeignToken(fc.cond.handle, Base.pointer_from_objref(fc.queue))

function notify!(token::ForeignToken, data::T) where T
    unsafe_enqueue!(token.queue, data)
    ccall(:uv_async_send, Cvoid, (Ptr{Cvoid},), token.handle)
    return
end

end # module
