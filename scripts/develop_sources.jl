#!/usr/bin/env julia
#
# Develop the [sources] deps of a sub-project.
#
# On Julia < 1.11 the [sources] table is ignored when an environment is
# resolved/built/tested, so a monorepo sublibrary (e.g. lib/<name>) that relies
# on [sources] to pin its in-repo siblings would otherwise resolve them as
# registered packages. This script restores the 1.11+ behavior on 1.10 (the
# SciML LTS) by Pkg.develop-ing each `path =` or `url =` source. On Julia >=
# 1.11 it is a no-op (the table is honored natively).
#
# The walk is transitive: a developed source dep can itself declare further
# *runtime* [sources] that must also be developed for the environment to load.
# BUT when recursing into an already-developed dependency, only [sources] that
# are also that dependency's runtime [deps] are followed. A dependency's
# [sources] table may contain entries that exist purely for that dependency's
# own test suite -- their names live in [extras]/[targets].test, not [deps].
# Developing those would inject phantom direct deps into the package-under-test's
# environment, which then trips Aqua's stale-deps / deps-compat checks
# (SciML/Optimization.jl#1228). The package-under-test itself (the root of the
# walk) is exempt from this filter: its own test-only [sources] are legitimately
# needed when its own test suite runs.
#
# Usage (from a workflow step):
#   include("scripts/develop_sources.jl")
#   develop_sources(project_dir)
#
# `develop_sources` activates `project_dir`, computes the source specs to
# develop via `collect_source_specs`, and Pkg.develop-s them. The pure
# source-collection logic is split out so it can be unit-tested without mutating
# any environment.

using Pkg

"""
    collect_source_paths(proj) -> Vector{String}

Walk the `[sources]` graph rooted at `proj` (a directory containing a
`Project.toml`) and return the ordered list of absolute `path` sources to
develop. Each `path` source is resolved relative to the `Project.toml` that
declares it. The walk recurses into a developed dependency's own `[sources]`,
but for non-root projects only follows sources that are also runtime `[deps]`
of that project (skipping the dep's test-only sources). The root project itself
is excluded from the result (it is the active project; developing it would be a
cyclic self-develop). Only `path =` sources are returned; `url`/`rev` git
sources are left to `Pkg`. Visiting each resolved path once handles cycles and
diamonds in the graph. This function is version-independent and mutates nothing.
"""
function collect_source_paths(proj::AbstractString)
    return first(_collect_source_paths_and_specs(proj))
end

"""
    collect_source_specs(proj) -> Vector{Pkg.PackageSpec}

Walk the `[sources]` graph rooted at `proj` and return the ordered
`Pkg.PackageSpec`s to develop on Julia versions that do not natively honor
`[sources]`. Unlike `collect_source_paths`, this includes both local `path =`
sources and git `url =` sources, preserving `rev` and `subdir` when present.
"""
function collect_source_specs(proj::AbstractString)
    return last(_collect_source_paths_and_specs(proj))
end

function _source_url_key(dep::AbstractString, spec::AbstractDict)
    url = String(spec["url"])
    rev = String(get(spec, "rev", ""))
    subdir = String(get(spec, "subdir", ""))
    return "url:$dep:$url:$rev:$subdir"
end

function _source_url_spec(dep::AbstractString, spec::AbstractDict)
    kwargs = Pair{Symbol, Any}[:name => dep, :url => String(spec["url"])]
    haskey(spec, "rev") && push!(kwargs, :rev => String(spec["rev"]))
    haskey(spec, "subdir") && push!(kwargs, :subdir => String(spec["subdir"]))
    return Pkg.PackageSpec(; kwargs...)
end

function _collect_source_paths_and_specs(proj::AbstractString)
    projroot = normpath(abspath(proj))
    developed = Set{String}([projroot])  # never develop the active project
    paths = String[]
    specs = Pkg.PackageSpec[]
    queue = String[projroot]
    while !isempty(queue)
        dir = popfirst!(queue)
        tomlpath = joinpath(dir, "Project.toml")
        isfile(tomlpath) || continue
        toml = Pkg.TOML.parsefile(tomlpath)
        sources = get(toml, "sources", nothing)
        sources isa AbstractDict || continue
        isroot = normpath(abspath(dir)) == projroot
        runtimedeps = keys(get(toml, "deps", Dict{String, Any}()))
        for (dep, spec) in sources
            # For dependencies (not the package-under-test), skip [sources] that
            # are not runtime deps -- those are the dep's test-only sources and
            # must not leak into the active environment.
            isroot || dep in runtimedeps || continue
            spec isa AbstractDict || continue
            if haskey(spec, "path")
                p = normpath(abspath(joinpath(dir, spec["path"])))
                if isdir(p) && !(p in developed)
                    push!(developed, p)
                    push!(paths, p)
                    push!(specs, Pkg.PackageSpec(path = p))
                    push!(queue, p)  # resolve this dep's own runtime [sources] too
                end
            elseif haskey(spec, "url")
                key = _source_url_key(dep, spec)
                if !(key in developed)
                    push!(developed, key)
                    push!(specs, _source_url_spec(dep, spec))
                end
            end
        end
    end
    return paths, specs
end

"""
    develop_sources(proj)

Activate `proj` and, on Julia < 1.11, `Pkg.develop` its `[sources]` deps
(see `collect_source_specs`). No-op on Julia >= 1.11.
"""
function develop_sources(proj::AbstractString)
    Pkg.activate(proj)
    VERSION < v"1.11.0-DEV.0" || return nothing
    specs = collect_source_specs(proj)
    isempty(specs) || Pkg.develop(specs)
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    develop_sources(ARGS[1])
end
