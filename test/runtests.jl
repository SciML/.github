using Test

# Load the detection script's functions without running main().
const SCRIPT = joinpath(@__DIR__, "..", "scripts", "compute_affected_sublibraries.jl")
include(SCRIPT)

# Build a fixture monorepo `lib/` tree in a temp dir.
#   A  (base, no internal deps)
#   B  deps A
#   C  deps B            -> transitively depends on A
#   D  independent
# Reverse-dep closure: A -> {B, C}, B -> {C}, C -> {}, D -> {}.
function make_fixture(; c_groups::Union{Nothing, String} = nothing)
    root = mktempdir()
    lib = joinpath(root, "lib")
    function pkg(name, deps; groups = nothing)
        d = joinpath(lib, name)
        mkpath(joinpath(d, "src"))
        mkpath(joinpath(d, "test"))
        depblock = isempty(deps) ? "" : "[deps]\n" * join(["$dep = \"$(lpad(i, 4, '0'))\"" for (i, dep) in enumerate(deps)], "\n") * "\n"
        write(joinpath(d, "Project.toml"), "name = \"$name\"\nuuid = \"00000000-0000-0000-0000-0000000000$(lpad(hash(name) % 100, 2, '0'))\"\n$depblock")
        write(joinpath(d, "src", "$name.jl"), "module $name\nend\n")
        write(joinpath(d, "test", "runtests.jl"), "using Test\n")
        groups === nothing || write(joinpath(d, "test", "test_groups.toml"), groups)
    end
    pkg("A", String[])
    pkg("B", ["A"])
    pkg("C", ["B"]; groups = c_groups)
    pkg("D", String[])
    return root
end

@testset "compute_affected_sublibraries" begin
    root = make_fixture()
    lib = joinpath(root, "lib")
    graph = build_dependency_graph(lib)
    rev = compute_reverse_deps(graph)

    @testset "dependency graph (only internal [deps])" begin
        @test Set(graph["A"]) == Set(String[])
        @test Set(graph["B"]) == Set(["A"])
        @test Set(graph["C"]) == Set(["B"])
        @test Set(graph["D"]) == Set(String[])
    end

    @testset "transitive reverse deps" begin
        @test rev["A"] == Set(["B", "C"])
        @test rev["B"] == Set(["C"])
        @test rev["C"] == Set(String[])
        @test rev["D"] == Set(String[])
    end

    @testset "affected: direct + transitive on src change" begin
        direct, trans = compute_affected(["lib/A/src/A.jl"], graph, rev)
        @test direct == Set(["A"])
        @test trans == Set(["B", "C"])
    end

    @testset "affected: test-only change does NOT propagate" begin
        direct, trans = compute_affected(["lib/A/test/runtests.jl"], graph, rev)
        @test direct == Set(["A"])
        @test trans == Set(String[])
    end

    @testset "affected: Project.toml change propagates" begin
        direct, trans = compute_affected(["lib/A/Project.toml"], graph, rev)
        @test direct == Set(["A"])
        @test trans == Set(["B", "C"])
    end

    @testset "affected: leaf change only itself" begin
        direct, trans = compute_affected(["lib/D/src/D.jl"], graph, rev)
        @test direct == Set(["D"])
        @test trans == Set(String[])
    end

    @testset "affected: non-lib change selects nothing" begin
        direct, trans = compute_affected(["README.md", "docs/src/index.md"], graph, rev)
        @test isempty(direct) && isempty(trans)
    end

    @testset "projects-matrix: default groups + downstream→v1" begin
        direct, trans = compute_affected(["lib/A/src/A.jl"], graph, rev)
        m = build_projects_matrix(direct, trans, lib)
        # A is directly changed: default Core on lts,1.11,1,pre + QA on 1
        a = filter(e -> e.project == "lib/A", m)
        @test Set((e.group, e.version) for e in a) ==
              Set([("Core", "lts"), ("Core", "1.11"), ("Core", "1"), ("Core", "pre"), ("QA", "1")])
        # B and C are downstream: version "1" only
        for p in ("lib/B", "lib/C")
            ds = filter(e -> e.project == p, m)
            @test !isempty(ds)
            @test all(e -> e.version == "1", ds)
        end
        @test isempty(filter(e -> e.project == "lib/D", m))  # D unaffected
    end

    @testset "--projects mode paths" begin
        direct, trans = compute_affected(["lib/A/src/A.jl"], graph, rev)
        # union of direct+transitive, as lib/<pkg> paths, sorted
        pkgs = sort!(collect(union(direct, trans)))
        @test pkgs == ["A", "B", "C"]
    end
end

@testset "test_groups.toml: custom group, runner, timeout, local_only" begin
    groups = """
    [Core]
    versions = ["1"]

    [GPU]
    versions = ["1"]
    runner = ["self-hosted", "Linux", "X64", "gpu"]
    timeout = 60

    [Heavy]
    versions = ["1"]
    local_only = true
    """
    root = make_fixture(; c_groups = groups)
    lib = joinpath(root, "lib")
    graph = build_dependency_graph(lib)
    rev = compute_reverse_deps(graph)

    @testset "C changed directly: all its groups incl local_only, GPU on its runner" begin
        direct, trans = compute_affected(["lib/C/src/C.jl"], graph, rev)
        m = build_projects_matrix(direct, trans, lib)
        c = filter(e -> e.project == "lib/C", m)
        @test Set(e.group for e in c) == Set(["Core", "GPU", "Heavy"])
        gpu = only(filter(e -> e.group == "GPU", c))
        @test gpu.runner == ["self-hosted", "Linux", "X64", "gpu"]
        @test gpu.timeout == 60
    end

    @testset "C pulled in transitively: local_only group skipped" begin
        direct, trans = compute_affected(["lib/B/src/B.jl"], graph, rev)  # C is downstream of B
        @test "C" in trans
        m = build_projects_matrix(direct, trans, lib)
        c = filter(e -> e.project == "lib/C", m)
        @test "Heavy" ∉ Set(e.group for e in c)   # local_only skipped when downstream
        @test "Core" in Set(e.group for e in c)
    end
end

@testset "EXCLUDES drops (group,version) pairs" begin
    # OrdinaryDiffEqBDF + pre is in EXCLUDES; a sublib of that name must not
    # emit a Core/pre entry.
    root = mktempdir()
    lib = joinpath(root, "lib")
    d = joinpath(lib, "OrdinaryDiffEqBDF")
    mkpath(joinpath(d, "src"))
    write(joinpath(d, "Project.toml"), "name = \"OrdinaryDiffEqBDF\"\nuuid = \"00000000-0000-0000-0000-000000000099\"\n")
    write(joinpath(d, "src", "OrdinaryDiffEqBDF.jl"), "module OrdinaryDiffEqBDF\nend\n")
    graph = build_dependency_graph(lib)
    rev = compute_reverse_deps(graph)
    direct, trans = compute_affected(["lib/OrdinaryDiffEqBDF/src/x.jl"], graph, rev)
    m = build_projects_matrix(direct, trans, lib)
    @test ("OrdinaryDiffEqBDF", "pre") in EXCLUDES
    @test isempty(filter(e -> e.group == "Core" && e.version == "pre", m))
    @test !isempty(filter(e -> e.group == "Core" && e.version == "1", m))
end

@testset "end-to-end CLI output (--projects-matrix is valid JSON)" begin
    root = make_fixture()
    out = read(pipeline(IOBuffer("lib/A/src/A.jl\n"), `$(Base.julia_cmd()) $SCRIPT $root --projects-matrix`), String)
    @test startswith(strip(out), "[")
    @test occursin("\"project\":\"lib/A\"", out)
    @test occursin("\"group\":\"Core\"", out)
    # empty input -> []
    out2 = read(pipeline(IOBuffer("README.md\n"), `$(Base.julia_cmd()) $SCRIPT $root --projects-matrix`), String)
    @test strip(out2) == "[]"
end
