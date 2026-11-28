if VERSION >= v"1.11"
    mkpath(joinpath(@__DIR__, "build"))
    write(joinpath(@__DIR__, "build", "index.html"), "documentation fixture\n")
end
