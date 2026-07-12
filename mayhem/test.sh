#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pgpdump's own upstream test suite (already built by mayhem/build.sh).
# The suite is the same one `make check` drives: the TAP runner test/test executes
# `pgpdump -u <input>` for every test/*.res case and diffs stdout against the golden .res
# output — a behavioral golden-output oracle, not an exit-status check.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# The upstream TAP runner drives the pre-built oracle binary; do NOT build here.
ORACLE="$SRC/build-oracle/pgpdump"
if [ ! -x "$ORACLE" ]; then
  echo "FATAL: $ORACLE missing — mayhem/build.sh must build the oracle binary" >&2
  emit_ctrf "pgpdump-tap" 0 1
  exit 1
fi

out="$(PGPDUMP="$ORACLE" sh test/test test/*.res 2>&1)"; rc=$?
echo "$out" | tail -n 25

passed=$(echo "$out" | grep -cE '^ok [0-9]+')
failed=$(echo "$out" | grep -cE '^not ok [0-9]+')
if echo "$out" | grep -q '^Bail out!'; then
  echo "FATAL: TAP runner bailed out (rc=$rc)" >&2
  emit_ctrf "pgpdump-tap" 0 1
  exit 1
fi
if [ "$(( passed + failed ))" -eq 0 ]; then
  echo "FATAL: could not parse TAP results (rc=$rc)" >&2
  emit_ctrf "pgpdump-tap" 0 1
  exit 1
fi

emit_ctrf "pgpdump-tap" "$passed" "$failed"
