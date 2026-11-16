#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
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

# Upstream's own suite (test/*.sh, built by build.sh as mayhem/build/test): each script runs calcurse
# on known input and the run-test helper diffs its output against the script's golden "expected" text.
B="$SRC/mayhem/build/test"
[ -x "$B/src/calcurse" ] && [ -x "$B/test/run-test" ] || { echo "missing calcurse/run-test; build.sh did not produce them" >&2; emit_ctrf "calcurse-test" 0 1 0; exit 1; }

export TEST_INIT="$SRC/test/test-init.sh" CALCURSE="$B/src/calcurse" DATA_DIR="$SRC/test/data/"
# Some upstream tests are skipped by upstream itself (exit 0) without faketime; the image installs it.
command -v faketime >/dev/null || echo "WARN: faketime missing, date-dependent tests will self-skip" >&2

passed=0; failed=0
W="$B/test/work"; rm -rf "$W"; mkdir -p "$W"; ln -s "$B/test/run-test" "$W/run-test"
for t in "$SRC"/test/*.sh; do ln -s "$t" "$W/$(basename "$t")"; done
cd "$W"
for t in $(sed -n '/^TESTS *=/,/^$/p' "$SRC/test/Makefile.am" | tr -d '\\' | tr ' \t' '\n\n' | grep '\.sh$'); do
  if timeout 120 sh "./$t" >"$W/$t.log" 2>&1; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $t" >&2; tail -20 "$W/$t.log" >&2
  fi
done
emit_ctrf "calcurse-test" "$passed" "$failed" 0
