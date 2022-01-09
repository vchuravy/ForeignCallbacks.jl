module ForeignCallbacks

import Base: Libc

struct Node{T}
    next::Ptr{Node{T}} # needs to be first field
    data::T
end
Node(data::T) where T = Node{T}(C_NULL, data)

setnext!(node::Ptr{Node{T}}, next::Ptr{Node{T}}) where {T} =
    unsafe_store!(convert(Ptr{Ptr{Node{T}}}, node), next)

function calloc(::Type{T}) where T 
    ptr = Libc.malloc(sizeof(T))
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), ptr, 0, sizeof(T))
    return convert(Ptr{T}, ptr)
end

"""
    SingleConsumerStack{T}

A variant of Treiber stack that assumes single-consumer for simple (hopefully)
correct implementation.

Safety notes: `push!` and `unsafe_push!` on `SingleConsumerStack{T}` can be
called from multiple tasks/threads. `unsafe_push! can be called from foreign
threads without the Julia runtime.  Only one Julia task is allowed to call
`popall!` at any point.  This simplifies the implementation and avoids the use
of "counted pointer" (and hence 128 bit CAS) that would typically be required
for general Treiber stack with manual memory management.
"""
mutable struct SingleConsumerStack{T}
    @atomic top::Ptr{Node{T}}
    function SingleConsumerStack{T}() where T
        @assert Base.datatype_pointerfree(Node{T})
        new{T}(C_NULL)
    end
end

function Base.push!(stack::SingleConsumerStack{T}, data::T) where T
    node = Node(data)
    p_node = convert(Ptr{Node{T}}, Libc.malloc(sizeof(Node{T})))
    Base.unsafe_store!(p_node, node)

    top = @atomic :monotonic stack.top
    while true
        setnext!(p_node, top)
        top, ok = @atomicreplace :acquire_release :monotonic stack.top top => p_node
        ok && return nothing
    end
end

# Manual implementation of `push!` since `unsafe_pointer_to_objref(ptr)::T` creates a gcframe
function unsafe_push!(ptr::Ptr{Cvoid}, data::T) where T
    node = Node(data)
    p_node = convert(Ptr{Node{T}}, Libc.malloc(sizeof(Node{T})))
    Base.unsafe_store!(p_node, node)

    p_top = Ptr{Ptr{Node{T}}}(ptr)
    top = Core.Intrinsics.atomic_pointerref(p_top, :monotonic)
    while true
        setnext!(p_node, top)
        top, ok = Core.Intrinsics.atomic_pointerreplace(
            p_top,
            top,
            p_node,
            :acquire_release,
            :monotonic,
        )
        ok && return nothing
    end
end

popall!(stack::SingleConsumerStack{T}) where T = moveto!(T[], stack)

function moveto!(results::AbstractVector{T}, stack::SingleConsumerStack{T}) where T
    p_node = @atomic :monotonic stack.top
    while true
        p_node, ok = @atomicreplace :acquire_release :monotonic stack.top p_node => C_NULL
        ok && break
    end

    # Copy the node data into `results` vector
    while p_node != C_NULL
        node = unsafe_load(p_node)
        Libc.free(p_node)
        push!(results, node.data)
        p_node = node.next
    end

    return results
end

mutable struct ForeignCallback{T}
    queue::SingleConsumerStack{T}
    cond::Base.AsyncCondition
    task::Task

    function ForeignCallback{T}(callback; fifo::Bool = true) where T
        stack = SingleConsumerStack{T}()
        cond = Base.AsyncCondition()
        mayreverse = fifo ? Iterators.reverse : identity
        task = Threads.@spawn begin
            local results = T[]
            while isopen(cond)
                wait(cond)
                moveto!(results, stack)
                for data in mayreverse(results)
                    Base.errormonitor(Threads.@spawn callback(data))
                end
                empty!(results)
            end
        end
        this = new{T}(stack, cond, task)
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
    unsafe_push!(token.queue, data)
    ccall(:uv_async_send, Cvoid, (Ptr{Cvoid},), token.handle)
    return
end

end # module
