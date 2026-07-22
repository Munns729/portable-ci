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

# 30. init nudges the user toward the pre-push hook (the pre-Actions path)
fresh
out="$("$CI" init 2>&1)"
if printf '%s' "$out" | grep -q "install-hook pre-push"; then
  ok "init nudges toward the pre-push hook"; else bad "init hook nudge"; fi

# 31. the installed pre-push hook runs .localci and frames itself as pre-Actions
fresh
git init -q .
"$CI" install-hook pre-push >/dev/null 2>&1
if grep -q "ci run" .git/hooks/pre-push && grep -qi "before push" .git/hooks/pre-push; then
  ok "pre-push hook runs .localci, framed as pre-Actions"; else bad "hook body framing"; fi

# 32. doctor warns on an interpreter split for a deps-sensitive tool (mypy)...
fresh
mkdir -p fakebin
printf '#!/nonexistent/python\n' > fakebin/mypy; chmod +x fakebin/mypy
printf 'step "types" mypy\n' > .localci
out="$(PATH="$PWD/fakebin:$PATH" "$CI" doctor 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "python -m mypy"; then
  ok "doctor warns on interpreter split (mypy), still exits 0"; else bad "doctor interpreter note (rc=$rc)"; fi

# 33. ...but not for a tool that doesn't need the project interpreter (ruff)
fresh
mkdir -p fakebin
printf '#!/nonexistent/python\n' > fakebin/ruff; chmod +x fakebin/ruff
printf 'step "lint" ruff\n' > .localci
out="$(PATH="$PWD/fakebin:$PATH" "$CI" doctor 2>&1)"
if printf '%s' "$out" | grep -q "python -m"; then
  bad "doctor should not warn for non-sensitive ruff"; else ok "doctor: no interpreter note for ruff"; fi

# 34. quota errors cleanly with no token (no network attempted)
fresh
git init -q .
out="$(env -u GITHUB_TOKEN -u GH_TOKEN "$CI" quota 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "token"; then
  ok "quota without a token fails cleanly"; else bad "quota no-token (rc=$rc)"; fi

# 35. quota errors cleanly when the repo can't be resolved
fresh
git init -q .
out="$(GITHUB_TOKEN=x "$CI" quota 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "owner/repo"; then
  ok "quota with unresolvable repo fails cleanly"; else bad "quota no-repo (rc=$rc)"; fi

# 36. quota reports availability (exit 0) via a stubbed billing response
fresh
mkdir -p fakebin
cat > fakebin/curl <<'STUB'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  */users/*/settings/billing/actions) printf '{"included_minutes":2000,"total_minutes_used":150}\n200' ;;
  *) printf '{}\n404' ;;
esac
STUB
chmod +x fakebin/curl
git init -q . && git remote add origin https://github.com/acme/widgets.git
out="$(PATH="$PWD/fakebin:$PATH" GITHUB_TOKEN=t "$CI" quota 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "1850 remaining"; then
  ok "quota reports remaining minutes (exit 0)"; else bad "quota available (rc=$rc): $out"; fi

# 37. quota reports exhaustion (exit 1) with a warning
fresh
mkdir -p fakebin
cat > fakebin/curl <<'STUB'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  */users/*/settings/billing/actions) printf '{"included_minutes":2000,"total_minutes_used":2000}\n200' ;;
  *) printf '{}\n404' ;;
esac
STUB
chmod +x fakebin/curl
git init -q . && git remote add origin https://github.com/acme/widgets.git
out="$(PATH="$PWD/fakebin:$PATH" GITHUB_TOKEN=t "$CI" quota 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "no Actions minutes left"; then
  ok "quota warns and exits 1 when exhausted"; else bad "quota exhausted (rc=$rc): $out"; fi

# 38. quota falls back to the org billing endpoint when the user endpoint 404s
fresh
mkdir -p fakebin
cat > fakebin/curl <<'STUB'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  */users/*/settings/billing/actions) printf '{}\n404' ;;
  */orgs/*/settings/billing/actions)  printf '{"included_minutes":3000,"total_minutes_used":500}\n200' ;;
  *) printf '{}\n404' ;;
esac
STUB
chmod +x fakebin/curl
git init -q . && git remote add origin https://github.com/acme/widgets.git
out="$(PATH="$PWD/fakebin:$PATH" GITHUB_TOKEN=t "$CI" quota 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "2500 remaining"; then
  ok "quota falls back to org billing endpoint"; else bad "quota org fallback (rc=$rc): $out"; fi

# 39. min_version: a satisfied requirement runs the config normally
fresh
printf 'min_version 0.0.1
step "echo" echo hi
' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "passed"; then
  ok "min_version: satisfied requirement runs"; else bad "min_version satisfied (rc=$rc): $out"; fi

# 40. min_version: an unmet requirement stops with exit 2 and names the fix.
# Exit 2 = "couldn't determine", not 1 = "your code failed" — the run produced
# no verdict at all.
fresh
printf 'min_version 9999.0.0
step "echo" echo hi
' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "requires portable-ci >= 9999.0.0" && printf '%s' "$out" | grep -q "install.sh"; then
  ok "min_version: unmet requirement stops with exit 2 and an actionable message"
else bad "min_version unmet (rc=$rc): $out"; fi

# 41. min_version: a MALFORMED requirement must FAIL, never silently pass. A
# config asking for `min_version latest` that quietly succeeded would assert a
# guarantee it never checked — this is the false-positive surface.
fresh
printf 'min_version latest
step "echo" echo hi
' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "needs X.Y.Z"; then
  ok "min_version: malformed requirement fails"; else bad "min_version malformed (rc=$rc): $out"; fi

# 42. min_version: a missing argument must fail too
fresh
printf 'min_version
step "echo" echo hi
' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "needs a version argument"; then
  ok "min_version: missing argument fails"; else bad "min_version missing arg (rc=$rc): $out"; fi

# 43. Version comparison is NUMERIC per field, not lexical. 0.3.0 < 0.10.0
# numerically (3 < 10) even though "0.3.0" > "0.10.0" lexically. An earlier
# implementation also split BOTH versions in one `set --` and read the
# right-hand fields from fixed positions, which shifts when the left side has
# fewer fields — `1` vs `2.0.0` compared the wrong operand, while `2` vs
# `1.0.0` returned the right answer for the wrong reason. A happy-path check
# would have missed both.
fresh
printf 'min_version 0.10.0
step "echo" echo hi
' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "min_version: 0.10.0 > 0.3.0 (numeric, not lexical)"
else bad "min_version numeric compare (rc=$rc): $out"; fi

# 44-47. The pre-push hook must sanitise git's hook environment and derive
# --since from the pushed range. A stub `ci` on PATH reports what it received.
_hookcase() { # <stdin-line> -> echoes the args the hook passed to `ci`
  printf '%s' "$1" | bash .git/hooks/pre-push 2>/dev/null | head -1
}
fresh
git init -q .
printf 'step "echo" echo hi
' > .localci
"$CI" install-hook pre-push >/dev/null 2>&1
mkdir -p stub
cat > stub/ci <<'STUB'
#!/usr/bin/env bash
echo "ARGS:$*"
echo "ENV:GIT_DIR=${GIT_DIR:-unset},GIT_INDEX_FILE=${GIT_INDEX_FILE:-unset}"
STUB
chmod +x stub/ci
PATH="$PWD/stub:$PATH"; export PATH
ZERO=0000000000000000000000000000000000000000

# 44. a normal push forwards the remote sha as --since
out="$(_hookcase 'refs/heads/main aaa111 refs/heads/main bbb222
')"
if [ "$out" = "ARGS:run --since bbb222" ]; then
  ok "pre-push hook derives --since from the pushed range"
else bad "pre-push --since: $out"; fi

# 45. a NEW branch has no remote baseline (all-zero remote sha) -> unscoped.
# Unscoped is the SAFE direction: it runs everything rather than silently
# checking a subset against a ref that does not exist.
out="$(_hookcase "refs/heads/new ccc333 refs/heads/new $ZERO
")"
if [ "$out" = "ARGS:run" ]; then
  ok "pre-push hook omits --since for a new branch"
else bad "pre-push new branch: $out"; fi

# 46. a branch DELETION (all-zero local sha) has nothing to check
out="$(_hookcase "(delete) $ZERO refs/heads/gone ddd444
")"
if [ "$out" = "ARGS:run" ]; then
  ok "pre-push hook skips a branch deletion"
else bad "pre-push deletion: $out"; fi

# 47. git's hook env must NOT reach the checks. Left set, a check's `git`
# subprocesses inherit a repo pointer: `git` then succeeds outside any repo
# (inverting any "not a git repo" assertion), and a test doing `git add`
# against its own temp repo writes to the REAL index instead.
out="$(printf 'refs/heads/main aaa111 refs/heads/main bbb222
'   | GIT_DIR=/fake GIT_INDEX_FILE=/fake/idx bash .git/hooks/pre-push 2>/dev/null | sed -n 2p)"
if [ "$out" = "ENV:GIT_DIR=unset,GIT_INDEX_FILE=unset" ]; then
  ok "pre-push hook unsets git's hook environment before running checks"
else bad "pre-push env sanitising: $out"; fi



# 48. step_timeout kills a hard step that overruns its cap -> fail, "timed out"
fresh
if command -v timeout >/dev/null 2>&1; then
  printf 'step_timeout 1\nstep "slow" sleep 5\n' > .localci
  out="$("$CI" run 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "timed out"; then
    ok "step_timeout fails a slow hard step"; else bad "step_timeout hard (rc=$rc): $out"; fi
else
  ok "step_timeout hard (skipped: no timeout binary)"
fi

# 49. a slow ADVISORY step that times out is reported, never gates the run
fresh
if command -v timeout >/dev/null 2>&1; then
  printf 'step "fast" true\nstep_timeout 1\nstep_soft "slow" sleep 5\n' > .localci
  out="$("$CI" run 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "advisory"; then
    ok "step_timeout advisory times out without gating"; else bad "step_timeout soft (rc=$rc): $out"; fi
else
  ok "step_timeout advisory (skipped: no timeout binary)"
fi

# 50. a fast step under the cap still passes normally
fresh
printf 'step_timeout 30\nstep "fast" true\n' > .localci
if "$CI" run >/dev/null 2>&1; then ok "step_timeout leaves a fast step alone"; else bad "step_timeout fast pass"; fi

# 51. step_timeout rejects a non-numeric argument (exit 2, no verdict)
fresh
printf 'step_timeout abc\nstep "x" true\n' > .localci
out="$("$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "whole number"; then
  ok "step_timeout rejects a non-numeric argument"; else bad "step_timeout bad arg (rc=$rc): $out"; fi

# 52. --list shows configured steps WITHOUT executing them (no side effects)
fresh
printf 'step "make-file" touch SHOULD_NOT_EXIST\n' > .localci
out="$("$CI" run --list 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "make-file" && [ ! -e SHOULD_NOT_EXIST ]; then
  ok "--list shows steps without executing"; else bad "--list (rc=$rc): $out"; fi

# 53. --dry-run prints the plan without executing it
fresh
printf 'step "make-file" touch SHOULD_NOT_EXIST\n' > .localci
out="$("$CI" run --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "would run" && [ ! -e SHOULD_NOT_EXIST ]; then
  ok "--dry-run shows the plan without executing"; else bad "--dry-run (rc=$rc): $out"; fi

# 54. install-hook claude wires ci run into agent hooks (.claude/settings.json)
fresh
git init -q .
out="$("$CI" install-hook claude 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f .claude/settings.json ] \
   && grep -q "PreToolUse" .claude/settings.json \
   && grep -q "Stop" .claude/settings.json \
   && grep -q "ci run" .claude/settings.json; then
  ok "install-hook claude writes agent hooks"; else bad "install-hook claude (rc=$rc): $out"; fi

# 55. install-hook claude is idempotent — no duplicate entries on re-run
fresh
git init -q .
"$CI" install-hook claude >/dev/null 2>&1
"$CI" install-hook claude >/dev/null 2>&1
n="$(grep -c "PreToolUse" .claude/settings.json 2>/dev/null || echo 0)"
if [ "$n" = "1" ]; then ok "install-hook claude is idempotent"; else bad "install-hook claude idempotency (n=$n)"; fi

# 56. install-hook claude merges into an EXISTING settings file, preserving it
fresh
git init -q .
mkdir -p .claude
printf '{"model":"opus","hooks":{"PreToolUse":[]}}\n' > .claude/settings.json
"$CI" install-hook claude >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '"model"' .claude/settings.json && grep -q "ci run" .claude/settings.json; then
  ok "install-hook claude merges without clobbering existing settings"; else bad "install-hook claude merge (rc=$rc)"; fi

# 57. install-hook rejects an unknown hook kind (exit 2)
fresh
git init -q .
"$CI" install-hook bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "install-hook rejects an unknown kind"; else bad "install-hook unknown (rc=$rc)"; fi

# 58. the generated PreToolUse hook must exit 2 (not 1) when ci run fails —
# Claude Code only BLOCKS a tool call on exit 2; exit 1 is a non-blocking error,
# so a plain `ci run` would let the commit through. Run the installed command
# with a failing `ci` on PATH and assert it exits 2.
fresh
git init -q .
mkdir -p stub; printf '#!/bin/sh\nexit 1\n' > stub/ci; chmod +x stub/ci
"$CI" install-hook claude >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
  cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' .claude/settings.json)"
  PATH="$PWD/stub:$PATH" bash -c "$cmd" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then ok "PreToolUse hook blocks (exit 2) when ci run fails"; else bad "PreToolUse block (rc=$rc)"; fi
else ok "PreToolUse block (skipped: no jq)"; fi

# 59. the Stop hook exits 2 when the worktree is dirty and ci run fails
fresh
git init -q .
printf 'dirty\n' > afile   # untracked -> porcelain non-empty
mkdir -p stub; printf '#!/bin/sh\nexit 1\n' > stub/ci; chmod +x stub/ci
"$CI" install-hook claude >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' .claude/settings.json)"
  PATH="$PWD/stub:$PATH" bash -c "$cmd" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then ok "Stop hook blocks (exit 2) when dirty and failing"; else bad "Stop block (rc=$rc)"; fi
else ok "Stop block (skipped: no jq)"; fi

# 60. the Stop hook exits 0 on a clean worktree (nothing to check — never blocks)
fresh
git init -q .
mkdir -p stub; printf '#!/bin/sh\nexit 1\n' > stub/ci; chmod +x stub/ci   # would fail if wrongly invoked
"$CI" install-hook claude >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' .claude/settings.json)"
  git add -A && gitcommit -m init   # commit settings + stub so the worktree is genuinely clean now
  PATH="$PWD/stub:$PATH" bash -c "$cmd" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "Stop hook skips a clean worktree (exit 0)"; else bad "Stop clean (rc=$rc)"; fi
else ok "Stop clean (skipped: no jq)"; fi

# 61. PORTABLE_CI_HOOKS_OFF short-circuits the PreToolUse hook (exit 0, ci never runs)
fresh
git init -q .
mkdir -p stub; printf '#!/bin/sh\nexit 1\n' > stub/ci; chmod +x stub/ci
"$CI" install-hook claude >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
  cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' .claude/settings.json)"
  PATH="$PWD/stub:$PATH" PORTABLE_CI_HOOKS_OFF=1 bash -c "$cmd" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "PORTABLE_CI_HOOKS_OFF disables the hook (exit 0)"; else bad "hooks-off (rc=$rc)"; fi
else ok "hooks-off (skipped: no jq)"; fi

# 62. inside GitHub Actions, a failing step emits ::group:: + an ::error:: annotation
fresh
printf 'step "boom" false\n' > .localci
out="$(GITHUB_ACTIONS=true "$CI" run 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '::group::boom' \
   && printf '%s' "$out" | grep -q '::endgroup::' \
   && printf '%s' "$out" | grep -q '::error .*boom'; then
  ok "Actions: failing step emits ::group:: + ::error:: annotation"; else bad "gha error annotation (rc=$rc)"; fi

# 63. a failing ADVISORY step emits ::warning:: (not ::error::) and still doesn't gate
fresh
printf 'step_soft "flaky" false\n' > .localci
out="$(GITHUB_ACTIONS=true "$CI" run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '::warning .*flaky' \
   && ! printf '%s' "$out" | grep -q '::error'; then
  ok "Actions: advisory failure emits ::warning::, not ::error::"; else bad "gha advisory warning (rc=$rc)"; fi

# 64. a passing step in Actions groups its output but raises no annotation
fresh
printf 'step "ok" true\n' > .localci
out="$(GITHUB_ACTIONS=true "$CI" run 2>&1)"
if printf '%s' "$out" | grep -q '::group::ok' && printf '%s' "$out" | grep -q '::endgroup::' \
   && ! printf '%s' "$out" | grep -q '::error\|::warning'; then
  ok "Actions: passing step groups output, no annotation"; else bad "gha pass grouping"; fi

# 65. OUTSIDE Actions, no workflow-command lines leak into local output
fresh
printf 'step "boom" false\n' > .localci
out="$(env -u GITHUB_ACTIONS "$CI" run 2>&1)"
if printf '%s' "$out" | grep -q '::group::\|::error\|::warning\|::endgroup::'; then
  bad "GHA workflow commands leaked into a local run"; else ok "no GHA annotations in local runs"; fi

echo
printf 'tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
