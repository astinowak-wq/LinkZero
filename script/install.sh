#!/bin/bash
#
# LinkZero Installation Script (tty-on-fd3 fix) - corrected conditional tests
#
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"

WG_PORT="${WG_PORT:-51820}"
API_PORT="${API_PORT:-8080}"
WAN_IF="${WAN_IF:-eth0}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

FORCE=false
ACTION=""   # will be "install" or "uninstall" or empty
YES=false

DEBUG="${DEBUG:-}"

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# open /dev/tty on fd 3 if possible
USE_TTY_FD=false
if [[ -r /dev/tty ]]; then
    exec 3</dev/tty 2>/dev/null || true
    if read -t 0 -u 3 >/dev/null 2>&1; then
        USE_TTY_FD=true
    else
        exec 3<&- 2>/dev/null || true
        USE_TTY_FD=false
    fi
fi

if [[ -n "$DEBUG" ]]; then
    printf "DEBUG: -t0=%s -t1=%s /dev/tty_readable=%s SUDO_USER=%s SUDO_TTY=%s TERM=%s\n" \
      "$( [[ -t 0 ]] && echo true || echo false )" \
      "$( [[ -t 1 ]] && echo true || echo false )" \
      "$USE_TTY_FD" \
      "${SUDO_USER:-}" \
      "${SUDO_TTY:-}" \
      "${TERM:-}"
fi

read_key() {
    key=''
    if [[ "$USE_TTY_FD" == true ]]; then
        IFS= read -rsn1 -t 0.1 key <&3 2>/dev/null || key=''
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.0005 rest <&3 2>/dev/null || rest=''
            key+="$rest"
        fi
    else
        IFS= read -rsn1 -t 0.1 key 2>/dev/null || key=''
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.0005 rest 2>/dev/null || rest=''
            key+="$rest"
        fi
    fi
}

if [[ $EUID -ne 0 ]]; then
    log_error "This installation script must be run as root"
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        --uninstall|-u) ACTION="uninstall" ;;
        --install|-i) ACTION="install" ;;
        --yes|-y|--yes-remove) YES=true ;;
        --force|-f) FORCE=true ;;
        -h|--help) echo "Usage: $0 [--install|--uninstall] [--yes]" ; exit 0 ;;
        *) ;;
    esac
done

if [[ -t 1 ]]; then clear; fi

echo -e "${GREEN}"
echo -e "   █████  █   █  █████        █      █        █   "
echo -e "  █     █ █   █    █          █               █  █"
echo -e "  █     █ █   █    █          █      █  █     █ █ "
echo -e "  █     █ █████    █          █      █  ████  ██  "
echo -e "  █     █ █   █    █          █      █  █   █ █ █ "
echo -e "   █████  █   █    █          █████  █  █   █ █  █"
echo -e "${NC}"
echo -e "${RED}${BOLD} a u t h o r :    D A N I E L    N O W A K O W S K I${NC}"
echo -e "${BLUE}========================================================"
echo -e "        QHTL Zero Configurator SMTP Hardening    "
echo -e "========================================================${NC}"
echo ""

ensure_install_dir() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi
}

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
    TMP_DL="$(mktemp /tmp/linkzero-script-XXXXXX.sh)"
    trap 'rm -f "${TMP_DL}"' EXIT
    if ! download_script_to_temp "$SCRIPT_URL" "$TMP_DL"; then
        log_error "Failed to download the LinkZero script from $SCRIPT_URL"
        exit 1
    fi
    if grep -qiE '<!doctype html|<html' "$TMP_DL" 2>/dev/null; then
        log_error "Downloaded content appears to be an HTML page instead of the raw script."
        log_error "Please ensure you can access the raw file at: $SCRIPT_URL"
        exit 1
    fi
    install_path="$INSTALL_DIR/$SCRIPT_NAME"
    mv "$TMP_DL" "$install_path"
    chmod +x "$install_path"
    log_info "Installed LinkZero script to: $install_path"
    log_warn "By design this installer will NOT modify system firewall settings."
    log_info "LinkZero SMTP Security Script installed successfully!"
    echo ""
    log_info "Usage examples:"
    echo "  $SCRIPT_NAME --help"
    echo "  $SCRIPT_NAME --dry-run"
    echo "  $SCRIPT_NAME --backup-only"
    echo "  $SCRIPT_NAME"
    echo ""
    log_warn "Remember to backup your configuration before running!"
}

uninstall_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    if [[ ! -f "$install_path" ]]; then
        log_warn "No installed LinkZero script found at: $install_path"
        return 0
    fi

    if [[ "$YES" != true && ( -t 0 || "$USE_TTY_FD" == true ) ]]; then
        echo ""
        echo "Confirm removal:"
        local opt_sel=0
        local opts=("Remove" "Cancel")
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
            read_key
            case "$key" in
                $'\n'|$'\r') printf "\n"; break ;;
                $'\x1b[C'|$'\x1b[B') opt_sel=$(( (opt_sel+1) % ${#opts[@]} )) ;;
                $'\x1b[D'|$'\x1b[A') opt_sel=$(( (opt_sel-1 + ${#opts[@]}) % ${#opts[@]} )) ;;
                *) ;;
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

    if [[ -f /var/log/linkzero-smtp-security.log ]]; then
        if [[ "$YES" == true ]]; then
            rm -f /var/log/linkzero-smtp-security.log || true
            log_info "Removed /var/log/linkzero-smtp-security.log"
        else
            if [[ -t 0 || "$USE_TTY_FD" == true ]]; then
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
                    read_key
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

if [[ -n "$ACTION" ]]; then
    case "$ACTION" in
        install) install_action ;;
        uninstall) uninstall_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
        *) log_error "Unknown action: $ACTION"; exec 3<&- 2>/dev/null || true; exit 2 ;;
    esac
    exec 3<&- 2>/dev/null || true
    exit 0
fi

# Fixed conditional: wrap -z tests in [[ ... ]]
if { [[ -t 1 || "$USE_TTY_FD" == true ]] && [[ -z "${NONINTERACTIVE:-}" ]] && [[ -z "${CI:-}" ]]; }; then
    options=("Install LinkZero" "Uninstall LinkZero" "Exit")
    sel=0
    tput civis 2>/dev/null || true
    echo "Use the arrow keys to choose and press Enter to confirm."
    while true; do
        printf "\n"
        for i in "${!options[@]}"; do
            if [[ $i -eq $sel ]]; then
                printf "  \033[7m%s\033[0m\n" "${options[$i]}"
            else
                printf "   %s\n" "${options[$i]}"
            fi
        done
        read_key
        case "$key" in
            $'\n'|$'\r')
                tput cnorm 2>/dev/null || true
                case $sel in
                    0) install_action; break ;;
                    1) uninstall_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
                    2) echo "Exiting."; exec 3<&- 2>/dev/null || true; exit 0 ;;
                esac
                ;;
            $'\x1b[A'|$'\x1b[D') sel=$(( (sel-1 + ${#options[@]}) % ${#options[@]} )); tput cuu $(( ${#options[@]} + 1 )) 2>/dev/null || printf '\033[%dA' $(( ${#options[@]} + 1 )) ;;
            $'\x1b[B'|$'\x1b[C') sel=$(( (sel+1) % ${#options[@]} )); tput cuu $(( ${#options[@]} + 1 )) 2>/dev/null || printf '\033[%dA' $(( ${#options[@]} + 1 )) ;;
            *) ;;
        esac
    done
    tput cnorm 2>/dev/null || true
else
    install_action
fi

exec 3<&- 2>/dev/null || true

exit 0
