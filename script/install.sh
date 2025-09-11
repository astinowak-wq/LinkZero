#!/bin/bash
#
# LinkZero installer — interactive menu with robust tty/input handling
#
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# Print header early so logo/author show even if we later fall back
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

# Config
SCRIPT_URL="https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="linkzero-smtp"

ACTION=""; YES=false; FORCE=false; FORCE_MENU=false
DEBUG="${DEBUG:-}"

log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERR]${NC} $*"; }

# Try to open a terminal fd (3). Prefer /dev/tty then SUDO_TTY.
USE_TTY_FD=false
try_open_tty(){
    exec 3<&- 2>/dev/null || true
    if [[ -r /dev/tty ]]; then
        if exec 3</dev/tty 2>/dev/null; then USE_TTY_FD=true; return 0; fi
    fi
    if [[ -n "${SUDO_TTY:-}" && -r "${SUDO_TTY}" ]]; then
        if exec 3<"${SUDO_TTY}" 2>/dev/null; then USE_TTY_FD=true; return 0; fi
    fi
    USE_TTY_FD=false
    return 1
}

# Drain any pending bytes on the chosen input fd so stale input doesn't consume the user's press.
drain_pending_input(){
    if [[ "$USE_TTY_FD" == true ]]; then
        while IFS= read -rsn1 -t 0.01 -u 3 _ 2>/dev/null; do :; done
    elif [[ -t 0 ]]; then
        while IFS= read -rsn1 -t 0.01 _ 2>/dev/null; do :; done
    elif [[ -r /dev/tty ]]; then
        exec 4</dev/tty 2>/dev/null || true
        while IFS= read -rsn1 -t 0.01 -u 4 _ 2>/dev/null; do :; done
        exec 4<&- 2>/dev/null || true
    fi
}

# read a single key (blocking). Prefer fd3 when available.
# sets global 'key' to captured data; returns 0 on success, non-zero if no input device.
read_key(){
    key=''
    # prefer fd3 if available
    if [[ "$USE_TTY_FD" == true ]]; then
        if read -rsn1 -u 3 key 2>/dev/null; then
            if [[ $key == $'\x1b' ]]; then
                IFS= read -rsn2 -t 0.05 -u 3 rest 2>/dev/null || rest=''
                key+="$rest"
            fi
            return 0
        fi
    fi

    # fallback to stdin if it's a tty
    if [[ -t 0 ]]; then
        if read -rsn1 key 2>/dev/null; then
            if [[ $key == $'\x1b' ]]; then
                IFS= read -rsn2 -t 0.05 rest 2>/dev/null || rest=''
                key+="$rest"
            fi
            return 0
        fi
    fi

    # last resort: temporarily open /dev/tty on fd4
    if [[ -r /dev/tty ]]; then
        exec 4</dev/tty 2>/dev/null || true
        if read -rsn1 -u 4 key 2>/dev/null; then
            if [[ $key == $'\x1b' ]]; then
                IFS= read -rsn2 -t 0.05 -u 4 rest 2>/dev/null || rest=''
                key+="$rest"
            fi
            exec 4<&- 2>/dev/null || true
            return 0
        fi
        exec 4<&- 2>/dev/null || true
    fi

    key=''
    return 1
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
    esac
done

debug_dump(){
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

ensure_install_dir(){ [[ -d "$INSTALL_DIR" ]] || mkdir -p "$INSTALL_DIR"; }

download_script_to_temp(){
    local url="$1" tmp="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$tmp"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$tmp" "$url"
    else
        return 2
    fi
}

install_action(){
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

uninstall_action(){
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    local targets=("$install_path" "/etc/linkzero" "/usr/local/share/linkzero" "/var/lib/linkzero")
    local any_found=false to_remove=()
    for t in "${targets[@]}"; do
        if [[ -e "$t" ]]; then to_remove+=("$t"); any_found=true; fi
    done
    if [[ "$any_found" != true ]]; then warn "Nothing to remove. No known LinkZero files found."; return 0; fi
    echo "The following items will be removed:"
    for t in "${to_remove[@]}"; do echo "  $t"; done
    if [[ "$YES" != true ]]; then
        echo ""; echo -n "Confirm removal (y/N): "
        if ! read_key; then warn "No interactive input — cancelling uninstall."; return 1; fi
        case "$key" in [yY]) ;; *) warn "Uninstall cancelled."; return 0 ;; esac
    fi
    for t in "${to_remove[@]}"; do
        if [[ -d "$t" ]]; then rm -rf -- "$t" && log "Removed directory $t" || warn "Failed to remove $t"
        else rm -f -- "$t" && log "Removed file $t" || warn "Failed to remove $t"; fi
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

# Interactive menu
options=("Install LinkZero" "Uninstall LinkZero" "Exit")
declare -i sel=0
if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" || -f "$INSTALL_DIR/$SCRIPT_NAME" ]]; then sel=1; else sel=0; fi

tput civis 2>/dev/null || true
echo "Use the arrow keys and Enter to choose."

# Ensure we don't have stale input before showing the menu
drain_pending_input

redraw_menu(){
    printf "\n"
    for i in "${!options[@]}"; do
        if (( i == sel )); then printf "  \033[7m%s\033[0m\n" "${options[$i]}"
        else printf "   %s\n" "${options[$i]}"; fi
    done
}

redraw_menu

while true; do
    # blocking read for a single keypress (robust)
    if ! read_key; then
        warn "No interactive input read; falling back to non-interactive install."
        tput cnorm 2>/dev/null || true
        exec 3<&- 2>/dev/null || true
        install_action
        exit 0
    fi

    case "$key" in
        $'\n'|$'\r')
            tput cnorm 2>/dev/null || true
            case $((sel)) in
                0) exec 3<&- 2>/dev/null || true; install_action; exit 0 ;;
                1) exec 3<&- 2>/dev/null || true; uninstall_action; exit 0 ;;
                2) exec 3<&- 2>/dev/null || true; echo "Exit."; exit 0 ;;
            esac
            ;;
        $'\x1b[A'|$'\x1b[D') # up/left
            sel=$(( (sel - 1 + ${#options[@]}) % ${#options[@]} ))
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

exec 3<&- 2>/dev/null || true
exit 0
