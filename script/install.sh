#!/bin/bash
#
# LinkZero installer — interactive menu with verbose tty/debug reporting
#
# This version prints explicit debug information about tty detection and will
# not silently exit. If the installer detects a non-interactive environment,
# it prints a clear message and waits for Enter so you can see the reason.
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

# Print header
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
# If neither works, USE_TTY_FD=false
USE_TTY_FD=false
try_open_tty() {
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

# Determine input/output paths to use for prompts.
INPUT_FD=""
OUTPUT_PATH=""
open_io() {
    INPUT_FD=""
    OUTPUT_PATH="/dev/stdout"

    if [[ "$USE_TTY_FD" == true ]]; then
        INPUT_FD="/dev/fd/3"
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

# Helper funcs
is_installed() {
    [[ -x "${INSTALL_DIR}/${SCRIPT_NAME}" ]]
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

# prelaunch menu (3 options)
choose_prelaunch_mode() {
    open_io

    if [[ -z "$INPUT_FD" ]]; then
        printf "launch"
        return 0
    fi

    printf "\n" >"$OUTPUT_PATH"
    printf "%b\n" "${ORANGE}Select what should happen after installation for this run:${NC}" >"$OUTPUT_PATH"
    printf " 1) launch     - start program in foreground immediately\n" >"$OUTPUT_PATH"
    printf " 2) dry        - run installed binary with --dry-run (do NOT start normally)\n" >"$OUTPUT_PATH"
    printf " 3) none       - do NOT start program after install (return to main menu)\n" >"$OUTPUT_PATH"
    printf "\n" >"$OUTPUT_PATH"
    read_line choice "Choose [1-3] (default=1): "
    choice="${choice%%[[:space:]]*}"
    case "$choice" in
        2) printf "dry" ;;
        3) printf "none" ;;
        *) printf "launch" ;;
    esac
}

# apply mode (no countdown)
countdown_and_apply_mode() {
    local install_path="$1"
    local mode="$2"
    open_io
    local out="$OUTPUT_PATH"

    case "$mode" in
        none)
            printf "%b\n" "${YELLOW}Autostart disabled for this run; not launching.${NC}" >"$out"
            return 0
            ;;
        dry)
            if [[ ! -x "$install_path" ]]; then
                printf "%b\n" "${YELLOW}Installed file missing or not executable: ${install_path}${NC}" >"$out"
                return 0
            fi
            printf "%b\n" "${GREEN}Running dry-run: ${install_path} --dry-run${NC}" >"$out"
            if [[ -w /dev/tty ]]; then
                ( "$install_path" --dry-run </dev/tty >/dev/tty 2>/dev/tty )
            else
                nohup "$install_path" --dry-run >/dev/null 2>&1 &
                printf "%b\n" "${GREEN}Dry-run started in background (nohup).${NC}" >"$out"
            fi
            return 0
            ;;
        launch)
            if [[ ! -x "$install_path" ]]; then
                printf "%b\n" "${YELLOW}Installed file missing or not executable: ${install_path}${NC}" >"$out"
                return 0
            fi
            printf "%b\n" "${GREEN}Launching ${install_path} (attached if possible)${NC}" >"$out"
            if [[ -w /dev/tty ]]; then
                ( "$install_path" </dev/tty >/dev/tty 2>/dev/tty ) &
                printf "%b\n" "${GREEN}Launched (attached subshell).${NC}" >"$out"
            else
                nohup "$install_path" >/dev/null 2>&1 &
                printf "%b\n" "${GREEN}Launched in background (nohup).${NC}" >"$out"
            fi
            return 0
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

    try_open_tty || true
    open_io
    chosen_mode="$(choose_prelaunch_mode)"

    countdown_and_apply_mode "$install_path" "$chosen_mode"

    if [[ "$chosen_mode" == "none" ]]; then
        return 0
    fi

    exec 3<&- 2>/dev/null || true
    exit 0
}

run_installed_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    open_io
    local out="$OUTPUT_PATH"

    if [[ ! -x "$install_path" ]]; then
        printf "%b\n" "${YELLOW}Installed file missing or not executable: ${install_path}${NC}" >"$out"
        return 0
    fi

    printf "%b\n" "${GREEN}Running installed program: ${install_path}${NC}" >"$out"
    if [[ -w /dev/tty ]]; then
        ( "$install_path" </dev/tty >/dev/tty 2>/dev/tty )
        printf "%b\n" "${GREEN}Program exited; returning to installer menu.${NC}" >"$out"
    else
        nohup "$install_path" >/dev/null 2>&1 &
        printf "%b\n" "${GREEN}Program started in background (nohup).${NC}" >"$out"
    fi
    return 0
}

uninstall_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    if [[ ! -f "$install_path" ]]; then
        warn "Not installed: $install_path"
        return 0
    fi

    rm -f "$install_path" && log "Removed $install_path"
    return 0
}

# If explicit action requested, do it and exit immediately
if [[ -n "$ACTION" ]]; then
    try_open_tty || true
    case "$ACTION" in
        install) install_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
        uninstall) uninstall_action; exec 3<&- 2>/dev/null || true; exit 0 ;;
    esac
fi

# Decide whether we can show the interactive menu
try_open_tty || true
open_io

# Print explicit debug status so you can see what happened
{
    printf "%b\n" "${BLUE}-- Debug: TTY/Environment status --${NC}"
    printf "stdin isatty: %s\n" "$( [[ -t 0 ]] && echo true || echo false )"
    printf "stdout isatty: %s\n" "$( [[ -t 1 ]] && echo true || echo false )"
    printf "USE_TTY_FD: %s\n" "$USE_TTY_FD"
    printf "SUDO_TTY: %s\n" "${SUDO_TTY:-<unset>}"
    printf "TERM: %s\n" "${TERM:-<unset>}"
    printf "CI: %s\n" "${CI:-<unset>}"
    printf "NONINTERACTIVE: %s\n" "${NONINTERACTIVE:-<unset>}"
    printf "%b\n" "${BLUE}-- End debug --${NC}"
} >"$OUTPUT_PATH"

# determine if we can show the interactive menu
CAN_MENU=false
if [[ "$FORCE_MENU" == true ]]; then
    CAN_MENU=true
elif [[ "$USE_TTY_FD" == true ]] || [[ -t 0 ]] || [[ -t 1 ]]; then
    CAN_MENU=true
fi

# If we can't show the menu, do NOT auto-install and do not exit silently.
if [[ "$CAN_MENU" != true ]]; then
    printf "%b\n" "${RED}[ERROR] Interactive menu not available. Script will not continue automatically.${NC}" >"$OUTPUT_PATH"
    printf "%b\n" "Run this script from a terminal, or use --install to install non-interactively." >"$OUTPUT_PATH"
    # wait so user can see message (prevents immediate silent exit)
    if [[ -w /dev/tty ]]; then
        printf "\nPress Enter to exit..." > /dev/tty
        read -r _ </dev/tty || true
    else
        read -r _ || true
    fi
    exec 3<&- 2>/dev/null || true
    exit 1
fi

# Numeric-style interactive main menu loop (dynamic options when installed)
while true; do
    # build menu dynamically
    MENU_TEXT=()
    MENU_ACTION=()

    MENU_TEXT+=("Install LinkZero")
    MENU_ACTION+=("install")

    if is_installed; then
        MENU_TEXT+=("Run LinkZero")
        MENU_ACTION+=("run")
    fi

    MENU_TEXT+=("Uninstall LinkZero")
    MENU_ACTION+=("uninstall")

    MENU_TEXT+=("Exit")
    MENU_ACTION+=("exit")

    # choose default: prefer "run" if installed, otherwise "install"
    default_choice_index=1
    if is_installed; then
        for idx in "${!MENU_ACTION[@]}"; do
            if [[ "${MENU_ACTION[$idx]}" == "run" ]]; then
                default_choice_index=$((idx+1))
                break
            fi
        done
    else
        default_choice_index=1
    fi

    try_open_tty || true
    open_io

    printf "\n" >"$OUTPUT_PATH"
    printf "Use numeric menu to choose an action:\n" >"$OUTPUT_PATH"
    for i in "${!MENU_TEXT[@]}"; do
        printf "  %d) %s\n" $((i+1)) "${MENU_TEXT[$i]}" >"$OUTPUT_PATH"
    done

    # Prompt for selection
    read_line selection "Choose [1-${#MENU_TEXT[@]}] (default=${default_choice_index}): "
    selection="${selection%%[[:space:]]*}"

    if [[ -z "$selection" ]]; then
        selection="${default_choice_index}"
    fi

    # validate numeric
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        printf "%b\n" "${YELLOW}Invalid selection; try again.${NC}" >"$OUTPUT_PATH"
        continue
    fi

    if (( selection < 1 || selection > ${#MENU_ACTION[@]} )); then
        printf "%b\n" "${YELLOW}Invalid selection; try again.${NC}" >"$OUTPUT_PATH"
        continue
    fi

    chosen_action="${MENU_ACTION[$((selection-1))]}"

    case "$chosen_action" in
        install)
            install_action
            continue
            ;;
        run)
            run_installed_action
            continue
            ;;
        uninstall)
            uninstall_action
            continue
            ;;
        exit)
            printf "Exit.\n" >"$OUTPUT_PATH"
            exec 3<&- 2>/dev/null || true
            exit 0
            ;;
        *)
            printf "%b\n" "${YELLOW}Unhandled action; try again.${NC}" >"$OUTPUT_PATH"
            continue
            ;;
    esac
done

# close fd 3 (should be unreachable)
exec 3<&- 2>/dev/null || true
exit 0
