# Changelog

Notable changes to portable-ci. The version in `bin/ci` is the only signal a
consumer has that their install is behind — `install.sh` installs once from the
moving `v1` tag and nothing re-checks afterwards. **Bump it on every release
that changes behaviour.**

## 0.3.0 — 2026-07-20

### Added

- **`min_version X.Y.Z`** — a `.localci` can declare the minimum portable-ci it
  needs. An older `ci` stops with an actionable message naming the required and
  actual versions plus the update command, and exits **2** ("couldn't
  determine" — the run produced no verdict) rather than 1.

  Motivation: 0.2.0 made the version string truthful, but a consumer on an old
  install still got `step_soft: command not found`, which names neither cause
  nor fix. `min_version` converts that into a diagnosis.

  A malformed or missing argument **fails**; it never silently passes. A config
  asking for `min_version latest` that quietly succeeded would assert a
  guarantee it never checked.

  **Honest limit:** an install older than `min_version` itself fails with
  `min_version: command not found` — it cannot know what the line means. This
  bounds the problem going forward; it cannot reach installs that already
  exist. `.localci.example` documents a portable guard idiom that works on any
  version, including 0.1.0.

### Fixed

- Version comparison is numeric per field and parses each side independently.
  The first implementation split both versions in a single `set -- $1 "|" $2`
  and read the right-hand fields from fixed positions, which shifts when the
  left side has fewer than three fields: `1` vs `2.0.0` compared the wrong
  operand. `2` vs `1.0.0` returned the right answer for the wrong reason, so a
  happy-path check would have missed it. Caught by a comparison table
  (`test/run-tests.sh` #43), not by a smoke test.

## 0.2.0 — 2026-07-20

Everything below shipped between the 0.1.0 commit and now while the version
string stayed at `0.1.0`. That is the headline defect this release fixes: an
install predating these features reported the *same version* as one containing
them, so no staleness check was possible even in principle.

### Added

- **`step_soft NAME COMMAND...`** — advisory steps. Reported in the run output
  and in a published status *description*, but never fail the run or flip a
  status to failure. Intended for non-deterministic checks (an LLM adversarial
  review gives different output each run). See
  `examples/adversarial-review.localci`.
- **`ci quota [--repo OWNER/REPO]`** — remaining GitHub Actions minutes as a
  real subcommand, with composable exit codes: `0` quota available, `1`
  exhausted, `2` couldn't determine. Replaces hand-rolled
  `gh api .../settings/billing/actions` calls, which silently return nothing
  when the token lacks billing-read scope.
- **Attestation record** — every run ends with a SHA-stamped line recording
  what was verified at which commit.
- **`--config` guard**, `PORTABLE_CI_REPO` / `--repo` override for status
  publishing, and `ci resolve-repo` / `ci resolve-context` introspection.
- **Install trust** — one-file install, pinned URLs, checksum verification,
  `--dry-run`.
- **`ci doctor` interpreter-split warning** — flags a configured tool resolving
  to a different Python than the one running the step.
- **Install staleness check (new in this release)** — `ci doctor` compares the
  running version against the latest published release and prints the update
  command if they differ. Advisory, network-optional, silent without `gh`, and
  never fails doctor.
- **Moving-tag workflow** — `.github/workflows/move-tag.yml` re-points `v1`
  from inside GitHub, where the token has `contents:write`.

### Changed

- `.localci` is documented as the pre-Actions default rather than an
  after-the-fact fallback, with a quota preflight.
- Published local statuses use context `portable-ci/local` and a description
  marked "local backup", so a local run can never be mistaken for a hosted
  Actions result. `ci status` reads HEAD's checks back and labels each one.

### Fixed

- **The version string itself.** `VERSION` had not moved since the initial
  commit despite seven feature PRs. A consumer repo hit the consequence on
  2026-07-20: it wrote a `step_soft` config, the installed `ci` errored
  `step_soft: command not found`, and `ci --version` reported `0.1.0` —
  identical to the version that *does* have the feature. Feature-detection
  (`declare -F step_soft`) was the only reliable workaround available to them.

## 0.1.0

Initial release: local + CI runner, composite action, pre-push hook,
changed-files scoping (`--since` / `$CI_CHANGED_FILES`), `ci doctor`, and the
commit-status publisher.
