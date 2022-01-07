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
end
function LockfreeQueue{T}() where T
    tmp = calloc(Node{T})
    LockfreeQueue(tmp, tmp)
end

# Notes:
# We require at-least one node in the queue.
# When we dequeue, we discard the head node and return the data
# from the new head.

function unsafe_enqueue!(ptr::Ptr{Cvoid}, data::T) where T
    q = Base.unsafe_pointer_to_objref(ptr)::LockfreeQueue{T}
    enqueue!(q, data)
end

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

function dequeue!(q::LockfreeQueue{T}) where T
    p_head = @atomic :acquire q.head
    p_new_head = Core.Intrinsics.atomic_pointerref(convert(Ptr{Ptr{Node{T}}}, p_head), :acquire)

    if p_new_head == convert(Ptr{Node{T}}, C_NULL)
        return nothing # never remove the last node, queue is empty
    end
    p_head = @atomicswap :acquire_release q.head = p_new_head
    p_new_head = Core.Intrinsics.atomic_pointerref(convert(Ptr{Ptr{Node{T}}}, p_head), :acquire)
    
    # We have atomically advanced head and claimed a node.
    # We return the data from the new head
    # The lists starts of with a temporary node, which we will now free.
    head = unsafe_load(p_new_head) # p_head is now valid to free
    Libc.free(p_head)
    return Some(head.data)
end

import FunctionWrappers: FunctionWrapper

mutable struct ForeignCallback{T}
    queue::LockfreeQueue{T}
    callback::FunctionWrapper{Nothing, Tuple{T}}
    cond::Base.AsyncCondition

    function ForeignCallback{T}(callback_fn) where T
        queue = LockfreeQueue{T}()
        callback = FunctionWrapper{Nothing, Tuple{T}}(callback_fn)

        cond = Base.AsyncCondition() do _
            data = dequeue!(queue)
            while data !== nothing
                Threads.@spawn callback(something($data))
                data = dequeue!(queue)
            end
            return
        end
        this = new{T}(queue, callback, cond)
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