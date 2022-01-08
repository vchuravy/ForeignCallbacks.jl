using ForeignCallbacks
using Test
using InteractiveUtils

struct Message
    id::Int
    data::Ptr{Cvoid}
end

struct Message2
    id::Int
    data::Ref{Int}
end

@testset "Constructor" begin
    @test_throws AssertionError ForeignCallbacks.Stack{Ref{Int}}()
    @test_throws AssertionError ForeignCallbacks.Stack{Base.RefValue{Int}}()
    @test_throws AssertionError ForeignCallbacks.Stack{Message2}()
    @test_throws AssertionError ForeignCallbacks.Stack{Array}()
    @test_throws AssertionError ForeignCallbacks.Stack{Array{Int, 1}}()
end

@testset "Stack" begin
    lfq = ForeignCallbacks.Stack{Int}()

    @test ForeignCallbacks.dequeueall!(lfq) == []
    ForeignCallbacks.enqueue!(lfq, 1)
    @test ForeignCallbacks.dequeueall!(lfq) == [1]
    @test ForeignCallbacks.dequeueall!(lfq) == []

    GC.@preserve lfq begin
        ptr = Base.pointer_from_objref(lfq)
        ForeignCallbacks.unsafe_enqueue!(ptr, 2)
    end
    # TODO: Test no load from TLS in `unsafe_enqueue!`
    @test ForeignCallbacks.dequeueall!(lfq) == [2]
    @test ForeignCallbacks.dequeueall!(lfq) == []
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

@testset "IR" begin 
    let llvm = sprint(io->code_llvm(io, ForeignCallbacks.enqueue!, Tuple{ForeignCallbacks.Stack{Int}, Int}))
        @test !contains(llvm, "%thread_ptr")
        @test !contains(llvm, "%pgcstack")
        @test !contains(llvm, "%gcframe")
    end
    let llvm = sprint(io->code_llvm(io, ForeignCallbacks.unsafe_enqueue!, Tuple{Ptr{Cvoid}, Int}))
        @test !contains(llvm, "%thread_ptr")
        @test !contains(llvm, "%pgcstack")
        @test !contains(llvm, "%gcframe")
    end
    let llvm = sprint(io->code_llvm(io, ForeignCallbacks.notify!, Tuple{ForeignCallbacks.ForeignToken, Int}))
        @test !contains(llvm, "%thread_ptr")
        @test !contains(llvm, "%pgcstack")
        @test !contains(llvm, "%gcframe")
    end
    let llvm = sprint(io->code_llvm(io, ForeignCallbacks.unsafe_enqueue!, Tuple{Ptr{Cvoid}, Message}))
        @test !contains(llvm, "%thread_ptr")
        @test !contains(llvm, "%pgcstack")
        @test !contains(llvm, "%gcframe")
    end
    let llvm = sprint(io->code_llvm(io, ForeignCallbacks.notify!, Tuple{ForeignCallbacks.ForeignToken, Message}))
        @test !contains(llvm, "%thread_ptr")
        @test !contains(llvm, "%pgcstack")
        @test !contains(llvm, "%gcframe")
    end
end


if Threads.nthreads() == 1 && Sys.CPU_THREADS > 1
    @info "relaunching with" threads = Sys.CPU_THREADS
    cmd = `$(Base.julia_cmd()) --threads=$(Sys.CPU_THREADS) $(@__FILE__)`
    @test success(pipeline(cmd, stdout=stdout, stderr=stderr))
    exit()
end

function producer!(lfq)
    for i in 1:100
        ForeignCallbacks.enqueue!(lfq, i)
        yield()
    end
end

function unsafe_producer!(lfq)
    for i in 1:100
        GC.@preserve lfq begin
            ptr = Base.pointer_from_objref(lfq)
            ForeignCallbacks.unsafe_enqueue!(ptr, i)
        end
        yield()
    end
end

function consumer!(lfq)
    acc = 0

    done = false
    while !done 
        for x in ForeignCallbacks.dequeueall!(lfq)
            acc += x
        end
        done = acc == sum(1:100)*2*Threads.nthreads()
        yield()
    end
end

@testset "Queue threads" begin
    @test Threads.nthreads() == Sys.CPU_THREADS
    let lfq = ForeignCallbacks.Stack{Int}()
        @sync begin
            for n in 1:2*Threads.nthreads()
                Threads.@spawn producer!(lfq)
            end
            Threads.@spawn consumer!(lfq)
        end
        @test true
    end

    let lfq = ForeignCallbacks.Stack{Int}()
        @sync begin
            for n in 1:2*Threads.nthreads()
                Threads.@spawn unsafe_producer!(lfq)
            end
            Threads.@spawn consumer!(lfq)
        end
        @test true
    end
end

@testset "Callback threads" begin
    ch = Channel{Int}(Inf)
    callback = ForeignCallbacks.ForeignCallback{Int}() do val
        put!(ch, val)
        return
    end

    GC.@preserve callback begin
        token = ForeignCallbacks.ForeignToken(callback)
        for n in 1:2*Threads.nthreads()
            Threads.@spawn ForeignCallbacks.notify!(token, 1)
        end
    end

    acc = 0
    while acc < 2*Threads.nthreads()
        acc += fetch(ch)
    end
    @test acc == 2*Threads.nthreads()
end
