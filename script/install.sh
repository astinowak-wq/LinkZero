#!/bin/bash
#
# LinkZero installer — numeric-menu main menu + pre-autostart numeric menu
#
# Uses line-based numeric input for the main menu (1/2/3) and pre-autostart (1-4).
# Uninstall removes the installed file without confirmation and then returns to the main menu.
#
set -euo pipefail

# -- Colors / header --
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'
ORANGE='\033[0;33m'

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

# Determine input/output paths to use for line-based prompts.
INPUT_FD=""
OUTPUT_PATH=""
open_io() {
    INPUT_FD=""
    OUTPUT_PATH="/dev/stdout"

    if [[ "$USE_TTY_FD" == true ]]; then
        # fd3 is open for read
        INPUT_FD="/dev/fd/3"
        # prefer /dev/tty for output so prompts are visible even if stdout is redirected
        if [[ -w /dev/tty ]]; then
            OUTPUT_PATH="/dev/tty"
        else
            OUTPUT_PATH="/dev/stdout"
        fi
    elif [[ -r /dev/tty ]]; then
        INPUT_FD="/dev/tty"
        OUTPUT_PATH="/dev/tty"
    elif [[ -t 0 ]]; then
        INPUT_FD="/dev/stdin"
        OUTPUT_PATH="/dev/stdout"
    else
        INPUT_FD=""
        OUTPUT_PATH="/dev/stdout"
    fi
}

# Read a line from chosen input fd into variable named by first arg.
# Usage: read_line varname "prompt text"
read_line() {
    local __var="$1"; shift
    local prompt="$*"
    if [[ -n "$prompt" ]]; then
        printf "%s" "$prompt" >"$OUTPUT_PATH" 2>/dev/null || true
    fi
    if [[ -n "$INPUT_FD" ]]; then
        IFS= read -r line <"$INPUT_FD" 2>/dev/null || line=""
    else
        line=""
    fi
    printf -v "$__var" "%s" "$line"
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

# Pre-autostart numeric menu (1-4)
choose_prelaunch_mode() {
    open_io

    if [[ -z "$INPUT_FD" ]]; then
        # no interactive input — default to launch
        printf "launch"
        return 0
    fi

    printf "\n" >"$OUTPUT_PATH"
    printf "%b\n" "${ORANGE}Select what should happen after installation for this run:${NC}" >"$OUTPUT_PATH"
    printf " 1) launch     - start program in foreground after countdown\n" >"$OUTPUT_PATH"
    printf " 2) background - start program in background after countdown\n" >"$OUTPUT_PATH"
    printf " 3) none       - do NOT start program after install\n" >"$OUTPUT_PATH"
    printf " 4) dry        - simulate install (remove installed file) and do NOT launch\n" >"$OUTPUT_PATH"
    printf "\n" >"$OUTPUT_PATH"
    read_line choice "Choose [1-4] (default=1): "
    choice="${choice%%[[:space:]]*}"
    case "$choice" in
        2) printf "background" ;;
        3) printf "none" ;;
        4) printf "dry" ;;
        *) printf "launch" ;;
    esac
}

# Countdown + apply mode
countdown_and_apply_mode() {
    local install_path="$1"
    local mode="$2"
    local seconds=5
    open_io
    local out="$OUTPUT_PATH"

    printf "%b\n" "${ORANGE}Warning: the installed program will be started automatically in ${seconds} seconds.${NC}" >"$out"
    for ((i=seconds;i>=1;i--)); do
        printf "%b\n" "${ORANGE}Starting in ${i}...${NC}" >"$out"
        sleep 1
    done

    case "$mode" in
        dry)
            printf "%b\n" "${YELLOW}Dry-run: simulated install; not launching.${NC}" >"$out"
            return 0
            ;;
        none)
            printf "%b\n" "${YELLOW}Autostart disabled for this run; not launching.${NC}" >"$out"
            return 0
            ;;
        background)
            if [[ ! -x "$install_path" ]]; then
                printf "%b\n" "${YELLOW}Installed file missing or not executable: ${install_path}${NC}" >"$out"
                return 0
            fi
            printf "%b\n" "${GREEN}Starting ${install_path} in background${NC}" >"$out"
            nohup "$install_path" >/dev/null 2>&1 &
            return 0
            ;;
        launch)
            if [[ ! -x "$install_path" ]]; then
                printf "%b\n" "${YELLOW}Installed file missing or not executable: ${install_path}${NC}" >"$out"
                return 0
            fi
            printf "%b\n" "${GREEN}Launching ${install_path}${NC}" >"$out"
            # attach to terminal if possible
            if [[ -w /dev/tty ]]; then
                exec "$install_path" </dev/tty >/dev/tty 2>/dev/tty
            else
                nohup "$install_path" >/dev/null 2>&1 &
            fi
            ;;
        *)
            printf "%b\n" "${YELLOW}Unknown mode: %s${NC}" "$mode" >"$out"
            return 0
            ;;
    esac
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

    # show the separate pre-autostart numeric menu
    try_open_tty || true
    open_io
    chosen_mode="$(choose_prelaunch_mode)"
    # If user selected dry, remove the file before countdown/launch
    if [[ "$chosen_mode" == "dry" ]]; then
        rm -f "$install_path" || true
    fi
    countdown_and_apply_mode "$install_path" "$chosen_mode"
}

uninstall_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    if [[ ! -f "$install_path" ]]; then
        warn "Not installed: $install_path"
        return 0
    fi

    # Uninstall: no confirmation, just remove
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

# Numeric-style interactive main menu loop
options=("Install LinkZero" "Uninstall LinkZero" "Exit")

while true; do
    # Determine default based on presence of installed file
    if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" ]] || [[ -f "$INSTALL_DIR/$SCRIPT_NAME" ]]; then
        default_choice=2
    else
        default_choice=1
    fi

    try_open_tty || true
    open_io

    printf "\n" >"$OUTPUT_PATH"
    printf "Use numeric menu to choose an action:\n" >"$OUTPUT_PATH"
    for i in "${!options[@]}"; do
        printf "  %d) %s\n" $((i+1)) "${options[$i]}" >"$OUTPUT_PATH"
    done

    # Prompt for selection
    read_line selection "Choose [1-3] (default=${default_choice}): "
    selection="${selection%%[[:space:]]*}"

    if [[ -z "$selection" ]]; then
        selection="$default_choice"
    fi

    case "$selection" in
        1)
            install_action
            # After install, exit the installer run (preserves original behavior)
            exec 3<&- 2>/dev/null || true
            exit 0
            ;;
        2)
            uninstall_action
            # After uninstall, return to top of the loop so the user can choose again
            continue
            ;;
        3|q|Q)
            echo "Exit." >"$OUTPUT_PATH"
            exec 3<&- 2>/dev/null || true
            exit 0
            ;;
        *)
            warn "Invalid selection; try again."
            continue
            ;;
    esac
done

# close fd 3 (should be unreachable, but keep for completeness)
exec 3<&- 2>/dev/null || true
exit 0
