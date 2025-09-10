#!/bin/sh
# Compatibility shim for test_script.sh
# This script has been moved to scripts/test_script.sh
exec "$(dirname "$0")/scripts/test_script.sh" "$@"