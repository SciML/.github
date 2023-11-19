Contributing to SciML
=========================

Please use the following guides to help get started with contributing to SciML:

- [The SciMLStyle Guide](https://github.com/SciML/SciMLStyle) defines the coding rules and
  style for the SciML community.
- [ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://github.com/SciML/ColPrac)
  defines the contribution practices of the SciML organization.

When in doubt, please feel free to open an early pull request or issue and ask! We tend to
prefer an open development model, where results are shared early and often. If you feel stuck
and want help, join one of the [SciML community channels](https://sciml.ai/community/)
and ask for help!

## Interface Definitions and Developer Tooling

The SciML organization is a large organization with hundreds of packages. It can be
overwhelming when first getting accustomed to the ecosystem. Thus we suggest focusing on a
single aspect when getting started. Ask for help with what you do not know, and don't worry
if you may not have handled some case you don't understand (downstream test,
automatic differentiation failure, etc.), this is for the maintainers to help you with!
Just open the PR with what you have and describe what works and what does not work.

However, if you are looking for more information on the overarching interfaces of the SciML
organization, check out the following resources:

- [SciMLBase.jl Documentation](https://docs.sciml.ai/SciMLBase/stable/): this documentation
  defines the core interface of the SciML world, from the problem types to the algorithms
  and the traits that should be supplied to enforce type correctness.
- [SymbolicIndexingInterface.jl](https://docs.sciml.ai/SymbolicIndexingInterface/stable/)
  defines the global symbolic indexing interface used throughout all problem and solution
  types.
- [SciMLOperators.jl](https://docs.sciml.ai/SciMLOperators/stable/) defines the operator
  interface used in all of the solvers.
- [CommonSolve.jl](https://docs.sciml.ai/CommonSolve/stable/) defines the high level
  `solve`, `init`, and `solve!` interfaces.
- [ArrayInterface.jl](https://docs.sciml.ai/ArrayInterface/stable/) defines the extended
  set of array traits used to enforce correctness and allow for fast and slower routes
  depending on array attributes.
- [StaticArrayInterface.jl](https://docs.sciml.ai/StaticArrayInterface/stable/) is the
  ArrayInterface extension for static arrays.

Additionally, the following developer tools are provided:

- [DiffEqDevTools.jl](https://github.com/SciML/DiffEqDevTools.jl) defines test functionality
  for the differential equation solvers.
- [DiffEqProblemLibrary.jl](https://github.com/SciML/DiffEqProblemLibrary.jl) defines premade
  test problems with analytical solutions for defining correctness tests.

And lastly, the [SciMLBenchmarks](https://github.com/SciML/SciMLBenchmarks.jl) serves as an
automatically updating audit of performance.
