#!/bin/bash
#
# LinkZero installer — interactive menu with improved tty detection
# and a short pre-autostart menu that appears right after installation
# (between the "[INFO] Installed to ..." line and the orange "Warning: ..." line).
#
# NOTES:
# - The main menu only contains: Install / Uninstall / Exit (no "Configure Autostart Mode").
# - A separate, ephemeral pre-autostart menu appears immediately after install and
#   BEFORE the orange warning/countdown. It is independent from the main menu.
# - Dry-run removes the just-installed file (to simulate no-change) and still shows
#   the 5-second delay. The countdown prints one line per second to avoid display issues.
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

# ------------------ NEW: pre-autostart menu (only invoked inside install_action) ----------
# show a tiny numbered menu on the user's terminal (prefers fd3 or /dev/tty).
# returns one of: launch|background|none|dry (printed to stdout)
choose_prelaunch_mode() {
    local default="launch"
    local out="/dev/tty"
    local in_fd="/dev/tty"

    # If we don't have a terminal at all, return default immediately.
    if [[ "$USE_TTY_FD" != true && ! -r /dev/tty && ! -t 0 ]]; then
        printf "%s" "$default"
        return 0
    fi

    # prefer /dev/tty for both in/out when available
    if [[ -r /dev/tty ]]; then
        out="/dev/tty"
        in_fd="/dev/tty"
    elif [[ "$USE_TTY_FD" == true ]]; then
        # fd3 is available for reading; output to stdout so messages remain visible
        out="/dev/stdout"
        in_fd="/dev/fd/3"
    fi

    printf "\n" >"$out"
    printf "%b\n" "${ORANGE}Select what should happen after installation for this run:${NC}" >"$out"
    printf " 1) launch     - start program in foreground after countdown\n" >"$out"
    printf " 2) background - start program in background after countdown\n" >"$out"
    printf " 3) none       - do NOT start program after install\n" >"$out"
    printf " 4) dry        - simulate install (remove installed file) and do NOT launch\n" >"$out"
    printf "\n" >"$out"
    printf "Press Enter to use default (launch).\n" >"$out"
    printf "\n" >"$out"

    local choice=""
    # read choice using /dev/tty or fd3
    if [[ -r "$in_fd" ]]; then
        read -r -p "Choose [1-4]: " choice <"$in_fd" 2>/dev/null || choice=""
    else
        read -r -p "Choose [1-4]: " choice 2>/dev/null || choice=""
    fi

    if [[ -z "$choice" ]]; then
        printf "%s" "$default"
        return 0
    fi

    case "$choice" in
        1) printf "launch" ;;
        2) printf "background" ;;
        3) printf "none" ;;
        4) printf "dry" ;;
        *) printf "%s" "$default" ;;
    esac
}

# Countdown + optional launch — prints the requested orange warning and a 5s countdown.
# Use newline-per-second countdown (more robust across terminals and remote sessions).
countdown_and_apply_mode() {
    local install_path="$1"
    local mode="$2"
    local seconds=5
    local out="/dev/tty"
    if [[ ! -r /dev/tty ]]; then
        out="/dev/stdout"
    fi

    # Print the orange warning line
    printf "%b\n" "${ORANGE}Warning: the installed program will be started automatically in ${seconds} seconds.${NC}" >"$out"

    # Print a simple, reliable newline-based countdown to avoid single-line overwrite issues.
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
            if [[ -r /dev/tty ]]; then
                exec "$install_path" </dev/tty >/dev/tty 2>/dev/tty
            else
                # fallback to running in background if no tty for exec
                nohup "$install_path" >/dev/null 2>&1 &
            fi
            ;;
        *)
            printf "%b\n" "${YELLOW}Unknown mode: %s${NC}" "$mode" >"$out"
            return 0
            ;;
    esac
}

# install_action now shows the new pre-autostart menu (separate from main menu)
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

    # === NEW: show the pre-autostart menu here, AFTER the "[INFO] Installed to ..." line ===
    # This menu is intentionally independent from the main (install/uninstall) menu.
    try_open_tty || true
    local chosen_mode
    chosen_mode="$(choose_prelaunch_mode)" || chosen_mode="launch"

    # If the user selected dry, simulate by removing the installed file (system remains unchanged)
    if [[ "$chosen_mode" == "dry" ]]; then
        rm -f "$install_path" || true
    fi

    # Show the orange warning and 5-second countdown, and then apply the chosen mode.
    countdown_and_apply_mode "$install_path" "$chosen_mode"
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
if [[ -x "/usr/local/bin/$SCRIPT_NAME" ]] || [[ -f "/usr/local/bin/$SCRIPT_NAME" ]]; then
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

    # if read_key produced empty key, bail to non-interactive
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
            case $sel in
                0) exec 3<&- 2>/dev/null || true; install_action; exit 0 ;;
                1) exec 3<&- 2>/dev/null || true; uninstall_action; exit 0 ;;
                2) exec 3<&- 2>/dev/null || true; echo "Exit."; exit 0 ;;
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
