# Changelog

Notable changes to portable-ci. The version in `bin/ci` is the only signal a
consumer has that their install is behind — `install.sh` installs once from the
moving `v1` tag and nothing re-checks afterwards.

Changes land under **`## [Unreleased]`** as they merge; `VERSION` is bumped once
**at release time**, when `[Unreleased]` is renamed to the new version and `v1`
is re-pointed. That keeps parallel PRs from racing for the same version slot —
a merged change is not yet a release.

## [Unreleased]

Ideas adapted from CircleCI's Chunk (its agent-hook wiring, per-command
timeouts, and `validate --list/--dry-run`), reworked to fit portable-ci's
zero-infra, single-script model — no sidecar, account, or remote environment.

### Added

- **`ci install-hook claude`** — wire `ci run` into an AI coding agent's own
  loop by writing `.claude/settings.json`. Two [Claude Code hooks](https://docs.claude.com/en/docs/claude-code/hooks),
  both running the same `.localci`:
  - `PreToolUse` on `git commit` blocks the agent's commit unless `ci run`
    passes — catching commits the git-layer `pre-commit` hook can't, because the
    agent makes them programmatically.
  - `Stop` (turn end) runs `ci run` when the worktree is dirty, so the agent
    can't hand back unchecked code; a clean tree is skipped.

  A failing check exits **2** so Claude Code actually blocks the action — exit 1
  is only a non-blocking error under the hooks contract. Merges safely: with
  `jq` it folds into an existing settings file without clobbering other hooks and
  idempotently on re-run; without `jq` it creates the file but refuses to touch
  an existing one. `PORTABLE_CI_HOOKS_OFF=1` disables both without editing the
  file.

- **`step_timeout N`** — cap every step declared after it at `N` seconds, so a
  hung check can't hang the whole run. A timed-out hard step fails
  (`✗ test (timed out after 300s)`); an advisory one is reported without gating.
  Needs a `timeout`/`gtimeout` binary; without one the cap is skipped with a
  single warning, never silently. A non-numeric argument exits 2 (no verdict)
  rather than being ignored.

  **Honest limit:** a capped step runs as an external process, so — unlike an
  uncapped step — it can't call a shell function defined in `.localci`. Wrap such
  a step in `bash -c '...'`.

- **`ci run --list` / `--dry-run`** — print the configured steps (with any
  `step_timeout` caps) without executing them. Exits 0 with no side effects — a
  plan, not a verdict, so nothing is published or attested.

## 0.4.0 — 2026-07-20

### Fixed

- **The generated hooks leaked git's hook environment into the checks.**
  Git exports `GIT_DIR` / `GIT_WORK_TREE` / `GIT_INDEX_FILE` / `GIT_COMMON_DIR`
  (and `GIT_QUARANTINE_PATH` on push) to hooks. Left set, every `git`
  subprocess a check spawns inherits a repo pointer, which does two bad things:

  1. `git` succeeds even with cwd outside any repository — silently removing
     the precondition of any test asserting "this is not a git repo".
  2. A test running `git add` against what it believes is its own temp repo
     **writes to the real index**. Observed in a consumer on 2026-07-20:
     credential-gate fixtures, including a PEM private key, ended up staged in
     the actual repository. Nothing was committed — but only because that
     repo's own credential gate caught it on the next commit.

  Both generated hooks now unset those variables before running anything.

### Added

- **The pre-push hook derives `--since` from the range actually being pushed.**
  Git feeds pre-push `<local ref> <local sha> <remote ref> <remote sha>` on
  stdin — the one place the pushed range is known unambiguously. The hook
  previously discarded it and ran `ci run` unscoped, so `$CI_CHANGED_FILES` was
  always empty and advisory steps (an LLM review, say) silently no-opped.

  Edge cases, each tested: a new branch (all-zero remote sha) has no baseline
  and runs **unscoped** — the safe direction, since unscoped runs everything;
  a branch deletion (all-zero local sha) is skipped; empty stdin (manual
  invocation) does not hang.

## 0.3.1 — 2026-07-20

### Fixed

- **`install.sh` silently ignored unrecognised arguments.** `bash install.sh
  --dry-run` discarded the flag and performed a real install, while printing a
  `plan:` block that reads exactly like a preview. Dry-run was only ever
  reachable via `PORTABLE_CI_DRY_RUN=1`, and the script had no argument parsing
  at all.

  Anyone reaching for the conventional flag before trusting a `curl | bash` got
  the opposite of what they asked for — which is the wrong failure direction for
  an installer. Found by doing exactly that during a real upgrade.

  `--dry-run` / `-n` and `--help` are now accepted, and **unknown arguments
  abort with exit 2 before anything is changed**. Through a pipe, pass flags
  after `-s --`: `curl -fsSL .../install.sh | bash -s -- --dry-run`.

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
