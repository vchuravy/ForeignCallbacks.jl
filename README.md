# ForeignCallbacks.jl

Callbacks executing on a foreign (to Julia) thread are not allowed to interact with the Julia runtime.
The one canonical exception is the use of `Base.AsyncCondition` and `uv_async_send`. This has worked
for 1:1 cases where there is one event trigger mapped to one `AsyncCondition`. The problem with
`uv_async_send` is that many triggers to the same handle can be coalesced into one invocation.

`ForeignCallbacks` implements a lock-free-queue that can be used to pass data from the foreign thread
to a Julia callback. The data being passed must satisfy `!Base.ismutabletype(T) && Base.datatype_pointerfree(T)`.

## Example

```julia
import ForeignCallbacks
struct Message
    id::Int
    data::Ptr{Cvoid}
end

barrier = Base.Event()
callback = ForeignCallbacks.ForeignCallback{Message}() do msg
    @info "Received message" id=msg.id
    notify(barrier)
    return
end

GC.@preserve callback begin
    token = ForeignCallbacks.ForeignToken(callback)
    ptr = @cfunction(ForeignCallbacks.notify!, Cvoid, (ForeignCallbacks.ForeignToken, Message))
    @sync Threads.@spawn begin
        msg = Message(1, C_NULL)
        ccall($ptr, Cvoid, (ForeignCallbacks.ForeignToken, Message), $token, msg)
    end
    wait(barrier)
end
```
