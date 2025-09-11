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

# Detect firewall type and act accordingly.
# Prefer csf (cPanel/ConfigServer) if present, otherwise detect firewalld, nftables, iptables, none
firewall_type="none"
if command -v csf >/dev/null 2>&1 || [[ -f /etc/csf/csf.conf ]]; then
    firewall_type="csf"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall_type="firewalld"
elif command -v nft >/dev/null 2>&1; then
    firewall_type="nftables"
elif command -v iptables >/dev/null 2>&1; then
    firewall_type="iptables"
else
    firewall_type="none"
fi

# Handle firewalld specially: attempt to fetch and use the repo helper; otherwise fallback to firewall-cmd directly.
if [[ "$firewall_type" == "firewalld" ]]; then
    log_info "Detected firewall: firewalld"

    HELPER_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/firewalld-support.sh"
    TMP_HELPER="/tmp/linkzero-firewalld-helper-$$.sh"
    fetched_helper=false

    # Try to fetch the helper into a temporary file (do not attempt to call local script/firewalld-support.sh)
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$HELPER_URL" -o "$TMP_HELPER"; then
            fetched_helper=true
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -O "$TMP_HELPER" "$HELPER_URL"; then
            fetched_helper=true
        fi
    fi

    if $fetched_helper && [[ -s "$TMP_HELPER" ]]; then
        # Ensure executable (harmless if noexec is set; we will run via bash to avoid noexec issues)
        chmod +x "$TMP_HELPER" || true

        # Run helper commands via the temporary helper file using an explicit shell so /tmp noexec won't block execution.
        bash "$TMP_HELPER" enable || true
        bash "$TMP_HELPER" add-interface "${WAN_IF:-eth0}" public || true
        bash "$TMP_HELPER" add-masquerade public || true
        # If cPanel/CSF is present, the helper will delegate add-port/remove-port to CSF. Still call add-port for LinkZero ports.
        bash "$TMP_HELPER" add-port "${WG_PORT:-51820}" udp public || true
        bash "$TMP_HELPER" add-port "${API_PORT:-8080}" tcp public || true

        # Clean up the temporary helper
        rm -f "$TMP_HELPER" || true
    else
        # Helper fetch failed: do not call a non-existent local helper. Fall back to firewall-cmd direct operations.
        log_warn "firewalld helper could not be retrieved; falling back to firewall-cmd directly"

        # Add interface to public zone (if supported)
        if firewall-cmd --help >/dev/null 2>&1; then
            firewall-cmd --permanent --zone=public --add-interface="${WAN_IF:-eth0}" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-masquerade >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port="${WG_PORT:-51820}/udp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port="${API_PORT:-8080}/tcp" >/dev/null 2>&1 || true
            # Try to reload firewalld to apply permanent changes; don't abort if reload fails.
            firewall-cmd --reload >/dev/null 2>&1 || true
        else
            log_warn "firewall-cmd is not usable despite detection; skipping direct firewall-cmd calls"
        fi
    fi

elif [[ "$firewall_type" == "csf" ]]; then
    # If CSF is present, do not attempt to call firewalld helper
    log_info "Detected firewall: csf (ConfigServer Security & Firewall). Installer will not call firewalld helper."
    # Keep existing behavior for CSF (do not call helper)
else
    # nftables, iptables, or none: keep existing fallback behavior but use log_info for consistency
    if [[ "$firewall_type" == "nftables" ]]; then
        log_info "Detected nftables; keeping existing firewall configuration path"
    elif [[ "$firewall_type" == "iptables" ]]; then
        log_info "Detected iptables; keeping existing firewall configuration path"
    else
        log_info "No known firewall detected; keeping existing firewall configuration path"
    fi
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