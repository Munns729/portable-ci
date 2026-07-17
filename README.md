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
# 1. install (clones to ~/.portable-ci and links `ci` onto your PATH)
curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/main/install.sh | bash

# 2. scaffold a config for this project (auto-detects your tools)
cd your-project && ci init

# 3. run your checks
ci run
```

That's the whole loop. Everything below is detail you can reach for later.

## Why

GitHub Actions is a hosted runner: it only tells you the result *after* you push
(and after it spends your minutes). When the minutes run out, CI stops entirely
and every PR shows a red check regardless of whether the code is fine.

portable-ci is the same checks as a **local command**. You get the result before
you push, for free, offline — and you can mirror that result back to GitHub so
tools that read GitHub status (like Claude Code's CI indicator) stay accurate.

## Install

It's a single script with no runtime dependencies beyond `bash`, `git`, and
`curl` (only for `--publish-status`).

```bash
curl -fsSL https://raw.githubusercontent.com/Munns729/portable-ci/main/install.sh | bash
```

The installer clones to `~/.portable-ci` and links `ci` into the first writable
dir on your PATH (`~/.local/bin`, then `/usr/local/bin`). Override with
`PORTABLE_CI_DIR`, `PORTABLE_CI_BIN`, or `PORTABLE_CI_REF` (branch/tag/SHA). Re-run
it any time to update.

Prefer to do it by hand? Clone and symlink yourself:

```bash
git clone https://github.com/Munns729/portable-ci ~/.portable-ci
ln -s ~/.portable-ci/bin/ci /usr/local/bin/ci   # or add bin/ to your PATH
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
/ `pytest`) and Node (`npm run lint|typecheck|test`) setups.

## Commands

| Command | What it does |
|---|---|
| `ci init` | Scaffold a `.localci` for this project (auto-detects your tools). Won't clobber an existing config. |
| `ci run` | Run all checks. Exit non-zero if any fails. (default) |
| `ci run --since <ref>` | Also export `$CI_CHANGED_FILES` (files changed vs `<ref>`) so steps can scope to what changed. |
| `ci run --publish-status` | After running, publish a GitHub commit status for `HEAD`. |
| `ci doctor` | Report which configured tools are installed (and versions) vs missing. |
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
status under the context `portable-ci`, which that indicator then reflects.

```bash
GITHUB_TOKEN=... ci run --publish-status
# or, with the gh CLI authenticated:
ci run --publish-status
```

Needs a token with the `repo:status` scope (`$GITHUB_TOKEN`, `$GH_TOKEN`, or
`gh auth token`).

The repo is derived from your `origin` remote when it's a `github.com` URL. If
`origin` is something else — a proxied checkout, GitHub Enterprise, or a fork —
set the target explicitly:

```bash
PORTABLE_CI_REPO=owner/repo ci run --publish-status
ci run --publish-status --repo owner/repo      # same thing, as a flag
ci resolve-repo                                 # print what it resolved (debug)
```

**Honest limitations:**

- A published `portable-ci` status **adds** a check; it does not override others.
  If a GitHub Actions run already **failed** on that same commit, the combined
  state stays failed. Where this shines is commits where Actions **never ran**
  (e.g. minutes exhausted) — then `portable-ci` is the only check, and the
  indicator reflects your local result.
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

## License

MIT — see [LICENSE](LICENSE).
