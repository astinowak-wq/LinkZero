#!/usr/bin/env bash
#
# LinkZero installer — simplified interactive menu (numbered choices)
# Uninstall no longer prompts — it deletes known installed files immediately.
#
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

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

# Flags
ACTION=""; YES=false; FORCE=false; FORCE_MENU=false
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

# Uninstall: no prompt — remove known files/directories immediately.
uninstall_action(){
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    local targets=("$install_path" "/etc/linkzero" "/usr/local/share/linkzero" "/var/lib/linkzero")
    local any_found=false to_remove=()
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

    echo "Removing the following items (no confirmation):"
    for t in "${to_remove[@]}"; do echo "  $t"; done

    # Perform removal (conservative reporting)
    for t in "${to_remove[@]}"; do
        if [[ -d "$t" ]]; then
            if rm -rf -- "$t"; then
                log "Removed directory $t"
            else
                warn "Failed to remove directory $t"
            fi
        else
            if rm -f -- "$t"; then
                log "Removed file $t"
            else
                warn "Failed to remove file $t"
            fi
        fi
    done

    log "Uninstall completed."
}

# Parse args
for arg in "$@"; do
    case "$arg" in
        --install|-i) ACTION="install" ;;
        --uninstall|-u) ACTION="uninstall" ;;
        --yes|-y) YES=true ;;   # kept for backward compatibility but uninstall no longer prompts
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

# Decide whether we can show the interactive menu
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

# ---------- Numbered interactive menu (robust) ----------
options=("Install LinkZero" "Uninstall LinkZero" "Exit")
declare -i sel_default=0
if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" || -f "$INSTALL_DIR/$SCRIPT_NAME" ]]; then
    sel_default=2   # default to Uninstall when already installed (menu numbering 1..3)
else
    sel_default=1
fi

echo "Use the numbers to choose and press Enter."
echo ""
for i in "${!options[@]}"; do
    num=$((i+1))
    prefix=" "
    if [[ $num -eq $sel_default ]]; then
        prefix="*"
    fi
    printf "%s %d) %s\n" "$prefix" "$num" "${options[$i]}"
done
echo ""

# Read choice from /dev/tty if available (works with sudo/piped runs). Fallback to stdin.
CHOICE=""
if [[ -r /dev/tty ]]; then
    read -r -p "Choose [1-3]: " CHOICE </dev/tty || CHOICE=""
else
    read -r -p "Choose [1-3]: " CHOICE || CHOICE=""
fi

# If empty (user hit Enter), use default selection
if [[ -z "$CHOICE" ]]; then
    CHOICE="$sel_default"
fi

case "$CHOICE" in
    1)
        install_action
        ;;
    2)
        uninstall_action
        ;;
    3)
        echo "Exit."
        ;;
    *)
        warn "Invalid choice: '$CHOICE' — falling back to non-interactive install."
        install_action
        ;;
esac

exit 0
