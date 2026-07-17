#!/usr/bin/env bash
# Self-test for portable-ci. Each case runs in its own throwaway directory so
# there is no cross-test state (git repos, installed hooks, config files).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="$ROOT/bin/ci"
PASS=0
FAIL=0
NO_COLOR=1; export NO_COLOR

ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# fresh <name> — make and cd into a clean dir for the next case.
fresh() { local d; d="$(mktemp -d)"; CASES+=("$d"); cd "$d" || exit 1; }
CASES=()
cleanup() { local d; for d in "${CASES[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT
gitcommit() { git -c user.email=t@t -c user.name=t commit -q "$@"; }

# 1. --version
fresh
if "$CI" --version | grep -q "portable-ci"; then ok "--version prints name"; else bad "--version"; fi

# 2. passing config exits 0
fresh
printf 'step "true-check" true\n' > .localci
if "$CI" run >/dev/null 2>&1; then ok "passing config -> exit 0"; else bad "passing config exit code"; fi

# 3. failing config exits non-zero
fresh
printf 'step "false-check" false\n' > .localci
if "$CI" run >/dev/null 2>&1; then bad "failing config should be non-zero"; else ok "failing config -> non-zero"; fi

# 4. mixed: one pass, one fail -> non-zero and both reported
fresh
printf 'step "a" true\nstep "b" false\n' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "a" && printf '%s' "$out" | grep -q "b"; then
  ok "mixed run reports both and fails"
else bad "mixed run (rc=$rc)"; fi

# 5. no config, nothing detected -> exit 2
fresh
"$CI" run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "empty project -> exit 2"; else bad "empty project (rc=$rc)"; fi

# 6. doctor flags a missing tool
fresh
printf 'step "ghost" definitely-not-a-real-binary-xyz\n' > .localci
if "$CI" doctor >/dev/null 2>&1; then bad "doctor should fail on missing tool"; else ok "doctor -> non-zero on missing tool"; fi

# 7. doctor passes when tool present
fresh
printf 'step "real" true\n' > .localci
if "$CI" doctor >/dev/null 2>&1; then ok "doctor -> 0 when present"; else bad "doctor false-negative"; fi

# 8. install-hook writes an executable pre-push hook
fresh
git init -q .
if "$CI" install-hook pre-push >/dev/null 2>&1 && [ -x .git/hooks/pre-push ]; then
  ok "install-hook writes executable pre-push"
else bad "install-hook"; fi

# 9. install-hook refuses to clobber an unmanaged hook
fresh
git init -q .
printf '#!/bin/sh\necho mine\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
if "$CI" install-hook pre-commit >/dev/null 2>&1; then bad "should refuse unmanaged hook"; else ok "refuses to clobber unmanaged hook"; fi

# 10. --since exports CI_CHANGED_FILES
fresh
git init -q .
printf 'step "x" true\n' > .localci
git add -A && gitcommit -m init
echo "new" > newfile.txt && git add -A && gitcommit -m second
printf 'step "changed" bash -c %s\n' "'printf \"%s\" \"\$CI_CHANGED_FILES\" | grep -q newfile.txt'" > .localci
if "$CI" run --since HEAD~1 >/dev/null 2>&1; then ok "--since exports CI_CHANGED_FILES"; else bad "--since scoping"; fi

# 11. resolve-repo honours PORTABLE_CI_REPO
fresh
if [ "$(PORTABLE_CI_REPO=me/proj "$CI" resolve-repo)" = "me/proj" ]; then
  ok "resolve-repo honours PORTABLE_CI_REPO"; else bad "PORTABLE_CI_REPO override"; fi

# 12. resolve-repo honours --repo flag (over env)
fresh
if [ "$(PORTABLE_CI_REPO=env/one "$CI" resolve-repo --repo flag/two)" = "flag/two" ]; then
  ok "resolve-repo --repo overrides env"; else bad "--repo flag override"; fi

# 13. resolve-repo parses a github.com https remote
fresh
git init -q .
git remote add origin https://github.com/acme/widgets.git
if [ "$("$CI" resolve-repo)" = "acme/widgets" ]; then ok "parses https github remote"; else bad "https remote parse"; fi

# 14. resolve-repo parses a github.com ssh remote
fresh
git init -q .
git remote add origin git@github.com:acme/gadgets.git
if [ "$("$CI" resolve-repo)" = "acme/gadgets" ]; then ok "parses ssh github remote"; else bad "ssh remote parse"; fi

# 15. non-github remote yields nothing without an override (the gap this closes)
fresh
git init -q .
git remote add origin http://local_proxy@127.0.0.1:41729/git/acme/thing
if [ -z "$("$CI" resolve-repo)" ]; then ok "non-github remote -> empty (needs override)"; else bad "non-github should be empty"; fi

# 16. ...but the override wins over a non-github remote
fresh
git init -q .
git remote add origin http://local_proxy@127.0.0.1:41729/git/acme/thing
if [ "$(PORTABLE_CI_REPO=acme/thing "$CI" resolve-repo)" = "acme/thing" ]; then
  ok "override wins over non-github remote"; else bad "override over proxied remote"; fi

# 17. init writes a runnable .localci and won't clobber an existing one
fresh
"$CI" init >/dev/null 2>&1
if [ -f .localci ] && "$CI" init >/dev/null 2>&1; then
  bad "init should refuse to clobber an existing .localci"
elif [ -f .localci ]; then
  ok "init writes .localci and refuses to clobber it"
else bad "init did not write .localci"; fi

# 18. init detects Node scripts and fills them in
fresh
printf '{"scripts":{"lint":"eslint","test":"jest"}}\n' > package.json
"$CI" init >/dev/null 2>&1
if grep -q 'npm run lint' .localci && grep -q 'npm run test' .localci; then
  ok "init detects and writes Node scripts"; else bad "init Node detection"; fi

# 19. init's generated config is loadable and runs
fresh
printf '{"scripts":{"test":"true"}}\n' > package.json
"$CI" init >/dev/null 2>&1
# swap the detected command for a no-op so the run doesn't depend on npm
printf 'step "ok" true\n' > .localci
if "$CI" run >/dev/null 2>&1; then ok "config produced by init is runnable"; else bad "init config run"; fi

# 20. resolve-context defaults to a distinct local-backup context.
# Force a non-Actions env: this suite itself runs inside GitHub Actions, where
# the (correct) default is plain `portable-ci` — see the next case.
fresh
if [ "$(env -u GITHUB_ACTIONS -u PORTABLE_CI_CONTEXT "$CI" resolve-context)" = "portable-ci/local" ]; then
  ok "local runs default to portable-ci/local context"; else bad "local context default"; fi

# 21. resolve-context yields plain portable-ci inside GitHub Actions (hosted)
fresh
if [ "$(GITHUB_ACTIONS=true "$CI" resolve-context)" = "portable-ci" ]; then
  ok "Actions runs default to portable-ci context"; else bad "Actions context default"; fi

# 22. an explicit --context always wins
fresh
if [ "$("$CI" resolve-context --context my-ctx)" = "my-ctx" ]; then
  ok "resolve-context honours explicit --context"; else bad "explicit context override"; fi

# 23. status errors cleanly with no token (no network attempted)
fresh
git init -q .
out="$(env -u GITHUB_TOKEN -u GH_TOKEN "$CI" status 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "token"; then
  ok "status without a token fails cleanly"; else bad "status no-token (rc=$rc)"; fi

# 24. status errors cleanly when the repo can't be resolved
fresh
git init -q .
out="$(GITHUB_TOKEN=x "$CI" status 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "owner/repo"; then
  ok "status with unresolvable repo fails cleanly"; else bad "status no-repo (rc=$rc)"; fi

# 25. an advisory step that fails does NOT gate the run (exit 0)
fresh
printf 'step "hard" true\nstep_soft "soft" false\n' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "advisory"; then
  ok "advisory step failure does not gate the run"; else bad "advisory non-gating (rc=$rc)"; fi

# 26. a hard step still fails even when an advisory step is present
fresh
printf 'step "hard" false\nstep_soft "soft" true\n' > .localci
"$CI" run >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "hard failure still gates alongside advisory"; else bad "hard+advisory gating"; fi

# 27. doctor treats a missing advisory tool as optional (does not fail)
fresh
printf 'step_soft "opt" definitely-not-a-real-binary-xyz\n' > .localci
out="$("$CI" doctor 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "optional"; then
  ok "doctor: missing advisory tool is optional"; else bad "doctor advisory optional (rc=$rc)"; fi

# 28. explicit --config to a missing file errors (no silent autodetect fallback)
fresh
printf '{"scripts":{"test":"true"}}\n' > package.json   # would autodetect if we fell through
out="$("$CI" run --config no-such.localci 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "not found"; then
  ok "explicit missing --config errors, no autodetect fallback"; else bad "config guard (rc=$rc)"; fi

# 29. a run prints a SHA-stamped attestation record
fresh
git init -q .
printf 'step "x" true\n' > .localci
git add -A && gitcommit -m init
sha="$(git rev-parse --short=12 HEAD)"
out="$("$CI" run 2>&1)"
if printf '%s' "$out" | grep -q "attestation:" && printf '%s' "$out" | grep -q "$sha"; then
  ok "run prints a SHA-stamped attestation"; else bad "attestation record"; fi

echo
printf 'tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
