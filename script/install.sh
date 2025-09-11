#!/usr/bin/env bash
#
# LinkZero installer — numbered interactive menu with configurable autostart mode
# Supported autostart modes:
#   launch     - start installed program in foreground after countdown (default)
#   background - start installed program in background after countdown
#   none       - do NOT start program after install
#   dry        - simulate install; do not write the installed file
#
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
# "Orange" (best-effort using a yellow tone; 256-color alternative: '\033[38;5;214m')
ORANGE='\033[0;33m'

# Header (show when stdout is a terminal)
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
CONFIG_DIR="/etc/linkzero"
CONFIG_FILE="$CONFIG_DIR/autostart_mode"

# State flags
ACTION=""
YES=false
FORCE=false
FORCE_MENU=false
DEBUG="${DEBUG:-}"

log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERR]${NC} $*"; }

debug_dump() {
    if [[ -n "$DEBUG" ]]; then
        printf "DEBUG: -t0=%s -t1=%s /dev/tty=%s NONINTERACTIVE=%s CI=%s\n" \
            "$( [[ -t 0 ]] && echo true || echo false )" \
            "$( [[ -t 1 ]] && echo true || echo false )" \
            "$( [[ -r /dev/tty ]] && echo true || echo false )" \
            "${NONINTERACTIVE:-}" "${CI:-}"
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

# Read autostart mode (sanitized). Returns one of: launch|background|none|dry
read_autostart_mode(){
    if [[ -f "$CONFIG_FILE" ]]; then
        local v
        v=$(tr -d '\r\n' <"$CONFIG_FILE" 2>/dev/null || true)
        case "$v" in
            launch|background|none|dry) printf "%s" "$v"; return 0 ;;
            *) printf "launch"; return 0 ;;
        esac
    fi
    printf "launch"
}

# Write autostart mode to CONFIG_FILE; returns 0 on success
write_autostart_mode(){
    local mode="$1"
    case "$mode" in
        launch|background|none|dry) ;;
        *) return 1 ;;
    esac
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    printf "%s\n" "$mode" > "$CONFIG_FILE" || return 1
    return 0
}

# Print to /dev/tty when available (so piped runs still show messages)
_output_dev() {
    if [[ -r /dev/tty ]]; then
        printf "%b" "$1" > /dev/tty
    else
        printf "%b" "$1"
    fi
}

# Countdown + launch respects mode
countdown_and_launch() {
    local install_path="$1"
    local mode="$2"
    local seconds=${3:-5}
    local outdev
    if [[ -r /dev/tty ]]; then outdev="/dev/tty"; else outdev="/dev/stdout"; fi

    case "$mode" in
        dry)
            printf "%b\n" "${ORANGE}Dry-run mode: installation simulated, program will NOT be launched.${NC}" >"$outdev"
            return 0
            ;;
        none)
            printf "%b\n" "${ORANGE}Autostart disabled: the installed program will not be launched automatically.${NC}" >"$outdev"
            return 0
            ;;
        background)
            printf "%b\n" "${ORANGE}Program will be started in background after ${seconds} seconds.${NC}" >"$outdev"
            ;;
        launch)
            printf "%b\n" "${ORANGE}Warning: the installed program will be started automatically in ${seconds} seconds.${NC}" >"$outdev"
            ;;
        *)
            printf "%b\n" "${ORANGE}Unknown autostart mode: %s — not launching.${NC}" "$mode" >"$outdev"
            return 0
            ;;
    esac

    for ((i=seconds;i>=1;i--)); do
        printf "\r%bStarting in %d... %b" "$ORANGE" "$i" "$NC" >"$outdev"
        sleep 1
    done
    printf "\n" >"$outdev"

    if [[ ! -x "$install_path" ]]; then
        printf "%b\n" "${YELLOW}Installed file not executable or missing: ${install_path}${NC}" >"$outdev"
        return 0
    fi

    case "$mode" in
        launch)
            printf "%b\n" "${GREEN}Launching ${install_path}${NC}" >"$outdev"
            # Attach to terminal if possible; exec replaces the installer process
            if [[ -r /dev/tty ]] || [[ -t 1 ]]; then
                exec "$install_path" </dev/tty >/dev/tty 2>/dev/tty
            else
                # no tty: run in background as fallback
                nohup "$install_path" >/dev/null 2>&1 &
            fi
            ;;
        background)
            printf "%b\n" "${GREEN}Starting ${install_path} in background${NC}" >"$outdev"
            nohup "$install_path" >/dev/null 2>&1 &
            ;;
    esac
}

# install_action supports an optional mode parameter. 'dry' doesn't write the installed file.
install_action(){
    local mode="${1:-$(read_autostart_mode)}"

    log "Installing LinkZero... (autostart mode: $mode)"
    ensure_install_dir
    TMP_DL="$(mktemp /tmp/linkzero-XXXXXX.sh)"
    trap 'rm -f "${TMP_DL}"' EXIT
    if ! download_script_to_temp "$SCRIPT_URL" "$TMP_DL"; then
        err "Failed to download $SCRIPT_URL"; exit 1
    fi
    if grep -qiE '<!doctype html|<html' "$TMP_DL" 2>/dev/null; then
        err "Downloaded file looks like HTML; check raw URL"; rm -f "$TMP_DL"; exit 1
    fi

    install_path="$INSTALL_DIR/$SCRIPT_NAME"

    if [[ "$mode" == "dry" ]]; then
        printf "%b\n" "${ORANGE}Dry-run: would install $TMP_DL -> $install_path${NC}"
        rm -f "$TMP_DL"
        countdown_and_launch "$install_path" "$mode" 5
        return 0
    fi

    mv "$TMP_DL" "$install_path"
    chmod +x "$install_path"
    log "Installed to $install_path"

    countdown_and_launch "$install_path" "$mode" 5
}

# Uninstall: no prompt — remove known files/directories immediately.
uninstall_action(){
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    local targets=("$install_path" "$CONFIG_DIR" "/usr/local/share/linkzero" "/var/lib/linkzero")
    local any_found=false to_remove=()
    for t in "${targets[@]}"; do
        if [[ -e "$t" ]]; then to_remove+=("$t"); any_found=true; fi
    done

    if [[ "$any_found" != true ]]; then
        warn "Nothing to remove. No known LinkZero files found."
        return 0
    fi

    echo "Removing the following items (no confirmation):"
    for t in "${to_remove[@]}"; do echo "  $t"; done

    for t in "${to_remove[@]}"; do
        if [[ -d "$t" ]]; then
            if rm -rf -- "$t"; then log "Removed directory $t"; else warn "Failed to remove directory $t"; fi
        else
            if rm -f -- "$t"; then log "Removed file $t"; else warn "Failed to remove file $t"; fi
        fi
    done

    log "Uninstall completed."
}

# Configure autostart mode menu (same numbered-menu logic)
configure_autostart_menu(){
    echo ""
    echo "Autostart mode configuration"
    echo "Current mode: $(read_autostart_mode)"
    echo "Choose autostart mode and press Enter:"
    echo " 1) launch     - start program in foreground after countdown (default)"
    echo " 2) background - start program in background after countdown"
    echo " 3) none       - do NOT start program after install"
    echo " 4) dry        - simulate install; do not write file nor launch"
    echo ""

    local choice
    if [[ -r /dev/tty ]]; then
        read -r -p "Choose [1-4]: " choice </dev/tty || choice=""
    else
        read -r -p "Choose [1-4]: " choice || choice=""
    fi

    if [[ -z "$choice" ]]; then choice=1; fi

    case "$choice" in
        1) write_autostart_mode "launch" && echo "Autostart mode set to: launch" ;;
        2) write_autostart_mode "background" && echo "Autostart mode set to: background" ;;
        3) write_autostart_mode "none" && echo "Autostart mode set to: none" ;;
        4) write_autostart_mode "dry" && echo "Autostart mode set to: dry (simulated installs)" ;;
        *) echo "Invalid choice" ;;
    esac
}

# Parse args
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

# If explicit action requested, run it and exit
if [[ -n "$ACTION" ]]; then
    debug_dump
    case "$ACTION" in
        install) install_action; exit 0 ;;
        uninstall) uninstall_action; exit 0 ;;
    esac
fi

# Decide whether to show interactive menu
debug_dump
CAN_MENU=false
if [[ "$FORCE_MENU" == true ]]; then
    CAN_MENU=true
elif [[ -r /dev/tty && -t 1 && -z "${NONINTERACTIVE:-}" && -z "${CI:-}" ]]; then
    CAN_MENU=true
elif [[ -t 0 && -t 1 && -z "${NONINTERACTIVE:-}" && -z "${CI:-}" ]]; then
    CAN_MENU=true
fi

if [[ "$CAN_MENU" != true ]]; then
    warn "Interactive menu not available — running non-interactive install."
    install_action
    exit 0
fi

# ---------- Main numbered interactive menu ----------
options=("Install LinkZero" "Uninstall LinkZero" "Configure Autostart Mode" "Exit")
declare -i sel_default=0
if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" || -f "$INSTALL_DIR/$SCRIPT_NAME" ]]; then
    sel_default=2   # default to Uninstall when already installed (menu numbering 1..4)
else
    sel_default=1
fi

echo "Use the numbers to choose and press Enter."
echo ""
for i in "${!options[@]}"; do
    num=$((i+1))
    prefix=""
    if [[ $num -eq $sel_default ]]; then prefix="*"; fi
    printf "%s %d) %s\n" "$prefix" "$num" "${options[$i]}"
done
echo ""

CHOICE=""
if [[ -r /dev/tty ]]; then
    read -r -p "Choose [1-4]: " CHOICE </dev/tty || CHOICE=""
else
    read -r -p "Choose [1-4]: " CHOICE || CHOICE=""
fi

if [[ -z "$CHOICE" ]]; then CHOICE="$sel_default"; fi

case "$CHOICE" in
    1)
        MODE="$(read_autostart_mode)"
        install_action "$MODE"
        ;;
    2)
        uninstall_action
        ;;
    3)
        configure_autostart_menu
        ;;
    4)
        echo "Exit."
        ;;
    *)
        warn "Invalid choice: '$CHOICE' — falling back to non-interactive install."
        install_action
        ;;
esac

exit 0
