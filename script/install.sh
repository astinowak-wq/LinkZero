#!/bin/bash
#
# LinkZero installer — interactive menu with improved tty detection
# Adds numeric-input fallback to main menu so users can type 1/2/3 if single-key reads fail.
#
set -euo pipefail

# -- Early header: show logo/author even when falling back to non-interactive mode --
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0;0m'

# Clear the screen and print the header when stdout is a terminal.
if [[ -t 1 ]]; then
    clear
fi

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

# Config
SCRIPT_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"

# State flags
ACTION=""
YES=false
FORCE=false
FORCE_MENU=false
DEBUG="${DEBUG:-}"

log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()    { echo -e "${RED}[ERR]${NC} $*"; }

# Try to open a terminal on fd 3. Order:
# 1) /dev/tty
# 2) SUDO_TTY (if set)
# 3) don't open anything (we will only use stdin if it's a real tty)
USE_TTY_FD=false
try_open_tty() {
    # close previous fd3 if any
    exec 3<&- 2>/dev/null || true

    if [[ -r /dev/tty ]]; then
        if exec 3</dev/tty 2>/dev/null; then
            USE_TTY_FD=true
            return 0
        else
            exec 3<&- 2>/dev/null || true
        fi
    fi

    if [[ -n "${SUDO_TTY:-}" && -r "${SUDO_TTY}" ]]; then
        if exec 3<"${SUDO_TTY}" 2>/dev/null; then
            USE_TTY_FD=true
            return 0
        else
            exec 3<&- 2>/dev/null || true
        fi
    fi

    USE_TTY_FD=false
    return 1
}

# read a single key (blocking first byte). Prefer fd3 when available.
read_key() {
    key=''
    if [[ "$USE_TTY_FD" == true ]]; then
        IFS= read -rsn1 key <&3 2>/dev/null || key=''
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 rest <&3 2>/dev/null || rest=''
            key+="$rest"
        fi
    else
        if [[ -t 0 ]]; then
            IFS= read -rsn1 key 2>/dev/null || key=''
            if [[ $key == $'\x1b' ]]; then
                IFS= read -rsn2 -t 0.05 rest 2>/dev/null || rest=''
                key+="$rest"
            fi
        else
            key=''
        fi
    fi
}

# Attempt to read a numeric menu choice from the user when single-key read fails.
# Returns selected number in the global variable "numeric_choice" (1-based).
numeric_choice=""
prompt_numeric_choice() {
    numeric_choice=""
    # Ensure we have a tty if possible
    try_open_tty || true

    local out="/dev/stdout"
    local in_fd="/dev/tty"
    if [[ "$USE_TTY_FD" == true ]]; then
        in_fd="/dev/fd/3"
        out="/dev/tty"
    elif [[ -r /dev/tty ]]; then
        in_fd="/dev/tty"
        out="/dev/tty"
    elif [[ -t 0 ]]; then
        in_fd="/dev/stdin"
        out="/dev/stdout"
    else
        # no terminal available
        return 1
    fi

    printf "No single-key input detected. Enter number (1=Install,2=Uninstall,3=Exit) [default=1]: " >"$out"
    IFS= read -r choice <"$in_fd" 2>/dev/null || choice=""
    choice="${choice%%[[:space:]]*}"
    case "$choice" in
        1|"" ) numeric_choice=1 ; return 0 ;;
        2) numeric_choice=2 ; return 0 ;;
        3|q|Q) numeric_choice=3 ; return 0 ;;
        *) return 1 ;;
    esac
}

# parse args
for arg in "$@"; do
    case "$arg" in
        --install|-i) ACTION="install" ;;
        --uninstall|-u) ACTION="uninstall" ;;
        --yes|-y) YES=true ;;
        --force|-f) FORCE=true ;;
        --interactive) FORCE_MENU=true ;;
        -h|--help) printf "Usage: %s [--install|--uninstall] [--yes] [--interactive]\n" "$0"; exit 0 ;;
        *) ;;
    esac
done

# DEBUG info helper
debug_dump() {
    if [[ -n "$DEBUG" ]]; then
        printf "DEBUG: -t0=%s -t1=%s SUDO_TTY=%s USE_TTY_FD=%s NONINTERACTIVE=%s CI=%s\n" \
            "$( [[ -t 0 ]] && echo true || echo false )" \
            "$( [[ -t 1 ]] && echo true || echo false )" \
            "${SUDO_TTY:-}" \
            "$USE_TTY_FD" \
            "${NONINTERACTIVE:-}" \
            "${CI:-}"
    fi
}

ensure_install_dir() {
    [[ -d "$INSTALL_DIR" ]] || mkdir -p "$INSTALL_DIR"
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
    log "Installing LinkZero..."
    ensure_install_dir
    TMP_DL="$(mktemp /tmp/linkzero-XXXXXX.sh)"
    trap 'rm -f "${TMP_DL}"' EXIT
    if ! download_script_to_temp "$SCRIPT_URL" "$TMP_DL"; then
        err "Failed to download $SCRIPT_URL"; exit 1
    fi
    if grep -qiE '<!doctype html|<html' "$TMP_DL" 2>/dev/null; then
        err "Downloaded file looks like HTML; check raw URL"; exit 1
    fi
    install_path="$INSTALL_DIR/$SCRIPT_NAME"
    mv "$TMP_DL" "$install_path"
    chmod +x "$install_path"
    log "Installed to $install_path"
}

uninstall_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    if [[ ! -f "$install_path" ]]; then
        warn "Not installed: $install_path"; return 0
    fi
    if [[ "$YES" != true ]]; then
        echo "Confirm removal (Enter to remove, any other key to cancel):"
        read_key
        if [[ -z "$key" ]]; then
            warn "No interactive input — cancelling uninstall."
            return 0
        fi
        if [[ "$key" != $'\n' && "$key" != $'\r' ]]; then
            warn "Uninstall cancelled."
            return 0
        fi
    fi
    rm -f "$install_path" && log "Removed $install_path"
}

# If explicit action requested, do it and exit
if [[ -n "$ACTION" ]]; then
    try_open_tty || true
    debug_dump
    case "$ACTION" in
        install) install_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
        uninstall) uninstall_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
    esac
fi

# Decide whether we can show the interactive menu
try_open_tty || true
debug_dump

CAN_MENU=false
if [[ "$FORCE_MENU" == true ]]; then
    CAN_MENU=true
elif [[ "$USE_TTY_FD" == true ]] || ( [[ -t 0 ]] && [[ -t 1 ]] && [[ -z "${NONINTERACTIVE:-}" ]] && [[ -z "${CI:-}" ]] ); then
    CAN_MENU=true
fi

if [[ "$CAN_MENU" != true ]]; then
    warn "Interactive menu not available — running non-interactive install."
    install_action
    exec 3<&- 2>/dev/null || true
    exit 0
fi

# show interactive menu (we have some tty fd to read from)
options=("Install LinkZero" "Uninstall LinkZero" "Exit")

# Preselect Uninstall if the script appears already installed.
if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" ]] || [[ -f "$INSTALL_DIR/$SCRIPT_NAME" ]]; then
    sel=1
else
    sel=0
fi

tput civis 2>/dev/null || true
echo "Use the arrow keys and Enter to choose."

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

    # If read_key produced empty key, try numeric-line fallback before bailing.
    if [[ -z "$key" ]]; then
        if prompt_numeric_choice; then
            case "$numeric_choice" in
                1) install_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
                2) uninstall_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
                3) echo "Exit."; exec 3<&- 2>/dev/null || true; exit 0 ;;
            esac
        else
            warn "No interactive input read; falling back to non-interactive install."
            tput cnorm 2>/dev/null || true
            exec 3<&- 2>/dev/null || true
            install_action
            exit 0
        fi
    fi

    case "$key" in
        $'\n'|$'\r')
            tput cnorm 2>/dev/null || true
            case $sel in
                0) install_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
                1) uninstall_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
                2) echo "Exit."; exec 3<&- 2>/dev/null || true; exit 0 ;;
            esac
            ;;
        $'\x1b[A'|$'\x1b[D')
            sel=$(( (sel-1 + ${#options[@]}) % ${#options[@]} ))
            tput cuu $(( ${#options[@]} + 1 )) 2>/dev/null || printf '\033[%dA' $(( ${#options[@]} + 1 ))
            ;;
        $'\x1b[B'|$'\x1b[C')
            sel=$(( (sel+1) % ${#options[@]} ))
            tput cuu $(( ${#options[@]} + 1 )) 2>/dev/null || printf '\033[%dA' $(( ${#options[@]} + 1 ))
            ;;
        *) ;;
    esac
done

# close fd 3
exec 3<&- 2>/dev/null || true
exit 0
