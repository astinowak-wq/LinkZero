#!/bin/bash
#
# LinkZero Installation Script
# Quick installer for CloudLinux SMTP security
#
# Usage: curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
# Or: wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
#

set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"

# Default port variables for firewall configuration (kept for reference only)
WG_PORT="${WG_PORT:-51820}"
API_PORT="${API_PORT:-8080}"
WAN_IF="${WAN_IF:-eth0}"

# Colors / text styles
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This installation script must be run as root"
    exit 1
fi
# Big pixel-art QHTL logo (with double space between T and L)
echo -e "${GREEN}"
echo -e "   █████  █   █  █████        █      █        █   "
echo -e "  █     █ █   █    █          █               █  █"
echo -e "  █     █ █   █    █          █      █  █     █ █ "
echo -e "  █     █ █████    █          █      █  ████  ██  "
echo -e "  █     █ █   █    █          █      █  █   █ █ █ "
echo -e "   █████  █   █    █          █████  █  █   █ █  █"
echo -e "${NC}"

# Red bold capital Daniel Nowakowski below logo
echo -e "${RED}${BOLD} a u t h o r :    D A N I E L    N O W A K O W S K I${NC}"

# Display QHTL Zero header
echo -e "${BLUE}========================================================"
echo -e "        QHTL Zero Configurator SMTP Hardening    "
echo -e "========================================================${NC}"
echo -e ""

log_info "Installing LinkZero SMTP Security Script..."

# Ensure install directory exists
mkdir -p "$INSTALL_DIR"

# Download the script into a temporary file first, validate it's not HTML, then move it into place
TMP_DL="$(mktemp /tmp/linkzero-script-XXXXXX.sh)"
trap 'rm -f "$TMP_DL"' EXIT

if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$SCRIPT_URL" -o "$TMP_DL"; then
        log_error "Failed to download the LinkZero script from $SCRIPT_URL"
        exit 1
    fi
elif command -v wget >/dev/null 2>&1; then
    if ! wget -q -O "$TMP_DL" "$SCRIPT_URL"; then
        log_error "Failed to download the LinkZero script from $SCRIPT_URL"
        exit 1
    fi
else
    log_error "Neither curl nor wget found. Please install one of them."
    exit 1
fi

# Reject obvious HTML pages (GitHub HTML pages served instead of raw content)
if grep -qiE '<!doctype html|<html' "$TMP_DL" 2>/dev/null; then
    log_error "Downloaded content appears to be an HTML page instead of the raw script."
    log_error "Please ensure you can access the raw file at: $SCRIPT_URL"
    exit 1
fi

# Move the verified script into place and make it executable
install_path="$INSTALL_DIR/$SCRIPT_NAME"
mv "$TMP_DL" "$install_path"
chmod +x "$install_path"

log_info "Installed LinkZero script to: $install_path"

# IMPORTANT: Do not change firewall configuration during installation
log_warn "By design this installer will NOT modify system firewall settings."
log_warn "Firewall changes are intentionally skipped. Configure your firewall manually or use script/firewalld-support.sh later if you need automated support."

log_info "LinkZero SMTP Security Script installed successfully!"
log_info "Location: $install_path"

echo ""
log_info "Usage examples:"
echo "  $SCRIPT_NAME --help                # Show help"
echo "  $SCRIPT_NAME --dry-run             # Preview changes"
echo "  $SCRIPT_NAME --backup-only         # Backup only"
echo "  $SCRIPT_NAME                       # Apply security configuration"

echo ""
log_warn "Remember to backup your configuration before running!"
