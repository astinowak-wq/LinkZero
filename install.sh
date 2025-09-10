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

log_info "LinkZero SMTP Security Script installed successfully!"
log_info "Location: $INSTALL_DIR/$SCRIPT_NAME"

# Firewall configuration
log_info "Configuring firewall rules..."

# Check for firewalld first
if command -v firewall-cmd >/dev/null 2>&1; then
    log_info "firewalld detected - using firewalld helper"
    
    # Download and install firewalld helper
    FIREWALLD_HELPER_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/scripts/firewalld-support.sh"
    FIREWALLD_HELPER_PATH="$INSTALL_DIR/linkzero-firewalld"
    
    if command -v curl >/dev/null 2>&1; then
        curl -sSL "$FIREWALLD_HELPER_URL" -o "$FIREWALLD_HELPER_PATH"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$FIREWALLD_HELPER_URL" -O "$FIREWALLD_HELPER_PATH"
    fi
    chmod +x "$FIREWALLD_HELPER_PATH"
    
    # Enable firewalld
    "$FIREWALLD_HELPER_PATH" enable
    
    # Add masquerade for NAT/routing
    "$FIREWALLD_HELPER_PATH" add-masquerade
    
    # Add common SMTP/Mail ports (if not using WireGuard-specific ports)
    "$FIREWALLD_HELPER_PATH" add-port 587 tcp  # SMTP submission
    "$FIREWALLD_HELPER_PATH" add-port 465 tcp  # SMTPS
    "$FIREWALLD_HELPER_PATH" add-port 993 tcp  # IMAPS
    "$FIREWALLD_HELPER_PATH" add-port 995 tcp  # POP3S
    
    # Detect and add WAN interface if available
    WAN_IF=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K[^ ]+' | head -1 || echo "")
    if [[ -n "$WAN_IF" ]]; then
        log_info "Adding WAN interface $WAN_IF to firewalld"
        "$FIREWALLD_HELPER_PATH" add-interface "$WAN_IF"
    else
        log_warn "Could not detect WAN interface automatically"
    fi
    
    # Reload firewalld to apply changes
    "$FIREWALLD_HELPER_PATH" reload
    
    log_info "firewalld configuration completed"

elif command -v iptables >/dev/null 2>&1; then
    log_info "iptables detected - keeping existing iptables behavior"
    log_warn "Firewall configuration via iptables is handled by the main script"
    
elif command -v nft >/dev/null 2>&1; then
    log_info "nftables detected - keeping existing nftables behavior" 
    log_warn "Firewall configuration via nftables is handled by the main script"
    
else
    log_warn "No supported firewall system detected (firewalld, iptables, nftables)"
fi

echo ""
log_info "Usage examples:"
echo "  $SCRIPT_NAME --help                # Show help"
echo "  $SCRIPT_NAME --dry-run             # Preview changes"
echo "  $SCRIPT_NAME --backup-only         # Backup only"
echo "  $SCRIPT_NAME                       # Apply security configuration"

if command -v firewall-cmd >/dev/null 2>&1; then
    echo ""
    log_info "Firewall management (firewalld):"
    echo "  linkzero-firewalld status          # Show firewall status"
    echo "  linkzero-firewalld add-port 8080   # Add custom port"
    echo "  linkzero-firewalld reload          # Reload configuration"
fi

echo ""
log_warn "Remember to backup your configuration before running!"