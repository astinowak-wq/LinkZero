#!/bin/bash
#
# LinkZero Installation Script
# Quick installer for CloudLinux SMTP security
#
# Usage: curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash
# Or: wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash
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
if command -v firewall-cmd >/dev/null 2>&1; then
  echo "Detected firewalld — using script/firewalld-support.sh helper"
  script/firewalld-support.sh enable || true
  script/firewalld-support.sh add-interface "${WAN_IF:-eth0}" public || true
  script/firewalld-support.sh add-masquerade public || true
  # If cPanel/CSF is present, the helper will delegate add-port/remove-port to CSF. Still call add-port for LinkZero ports.
  script/firewalld-support.sh add-port "${WG_PORT:-51820}" udp public || true
  script/firewalld-support.sh add-port "${API_PORT:-8080}" tcp public || true
else
  # existing iptables/nftables logic remains unchanged for systems without firewalld
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