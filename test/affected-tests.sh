#!/usr/bin/env bash
# Tests for `ci run --affected <base-ref>` and head binding (`ci run --shard --head`).
#
# The rule under test: a PARTIAL (affected) result must not be readable as a full-suite verdict by ANY reader
# of the grammar, and a shard result must never be bound to a head other than the one asked for. Each reader and
# each refusal site has its own test, with a positive control (the same reader accepts a real full result).
# CI=<path> runs the suite against another build (used to prove each test is red before the feature).
# shellcheck disable=SC2015  # ok() and bad() always return 0, so `cond && ok || bad` is a real if-else here
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="${AFFECTED_TEST_CI:-$ROOT/bin/ci}"
PASS=0; FAIL=0
NO_COLOR=1; export NO_COLOR
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PORTABLE_CI_RUNS_DIR="$WORK/runs"
export HOME="$WORK/home"; mkdir -p "$HOME"
gc() { git -c user.email=t@t -c user.name=t commit -q "$@"; }

# ---- fixture: main + one feature commit touching src/widget.py --------------------------------------------
REPO="$WORK/repo"; mkdir -p "$REPO/src" "$REPO/tests" && cd "$REPO" || exit 1
git init -q -b main .
echo a > src/widget.py; echo b > src/other.py; echo t > tests/test_widget.py; echo t > tests/test_other.py
git add -A && gc -m base
BASE="$(git rev-parse HEAD)"; BASE12="${BASE:0:12}"
echo a2 > src/widget.py && git add -A && gc -m feature
HEAD40="$(git rev-parse HEAD)"

# the hook maps src/<n>.py -> tests/test_<n>.py
write_hook_config() {
  cat > .localci <<'L'
affected_tests bash -c 'sed -n "s|^src/\(.*\)\.py$|tests/test_\1.py|p"'
step "test" bash -c 'echo "SELECTED=[${CI_AFFECTED_TESTS-UNSET}] MODE=${CI_AFFECTED_MODE-none}"'
L
}
RXA="$ROOT/contract/attestation.regex"; RXS="$ROOT/contract/shard-result.regex"
[ -f "$RXA" ] && [ -f "$RXS" ] || { echo "contract regexes missing"; exit 1; }
rx() { printf '%s\n' "$2" | LC_ALL=C grep -Eq -f "$1"; }
LABEL="partial (affected vs $BASE12)"

# ---- 1. the hook narrows the run; the line is labelled partial -----------------------------------------------
write_hook_config
out="$("$CI" run --affected "$BASE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SELECTED=\[tests/test_widget.py\] MODE=hook'; then ok "affected: hook output reaches the steps as CI_AFFECTED_TESTS (only the mapped test)"; else bad "hook selection (rc=$rc): $out"; fi
pl="$(printf '%s\n' "$out" | grep '^portable-ci partial-run:' | head -1)"
if printf '%s' "$pl" | grep -qF "$LABEL" && printf '%s' "$pl" | grep -qF "head ${HEAD40:0:12}" && printf '%s' "$pl" | grep -q 'NOT a verdict'; then ok "affected: the line is labelled '$LABEL' and says NOT a verdict"; else bad "partial line: '$pl'"; fi

if printf '%s' "$pl" | grep -q 'selection: hook · affected-tests: 1 ·'; then ok "affected: the line states how many tests the hook selected (1)"; else bad "count missing: '$pl'"; fi
# a hook that selects nothing is visible as 0, not as a silent pass
cat > .localci <<'L'
affected_tests bash -c 'true'
step "test" bash -c 'for t in $CI_AFFECTED_TESTS; do echo "ran $t"; done'
L
out="$("$CI" run --affected "$BASE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'affected-tests: 0 ·'; then ok "affected: an empty hook result shows 'affected-tests: 0' in the line"; else bad "zero count (rc=$rc): $out"; fi
# a hook declared AFTER a step is refused, never mislabelled as 'hook'
cat > .localci <<'L'
step "early" true
affected_tests bash -c 'echo tests/test_widget.py'
L
out="$("$CI" run --affected "$BASE" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'affected_tests refused: it is declared AFTER a step' && ! printf '%s' "$out" | grep -q 'selection: hook'; then ok "affected: a hook declared after a step is refused (exit 2), not labelled 'hook'"; else bad "late hook (rc=$rc): $out"; fi

# ---- 2. fallbacks: no hook, a failing hook -> run everything, still partial ----------------------------------
printf 'step "test" bash -c %s\n' "'echo \"SELECTED=[\${CI_AFFECTED_TESTS-UNSET}] MODE=\${CI_AFFECTED_MODE-none}\"'" > .localci
out="$("$CI" run --affected "$BASE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SELECTED=\[UNSET\] MODE=all' && printf '%s' "$out" | grep -qF "$LABEL" && printf '%s' "$out" | grep -q 'no-hook-ran-everything'; then ok "affected: no hook -> runs everything (selection unset) and is STILL labelled partial"; else bad "no-hook fallback (rc=$rc): $out"; fi
cat > .localci <<'L'
affected_tests bash -c 'exit 3'
step "test" bash -c 'echo "SELECTED=[${CI_AFFECTED_TESTS-UNSET}]"'
L
out="$("$CI" run --affected "$BASE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'SELECTED=\[UNSET\]' && printf '%s' "$out" | grep -q 'hook failed' && printf '%s' "$out" | grep -qF "$LABEL"; then ok "affected: a failing hook falls back to everything, says so, still partial"; else bad "failing hook (rc=$rc): $out"; fi

# ---- 3. a failing step still fails the run (exit non-zero), still partial -------------------------------------
printf 'step "boom" false\n' > .localci
out="$("$CI" run --affected "$BASE" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'steps-FAILED' && ! printf '%s' "$out" | grep -q 'attestation:'; then ok "affected: a failing step exits non-zero, labelled steps-FAILED, no attestation"; else bad "failing step (rc=$rc): $out"; fi

# ---- 4. EVERY reader refuses a partial result (the red-if-accepted tests) -------------------------------------
write_hook_config
out="$("$CI" run --affected "$BASE" 2>&1)"
pl="$(printf '%s\n' "$out" | grep '^portable-ci partial-run:' | head -1)"
# 4a. a full run, as the positive control for every reader
printf 'step "t" true\n' > .localci
full="$("$CI" run 2>&1 | grep '^portable-ci attestation:' | head -1)"
if rx "$RXA" "$full"; then ok "positive control: a real full-run line matches contract/attestation.regex"; else bad "control: '$full'"; fi
# 4b. reader: attestation.regex
if [ -n "$pl" ] && ! rx "$RXA" "$pl"; then ok "reader attestation.regex: the partial line does NOT match"; else bad "ACCEPTED by attestation.regex: $pl"; fi
# 4c. reader: shard-result.regex
if [ -n "$pl" ] && ! rx "$RXS" "$pl"; then ok "reader shard-result.regex: the partial line does NOT match"; else bad "ACCEPTED by shard-result.regex: $pl"; fi
# 4d. reader: the prefix every prose/grep consumer keys on, and the verdict words
if [ -n "$pl" ] && ! printf '%s' "$out" | grep -q 'portable-ci attestation:' && ! printf '%s' "$out" | grep -qE 'passed @|passed-on-rerun @|FAILED @'; then ok "reader prefix/verdict grep: no 'attestation:' prefix and no '<verdict> @ <sha>' anywhere in a partial run"; else bad "partial output carries a verdict shape: $out"; fi
# 4e. reader: the run record says partial, scope says partial
write_hook_config; rm -rf "$PORTABLE_CI_RUNS_DIR"; "$CI" run --affected "$BASE" >/dev/null 2>&1
rec="$(find "$PORTABLE_CI_RUNS_DIR" -name '*.json' | head -1)"
if [ -n "$rec" ] && grep -q '^  "verdict": "partial"' "$rec" && grep -qF "\"scope\": \"$LABEL\"" "$rec"; then ok "reader run record: verdict 'partial', scope '$LABEL'"; else bad "record: $(cat "$rec" 2>/dev/null | head -12)"; fi
# 4f. reader: the next full run at this sha is plain 'passed' (a partial FAILED record is not a prior failure)
printf 'step "boom" false\n' > .localci; "$CI" run --affected "$BASE" >/dev/null 2>&1
printf 'step "t" true\n' > .localci; out="$("$CI" run 2>&1)"
if printf '%s' "$out" | grep -q '^portable-ci attestation: passed @ ' && ! printf '%s' "$out" | grep -q 'passed-on-rerun'; then ok "reader previous-record: a partial run leaves no 'prior failure' (next full run is plain passed)"; else bad "partial record leaked into verdict: $out"; fi
# 4g. reader: attest-merge refuses a shard result that is partial (verdict, key, scope), and still accepts the control
SHARD_REPO="$WORK/srepo"; mkdir -p "$SHARD_REPO" && cd "$SHARD_REPO" || exit 1
git init -q -b main . && git init -q --bare "$WORK/origin.git" && git remote add origin "$WORK/origin.git"
cat > nodes.all <<'N'
tests/test_a.py::test_one
N
printf 'tests/test_a.py\t0\n' > plan.txt
cat > stub.sh <<'S'
#!/usr/bin/env bash
d="$CI_SHARD_DIR"
case "$1" in
  collect) cp nodes.all "$d/collect.nodes"; cp plan.txt "$d/partition.plan"; echo "-q" > "$d/pytest.args"; echo 7 > "$d/seed"; : > "$d/guards.list"; : > "$d/once.steps"; echo 0 > "$d/member.mode" ;;
  run) cp nodes.all "$d/executed.nodes"; printf 'passed=1\nfailed=0\nerror=0\nskipped=0\nxfailed=0\nxpassed=0\n' > "$d/counts" ;;
esac
S
chmod +x stub.sh
cat > .localci <<'L'
if [ -n "${CI_SHARD_COUNT:-}" ]; then
  step "fingerprint" echo fixture-env
  step "shard-collect" ./stub.sh collect
  step "pytest" ./stub.sh run
else
  step "pytest" true
fi
L
git add -A && gc -m fixture && git push -q origin main 2>/dev/null
SHEAD="$(git rev-parse HEAD)"
"$CI" run --shard 0/1 >/dev/null 2>&1 || bad "shard fixture run failed"
mkdir -p "$WORK/good" && cp .portable-ci/shard-result.json .portable-ci/shard-*.nodes .portable-ci/shard-partition.plan "$WORK/good/"
out="$("$CI" attest-merge --head "$SHEAD" "$WORK/good/shard-result.json" 2>&1)"
if printf '%s' "$out" | grep -q '^portable-ci attestation: passed @ '; then ok "positive control: attest-merge accepts the good shard result"; else bad "attest-merge control: $out"; fi
for variant in 'verdict:"partial"' 'affected_base:"abc"' 'scope:"partial (affected vs abc)"'; do
  d="$WORK/p-${variant%%:*}"; mkdir -p "$d"; cp "$WORK"/good/* "$d/"
  case "${variant%%:*}" in
    verdict) sed -i 's|^  "verdict": .*|  "verdict": "partial",|' "$d/shard-result.json" ;;
    *) sed -i "s|^  \"kind\": \(.*\)|  \"kind\": \1\n  \"${variant%%:*}\": ${variant#*:},|" "$d/shard-result.json" ;;
  esac
  out="$("$CI" attest-merge --head "$SHEAD" "$d/shard-result.json" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q 'attestation: passed'; then ok "reader attest-merge: a shard result marked ${variant%%:*}=partial is REFUSED"; else bad "attest-merge ACCEPTED a partial ($variant) rc=$rc: $out"; fi
done
# 4h. the producer side: --affected can never become a shard result, a published status, a rerun, or a --since run
cd "$REPO" || exit 1
write_hook_config
for combo in '--shard 0/1' '--publish-status' '--since HEAD~1' "--rerun-of $HEAD40" "--head $HEAD40"; do
  # shellcheck disable=SC2086  # the combo is a deliberate word list
  out="$("$CI" run --affected "$BASE" $combo 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--affected refused'; then ok "affected + $combo -> refused by name (exit 2)"; else bad "affected + $combo (rc=$rc): $out"; fi
done
out="$("$CI" run --affected nosuchref 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'does not resolve'; then ok "affected: an unresolvable base is refused, not silently a full run"; else bad "bad base (rc=$rc): $out"; fi
out="$("$CI" run --affected 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'needs a base ref'; then ok "affected: no base ref is refused"; else bad "no base (rc=$rc): $out"; fi
# a plain run is untouched: no partial vocabulary, affected variables not set
printf 'step "e" bash -c %s\n' "'echo \"A=[\${CI_AFFECTED-unset}]\"'" > .localci
out="$(CI_AFFECTED=1 "$CI" run 2>&1)"
if printf '%s' "$out" | grep -q 'A=\[unset\]' && printf '%s' "$out" | grep -q '^portable-ci attestation: passed @ ' && ! printf '%s' "$out" | grep -q partial; then ok "plain run: unaffected, and inherits no CI_AFFECTED from the environment"; else bad "plain run: $out"; fi

# ---- 5. head binding: the producer ------------------------------------------------------------------------------
cd "$SHARD_REPO" || exit 1
rm -f .portable-ci/shard-result.json   # the earlier fixture run's result: the refusal must not produce a NEW one
out="$("$CI" run --shard 0/1 --head 1111111111111111111111111111111111111111 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--head refused' && [ ! -e .portable-ci/shard-result.json ]; then ok "head binding [run --shard --head]: a checkout at another head is refused and writes NO result"; else bad "stale checkout (rc=$rc): $out"; fi
out="$("$CI" run --shard 0/1 --head "$SHEAD" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -s .portable-ci/shard-result.json ]; then ok "head binding: the matching head runs and writes the result (positive control)"; else bad "matching head (rc=$rc): $out"; fi
# strict equality, never a prefix and never case-folded: a 12-char prefix, an upper-cased head, and a head that
# differs only at char 40 (positive control above: the exact head runs)
lastc="${SHEAD:39:1}"; altc=0; [ "$lastc" = 0 ] && altc=1
for badhead in "${SHEAD:0:12}" "$(printf '%s' "$SHEAD" | tr 'a-f' 'A-F')" "${SHEAD:0:39}$altc"; do
  [ "$badhead" != "$SHEAD" ] || { bad "fixture: bad head equals the real one"; continue; }
  rm -f .portable-ci/shard-result.json
  out="$("$CI" run --shard 0/1 --head "$badhead" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e .portable-ci/shard-result.json ]; then ok "head binding [strict]: run --shard --head '${badhead:0:14}…' (prefix / case / char-40) refused, no result"; else bad "strict head $badhead (rc=$rc): $out"; fi
done
# a bad HEAD at char 40 as seen by the checkout: the sha one char off must not match the real checkout
for badhead in abc "${SHEAD:0:39}" "ZZ${SHEAD:2}"; do
  out="$("$CI" run --shard 0/1 --head "$badhead" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--head refused'; then ok "head binding: malformed --head '${badhead:0:12}' refused"; else bad "malformed head $badhead (rc=$rc): $out"; fi
done
out="$("$CI" run --head "$SHEAD" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'only applies to a --shard run'; then ok "head binding: --head without --shard refused"; else bad "--head w/o shard (rc=$rc): $out"; fi
# write site: HEAD moves during the run -> no result file, refusal named
cat > .localci <<'L'
if [ -n "${CI_SHARD_COUNT:-}" ]; then
  step "fingerprint" echo fixture-env
  step "shard-collect" ./stub.sh collect
  step "pytest" ./stub.sh run
  step "mover" bash -c 'git -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved'
fi
L
git add -A; gc -q -m cfg 2>/dev/null; CFGHEAD="$(git rev-parse HEAD)"
out="$("$CI" run --shard 0/1 --head "$CFGHEAD" 2>&1)"
if printf '%s' "$out" | grep -q 'REFUSED \[head-binding\]' && [ ! -e .portable-ci/shard-result.json ]; then ok "head binding [write site]: HEAD moved mid-run -> result refused, none written"; else bad "write site: $out"; fi
out="$("$CI" run --shard 0/1 2>&1)"
if printf '%s' "$out" | grep -q 'shard result: ' && [ -s .portable-ci/shard-result.json ]; then ok "head binding: an unbound shard run still writes its result (back-compat)"; else bad "unbound: $out"; fi

# ---- 6. head binding: the aggregator, one test per exit site --------------------------------------------------
cd "$SHARD_REPO" || exit 1
mk() { local d; d="$(mktemp -d "$WORK/hb.XXXX")"; cp "$WORK"/good/* "$d/"; printf '%s' "$d"; }
d="$(mk)"; sed -i 's|^  "head_sha": .*|  "head_sha": "2222222222222222222222222222222222222222",|' "$d/shard-result.json"
out="$("$CI" attest-merge --head "$SHEAD" "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSED \[A\]: head-binding: shard 0' && printf '%s' "$out" | grep -q 'stale shard result refused'; then ok "head binding [attest-merge, stale shard]: names the shard, its head, and 'stale shard result refused'"; else bad "stale shard (rc=$rc): $out"; fi
d="$(mk)"; sed -i 's|^  "head_sha": .*|  "head_sha": "",|' "$d/shard-result.json"
out="$("$CI" attest-merge --head "$SHEAD" "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'head-binding: .* records no head_sha'; then ok "head binding [attest-merge, empty head]: a result with no recorded head is refused by name"; else bad "empty head (rc=$rc): $out"; fi
d="$(mk)"; out="$("$CI" attest-merge --head 3333333333333333333333333333333333333333 "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'head-binding: shard 0'; then ok "head binding [attest-merge, --head differs from the shards]: refused by name"; else bad "head differs (rc=$rc): $out"; fi
d="$(mk)"; out="$("$CI" attest-merge "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--head <40-hex sha'; then ok "head binding [attest-merge, no --head]: refused (a shard set is never self-binding)"; else bad "no head (rc=$rc): $out"; fi
# strict equality in the aggregator: a 12-char prefix, and a case-only difference, are NOT the head
d="$(mk)"; sed -i "s|^  \"head_sha\": .*|  \"head_sha\": \"${SHEAD:0:12}\",|" "$d/shard-result.json"
out="$("$CI" attest-merge --head "$SHEAD" "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'head-binding: shard 0' && ! printf '%s' "$out" | grep -q 'attestation: passed'; then ok "head binding [attest-merge, strict]: a 12-char-prefix recorded head is refused"; else bad "prefix head (rc=$rc): $out"; fi
d="$(mk)"; up="$(printf '%s' "$SHEAD" | tr 'a-f' 'A-F')"; sed -i "s|^  \"head_sha\": .*|  \"head_sha\": \"$up\",|" "$d/shard-result.json"
out="$("$CI" attest-merge --head "$SHEAD" "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$up" != "$SHEAD" ] && [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'head-binding: shard 0'; then ok "head binding [attest-merge, strict]: an upper-cased recorded head is refused"; else bad "case head (rc=$rc): $out"; fi
d="$(mk)"; sed -i "s|^  \"head_sha\": .*|  \"head_sha\": \"${SHEAD:0:39}$altc\",|" "$d/shard-result.json"
out="$("$CI" attest-merge --head "$SHEAD" "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'head-binding: shard 0'; then ok "head binding [attest-merge, strict]: a head off by char 40 is refused"; else bad "char-40 head (rc=$rc): $out"; fi
# failed-attempt site: a stale red attempt
d="$(mk)"; a="$(mk)"
sed -i 's|^  "head_sha": .*|  "head_sha": "4444444444444444444444444444444444444444",|; s|^  "exit": .*|  "exit": 1,|; s|^  "verdict": .*|  "verdict": "FAILED",|; s|^  "failed_tests": .*|  "failed_tests": ["tests/test_a.py::test_one"],|' "$a/shard-result.json"
out="$("$CI" attest-merge --head "$SHEAD" --failed-attempt "$a/shard-result.json" "$d/shard-result.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'head-binding: failed attempt' && printf '%s' "$out" | grep -q 'stale attempt refused'; then ok "head binding [attest-merge, failed attempt]: a red attempt from another head is refused by name"; else bad "stale attempt (rc=$rc): $out"; fi

echo
printf 'affected/head-binding tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
