#!/bin/sh
# Compatibility shim for disable_smtp_plain.sh
# This script has been moved to scripts/disable_smtp_plain.sh
exec "$(dirname "$0")/scripts/disable_smtp_plain.sh" "$@"