#!/bin/bash
#
# LinkZero Installation Script
# Quick installer for CloudLinux SMTP security
#
# Usage: curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
# To allow firewall changes during install from GitHub, prefix with: ALLOW_FIREWALL_CHANGES=1
# Example: ALLOW_FIREWALL_CHANGES=1 sudo bash -c "curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | bash"
#

set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"

# Default port variables for firewall configuration
WG_PORT="${WG_PORT:-51820}"
API_PORT="${API_PORT:-8080}"
WAN_IF="${WAN_IF:-eth0}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

log_info "Installing LinkZero SMTP Security Script..."

# Download the script
if command -v curl >/dev/null 2>&1; then
    curl -sSL "$SCRIPT_URL" -o "$INSTALL_DIR/$SCRIPT_NAME"
elif command -v wget >/dev/null 2>&1; then
    wget -q "$SCRIPT_URL" -O "$INSTALL_DIR/$SCRIPT_NAME"
else
    log_error "Neither curl nor wget found. Please install one of them."
    exit 1
fi

# Make executable
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

log_info "Configuring firewall rules..."

# Begin LinkZero firewalld/cPanel integration
# Firewall changes are disabled by default when running the installer directly from GitHub.
# To enable firewall changes during install, set ALLOW_FIREWALL_CHANGES=1 in the environment.

if command -v firewall-cmd >/dev/null 2>&1; then
  if [[ "${ALLOW_FIREWALL_CHANGES:-0}" == "1" ]]; then
    echo "Detected firewalld — ALLOW_FIREWALL_CHANGES=1 set, applying firewall changes using remote helper"

    TMPDIR=$(mktemp -d)
    helper_url="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/firewalld-support.sh"
    if command -v curl >/dev/null 2>&1; then
      curl -sSL "$helper_url" -o "$TMPDIR/firewalld-support.sh" || true
    elif command -v wget >/dev/null 2>&1; then
      wget -q "$helper_url" -O "$TMPDIR/firewalld-support.sh" || true
    fi

    if [[ -f "$TMPDIR/firewalld-support.sh" ]]; then
      chmod +x "$TMPDIR/firewalld-support.sh"
      # Use the helper from the temp dir
      "$TMPDIR/firewalld-support.sh" enable || true
      "$TMPDIR/firewalld-support.sh" add-interface "${WAN_IF:-eth0}" public || true
      "$TMPDIR/firewalld-support.sh" add-masquerade public || true
      "$TMPDIR/firewalld-support.sh" add-port "${WG_PORT:-51820}" udp public || true
      "$TMPDIR/firewalld-support.sh" add-port "${API_PORT:-8080}" tcp public || true
      rm -rf "$TMPDIR"
    else
      log_warn "Could not download firewalld helper; skipping firewall configuration"
    fi
  else
    echo "Detected firewalld — installer will NOT modify firewall (set ALLOW_FIREWALL_CHANGES=1 to enable)"
  fi
else
  echo "firewalld not found; keeping existing firewall configuration path"
fi
# End LinkZero firewalld/cPanel integration

log_info "LinkZero SMTP Security Script installed successfully!"
log_info "Location: $INSTALL_DIR/$SCRIPT_NAME"
echo ""
log_info "Usage examples:"
echo "  $SCRIPT_NAME --help                # Show help"
echo "  $SCRIPT_NAME --dry-run             # Preview changes"
echo "  $SCRIPT_NAME --backup-only         # Backup only"
echo "  $SCRIPT_NAME                       # Apply security configuration"
echo ""
log_warn "Remember to backup your configuration before running!"