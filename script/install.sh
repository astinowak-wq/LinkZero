#!/bin/bash
#
# LinkZero installer — interactive menu with improved tty detection
#
# Test: run 'sudo bash script/install.sh' (or download and run) to see Uninstall preselected when
#       the script is already installed at /usr/local/bin/linkzero-smtp.
#
set -euo pipefail

# -- Early header: show logo/author even when falling back to non-interactive mode --
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

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
# Implementation note:
# Previously this function required a non-blocking read probe to mark fd3 usable.
# That probe caused failures in some sudo/piped environments. Now we treat a successful
# exec 3<... as sufficient to indicate a usable terminal fd.
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
# sets global 'key'
read_key() {
    key=''
    if [[ "$USE_TTY_FD" == true ]]; then
        # read from fd3 (blocking). This allows interactive menus even when stdin is not a tty.
        IFS= read -rsn1 key <&3 2>/dev/null || key=''
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 rest <&3 2>/dev/null || rest=''
            key+="$rest"
        fi
    else
        # only read from stdin if stdin is tty
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

    # If we didn't get anything, try one last time reading directly from /dev/tty
    # This helps environments where fd3 may be closed or stdin is not the input device
    # that actually receives key presses (some sudo/piped terminals).
    if [[ -z "$key" && -r /dev/tty ]]; then
        IFS= read -rsn1 key </dev/tty 2>/dev/null || key=''
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 rest </dev/tty 2>/dev/null || rest=''
            key+="$rest"
        fi
    fi
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

# Uninstall: remove files that were created by installation.
# We remove the main installed script and a small set of well-known dirs (if present).
# The user is prompted unless --yes was provided.
uninstall_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    local targets=("$install_path" "/etc/linkzero" "/usr/local/share/linkzero" "/var/lib/linkzero")
    local any_found=false

    # Collect existing targets
    local to_remove=()
    for t in "${targets[@]}"; do
        if [[ -e "$t" ]]; then
            to_remove+=("$t")
            any_found=true
        fi
    done

    if [[ "$any_found" != true ]]; then
        warn "Nothing to remove. No known LinkZero files found."
        return 0
    fi

    echo "The following items will be removed:"
    for t in "${to_remove[@]}"; do
        echo "  $t"
    done

    if [[ "$YES" != true ]]; then
        echo ""
        echo -n "Confirm removal (y/N): "
        # read a single key for yes/no
        read_key
        # normalize key
        case "$key" in
            [yY]) ;; # proceed
            *) warn "Uninstall cancelled."; return 0 ;;
        esac
    fi

    # Perform removal (be conservative and report results)
    for t in "${to_remove[@]}"; do
        if [[ -d "$t" ]]; then
            rm -rf -- "$t" && log "Removed directory $t" || warn "Failed to remove $t"
        else
            rm -f -- "$t" && log "Removed file $t" || warn "Failed to remove $t"
        fi
    done

    log "Uninstall completed."
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
# This improves UX: users who already have LinkZero installed are likely trying to uninstall.
# Override: use --install or --uninstall flags, or --interactive to force the menu.
declare -i sel=0
if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" ]] || [[ -f "$INSTALL_DIR/$SCRIPT_NAME" ]]; then
    sel=1
else
    sel=0
fi

tput civis 2>/dev/null || true
echo "Use the arrow keys and Enter to choose."

# helper: redraw menu
redraw_menu() {
    printf "\n"
    for i in "${!options[@]}"; do
        if (( i == sel )); then
            printf "  \033[7m%s\033[0m\n" "${options[$i]}"
        else
            printf "   %s\n" "${options[$i]}"
        fi
    done
}

# initial draw
redraw_menu

while true; do
    read_key

    # if read_key produced empty key, try one more targeted read from /dev/tty before bailing
    if [[ -z "$key" ]]; then
        # attempt once more (blocking) from /dev/tty
        if [[ -r /dev/tty ]]; then
            IFS= read -rsn1 key </dev/tty 2>/dev/null || key=''
            if [[ $key == $'\x1b' ]]; then
                IFS= read -rsn2 -t 0.05 rest </dev/tty 2>/dev/null || rest=''
                key+="$rest"
            fi
        fi
    fi

    # if still empty, bail to non-interactive
    if [[ -z "$key" ]]; then
        warn "No interactive input read; falling back to non-interactive install."
        tput cnorm 2>/dev/null || true
        exec 3<&- 2>/dev/null || true
        install_action
        exit 0
    fi

    case "$key" in
        $'\n'|$'\r')
            tput cnorm 2>/dev/null || true
            # use arithmetic evaluation to ensure sel is treated as integer
            case $((sel)) in
                0)
                    exec 3<&- 2>/dev/null || true
                    install_action
                    exit 0
                    ;;
                1)
                    exec 3<&- 2>/dev/null || true
                    uninstall_action
                    exit 0
                    ;;
                2)
                    exec 3<&- 2>/dev/null || true
                    echo "Exit."
                    exit 0
                    ;;
            esac
            ;;
        $'\x1b[A'|$'\x1b[D') # up/left
            sel=$(( (sel - 1 + ${#options[@]}) % ${#options[@]} ))
            # move cursor up the number of menu lines + 1 blank line
            lines_to_move=$(( ${#options[@]} + 1 ))
            tput cuu "$lines_to_move" 2>/dev/null || printf '\033[%dA' "$lines_to_move"
            redraw_menu
            ;;
        $'\x1b[B'|$'\x1b[C') # down/right
            sel=$(( (sel + 1) % ${#options[@]} ))
            lines_to_move=$(( ${#options[@]} + 1 ))
            tput cuu "$lines_to_move" 2>/dev/null || printf '\033[%dA' "$lines_to_move"
            redraw_menu
            ;;
        *)
            # ignore other keys
            ;;
    esac
done

# close fd 3
exec 3<&- 2>/dev/null || true
exit 0
