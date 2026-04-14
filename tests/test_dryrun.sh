#!/bin/bash
set -e
set -u

# Tests for lib/dryrun.sh — dry_run_exec, agent_output, exit codes
TESTS_RUN=0
TESTS_PASSED=0
TEST_RAND=$RANDOM

LIB_DIR="${LIB_DIR:-$(dirname "$0")/../lib}"
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/dryrun.sh"

assert() {
    local desc="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

# ── is_dry_run ──
DRY_RUN=0
assert "is_dry_run returns 1 when DRY_RUN=0" "1" "$(is_dry_run && echo 0 || echo 1)"

DRY_RUN=1
assert "is_dry_run returns 0 when DRY_RUN=1" "0" "$(is_dry_run && echo 0 || echo 1)"

# ── dry_run_exec (dry-run mode) ──
DRY_RUN=1
OUTPUT=$(dry_run_exec "Test operation" echo "hello" 2>&1)
assert "dry_run_exec in DRY_RUN=1 prints description" "1" "$(echo "$OUTPUT" | grep -c 'Test operation')"
assert "dry_run_exec in DRY_RUN=1 prints command" "1" "$(echo "$OUTPUT" | grep -c 'echo')"

_rc=0
dry_run_exec "Test" echo "hello" >/dev/null 2>&1 || _rc=$?
assert "dry_run_exec in DRY_RUN=1 returns 0" "0" "$_rc"

# Verify no actual execution (file should not exist)
_tmpfile="/tmp/dryrun_test_${TEST_RAND}"
dry_run_exec "Create temp" touch "$_tmpfile" >/dev/null 2>&1
assert "dry_run_exec in DRY_RUN=1 does not execute command" "1" "$([ -f "$_tmpfile" ] && echo 0 || echo 1)"
rm -f "$_tmpfile" 2>/dev/null || true

# ── dry_run_exec (normal mode) ──
DRY_RUN=0
_tmpfile="/tmp/dryrun_test_${TEST_RAND}"
dry_run_exec "Create temp file" touch "$_tmpfile" >/dev/null 2>&1
assert "dry_run_exec in DRY_RUN=0 executes command" "0" "$([ -f "$_tmpfile" ] && echo 0 || echo 1)"
rm -f "$_tmpfile"

_rc=0
dry_run_exec "Failing command" false >/dev/null 2>&1 || _rc=$?
assert "dry_run_exec in DRY_RUN=0 propagates exit code" "1" "$_rc"

# ── escape_json ──
assert "escape_json escapes backslash" 'a\\\\b' "$(escape_json 'a\\b')"
assert "escape_json escapes double quote" 'a\"b' "$(escape_json 'a"b')"
assert "escape_json handles empty" '' "$(escape_json '')"

# ── agent_output (JSON mode) ──
JSON_OUTPUT=1
AGENT_MODE=1
OUTPUT=$(agent_output "confirm" "Test Title" "yes" 2>/dev/null)
assert "agent_output JSON has type field" "1" "$(echo "$OUTPUT" | grep -c '"type":"confirm"')"
assert "agent_output JSON has title field" "1" "$(echo "$OUTPUT" | grep -c '"title":"Test Title"')"
assert "agent_output JSON has value field" "1" "$(echo "$OUTPUT" | grep -c '"value":"yes"')"

# ── agent_output (non-JSON mode) ──
JSON_OUTPUT=0
OUTPUT=$(agent_output "confirm" "Test" "yes" 2>&1)
assert "agent_output non-JSON logs [AGENT]" "1" "$(echo "$OUTPUT" | grep -c '\[AGENT\]')"

# ── exit code constants ──
assert "E_SUCCESS is 0" "0" "$E_SUCCESS"
assert "E_GENERAL is 1" "1" "$E_GENERAL"
assert "E_USAGE is 2" "2" "$E_USAGE"
assert "E_DRY_RUN_OK is 11" "11" "$E_DRY_RUN_OK"
assert "E_AGENT_PARAM is 12" "12" "$E_AGENT_PARAM"
assert "E_AGENT_DENIED is 13" "13" "$E_AGENT_DENIED"

# ── agent_confirm ──
AGENT_MODE=1
CONFIRM_YES=1
agent_confirm "Test" "Proceed" >/dev/null 2>&1 || true
assert "agent_confirm with CONFIRM_YES=1 returns 0" "0" "$(agent_confirm "Test" "Proceed" >/dev/null 2>&1; echo $?)"

CONFIRM_YES=0
agent_confirm "Test" "Proceed" >/dev/null 2>&1 || true
assert "agent_confirm with CONFIRM_YES=0 returns 1" "1" "$(agent_confirm "Test" "Proceed" >/dev/null 2>&1; echo $?)"

AGENT_MODE=0
agent_confirm "Test" "Proceed" >/dev/null 2>&1 || true
assert "agent_confirm without AGENT_MODE returns 2" "2" "$(agent_confirm "Test" "Proceed" >/dev/null 2>&1; echo $?)"

# Cleanup
unset DRY_RUN AGENT_MODE JSON_OUTPUT CONFIRM_YES

echo ""
echo "Results: $TESTS_PASSED passed, $((TESTS_RUN - TESTS_PASSED)) failed"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ] && echo "  PASS" || echo "  FAIL"
exit $([ "$TESTS_PASSED" -eq "$TESTS_RUN" ] && echo 0 || echo 1)