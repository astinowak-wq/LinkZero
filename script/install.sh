#!/bin/bash
#
# LinkZero installer — numeric-menu main menu (looping) with reliable tty IO
#
# Update: removed all countdowns — actions (launch / dry / none) occur immediately.
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
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'

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

# Use this exact line as the animated author text (do NOT create another variable).
AUTHOR_TEXT=" a u t h o r :    D A N I E L    N O W A K O W S K I"

# Print the author line initially in RED (fallback)
# Note: we print it normally (with newline) so the layout stays the same.
echo -e "${RED}${BOLD}${AUTHOR_TEXT}${NC}"
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
        # fallback to stdin/stdout if it's a real tty
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

# --------------- Rainbow author animation helpers ----------------

# Variables to hold animator PID and author position
ANIM_PID=""
AUTHOR_ROW=""
AUTHOR_COL=""

# Get the cursor position (row;col) by querying the terminal. Requires INPUT_FD and OUTPUT_PATH set.
# Returns "row;col" on stdout, or empty string on failure.
get_cursor_pos() {
    # REQUIRE: INPUT_FD readable, OUTPUT_PATH writable
    if [[ -z "$INPUT_FD" ]] || [[ ! -r "$INPUT_FD" ]]; then
        return 1
    fi
    # Save terminal settings, set raw mode temporarily to read response
    local oldstty
    oldstty=$(stty -g <"$INPUT_FD" 2>/dev/null || true)
    stty raw -echo <"$INPUT_FD" 2>/dev/null || true
    # Request cursor position
    printf '\033[6n' >"$OUTPUT_PATH" 2>/dev/null
    # Read response of the form ESC[row;colR]
    local response
    # read up to 'R'
    IFS=';' read -r -d R response <"$INPUT_FD" 2>/dev/null || true
    # restore terminal settings
    if [[ -n "$oldstty" ]]; then
        stty "$oldstty" <"$INPUT_FD" 2>/dev/null || true
    fi
    # response will contain something like ^[[24;1
    # strip leading ESC and '['
    response="${response#*[}"
    # split
    local row="${response%%;*}"
    local col="${response#*;}"
    if [[ -n "$row" && -n "$col" ]]; then
        printf "%s;%s" "$row" "$col"
        return 0
    fi
    return 1
}

# Animator: cycles through colors and updates the author line at a fixed absolute position.
# Usage: animate_author <row> <col>
animate_author() {
    local row="$1" col="$2"
    local colors=("$RED" "$ORANGE" "$YELLOW" "$GREEN" "$CYAN" "$BLUE" "$MAGENTA")
    local idx=0
    # Protect against missing OUTPUT_PATH
    local out="${OUTPUT_PATH:-/dev/stdout}"
    # hide cursor while animating so it doesn't blink and interfere
    printf '\033[?25l' >"$out" 2>/dev/null || true
    while true; do
        local color="${colors[$((idx % ${#colors[@]}))]}"
        # Save cursor, move to absolute pos, print colored author, restore cursor
        printf '\033[s' >"$out" 2>/dev/null || true
        printf '\033[%s;%sH' "$row" "$col" >"$out" 2>/dev/null || true
        # Use %b to interpret escape sequences for color and bold; AUTHOR_TEXT is plain text
        printf "%b%s%b" "$color$BOLD" "$AUTHOR_TEXT" "$NC" >"$out" 2>/dev/null || true
        # pad to clear any leftover chars if previous text was longer
        printf "%b" "   " >"$out" 2>/dev/null || true
        printf '\033[u' >"$out" 2>/dev/null || true
        sleep 0.15
        idx=$((idx+1))
    done
}

# Start rainbow animation anchored to the already-printed AUTHOR_TEXT line.
# This function will not create a new author line; it finds the existing one and animates it in-place.
start_rainbow_author() {
    # Only start if we have a real tty to interact with
    if [[ "$USE_TTY_FD" != true ]]; then
        return 1
    fi
    open_io
    if [[ -z "$INPUT_FD" || -z "$OUTPUT_PATH" ]]; then
        return 1
    fi

    # The AUTHOR_TEXT was printed above with a newline. To get the cursor position
    # of that printed line we move the terminal cursor up one line, query position,
    # then move the cursor back down — this avoids creating or printing another author line.
    printf '\033[1A' >"$OUTPUT_PATH" 2>/dev/null || true   # move up to author line
    local pos
    pos="$(get_cursor_pos)" || {
        # If we can't get cursor pos, restore position and bail out gracefully
        printf '\033[1B' >"$OUTPUT_PATH" 2>/dev/null || true
        return 1
    }
    printf '\033[1B' >"$OUTPUT_PATH" 2>/dev/null || true   # move back to original spot

    AUTHOR_ROW="${pos%;*}"
    AUTHOR_COL="${pos#*;}"
    # Start animator in background, detached from job control
    animate_author "$AUTHOR_ROW" "$AUTHOR_COL" >/dev/null 2>&1 &
    ANIM_PID=$!
    # Ensure we try to kill background children and restore cursor on exit
    trap 'kill_animator' EXIT
    return 0
}

kill_animator() {
    # Make sure OUTPUT_PATH is available so we can restore cursor visibility
    try_open_tty || true
    open_io || true
    if [[ -n "${ANIM_PID:-}" ]]; then
        kill "${ANIM_PID}" 2>/dev/null || true
        wait "${ANIM_PID}" 2>/dev/null || true
        ANIM_PID=""
    fi
    # show cursor again
    local out="${OUTPUT_PATH:-/dev/stdout}"
    printf '\033[?25h' >"$out" 2>/dev/null || true
}

# --------------- End rainbow helpers ----------------

# Pre-autostart numeric menu (3 options: launch, dry, none)
choose_prelaunch_mode() {
    open_io

    if [[ -z "$INPUT_FD" ]]; then
        # no interactive input — default to launch
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

# Apply selected mode immediately (no countdown)
# modes:
#  - dry  -> run installed binary with --dry-run (attached to /dev/tty if possible)
#  - none -> do nothing, return to caller immediately
#  - launch-> start installed binary (attached if possible) and then exit installer
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
                # run attached to tty and wait (subshell so installer is not replaced)
                ( "$install_path" --dry-run </dev/tty >/dev/tty 2>/dev/tty )
            else
                # no tty; run detached so installer can continue/exit cleanly
                nohup "$install_path" --dry-run >/dev/null 2>&1 &
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
            else
                nohup "$install_path" >/dev/null 2>&1 &
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
    # ensure both temp cleanup and animator kill happen on exit from this function
    trap 'rm -f "${TMP_DL}"; kill_animator' EXIT
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

    # pre-autostart numeric menu
    try_open_tty || true
    open_io
    chosen_mode="$(choose_prelaunch_mode)"

    # Apply selected mode immediately (no countdown)
    countdown_and_apply_mode "$install_path" "$chosen_mode"

    if [[ "$chosen_mode" == "none" ]]; then
        # return to main menu (caller is the menu loop)
        return 0
    fi

    # For other modes (launch/dry) preserve previous behavior and exit installer after completing.
    kill_animator
    exec 3<&- 2>/dev/null || true
    exit 0
}

uninstall_action() {
    local install_path="$INSTALL_DIR/$SCRIPT_NAME"
    if [[ ! -f "$install_path" ]]; then
        warn "Not installed: $install_path"
        return 0
    fi

    # Uninstall: no confirmation, just remove
    rm -f "$install_path" && log "Removed $install_path"
    return 0
}

# If explicit action requested, do it and exit
if [[ -n "$ACTION" ]]; then
    try_open_tty || true
    debug_dump
    case "$ACTION" in
        install) install_action; kill_animator; exec 3<&- 2>/dev/null || true; exit 0 ;;
        uninstall) uninstall_action; kill_animator; exec 3<&- 2>/dev/null || true; exit 0 ;;
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
    kill_animator
    exec 3<&- 2>/dev/null || true
    exit 0
fi

# Start rainbow animation for the already-printed author line (only if we have a tty)
try_open_tty || true
start_rainbow_author || true

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
            # If install_action returns (chosen_mode == none), loop will continue; otherwise install_action exits.
            continue
            ;;
        2)
            uninstall_action
            # After uninstall, show status then loop back so user can choose again
            continue
            ;;
        3|q|Q)
            echo "Exit." >"$OUTPUT_PATH"
            kill_animator
            exec 3<&- 2>/dev/null || true
            exit 0
            ;;
        *)
            warn "Invalid selection; try again."
            continue
            ;;
    esac
done

# close fd 3 (should be unreachable)
kill_animator
exec 3<&- 2>/dev/null || true
exit 0
