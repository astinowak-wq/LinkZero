#!/bin/sh
# Compatibility shim for demo.sh
# This script has been moved to scripts/demo.sh
exec "$(dirname "$0")/scripts/demo.sh" "$@"