#!/bin/bash
# Unit tests for lib/retry.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

# Source the module
source "$LIB_DIR/retry.sh"

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function
run_test() {
    local test_name="$1"
    local test_func="$2"
    
    if $test_func; then
        echo "PASS: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "FAIL: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Test is_transient_error with exit code 1 (transient)
test_is_transient_error_1() {
    if is_transient_error 1; then
        return 0
    else
        echo "  Expected code 1 to be transient"
        return 1
    fi
}

# Test is_transient_error with exit code 0 (success, not transient)
test_is_transient_error_0() {
    if is_transient_error 0; then
        echo "  Expected code 0 to NOT be transient"
        return 1
    else
        return 0
    fi
}

# Test is_transient_error with exit code 2 (permanent)
test_is_transient_error_2() {
    if is_transient_error 2; then
        echo "  Expected code 2 to NOT be transient"
        return 1
    else
        return 0
    fi
}

# Test is_transient_error with exit code 127 (permanent)
test_is_transient_error_127() {
    if is_transient_error 127; then
        echo "  Expected code 127 to NOT be transient"
        return 1
    else
        return 0
    fi
}

# Test is_transient_error with exit code 130 (SIGINT, permanent)
test_is_transient_error_130() {
    if is_transient_error 130; then
        echo "  Expected code 130 to NOT be transient"
        return 1
    else
        return 0
    fi
}

# Test is_transient_error with exit code 124 (timeout, transient)
test_is_transient_error_124() {
    if is_transient_error 124; then
        return 0
    else
        echo "  Expected code 124 to be transient"
        return 1
    fi
}

# Test is_transient_error with exit code 255 (SSH, transient)
test_is_transient_error_255() {
    if is_transient_error 255; then
        return 0
    else
        echo "  Expected code 255 to be transient"
        return 1
    fi
}

# Run all tests
echo "=== Testing lib/retry.sh ==="
echo ""

run_test "is_transient_error 1 returns 0 (transient)" test_is_transient_error_1
run_test "is_transient_error 0 returns 1 (success, not transient)" test_is_transient_error_0
run_test "is_transient_error 2 returns 1 (permanent)" test_is_transient_error_2
run_test "is_transient_error 127 returns 1 (permanent)" test_is_transient_error_127
run_test "is_transient_error 130 returns 1 (SIGINT, permanent)" test_is_transient_error_130
run_test "is_transient_error 124 returns 0 (timeout, transient)" test_is_transient_error_124
run_test "is_transient_error 255 returns 0 (SSH, transient)" test_is_transient_error_255

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
