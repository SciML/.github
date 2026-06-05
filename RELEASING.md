# Releasing the SciML reusable workflows

Consumers pin the **major tag** of the reusable workflows, e.g.:

```yaml
uses: "SciML/.github/.github/workflows/tests.yml@v1"
```

`@v1` is a *moving tag* that always points at the latest `v1.x.y` release.
Repos that want to pin exactly can use `@v1.2.3` (immutable).

## Cutting a release

1. Land the changes on `master` as usual (PRs).
2. Tag the release commit with the next semver tag and push it:

   ```bash
   git checkout master && git pull
   git tag -a v1.3.0 -m "v1.3.0"
   git push origin v1.3.0
   ```

   (Or publish a GitHub Release with that tag.)
3. The `Maintain major version tag` workflow automatically moves `v1` to the
   new release commit. Nothing else to do — every `@v1` consumer now gets it.

   **If `v1` didn't move** (e.g. the tag-push run was stuck/failed), run the
   workflow manually: Actions → "Maintain major version tag" → "Run workflow",
   optionally passing the release tag (defaults to the latest `vX.Y.Z`). It
   re-points `vX` at that release. You can also do it by hand:

   ```bash
   git fetch --tags
   git tag -f v1 "$(git rev-list -n1 v1.3.0)"
   git push -f origin refs/tags/v1
   ```

- **Bug/feature, backward compatible:** bump patch/minor (`v1.x.y`); `v1` moves.
- **Breaking change** (e.g. dropping an input, switching the formatter): tag
  `v2.0.0`. `@v1` consumers are unaffected; they opt in by changing to `@v2`
  when ready. Keep moving `v1` for `v1.x` backports if needed.

This replaces the old `master` -> `v1` *branch* promotion: there is no longer
a `v1` branch, and no per-change promotion PR. Just merge to `master` and tag
when you want consumers to pick the change up.

## One-time migration (admin)

The repo is moving from a floating `v1` **branch** to tags. A maintainer with
push access runs once (when `v1` branch == `master`):

```bash
git fetch origin
# tag the current release state (master, which equals the v1 branch today):
git tag -a v1.0.0 origin/master -m "v1.0.0 — first tagged release"
git tag v1 origin/master
git push origin refs/tags/v1.0.0 refs/tags/v1
# now retire the v1 BRANCH so @v1 resolves to the tag (do this AFTER the tags exist):
git push origin --delete refs/heads/v1
```

`@v1` consumers are unaffected: the `v1` tag points at the same commit the
`v1` branch did.
