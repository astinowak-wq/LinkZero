#!/bin/bash
#
# LinkZero Installation Script (refined)
# Quick installer for CloudLinux SMTP security
#
# Usage: curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
# Or: wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
#
# Changes in this revision:
# - Removed verbose "Attempting to download" and explicit raw-URL HTML-warning lines that were printed during install.
# - Downloads are now attempted quietly; only concise, non-redundant informational or error messages are shown.
# - If downloaded content looks like an HTML page, the installer treats that as a failed download and moves on (no raw-URL echoing).
# - Tries a small list of candidate raw URLs quietly before failing with a single clear error message.
#

set -euo pipefail

# Primary candidates for the script raw URL. Try these quietly (no repetitive attempt messages).
CANDIDATE_URLS=(
    "https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh"
    "https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/disable_smtp_plain.sh"
)

INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"

# Default port variables for firewall configuration (kept from original script)
WG_PORT="${WG_PORT:-51820}"
API_PORT="${API_PORT:-8080}"
WAN_IF="${WAN_IF:-eth0}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This installation script must be run as root"
    exit 1
fi

log_info "Installing LinkZero SMTP Security Script..."

# Create temp file for download attempts
TMP_DL="$(mktemp /tmp/linkzero-script-XXXXXX.sh)"
trap 'rm -f "$TMP_DL"' EXIT

download_ok=false
for url in "${CANDIDATE_URLS[@]}"; do
    # Try to fetch quietly; suppress curl text output (-s) and fail on HTTP errors (-f).
    # We intentionally do not print the URL on each attempt to avoid noisy logs.
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$url" -o "$TMP_DL"; then
            # Check whether the downloaded file is likely an HTML page (GitHub rendered page accidentally downloaded)
            if grep -qiE '<!doctype html|<html' "$TMP_DL" 2>/dev/null; then
                # treat as failure and try next candidate quietly
                rm -f "$TMP_DL"
                TMP_DL="$(mktemp /tmp/linkzero-script-XXXXXX.sh)"
                continue
            fi
            download_ok=true
            break
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -O "$TMP_DL" "$url"; then
            if grep -qiE '<!doctype html|<html' "$TMP_DL" 2>/dev/null; then
                rm -f "$TMP_DL"
                TMP_DL="$(mktemp /tmp/linkzero-script-XXXXXX.sh)"
                continue
            fi
            download_ok=true
            break
        fi
    else
        log_error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi
done

if ! $download_ok; then
    log_error "Failed to download the LinkZero script (network/HTTP error or invalid content)."
    log_error "Please ensure the repository contains the raw script and try again."
    exit 1
fi

# Move the verified script into place
install_path="$INSTALL_DIR/$SCRIPT_NAME"
mv "$TMP_DL" "$install_path"
chmod +x "$install_path"
log_info "Installed LinkZero script to: $install_path"

# --- Firewall configuration handling (unchanged behaviour, refined small parts) ---

log_info "Configuring firewall rules..."

# Detect firewall type and act accordingly.
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
    TMP_HELPER="$(mktemp /tmp/linkzero-firewalld-helper-XXXXXX.sh)"
    fetched_helper=false

    # Try to fetch the helper quietly
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$HELPER_URL" -o "$TMP_HELPER"; then
            # Verify not HTML
            if ! grep -qiE '<!doctype html|<html' "$TMP_HELPER" 2>/dev/null; then
                fetched_helper=true
            else
                rm -f "$TMP_HELPER"
                TMP_HELPER="$(mktemp /tmp/linkzero-firewalld-helper-XXXXXX.sh)"
            fi
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -O "$TMP_HELPER" "$HELPER_URL"; then
            if ! grep -qiE '<!doctype html|<html' "$TMP_HELPER" 2>/dev/null; then
                fetched_helper=true
            else
                rm -f "$TMP_HELPER"
                TMP_HELPER="$(mktemp /tmp/linkzero-firewalld-helper-XXXXXX.sh)"
            fi
        fi
    fi

    if $fetched_helper && [[ -s "$TMP_HELPER" ]]; then
        chmod +x "$TMP_HELPER" || true
        # Run helper commands via the temporary helper file using an explicit shell
        bash "$TMP_HELPER" enable || true
        bash "$TMP_HELPER" add-interface "${WAN_IF:-eth0}" public || true
        bash "$TMP_HELPER" add-masquerade public || true
        bash "$TMP_HELPER" add-port "${WG_PORT:-51820}" udp public || true
        bash "$TMP_HELPER" add-port "${API_PORT:-8080}" tcp public || true
        rm -f "$TMP_HELPER" || true
    else
        # Helper fetch failed or invalid; fall back to firewall-cmd direct operations quietly
        log_warn "firewalld helper unavailable; falling back to direct firewall-cmd operations."
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --zone=public --add-interface="${WAN_IF:-eth0}" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-masquerade >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port="${WG_PORT:-51820}/udp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port="${API_PORT:-8080}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        else
            log_warn "firewall-cmd is not usable despite firewalld detection; skipping direct firewall-cmd calls"
        fi
    fi

elif [[ "$firewall_type" == "csf" ]]; then
    log_info "Detected firewall: csf (ConfigServer Security & Firewall). Installer will not call firewalld helper."
else
    if [[ "$firewall_type" == "nftables" ]]; then
        log_info "Detected nftables; keeping existing firewall configuration path"
    elif [[ "$firewall_type" == "iptables" ]]; then
        log_info "Detected iptables; keeping existing firewall configuration path"
    else
        log_info "No known firewall detected; keeping existing firewall configuration path"
    fi
fi

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
