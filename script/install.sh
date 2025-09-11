#!/bin/bash
#
# LinkZero Installation Script (improved)
# - Uninstalls previous installation (if present) before installing
# - Downloads to a secure temp file and validates it's a shell script (not HTML)
# - Cleans up temporary files on exit
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
#   wget -qO- https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
#

set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"

# Default port variables for firewall configuration (used later if needed)
WG_PORT="${WG_PORT:-51820}"
API_PORT="${API_PORT:-8080}"
WAN_IF="${WAN_IF:-eth0}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Ensure temporary files are cleaned up on exit (success or failure)
TMP_HELPER=""
TMP_SCRIPT=""
_cleanup() {
    [[ -n "${TMP_HELPER:-}" && -f "$TMP_HELPER" ]] && rm -f "$TMP_HELPER" || true
    [[ -n "${TMP_SCRIPT:-}" && -f "$TMP_SCRIPT" ]] && rm -f "$TMP_SCRIPT" || true
}
trap _cleanup EXIT

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This installation script must be run as root"
    exit 1
fi

log_info "Starting LinkZero installer..."

# If an existing installation exists, try to uninstall it first
existing="$INSTALL_DIR/$SCRIPT_NAME"
if [[ -e "$existing" || -L "$existing" ]]; then
    log_info "Existing installation detected at $existing"
    # Try common uninstall/restore/remove flags if the installed script supports them
    tried_uninstall=false
    for flag in --uninstall --remove --restore --force-uninstall --uninstall-all; do
        if bash "$existing" "$flag" >/dev/null 2>&1; then
            log_info "Previous installation uninstalled via '$flag'"
            tried_uninstall=true
            break
        fi
    done

    if ! $tried_uninstall; then
        # If uninstall flags didn't exist or failed, make a backup and remove the file
        bak="${existing}.bak.$(date +%s)"
        if mv -f "$existing" "$bak" 2>/dev/null; then
            log_warn "Previous installation moved to backup: $bak"
        else
            # Last resort: try to remove
            if rm -f "$existing" 2>/dev/null; then
                log_warn "Previous installation removed: $existing"
            else
                log_error "Unable to remove or back up existing installation at $existing. Please remove it manually and re-run the installer."
                exit 1
            fi
        fi
    fi
else
    log_info "No previous installation found."
fi

log_info "Preparing to download the main script from $SCRIPT_URL"

# Create secure temporary file for download
TMP_SCRIPT="$(mktemp -p /tmp linkzero-script-XXXXXX.sh)" || {
    log_error "Failed to create temporary file for download"
    exit 1
}

download_to_temp() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        # Use -f to fail on HTTP errors, -L to follow redirects, -sS to show errors when they happen
        if ! curl -fLsS "$url" -o "$dest"; then
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

case "$(download_to_temp "$SCRIPT_URL" "$TMP_SCRIPT"; echo $?)" in
    0)
        ;;
    1)
        log_error "Failed to download the main script from $SCRIPT_URL (HTTP error or network issue)"
        exit 1
        ;;
    2)
        log_error "Neither curl nor wget found. Please install one of them and re-run the installer."
        exit 1
        ;;
esac

# Basic validation: ensure the downloaded file looks like a shell script and not an HTML error page.
# Check first non-empty line for a shebang (#!) and ensure file does not start with <!DOCTYPE or <html
first_nonempty_line="$(sed -n '/\S/ {p;q;}' "$TMP_SCRIPT" || true)"
if [[ -z "$first_nonempty_line" ]]; then
    log_error "Downloaded file is empty -- aborting"
    exit 1
fi

# Detect obvious HTML (common cause: wrong raw URL / GitHub HTML page returned)
if echo "$first_nonempty_line" | grep -qiE '^<!DOCTYPE|^<html|^<!doctype'; then
    log_error "Downloaded content appears to be HTML (not a shell script). This usually means the raw URL is incorrect or GitHub returned an HTML page (404/redirect)."
    log_error "First line of downloaded file: $first_nonempty_line"
    log_info "Saving invalid download to: $TMP_SCRIPT (will be removed on exit)."
    exit 1
fi

# Ensure shebang present (recommended). If not present, still allow but warn.
if ! echo "$first_nonempty_line" | grep -q '^#!'; then
    log_warn "Downloaded file does not start with a shebang (#!). The script may still run, but this is unusual."
fi

# Make executable and move into place atomically
chmod +x "$TMP_SCRIPT" || true
mv -f "$TMP_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
# Clear TMP_SCRIPT so cleanup trap won't remove the installed file
TMP_SCRIPT=""

log_info "Installed $INSTALL_DIR/$SCRIPT_NAME"

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

if [[ "$firewall_type" == "firewalld" ]]; then
    log_info "Detected firewall: firewalld"

    HELPER_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/firewalld-support.sh"
    TMP_HELPER="$(mktemp -p /tmp linkzero-firewalld-helper-XXXXXX.sh)" || {
        log_warn "Could not create temporary file for the firewalld helper; falling back to firewall-cmd directly"
        TMP_HELPER=""
    }
    fetched_helper=false

    if [[ -n "${TMP_HELPER:-}" ]]; then
        if download_to_temp "$HELPER_URL" "$TMP_HELPER"; then
            chmod +x "$TMP_HELPER" || true
            fetched_helper=true
        fi
    fi

    if $fetched_helper && [[ -s "$TMP_HELPER" ]]; then
        # Run helper via bash (avoids /tmp noexec)
        bash "$TMP_HELPER" enable || true
        bash "$TMP_HELPER" add-interface "${WAN_IF:-eth0}" public || true
        bash "$TMP_HELPER" add-masquerade public || true
        bash "$TMP_HELPER" add-port "${WG_PORT:-51820}" udp public || true
        bash "$TMP_HELPER" add-port "${API_PORT:-8080}" tcp public || true
        # TMP_HELPER will be removed by trap
    else
        log_warn "firewalld helper could not be retrieved; falling back to firewall-cmd directly"
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --zone=public --add-interface="${WAN_IF:-eth0}" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-masquerade >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port="${WG_PORT:-51820}/udp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port="${API_PORT:-8080}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        else
            log_warn "firewall-cmd not available; skipping firewalld configuration"
        fi
    fi

elif [[ "$firewall_type" == "csf" ]]; then
    log_info "Detected firewall: csf (ConfigServer Security & Firewall). Installer will not modify CSF automatically beyond what the script does."
else
    log_info "Firewall type: $firewall_type — no automated changes made by installer in this branch."
fi

log_info "LinkZero installed successfully at $INSTALL_DIR/$SCRIPT_NAME"
echo ""
log_info "Try: $INSTALL_DIR/$SCRIPT_NAME --dry-run"
log_warn "If you still see HTML in the installed file, check that $SCRIPT_URL is correct and points to a raw shell script (raw.githubusercontent.com link)."

exit 0
