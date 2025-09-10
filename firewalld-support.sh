#!/bin/sh
# Compatibility shim for firewalld-support.sh
# This script has been moved to scripts/firewalld-support.sh
exec "$(dirname "$0")/scripts/firewalld-support.sh" "$@"