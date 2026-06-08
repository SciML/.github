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
        # A is directly changed: default Core on lts,1,pre + QA on lts,1
        a = filter(e -> e.project == "lib/A", m)
        @test Set((e.group, e.version) for e in a) ==
              Set([("Core", "lts"), ("Core", "1"), ("Core", "pre"), ("QA", "lts"), ("QA", "1")])
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

@testset "root matrix: build_root_matrix (defaults, per-group fields, continue_on_error)" begin
    d = mktempdir()
    # No test/test_groups.toml -> single Core group on the standard set.
    @test Set((e.group, e.version) for e in build_root_matrix(d)) ==
          Set([("Core", "lts"), ("Core", "1"), ("Core", "pre")])
    @test all(e -> e.continue_on_error == false, build_root_matrix(d))

    mkpath(joinpath(d, "test"))
    write(
        joinpath(d, "test", "test_groups.toml"), """
        [Core]
        versions = ["lts", "1", "pre"]

        [QA]
        versions = ["lts", "1"]

        [AD]
        versions = ["lts"]

        [Downstream]
        versions = ["lts", "1", "pre"]
        continue_on_error = true

        [GPU]
        versions = ["1"]
        runner = ["self-hosted", "Linux", "X64", "gpu"]
        timeout = 200
        num_threads = 4
        """
    )
    m = build_root_matrix(d)
    cells = Set((e.group, e.version) for e in m)
    @test ("AD", "1") ∉ cells && ("AD", "pre") ∉ cells && ("AD", "lts") in cells
    @test ("QA", "pre") ∉ cells && ("QA", "lts") in cells && ("QA", "1") in cells
    # continue_on_error rides only on the Downstream group.
    @test all(e -> e.continue_on_error, filter(e -> e.group == "Downstream", m))
    @test all(e -> !e.continue_on_error, filter(e -> e.group != "Downstream", m))
    gpu = only(filter(e -> e.group == "GPU", m))
    @test gpu.runner == ["self-hosted", "Linux", "X64", "gpu"]
    @test gpu.timeout == 200 && gpu.num_threads == 4
end

@testset "root matrix: OS axis (group × version × os)" begin
    d = mktempdir()
    mkpath(joinpath(d, "test"))
    write(
        joinpath(d, "test", "test_groups.toml"), """
        [Core]
        versions = ["lts", "1"]
        os = ["ubuntu-latest", "windows-latest", "macos-latest"]

        [QA]
        versions = ["1"]

        [GPU]
        versions = ["1"]
        runner = ["self-hosted", "Linux", "X64", "gpu"]
        """
    )
    m = build_root_matrix(d)
    # Core: 2 versions × 3 OSes = 6 cells; each cell's runner is the OS string.
    core = filter(e -> e.group == "Core", m)
    @test length(core) == 6
    @test Set((e.version, e.runner) for e in core) ==
          Set((v, o) for v in ["lts", "1"] for o in ["ubuntu-latest", "windows-latest", "macos-latest"])
    # QA: no os -> single default ubuntu runner.
    qa = filter(e -> e.group == "QA", m)
    @test length(qa) == 1 && only(qa).runner == "ubuntu-latest"
    # GPU: custom runner, no OS fan-out.
    gpu = filter(e -> e.group == "GPU", m)
    @test length(gpu) == 1 && only(gpu).runner == ["self-hosted", "Linux", "X64", "gpu"]
end

@testset "root matrix faithfully reproduces OrdinaryDiffEq's embedded matrix" begin
    # ODE's root CI.yml is 17 groups × [lts,1,pre] minus excludes (AD->lts only,
    # QA->lts/1, ODEInterfaceRegression->lts only). Per-group `versions`
    # expresses the same 46 cells, which is the migration this enables.
    base = [
        "InterfaceI", "InterfaceII", "InterfaceIII", "InterfaceIV", "InterfaceV",
        "Integrators_I", "Integrators_II", "AlgConvergence_I", "AlgConvergence_II",
        "AlgConvergence_III", "ModelingToolkit", "Downstream", "Regression_I", "Regression_II",
    ]
    d = mktempdir()
    mkpath(joinpath(d, "test"))
    io = IOBuffer()
    for g in base
        println(io, "[$g]\nversions = [\"lts\", \"1\", \"pre\"]\n")
    end
    println(io, "[AD]\nversions = [\"lts\"]\n")
    println(io, "[QA]\nversions = [\"lts\", \"1\"]\n")
    println(io, "[ODEInterfaceRegression]\nversions = [\"lts\"]\n")
    write(joinpath(d, "test", "test_groups.toml"), String(take!(io)))

    cells = Set((e.group, e.version) for e in build_root_matrix(d))
    groups17 = vcat(base, ["AD", "QA", "ODEInterfaceRegression"])
    expected = Set((g, v) for g in groups17 for v in ["lts", "1", "pre"])
    for ex in [("AD", "1"), ("AD", "pre"), ("QA", "pre"), ("ODEInterfaceRegression", "1"), ("ODEInterfaceRegression", "pre")]
        delete!(expected, ex)
    end
    @test cells == expected
    @test length(cells) == 46
end

@testset "--root-matrix CLI (no lib/ required) + JSON shape" begin
    d = mktempdir()  # deliberately NO lib/ directory
    out = read(pipeline(IOBuffer(""), `$(Base.julia_cmd()) $SCRIPT $d --root-matrix`), String)
    @test occursin("\"group\":\"Core\"", out)
    @test occursin("\"continue_on_error\":false", out)
    @test startswith(strip(out), "[") && endswith(strip(out), "]")
end
