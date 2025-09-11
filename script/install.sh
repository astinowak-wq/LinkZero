#!/bin/bash
#
# LinkZero installer — interactive menu with simplified, robust tty handling
#
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# Print header early
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

# Flags
ACTION=""; YES=false; FORCE=false; FORCE_MENU=false
DEBUG="${DEBUG:-}"

log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERR]${NC} $*"; }

# Choose input device: prefer /dev/tty (for sudo/piped runs), otherwise use stdin.
INPUT_DEV=""
INPUT_FD=0
open_input_dev() {
    # close any existing fd 3
    exec 3<&- 2>/dev/null || true
    if [[ -r /dev/tty ]]; then
        INPUT_DEV="/dev/tty"
        exec 3<"$INPUT_DEV" 2>/dev/null || return 1
        INPUT_FD=3
        return 0
    fi
    # fallback to stdin
    if [[ -t 0 ]]; then
        INPUT_DEV="stdin"
        INPUT_FD=0
        return 0
    fi
    INPUT_DEV=""
    return 1
}

close_input_dev() {
    if [[ "$INPUT_FD" -eq 3 ]]; then
        exec 3<&- 2>/dev/null || true
    fi
    INPUT_DEV=""; INPUT_FD=0
}

# Drain any pending bytes on the chosen input so stale presses don't get consumed.
drain_pending_input() {
    if ! open_input_dev >/dev/null 2>&1; then return 1; fi
    if [[ "$INPUT_FD" -eq 3 ]]; then
        # non-blocking short reads from fd 3
        while IFS= read -rsn1 -t 0.01 -u 3 _ 2>/dev/null; do :; done
    elif [[ "$INPUT_FD" -eq 0 ]]; then
        while IFS= read -rsn1 -t 0.01 _ 2>/dev/null; do :; done
    fi
    return 0
}

# Read one key (blocking) from the chosen input device, using stty on the controlling tty.
# Returns 0 and sets global 'key' on success; returns non-zero if no interactive device.
read_key() {
    key=''

    # Open input device (sets INPUT_DEV and INPUT_FD)
    if ! open_input_dev; then
        key=''; return 1
    fi

    # Save current stty for /dev/tty if available (best-effort)
    OLD_STTY=""
    if [[ -r /dev/tty ]]; then
        OLD_STTY=$(stty -g </dev/tty 2>/dev/null || true)
        # non-canonical, no echo, immediate return for each keypress
        stty -icanon -echo min 1 time 0 </dev/tty 2>/dev/null || true
    elif [[ -t 0 ]]; then
        OLD_STTY=$(stty -g 2>/dev/null || true)
        stty -icanon -echo min 1 time 0 2>/dev/null || true
    fi

    # perform blocking read from chosen fd
    if [[ "$INPUT_FD" -eq 3 ]]; then
        if read -rsn1 -u 3 key 2>/dev/null; then
            # read remaining bytes of escape sequence (short timeout)
            if [[ $key == $'\x1b' ]]; then
                IFS= read -rsn3 -t 0.06 -u 3 rest 2>/dev/null || rest=''
                key+="$rest"
            fi
        fi
    else
        # stdin
        if read -rsn1 key 2>/dev/null; then
            if [[ $key == $'\x1b' ]]; then
                IFS= read -rsn3 -t 0.06 rest 2>/dev/null || rest=''
                key+="$rest"
            fi
        fi
    fi

    # Restore stty
    if [[ -n "$OLD_STTY" ]]; then
        if [[ -r /dev/tty ]]; then
            stty "$OLD_STTY" </dev/tty 2>/dev/null || true
        else
            stty "$OLD_STTY" 2>/dev/null || true
        fi
    fi

    # close fd3 if we opened it
    if [[ "$INPUT_FD" -eq 3 ]]; then
        exec 3<&- 2>/dev/null || true
    fi

    # success if key non-empty
    if [[ -z "$key" ]]; then
        return 1
    fi
    return 0
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

debug_dump() {
    if [[ -n "$DEBUG" ]]; then
        printf "DEBUG: -t0=%s -t1=%s INPUT_DEV=%s NONINTERACTIVE=%s CI=%s\n" \
            "$( [[ -t 0 ]] && echo true || echo false )" \
            "$( [[ -t 1 ]] && echo true || echo false )" \
            "${INPUT_DEV:-}" \
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

# explicit actions
if [[ -n "$ACTION" ]]; then
    open_input_dev >/dev/null 2>&1 || true
    debug_dump
    case "$ACTION" in
        install) install_action; close_input_dev; exit 0 ;;
        uninstall) uninstall_action; close_input_dev; exit 0 ;;
    esac
fi

# menu availability
open_input_dev >/dev/null 2>&1 || true
debug_dump

CAN_MENU=false
if [[ "$FORCE_MENU" == true ]]; then CAN_MENU=true
elif [[ -n "$INPUT_DEV" ]] && [[ -t 1 ]] && [[ -z "${NONINTERACTIVE:-}" ]] && [[ -z "${CI:-}" ]]; then
    CAN_MENU=true
fi

if [[ "$CAN_MENU" != true ]]; then
    warn "Interactive menu not available — running non-interactive install."
    install_action
    close_input_dev
    exit 0
fi

# menu
options=("Install LinkZero" "Uninstall LinkZero" "Exit")
declare -i sel=0
if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" || -f "$INSTALL_DIR/$SCRIPT_NAME" ]]; then sel=1; else sel=0; fi

tput civis 2>/dev/null || true
echo "Use the arrow keys and Enter to choose."

# drain stale input
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
    if ! read_key; then
        warn "No interactive input read; falling back to non-interactive install."
        tput cnorm 2>/dev/null || true
        close_input_dev
        install_action
        exit 0
    fi

    case "$key" in
        $'\n'|$'\r')
            tput cnorm 2>/dev/null || true
            case $((sel)) in
                0) close_input_dev; install_action; exit 0 ;;
                1) close_input_dev; uninstall_action; exit 0 ;;
                2) close_input_dev; echo "Exit."; exit 0 ;;
            esac
            ;;
        $'\x1b'*)
            # arrow handling (common variants)
            case "$key" in
                $'\x1b[A'|$'\x1b[1;2A'|$'\x1b[OA') sel=$(( (sel - 1 + ${#options[@]}) % ${#options[@]} ));;
                $'\x1b[B'|$'\x1b[1;2B'|$'\x1b[OB') sel=$(( (sel + 1) % ${#options[@]} ));;
                $'\x1b[D'|$'\x1b[OD') sel=$(( (sel - 1 + ${#options[@]}) % ${#options[@]} ));;
                $'\x1b[C'|$'\x1b[OC') sel=$(( (sel + 1) % ${#options[@]} ));;
                *) ;;
            esac
            lines_to_move=$(( ${#options[@]} + 1 ))
            tput cuu "$lines_to_move" 2>/dev/null || printf '\033[%dA' "$lines_to_move"
            redraw_menu
            ;;
        *)
            # ignore other keys
            ;;
    esac
done

# cleanup
close_input_dev
exec 3<&- 2>/dev/null || true
tput cnorm 2>/dev/null || true
exit 0
