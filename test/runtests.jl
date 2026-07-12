using Test

# Load the detection script's functions without running main().
const SCRIPT = joinpath(@__DIR__, "..", "scripts", "compute_affected_sublibraries.jl")
include(SCRIPT)

# Load the [sources] develop helper's pure collection functions.
const DEVELOP_SCRIPT = joinpath(@__DIR__, "..", "scripts", "develop_sources.jl")
include(DEVELOP_SCRIPT)

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
        return groups === nothing || write(joinpath(d, "test", "test_groups.toml"), groups)
    end
    pkg("A", String[])
    pkg("B", ["A"])
    pkg("C", ["B"]; groups = c_groups)
    pkg("D", String[])
    return root
end

@testset "develop_sources: path and URL source collection" begin
    root = mktempdir()
    localdep = joinpath(root, "lib", "LocalDep")
    nested = joinpath(root, "lib", "NestedRuntime")
    mkpath(localdep)
    mkpath(nested)
    write(
        joinpath(root, "Project.toml"), """
        name = "Root"
        uuid = "00000000-0000-0000-0000-000000000001"

        [deps]
        LocalDep = "00000000-0000-0000-0000-000000000002"
        UrlDep = "00000000-0000-0000-0000-000000000003"

        [extras]
        TestOnlyUrl = "00000000-0000-0000-0000-000000000004"

        [sources]
        LocalDep = {path = "lib/LocalDep"}
        UrlDep = {url = "https://example.com/runtime.git", rev = "main"}
        TestOnlyUrl = {url = "https://example.com/test-only.git"}
        """
    )
    write(
        joinpath(localdep, "Project.toml"), """
        name = "LocalDep"
        uuid = "00000000-0000-0000-0000-000000000002"

        [deps]
        NestedRuntime = "00000000-0000-0000-0000-000000000005"

        [extras]
        NestedTestOnly = "00000000-0000-0000-0000-000000000006"

        [sources]
        NestedRuntime = {path = "../NestedRuntime"}
        NestedTestOnly = {url = "https://example.com/nested-test-only.git"}
        """
    )
    write(
        joinpath(nested, "Project.toml"), """
        name = "NestedRuntime"
        uuid = "00000000-0000-0000-0000-000000000005"
        """
    )

    paths = collect_source_paths(root)
    @test paths == [normpath(localdep), normpath(nested)]

    specs = collect_source_specs(root)
    @test Set(filter(!isnothing, getfield.(specs, :path))) == Set(paths)
    url_specs = filter(s -> !isnothing(s.url), specs)
    @test any(s -> s.name == "UrlDep" && s.url == "https://example.com/runtime.git" && s.rev == "main", url_specs)
    @test any(s -> s.name == "TestOnlyUrl" && s.url == "https://example.com/test-only.git", url_specs)
    @test !any(s -> s.name == "NestedTestOnly", url_specs)
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
        # A is directly changed: default Core on lts,1,pre + QA on 1 (QA defaults to v1 only)
        a = filter(e -> e.project == "lib/A", m)
        @test Set((e.group, e.version) for e in a) ==
            Set([("Core", "lts"), ("Core", "1"), ("Core", "pre"), ("QA", "1")])
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
    # The default matrix runner is self-hosted-capable `ubuntu-latest` (the
    # SciML demeter*/arctic* pool answers that label). Only legs that set
    # apt-packages/container are forced to GitHub-hosted, and that routing lives
    # in the reusable workflows' runs-on expression (see the "runs-on conditional"
    # testset), NOT in this matrix.
    @test all(e -> e.runner == "ubuntu-latest", build_root_matrix(d))

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
    # QA is centrally clamped to v1 only, regardless of the per-group `versions`.
    @test ("QA", "pre") ∉ cells && ("QA", "lts") ∉ cells && ("QA", "1") in cells
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

@testset "root matrix: arch axis and group alias (32-bit lane)" begin
    d = mktempdir()
    mkpath(joinpath(d, "test"))
    write(
        joinpath(d, "test", "test_groups.toml"), """
        [Core]
        versions = ["lts", "1"]
        os = ["ubuntu-latest", "windows-latest"]

        ["Core 32-bit"]
        group = "Core"
        versions = ["1"]
        os = ["ubuntu-latest"]
        arch = "x86"

        [QA]
        versions = ["1"]
        """
    )
    m = build_root_matrix(d)
    # Native Core cells carry an empty arch (tests.yml falls back to runner.arch).
    native = filter(e -> e.group == "Core" && e.arch == "", m)
    @test length(native) == 4  # 2 versions × 2 OSes
    @test Set((e.version, e.runner) for e in native) ==
        Set((v, o) for v in ["lts", "1"] for o in ["ubuntu-latest", "windows-latest"])
    # The aliased "Core 32-bit" section dispatches GROUP=Core but adds exactly one
    # x86 cell on ubuntu, so runtests.jl's folder resolves to the Core body.
    x86 = filter(e -> e.arch == "x86", m)
    @test length(x86) == 1
    @test only(x86).group == "Core" && only(x86).version == "1" && only(x86).runner == "ubuntu-latest"
    # QA stays native.
    @test all(e -> e.arch == "", filter(e -> e.group == "QA", m))
end

@testset "root matrix: arch as a list fans out per arch" begin
    d = mktempdir()
    mkpath(joinpath(d, "test"))
    write(
        joinpath(d, "test", "test_groups.toml"), """
        [Core]
        versions = ["1"]
        arch = ["x64", "x86"]
        """
    )
    m = build_root_matrix(d)
    @test Set(e.arch for e in m) == Set(["x64", "x86"])
    @test length(m) == 2
end

@testset "root matrix: --root-matrix CLI emits arch field" begin
    d = mktempdir()
    mkpath(joinpath(d, "test"))
    write(
        joinpath(d, "test", "test_groups.toml"), """
        ["Core 32-bit"]
        group = "Core"
        versions = ["1"]
        arch = "x86"
        """
    )
    out = read(pipeline(IOBuffer(""), `$(Base.julia_cmd()) $SCRIPT $d --root-matrix`), String)
    @test occursin("\"arch\":\"x86\"", out)
    @test occursin("\"group\":\"Core\"", out)
end

@testset "root matrix faithfully reproduces OrdinaryDiffEq's embedded matrix" begin
    # ODE's root CI.yml is 17 groups × [lts,1,pre] minus excludes (AD->lts only,
    # ODEInterfaceRegression->lts only). QA is centrally clamped to v1 only (see
    # QA_VERSIONS), so it intentionally diverges from ODE's old QA-on-lts/1: 45 cells.
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
    for ex in [("AD", "1"), ("AD", "pre"), ("QA", "pre"), ("QA", "lts"), ("ODEInterfaceRegression", "1"), ("ODEInterfaceRegression", "pre")]
        delete!(expected, ex)
    end
    @test cells == expected
    @test length(cells) == 45
end

@testset "--root-matrix CLI (no lib/ required) + JSON shape" begin
    d = mktempdir()  # deliberately NO lib/ directory
    out = read(pipeline(IOBuffer(""), `$(Base.julia_cmd()) $SCRIPT $d --root-matrix`), String)
    @test occursin("\"group\":\"Core\"", out)
    @test occursin("\"continue_on_error\":false", out)
    @test startswith(strip(out), "[") && endswith(strip(out), "]")
end

# The "force GitHub-hosted only for apt-packages/container legs" routing lives
# in the reusable workflows' job-level `runs-on` expression, not in the matrix
# script. The expression is a GitHub Actions ternary of the form
#   (apt != '' || container != '') && fromJSON('["ubuntu-24.04"]') || <default>
# Live routing can only be proven by a retagged run, but we can (a) assert the
# real expression is present in each reusable, and (b) emulate GitHub Actions'
# &&/|| short-circuit semantics to confirm it resolves to ubuntu-24.04 exactly
# when apt-packages/container is set and otherwise preserves the default
# (matrix runner / self-hosted / os) — including GPU self-hosted overrides.
@testset "runs-on conditional: apt/container -> GitHub-hosted, else default" begin
    wf(p) = joinpath(@__DIR__, "..", ".github", "workflows", p)

    # GitHub Actions truthiness: only '', false, 0, null are falsy; a non-empty
    # array (the fromJSON result) is truthy, so the ternary doesn't fall through.
    # Emulate the three workflow expressions for given inputs.
    function resolve(; apt, container, default)
        (apt != "" || container != "") ? ["ubuntu-24.04"] : default
    end

    @testset "expression present in each reusable" begin
        for (p, frag) in (
                ("tests.yml", "(inputs.apt-packages != '' || inputs.container != '') && fromJSON('[\"ubuntu-24.04\"]')"),
                ("downgrade.yml", "(inputs.apt-packages != '' || inputs.container != '') && fromJSON('[\"ubuntu-24.04\"]')"),
                ("sublibrary-downgrade.yml", "(inputs.apt-packages != '' || inputs.container != '') && fromJSON('[\"ubuntu-24.04\"]')"),
            )
            txt = read(wf(p), String)
            @test occursin(frag, txt)
        end
        # detect/discover helper jobs and sublibrary-project-tests are NOT routed
        # (no apt/container) and must keep ubuntu-latest.
        @test occursin("runs-on: ubuntu-latest", read(wf("grouped-tests.yml"), String))
        @test occursin("runs-on: ubuntu-latest", read(wf("sublibrary-project-tests.yml"), String))
        # sublibrary-project-tests passes no apt-packages/container through, so it
        # never forces GitHub-hosted.
        @test !occursin("apt-packages", read(wf("sublibrary-project-tests.yml"), String))
        @test !occursin("ubuntu-24.04", read(wf("sublibrary-project-tests.yml"), String))
    end

    @testset "apt-packages set -> ubuntu-24.04 (GitHub-hosted)" begin
        @test resolve(apt = "python3-scipy", container = "", default = "ubuntu-latest") == ["ubuntu-24.04"]
        # even when the caller passed a self-hosted matrix runner, an apt leg is
        # forced GitHub-hosted (apt provisioning needs passwordless sudo).
        @test resolve(apt = "r-base-dev", container = "", default = ["self-hosted", "Linux", "X64", "gpu"]) == ["ubuntu-24.04"]
    end

    @testset "container set -> ubuntu-24.04 (GitHub-hosted)" begin
        @test resolve(apt = "", container = "cmhyett/julia-fenics:latest", default = "ubuntu-latest") == ["ubuntu-24.04"]
    end

    @testset "neither set -> default preserved (self-hosted-capable)" begin
        # default string `ubuntu-latest` (self-hosted pool squats this label).
        @test resolve(apt = "", container = "", default = "ubuntu-latest") == "ubuntu-latest"
        # GPU / explicit self-hosted runner override is preserved, NOT forced to
        # ubuntu-24.04.
        @test resolve(apt = "", container = "", default = ["self-hosted", "Linux", "X64", "gpu"]) ==
            ["self-hosted", "Linux", "X64", "gpu"]
    end
end

# develop_sources.jl: the [sources] develop helper used by tests.yml on Julia
# <1.11. The pure path-collection (collect_source_paths) is tested here without
# mutating any environment.
include(joinpath(@__DIR__, "..", "scripts", "develop_sources.jl"))

# Build a fixture monorepo. `Top` runtime-sources `Mid`; `Mid` runtime-sources
# `Leaf` (in its [deps]) and test-only-sources `TestOnly` (only in its
# [extras]/[targets].test, NOT [deps]). The walk from `Top` must develop the
# runtime chain {Mid, Leaf} and must NOT pull in `Mid`'s test-only `TestOnly`.
function make_sources_fixture()
    root = mktempdir()
    function pkg(name, toml)
        d = joinpath(root, name)
        mkpath(joinpath(d, "src"))
        write(joinpath(d, "Project.toml"), toml)
        write(joinpath(d, "src", "$name.jl"), "module $name\nend\n")
        return d
    end
    pkg("Leaf", "name = \"Leaf\"\nuuid = \"11111111-1111-1111-1111-111111111111\"\n")
    pkg("TestOnly", "name = \"TestOnly\"\nuuid = \"44444444-4444-4444-4444-444444444444\"\n")
    pkg(
        "Mid", """
        name = "Mid"
        uuid = "22222222-2222-2222-2222-222222222222"

        [deps]
        Leaf = "11111111-1111-1111-1111-111111111111"

        [sources]
        Leaf = {path = "../Leaf"}
        TestOnly = {path = "../TestOnly"}

        [extras]
        TestOnly = "44444444-4444-4444-4444-444444444444"

        [targets]
        test = ["TestOnly"]
        """
    )
    pkg(
        "Top", """
        name = "Top"
        uuid = "33333333-3333-3333-3333-333333333333"

        [deps]
        Mid = "22222222-2222-2222-2222-222222222222"

        [sources]
        Mid = {path = "../Mid"}
        """
    )
    return root
end

@testset "develop_sources: runtime [sources] developed, dep test-only [sources] excluded" begin
    root = make_sources_fixture()
    names = sort(basename.(collect_source_paths(joinpath(root, "Top"))))
    # Runtime transitive chain Top -> Mid -> Leaf is developed.
    @test names == ["Leaf", "Mid"]
    # Mid's test-only source (TestOnly) is NOT pulled into Top's env
    # (SciML/Optimization.jl#1228).
    @test "TestOnly" ∉ names
    # The active project (Top) is never self-developed.
    @test "Top" ∉ names
end

@testset "develop_sources: package-under-test's OWN test-only [sources] ARE developed" begin
    # When the project at the root of the walk is itself being tested, its
    # test-only [sources] (e.g. OptimizationBase developing LBFGSB/Manopt for
    # its own test suite) must still be developed -- only a *dependency's*
    # test-only sources are filtered out.
    root = make_sources_fixture()
    names = sort(basename.(collect_source_paths(joinpath(root, "Mid"))))
    # Testing Mid directly: its runtime source (Leaf) AND its test-only source
    # (TestOnly) are both developed; only Leaf is then recursed into.
    @test names == ["Leaf", "TestOnly"]
end

@testset "develop_sources: no [sources] table -> nothing to develop" begin
    root = make_sources_fixture()
    @test isempty(collect_source_paths(joinpath(root, "Leaf")))
end
