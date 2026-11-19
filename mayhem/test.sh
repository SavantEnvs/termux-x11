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

# Oracle: termux-x11's clipboard bridge (lorie/clipboard.c) end to end. mayhem/build.sh built
# mayhem/build/xvfb-lorie-test (normal flags): the pinned X server with lorie's clipboard hooks. Each
# case feeds one X11 client stream (mayhem/x11-client-clipboard/testsuite/<case>, made by
# mayhem/harness/mkseeds.py) and asserts the exact bytes lorie hands to the Android side
# (printed as `LORIE_CLIPBOARD_SEND <len> <hex>`): CRLF/CR -> LF, Latin-1 -> UTF-8, invalid UTF-8 -> "".
BIN="$SRC/mayhem/build/xvfb-lorie-test"
SEEDS="$SRC/mayhem/x11-client-clipboard/testsuite"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh" >&2; exit 2; }

run_case() {  # run_case <seed> -> lorie's clipboard sends on stdout
  timeout 60 "$BIN" :99 -nolisten tcp -nolisten unix -nolock -terminate -screen 0 640x480x24 \
      -fuzzinput "$SEEDS/$1" 2>/dev/null | grep '^LORIE_CLIPBOARD' || true
}

passed=0 failed=0
check() {  # check <seed> <expected output>
  local got; got=$(run_case "$1")
  if [ "$got" = "$2" ]; then passed=$((passed+1)); echo "PASS $1"
  else failed=$((failed+1)); echo "FAIL $1: expected [$2] got [$got]"; fi
}
# "hello\r\nworld\xe9" (STRING, Latin-1) -> "hello\nworld\xc3\xa9"
check string_clipboard  "LORIE_CLIPBOARD_SEND 13 68656c6c6f0a776f726c64c3a9"
# "caf\xc3\xa9\r\nx\ry" (UTF8_STRING) -> "caf\xc3\xa9\nx\ny"
check utf8_clipboard    "LORIE_CLIPBOARD_SEND 9 636166c3a90a780a79"
# "ab\xe2\x82" (truncated 3-byte sequence) is rejected -> ""
check utf8_truncated    "LORIE_CLIPBOARD_SEND 0 "
# no clipboard notification in the stream -> nothing sent
check intern_atoms      ""

emit_ctrf "lorie-clipboard" "$passed" "$failed" 0
