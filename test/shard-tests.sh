#!/usr/bin/env bash
# Tests for `ci run --shard I/K` and `ci attest-merge`.
#
# The aggregator is the merge gate's verdict machinery, so every identity check A..H
# has a test where ONE shard's evidence is altered to violate exactly that check and
# the aggregator must REFUSE naming it (a check whose violation does not refuse is a
# bug), plus an all-good test that must attest. test/shard-mutation.sh plants a fault
# per check and proves the matching test goes red.
#
# Fixture: a real git repo whose `.localci` is driven through `ci run --shard i/3`, so
# the producer and the aggregator are tested together. The "test runner" is a stub.
# shellcheck disable=SC2015  # ok() and bad() always return 0, so `cond && ok || bad` is a real if-else here
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="${SHARD_TEST_CI:-$ROOT/bin/ci}"
PASS=0; FAIL=0
NO_COLOR=1; export NO_COLOR
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PORTABLE_CI_RUNS_DIR="$WORK/runs"
export HOME="$WORK/home"; mkdir -p "$HOME"

# ---- fixture repo -----------------------------------------------------------
# Known answers, computed independently with Python: sha256(path) mod 3 is
#   tests/test_i.py -> 0, tests/test_a.py -> 1, tests/test_b.py -> 2
# tests/test_guard.py is a repo-wide guard: it runs once, in shard 0.
REPO="$WORK/repo"; ORIGIN="$WORK/origin.git"
git init -q --bare "$ORIGIN"
mkdir -p "$REPO/tests" && cd "$REPO" || exit 1
git init -q -b main . && git remote add origin "$ORIGIN"
cat > nodes.all <<'N'
tests/test_a.py::test_one
tests/test_a.py::test_two
tests/test_b.py::test_one
tests/test_b.py::test_two
tests/test_guard.py::test_repo_wide
tests/test_guard.py::test_ratchet
tests/test_i.py::test_one
tests/test_i.py::test_two
N
printf 'tests/test_a.py\t1\ntests/test_b.py\t2\ntests/test_guard.py\t0\ntests/test_i.py\t0\n' > plan.txt
cat > stub.sh <<'S'
#!/usr/bin/env bash
# stub test runner: stub.sh collect | run
d="$CI_SHARD_DIR"
case "$1" in
  collect)
    cp nodes.all "$d/collect.nodes"; cp plan.txt "$d/partition.plan"
    echo "-q -m not-live --dist loadfile" > "$d/pytest.args"; echo "7" > "$d/seed"
    echo "tests/test_guard.py" > "$d/guards.list"; echo "lint" > "$d/once.steps"; echo 0 > "$d/member.mode" ;;
  run)
    : > "$d/executed.nodes"
    while read -r f s; do
      if [ "$s" = "$CI_SHARD_INDEX" ]; then grep "^$f::" nodes.all >> "$d/executed.nodes"; fi
    done < plan.txt
    n="$(grep -c . "$d/executed.nodes")"
    printf 'passed=%s\nfailed=0\nerror=0\nskipped=0\nxfailed=0\nxpassed=0\n' "$n" > "$d/counts" ;;
esac
S
chmod +x stub.sh
cat > .localci <<'L'
# mirrors streamline's .localci: the shard branch only when CI_SHARD_COUNT is set
if [ -n "${CI_SHARD_COUNT:-}" ]; then
  [ "${CI_SHARD_INDEX:-0}" = 0 ] && step "lint" true
  step "fingerprint" echo "python 3.12.8 fixture-env"
  step "shard-collect" ./stub.sh collect
  step "pytest" ./stub.sh run
else
  step "lint" true
  step "pytest" true
fi
L
git add -A && git -c user.email=t@t -c user.name=t commit -q -m fixture && git push -q origin main 2>/dev/null
HEADSHA="$(git rev-parse HEAD)"

BASE="$WORK/base"; mkdir -p "$BASE"
for i in 0 1 2; do
  "$CI" run --shard "$i/3" > "$WORK/run$i.log" 2>&1 || { bad "fixture: shard $i run failed"; cat "$WORK/run$i.log"; }
  mkdir -p "$BASE/s$i" && cp .portable-ci/shard-result.json .portable-ci/shard-*.nodes .portable-ci/shard-partition.plan "$BASE/s$i/"
done

# fresh copy of the good shard results; prints its directory
copy_base() { local d; d="$(mktemp -d "$WORK/case.XXXX")"; cp -R "$BASE"/s0 "$BASE"/s1 "$BASE"/s2 "$d/"; printf '%s' "$d"; }
# --head is mandatory; a caller's own --head (later on the line) overrides the default.
merge() { local d="$1"; shift; "$CI" attest-merge --head "$HEADSHA" "$@" "$d/s0/shard-result.json" "$d/s1/shard-result.json" "$d/s2/shard-result.json" 2>&1; }
# set a scalar field of shard $2 in case dir $1:  setf DIR N key 'raw json value'
setf() { sed -i "s|^  \"$3\": .*|  \"$3\": $4,|" "$1/s$2/shard-result.json"; }
# expect REFUSED naming check $2 (and exit non-zero), no attestation line
expect_refuse() {
  local label="$1" code="$2" out rc; shift 2
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "REFUSED \[$code\]" && ! printf '%s' "$out" | grep -q 'attestation: passed'; then
    ok "check $code: $label -> REFUSED [$code]"
  else bad "check $code: $label (rc=$rc) $(printf '%s' "$out" | head -2)"; fi
}

# ---- producer ---------------------------------------------------------------
j="$BASE/s1/shard-result.json"
if grep -q "\"head_sha\": \"$HEADSHA\"" "$j" && grep -q '"shard_index": 1,' "$j" && grep -q '"shard_count": 3,' "$j" \
   && grep -q '"tree_clean": true,' "$j" && grep -q '"tree_clean_start": true,' "$j" && grep -q '"behind_main": "false",' "$j" \
   && grep -q '"exit": 0,' "$j" && grep -q '"counts": {"passed": 2, "failed": 0' "$j"; then
  ok "producer: result JSON carries sha, shard, clean tree, behind_main, exit, counts"
else bad "producer fields: $(cat "$j")"; fi
fp0="$(sed -n 's/^  "env_fingerprint": "\(.*\)",/\1/p' "$BASE/s0/shard-result.json")"
exp_fp="$(printf 'python 3.12.8 fixture-env\n' | sha256sum | cut -d' ' -f1)"
if [ "$fp0" = "$exp_fp" ]; then ok "producer: env_fingerprint is sha256 of the fingerprint step's output"; else bad "fingerprint $fp0 != $exp_fp"; fi
exp_ch="$(LC_ALL=C sort "$REPO/nodes.all" | sha256sum | cut -d' ' -f1)"
if grep -q "\"collect_hash\": \"$exp_ch\"" "$j"; then ok "producer: collect_hash is sha256 of the sorted collected node ids"; else bad "collect_hash"; fi
if grep -q '"step_results": {"fingerprint": "pass", "shard-collect": "pass", "pytest": "pass"}' "$j" \
   && grep -q '"step_results": {"lint": "pass", "fingerprint"' "$BASE/s0/shard-result.json"; then
  ok "producer: step_results recorded (lint only in shard 0)"
else bad "step_results: $(grep step_results "$j" "$BASE/s0/shard-result.json")"; fi

# ---- all good: attests ------------------------------------------------------
d="$(copy_base)"; out="$(merge "$d" --head "$HEADSHA")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE "^portable-ci attestation: passed @ ${HEADSHA:0:12} · 2/2 checks · sharded K=3 partition=[0-9a-f]{12} env=${fp0:0:12} seed=7 · aggregator portable-ci@[0-9.]+/[0-9a-f]{12}\$"; then
  ok "all-good: ONE attestation line (2/2 checks, fingerprint and shard-* plumbing not counted, sharded K=3 partition= env=, aggregator version)"
else bad "all-good (rc=$rc): $out"; fi
printf '%s' "$out" | grep -q '^shard-results (sha256 json/json+lists, post these): shard0=[0-9a-f]\{12\}/[0-9a-f]\{12\} shard1=[0-9a-f]\{12\}/[0-9a-f]\{12\} shard2=[0-9a-f]\{12\}/[0-9a-f]\{12\}$' \
  && ok "all-good: per-shard result digests printed (H audit trail)" || bad "digests: $out"
# order of arguments must not matter
out2="$("$CI" attest-merge --head "$HEADSHA" "$d/s2/shard-result.json" "$d/s0/shard-result.json" "$d/s1/shard-result.json" 2>&1)"
[ "$(printf '%s' "$out" | head -1)" = "$(printf '%s' "$out2" | head -1)" ] && ok "all-good: argument order does not change the attestation" || bad "order: $out2"

# ---- A: same commit -----------------------------------------------------------
d="$(copy_base)"; setf "$d" 2 head_sha '"0000000000000000000000000000000000000000"'
expect_refuse "one shard at a different 40-char head" A merge "$d"
d="$(copy_base)"; expect_refuse "head differs from the head being attested" A merge "$d" --head 1111111111111111111111111111111111111111
d="$(copy_base)"; setf "$d" 1 head_sha '"abc123"'
expect_refuse "head_sha is not 40 hex chars" A merge "$d"
d="$(copy_base)"; setf "$d" 1 tree_clean false
expect_refuse "tree dirty at the end of a shard" A merge "$d"
d="$(copy_base)"; setf "$d" 0 tree_clean_start false
expect_refuse "tree dirty at the start of a shard" A merge "$d"
d="$(copy_base)"; setf "$d" 2 behind_main '"true"'
expect_refuse "head is behind the remote main" A merge "$d"
d="$(copy_base)"; setf "$d" 2 behind_main '"unknown"'
expect_refuse "behind-main could not be established" A merge "$d"

# ---- B: same environment ----------------------------------------------------
d="$(copy_base)"; setf "$d" 1 env_fingerprint "\"$(printf '%s' "$fp0" | sed 's/^./f/;s/^ff/fe/')\""
expect_refuse "one shard's environment fingerprint differs by a byte" B merge "$d"
d="$(copy_base)"; setf "$d" 2 env_fingerprint '""'
expect_refuse "no fingerprint recorded" B merge "$d"

# ---- C: same collection -----------------------------------------------------
d="$(copy_base)"; setf "$d" 1 collect_hash "\"$(printf '%064d' 7)\""
expect_refuse "one shard recorded a different collect hash" C merge "$d"
d="$(copy_base)"; sed -i '1d' "$d/s2/shard-collect.nodes"
expect_refuse "a shard's shipped collection no longer matches its recorded hash" C merge "$d"

# ---- D: a true partition ----------------------------------------------------
# keep the recorded hash/counts consistent so ONLY the partition is wrong.
resum() { # DIR N : recompute executed hash and counts for shard N from its list
  local f="$1/s$2/shard-executed.nodes" h n
  h="$(LC_ALL=C sort "$f" | sha256sum | cut -d' ' -f1)"; n="$(grep -c . "$f")"
  setf "$1" "$2" executed_nodes_hash "\"$h\""
  setf "$1" "$2" counts "{\"passed\": $n, \"failed\": 0, \"error\": 0, \"skipped\": 0, \"xfailed\": 0, \"xpassed\": 0}"
}
d="$(copy_base)"; sed -i '1d' "$d/s2/shard-executed.nodes"; resum "$d" 2
expect_refuse "a node id dropped from one shard (hash and counts consistent)" D merge "$d"
d="$(copy_base)"; sed -i '1d' "$d/s2/shard-executed.nodes"
expect_refuse "a node id deleted from the executed list without fixing the hash" D merge "$d"
d="$(copy_base)"; head -1 "$d/s1/shard-executed.nodes" >> "$d/s2/shard-executed.nodes"; resum "$d" 2
expect_refuse "a node id executed in two shards" D merge "$d"
d="$(copy_base)"; echo 'tests/test_zzz.py::test_extra' >> "$d/s2/shard-executed.nodes"; resum "$d" 2
expect_refuse "a node id executed that was never collected" D merge "$d"
d="$(copy_base)"; setf "$d" 1 counts '{"passed": 1, "failed": 0, "error": 0, "skipped": 0, "xfailed": 0, "xpassed": 0}'
expect_refuse "counts do not reconcile with the executed node ids" D merge "$d"
d="$(copy_base)"; setf "$d" 1 partition_hash "\"$(printf '%064d' 9)\""
expect_refuse "partition_hash differs between shards" D merge "$d"
d="$(copy_base)"; # swap which shard ran test_a/test_b: lists are whole and consistent, but files are in the wrong shard
cp "$d/s1/shard-executed.nodes" "$WORK/swap"; cp "$d/s2/shard-executed.nodes" "$d/s1/shard-executed.nodes"; cp "$WORK/swap" "$d/s2/shard-executed.nodes"
resum "$d" 1; resum "$d" 2
expect_refuse "files executed in the wrong shard (sha256 mod K)" D merge "$d"

# ---- E: same pytest behaviour -----------------------------------------------
d="$(copy_base)"; setf "$d" 1 seed '"8"'
expect_refuse "one shard ran with a different seed" E merge "$d"
d="$(copy_base)"; setf "$d" 2 pytest_args '"-q -m not-live --dist load"'
expect_refuse "one shard ran with different pytest args" E merge "$d"
d="$(copy_base)"; setf "$d" 0 seed '""'; setf "$d" 1 seed '""'; setf "$d" 2 seed '""'
expect_refuse "no explicit seed recorded" E merge "$d"

# ---- F: guards run once -----------------------------------------------------
d="$(copy_base)"; # the guard file's nodes move from shard 0 to shard 1: still a perfect partition by count
grep '^tests/test_guard.py::' "$d/s0/shard-executed.nodes" >> "$d/s1/shard-executed.nodes"
sed -i '/^tests\/test_guard.py::/d' "$d/s0/shard-executed.nodes"; resum "$d" 0; resum "$d" 1
expect_refuse "guard tests ran in shard 1 instead of the guards shard" F merge "$d"
d="$(copy_base)"; sed -i 's|^  "step_results": {|  "step_results": {"lint": "pass", |' "$d/s1/shard-result.json"
expect_refuse "a run-once step (lint) also ran in shard 1" F merge "$d"
d="$(copy_base)"; setf "$d" 2 guard_files '["tests/test_guard.py", "tests/test_b.py"]'
expect_refuse "guard file lists differ between shards" F merge "$d"
d="$(copy_base)"; sed -i 's|"lint": "pass", ||' "$d/s0/shard-result.json"
expect_refuse "the run-once step never ran in shard 0" F merge "$d"

# ---- G: every shard has a verdict -------------------------------------------
d="$(copy_base)"; expect_refuse "only two of three shard results supplied" G "$CI" attest-merge --head "$HEADSHA" "$d/s0/shard-result.json" "$d/s1/shard-result.json"
d="$(copy_base)"; expect_refuse "a shard result file does not exist (shard killed)" G "$CI" attest-merge --head "$HEADSHA" "$d/s0/shard-result.json" "$d/s1/shard-result.json" "$d/s9/shard-result.json"
d="$(copy_base)"; setf "$d" 2 exit 1
expect_refuse "a shard exited non-zero" G merge "$d"
d="$(copy_base)"; setf "$d" 1 verdict '"FAILED"'
expect_refuse "a shard's verdict is FAILED" G merge "$d"
d="$(copy_base)"; sed -i 's|"pytest": "pass"|"pytest": "FAIL"|' "$d/s1/shard-result.json"
expect_refuse "a shard has a failed step" G merge "$d"
d="$(copy_base)"; expect_refuse "the same shard supplied twice" G "$CI" attest-merge --head "$HEADSHA" "$d/s0/shard-result.json" "$d/s1/shard-result.json" "$d/s1/shard-result.json"
d="$(copy_base)"; : > "$d/s2/shard-result.json"
expect_refuse "an empty result file (killed mid-write)" G merge "$d"

# ---- H: provenance ----------------------------------------------------------
d="$(copy_base)"; setf "$d" 1 portable_ci_version '"0.0.1"'
expect_refuse "shards produced by different portable-ci versions" H merge "$d"
d="$(copy_base)"; setf "$d" 2 schema 2
expect_refuse "unknown result schema" H merge "$d"
d="$(copy_base)"; setf "$d" 0 kind '"something-else"'
expect_refuse "not a shard result" H merge "$d"


# ---- review R-SHARD fold: isolating and added controls ------------------------
# A: --head is mandatory; no all-shards-at-an-old-head attestation
d="$(copy_base)"; expect_refuse "no --head given" A "$CI" attest-merge "$d/s0/shard-result.json" "$d/s1/shard-result.json" "$d/s2/shard-result.json"
d="$(copy_base)"; expect_refuse "--head is a 12-char prefix" A merge "$d" --head "${HEADSHA:0:12}"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n head_sha "\"${HEADSHA:0:12}\""; done
expect_refuse "ALL shards at a 12-char head (isolates the 40-hex condition)" A merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n head_sha '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'; done
expect_refuse "ALL shards consistently at an older head" A merge "$d"
orphan="$(git -c user.email=t@t -c user.name=t commit-tree "$(git hash-object -t tree /dev/null)" -m unrelated)"
d="$(copy_base)"; expect_refuse "head is behind the current remote main at attest time" A merge "$d" --main "$orphan"
d="$(copy_base)"; expect_refuse "current remote main cannot be established" A merge "$d" --main 0000000000000000000000000000000000000000
d="$(copy_base)"; out="$(merge "$d" --no-main-check)"
printf '%s' "$out" | grep -q '^portable-ci attestation: passed' && ok "--no-main-check is an explicit opt-out (still attests)" || bad "--no-main-check: $out"
d="$(copy_base)"; sed -i 's|^  "tree_clean": true,|  "tree_clean": "true",|' "$d/s1/shard-result.json"
expect_refuse "tree_clean as the string \"true\" (type-strict)" A merge "$d"
d="$(copy_base)"; sed -i 's|^  "behind_main": "false",|  "behind_main": false,|' "$d/s1/shard-result.json"
expect_refuse "behind_main as a bare literal (type-strict)" A merge "$d"
# C: collect_hash equality isolated (hash consistent with the shipped list)
d="$(copy_base)"; echo 'tests/test_extra.py::test_x' >> "$d/s2/shard-collect.nodes"
setf "$d" 2 collect_hash "\"$(LC_ALL=C sort "$d/s2/shard-collect.nodes" | sha256sum | cut -d' ' -f1)\""
expect_refuse "one shard collected an extra node (its own hash consistent)" C merge "$d"
# D: union == collected isolated (same file, one node renamed, totals equal)
d="$(copy_base)"; sed -i 's/test_two$/test_twoX/' "$d/s1/shard-executed.nodes"; resum "$d" 1
expect_refuse "same-file node substitution with equal totals" D merge "$d"
d="$(copy_base)"; setf "$d" 1 counts '{"passed": "2", "failed": 0, "error": 0, "skipped": 0, "xfailed": 0, "xpassed": 0}'
expect_refuse "counts with a string where an integer belongs" G merge "$d"
# G: counts must be green; verdict must name flakes; steps are an allowlist
d="$(copy_base)"; setf "$d" 1 counts '{"passed": 1, "failed": 1, "error": 0, "skipped": 0, "xfailed": 0, "xpassed": 0}'
expect_refuse "counts show a failed test though exit is 0 (totals still reconcile)" G merge "$d"
d="$(copy_base)"; setf "$d" 1 counts '{"passed": 1, "failed": 0, "error": 1, "skipped": 0, "xfailed": 0, "xpassed": 0}'
expect_refuse "counts show an errored test though exit is 0" G merge "$d"
d="$(copy_base)"; setf "$d" 1 counts '{"passed": null, "failed": 0, "error": 0, "skipped": 0, "xfailed": 0, "xpassed": 0}'
expect_refuse "a null count (totals no longer reconcile)" D merge "$d"
d="$(copy_base)"; setf "$d" 1 verdict '"passed-on-rerun"'; setf "$d" 1 flaked '""'
expect_refuse "passed-on-rerun that names nothing" G merge "$d"
d="$(copy_base)"; setf "$d" 1 verdict '"passed-on-rerun"'; setf "$d" 1 flaked '"unknown"'
expect_refuse "passed-on-rerun that says only unknown" G merge "$d"
d="$(copy_base)"; sed -i 's|"pytest": "pass"|"pytest": "skipped"|' "$d/s1/shard-result.json"
expect_refuse "a step with status skipped" G merge "$d"
d="$(copy_base)"; sed -i 's|, "pytest": "pass"||' "$d/s1/shard-result.json"
expect_refuse "the pytest step is absent from one shard" G merge "$d"
d="$(copy_base)"; for n in 0 1 2; do sed -i 's|^  "step_results": {|  "step_results": {"review": "advisory-fail", |' "$d/s$n/shard-result.json"; done
out="$(merge "$d")"; printf '%s' "$out" | grep -q '^portable-ci attestation: passed' && ok "an advisory finding does not refuse (same as an unsharded run)" || bad "advisory: $out"
# H: provenance
d="$(copy_base)"; sed -i 's|^  "exit": 0,|  "exit": 0,\n  "exit": 1,|' "$d/s1/shard-result.json"
expect_refuse "duplicate key (exit 0 then exit 1) is read differently by jq" H merge "$d"
d="$(copy_base)"; setf "$d" 1 collect_nodes_file '"../s0/shard-collect.nodes"'
expect_refuse "node-list file name taken from the JSON (path traversal)" H merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n portable_ci_version '"0.0.1"'; done
expect_refuse "every shard from a runner that is not this aggregator's version" H merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n portable_ci_version '""'; done
expect_refuse "empty runner version on every shard" H merge "$d"
# F: the guard match is anchored at the start of the node id
src="$(sed -n '/^_ag_has_file()/p' "$CI")"
printf 'xtests/test_guard.py::t\nother/tests/test_guard.py::t\n' > "$WORK/nodes.sub"
printf 'tests/test_guard.py::t\n' > "$WORK/nodes.exact"
if ! bash -c "$src; _ag_has_file tests/test_guard.py $WORK/nodes.sub" && bash -c "$src; _ag_has_file tests/test_guard.py $WORK/nodes.exact"; then
  ok "check F: guard match is anchored (substring paths do not count)"; else bad "check F anchoring"; fi
# an inherited shard environment must not turn an UNSHARDED run into a subset (finding 4)
rm -rf .portable-ci; out="$(CI_SHARD_COUNT=3 CI_SHARD_INDEX=1 CI_SHARD_DIR="$WORK/leak" "$CI" run 2>&1)"
if printf '%s' "$out" | grep -q '▶ lint' && [ ! -e .portable-ci/shard-result.json ] && [ ! -e "$WORK/leak" ]; then
  ok "unsharded run ignores inherited CI_SHARD_* (full step set, no shard output)"; else bad "env leak: $out"; fi

# ---- sites that stayed green when silenced individually (shard-mutation.sh sites): isolating tests ----
d="$(copy_base)"; ( cd "$WORK" && expect_refuse "no remote main can be established (not in a clone, no --main)" A "$CI" attest-merge --head "$HEADSHA" "$d/s0/shard-result.json" "$d/s1/shard-result.json" "$d/s2/shard-result.json" )
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n env_fingerprint '""'; done
expect_refuse "no fingerprint on ANY shard" B merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n env_fingerprint '"abcdef0123456789"'; done
expect_refuse "the same short non-sha256 fingerprint on every shard" B merge "$d"
d="$(copy_base)"; rm "$d/s1/shard-collect.nodes"
expect_refuse "one shard's collected node list is missing" C merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n pytest_args '""'; done
expect_refuse "no pytest_args on any shard" E merge "$d"
d="$(copy_base)"; setf "$d" 1 shard_count 4
expect_refuse "shard_count differs in one shard" G merge "$d"
d="$(copy_base)"; setf "$d" 1 shard_index '"x"'
expect_refuse "non-numeric shard_index" G merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n step_results '{}'; setf "$d" $n once_steps '[]'; done
expect_refuse "no steps recorded on any shard" G merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n shard_count '"x"'; done
expect_refuse "shard_count is not a number on any shard" G merge "$d"
d="$(copy_base)"; for n in 0 1 2; do setf "$d" $n partition_hash '""'; done
expect_refuse "no partition_hash on any shard" D merge "$d"
d="$(copy_base)"; setf "$d" 2 once_steps '["lint", "mypy"]'
expect_refuse "once_steps lists differ between shards" F merge "$d"

# ---- review OPUS-SHARD fold ---------------------------------------------------
# 1 HIGH: a shard run's own line must not carry the attestation prefix (a judge gate keyed on it would accept 1/K of a suite)
if ! grep -q 'portable-ci attestation:' "$WORK/run1.log" && grep -q '^portable-ci shard-result: passed @ [0-9a-f]\{12\} · [0-9]/[0-9] checks · shard 1/3 · NOT a verdict' "$WORK/run1.log"; then
  ok "shard run prints a shard-result line, never the 'portable-ci attestation:' prefix"
else bad "shard line: $(grep -a 'portable-ci' "$WORK/run1.log" | tail -2)"; fi
# 4 MED: version is bumped past the released 0.9.0
case "$("$CI" --version)" in "portable-ci 0.9."*|"portable-ci 0.8."*) bad "VERSION not bumped past 0.9.x" ;; *) ok "VERSION is past the released 0.9.0 (shard-capable installs are distinguishable)" ;; esac
# 2 MED: attempt history
mkattempt() { # DIR N exit failed_tests_json -> writes DIR/att.json from base shard N
  cp "$BASE/s$2/shard-result.json" "$1/att.json"
  sed -i "s|^  \"exit\": .*|  \"exit\": $3,|; s|^  \"verdict\": .*|  \"verdict\": \"FAILED\",|; s|^  \"failed_tests\": .*|  \"failed_tests\": $4,|" "$1/att.json"
}
d="$(copy_base)"; mkattempt "$d" 1 1 '["tests/test_a.py::test_one"]'
out="$(merge "$d" --failed-attempt "$d/att.json")"
printf '%s' "$out" | grep -q '^portable-ci attestation: passed-on-rerun @ .* · flaked: shard 1: tests: tests/test_a.py::test_one · aggregator' \
  && ok "failed attempt supplied: attested as passed-on-rerun, naming shard and test" || bad "failed attempt: $out"
d="$(copy_base)"; mkattempt "$d" 1 1 '[]'
expect_refuse "failed attempt that names no failing test" G merge "$d" --failed-attempt "$d/att.json"
d="$(copy_base)"; mkattempt "$d" 1 0 '["t::x"]'; sed -i 's|^  "verdict": .*|  "verdict": "passed",|' "$d/att.json"
expect_refuse "an 'attempt' that actually passed" G merge "$d" --failed-attempt "$d/att.json"
d="$(copy_base)"; mkattempt "$d" 1 1 '["t::x"]'; sed -i 's|^  "head_sha": .*|  "head_sha": "1111111111111111111111111111111111111111",|' "$d/att.json"
expect_refuse "failed attempt from a different head" A merge "$d" --failed-attempt "$d/att.json"
d="$(copy_base)"; mkattempt "$d" 1 1 '["t::x"]'; sed -i 's|^  "shard_count": .*|  "shard_count": 4,|' "$d/att.json"
expect_refuse "failed attempt from a different shard count" G merge "$d" --failed-attempt "$d/att.json"
d="$(copy_base)"; expect_refuse "failed attempt file missing" G merge "$d" --failed-attempt "$d/nope.json"
# 8 LOW: member mode is recorded and not aggregable
grep -q '"member_mode": "0",' "$BASE/s1/shard-result.json" && ok "producer records member_mode from the evidence file" || bad "member_mode not recorded"
d="$(copy_base)"; setf "$d" 1 member_mode '"1"'
expect_refuse "a shard ran in negatives member mode" A merge "$d"
grep -q '"failed_tests": \[\],' "$BASE/s1/shard-result.json" && ok "producer records failed_tests (empty on a green shard)" || bad "failed_tests field"
# survivors: a duplicated id inside one shard's list with hash and counts edited to match
d="$(copy_base)"; dupline="$(head -1 "$d/s1/shard-executed.nodes")"; echo "$dupline" >> "$d/s1/shard-executed.nodes"; resum "$d" 1
expect_refuse "an id duplicated inside one shard (hash and counts consistent)" D merge "$d"

# ---- passed-on-rerun is named, not hidden -----------------------------------
d="$(copy_base)"; setf "$d" 1 verdict '"passed-on-rerun"'; setf "$d" 1 flaked '"pytest; tests: tests/test_a.py::test_one"'
out="$(merge "$d")"
if printf '%s' "$out" | grep -q '^portable-ci attestation: passed-on-rerun @ .* · flaked: shard 1: pytest; tests: tests/test_a.py::test_one · aggregator'; then
  ok "passed-on-rerun: attested as the WEAKER verdict, naming shard and test"
else bad "passed-on-rerun: $out"; fi

# ---- a refusal prints nothing on stdout -------------------------------------
d="$(copy_base)"; setf "$d" 2 exit 1
if [ -z "$("$CI" attest-merge --head "$HEADSHA" "$d"/s?/shard-result.json 2>/dev/null)" ]; then ok "a refusal writes nothing to stdout"; else bad "stdout on refusal"; fi

# ---- known answer: sha256(path) mod K (independent of the fixture) ----------
src="$(sed -n '/^_path_shard()/,/^}/p' "$CI"; sed -n '/^_sha256()/,/^}/p' "$CI")"
ka="$(bash -c "$src; for a in 'tests/test_a.py 3' 'tests/test_a.py 4' 'tests/test_d.py 2' 'x 1'; do _path_shard \$a; echo; done" | paste -sd' ' -)"
[ "$ka" = "1 3 0 0" ] && ok "known answer: _path_shard matches Python's int(sha256) % K" || bad "_path_shard: $ka"

# ---- CLI surface ------------------------------------------------------------
cd "$REPO" || exit 1
for bad_arg in "3/3" "x/3" "1" "0/0" "1/"; do
  if "$CI" run --shard "$bad_arg" --list >/dev/null 2>&1; then bad "--shard $bad_arg should be refused"; else ok "--shard $bad_arg refused"; fi
done
"$CI" run --shard 0/3 --since HEAD >/dev/null 2>&1; [ $? -eq 2 ] && ok "--shard with --since refused (exit 2)" || bad "--shard --since"
out="$("$CI" run --shard 0/3 --list 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'shard-result' && ok "--shard --list plans without running or writing a result" || bad "--list: $out"
# an unsharded run is untouched: no shard file, no shard suffix
rm -rf .portable-ci; out="$("$CI" run 2>&1)"
if [ ! -e .portable-ci/shard-result.json ] && ! printf '%s' "$out" | grep -q 'shard'; then ok "unsharded run: no shard output at all"; else bad "unsharded run leaked shard output: $out"; fi

echo
printf 'shard tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
