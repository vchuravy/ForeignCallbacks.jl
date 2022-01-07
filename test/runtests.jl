using ForeignCallbacks
using Test
using InteractiveUtils

@testset "Queue" begin
    lfq = ForeignCallbacks.LockfreeQueue{Int}()

    @test ForeignCallbacks.dequeue!(lfq) === nothing
    ForeignCallbacks.enqueue!(lfq, 1)
    @test ForeignCallbacks.dequeue!(lfq) === Some(1)
    @test ForeignCallbacks.dequeue!(lfq) === nothing

    GC.@preserve lfq begin
        ptr = Base.pointer_from_objref(lfq)
        ForeignCallbacks.unsafe_enqueue!(ptr, 2)
    end
    # TODO: Test no load from TLS in `unsafe_enqueue!`
    @test ForeignCallbacks.dequeue!(lfq) === Some(2)
    @test ForeignCallbacks.dequeue!(lfq) === nothing
end

@testset "callback" begin
    ch = Channel{Int}(Inf)
    callback = ForeignCallbacks.ForeignCallback{Int}() do val
        put!(ch, val)
        return
    end

    GC.@preserve callback begin
        token = ForeignCallbacks.ForeignToken(callback)
        ForeignCallbacks.notify!(token, 1)
        @test fetch(ch) === 1
    end
end



