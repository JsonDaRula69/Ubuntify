#!/bin/bash
# Run all test files

set -e

PASS=0
FAIL=0
FAILURES=""

for test_file in tests/test_*.sh; do
    [ -f "$test_file" ] || continue
    echo "Running: $test_file"
    if source lib/colors.sh && source lib/logging.sh && bash "$test_file" 2>&1; then
        PASS=$((PASS + 1))
        echo "  PASS"
    else
        FAIL=$((FAIL + 1))
        FAILURES="$FAILURES\n  $test_file"
        echo "  FAIL"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
