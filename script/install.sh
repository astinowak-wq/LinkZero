#!/usr/bin/env bash
#
# LinkZero installer — numbered interactive menu with a short "pre-autostart" menu
# that appears immediately after the "[INFO] Installed to ..." line and before
# the orange warning/countdown. This lets the user choose a per-run mode (launch,
# background, none, dry) which will then be applied 5 seconds after selection.
#
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
# "Orange" is represented with a yellow-ish ANSI color (best-effort)
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

# Small menu shown immediately before autostart; returns chosen mode on stdout.
# This is printed between the "[INFO] Installed to ..." line and the orange warning.
choose_autostart_for_run() {
    local default_mode="${1:-$(read_autostart_mode)}"

    # If no interactive terminal, return the default immediately
    if [[ ! -r /dev/tty && ! -t 1 ]]; then
        printf "%s" "$default_mode"
        return 0
    fi

    local out="/dev/tty"
    printf "\n" >"$out"
    printf "%b\n" "${ORANGE}Choose autostart mode for this run (the chosen mode will start 5 seconds after selection):${NC}" >"$out"
    printf "Current default: %s\n" "$default_mode" >"$out"
    printf " 1) launch     - start program in foreground after countdown\n" >"$out"
    printf " 2) background - start program in background after countdown\n" >"$out"
    printf " 3) none       - do NOT start program after install\n" >"$out"
    printf " 4) dry        - simulate install; do not write file nor launch\n" >"$out"
    printf "\n" >"$out"
    printf "Press Enter to use default (%s).\n" "$default_mode" >"$out"

    local choice=""
    read -r -p "Choose [1-4]: " choice </dev/tty || choice=""

    if [[ -z "$choice" ]]; then
        printf "%s" "$default_mode"
        return 0
    fi

    case "$choice" in
        1) printf "launch" ;;
        2) printf "background" ;;
        3) printf "none" ;;
        4) printf "dry" ;;
        *) printf "%s" "$default_mode" ;;
    esac
}

# Countdown + launch helper.
# For "dry" and "none" we still show a 5s countdown, but we do not start the program.
countdown_and_launch() {
    local install_path="$1"
    local mode="$2"
    local seconds=${3:-5}
    local outdev
    if [[ -r /dev/tty ]]; then outdev="/dev/tty"; else outdev="/dev/stdout"; fi

    case "$mode" in
        dry)
            printf "%b\n" "${ORANGE}Dry-run: installation simulated, the program will NOT be launched.${NC}" >"$outdev"
            ;;
        none)
            printf "%b\n" "${ORANGE}Autostart disabled: the installed program will not be launched automatically.${NC}" >"$outdev"
            ;;
        background)
            # exact warning line requested; printed in orange
            printf "%b\n" "${ORANGE}Warning: the installed program will be started automatically in ${seconds} seconds.${NC}" >"$outdev"
            ;;
        launch)
            # exact warning line requested; printed in orange
            printf "%b\n" "${ORANGE}Warning: the installed program will be started automatically in ${seconds} seconds.${NC}" >"$outdev"
            ;;
        *)
            printf "%b\n" "${ORANGE}Unknown autostart mode: %s — not launching.${NC}" "$mode" >"$outdev"
            return 0
            ;;
    esac

    # show countdown for all modes (so dry/none also have the 5s delay the user requested)
    for ((i=seconds;i>=1;i--)); do
        printf "\r%bStarting in %d... %b" "$ORANGE" "$i" "$NC" >"$outdev"
        sleep 1
    done
    printf "\n" >"$outdev"

    # If mode is dry or none: do not launch; just inform and return.
    if [[ "$mode" == "dry" ]]; then
        printf "%b\n" "${YELLOW}Dry-run complete: not launching ${install_path}${NC}" >"$outdev"
        return 0
    fi
    if [[ "$mode" == "none" ]]; then
        printf "%b\n" "${YELLOW}Autostart disabled for this run: not launching ${install_path}${NC}" >"$outdev"
        return 0
    fi

    # For launch/background ensure file exists and is executable
    if [[ ! -x "$install_path" ]]; then
        printf "%b\n" "${YELLOW}Installed file not executable or missing: ${install_path}${NC}" >"$outdev"
        return 0
    fi

    if [[ "$mode" == "launch" ]]; then
        printf "%b\n" "${GREEN}Launching ${install_path}${NC}" >"$outdev"
        if [[ -r /dev/tty ]] || [[ -t 1 ]]; then
            exec "$install_path" </dev/tty >/dev/tty 2>/dev/tty
        else
            nohup "$install_path" >/dev/null 2>&1 &
        fi
    elif [[ "$mode" == "background" ]]; then
        printf "%b\n" "${GREEN}Starting ${install_path} in background${NC}" >"$outdev"
        nohup "$install_path" >/dev/null 2>&1 &
    fi
}

# install_action supports an optional mode parameter. If interactive, it will show
# the pre-autostart menu between the "[INFO] Installed to ..." line and the warning.
install_action(){
    local cfg_mode="${1:-$(read_autostart_mode)}"

    log "Installing LinkZero... (configured autostart mode: $cfg_mode)"
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

    # Move into place (unless later dry-run prevents it); we'll decide run_mode next.
    mv "$TMP_DL" "$install_path"
    chmod +x "$install_path"
    log "Installed to $install_path"

    # --- NEW: show a tiny menu here, AFTER the "[INFO] Installed to ..." line and
    # BEFORE the orange warning/countdown. The user's choice is applied for this run.
    local run_mode="$cfg_mode"
    if [[ -r /dev/tty ]] || [[ -t 1 ]]; then
        run_mode="$(choose_autostart_for_run "$cfg_mode")"
    fi

    # If the per-run choice is "dry" we should simulate: remove the installed file
    # and still show the 5-second countdown (then do not launch).
    if [[ "$run_mode" == "dry" ]]; then
        # remove the installed file to simulate a dry-run (so the system is unchanged)
        rm -f "$install_path" || true
    fi

    # Now show the orange warning / countdown and apply run_mode.
    # The countdown_and_launch function prints the "Warning: the installed program will be started automatically in 5 seconds."
    countdown_and_launch "$install_path" "$run_mode" 5
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
