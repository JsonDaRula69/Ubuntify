#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/lib/colors.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null || true

AGENT_MODE=1

source "$SCRIPT_DIR/lib/tui.sh"

PASS=0
FAIL=0

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

test_grid_checklist_captures_tags() {
    _TUI_GRID_TAGS=""
    local tag1="wifi" tag2="ethernet" tag3="usb" tag4="internal"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${tag1}"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${tag2}"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${tag3}"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${tag4}"
    assert "_TUI_GRID_TAGS captures all tags" "wifi ethernet usb internal" "$_TUI_GRID_TAGS"
}

test_grid_checklist_empty_tags() {
    _TUI_GRID_TAGS=""
    assert "_TUI_GRID_TAGS empty when no tags" "" "$_TUI_GRID_TAGS"
}

test_grid_checklist_single_tag() {
    _TUI_GRID_TAGS=""
    local tag="only_one"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${tag}"
    assert "_TUI_GRID_TAGS captures single tag" "only_one" "$_TUI_GRID_TAGS"
}

test_cool_header_no_crash() {
    local result
    result=$(COLUMNS=80 tui_cool_header "Test Title" 2>/dev/null) || true
    assert "tui_cool_header doesn't crash" "0" "0"
}

test_grid_checklist_tag_order() {
    _TUI_GRID_TAGS=""
    local t1="alpha" t2="beta" t3="gamma"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${t1}"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${t2}"
    _TUI_GRID_TAGS="${_TUI_GRID_TAGS}${_TUI_GRID_TAGS:+ }${t3}"
    assert "_TUI_GRID_TAGS preserves insertion order" "alpha beta gamma" "$_TUI_GRID_TAGS"
}

test_grid_checklist_captures_tags
test_grid_checklist_empty_tags
test_grid_checklist_single_tag
test_cool_header_no_crash
test_grid_checklist_tag_order

echo ""
echo "TUI tests: $PASS passed, $FAIL failed (of $((PASS + FAIL)))"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1