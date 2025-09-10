#!/bin/bash
#
# LinkZero Installation Script
# Quick installer for CloudLinux SMTP security
#
# Usage: curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash
# Or: wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash
#

set -euo pipefail

# Repository URLs
LINKZERO_SMTP_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/linkzero-smtp"
FIREWALLD_HELPER_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/scripts/firewalld-support.sh"

# Installation paths
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"
HELPER_DIR="/usr/local/bin/linkzero-scripts"
HELPER_NAME="firewalld-support.sh"

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

# Detect available download tool
detect_download_tool() {
    if command -v curl >/dev/null 2>&1; then
        echo "curl"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget"
    else
        log_error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi
}

# Download file with appropriate tool
download_file() {
    local url="$1"
    local output="$2"
    local tool="$3"
    
    case "$tool" in
        "curl")
            curl -sSL "$url" -o "$output"
            ;;
        "wget")
            wget -q "$url" -O "$output"
            ;;
    esac
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This installation script must be run as root"
    exit 1
fi

log_info "Installing LinkZero SMTP Security Runtime..."

# Detect download tool
DOWNLOAD_TOOL=$(detect_download_tool)
log_info "Using $DOWNLOAD_TOOL for downloads"

# Create necessary directories
mkdir -p "$HELPER_DIR"

# Download and install the linkzero-smtp runtime
log_info "Installing linkzero-smtp runtime to $INSTALL_DIR/$SCRIPT_NAME"
download_file "$LINKZERO_SMTP_URL" "$INSTALL_DIR/$SCRIPT_NAME" "$DOWNLOAD_TOOL"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

# Download and install the firewalld helper
log_info "Installing firewalld helper to $HELPER_DIR/$HELPER_NAME"
download_file "$FIREWALLD_HELPER_URL" "$HELPER_DIR/$HELPER_NAME" "$DOWNLOAD_TOOL"
chmod +x "$HELPER_DIR/$HELPER_NAME"

log_info "Configuring firewall rules..."

# Begin LinkZero firewalld/cPanel integration
if command -v firewall-cmd >/dev/null 2>&1; then
    log_info "Detected firewalld — using firewalld helper"
    
    # Use the installed helper script
    HELPER_SCRIPT="$HELPER_DIR/$HELPER_NAME"
    
    "$HELPER_SCRIPT" enable || log_warn "Failed to enable firewalld"
    "$HELPER_SCRIPT" add-interface "${WAN_IF}" public || log_warn "Failed to add interface ${WAN_IF}"
    "$HELPER_SCRIPT" add-masquerade public || log_warn "Failed to enable masquerading"
    
    # Add LinkZero ports (helper will delegate to CSF if present)
    "$HELPER_SCRIPT" add-port "${WG_PORT}" udp public || log_warn "Failed to add UDP port ${WG_PORT}"
    "$HELPER_SCRIPT" add-port "${API_PORT}" tcp public || log_warn "Failed to add TCP port ${API_PORT}"
    
    log_info "Firewall configuration completed"
else
    log_warn "firewalld not found; skipping automatic firewall configuration"
    log_info "Please configure your firewall manually to allow:"
    log_info "  - UDP port ${WG_PORT} (WireGuard)"
    log_info "  - TCP port ${API_PORT} (API)"
fi
# End LinkZero firewalld/cPanel integration

log_info "LinkZero SMTP Security Runtime installed successfully!"
log_info "Runtime: $INSTALL_DIR/$SCRIPT_NAME"
log_info "Helper: $HELPER_DIR/$HELPER_NAME"
echo ""
log_info "Usage examples:"
echo "  $SCRIPT_NAME --help                # Show help"
echo "  $SCRIPT_NAME --dry-run             # Preview changes"
echo "  $SCRIPT_NAME --backup-only         # Backup only"
echo "  $SCRIPT_NAME                       # Apply security configuration"
echo ""
log_warn "Remember to backup your configuration before running!"
log_info "For support, visit: https://github.com/astinowak-wq/LinkZero"