const RECONCILE_SCRIPT =
    joinpath(@__DIR__, "..", "scripts", "reconcile_downgrade_sources.jl")
include(RECONCILE_SCRIPT)

function make_reconcile_fixture()
    root = mktempdir()
    mid = joinpath(root, "Mid")
    nested = joinpath(root, "Nested")
    test_only = joinpath(root, "TestOnly")
    mkpath.((mid, nested, test_only))

    write(
        joinpath(root, "Project.toml"),
        """
        name = "Root"
        uuid = "10000000-0000-0000-0000-000000000001"

        [deps]
        Shared = "10000000-0000-0000-0000-000000000010"

        [compat]
        Shared = "1"
        julia = "1.10"

        [extras]
        Mid = "10000000-0000-0000-0000-000000000002"

        [sources]
        Mid = {path = "Mid"}

        [targets]
        test = ["Mid"]
        """,
    )
    write(
        joinpath(mid, "Project.toml"),
        """
        name = "Mid"
        uuid = "10000000-0000-0000-0000-000000000002"

        [deps]
        Nested = "10000000-0000-0000-0000-000000000003"
        Shared = "10000000-0000-0000-0000-000000000010"

        [compat]
        Nested = "1"
        Shared = "1.2"

        [extras]
        TestOnly = "10000000-0000-0000-0000-000000000004"

        [sources]
        Nested = {path = "../Nested"}
        TestOnly = {path = "../TestOnly"}

        [targets]
        test = ["TestOnly"]
        """,
    )
    write(
        joinpath(nested, "Project.toml"),
        """
        name = "Nested"
        uuid = "10000000-0000-0000-0000-000000000003"

        [deps]
        Other = "10000000-0000-0000-0000-000000000011"
        Shared = "10000000-0000-0000-0000-000000000010"

        [weakdeps]
        Optional = "10000000-0000-0000-0000-000000000012"

        [compat]
        Optional = "0.5"
        Other = "2.3"
        Shared = "1.4"
        """,
    )
    write(
        joinpath(test_only, "Project.toml"),
        """
        name = "TestOnly"
        uuid = "10000000-0000-0000-0000-000000000004"
        """,
    )
    return root
end

function git_commit(repo::AbstractString, message::AbstractString)
    run(Cmd(["git", "-C", repo, "add", "."]))
    run(Cmd(["git", "-C", repo, "commit", "-q", "-m", message]))
    return strip(read(Cmd(["git", "-C", repo, "rev-parse", "HEAD^{tree}"]), String))
end

function make_locked_source_fixture()
    root = mktempdir()
    package_repo = joinpath(root, "CompatFloor")
    registry = joinpath(root, "LocalRegistry")
    project = joinpath(root, "RootPkg")
    source = joinpath(root, "PathDep")
    depot = joinpath(root, "depot")
    mkpath.(
        (
            joinpath(package_repo, "src"),
            joinpath(registry, "C", "CompatFloor"),
            joinpath(project, "src"),
            joinpath(project, "test"),
            joinpath(source, "src"),
            depot,
        ),
    )

    run(Cmd(["git", "-C", package_repo, "init", "-q"]))
    run(Cmd(["git", "-C", package_repo, "config", "user.name", "SciML CI"]))
    run(Cmd(["git", "-C", package_repo, "config", "user.email", "ci@example.com"]))
    package_project = joinpath(package_repo, "Project.toml")
    package_source = joinpath(package_repo, "src", "CompatFloor.jl")
    write(
        package_project,
        "name = \"CompatFloor\"\nuuid = \"20000000-0000-0000-0000-000000000001\"\nversion = \"1.0.0\"\n",
    )
    write(package_source, "module CompatFloor\nversion() = v\"1.0.0\"\nend\n")
    tree_1_0 = git_commit(package_repo, "CompatFloor 1.0.0")
    write(
        package_project,
        "name = \"CompatFloor\"\nuuid = \"20000000-0000-0000-0000-000000000001\"\nversion = \"1.1.0\"\n",
    )
    write(package_source, "module CompatFloor\nversion() = v\"1.1.0\"\nend\n")
    tree_1_1 = git_commit(package_repo, "CompatFloor 1.1.0")

    write(
        joinpath(registry, "Registry.toml"),
        """
        name = "LocalRegistry"
        uuid = "20000000-0000-0000-0000-000000000010"
        repo = "file://$registry"

        [packages]
        20000000-0000-0000-0000-000000000001 = {name = "CompatFloor", path = "C/CompatFloor"}
        """,
    )
    write(
        joinpath(registry, "C", "CompatFloor", "Package.toml"),
        """
        name = "CompatFloor"
        uuid = "20000000-0000-0000-0000-000000000001"
        repo = "file://$package_repo"
        """,
    )
    write(
        joinpath(registry, "C", "CompatFloor", "Versions.toml"),
        """
        ["1.0.0"]
        git-tree-sha1 = "$tree_1_0"

        ["1.1.0"]
        git-tree-sha1 = "$tree_1_1"
        """,
    )
    run(Cmd(["git", "-C", registry, "init", "-q"]))
    run(Cmd(["git", "-C", registry, "config", "user.name", "SciML CI"]))
    run(Cmd(["git", "-C", registry, "config", "user.email", "ci@example.com"]))
    git_commit(registry, "Local registry")

    write(
        joinpath(source, "Project.toml"),
        """
        name = "PathDep"
        uuid = "20000000-0000-0000-0000-000000000002"
        version = "1.0.0"

        [deps]
        CompatFloor = "20000000-0000-0000-0000-000000000001"

        [compat]
        CompatFloor = "1.1"
        """,
    )
    write(
        joinpath(source, "src", "PathDep.jl"),
        "module PathDep\nusing CompatFloor\ncompatible() = CompatFloor.version() >= v\"1.1.0\"\nend\n",
    )

    original_project = """
    name = "RootPkg"
    uuid = "20000000-0000-0000-0000-000000000003"
    version = "1.0.0"

    [deps]
    CompatFloor = "20000000-0000-0000-0000-000000000001"

    [compat]
    CompatFloor = "1"

    [extras]
    PathDep = "20000000-0000-0000-0000-000000000002"
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [sources]
    PathDep = {path = "../PathDep"}

    [targets]
    test = ["PathDep", "Test"]
    """
    write(joinpath(project, "Project.toml"), original_project)
    write(joinpath(project, "src", "RootPkg.jl"), "module RootPkg\nend\n")
    write(
        joinpath(project, "test", "runtests.jl"),
        "using Test, PathDep\n@test PathDep.compatible()\n",
    )
    return (; root, registry, project, depot, original_project)
end

function run_fixture_julia(fixture, expression::AbstractString, log::AbstractString)
    command = addenv(
        `$(Base.julia_cmd()) --startup-file=no --project=$(fixture.project) -e $expression`,
        "JULIA_DEPOT_PATH" => fixture.depot,
        "JULIA_LOAD_PATH" => "@:@stdlib",
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
    )
    return open(log, "w") do io
        run(pipeline(ignorestatus(command), stdout = io, stderr = io))
    end
end

@testset "downgrade path-source constraint reconciliation" begin
    @test compat_lower_bound("1.2.3") == v"1.2.3"
    @test compat_lower_bound("3.75, 4") == v"3.75"
    @test compat_lower_bound("1.2 - 1.8") == v"1.2"
    @test compat_lower_bound("<2") == v"0"
    @test compat_lower_bound("<0.0.1, 1") == v"0"
    @test prefer_higher_floor("1", "1.4") == "1.4"

    root = make_reconcile_fixture()
    original = read(joinpath(root, "Project.toml"), String)
    project = TOML.parse(original)
    flatten_source_constraints!(project, root)
    @test project["deps"]["Mid"] == "10000000-0000-0000-0000-000000000002"
    @test project["deps"]["Nested"] == "10000000-0000-0000-0000-000000000003"
    @test project["deps"]["Other"] == "10000000-0000-0000-0000-000000000011"
    @test project["weakdeps"]["Optional"] == "10000000-0000-0000-0000-000000000012"
    @test project["compat"]["Shared"] == "1.4"
    @test project["compat"]["Other"] == "2.3"
    @test project["compat"]["Optional"] == "0.5"
    @test project["compat"]["julia"] == "1.10"
    @test !haskey(project["deps"], "TestOnly")
    @test !haskey(project["sources"], "TestOnly")

    backup = joinpath(root, "Project.backup.toml")
    prepare_project(root, backup)
    @test read(backup, String) == original
    @test TOML.parsefile(joinpath(root, "Project.toml"))["compat"]["Shared"] == "1.4"
    restore_project(root, backup)
    @test read(joinpath(root, "Project.toml"), String) == original
    @test !isfile(backup)
end

@testset "locked Pkg.test accepts the reconciled source floor" begin
    fixture = make_locked_source_fixture()
    setup_log = joinpath(fixture.root, "setup.log")
    setup = run_fixture_julia(
        fixture,
        "using Pkg; Pkg.Registry.add(Pkg.RegistrySpec(path=$(repr(fixture.registry)))); " *
            "Pkg.add(Pkg.PackageSpec(name=\"CompatFloor\", version=v\"1.0.0\"))",
        setup_log,
    )
    @test success(setup)

    project_file = joinpath(fixture.project, "Project.toml")
    setup_backup = joinpath(fixture.root, "setup-project.toml")
    write(setup_backup, fixture.original_project)
    restore_project(fixture.project, setup_backup)
    @test read(project_file, String) == fixture.original_project

    failing_log = joinpath(fixture.root, "locked-failure.log")
    failing = run_fixture_julia(
        fixture,
        "using Pkg; Pkg.test(; allow_reresolve=false)",
        failing_log,
    )
    @test !success(failing)
    @test occursin("Unsatisfiable requirements", read(failing_log, String))

    backup = joinpath(fixture.root, "downgrade-project.toml")
    prepare_project(fixture.project, backup)
    rm(joinpath(fixture.project, "Manifest.toml"))
    resolve_log = joinpath(fixture.root, "resolve.log")
    resolved = run_fixture_julia(fixture, "using Pkg; Pkg.resolve()", resolve_log)
    @test success(resolved)
    restore_project(fixture.project, backup)

    manifest = TOML.parsefile(joinpath(fixture.project, "Manifest.toml"))
    @test only(manifest["deps"]["CompatFloor"])["version"] == "1.1.0"
    @test read(project_file, String) == fixture.original_project

    passing_log = joinpath(fixture.root, "locked-pass.log")
    passing = run_fixture_julia(
        fixture,
        "using Pkg; Pkg.test(; allow_reresolve=false)",
        passing_log,
    )
    @test success(passing)
end

@testset "sublibrary downgrade reconciles before locked testing" begin
    workflow = read(
        joinpath(@__DIR__, "..", ".github", "workflows", "sublibrary-downgrade.yml"),
        String,
    )
    prepare_at = findfirst("reconcile_downgrade_sources.jl\n          prepare", workflow)
    action_at = findfirst("julia-actions/julia-downgrade-compat@v2", workflow)
    restore_at = findfirst("reconcile_downgrade_sources.jl\n          restore", workflow)
    test_at = findfirst("julia-actions/julia-runtest@v1", workflow)
    @test all(!isnothing, (prepare_at, action_at, restore_at, test_at))
    @test first(prepare_at) < first(action_at) < first(restore_at) < first(test_at)
    @test occursin("if: always()", workflow)
    @test occursin("allow_reresolve: false", workflow)
end
