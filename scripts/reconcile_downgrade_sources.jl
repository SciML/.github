#!/usr/bin/env julia

using Pkg
using TOML

isdefined(@__MODULE__, :collect_source_paths) ||
    include(joinpath(@__DIR__, "develop_sources.jl"))

function compat_lower_bound(spec::AbstractString)
    bounds = VersionNumber[]
    for alternative in split(spec, ',')
        part = strip(alternative)
        if startswith(part, '<')
            push!(bounds, v"0")
            continue
        end
        m = match(r"(?:^|[^0-9])v?([0-9]+(?:\.[0-9]+){0,2}(?:-[0-9A-Za-z.-]+)?)", part)
        push!(bounds, m === nothing ? v"0" : VersionNumber(m.captures[1]))
    end
    return isempty(bounds) ? v"0" : minimum(bounds)
end

function prefer_higher_floor(current, candidate)
    current isa AbstractString || return candidate
    candidate isa AbstractString || return current
    return compat_lower_bound(candidate) > compat_lower_bound(current) ? candidate : current
end

function source_projects(project_dir::AbstractString)
    return map(collect_source_paths(project_dir)) do path
        path => TOML.parsefile(joinpath(path, "Project.toml"))
    end
end

function flatten_source_constraints!(project::AbstractDict, project_dir::AbstractString)
    deps = get!(project, "deps", Dict{String, Any}())
    weakdeps = get!(project, "weakdeps", Dict{String, Any}())
    sources = get!(project, "sources", Dict{String, Any}())
    compat = get!(project, "compat", Dict{String, Any}())

    extras = get(project, "extras", Dict{String, Any}())
    test_target = get(get(project, "targets", Dict{String, Any}()), "test", String[])
    for name in test_target
        uuid = get(extras, name, get(weakdeps, name, nothing))
        if uuid !== nothing
            deps[name] = uuid
            delete!(weakdeps, name)
        end
    end

    local_projects = source_projects(project_dir)
    local_names = Set(String(source["name"]) for (_, source) in local_projects)
    haskey(project, "name") && push!(local_names, String(project["name"]))
    for (path, source) in local_projects
        name = String(source["name"])
        deps[name] = source["uuid"]
        sources[name] = Dict("path" => path)

        source_deps = get(source, "deps", Dict{String, Any}())
        source_weakdeps = get(source, "weakdeps", Dict{String, Any}())
        for (dependency, uuid) in source_deps
            dependency in local_names && continue
            deps[dependency] = uuid
            delete!(weakdeps, dependency)
        end
        for (dependency, uuid) in source_weakdeps
            dependency in local_names && continue
            haskey(deps, dependency) || (weakdeps[dependency] = uuid)
        end

        runtime_dependencies = union(keys(source_deps), keys(source_weakdeps))
        for (dependency, source_compat) in get(source, "compat", Dict{String, Any}())
            dependency == "julia" && continue
            dependency in local_names && continue
            dependency in runtime_dependencies || continue
            compat[dependency] = prefer_higher_floor(get(compat, dependency, nothing), source_compat)
        end
    end

    isempty(weakdeps) && delete!(project, "weakdeps")
    isempty(sources) && delete!(project, "sources")
    isempty(compat) && delete!(project, "compat")
    return project
end

function prepare_project(project_dir::AbstractString, backup_file::AbstractString)
    project_file = joinpath(project_dir, "Project.toml")
    original = read(project_file, String)
    write(backup_file, original)
    project = TOML.parse(original)
    flatten_source_constraints!(project, project_dir)
    open(project_file, "w") do io
        TOML.print(io, project)
    end
    return nothing
end

function restore_project(project_dir::AbstractString, backup_file::AbstractString)
    isfile(backup_file) || return nothing
    project_file = joinpath(project_dir, "Project.toml")
    write(project_file, read(backup_file, String))

    manifest_file = joinpath(project_dir, "Manifest.toml")
    if isfile(manifest_file)
        # Pkg has no public project-hash API. Updating this field is necessary after
        # restoring Project.toml so locked Pkg.test does not treat the manifest as stale.
        env = Pkg.Types.EnvCache(project_file)
        project_hash = if isdefined(Pkg.Types, :workspace_resolve_hash)
            Pkg.Types.workspace_resolve_hash(env)
        else
            Pkg.Types.project_resolve_hash(env.project)
        end
        manifest = TOML.parsefile(manifest_file)
        manifest["project_hash"] = string(project_hash)
        open(manifest_file, "w") do io
            TOML.print(io, manifest)
        end
    end
    rm(backup_file; force = true)
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 3 || error("usage: reconcile_downgrade_sources.jl prepare|restore PROJECT BACKUP")
    command, project_dir, backup_file = ARGS
    if command == "prepare"
        prepare_project(project_dir, backup_file)
    elseif command == "restore"
        restore_project(project_dir, backup_file)
    else
        error("unknown command: $command")
    end
end
