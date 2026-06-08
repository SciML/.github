# The SciML Canonical Monorepo Structure

This is the reference specification for a **SciML monorepo**: a Julia package
whose functionality is split across many independently-registered sub-packages
living under `lib/<Name>/`, all in one Git repository, sharing one CI system.

The canonical reference implementation is
[**SciML/OrdinaryDiffEq.jl**](https://github.com/SciML/OrdinaryDiffEq.jl) — when
in doubt, copy what it does. Other monorepos on this pattern include
ModelingToolkit.jl, NonlinearSolve.jl, LinearSolve.jl, Optimization.jl,
BoundaryValueDiffEq.jl, and RecursiveArrayTools.jl. The shared CI lives in
[SciML/.github](https://github.com/SciML/.github); the reusable workflows are
consumed at the `@v1` moving tag (see the
[README](README.md#versioning-the-v1-moving-tag)).

Every concrete value, file shape, and snippet below is taken from the live
`SciML/.github` `@v1` reusable workflows and from OrdinaryDiffEq.jl `master`.

## Table of contents

1. [Repository layout](#1-repository-layout)
2. [The `[sources]` dependency graph](#2-the-sources-dependency-graph)
3. [Test structure: one group, one folder](#3-test-structure-one-group-one-folder)
4. [Group names and the test-group env var](#4-group-names-and-the-test-group-env-var)
5. [`test_groups.toml`](#5-test_groupstoml)
6. [Workflows: thin `@v1` callers](#6-workflows-thin-v1-callers)
7. [Repository-level files](#7-repository-level-files)
8. [Formatting](#8-formatting)
9. [Checklist for a new monorepo](#9-checklist-for-a-new-monorepo)

---

## 1. Repository layout

A monorepo is an **umbrella root package** plus one **full package per
sublibrary** under `lib/`:

```
OrdinaryDiffEq.jl/
├── Project.toml                 # the umbrella/root package
├── src/                         # root package source
├── test/                        # root test suite (grouped, see §3)
│   ├── runtests.jl
│   ├── interface/  integrators/  regression/  qa/  ...   # one folder per group
│   ├── ad/Project.toml          # dep-adding root group (isolated env)
│   └── gpu/Project.toml
├── README.md  LICENSE.md  .gitignore  .codecov.yml  .typos.toml
├── docs/  benchmark/
├── .github/workflows/           # thin @v1 callers (see §6)
└── lib/
    ├── OrdinaryDiffEqCore/       # a full, standalone, registered package
    │   ├── Project.toml          # name/uuid/version/authors/[deps]/[compat]/[extras]/[targets] (+ [sources] if it has in-repo deps)
    │   ├── src/
    │   ├── test/
    │   │   ├── runtests.jl       # reads the test-group env var, dispatches groups
    │   │   ├── test_groups.toml  # optional: per-group versions/runner/timeout/threads
    │   │   ├── qa/Project.toml   # dep-adding group → isolated env
    │   │   └── gpu/Project.toml
    │   ├── LICENSE.md
    │   └── README.md             # monorepo-component template
    ├── OrdinaryDiffEqBDF/
    ├── OrdinaryDiffEqDefault/
    └── ...                        # ~55 sublibraries in OrdinaryDiffEq
```

Each `lib/<Name>/` is a **complete Julia package** — registerable, testable, and
usable entirely on its own. It is not a "subdirectory of code"; it has its own
`uuid`, its own `version`, its own `[compat]`, and is tagged/registered
independently (see TagBot in §6).

### The root `Project.toml`

The root package re-exports / glues together a curated subset of the
sublibraries. Its `[deps]` are the sublibraries (and external packages) it
actually depends on, and its `[sources]` point at the in-repo copies of those it
tests against. From OrdinaryDiffEq.jl's root `Project.toml`:

```toml
name = "OrdinaryDiffEq"
uuid = "1dea7af3-3e70-54e6-95c3-0bf5283fa5ed"
authors = ["Chris Rackauckas <accounts@chrisrackauckas.com>", "Yingbo Ma <mayingbo5@gmail.com>"]
version = "7.0.0"

[deps]
ADTypes = "47edcb42-4c32-4615-8424-f2b9edc5f35b"
OrdinaryDiffEqBDF = "6ad6398a-0878-4a85-9266-38940aa047c8"
OrdinaryDiffEqCore = "bbf590c4-e513-4bbe-9b18-05decba2e5d8"
OrdinaryDiffEqDefault = "50262376-6c5a-4cf5-baba-aaf4f84d72d7"
# ... and the other re-exported solver sets

[sources]
OrdinaryDiffEqCore = {path = "lib/OrdinaryDiffEqCore"}
OrdinaryDiffEqBDF = {path = "lib/OrdinaryDiffEqBDF"}
OrdinaryDiffEqDefault = {path = "lib/OrdinaryDiffEqDefault"}
# ... one entry per tested in-repo sublibrary, as path = "lib/<Name>"

[compat]
OrdinaryDiffEqCore = "4, 5.0"
OrdinaryDiffEqBDF = "2"
julia = "1.10"

[extras]
# base test deps only — see §3
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
SafeTestsets = "1bc83da4-3b8d-516f-aca4-4fe02f6d838f"
# ...

[targets]
test = ["Test", "SafeTestsets", "DiffEqDevTools", ...]
```

### A sublibrary `Project.toml`

A sublibrary is a normal package `Project.toml` with the full standard set of
sections: `name`, `uuid`, `version`, `authors`, `[deps]`, optional `[weakdeps]`
/ `[extensions]`, `[compat]`, `[extras]`, `[targets]`, and — if it depends on
sibling sublibraries — `[sources]`. A leaf such as `OrdinaryDiffEqCore` has no
`[sources]` at all (it depends on no in-repo package).

### The component `README.md`

Every sublibrary uses the **monorepo-component README template**. From
`lib/OrdinaryDiffEqBDF/README.md`:

```markdown
# OrdinaryDiffEqBDF.jl

[![Join the chat at https://julialang.zulipchat.com #sciml-bridged](https://img.shields.io/static/v1?label=Zulip&message=chat&color=9558b2&labelColor=389826)](https://julialang.zulipchat.com/#narrow/stream/279055-sciml-bridged)
[![Global Docs](https://img.shields.io/badge/docs-SciML-blue.svg)](https://docs.sciml.ai/DiffEqDocs/stable/solvers/ode_solve/stiff/)

[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor%27s%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![SciML Code Style](https://img.shields.io/static/v1?label=code%20style&message=SciML&color=9558b2&labelColor=389826)](https://github.com/SciML/SciMLStyle)

OrdinaryDiffEqBDF.jl is a component of the [OrdinaryDiffEq.jl](https://github.com/SciML/OrdinaryDiffEq.jl) monorepo. Backward Differentiation Formula (BDF) and related implicit multistep methods for stiff ODEs and DAEs.
While completely independent and usable on its own, users wanting the full ODE solver suite should use [OrdinaryDiffEq.jl](https://github.com/SciML/OrdinaryDiffEq.jl).

## Solvers

- `ABDF2`
- `QNDF`
- `FBDF`
...
```

The two load-bearing lines are the standard SciML badge block and the sentence
**"X.jl is a component of the [Umbrella.jl](...) monorepo. ... While completely
independent and usable on its own, users wanting the full suite should use
[Umbrella.jl](...)."**

Each sublibrary also carries its own `LICENSE.md` (same license as the root).

---

## 2. The `[sources]` dependency graph

In-repo dependencies are wired with relative-path `[sources]` entries so that a
checkout tests the code *in the working tree*, not a registered release.

**Rules:**

- A sublibrary lists its sibling in-repo deps by relative path:
  ```toml
  [sources]
  Sibling = {path = "../Sibling"}
  ```
  From `lib/OrdinaryDiffEqDefault/Project.toml`:
  ```toml
  [sources]
  DiffEqBase = {path = "../DiffEqBase"}
  OrdinaryDiffEqBDF = {path = "../OrdinaryDiffEqBDF"}
  OrdinaryDiffEqCore = {path = "../OrdinaryDiffEqCore"}
  OrdinaryDiffEqRosenbrock = {path = "../OrdinaryDiffEqRosenbrock"}
  OrdinaryDiffEqTsit5 = {path = "../OrdinaryDiffEqTsit5"}
  OrdinaryDiffEqVerner = {path = "../OrdinaryDiffEqVerner"}
  ```
- The **root** lists the sublibraries it tests against as
  `{path = "lib/<Name>"}` (see §1).
- When a sublibrary (or a per-group env, see §3) needs to point back at the
  root package, it uses `{path = "../.."}` (from a `lib/<Name>/` directory) or
  the right number of `..` from a deeper test-group folder.

**Constraints — read these before editing any `[sources]`:**

- **Never add a `[sources]` entry for a package that is not also in `[deps]`.**
  Pkg rejects a `[sources]` key with no corresponding dependency. `[sources]`
  *redirects* an existing dependency to a local path; it does not *add* one.
- **Preserve the true dependency direction.** Leaf → root is fine (a sublibrary
  depending on the umbrella, e.g. in a GPU test env). Do **not** introduce a
  cyclic root → leaf edge in package `[deps]` that contradicts the real
  architecture; the umbrella depends on its components, not the reverse.
- The graph must stay acyclic in `[deps]`. (Test-only `[sources]` in a per-group
  env may point "up" at the root without creating a package-level cycle, because
  that env is not itself a dependency of anything.)

**Why it matters:** the reusable sublibrary CI
([`scripts/compute_affected_sublibraries.jl`](scripts/compute_affected_sublibraries.jl))
builds the **affected + reverse-dependency** test matrix from this graph. It
reads each `lib/*/Project.toml` **`[deps]` only** (not `[extras]`/`[targets]`),
keeps the deps whose names match a `lib/<Name>` directory, and computes the
transitive reverse-dependency closure. So:

- A directly-changed sublibrary is tested on its full version matrix.
- Every sublibrary that (transitively) depends on it is **downstream-affected**
  and tested on the latest stable (`"1"`) only.
- A change confined to a sublibrary's `test/` does **not** propagate to
  dependents.
- A correct `[deps]`/`[sources]` graph is therefore what makes "test only what a
  change affects" correct. A missing edge under-tests; a wrong edge over-tests
  or breaks resolution.

---

## 3. Test structure: one group, one folder

Tests are partitioned into **groups**. Each group runs as a separate CI job, and
**every test belongs to exactly one group**. Each group gets **its own
`test/<Group>/` folder** (at the root *and* inside each sublibrary) so test files
are physically separated by group.

### Per-group `Project.toml` is dependency-driven

Whether a group needs a `Project.toml` is decided purely by **whether it needs
extra dependencies** beyond the package's main test environment
(`[extras]` + `[targets].test`):

| Group needs extra deps? | `test/<Group>/Project.toml`? | Where it runs | In the "All" run? |
|---|---|---|---|
| **No** | **No** Project.toml | Main test env | **Yes** — part of `All` |
| **Yes** | **Yes** Project.toml | Its own isolated env, activated via `Pkg.activate` in `runtests.jl` | **No** — excluded from `All` |

A group with **no extra deps** lives directly in the main test environment and is
exercised as part of the default `All` run.

A group that **adds deps** carries an isolated `test/<Group>/Project.toml`
containing:

- `[sources]` redirecting the package-under-test back to the repo:
  `pkg = {path = "../.."}` (plus any sibling in-repo deps),
- the **extra** dependencies that group needs,
- `Test`.

It is **excluded from the `All`/`Core` run** and activated on its own via
`Pkg.activate(joinpath(@__DIR__, "<group>"))` in `runtests.jl`. This keeps heavy
tooling (JET, Aqua, AllocCheck, CUDA, Enzyme, ModelingToolkit, …) out of the main
test environment *and* out of every reverse-dependency's resolution.

Example — the sublibrary **QA** group `lib/OrdinaryDiffEqCore/test/qa/Project.toml`:

```toml
[deps]
Aqua = "4c88cf16-eb10-579e-8560-4a9242c79595"
DiffEqBase = "2b5f629d-d688-5b77-993f-72d75c75574e"
JET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"
OrdinaryDiffEqCore = "bbf590c4-e513-4bbe-9b18-05decba2e5d8"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[sources.OrdinaryDiffEqCore]
path = "../.."

[sources.DiffEqBase]
path = "../../../DiffEqBase"

[compat]
Aqua = "0.8.11"
DiffEqBase = "7"
JET = "0.9, 0.11"
OrdinaryDiffEqCore = "4"
julia = "1.10"
```

Example — a **GPU** group env `lib/OrdinaryDiffEqCore/test/gpu/Project.toml`
adds `CUDA`, `Adapt`, etc. and sources the umbrella with the right depth of `..`:

```toml
[sources.OrdinaryDiffEq]
path = "../../../.."
[sources.OrdinaryDiffEqCore]
path = "../../../OrdinaryDiffEqCore"
```

### The **QA** group

QA (`Aqua` ambiguity/quality checks, `JET` static analysis, `AllocCheck`
allocation checks) almost always needs extra deps, so it lives in
`test/qa/Project.toml` and is **excluded from `All`**, run as its own job. (If a
particular QA group needs nothing beyond what's already in the main test env —
e.g. only `ExplicitImports`, as in the OrdinaryDiffEq *root* QA group — then by
the dependency-driven rule it has no `Project.toml` and runs in the main env.
The rule is about dependencies, not about the group's name.)

### Keep the main `[extras]`/`[targets].test` light

The package's main `[extras]` + `[targets].test` should contain only the **base**
test dependencies needed for the in-env (`Core`/`All`) groups. Everything heavier
belongs in a per-group `test/<Group>/Project.toml`. A light main test target is
what keeps reverse-dependency resolution fast and avoids forcing the whole fleet
to resolve JET/CUDA/MTK.

### There is no top-level `test/Project.toml`

The main test dependencies live in the package's `[extras]` + `[targets].test`
(the standard Julia mechanism). **Do not create a `test/Project.toml`** — it
breaks `Pkg.test`'s standard test-dependency resolution. The *only* test
`Project.toml` files in the repo are the **per-group** ones
(`test/<Group>/Project.toml`).

---

## 4. Group names and the test-group env var

### Naming

- Standard groups are **capitalized**: `All`, `Core`, `QA`.
- Custom groups are **Title-case**: `InterfaceI`, `Integrators_I`,
  `AlgConvergence_II`, `ModelingToolkit`, `Downstream`, `GPU`.
- The default when no group is set is **`All`**.

**Never** read the group through `lowercase(get(ENV, ...))`. The group string is
compared as-is, in its canonical case.

### The env var

Each repo threads a single test-group environment variable. The reusable
sublibrary CI sets it via the `group-env-name` input, and **every**
`runtests.jl` in the repo reads from it. OrdinaryDiffEq uses
`ODEDIFFEQ_TEST_GROUP`:

```julia
const TEST_GROUP = get(ENV, "ODEDIFFEQ_TEST_GROUP", "All")
```

A sublibrary's `runtests.jl` then dispatches on it, activating an isolated env
for dep-adding groups and running base groups in place. From
`lib/OrdinaryDiffEqCore/test/runtests.jl`:

```julia
using Pkg
using SafeTestsets

const TEST_GROUP = get(ENV, "ODEDIFFEQ_TEST_GROUP", "ALL")

function activate_qa_env()
    Pkg.activate(joinpath(@__DIR__, "qa"))
    return Pkg.instantiate()
end

if TEST_GROUP == "GPU"
    activate_gpu_env()
    @time @safetestset "Simple GPU" include("gpu/simple_gpu.jl")
end

if (TEST_GROUP == "QA" || TEST_GROUP == "ALL") && isempty(VERSION.prerelease)
    activate_qa_env()
    @time @safetestset "JET Tests" include("qa/jet.jl")
    @time @safetestset "Aqua" include("qa/qa.jl")
end

if TEST_GROUP == "Core" || TEST_GROUP == "ALL"
    @time @safetestset "Discontinuity Detection" include("disco_tests.jl")
end
```

### The root `runtests.jl` is a sublibrary-group dispatcher

At the root, `test/runtests.jl` does double duty. When `GROUP` is a *root* group
(e.g. `InterfaceI`, `QA`, `AD`) it runs that group's tests. When `GROUP` names a
sublibrary — either bare (`OrdinaryDiffEqCore`, meaning that sublib's `Core`
group) or as `<Sublib>_<Group>` (`OrdinaryDiffEqCore_QA`) — it activates
`lib/<Sublib>` and runs that sublibrary's tests. The dispatcher that splits the
name is `_detect_sublibrary_group`, from the root `test/runtests.jl`:

```julia
const GROUP = get(ENV, "GROUP", "All")

# GROUP can be a bare sublibrary name (its Core group) or "{sublib}_{GROUP}"
# for any custom group (QA, GPU, …). Scan underscores right-to-left to find
# the longest matching sublibrary prefix.
function _detect_sublibrary_group(group, lib_dir)
    isdir(joinpath(lib_dir, group)) && return (group, "Core")
    for i in length(group):-1:1
        if group[i] == '_' && isdir(joinpath(lib_dir, group[1:(i - 1)]))
            return (group[1:(i - 1)], group[(i + 1):end])
        end
    end
    return (group, "Core")
end
base_group, test_group = _detect_sublibrary_group(GROUP, lib_dir)

if isdir(joinpath(lib_dir, base_group))
    Pkg.activate(joinpath(lib_dir, base_group))
    # (on Julia < 1.11, manually Pkg.develop the [sources] path deps)
    withenv("ODEDIFFEQ_TEST_GROUP" => test_group) do
        Pkg.test(base_group; ...)
    end
end
```

(The project-model sublibrary CI in §6 invokes each sublibrary's own
`runtests.jl` directly via `project: lib/<Name>`, so a root dispatcher is not
strictly required for it; the root dispatcher remains useful for running a
sublibrary group locally or from the root `CI.yml`.)

---

## 5. `test_groups.toml`

Each sublibrary may declare its group matrix in
`lib/<Name>/test/test_groups.toml`. The reusable CI reads it to expand that
sublibrary into one CI job per `(group × version)`. `versions` is **required**
per group; `runner`, `timeout`, and `num_threads` are optional.

From `lib/OrdinaryDiffEqCore/test/test_groups.toml`:

```toml
[Core]
versions = ["lts", "1.11", "1", "pre"]

[GPU]
versions = ["1"]
runner = ["self-hosted", "Linux", "X64", "gpu"]
timeout = 60

[QA]
versions = ["1"]
```

| Field | Required? | Default | Meaning |
|---|---|---|---|
| `versions` | **yes** | — | Julia versions to run this group on. |
| `runner` | no | `"ubuntu-latest"` | `runs-on` string, or a JSON/TOML array of labels (e.g. a GPU self-hosted runner). |
| `timeout` | no | `120` | Job timeout, minutes. |
| `num_threads` | no | `1` | `JULIA_NUM_THREADS`. |
| `local_only` | no | `false` | When `true`, skip the group if the sublibrary is in the matrix *only* because an upstream dependency changed (not its own files). For groups too expensive to run on every transitive rebuild — e.g. the weak-convergence groups in `StochasticDiffEqWeak`. |

### Version convention

The established version sets (verified against OrdinaryDiffEq's `test_groups.toml`
files and the detection script's defaults):

- **Standard / `Core` (base) groups:** `["lts", "1.11", "1", "pre"]`.
- **`QA` groups:** `["1"]`.
- **`GPU` groups:** `["1"]`.

If a sublibrary has **no `test_groups.toml`**, the CI applies the default
`Core` on `["lts", "1.11", "1", "pre"]` + `QA` on `["1"]`.

> Note: downstream (reverse-dependency-affected) sublibraries are always run on
> the single latest-stable version `"1"` regardless of their declared
> `versions`, by the change-detection script.

### GPU is a dep-adding group on a custom runner — there is no GPU workflow

GPU testing is **not** a separate workflow. It is just a group:

1. `test/gpu/Project.toml` (the isolated env with `CUDA` etc., per §3),
2. a `[GPU]` entry in `test_groups.toml` with
   `runner = ["self-hosted", "Linux", "X64", "gpu"]`,
3. a `if TEST_GROUP == "GPU"` branch in `runtests.jl` that activates the GPU env.

There is **no bespoke `GPU.yml`**. The standard sublibrary CI picks up the GPU
group from `test_groups.toml` and schedules it on the GPU runner.

---

## 6. Workflows: thin `@v1` callers

Every workflow in `.github/workflows/` is a **thin caller** that delegates to a
reusable workflow in `SciML/.github` at `@v1`, with `secrets: "inherit"`. Do not
inline build/test steps, permissions, or matrices that a reusable workflow
already owns. The canonical OrdinaryDiffEq set:

### `SublibraryCI.yml` → `sublibrary-project-tests.yml@v1`

```yaml
jobs:
  sublibrary-ci:
    uses: "SciML/.github/.github/workflows/sublibrary-project-tests.yml@v1"
    with:
      group-env-name: ODEDIFFEQ_TEST_GROUP
      check-bounds: auto
    secrets: "inherit"
```

This is the heart of monorepo CI: it computes the affected sublibrary set from
the `[deps]` graph (§2), expands each via `test_groups.toml` (§5), and runs each
through `tests.yml` with `project: lib/<Name>` and the group passed through the
`group-env-name` env var. `check-bounds: auto` lets the matrix run bounds checks
per the matrix cell.

### `DowngradeSublibraries.yml` → `sublibrary-downgrade.yml@v1`

```yaml
jobs:
  downgrade-sublibraries:
    uses: "SciML/.github/.github/workflows/sublibrary-downgrade.yml@v1"
    secrets: "inherit"
    with:
      julia-version: "1.11"
      skip: "Pkg,TOML,Statistics,LinearAlgebra,SparseArrays,InteractiveUtils,OrdinaryDiffEqCore,OrdinaryDiffEqNonlinearSolve,OrdinaryDiffEqDifferentiation"
      group-env-name: "ODEDIFFEQ_TEST_GROUP"
      group-env-value: "Core"
```

The reusable workflow **auto-discovers every `lib/<Name>` with a Project.toml**
and downgrade-tests each. **Downgrade is strict fleet-wide:** the reusable
workflow hardcodes `allow_reresolve: false` and exposes **no `allow-reresolve`
input** — there is no per-repo opt-out. The `skip` input
(default `"Pkg,TOML"`) is the comma-separated list of deps the downgrade step
should not touch; a monorepo caller adds the stdlibs it uses and the in-repo
sublibraries it doesn't want downgraded (as above). Use `exclude` to drop
sublibraries from the auto-discovered set.

### `Downgrade.yml` → `downgrade.yml@v1` (root package)

```yaml
jobs:
  test:
    name: "Downgrade"
    uses: "SciML/.github/.github/workflows/downgrade.yml@v1"
    with:
      julia-version: "1.11"
      group: "InterfaceI"
      skip: "Pkg,TOML,Statistics,LinearAlgebra,SparseArrays,InteractiveUtils"
    secrets: "inherit"
```

Same strict policy: the reusable `downgrade.yml` hardcodes `allow_reresolve:
false` with no input.

### `CI.yml` (root suite, group-dispatched)

The root suite is GROUP-dispatched: a matrix over the root test groups, each cell
passing `GROUP: ${{ matrix.group }}` to `julia-actions/julia-runtest`, which the
root `runtests.jl` dispatches on (§4). OrdinaryDiffEq's matrix groups are e.g.
`InterfaceI…V`, `Integrators_I/II`, `AlgConvergence_I/II/III`, `ModelingToolkit`,
`Downstream`, `QA`, `Regression_I/II`, `AD`, across versions `lts`/`1.11`/`1`/`pre`.

### `Documentation.yml` → `documentation.yml@v1`

```yaml
jobs:
  build-and-deploy-docs:
    name: "Documentation"
    uses: "SciML/.github/.github/workflows/documentation.yml@v1"
    secrets: "inherit"
```

The reusable `documentation.yml` exposes a `runner` input (JSON-encoded
`runs-on`, e.g. `'["self-hosted","Linux","X64","gpu"]'`) for building docs on a
GPU queue when the docs need a GPU.

### `Downstream.yml`

Integration tests that load this package into selected downstream repos and run
their suites (resolver failures are treated as an intentional breaking change and
pass). This is a per-repo workflow listing the downstream consumers to exercise.

### `FormatCheck.yml` → `runic.yml@v1` and `RunicSuggestions.yml` → `runic-suggestions-on-pr.yml@v1`

```yaml
# FormatCheck.yml
jobs:
  runic:
    name: "Runic"
    uses: "SciML/.github/.github/workflows/runic.yml@v1"
    secrets: "inherit"
```
```yaml
# RunicSuggestions.yml
jobs:
  runic-suggestions:
    uses: "SciML/.github/.github/workflows/runic-suggestions-on-pr.yml@v1"
    secrets: "inherit"
```

See [§8](#8-formatting) for the Catalyst/JumpProcesses JuliaFormatter exception.

### `SpellCheck.yml` → `spellcheck.yml@v1`

```yaml
jobs:
  typos-check:
    name: "Spell Check with Typos"
    uses: "SciML/.github/.github/workflows/spellcheck.yml@v1"
    secrets: "inherit"
```

### `TagBot.yml` → `tagbot.yml@v1` + a `TagBot-Subpackages` matrix

TagBot stays thin: a root job for the umbrella plus a matrix job that tags each
**registered** `lib/<Name>` via the `subdir` input. Do **not** inline
permissions/steps per package — list the package names in the matrix and let one
templated step run per `subdir`. Shape (from OrdinaryDiffEq's `TagBot.yml`):

```yaml
jobs:
  TagBot-OrdinaryDiffEq:
    if: github.event_name == 'workflow_dispatch' || github.actor == 'JuliaTagBot'
    runs-on: ubuntu-latest
    steps:
      - uses: JuliaRegistries/TagBot@v1
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          ssh: ${{ secrets.DOCUMENTER_KEY }}

  TagBot-Subpackages:
    if: github.event_name == 'workflow_dispatch' || github.actor == 'JuliaTagBot'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        package:
          - OrdinaryDiffEqCore
          - OrdinaryDiffEqBDF
          # ... every registered lib/<Name>
    steps:
      - uses: JuliaRegistries/TagBot@v1
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          ssh: ${{ secrets.DOCUMENTER_KEY }}
          subdir: "lib/${{ matrix.package }}"
```

### `DependabotAutoMerge.yml` → `dependabot-automerge.yml@v1`

```yaml
jobs:
  automerge:
    uses: "SciML/.github/.github/workflows/dependabot-automerge.yml@v1"
    secrets: "inherit"
```

### `DocPreviewCleanup.yml` → `docs-preview-cleanup.yml@v1`

```yaml
jobs:
  doc-preview-cleanup:
    uses: "SciML/.github/.github/workflows/docs-preview-cleanup.yml@v1"
    secrets: "inherit"
```

### `benchmark.yml`

A per-repo PR-benchmark workflow (e.g. via `MilesCranmer/AirspeedVelocity.jl`)
running `benchmark/benchmarks.jl`.

---

## 7. Repository-level files

| File | Content / convention |
|---|---|
| `.codecov.yml` | `comment: false`. |
| `.typos.toml` | `[default.extend-words]` listing domain terms `typos` must not "correct" — Julia API names (`eachindex`, `getu`, …), math terms (`jacobian`, `discretization`, `preconditioner`, …), and author surnames in citations (`Hairer`, `Wanner`, `Rodas5P`, …). |
| `.gitignore` | Ignores `Manifest.toml`, `docs/build`, `LocalPreferences.toml`, `*.jl.cov` / `*.jl.*.cov` / `*.jl.mem`, and `.vscode`. |
| `LICENSE.md` | One **per package**: at the root *and* in each `lib/<Name>/`. |

The OrdinaryDiffEq `.codecov.yml` is exactly:

```yaml
comment: false
```

and `.gitignore`:

```gitignore
*.jl.cov
*.jl.*.cov
*.jl.mem
*.jl.*.mem
Manifest.toml
.vscode
LocalPreferences.toml
docs/build
```

`.typos.toml` opens with:

```toml
[default.extend-words]
# Julia-specific functions
eachindex = "eachindex"
getu = "getu"
# Mathematical/scientific terms
jacobian = "jacobian"
discretization = "discretization"
# Person names in citations
Hairer = "Hairer"
Wanner = "Wanner"
```

---

## 8. Formatting

**Runic is the fleet default.** A standard repo uses:

- `FormatCheck.yml` → `runic.yml@v1` (the CI check), and
- `RunicSuggestions.yml` → `runic-suggestions-on-pr.yml@v1` (auto-suggests fixes
  on PRs).

**JuliaFormatter exceptions: Catalyst.jl and JumpProcesses.jl.** These two repos
have not migrated to Runic and instead use the JuliaFormatter (`SciMLStyle`)
reusable workflows — `format-check.yml@v1` (and/or
`format-suggestions-on-pr.yml@v1`) — rather than `runic.yml@v1`. New monorepos
should use **Runic**; only these two legacy repos are on JuliaFormatter.

### Things that are *not* part of the standard set

- **CompatHelper is removed fleet-wide.** `[compat]` bumps are handled by
  Dependabot (GitHub Actions + Julia ecosystem) plus
  `dependabot-automerge.yml@v1`. Do not add a `CompatHelper.yml`.
- **Invalidations** is **not** a standard per-repo workflow.

---

## 9. Checklist for a new monorepo

- [ ] Umbrella root package `Project.toml` with `[deps]`/`[sources]`
      (`lib/<Name>`) for tested sublibraries; **light** `[extras]`/`[targets].test`.
- [ ] Each `lib/<Name>/` is a full package: `Project.toml`
      (name/uuid/version/authors/`[deps]`/`[compat]`/`[extras]`/`[targets]`, plus
      `[sources]` for in-repo deps), `src/`, `test/`, `LICENSE.md`, component
      `README.md`.
- [ ] `[sources]` graph preserves true direction, has no missing-`[deps]` entry,
      and no root→leaf cycle.
- [ ] Each group has its own `test/<Group>/` folder; dep-adding groups carry an
      isolated `test/<Group>/Project.toml` (with `[sources]` `pkg={path="../.."}`
      + extra deps + `Test`) and are excluded from `All`; QA in `test/qa`.
- [ ] No top-level `test/Project.toml`.
- [ ] Group names capitalized/Title-case; one shared `<REPO>_TEST_GROUP` env var
      read by every `runtests.jl`; default `All`; never
      `lowercase(get(ENV, ...))`.
- [ ] Root `runtests.jl` dispatches sublibrary groups (`_detect_sublibrary_group`).
- [ ] `test_groups.toml` per sublibrary: Core `["lts","1.11","1","pre"]`,
      QA `["1"]`, GPU `["1"]` + self-hosted GPU runner. No `GPU.yml`.
- [ ] Workflows are thin `@v1` callers with `secrets: "inherit"`:
      `SublibraryCI` (`group-env-name`, `check-bounds: auto`),
      `DowngradeSublibraries`, `CI` (group-dispatched), `Downgrade`,
      `Documentation`, `Downstream`, `FormatCheck`/`RunicSuggestions`,
      `SpellCheck`, `TagBot` (root + `TagBot-Subpackages` matrix with
      `subdir: lib/<pkg>`), `DependabotAutoMerge`, `DocPreviewCleanup`,
      `benchmark`.
- [ ] Repo files: `.codecov.yml` (`comment: false`), `.typos.toml`,
      `.gitignore`, per-package `LICENSE.md`.
- [ ] Runic formatting (Catalyst/JumpProcesses excepted). No CompatHelper, no
      Invalidations.
