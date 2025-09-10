#!/bin/bash
# Author: Daniel Nowakowski
#
# LinkZero Test Script
# Tests script functionality and syntax validation
#


set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/disable_smtp_plain.sh"


# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


test_count=0
pass_count=0


run_test() {
    local test_name="$1"
    local test_command="$2"
    
    test_count=$((test_count + 1))
    echo -e "${BLUE}Test $test_count:${NC} $test_name"
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        pass_count=$((pass_count + 1))
    else
        echo -e "${RED}✗ FAIL${NC}"
    fi
    echo ""
}


echo "LinkZero Script Test Suite"
echo "=========================="
echo ""


# Test script exists and is executable
run_test "Script file exists and is executable" "[[ -x '$MAIN_SCRIPT' ]]"


# Test script syntax
run_test "Script syntax validation" "bash -n '$MAIN_SCRIPT'"


# Test help option
run_test "Help option works" "$MAIN_SCRIPT --help | grep -q 'LinkZero'"


# Test invalid option handling
run_test "Invalid option handling" "! $MAIN_SCRIPT --invalid-option 2>/dev/null"


# Test install script exists and is executable
run_test "Install script exists and is executable" "[[ -x '$SCRIPT_DIR/install.sh' ]]"


# Test install script syntax
run_test "Install script syntax validation" "bash -n '$SCRIPT_DIR/install.sh'"


# Test README exists
run_test "README file exists" "[[ -f '$SCRIPT_DIR/README.md' ]]"


# Test README contains key information
run_test "README contains usage information" "grep -q 'Usage' '$SCRIPT_DIR/README.md'"


echo "=========================="
echo -e "Test Results: ${GREEN}$pass_count${NC}/$test_count passed"


if [[ $pass_count -eq $test_count ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
