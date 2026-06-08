#!/usr/bin/env julia
#
# Compute which sublibrary test jobs need to run based on changed files.
#
# Reads the dependency graph from lib/*/Project.toml [deps] section only
# (NOT [extras]/test deps), identifies internal dependencies by matching dep names against
# known sublibrary directory names, computes the transitive reverse-dependency
# map, then given a list of changed files outputs a GitHub Actions matrix
# include list as JSON.
#
# Each sublibrary can optionally define test groups in test/test_groups.toml:
#
#   [Core]
#   versions = ["lts", "1", "pre"]
#
#   [QA]
#   versions = ["lts", "1"]
#
#   [GPU]
#   versions = ["1"]
#   runner = ["self-hosted", "Linux", "X64", "gpu"]
#
# Optional fields per group:
#   runner      — string or array of labels (default: "ubuntu-latest")
#   timeout     — integer, job timeout in minutes (default: 120)
#   num_threads — integer, JULIA_NUM_THREADS (default: 1)
#   local_only  — boolean (default: false). When true, the group is skipped
#                 whenever this sublibrary is only being tested because an
#                 upstream dependency changed (i.e. it landed in the matrix
#                 transitively, not because its own files were touched). Use
#                 this for groups so expensive that running them on every
#                 dependency-graph rebuild is wasteful — e.g. weak-convergence
#                 tests in the StochasticDiffEq sublibraries. The group still
#                 runs whenever any file under lib/<this-pkg>/ is edited.
#
# If no test/test_groups.toml exists, the default is:
#   Core on ["lts", "1", "pre"]
#   QA on ["lts", "1"]
#
# A group that needs test-only deps beyond the sublibrary's [targets].test list should
# carry an isolated environment at test/<group>/Project.toml that runtests.jl activates
# before running that group. This keeps heavy tooling (JET, Aqua, AllocCheck, CUDA, MTK, …)
# out of the main test env and out of reverse-dependency resolution. See CONTRIBUTING.md
# ("Per-group test environments") for the standard pattern.
#
# Directly changed packages get their full version matrix.
# Transitively affected packages (reverse deps) only run on version "1".
#
# Usage:
#   git diff --name-only origin/master...HEAD | julia compute_affected_sublibraries.jl /path/to/repo
#
# Output: JSON array of {group, version, runner, timeout, num_threads} objects
#   for GitHub Actions matrix include.
#
# With the --projects flag the output is instead a JSON array of the affected
# "lib/<pkg>" paths (the union of directly-changed and transitively-affected
# sublibraries), for the project-model sublibrary CI which tests each via
# `tests.yml` project=lib/<pkg> rather than GROUP dispatch. test_groups.toml
# (versions/runner/timeout/threads/local_only) does not apply in that mode.
#
# With the --root-matrix flag the output is the ROOT package's group matrix,
# read from <repo>/test/test_groups.toml (NOT under lib/), as a JSON array of
# {group, version, runner, timeout, num_threads, continue_on_error}. This is not
# diff-filtered (the root package runs all its groups every push/PR) and needs
# no lib/ directory, so ordinary single packages can use it too. When no
# test/test_groups.toml exists the default is a single "Core" group on
# ["lts", "1", "pre"]. Consumed by the reusable grouped-tests.yml so a repo's
# root CI.yml is a thin caller instead of a hand-maintained matrix. Usage:
#   julia compute_affected_sublibraries.jl /path/to/repo --root-matrix

using TOML

const DEFAULT_TEST_GROUPS = Dict(
    "Core" => ["lts", "1", "pre"],
    "QA" => ["lts", "1"],
)

function build_dependency_graph(lib_dir::String)
    # Collect all sublibrary names (directories with a Project.toml)
    known_sublibs = Set{String}()
    for entry in readdir(lib_dir)
        if isfile(joinpath(lib_dir, entry, "Project.toml"))
            push!(known_sublibs, entry)
        end
    end

    # Parse each sublibrary's Project.toml for internal deps.
    # Only use [deps], NOT [extras]/[targets] — those are test-only dependencies
    # and should not propagate downstream test triggering.
    graph = Dict{String, Vector{String}}()
    for pkg in known_sublibs
        toml = TOML.parsefile(joinpath(lib_dir, pkg, "Project.toml"))
        internal_deps = String[]
        if haskey(toml, "deps")
            for dep_name in keys(toml["deps"])
                if dep_name in known_sublibs
                    push!(internal_deps, dep_name)
                end
            end
        end
        graph[pkg] = internal_deps
    end

    return graph
end

function compute_reverse_deps(graph::Dict{String, Vector{String}})
    # Build direct reverse dependency map
    rev = Dict{String, Set{String}}()
    for (pkg, deps) in graph
        for dep in deps
            if !haskey(rev, dep)
                rev[dep] = Set{String}()
            end
            push!(rev[dep], pkg)
        end
    end

    # Compute transitive closure via DFS
    function get_all_rdeps!(visited::Set{String}, pkg::String)
        pkg in visited && return
        push!(visited, pkg)
        for rdep in get(rev, pkg, Set{String}())
            get_all_rdeps!(visited, rdep)
        end
        return
    end

    transitive = Dict{String, Set{String}}()
    for pkg in keys(graph)
        visited = Set{String}()
        get_all_rdeps!(visited, pkg)
        delete!(visited, pkg)  # don't include self
        transitive[pkg] = visited
    end

    return transitive
end

struct TestGroupConfig
    versions::Vector{String}
    runner::Any  # String or Vector{String}
    timeout::Int
    num_threads::Int
    local_only::Bool
    continue_on_error::Bool
end

function parse_test_group(config::AbstractDict)
    versions = convert(Vector{String}, config["versions"])
    runner_raw = get(config, "runner", "ubuntu-latest")
    runner = runner_raw isa Vector ? convert(Vector{String}, runner_raw) : runner_raw::String
    timeout = Int(get(config, "timeout", 120))
    num_threads = Int(get(config, "num_threads", 1))
    local_only = Bool(get(config, "local_only", false))
    continue_on_error = Bool(get(config, "continue_on_error", false))
    return TestGroupConfig(versions, runner, timeout, num_threads, local_only, continue_on_error)
end

function load_test_groups(lib_dir::String, pkg::String)
    groups_file = joinpath(lib_dir, pkg, "test", "test_groups.toml")
    if isfile(groups_file)
        toml = TOML.parsefile(groups_file)
        return Dict{String, TestGroupConfig}(name => parse_test_group(config) for (name, config) in toml)
    end
    return Dict{String, TestGroupConfig}(
        k => TestGroupConfig(v, "ubuntu-latest", 120, 1, false, false) for (k, v) in DEFAULT_TEST_GROUPS
    )
end

# The root package's own test groups (test/test_groups.toml at the repo root,
# NOT under lib/). Unlike the sublibrary matrix this is not diff-filtered: the
# root package runs all of its groups on every push/PR. Consumed by the
# reusable grouped-tests.yml so a monorepo root -- or any single package --
# declares its group x version matrix once in test_groups.toml and keeps CI.yml
# a thin caller, instead of hand-maintaining the matrix in YAML. When no
# test/test_groups.toml exists, defaults to a single "Core" group (the whole
# suite) on the standard version set.
const DEFAULT_ROOT_GROUPS = Dict("Core" => ["lts", "1", "pre"])

function load_root_test_groups(repo_root::String)
    groups_file = joinpath(repo_root, "test", "test_groups.toml")
    if isfile(groups_file)
        toml = TOML.parsefile(groups_file)
        groups = Dict{String, TestGroupConfig}(name => parse_test_group(config) for (name, config) in toml)
        isempty(groups) || return groups
    end
    return Dict{String, TestGroupConfig}(
        k => TestGroupConfig(v, "ubuntu-latest", 120, 1, false, false) for (k, v) in DEFAULT_ROOT_GROUPS
    )
end

"""
Return (directly_changed, transitively_affected) package sets.

Directly changed packages get their full version matrix from test_groups.toml.
Transitively affected packages (reverse deps) only run on version "1".
"""
function compute_affected(
        changed_files::Vector{String},
        graph::Dict{String, Vector{String}},
        reverse_deps::Dict{String, Set{String}}
    )
    direct = Set{String}()
    transitive = Set{String}()
    for filepath in changed_files
        filepath = strip(filepath)
        isempty(filepath) && continue

        parts = split(filepath, '/')
        if length(parts) >= 2 && parts[1] == "lib" && haskey(graph, String(parts[2]))
            pkg = String(parts[2])
            push!(direct, pkg)
            # Only propagate to reverse deps for src/ or Project.toml changes.
            # Test-only changes don't affect dependents.
            if length(parts) >= 3 &&
                    (parts[3] == "src" || (parts[3] == "Project.toml" && length(parts) == 3))
                union!(transitive, get(reverse_deps, pkg, Set{String}()))
            end
        end
    end
    # Packages that are both direct and transitive get the full matrix (direct wins).
    setdiff!(transitive, direct)
    return (direct, transitive)
end

# Entries to exclude from the matrix.
# Each entry is (group, version) where group is the CI GROUP string.
# See: https://github.com/SciML/OrdinaryDiffEq.jl/issues/2977
const EXCLUDES = Set(
    [
        ("OrdinaryDiffEqBDF", "pre"),  # JET resolution fails on pre-release Julia
    ]
)

const DOWNSTREAM_VERSION = "1"

function build_matrix(
        direct::Set{String}, transitive::Set{String}, lib_dir::String
    )
    entries = []
    for pkg in sort!(collect(union(direct, transitive)))
        groups = load_test_groups(lib_dir, pkg)
        is_downstream = pkg in transitive
        for group_name in sort!(collect(keys(groups)))
            config = groups[group_name]
            # local_only groups don't run when this package was only pulled
            # in via the reverse-dependency graph.
            is_downstream && config.local_only && continue
            ci_group = group_name == "Core" ? pkg : "$(pkg)_$(group_name)"
            # Downstream (transitive) deps only run on latest stable.
            versions = is_downstream ? [DOWNSTREAM_VERSION] : config.versions
            for ver in versions
                (ci_group, ver) in EXCLUDES && continue
                push!(
                    entries,
                    (;
                        group = ci_group, version = ver, runner = config.runner,
                        timeout = config.timeout, num_threads = config.num_threads,
                    )
                )
            end
        end
    end
    return entries
end

# Minimal JSON serialization (no external dependency needed)
function json_value(v::String)
    return print("\"", v, "\"")
end
function json_value(v::Vector)
    print("[")
    for (j, item) in enumerate(v)
        j > 1 && print(",")
        json_value(item)
    end
    return print("]")
end
function json_value(v::Int)
    return print(v)
end

function print_projects(direct::Set{String}, transitive::Set{String})
    print("[")
    for (i, pkg) in enumerate(sort!(collect(union(direct, transitive))))
        i > 1 && print(",")
        print("\"lib/", pkg, "\"")
    end
    return println("]")
end

# Like build_matrix, but for the project model: one entry per affected
# sublibrary × test group × version, carrying the lib/<pkg> project path and
# the bare group name (passed to the sublibrary's runtests via the group env
# var, e.g. ODEDIFFEQ_TEST_GROUP) rather than the GROUP-dispatch "pkg_group"
# string. Same test_groups.toml semantics (versions/runner/timeout/threads/
# local_only), downstream-only-on-v1 rule, and EXCLUDES as build_matrix.
function build_projects_matrix(
        direct::Set{String}, transitive::Set{String}, lib_dir::String
    )
    entries = []
    for pkg in sort!(collect(union(direct, transitive)))
        groups = load_test_groups(lib_dir, pkg)
        is_downstream = pkg in transitive
        for group_name in sort!(collect(keys(groups)))
            config = groups[group_name]
            is_downstream && config.local_only && continue
            ci_group = group_name == "Core" ? pkg : "$(pkg)_$(group_name)"
            versions = is_downstream ? [DOWNSTREAM_VERSION] : config.versions
            for ver in versions
                (ci_group, ver) in EXCLUDES && continue
                push!(
                    entries,
                    (;
                        project = "lib/$(pkg)", group = group_name, version = ver,
                        runner = config.runner, timeout = config.timeout,
                        num_threads = config.num_threads,
                    )
                )
            end
        end
    end
    return entries
end

function print_projects_matrix(entries)
    print("[")
    for (i, entry) in enumerate(entries)
        i > 1 && print(",")
        print(
            "{\"project\":\"", entry.project, "\",\"group\":\"", entry.group,
            "\",\"version\":\"", entry.version, "\",\"runner\":",
        )
        json_value(entry.runner)
        print(",\"timeout\":", entry.timeout, ",\"num_threads\":", entry.num_threads, "}")
    end
    return println("]")
end

function print_json(entries)
    print("[")
    for (i, entry) in enumerate(entries)
        i > 1 && print(",")
        print("{\"group\":\"", entry.group, "\",\"version\":\"", entry.version, "\",\"runner\":")
        json_value(entry.runner)
        print(",\"timeout\":", entry.timeout, ",\"num_threads\":", entry.num_threads, "}")
    end
    return println("]")
end

# Root-package matrix: every group × every version it lists, with no diff
# filtering (the root package runs all its groups on every push/PR). Carries
# continue_on_error so a non-fatal group (e.g. OrdinaryDiffEq's Downstream) maps
# to tests.yml's continue-on-error input.
function build_root_matrix(repo_root::String)
    groups = load_root_test_groups(repo_root)
    entries = []
    for group_name in sort!(collect(keys(groups)))
        config = groups[group_name]
        for ver in config.versions
            push!(
                entries,
                (;
                    group = group_name, version = ver, runner = config.runner,
                    timeout = config.timeout, num_threads = config.num_threads,
                    continue_on_error = config.continue_on_error,
                )
            )
        end
    end
    return entries
end

function print_root_matrix(entries)
    print("[")
    for (i, entry) in enumerate(entries)
        i > 1 && print(",")
        print("{\"group\":\"", entry.group, "\",\"version\":\"", entry.version, "\",\"runner\":")
        json_value(entry.runner)
        print(
            ",\"timeout\":", entry.timeout, ",\"num_threads\":", entry.num_threads,
            ",\"continue_on_error\":", entry.continue_on_error ? "true" : "false", "}",
        )
    end
    return println("]")
end

function main()
    if length(ARGS) < 1
        println(stderr, "Usage: julia $(PROGRAM_FILE) <repo_root>")
        exit(1)
    end

    repo_root = ARGS[1]

    # Root-package group matrix from <repo>/test/test_groups.toml. Independent of
    # the sublibrary dependency graph, so it works for ordinary single packages
    # too (no lib/ required) -- handle it before the lib/ check.
    if "--root-matrix" in ARGS
        return print_root_matrix(build_root_matrix(repo_root))
    end

    lib_dir = joinpath(repo_root, "lib")

    if !isdir(lib_dir)
        println(stderr, "Error: $lib_dir is not a directory")
        exit(1)
    end

    graph = build_dependency_graph(lib_dir)
    reverse_deps = compute_reverse_deps(graph)

    changed_files = split(read(stdin, String), '\n')
    direct, transitive = compute_affected(collect(String, changed_files), graph, reverse_deps)

    if "--projects-matrix" in ARGS
        return print_projects_matrix(build_projects_matrix(direct, transitive, lib_dir))
    end

    if "--projects" in ARGS
        return print_projects(direct, transitive)
    end

    matrix = build_matrix(direct, transitive, lib_dir)
    return print_json(matrix)
end

# Only run when executed as a script; `include`-ing the file (e.g. from the
# test suite) gets the functions without invoking main().
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
