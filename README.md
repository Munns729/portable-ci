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

If there's no `.localci`, portable-ci auto-detects common Python (`ruff` / `mypy`
/ `pytest`) and Node (`npm run lint|typecheck|test`) setups. Autodetect is only a
fallback for the *default* path: an explicit `--config X` (or `PORTABLE_CI_CONFIG`)
that points at a missing file is an error, not a silent fall-through — so a
typo'd path can never quietly run a different set of checks and read as a pass.

## Commands

| Command | What it does |
|---|---|
| `ci init` | Scaffold a `.localci` for this project (auto-detects your tools). Won't clobber an existing config. |
| `ci run` | Run all checks. Exit non-zero if any fails. (default) |
| `ci run --since <ref>` | Also export `$CI_CHANGED_FILES` (files changed vs `<ref>`) so steps can scope to what changed. |
| `ci run --publish-status` | After running, publish a GitHub commit status for `HEAD`. |
| `ci doctor` | Report which configured tools are installed (and versions) vs missing. Warns when a deps-sensitive tool (`mypy`, `pytest`, …) resolves to a different Python than your `python3` — the "bare `mypy` vs `python -m mypy`" split that fails cryptically at run time. |
| `ci status` | Read back what GitHub actually has recorded for `HEAD` and label each check **hosted** (Actions/app) vs **local backup** (portable-ci). Warns when only a local backup vouches for the commit. Needs `jq`. |
| `ci quota` | Report remaining GitHub Actions minutes for the repo owner. Exit `1` when exhausted, `2` when it can't be determined — so it composes in scripts and hooks. |
| `ci install-hook [pre-push\|pre-commit]` | Install a git hook that runs `ci run` and blocks the action on failure. Won't clobber an existing unmanaged hook. |
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
