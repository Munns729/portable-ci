#!/usr/bin/env bash
# Plant a fault in the aggregator for each identity check A..H (the check can no
# longer fail) and prove test/shard-tests.sh goes red on that check's own tests.
# A check whose removal leaves its tests green is not tested (positive-control rule).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
rc=0
for c in A B C D E F G H; do
  mut="$W/ci-$c"
  # The fault: _ag_fail (and _ag_incomplete's G) silently drop failures of check $c.
  sed "s/^_ag_fail() { AG_FAILS+=(\"\$1|\$2\"); }/_ag_fail() { [ \"\$1\" = $c ] \&\& return 0; AG_FAILS+=(\"\$1|\$2\"); }/" "$ROOT/bin/ci" > "$mut"
  if cmp -s "$mut" "$ROOT/bin/ci"; then echo "MUTATION NOT APPLIED for $c"; rc=1; continue; fi
  chmod +x "$mut"
  out="$(SHARD_TEST_CI="$mut" "$ROOT/test/shard-tests.sh" 2>&1)"
  red="$(printf '%s\n' "$out" | grep -c "^  FAIL check $c:" || true)"
  other="$(printf '%s\n' "$out" | grep "^  FAIL check [A-H]:" | grep -vc "^  FAIL check $c:" || true)"
  if [ "$red" -gt 0 ]; then echo "check $c: fault planted -> $red of its test(s) went red (other checks' tests red: $other)"
  else echo "check $c: fault planted but NO test of check $c went red -> the check is untested"; rc=1; fi
done
exit $rc
