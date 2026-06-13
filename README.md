# SciML `.github`

Organization-wide community-health files **and** the shared, reusable GitHub
Actions CI system used across the SciML ecosystem.

Two things live here:

1. **Default community-health files** (issue templates, etc.) that GitHub
   applies to every SciML repo that doesn't define its own. See
   [GitHub's docs on default community health files](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file).
2. **Reusable workflows** under [`.github/workflows/`](.github/workflows) —
   the topic of the rest of this document. Instead of every package copy-pasting
   the same `CI.yml`, `Documentation.yml`, etc., each package calls a shared
   workflow with a few lines. Fixes and improvements land here once and every
   consumer picks them up.

---

## Table of contents

- [How it works](#how-it-works)
- [Versioning: the `@v1` moving tag](#versioning-the-v1-moving-tag)
- [Quick start](#quick-start)
- [Workflow reference](#workflow-reference)
  - [`tests.yml`](#testsyml) · [`downstream.yml`](#downstreamyml) ·
    [`downgrade.yml`](#downgradeyml) · [`documentation.yml`](#documentationyml) ·
    [`runic.yml`](#runicyml) · [`format-check.yml` / `format-suggestions-on-pr.yml`](#format-checkyml--format-suggestions-on-pryml) ·
    [`spellcheck.yml`](#spellcheckyml) · [`benchmark.yml`](#benchmarkyml) ·
    [`tagbot.yml`](#tagbotyml) · [`dependabot-automerge.yml`](#dependabot-automergeyml) ·
    [`docs-preview-cleanup.yml`](#docs-preview-cleanupyml) ·
    [`major-version-tag.yml`](#major-version-tagyml)
- [Monorepos: sublibrary CI](#monorepos-sublibrary-ci)
  - [Monorepo structure](#monorepo-structure) — full layout spec in [Monorepo.md](Monorepo.md)
  - [How sublibrary tests run](#how-sublibrary-tests-run)
  - [`test_groups.toml`](#test_groupstoml)
  - [`grouped-tests.yml` (root matrix)](#grouped-testsyml--declare-the-root-test-matrix-in-test_groupstoml)
  - [Dependency-graph change detection](#dependency-graph-change-detection)
  - [`sublibrary-project-tests.yml`](#sublibrary-project-testsyml)
  - [`sublibrary-downgrade.yml`](#sublibrary-downgradeyml)
- [Recommended repository setup](#recommended-repository-setup)
- [Secrets](#secrets)
- [Full examples](#full-examples)
- [Releasing changes to these workflows](#releasing-changes-to-these-workflows)
- [Sources](#sources)

---

## How it works

A package's workflow becomes a thin **caller** that delegates to a **reusable
workflow** here via [`uses:`](https://docs.github.com/en/actions/using-workflows/reusing-workflows).
The caller supplies its own triggers (`on:`) and concurrency; the reusable
workflow does the work.

```yaml
# .github/workflows/CI.yml in a consuming repo
name: CI
on:
  pull_request:
    branches: [master]
  push:
    branches: [master]

jobs:
  test:
    uses: "SciML/.github/.github/workflows/tests.yml@v1"
    secrets: "inherit"
```

Notes that apply to **every** caller:

- **`secrets: "inherit"`** forwards the calling repo's secrets (e.g.
  `CODECOV_TOKEN`, `DOCUMENTER_KEY`) to the reusable workflow. Without it,
  coverage upload and docs deploy can't authenticate. `inherit` does **not**
  propagate across *nested* reusable-workflow calls — each level must re-declare
  it.
- **Triggers and `concurrency:` must live in the caller.** Reusable workflows
  can't define their own `push`/`pull_request` triggers.
- Pin with **`@v1`** (see below).

---

## Versioning: the `@v1` moving tag

Consumers pin the **major tag**:

```yaml
uses: "SciML/.github/.github/workflows/tests.yml@v1"
```

`@v1` is a *moving* tag that always points at the latest `v1.x.y` release;
[`major-version-tag.yml`](#major-version-tagyml) advances it automatically when
a `vX.Y.Z` tag is pushed. Repos that want an immutable pin can use `@v1.2.3`.

- **Backward-compatible change** → new `v1.x.y`; `@v1` consumers get it
  automatically.
- **Breaking change** (removing an input, switching a tool) → `v2.0.0`; `@v1`
  consumers are unaffected and opt in by switching to `@v2`.

See [`RELEASING.md`](RELEASING.md) for the full process.

---

## Quick start

A standard (non-monorepo) package typically has these callers. Each is a few
lines:

| Workflow | Reusable workflow | Purpose |
|---|---|---|
| `CI.yml` | `tests.yml@v1` | Run the test suite |
| `Downstream.yml` | `downstream.yml@v1` | Integration-test dependents against this PR |
| `Downgrade.yml` | `downgrade.yml@v1` | Tests with the oldest compatible deps |
| `Documentation.yml` | `documentation.yml@v1` | Build & deploy docs |
| `FormatCheck.yml` | `runic.yml@v1` | Runic format check |
| `SpellCheck.yml` | `spellcheck.yml@v1` | Spell-check with `typos` |
| `TagBot.yml` | `tagbot.yml@v1` | Create releases/tags on registration |
| `DocPreviewCleanup.yml` | `docs-preview-cleanup.yml@v1` | Delete closed-PR doc previews |

Monorepos (a package with `lib/<sublibrary>/` sub-packages) add one more —
[sublibrary CI](#monorepos-sublibrary-ci).

A copy-pasteable starter set is in [Full examples](#full-examples).

---

## Workflow reference

All inputs are optional unless marked **required**. Defaults are shown.

### `tests.yml`

Runs a package's test suite: checkout → setup Julia → cache → build → `Pkg.test`
→ process coverage → upload to Codecov.

It also **transitively develops in-repo `[sources]` path dependencies** of the
tested project. On Julia < 1.11 (where `[sources]` isn't auto-resolved), it
walks the project's `[sources]`, `Pkg.develop`s each in-repo path dep, and
recurses into their `[sources]` too. This is what lets a monorepo sublibrary be
tested via `project: lib/X` without a hand-written develop step.

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version (`setup-julia` spec: `"1"`, `"lts"`, `"1.11"`, `"pre"`, `"nightly"`, …). |
| `julia-arch` | string | runner arch | Architecture of Julia. |
| `project` | string | `"@."` | Value passed to Julia's `--project`. Set to `lib/X` to test a sublibrary. |
| `group` | string | `""` | Test group; exposed to tests via an env var (see `group-env-name`). |
| `group-env-name` | string | `"GROUP"` | Name of the env var the group is set under (e.g. `ODEDIFFEQ_TEST_GROUP`). |
| `num-threads` | string | `"auto"` | `JULIA_NUM_THREADS`. `auto` matches the runner's vCPUs on hosted runners; on self-hosted it falls back to `2` (avoid oversubscribing a large shared box). An explicit integer is always honored. |
| `self-hosted` | boolean | `false` | Run on a self-hosted runner. |
| `os` | string | `"ubuntu-latest"` | Runner OS (ignored when self-hosted). |
| `runner` | string | `""` | JSON-encoded `runs-on` (string or label array, e.g. `'["self-hosted","Linux","X64","gpu"]'`). When non-empty, overrides `self-hosted`/`os`. |
| `container` | string | `""` | Docker container image to run the job in (e.g. `cmhyett/julia-fenics:latest` for Python-stack packages). Empty = no container. |
| `timeout-minutes` | number | `360` | Job timeout. |
| `cache` | boolean | `true` | Use `julia-actions/cache`. |
| `buildpkg` | boolean | `true` | Run `julia-actions/julia-buildpkg`. |
| `coverage` | boolean | `true` | Collect coverage and upload to Codecov. |
| `coverage-directories` | string | `"src,ext"` | Comma-separated dirs `julia-processcoverage` scans (e.g. `lib/X/src,lib/X/ext`). |
| `check-bounds` | string | `"yes"` | `julia-runtest` `check_bounds` (`yes`/`no`/`auto`). |
| `allow-reresolve` | boolean | `true` | `julia-runtest` `allow_reresolve`. |
| `julia-runtest-depwarn` | string | `"yes"` | `--depwarn` flag value. |
| `continue-on-error` | boolean | — | Don't fail the run if the job fails (also auto-true on `nightly`). |

```yaml
jobs:
  test:
    uses: "SciML/.github/.github/workflows/tests.yml@v1"
    secrets: "inherit"
```

With a group matrix:

```yaml
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        group: [Core, InterfaceI, InterfaceII]
        version: ["1", "lts"]
    uses: "SciML/.github/.github/workflows/tests.yml@v1"
    with:
      group: "${{ matrix.group }}"
      julia-version: "${{ matrix.version }}"
    secrets: "inherit"
```

### `downstream.yml`

Integration test: checks out a **downstream** repository that depends on this
package, develops the PR's version into it, and runs the downstream test suite —
catching breakage you'd otherwise only find after release.

| Input | Type | Default | Description |
|---|---|---|---|
| `repo` | string | — **(required)** | Downstream repo name (e.g. `OrdinaryDiffEq.jl`). |
| `owner` | string | `"SciML"` | Owner of the downstream repo. |
| `group` | string | `"All"` | Downstream test group. |
| `julia-version` | string | `"1"` | Julia version. |
| `julia-arch` | string | runner arch | Architecture. |
| `self-hosted` / `os` | | `false` / `ubuntu-latest` | Runner selection. |
| `cache` / `buildpkg` / `coverage` | boolean | `true` | As in `tests.yml`. |
| `julia-runtest-depwarn` | string | `"error"` | `--depwarn` flag value. |
| `continue-on-error` | boolean | — | Don't fail the run if the job fails. |

```yaml
jobs:
  downstream:
    strategy:
      fail-fast: false
      matrix:
        repo: [OrdinaryDiffEq.jl, ModelingToolkit.jl]
    uses: "SciML/.github/.github/workflows/downstream.yml@v1"
    with:
      repo: "${{ matrix.repo }}"
    secrets: "inherit"
```

### `downgrade.yml`

Runs the test suite with **the oldest declared-compatible versions** of every
dependency (via [`julia-actions/julia-downgrade-compat`](https://github.com/julia-actions/julia-downgrade-compat))
to catch under-specified `[compat]` lower bounds.

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"lts"` | Julia version: the LTS alias (currently 1.10), tracking the LTS as it advances (the minimum-supported floor; see note). |
| `group` | string | `""` | Test group. |
| `skip` | string | `""` | **Additional** deps to skip when downgrading, beyond the auto-included Julia stdlibs and any `[sources]` path/url deps (see note). |
| `projects` | string | `"."` | Comma-separated project dirs to downgrade. |
| `project` | string | `"@."` | `--project` for build/test (a workspace submodule or `lib/X`); default tests the repo root. |
| `self-hosted` / `os` | | `false` / `ubuntu-latest` | Runner selection. |

```yaml
jobs:
  downgrade:
    uses: "SciML/.github/.github/workflows/downgrade.yml@v1"
    secrets: "inherit"
```

> Downgrade is **strict**: the reusable workflow hardcodes `allow_reresolve:
> false` and exposes **no `allow-reresolve` input**. The `skip` list is
> **auto-populated** with all Julia stdlibs **and every dep declared in a
> project's `[sources]` table** (path/url deps are satisfied in-tree, not from
> the registry, so they must never be downgrade-pinned), so callers no longer
> hand-list `Pkg,TOML,Statistics,…` or their path deps — pass `skip` only for
> genuinely-extra deps. The caller-facing `julia-version` default is **`"lts"`**,
> the LTS alias (currently 1.10), tracking the LTS as it advances.
> (Auto-skip and the `lts` default land via
> [SciML/.github #73](https://github.com/SciML/.github/pull/73); strict
> `allow_reresolve: false` is already in effect.)

### `documentation.yml`

Builds and deploys [Documenter](https://documenter.juliadocs.org/)
documentation (and runs doctests, with coverage).

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version. |
| `documenter-key` | string | — | `DOCUMENTER_KEY` (ssh deploy key) — usually supplied via `secrets: inherit`. |
| `github-token` | string | — | GitHub token for deploy auth. |
| `debug-documenter` | boolean | `false` | Set `JULIA_DEBUG=Documenter`. |
| `self-hosted` / `os` | | `false` / `ubuntu-latest` | Runner selection. |
| `cache` | boolean | `true` | Use the Julia cache. |
| `coverage` | boolean | `true` | Collect doctest coverage. |
| `coverage-directories` | string | `"src,ext"` | Coverage dirs. |
| `continue-on-error` | boolean | — | Don't fail the run if the job fails. |

```yaml
jobs:
  docs:
    uses: "SciML/.github/.github/workflows/documentation.yml@v1"
    secrets: "inherit"
```

### `runic.yml`

Checks formatting with [Runic](https://github.com/fredrikekre/Runic.jl) — the
SciML standard formatter. Fails if any tracked file isn't Runic-formatted.

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version. |
| `runic-version` | string | `"1"` | Runic version. |
| `exclude` | string | `""` | Space-separated paths to drop from the git index before the check (e.g. vendored/legacy files Runic can't parse). The working tree and history are untouched. |

```yaml
jobs:
  runic:
    uses: "SciML/.github/.github/workflows/runic.yml@v1"
    secrets: "inherit"
```

> **Runic exemptions (do not roll Runic out to these):** **JumpProcesses.jl**
> and **Catalyst.jl** are exempt from Runic at the maintainer's (Sam Isaacson)
> request — they stay on their own JuliaFormatter (`Format`) setup. Don't add
> `runic.yml` to these repos or reformat them with Runic.

### `format-check.yml` / `format-suggestions-on-pr.yml`

[JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl)-based
alternatives, for repos not yet on Runic. `format-check.yml` fails on
misformatted files; `format-suggestions-on-pr.yml` posts formatting suggestions as PR
comments. Inputs: `directory` (`"."`), `julia-version` (`"1"`),
`juliaformatter-version` (`"2"`), `concurrent-jobs` (`false`),
`cancel-in-progress` (`true`). **New repos should prefer `runic.yml`.**

### `spellcheck.yml`

Spell-checks the repo with [`crate-ci/typos`](https://github.com/crate-ci/typos).
No inputs.

```yaml
jobs:
  spellcheck:
    uses: "SciML/.github/.github/workflows/spellcheck.yml@v1"
    secrets: "inherit"
```

> Don't carry a `typos` ignore/version pin in each repo — the shared workflow
> tracks a current `typos`, so you get fixes and dictionary updates centrally.

### `benchmark.yml`

Runs benchmarks (via [AirspeedVelocity.jl](https://github.com/MilesCranmer/AirspeedVelocity.jl))
and reports results on PRs. Input: `julia-version` (`"1"`).

### `tagbot.yml`

Creates GitHub releases/tags when a package is registered, via
[JuliaRegistries/TagBot](https://github.com/JuliaRegistries/TagBot). Tags one
package — the root, or a monorepo sublibrary when `subdir` is set. The
if-guard (`workflow_dispatch` or `JuliaTagBot` actor) and the permissions block
live in the reusable workflow; the caller keeps the `issue_comment` /
`workflow_dispatch` triggers. `token` and `ssh` (`DOCUMENTER_KEY`) come from
`secrets: inherit`.

| Input | Type | Default | Description |
|---|---|---|---|
| `subdir` | string | `""` | Package subdirectory to tag (e.g. `lib/Foo` for a sublibrary); empty for the root. |
| `lookback` | string | `"3"` | TagBot lookback window in days (manual `workflow_dispatch` runs). |

```yaml
# .github/workflows/TagBot.yml
name: TagBot
on:
  issue_comment:
    types: [created]
  workflow_dispatch:
jobs:
  tagbot:
    uses: "SciML/.github/.github/workflows/tagbot.yml@v1"
    secrets: "inherit"
```

Monorepo (tag the root + each sublibrary):

```yaml
jobs:
  tagbot:
    uses: "SciML/.github/.github/workflows/tagbot.yml@v1"
    secrets: "inherit"
  tagbot-sublibraries:
    strategy:
      fail-fast: false
      matrix:
        package: [lib/Foo, lib/Bar]
    uses: "SciML/.github/.github/workflows/tagbot.yml@v1"
    with:
      subdir: "${{ matrix.package }}"
    secrets: "inherit"
```

### `dependabot-automerge.yml`

Auto-approves Dependabot PRs matching the configured update types / ecosystems,
then merges **only after every status check on the PR head has completed _and_
passed** — not just the checks branch protection happens to mark *required*.

This is deliberately stricter than a bare `gh pr merge --auto`. Native
auto-merge waits only on *required* checks and merges immediately if a repo has
none configured (or its required set is stale / misconfigured), which can
fast-track a still-running or red PR. This workflow instead polls **all** checks that
actually ran on the head commit, so the gate holds regardless of branch
protection config. If any check fails, no checks are present, or the wait times
out, the PR is left for a human with an explanatory comment (the job still
succeeds — holding is a valid outcome, not a failure). No repo-level "auto-merge
enabled" setting is required.

| Input | Type | Default | Description |
|---|---|---|---|
| `update-types` | string | `"version-update:semver-patch,version-update:semver-minor"` | Dependabot update types to auto-merge. |
| `ecosystems` | string | `""` | Comma-separated `package-ecosystem`s to restrict to (e.g. `github-actions`); empty = any. |
| `merge-method` | string | `"squash"` | `squash`, `merge`, or `rebase`. |
| `wait-timeout-minutes` | number | `720` | Max minutes to wait for all checks to finish before holding the PR for a human. The job exits as soon as checks finish — this is only the give-up cap for stuck CI, so it's generous (12h) for heavy suites. |

```yaml
# .github/workflows/DependabotAutoMerge.yml
name: Dependabot Auto-merge
on: pull_request
permissions:
  contents: write
  pull-requests: write
  checks: read     # only needed on private repos
  statuses: read   # only needed on private repos
jobs:
  automerge:
    uses: "SciML/.github/.github/workflows/dependabot-automerge.yml@v1"
    secrets: "inherit"
```

### `docs-preview-cleanup.yml`

Deletes a closed PR's [Documenter](https://documenter.juliadocs.org/) preview
from the docs branch and squashes that branch's history to one commit so it
doesn't grow unbounded ([Documenter's `DocPreviewCleanup`](https://documenter.juliadocs.org/stable/man/hosting/)).

| Input | Type | Default | Description |
|---|---|---|---|
| `preview-branch` | string | `"gh-pages"` | Branch the docs/previews live on. |
| `preview-dir-root` | string | `"previews"` | Per-PR preview is `<root>/PR<number>`. |

```yaml
# .github/workflows/DocPreviewCleanup.yml
name: Doc Preview Cleanup
on:
  pull_request:
    types: [closed]
permissions:
  contents: write
jobs:
  cleanup:
    uses: "SciML/.github/.github/workflows/docs-preview-cleanup.yml@v1"
    secrets: "inherit"
```

### `major-version-tag.yml`

The release-plumbing workflow that lives here and runs **on this repo** (not a
`workflow_call` consumer). On a `vX.Y.Z` tag push it force-moves the floating
`vX` tag to that commit, so `@vX` consumers track the latest `vX.Y.Z`. See
[Releasing](#releasing-changes-to-these-workflows).

---

## Monorepos: sublibrary CI

A SciML *monorepo* is a package with sub-packages under `lib/<name>/`, each with
its own `Project.toml` and `test/runtests.jl` (e.g. OrdinaryDiffEq,
ModelingToolkit, Optimization, NonlinearSolve). Sublibrary CI runs each
sublibrary's tests, and — crucially — only the ones a change actually affects.

### Monorepo structure

The full canonical layout — umbrella root + `lib/<Name>` packages, the
`[sources]` dependency graph, the one-group-one-folder test structure with
dependency-driven per-group `Project.toml`s, group naming and the
`<REPO>_TEST_GROUP` env var, `test_groups.toml`, the thin `@v1` workflow set, and
the standard repo files — is specified in **[Monorepo.md](Monorepo.md)**, the
reference for setting up a new monorepo. The reference implementation is
[SciML/OrdinaryDiffEq.jl](https://github.com/SciML/OrdinaryDiffEq.jl). The
remainder of this section is the CI-mechanics summary.

### How sublibrary tests run

`sublibrary-project-tests.yml` computes the **affected** sublibraries (see
[change detection](#dependency-graph-change-detection)) and runs each via
`tests.yml` with `project: lib/X` — i.e. `lib/X/test/runtests.jl` directly,
with the test group passed through `group-env-name`. It needs no per-repo root
`runtests.jl` dispatcher, because `tests.yml` transitively develops the
sublibrary's in-repo `[sources]`. Per-sublibrary versions / runners / timeouts
come from each sublib's `test_groups.toml` (below).

### `test_groups.toml`

The same file format declares test groups in **two** places:

- **`lib/<name>/test/test_groups.toml`** — a sublibrary's groups, expanded by
  the (diff-filtered) sublibrary CI below.
- **`test/test_groups.toml`** (repo root) — the **root** package's own groups,
  expanded by [`grouped-tests.yml`](#grouped-testsyml) so the root `CI.yml` is a
  thin caller instead of a hand-maintained matrix. Works for non-monorepos too.

A sublibrary file looks like:

```toml
[Core]
versions = ["lts", "1", "pre"]

[GPU]
versions = ["1"]
runner = ["self-hosted", "Linux", "X64", "gpu"]
timeout = 60

[QA]
versions = ["lts", "1"]
```

Per-group fields:

| Field | Default | Meaning |
|---|---|---|
| `versions` | — | Julia versions to run this group on. |
| `runner` | `"ubuntu-latest"` | `runs-on` string or label array (e.g. a GPU self-hosted runner). |
| `os` | — | *(Root matrix only.)* Array of OS runners for an **OS matrix** — the group runs once per OS (e.g. `["ubuntu-latest","windows-latest","macos-latest"]`), each cell's `runs-on` being that OS. Empty → use `runner`. Don't combine with a custom `runner`; if both are set, the OS axis wins. |
| `timeout` | `120` | Job timeout in minutes. |
| `num_threads` | `1` | `JULIA_NUM_THREADS`. |
| `local_only` | `false` | When `true`, skip this group if the sublibrary is in the matrix only because an upstream dependency changed (not its own files). For groups too expensive to run on every transitive rebuild. *(Sublibrary matrix only; not meaningful at the root.)* |
| `continue_on_error` | `false` | When `true`, a failing job in this group doesn't fail the run (maps to `tests.yml`'s `continue-on-error`). Used for non-fatal root groups such as OrdinaryDiffEq's `Downstream`. |

**Default when there's no `test_groups.toml`:** for a sublibrary, `Core` on
`["lts","1","pre"]` + `QA` on `["lts","1"]`; for the **root** matrix
(`grouped-tests.yml`), a single `Core` group (the whole suite) on
`["lts","1","pre"]`. (See [Monorepo.md](Monorepo.md#5-test_groupstoml) for the
version-set rollout.)

The group name reaches the sublibrary's `runtests.jl` through an env var. In the
project model that var is `group-env-name` (default `GROUP`; OrdinaryDiffEq uses
`ODEDIFFEQ_TEST_GROUP`). A sublibrary's `runtests.jl` typically does:

```julia
const GROUP = get(ENV, "GROUP", "All")
if GROUP == "All" || GROUP == "Core"
    # functional tests
end
if GROUP == "All" || GROUP == "QA"
    # Aqua / JET / allocation tests
end
```

### `grouped-tests.yml` — declare the root test matrix in `test_groups.toml`

A package's **root** test groups can be declared once in a root
`test/test_groups.toml` and run via `grouped-tests.yml`, instead of
hand-maintaining a `group × version` matrix in each repo's `CI.yml`. The root
`CI.yml` becomes a thin caller:

```yaml
# .github/workflows/CI.yml
name: CI
on:
  pull_request:
    branches: [master]
    paths-ignore: ['docs/**']
  push:
    branches: [master]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ startsWith(github.ref, 'refs/pull/') }}
jobs:
  tests:
    uses: "SciML/.github/.github/workflows/grouped-tests.yml@v1"
    secrets: "inherit"
```

and `test/test_groups.toml` carries the matrix (per-group `versions` express
what would otherwise be a base matrix plus `exclude:`/`include:` rows):

```toml
[InterfaceI]
versions = ["lts", "1", "pre"]

[AD]
versions = ["lts"]                              # this group only on lts

[QA]
versions = ["lts", "1"]

[Downstream]
versions = ["lts", "1", "pre"]
continue_on_error = true                        # non-fatal group

[GPU]
versions = ["1"]
runner = ["self-hosted", "Linux", "X64", "gpu"]

[Core]
versions = ["lts", "1"]
os = ["ubuntu-latest", "windows-latest", "macos-latest"]   # OS matrix: runs once per OS
```

`grouped-tests.yml` runs `compute_affected_sublibraries.jl --root-matrix` to
turn that into the job matrix, then runs each `group × version × os` cell via
`tests.yml` (`project: '.'`), dispatching the group through `group-env-name`
(default `GROUP`) — the same env var the package's `runtests.jl` already reads.
Unlike the per-sublibrary matrix it is **not** diff-filtered: the root package
runs all of its groups on every push/PR.

**Not monorepo-only.** Any single package can adopt it: with no
`test/test_groups.toml` the default is a single `Core` group (the whole suite)
on `["lts","1","pre"]`, so a non-monorepo gets the standard version matrix from
a near-zero-line `CI.yml`, and can split into groups later.

| Input | Type | Default | Description |
|---|---|---|---|
| `group-env-name` | string | `"GROUP"` | Env var the package's `runtests.jl` reads its group from (OrdinaryDiffEq uses `ODEDIFFEQ_TEST_GROUP`). |
| `check-bounds` | string | `"yes"` | `julia-runtest` `check_bounds` per group. |
| `allow-reresolve` | boolean | `true` | `julia-runtest` `allow_reresolve`. |
| `coverage` | boolean | `true` | Collect & upload coverage. |
| `coverage-directories` | string | `"src,ext"` | Coverage dirs. |
| `apt-packages` | string | `""` | System packages to install (Linux). |
| `container` | string | `""` | Docker container image each test job runs in (e.g. `cmhyett/julia-fenics:latest`). Empty = no container. |
| `dotgithub-ref` | string | `"v1"` | Ref of `SciML/.github` to source the matrix script from. |

> A monorepo therefore has **two** test workflows: `grouped-tests.yml` for the
> root package's own groups, and `sublibrary-project-tests.yml` for the
> (incremental) `lib/<name>` sublibraries.

### Dependency-graph change detection

[`scripts/compute_affected_sublibraries.jl`](scripts/compute_affected_sublibraries.jl)
reads the inter-sublibrary dependency graph from each `lib/*/Project.toml`
`[deps]` (test-only `[extras]`/`[targets]` deps do **not** propagate), then given
the changed files:

- A changed sublibrary is **directly affected** (full version matrix).
- Sublibraries that (transitively) depend on it are **downstream-affected** and
  run on the latest stable (`"1"`) only.
- Changes confined to a sublibrary's `test/` don't propagate to dependents.
- Changes outside `lib/` select nothing (the root suite is covered by `CI.yml`).

The script's output modes:

| Invocation | Output | Used by |
|---|---|---|
| `… <repo> --projects-matrix` | `[{project, group, version, runner, timeout, num_threads}, …]` | `sublibrary-project-tests.yml` |
| `… <repo> --projects` | `["lib/A", "lib/B", …]` | simple path listing |
| `… <repo> --root-matrix` | `[{group, version, runner, timeout, num_threads, continue_on_error}, …]` from the **root** `test/test_groups.toml` (no diff filter, no `lib/` required) | `grouped-tests.yml` |

### `sublibrary-project-tests.yml`

Lists the affected `lib/*` (with change detection) and runs each via
`tests.yml` `project: lib/X`, expanding `test_groups.toml`. No root dispatcher
needed.

| Input | Type | Default | Description |
|---|---|---|---|
| `coverage` | boolean | `true` | Collect per-sublibrary coverage (pointed at `lib/<name>/src,ext`). |
| `group-env-name` | string | `"GROUP"` | Env var the sublibrary's `runtests.jl` reads its group from. |
| `check-bounds` | string | `"yes"` | `julia-runtest` `check_bounds` for each sublibrary. |
| `allow-reresolve` | boolean | `true` | `julia-runtest` `allow_reresolve`. |
| `test-all` | boolean | `false` | Test every sublibrary (full matrix) regardless of the diff. |
| `dotgithub-ref` | string | `"v1"` | Ref of `SciML/.github` to source the detection script from. |

```yaml
jobs:
  sublibrary-ci:
    uses: "SciML/.github/.github/workflows/sublibrary-project-tests.yml@v1"
    secrets: "inherit"
```

OrdinaryDiffEq-style caller (custom group env + bounds checking):

```yaml
jobs:
  sublibrary-ci:
    uses: "SciML/.github/.github/workflows/sublibrary-project-tests.yml@v1"
    with:
      group-env-name: ODEDIFFEQ_TEST_GROUP
      check-bounds: auto
    secrets: "inherit"
```

### `sublibrary-downgrade.yml`

Downgrade-compat tests for each `lib/*` sublibrary.

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"lts"` | Julia version: the LTS alias (currently 1.10), tracking the LTS as it advances (the minimum-supported floor; see note). |
| `skip` | string | `""` | **Additional** deps to skip when downgrading, beyond the auto-included Julia stdlibs, in-repo `lib/*` sublibrary names, and the sublibrary's own `[sources]` path/url deps (see note). |
| `projects` | string | `""` | Explicit space-separated `lib/*` paths; empty = auto-discover all. |
| `exclude` | string | `""` | Space-separated sublibrary names to exclude from auto-discovery. |
| `group-env-name` | string | `""` | Optional group env var name (e.g. `ODEDIFFEQ_TEST_GROUP`). |
| `group-env-value` | string | `""` | Value for `group-env-name`. |

```yaml
jobs:
  downgrade-sublibraries:
    uses: "SciML/.github/.github/workflows/sublibrary-downgrade.yml@v1"
    secrets: "inherit"
```

> Downgrade is **strict**: the reusable workflow hardcodes `allow_reresolve:
> false` and exposes **no `allow-reresolve` input**. The `skip` list is
> **auto-populated** with all Julia stdlibs, the in-repo `lib/*` sublibrary
> names, **and every dep declared in the downgraded sublibrary's `[sources]`
> table** (path/url packages are satisfied in-tree, not from the registry, so
> they must never be downgrade-pinned), so callers no longer hand-list them —
> pass `skip` only for genuinely-extra deps. The caller-facing `julia-version`
> default is **`"lts"`**, the LTS alias (currently 1.10), tracking the LTS as it
> advances.
> (Auto-skip and the `lts` default land via
> [SciML/.github #73](https://github.com/SciML/.github/pull/73); strict
> `allow_reresolve: false` is already in effect.)

---

## Recommended repository setup

- **Use `secrets: "inherit"`** on every caller.
- **Dependabot** for GitHub Actions (keeps `actions/checkout` etc. current).
  Don't carry a per-repo `crate-ci/typos` ignore — the shared `spellcheck.yml`
  manages `typos` centrally. Only include a Julia `package-ecosystem` block for
  directories that actually contain a `Project.toml`.
- **No `CompatHelper.yml`.** `[compat]` bumps come from Dependabot's Julia
  ecosystem support; CompatHelper is retired in this system.
- **Coverage:** add `CODECOV_TOKEN` (see below) and leave `coverage: true`.
- **Formatting:** prefer `runic.yml`.

---

## Secrets

Forwarded via `secrets: "inherit"`. Set these in the consuming repo (or org):

| Secret | Needed by | Purpose |
|---|---|---|
| `CODECOV_TOKEN` | `tests.yml`, `sublibrary-*` | Authenticated coverage upload to [Codecov](https://about.codecov.io/). |
| `DOCUMENTER_KEY` | `documentation.yml` | SSH deploy key for publishing docs (see [Documenter's hosting guide](https://documenter.juliadocs.org/stable/man/hosting/)). |
| `GITHUB_TOKEN` | several | Provided automatically by Actions; forwarded for cache/deploy auth. |

---

## Full examples

### Standard package

`.github/workflows/CI.yml`:

```yaml
name: CI
on:
  pull_request:
    branches: [master]
    paths-ignore: ['docs/**']
  push:
    branches: [master]
    paths-ignore: ['docs/**']
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ startsWith(github.ref, 'refs/pull/') }}
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        version: ["1", "lts"]
    uses: "SciML/.github/.github/workflows/tests.yml@v1"
    with:
      julia-version: "${{ matrix.version }}"
    secrets: "inherit"
```

`.github/workflows/Downgrade.yml`, `Documentation.yml`, `FormatCheck.yml`
(`runic.yml`), `SpellCheck.yml`, `Downstream.yml` follow the one-job pattern
shown in each workflow's section above.

### Monorepo sublibrary CI

`.github/workflows/SublibraryCI.yml`:

```yaml
name: Sublibrary CI
on:
  pull_request:
    branches: [master]
    paths-ignore: ['docs/**']
  push:
    branches: [master]
    paths-ignore: ['docs/**']
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ startsWith(github.ref, 'refs/pull/') }}
jobs:
  sublibrary-ci:
    uses: "SciML/.github/.github/workflows/sublibrary-project-tests.yml@v1"
    secrets: "inherit"
```

`.github/workflows/DowngradeSublibraries.yml`:

```yaml
name: Downgrade Sublibraries
on:
  pull_request:
    branches: [master]
    paths-ignore: ['docs/**']
  push:
    branches: [master]
    paths-ignore: ['docs/**']
jobs:
  downgrade-sublibraries:
    uses: "SciML/.github/.github/workflows/sublibrary-downgrade.yml@v1"
    secrets: "inherit"
```

---

## Releasing changes to these workflows

Merge to `master`, then tag a semver release; `major-version-tag.yml` moves
`@v1` for you (or run it manually via `workflow_dispatch` if a tag-push run
doesn't fire). Full process in [`RELEASING.md`](RELEASING.md). Breaking changes
get a new major (`v2.0.0`) so `@v1` consumers aren't disrupted.

This repo has its own CI (`ci.yml`): [`actionlint`](https://github.com/rhysd/actionlint)
(which bundles `shellcheck`) lints every workflow and the shell in their `run:`
steps, and a Julia test suite (`test/runtests.jl`) covers
`scripts/compute_affected_sublibraries.jl` (the sublibrary affected-set
detection). Keep both green when changing workflows or the script — they ship
to the whole org via `@v1`.

---

## Sources

- [GitHub: Reusing workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- [GitHub: Default community health files](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)
- [`julia-actions`](https://github.com/julia-actions) —
  [`setup-julia`](https://github.com/julia-actions/setup-julia),
  [`cache`](https://github.com/julia-actions/cache),
  [`julia-buildpkg`](https://github.com/julia-actions/julia-buildpkg),
  [`julia-runtest`](https://github.com/julia-actions/julia-runtest),
  [`julia-processcoverage`](https://github.com/julia-actions/julia-processcoverage),
  [`julia-downgrade-compat`](https://github.com/julia-actions/julia-downgrade-compat)
- [Runic.jl](https://github.com/fredrikekre/Runic.jl) ·
  [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl)
- [crate-ci/typos](https://github.com/crate-ci/typos) ·
  [Documenter.jl](https://documenter.juliadocs.org/) ·
  [AirspeedVelocity.jl](https://github.com/MilesCranmer/AirspeedVelocity.jl) ·
  [Codecov](https://about.codecov.io/)
- [Pkg `[sources]`](https://pkgdocs.julialang.org/v1/toml-files/#The-%5Bsources%5D-section)
