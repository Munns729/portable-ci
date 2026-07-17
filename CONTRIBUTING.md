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
