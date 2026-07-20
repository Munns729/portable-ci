# Contributing to portable-ci

portable-ci dogfoods itself: the same checks CI runs are the ones you run
locally. Run them before you push and CI failure emails simply stop happening —
a broken commit is caught on your machine, not after it reaches GitHub Actions.

## Run the checks

From the repo root:

```bash
./bin/ci run
```

This runs the project's `.localci` — `shellcheck` on the scripts (if installed)
and the self-test suite (`test/run-tests.sh`) — exactly as the GitHub Actions
workflow does. A non-zero exit means CI would fail too.

`shellcheck` is required for the lint step to run; install it first:

```bash
# Debian/Ubuntu
sudo apt-get install -y shellcheck
# macOS
brew install shellcheck
```

## Gate every push automatically

Install the pre-push hook once, and `ci run` runs before every `git push`,
blocking the push if any check fails:

```bash
./bin/ci install-hook pre-push
```

That's the whole point of the tool: the local run and the CI run can't drift, so
if it's green locally it's green in Actions. The hook only blocks; it never
pushes anything on its own, and it won't clobber an existing unmanaged hook.

## Adding or changing checks

Edit `.localci`. Each `step "name" command...` is one check; any non-zero exit
fails the run. Keep new behaviour covered by a case in `test/run-tests.sh` —
each case runs in a throwaway directory, so there's no cross-test state.

## Changelog and versioning

Add a bullet under **`## [Unreleased]`** in `CHANGELOG.md` — don't invent a
version number in your PR. `VERSION` in `bin/ci` is bumped once **at release
time**, when `[Unreleased]` is renamed to the new version and the `v1` tag is
re-pointed. This keeps parallel PRs from colliding on the same version slot
(which is exactly what happened when two PRs both claimed `0.4.0`).

## Releasing

A release is what actually ships to consumers — bumping `VERSION` in a merged PR
does **not** reach anyone on its own. Steps, in order:

1. **Pick the version.** Semantic-ish: new behaviour → minor (`0.4.0` → `0.5.0`);
   fixes only → patch. Consumers read `VERSION` (via `ci --version`, `min_version`,
   and `ci doctor`'s staleness check), so it must be truthful.
2. **Promote the changelog.** Rename `## [Unreleased]` to `## X.Y.Z — <date>` and
   add a fresh empty `## [Unreleased]` above it.
3. **Bump `VERSION`** in `bin/ci` to match. (Steps 2–3 can ride along in the last
   feature PR of the release, or land as their own release PR.)
4. **Merge to `main`.**
5. **Cut the `vX.Y.Z` GitHub release** at `main` HEAD. This creates the immovable
   `vX.Y.Z` tag (for consumers who SHA/version-pin) and is what `ci doctor`'s
   staleness check reads (`releases/latest`) to nudge stale installs.
6. **Re-point `v1`.** Run the **Move major tag** workflow (Actions tab →
   `workflow_dispatch`, or `.github/workflows/move-tag.yml`) with `tag: v1` and a
   blank SHA (defaults to `main` HEAD). This is the step that ships to everyone
   tracking the moving major tag — the composite action (`uses: …@v1`) and
   `install.sh`. Nothing propagates until `v1` moves.

**What reaches whom after `v1` moves:** Actions consumers pinned `@v1` pick it up
automatically on their next run; anyone who copied `bin/ci` via `install.sh` does
**not** auto-update (re-run `install.sh`; `ci doctor` flags the staleness);
anyone pinned to a commit SHA or `@vX.Y.Z` stays put by design.
