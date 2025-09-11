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

FORCE=false
ACTION=""   # will be "install" or "uninstall" or empty
YES=false

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

# Parse non-interactive args
for arg in "$@"; do
    case "$arg" in
        --uninstall|-u)
            ACTION="uninstall" ;; 
        --install|-i)
            ACTION="install" ;;
        --yes|-y|--yes-remove)
            YES=true ;;
        --force|-f)
            FORCE=true ;;
        -h|--help)
            echo "Usage: $0 [--install|--uninstall] [--yes]" ; exit 0 ;;
        *) ;;
    esac
done

# Clear the terminal screen if interactive
if [[ -t 1 ]]; then
  clear
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

# Ensure install directory exists function
ensure_install_dir() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi
}

# Download helper
download_script_to_temp() {
    local url="$1" tmp="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$tmp"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$tmp" "$url"
    else
        return 2
    fi
}

install_action() {
    log_info "Installing LinkZero SMTP Security Script..."

    ensure_install_dir

    # Download the script into a temporary file first, validate it's not HTML, then move it into place
    TMP_DL="$(mktemp /tmp/linkzero-script-XXXXXX.sh)"
    trap 'rm -f "${TMP_DL}"' EXIT

    if ! download_script_to_temp "$SCRIPT_URL" "$TMP_DL"; then
        log_error "Failed to download the LinkZero script from $SCRIPT_URL"
        exit 1
    fi

    # Reject obvious HTML pages (GitHub HTML pages served instead of the raw content)
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
}

uninstall_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    if [[ ! -f "$install_path" ]]; then
        log_warn "No installed LinkZero script found at: $install_path"
        return 0
    fi

    # If user didn't pass --yes and we are interactive, still ask using yes/no chooser below.
    if [[ "$YES" != true && -t 0 ]]; then
        # Provide a confirmation prompt that uses only arrows + Enter
        echo ""
        echo "Confirm removal:"
        local opt_sel=0
        local opts=("Remove" "Cancel")
        tput civis 2>/dev/null || true
        while true; do
            printf "\r\033[K"
            for i in "${!opts[@]}"; do
                if [[ $i -eq $opt_sel ]]; then
                    printf "  \033[7m%s\033[0m" "${opts[$i]}"   # inverse video highlight
                else
                    printf "  %s" "${opts[$i]}"
                fi
            done
            # read single key
            IFS= read -rsn1 key 2>/dev/null || key=''
            if [[ $key == $'\x1b' ]]; then
                # read the rest of sequence
                IFS= read -rsn2 -t 0.0005 -u 0 rest 2>/dev/null || rest=''
                key+="$rest"
            fi
            case "$key" in
                $'\n'|$'\r') printf "\n"; break ;;
                $'\x1b[C'|$'\x1b[B') opt_sel=$(( (opt_sel+1) % ${#opts[@]} )) ;;
                $'\x1b[D'|$'\x1b[A') opt_sel=$(( (opt_sel-1 + ${#opts[@]}) % ${#opts[@]} )) ;;
                *) ;; # ignore other keys
            esac
        done
        tput cnorm 2>/dev/null || true
        if [[ $opt_sel -ne 0 ]]; then
            log_info "Abort: uninstall cancelled by user"
            return 0
        fi
    fi

    if rm -f "$install_path"; then
        log_info "Removed $install_path"
    else
        log_error "Failed to remove $install_path"
        return 1
    fi

    # Optionally remove log file if it was created by the script
    if [[ -f /var/log/linkzero-smtp-security.log ]]; then
        if [[ "$YES" == true ]]; then
            rm -f /var/log/linkzero-smtp-security.log || true
            log_info "Removed /var/log/linkzero-smtp-security.log"
        else
            if [[ -t 0 ]]; then
                echo ""
                echo "Remove log file /var/log/linkzero-smtp-security.log?"
                local opt_sel=0
                local opts=("Remove" "Keep")
                tput civis 2>/dev/null || true
                while true; do
                    printf "\r\033[K"
                    for i in "${!opts[@]}"; do
                        if [[ $i -eq $opt_sel ]]; then
                            printf "  \033[7m%s\033[0m" "${opts[$i]}"
                        else
                            printf "  %s" "${opts[$i]}"
                        fi
                    done
                    IFS= read -rsn1 key 2>/dev/null || key=''
                    if [[ $key == $'\x1b' ]]; then
                        IFS= read -rsn2 -t 0.0005 -u 0 rest 2>/dev/null || rest=''
                        key+="$rest"
                    fi
                    case "$key" in
                        $'\n'|$'\r') printf "\n"; break ;;
                        $'\x1b[C'|$'\x1b[B') opt_sel=$(( (opt_sel+1) % ${#opts[@]} )) ;;
                        $'\x1b[D'|$'\x1b[A') opt_sel=$(( (opt_sel-1 + ${#opts[@]}) % ${#opts[@]} )) ;;
                        *) ;;
                    esac
                done
                tput cnorm 2>/dev/null || true
                if [[ $opt_sel -eq 0 ]]; then
                    rm -f /var/log/linkzero-smtp-security.log || true
                    log_info "Removed /var/log/linkzero-smtp-security.log"
                else
                    log_info "Left log file in place"
                fi
            fi
        fi
    fi

    log_info "Uninstall complete."
}

# If action provided via flags, skip interactive selection
if [[ -n "$ACTION" ]]; then
    case "$ACTION" in
        install) install_action ;;
        uninstall) uninstall_action; exit 0 ;;
        *) log_error "Unknown action: $ACTION"; exit 2 ;;
    esac
    exit 0
fi

# Interactive menu using arrow keys + Enter only (no y/n)
# Show interactive menu only when BOTH stdin and stdout are TTYs AND neither NONINTERACTIVE nor CI environment vars are set.
# This reduces accidental interactive prompts when the script is piped or run in CI.
if [[ -t 0 && -t 1 && -z "${NONINTERACTIVE:-}" && -z "${CI:-}" ]]; then
    options=("Install LinkZero" "Uninstall LinkZero" "Exit")
    sel=0
    tput civis 2>/dev/null || true
    echo "Use the arrow keys to choose and press Enter to confirm."
    while true; do
        printf "\n"
        for i in "${!options[@]}"; do
            if [[ $i -eq $sel ]]; then
                # highlighted
                printf "  \033[7m%s\033[0m\n" "${options[$i]}"
            else
                printf "   %s\n" "${options[$i]}"
            fi
        done
        # read a single key (arrow keys are escape sequences)
        IFS= read -rsn1 key 2>/dev/null || key=''
        if [[ $key == $'\x1b' ]]; then
            # read the rest of the sequence (two more chars for arrow)
            IFS= read -rsn2 -t 0.0005 -u 0 rest 2>/dev/null || rest=''
            key+="$rest"
        fi
        case "$key" in
            $'\n'|$'\r')
                # Enter pressed
                tput cnorm 2>/dev/null || true
                case $sel in
                    0) install_action; break ;;
                    1) uninstall_action; exit 0 ;;  # after uninstall immediately exit installer
                    2) echo "Exiting."; exit 0 ;;
                esac
                ;;
            $'\x1b[A'|$'\x1b[D') # up or left
                sel=$(( (sel-1 + ${#options[@]}) % ${#options[@]} ))
                # re-render
                tput cuu $(( ${#options[@]} + 1 )) 2>/dev/null || printf '\033[%dA' $(( ${#options[@]} + 1 ))
                ;;
            $'\x1b[B'|$'\x1b[C') # down or right
                sel=$(( (sel+1) % ${#options[@]} ))
                tput cuu $(( ${#options[@]} + 1 )) 2>/dev/null || printf '\033[%dA' $(( ${#options[@]} + 1 ))
                ;;
            *) # ignore other keys
                ;;
        esac
    done
    tput cnorm 2>/dev/null || true
else
    # Non-interactive terminal with no action flag OR NONINTERACTIVE/CI set: default to install
    install_action
fi

exit 0
