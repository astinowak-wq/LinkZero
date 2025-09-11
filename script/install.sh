#!/bin/bash
#
# LinkZero Installation Script (updated to clean up temporary downloads)
# Quick installer for CloudLinux SMTP security
#
# Usage: curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
# Or: wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
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

# Ensure temporary files are cleaned up on exit (success or failure)
TMP_HELPER=""
TMP_SCRIPT=""
_cleanup() {
    # Remove temporary files if they exist.
    [[ -n "${TMP_HELPER:-}" && -f "$TMP_HELPER" ]] && rm -f "$TMP_HELPER" || true
    [[ -n "${TMP_SCRIPT:-}" && -f "$TMP_SCRIPT" ]] && rm -f "$TMP_SCRIPT" || true
}
trap _cleanup EXIT

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This installation script must be run as root"
    exit 1
fi

log_info "Installing LinkZero SMTP Security Script..."

# Download the main script to a secure temporary file and move it into place atomically
TMP_SCRIPT="$(mktemp -p /tmp linkzero-script-XXXXXX.sh)" || {
    log_error "Failed to create temporary file for the main script"
    exit 1
}

download_to_temp() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$url" -o "$dest"; then
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q -O "$dest" "$url"; then
            return 1
        fi
    else
        return 2
    fi

    return 0
}

# Fetch main script
case "$(download_to_temp "$SCRIPT_URL" "$TMP_SCRIPT"; echo $?)" in
    0)
        chmod +x "$TMP_SCRIPT"
        # Move into place atomically
        mv -f "$TMP_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
        # Clear TMP_SCRIPT variable so trap won't try to remove the installed file
        TMP_SCRIPT=""
        ;;
    1)
        log_error "Failed to download the main script from $SCRIPT_URL"
        exit 1
        ;;
    2)
        log_error "Neither curl nor wget found. Please install one of them."
        exit 1
        ;;
esac

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
    TMP_HELPER="$(mktemp -p /tmp linkzero-firewalld-helper-XXXXXX.sh)" || {
        log_warn "Could not create temporary file for the firewalld helper; falling back to firewall-cmd directly"
        TMP_HELPER=""
    }
    fetched_helper=false

    if [[ -n "${TMP_HELPER:-}" ]]; then
        # Try to fetch the helper into the temporary file
        if download_to_temp "$HELPER_URL" "$TMP_HELPER"; then
            # Ensure executable (we will run via bash to avoid noexec problems on /tmp)
            chmod +x "$TMP_HELPER" || true
            fetched_helper=true
        fi
    fi

    if $fetched_helper && [[ -s "$TMP_HELPER" ]]; then
        # Run helper commands via the temporary helper file using an explicit shell so /tmp noexec won't block execution.
        bash "$TMP_HELPER" enable || true
        bash "$TMP_HELPER" add-interface "${WAN_IF:-eth0}" public || true
        bash "$TMP_HELPER" add-masquerade public || true
        # If cPanel/CSF is present, the helper will delegate add-port/remove-port to CSF. Still call add-port for LinkZero ports.
        bash "$TMP_HELPER" add-port "${WG_PORT:-51820}" udp public || true
        bash "$TMP_HELPER" add-port "${API_PORT:-8080}" tcp public || true

        # helper will be removed by the EXIT trap (_cleanup)
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
