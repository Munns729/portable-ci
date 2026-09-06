# portable-ci

Run your project's CI checks — lint, typecheck, tests, anything — from **one
config**, both **locally** and in **GitHub Actions**. The same `.localci` file
drives both, so your local run and your CI run can never drift.

Because the runner also works locally, it does things a hosted CI runner can't:
install a pre-push git hook, scope checks to changed files, and publish a commit
status that Claude Code's **CI indicator** reflects — useful when you're out of
GitHub Actions minutes and CI can't run at all.

```console
$ ci run
▶ lint
✓ lint (2s)
▶ test
✓ test (11s)
── portable-ci summary ──
  ✓ lint
  ✓ test
portable-ci: passed
```

## Quick start

```bash
# 1. install — grab the one script the product is, read it, put it on your PATH
curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/v1/bin/ci -o ci
less ci && install -m 0755 ci ~/.local/bin/ci

# 2. scaffold a config for this project (auto-detects your tools)
cd your-project && ci init

# 3. run your checks
ci run
```

That's the whole loop — no clone, one file you can read in full. Everything below
is detail you can reach for later.

## Why

GitHub Actions is a hosted runner: it only tells you the result *after* you push
(and after it spends your minutes). When the minutes run out, CI stops entirely
and every PR shows a red check regardless of whether the code is fine.

portable-ci is the same checks as a **local command**. You get the result before
you push, for free, offline — and you can mirror that result back to GitHub so
tools that read GitHub status (like Claude Code's CI indicator) stay accurate.

The usual answer to "CI is slow or expensive" is a *faster or bigger hosted
runner*. portable-ci takes the other lever — **locality**: the fastest feedback
isn't a quicker remote job, it's not making a remote round-trip at all. Same
checks, on your machine, before the push — no account, no runner fleet, one
script you can read in full.

## Install

portable-ci is a **single self-contained script** (`bin/ci`) with no runtime
dependencies beyond `bash`, `git`, and `curl` (only for `--publish-status`).
That's the whole audit surface — which shapes the simplest way to install it.

### One file, no clone (most auditable)

You don't need the repo. Grab the one script the product *is*, read it in full,
and drop it on your PATH:

```bash
curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/v1/bin/ci -o ci
less ci                                # this file IS the product — nothing else runs
install -m 0755 ci ~/.local/bin/ci     # or anywhere on your PATH
```

Updating is the same three lines. Reading `ci` *is* the audit — there's no
second artifact to trust.

### Installer (manages the symlink + updates)

If you'd rather something handle the PATH symlink and updates for you:

```bash
# read-before-run (recommended):
curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/v1/install.sh -o install.sh
less install.sh && bash install.sh

# unattended:
curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/v1/install.sh | bash
```

It clones to `~/.portable-ci` and links `ci` into the first writable dir on your
PATH (`~/.local/bin`, then `/usr/local/bin`). Override with `PORTABLE_CI_DIR`,
`PORTABLE_CI_BIN`, or `PORTABLE_CI_REF`. Re-run to update. Preview exactly what it
will do without changing anything: `PORTABLE_CI_DRY_RUN=1 bash install.sh`.

Verifying the installer before you pipe it to a shell:

```bash
curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/v1/install.sh | sha256sum
# expected (install.sh @ v1): cfeac88bf18462fe9365c595dfc8cff60e49a3f995ed95976f0df425726ca2da
```

The checksum is regenerated each release (`sha256sum install.sh`); pin
`@<commit-sha>` instead of `@v1` if you want a reference that can never move.

### Developing portable-ci itself

Cloning is for *hacking on* portable-ci — the tests, the action, the examples —
not a prerequisite for using it:

```bash
git clone https://github.com/Munns729/portable-ci && cd portable-ci
./test/run-tests.sh
```

## Configure

The fastest path is `ci init`: it detects your toolchain (Python `ruff`/`mypy`/
`pytest`, Node `lint`/`typecheck`/`test` scripts) and writes a ready-to-run
`.localci` filled in with the tools it found. Review it, tweak the commands, and
you're done — no need to learn the format first.

```console
$ ci init
portable-ci: wrote .localci with 3 detected check(s).
Review it, then run: ci run
```

Prefer to write it yourself? A `.localci` is just a shell fragment where each
`step` is one check (see `.localci.example`):

```sh
step "lint"  ruff check src/
step "types" mypy
step "test"  pytest -q
```

Any non-zero exit fails the run. For compound commands, wrap them in a shell:

```sh
step "build" bash -c "make && make test"
```

`step_timeout N` caps every step declared **after** it at `N` seconds, so a hung
test can't hang the whole run. It's a plain setter, so you can vary it per step:

```sh
step_timeout 30
step "lint" ruff check .
step_timeout 300
step "test" pytest -q          # killed and failed if it runs past 300s
```

A timed-out hard step fails the run (`✗ test (timed out after 300s)`); an
advisory one is reported without gating. It needs a `timeout` binary (coreutils
`timeout`, or `gtimeout` on macOS); without one the cap is skipped with a single
warning, never silently. `step_timeout 0` clears the cap. One caveat: a capped
step runs as an external process, so — unlike an uncapped step — it can't call a
shell function defined in `.localci`; wrap such a step in `bash -c '...'`.

### Path predicates — a docs-only fast path as data

`step_unless_only GLOBS name cmd…` **skips** a step when every changed file
matches one of the space-separated globs; `step_when_only GLOBS name cmd…` runs
a step **only** then. Globs are bash `case` patterns (`*` crosses `/`). The
changed-file set comes from `--since` — which the pre-push hook derives from the
push range, and for a *new* branch from the merge-base with the default branch.

```sh
docs='*.md docs/* wiki/*'
step_unless_only "$docs" "test"        pytest -q                 # skipped on a docs-only diff
step_when_only   "$docs" "docs-guards" pytest tests/test_docs_*.py -q   # runs only then
```

The safe direction is hard-coded: with no scope (no `--since`, not a git repo)
or an empty diff there is nothing to classify, so `unless_only` steps **run**
and `when_only` steps do not — an unscoped run is always the full run.

Only an `unless_only` skip is a **coverage reduction**, and only that is
counted: it is printed, listed in the summary, and **named** in the published
description and the attestation (`· skipped by path predicate: test`), so a
fast-path pass reads as the partial verdict it is — and a code push, whose
`when_only` step simply did not run because the full step covered it, attests
clean. A `when_only` step that does not run is *inert* (printed as `not run`,
never counted), so hosted runs and ordinary pushes are not labelled partial.
Pair every `unless_only` with a `when_only` that runs the reduced checks — a run
in which **every hard step was removed fails** (`✗ every hard step was skipped
by a path predicate — nothing was verified`) rather than posting a green `0/0`.

**Two things to know before relying on it.** (1) Hosted Actions runs `ci run`
with no `--since`, so there `unless_only` steps always run **and `when_only`
steps never do**. Keep every `when_only` check a strict subset of what the
`unless_only` suite already covers; a check that exists *only* behind
`when_only` runs on your machine and nowhere else. (2) Because the pre-push
hook now scopes a **new** branch to its merge-base, a first push's attestation
and status description carry `· scoped to <sha> (partial)` where they used to
be unscoped — the checks that ran are unchanged, only the label is. Tooling that
parses that line should key on `skipped by path predicate:` and the step names
after it, not on `(partial)`.

If there's no `.localci`, portable-ci auto-detects common Python (`ruff` / `mypy`
/ `pytest`) and Node (`npm run lint|typecheck|test`) setups. Autodetect is only a
fallback for the *default* path: an explicit `--config X` (or `PORTABLE_CI_CONFIG`)
that points at a missing file is an error, not a silent fall-through — so a
typo'd path can never quietly run a different set of checks and read as a pass.

### One run at a time (the run lock)

Two `ci run`s overlapping on one machine is the documented way a green suite
turns red for no reason: several pre-push hooks (one per concurrent session or
worktree) each start the full suite and the box runs out of memory — the loser
aborts at N% with **no failed test named** — or one suite reads a working tree
another run is rewriting underneath it. Neither is a check failing, and both
teach `--no-verify`.

So `ci run` takes a lock before its first step, and a later run **waits,
visibly, instead of competing**:

```console
$ ci run
portable-ci: another ci run holds the repo lock (pid 4121 in /work/app since 14:02:11) — waiting, not competing
portable-ci: lock acquired after 38s
▶ test
```

The lock is scoped by `serialize` in `.localci` (before the first `step`):

```sh
serialize repo       # default: one run per repository, shared across its worktrees
serialize machine    # one run per machine, any repository — when the suite is the
                     # resource, not the tree (one 16GB box, three pytest suites)
serialize off        # no lock
serialize repo 600   # optional second arg: seconds to wait before giving up (default 1800)
```

`repo` keys on the git common dir, so a linked worktree and its main checkout
contend for the same lock — the exact pre-push collision. A lock whose holder
has died is reclaimed, never waited on. Past the timeout the run exits `3`
naming the holder, so a wedged lock is a message, not a hang. `--no-lock` on
the command line (or `PORTABLE_CI_LOCK=off`) overrides the file. Inside GitHub
Actions the lock is never taken — the hosted runner is already one job on one
VM, and `concurrency:` groups serialise at the workflow level. Lock files live
under `$PORTABLE_CI_LOCK_DIR`, else `$XDG_RUNTIME_DIR`, else `$TMPDIR`.

## Commands

| Command | What it does |
|---|---|
| `ci init` | Scaffold a `.localci` for this project (auto-detects your tools). Won't clobber an existing config. |
| `ci run` | Run all checks. Exit non-zero if any fails. (default) |
| `ci run --since <ref>` | Also export `$CI_CHANGED_FILES` (files changed vs `<ref>`) so steps can scope to what changed. |
| `ci run --list` / `--dry-run` | Print the configured steps (and any `step_timeout` caps) **without running them** — a plan, not a verdict. Exits 0, no side effects. |
| `ci run --no-lock` | Skip the [run lock](#one-run-at-a-time-the-run-lock) for this invocation. |
| `ci run --publish-status` | After running, publish a GitHub commit status for `HEAD`. |
| `ci doctor` | Report which configured tools are installed (and versions) vs missing. Warns when a deps-sensitive tool (`mypy`, `pytest`, …) resolves to a different Python than your `python3` — the "bare `mypy` vs `python -m mypy`" split that fails cryptically at run time. |
| `ci status` | Read back what GitHub actually has recorded for `HEAD` and label each check **hosted** (Actions/app) vs **local backup** (portable-ci). Warns when only a local backup vouches for the commit. Needs `jq`. |
| `ci quota` | Report remaining GitHub Actions minutes for the repo owner. Exit `1` when exhausted, `2` when it can't be determined — so it composes in scripts and hooks. |
| `ci install-hook [pre-push\|pre-commit\|claude]` | Install a git hook (or **`claude`** agent hooks) that run `ci run` and block on failure. Won't clobber an existing unmanaged hook. See [Agent hooks](#agent-hooks-claude-code). |
| `ci --version` / `ci --help` | Version / usage. |

### Changed-files scoping

```sh
# in .localci
step "lint-changed" bash -c '[ -z "$CI_CHANGED_FILES" ] || ruff check $CI_CHANGED_FILES'
```

```console
$ ci run --since origin/main
3 file(s) changed since origin/main exported as $CI_CHANGED_FILES
```

The pre-push hook passes `--since` automatically: the remote sha of the ref
being pushed, or — when the branch is new upstream — the merge-base with the
default branch, so a first push is scoped the same way its PR diff will be.
`step_unless_only` / `step_when_only` (above) turn that scope into a decision.

### Advisory steps (and adversarial review)

`step_soft` is like `step`, but a failure is **reported, never gating**: it
doesn't fail the run or flip a published status to failure. Use it for
non-deterministic or informational checks — the canonical case being an LLM
**adversarial review**, which shouldn't block a merge on a low-confidence
opinion.

```sh
# in .localci — hard checks gate; the review is advisory
step      "test"   pytest -q
step_soft "review" bash -c '[ -z "$CI_CHANGED_FILES" ] || claude -p "Review: $CI_CHANGED_FILES"'
```

```console
$ ci run --since origin/main
▶ review (advisory)
⚠ review — advisory (exit 1, 0s), not blocking
...
portable-ci: passed
```

Advisory findings surface in the run output and in the published status
**description** (`… · 1 advisory finding(s)`), but never change the pass/fail
state — so a green dot stays honest. `ci doctor` reports a missing advisory tool
as *optional*, not a hard miss. Full recipe: `examples/adversarial-review.localci`.
Sending your diff to an external reviewer is opt-in — it's a step you add.

### Attestation record

Every `ci run` ends with a SHA-stamped, copy-pasteable line stating exactly what
was verified on which commit — the basis you can quote instead of "CI passed":

```console
portable-ci attestation: passed @ 2435475ec167 · 3/3 checks · 1 advisory finding(s)
```

## Your verdict before Actions

The point of portable-ci is that you don't wait on hosted CI to learn whether
your checks pass — you get the verdict **locally, before you push**, so a dead or
quota-exhausted GitHub Actions never sits between you and the answer. Make that
the default, not a fallback:

```bash
ci install-hook pre-push
```

Now `.localci` runs on every `git push` and blocks the push if it fails — the
same checks Actions would run, delivered before Actions is ever in the picture.
`ci init` points you at this the moment you scaffold a config. (Prefer a
lighter touch? Just run `ci run` before pushing; the hook only automates it.)

### Agent hooks (Claude Code)

When an AI coding agent writes the code, the verdict should land inside *its*
loop — before it commits, and before it hands work back — not just at `git push`.
`ci install-hook claude` wires `ci run` into [Claude Code's hooks](https://docs.claude.com/en/docs/claude-code/hooks)
by writing `.claude/settings.json`:

```bash
ci install-hook claude
```

It installs two hooks, both running the **same `.localci`** as everything else:

- **`PreToolUse` on `git commit`** — the agent's commit is blocked unless
  `ci run` passes. The git-layer `pre-commit` hook can't catch a commit the agent
  makes programmatically; this does.
- **`Stop` (turn end) with a dirty worktree** — runs `ci run` when the agent
  finishes a turn with uncommitted changes, so it can't quietly hand back code it
  never checked. A clean worktree is skipped, so a no-op turn costs nothing.

The merge is safe: with `jq` present it merges into an existing
`.claude/settings.json` without clobbering your other hooks and without
duplicating on re-run; without `jq` it creates the file but won't touch an
existing one. `ci` must be on the agent's PATH. Disable both hooks without
editing the file by setting `PORTABLE_CI_HOOKS_OFF=1`.

This is the same "catch failures in the inner loop, before CI" idea as hosted
agent-CI tools — delivered by the one script you already audited, offline, with
no account or remote environment.

### Check Actions quota before you rely on it

On a private repo, exhausted Actions minutes don't fail loudly — jobs "complete"
in ~3 seconds with no logs, which reads like a red X but isn't a real failure.
Before trusting hosted CI, check what's left:

```console
$ ci quota
portable-ci quota: 150/2000 Actions minutes used for acme — 1850 remaining
```

Needs a token that can read billing (classic PAT with `repo`, or a fine-grained
token with **Plan: read**) — tries the personal-account billing endpoint first,
falls back to the organization endpoint. Exits `1` when minutes are exhausted
(so it composes: `ci quota || ci run`), `2` when it can't be determined at all
(no token, no billing access).

If quota's exhausted (or the combined check state is failing with zero-duration
jobs and 404ing logs), Actions can't vouch for the commit — lean on your local
`ci run` / pre-push verdict, and mirror it back with `ci run --publish-status`
(see below), which records under `portable-ci/local` so it's never mistaken for a
hosted pass.

## Use in GitHub Actions

Drop this in `.github/workflows/ci.yml` (full copy in `examples/consumer-ci.yml`):

```yaml
name: CI
on: [push, pull_request]
permissions:
  contents: read
  statuses: write        # only for publish-status
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # set up your language + install deps here
      - uses: Munns729/portable-ci@v1
        with:
          config: ".localci"
          publish-status: "true"
```

The action runs the **same `.localci`** as your local `ci run`. The caller is
responsible for `actions/checkout` and any language setup (`setup-python`, etc.)
— portable-ci runs your checks, it doesn't guess your toolchain.

When it runs inside Actions, each step's output is wrapped in a collapsible log
group and a failing step raises an inline **`::error::` annotation** (advisory
steps raise `::warning::`), so a red check surfaces in the Actions UI and the
PR's checks tab — not just buried in the run log. These are emitted only inside
Actions; a local `ci run` stays clean.

`@v1` tracks the stable major (recommended). Use `@main` for the latest
unreleased changes, or a commit SHA to fully pin.

## Claude Code CI indicator integration

Claude Code's CI indicator (the `●CI` dot on a PR) mirrors GitHub's combined
check/status state for the head commit. `--publish-status` writes a commit
status that the indicator then reflects.

```bash
GITHUB_TOKEN=... ci run --publish-status
# or, with the gh CLI authenticated:
ci run --publish-status
```

Needs a token with the `repo:status` scope (`$GITHUB_TOKEN`, `$GH_TOKEN`, or
`gh auth token`).

### So the recorded status can't mislead you

A backup run should never be mistaken for hosted CI. Two things make sure of it:

- **A distinct context.** Run locally, `--publish-status` publishes under
  `portable-ci/local` (not `portable-ci`, which is what the hosted GitHub Actions
  job uses), with a description marked `local backup · N/N checks passed` — and
  `scoped to <ref> (partial)` when you used `--since`, so a scoped run never reads
  as full coverage. Inside Actions it publishes under `portable-ci` as `hosted`.
  Print the context that will be used with `ci resolve-context`.
- **A way to read back the truth.** `ci status` fetches what GitHub actually has
  for `HEAD` and labels every check *hosted* vs *local backup*, warning loudly
  when the only thing vouching for a commit is a local backup:

  ```console
  $ ci status
  portable-ci status for 7195126b4616 (Munns729/portable-ci)

    ✓  portable-ci/local      local backup         local backup · 3/3 checks passed

  summary: 0 hosted, 1 local backup, 0 other
  ⚠ hosted CI has not verified this commit — the only checks here are local portable-ci backups.
  ```

The repo is derived from your `origin` remote when it's a `github.com` URL. If
`origin` is something else — a proxied checkout, GitHub Enterprise, or a fork —
set the target explicitly:

```bash
PORTABLE_CI_REPO=owner/repo ci run --publish-status
ci run --publish-status --repo owner/repo      # same thing, as a flag
ci resolve-repo                                 # print what it resolved (debug)
```

**Honest limitations:**

- A published backup status **adds** a check under its own context
  (`portable-ci/local`); it does not override others. If a GitHub Actions run
  already **failed** on that same commit, the combined state stays failed. Where
  this shines is commits where Actions **never ran** (e.g. minutes exhausted) —
  then the backup is the only check and the indicator reflects your local result.
  Use `ci status` to confirm which is which before you trust a green dot.
- This reproduces the **checks**, not GitHub's **enforcement**. Required-status
  checks, branch protection, and CODEOWNERS live in repo settings; a local run
  carries none of that gating authority. Treat it as fast, honest signal — not
  as a security gate.
- Local runs use your local toolchain/versions. For exact CI parity, pin the
  same versions in your `.github/workflows/ci.yml` setup steps.
- **Parity has a ceiling: a local run can't reproduce what only the hosted job
  has** — repository/organization **secrets**, **OIDC** tokens (cloud
  federation), and **service containers** (a Postgres/Redis sidecar). A check
  that genuinely needs those still belongs in hosted CI (or a remote runner that
  mirrors it); portable-ci's job is the lint/type/test inner loop you *can* run
  locally, not the secret-dependent integration leg. Keep those checks in
  `ci.yml`, and let `.localci` cover the rest.

## Roadmap (not in v1)

Deliberately left out to keep v1 small: `--parallel` (concurrent steps),
`--watch` (re-run on change), and `--fix` (run formatters). Open an issue if you
want one.

## Contributing

portable-ci dogfoods itself — run `./bin/ci run` before you push, or install the
pre-push hook (`./bin/ci install-hook pre-push`) so it runs automatically and CI
failures never reach your inbox. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
