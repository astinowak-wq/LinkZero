#!/bin/bash
#
# LinkZero Installation Script (resilient downloader, correct paths)
# - Prefer the script inside "script/" directory
# - Download to a secure temp file and validate it's not HTML before installing
# - Keeps original firewall helper behavior
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
#   wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/script/install.sh | sudo bash
#

set -euo pipefail

REPO_OWNER="${REPO_OWNER:-astinowak-wq}"
REPO_NAME="${REPO_NAME:-LinkZero}"
BRANCH="${BRANCH:-main}"

# Candidate raw paths for the real script (in order of preference)
CANDIDATE_PATHS=(
  "script/disable_smtp_plain.sh"
  "disable_smtp_plain.sh"
)

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
SCRIPT_NAME="${SCRIPT_NAME:-linkzero-smtp}"

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
TMP_SCRIPT=""
_cleanup() {
    [[ -n "${TMP_SCRIPT:-}" && -f "$TMP_SCRIPT" ]] && rm -f "$TMP_SCRIPT" || true
}
trap _cleanup EXIT

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This installation script must be run as root"
    exit 1
fi

log_info "Starting LinkZero installer..."

# Helper: download an URL to a destination using curl or wget
download_url() {
    local url="$1"; local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 2 --retry-delay 1 "$url" -o "$dest"
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
        return $?
    else
        return 2
    fi
}

# Validate downloaded file: non-empty, not HTML (doctype/html), and preferably has a shebang
is_valid_script() {
    local file="$1"
    # file must be non-empty
    [[ -s "$file" ]] || return 1
    # First non-empty line
    local first_nonempty_line
    first_nonempty_line="$(sed -n '/\S/ {p;q;}' "$file" || true)"
    [[ -n "$first_nonempty_line" ]] || return 1
    # Reject obvious HTML pages
    if echo "$first_nonempty_line" | grep -qiE '^<!DOCTYPE|^<html|^<!doctype|^<\!DOCTYPE'; then
        return 2
    fi
    # Prefer shebang but don't strictly require it
    return 0
}

selected_url=""
for path in "${CANDIDATE_PATHS[@]}"; do
    url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/${path}"
    TMP_SCRIPT="$(mktemp -p /tmp linkzero-script-XXXXXX.sh)" || {
        log_error "Failed to create temporary file for download"
        exit 1
    }

    log_info "Attempting to download: $url"
    if download_url "$url" "$TMP_SCRIPT"; then
        if is_valid_script "$TMP_SCRIPT"; then
            selected_url="$url"
            log_info "Valid script downloaded from: $url"
            break
        else
            # Determine reason
            if is_valid_script "$TMP_SCRIPT"; then :; fi
            # Check if it was HTML-like
            first_nonempty_line="$(sed -n '/\S/ {p;q;}' "$TMP_SCRIPT" || true)"
            if echo "$first_nonempty_line" | grep -qiE '^<!DOCTYPE|^<html|^<!doctype|^<\!DOCTYPE'; then
                log_warn "Downloaded content from $url looks like an HTML page (likely a 404 or GitHub HTML response). Skipping."
            else
                log_warn "Downloaded file from $url is empty or doesn't look like a shell script. Skipping."
            fi
            rm -f "$TMP_SCRIPT" || true
            TMP_SCRIPT=""
            continue
        fi
    else
        log_warn "Failed to download $url (network/HTTP error)."
        rm -f "$TMP_SCRIPT" || true
        TMP_SCRIPT=""
        continue
    fi
done

if [[ -z "$selected_url" ]]; then
    log_error "Unable to retrieve a valid shell script for disable_smtp_plain.sh from the repository."
    echo ""
    log_info "Tried these candidate raw URLs:"
    for path in "${CANDIDATE_PATHS[@]}"; do
        echo "  - https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/${path}"
    done
    echo ""
    log_info "Possible fixes:"
    echo "  - Add the script at one of the candidate locations"
    echo "  - Ensure BRANCH/REPO_OWNER/REPO_NAME environment variables are correct"
    echo ""
    echo "Debug commands you can run locally to inspect raw responses:"
    echo "  curl -I \"https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/${CANDIDATE_PATHS[0]}\""
    echo "  curl -fsSL \"https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/${CANDIDATE_PATHS[0]}\" | sed -n '1,20p'"
    exit 1
fi

# Move validated script into place atomically
chmod +x "$TMP_SCRIPT" || true
mv -f "$TMP_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
TMP_SCRIPT=""  # prevent trap from removing installed file

log_info "Installed $INSTALL_DIR/$SCRIPT_NAME"

log_info "Configuring firewall rules..."

# Detect firewall type
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

    HELPER_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/script/firewalld-support.sh"
    TMP_HELPER="$(mktemp -p /tmp linkzero-firewalld-helper-XXXXXX.sh)" || TMP_HELPER=""
    fetched_helper=false

    if [[ -n "${TMP_HELPER}" ]]; then
        if download_url "$HELPER_URL" "$TMP_HELPER"; then
            chmod +x "$TMP_HELPER" || true
            fetched_helper=true
        else
            rm -f "$TMP_HELPER" || true
            TMP_HELPER=""
        fi
    fi

    if $fetched_helper && [[ -s "$TMP_HELPER" ]]; then
        bash "$TMP_HELPER" enable || true
        bash "$TMP_HELPER" add-interface "${WAN_IF:-eth0}" public || true
        bash "$TMP_HELPER" add-masquerade public || true
        bash "$TMP_HELPER" add-port "${WG_PORT:-51820}" udp public || true
        bash "$TMP_HELPER" add-port "${API_PORT:-8080}" tcp public || true
        rm -f "$TMP_HELPER" || true
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
log_warn "If you still see HTML in the installed file, check that the raw URL below is correct:"
log_warn "  $selected_url"

exit 0
