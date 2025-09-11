#!/usr/bin/env bash
#
# disable_smtp_plain.sh
# Harden Postfix/Exim by disabling plaintext auth methods and provide a strict
# --dry-run mode that produces no side effects on the running system.
#
# This revision displays a simple two-option chooser (Yes / No). Yes is green,
# No is red, and the currently highlighted option is shown in bold. Left/right
# arrows (or h/l) cycle between the options and Enter confirms. In --dry-run
# the script never performs changes even when Yes is chosen; accepted actions
# in dry-run are recorded as "dry-accepted".
#
set -euo pipefail

LOG_FILE="/var/log/linkzero-smtp-security.log"
DRY_RUN="${DRY_RUN:-false}"

# Use colors only when stdout is a terminal
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  MAGENTA=''
  CYAN=''
  BOLD=''
  RESET=''
fi

# Arrays for summary
declare -a ACTION_DESCS
declare -a ACTION_CMDS
declare -a ACTION_RESULTS   # values: executed / skipped / dry-accepted / failed

# Logging helpers (do not write files on dry-run)
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '%s [%s] %s\n' "$ts" "$level" "$msg"
  else
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
  fi
}
log_info(){ log "INFO" "$@"; }
log_error(){ log "ERROR" "$@"; }
log_success(){ log "SUCCESS" "$@"; }

# Terminal arrow-based chooser:
# - prompt: displayed text to ask
# Returns:
#   0 -> user selected YES
#   1 -> user selected NO
choose_yes_no() {
  local prompt="$1"

  # Non-interactive: safe default to NO
  if ! [[ -t 0 ]]; then
    echo "$prompt"
    echo "Non-interactive terminal: defaulting to 'No'"
    return 1
  fi

  # selection: 0 = YES, 1 = NO
  local sel=0
  local key

  # hide cursor if possible
  tput civis 2>/dev/null || true

  while true; do
    # clear line and render prompt with colored options
    printf '\r\033[K'  # CR + clear to end of line

    if [[ $sel -eq 0 ]]; then
      option_yes="${BOLD}${GREEN}YES${RESET}"
      option_no="${RED}NO${RESET}"
    else
      option_yes="${GREEN}YES${RESET}"
      option_no="${BOLD}${RED}NO${RESET}"
    fi

    # Print: cyan bold prompt text then options
    printf "%b %s   [ %b ]  [ %b ]" "${CYAN}${BOLD}" "$prompt" "$option_yes" "$option_no"

    # read one key (raw, silent)
    IFS= read -rsn1 key 2>/dev/null || key=''

    # If it's an escape, read remaining bytes of the sequence (arrow keys)
    if [[ $key == $'\x1b' ]]; then
      # read up to two more bytes (common CSI sequences are 3 bytes total)
      IFS= read -rsn2 -t 0.0005 rest 2>/dev/null || rest=''
      key+="$rest"
    fi

    case "$key" in
      $'\n'|$'\r'|'')   # Enter pressed
        printf "\n"
        tput cnorm 2>/dev/null || true
        if [[ $sel -eq 0 ]]; then
          return 0
        else
          return 1
        fi
        ;;
      $'\x1b[C'|$'\x1b[D')  # Right or Left arrow
        sel=$((1 - sel))
        ;;
      h|H|l|L)
        sel=$((1 - sel))
        ;;
      q|Q)
        printf "\n"
        echo -e "${RED}Aborted by user.${RESET}"
        tput cnorm 2>/dev/null || true
        exit 1
        ;;
      *)
        # ignore other keys
        ;;
    esac
  done
}

# perform_action "Description" "command string"
# - prompts Yes/No with choose_yes_no
# - in dry-run will never execute the command even if the user picks Yes
# - when not dry-run and user picks Yes, eval the command
perform_action(){
  local desc="$1"; shift
  local cmd="$*"

  echo -e "${CYAN}${BOLD}Action:${RESET} ${desc}"
  echo -e "${YELLOW}Command:${RESET} ${cmd}"

  if choose_yes_no "Apply?"; then
    ACTION_DESCS+=("$desc")
    ACTION_CMDS+=("$cmd")

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo -e "${GREEN}Accepted (dry-run): would run:${RESET} ${cmd}"
      ACTION_RESULTS+=("dry-accepted")
      return 0
    fi

    echo -e "${GREEN}Executing:${RESET} ${cmd}"
    if eval "$cmd"; then
      log_success "$desc"
      ACTION_RESULTS+=("executed")
      return 0
    else
      log_error "$desc failed"
      ACTION_RESULTS+=("failed")
      return 1
    fi
  else
    echo -e "${MAGENTA}Skipped:${RESET} ${cmd}"
    ACTION_DESCS+=("$desc")
    ACTION_CMDS+=("$cmd")
    ACTION_RESULTS+=("skipped")
    return 0
  fi
}

# Compatibility shim
run_or_echo(){
  perform_action "Run command" "$*"
}

backup_iptables_snapshot(){
  local BACKUP_DIR="/var/backups/linkzero"
  local TIMESTAMP
  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

  if ! command -v iptables-save >/dev/null 2>&1; then
    log_info "iptables-save not found; skipping snapshot"
    return 0
  fi

  perform_action "Create backup directory for iptables snapshot" "mkdir -p '$BACKUP_DIR'"
  perform_action "Save current iptables rules to snapshot" "iptables-save > '$BACKUP_DIR/iptables.$TIMESTAMP'"
}

configure_firewall(){
  log_info "Preparing firewall changes: allow submission on port 587 and enforce TLS-only AUTH"
  backup_iptables_snapshot

  local cmd1="iptables -I INPUT -p tcp --dport 587 -j ACCEPT"
  local cmd2="iptables -I INPUT -p tcp --dport 25 -j ACCEPT"
  local cmd3="iptables -I INPUT -p tcp --dport 465 -j ACCEPT"

  perform_action "Allow Submission (port 587)" "$cmd1"
  perform_action "Allow SMTP (port 25)" "$cmd2"
  perform_action "Allow SMTPS (port 465)" "$cmd3"

  if command -v csf >/dev/null 2>&1; then
    perform_action "Reload CSF (ConfigServer) firewall" "csf -r"
  fi
}

configure_postfix(){
  log_info "Configuring Postfix to require TLS for AUTH"

  if ! command -v postconf >/dev/null 2>&1; then
    log_info "postconf not present; skipping Postfix configuration"
    return 0
  fi

  perform_action "Set Postfix: smtpd_tls_auth_only = yes" "postconf -e 'smtpd_tls_auth_only = yes'"
  perform_action "Set Postfix: smtpd_tls_security_level = may" "postconf -e 'smtpd_tls_security_level = may'"
  perform_action "Set Postfix: smtpd_sasl_auth_enable = yes" "postconf -e 'smtpd_sasl_auth_enable = yes'"

  if command -v systemctl >/dev/null 2>&1; then
    perform_action "Restart Postfix via systemctl" "systemctl restart postfix"
  else
    perform_action "Restart Postfix via service" "service postfix restart"
  fi
}

configure_exim(){
  log_info "Configuring Exim to require TLS for AUTH (if Exim is present)"

  if ! command -v exim >/dev/null 2>&1 && ! command -v exim4 >/dev/null 2>&1; then
    log_info "Exim not present; skipping Exim configuration"
    return 0
  fi

  local exim_conf=""
  if [[ -f /etc/exim4/exim4.conf.template ]]; then
    exim_conf="/etc/exim4/exim4.conf.template"
  elif [[ -f /etc/exim/exim.conf ]]; then
    exim_conf="/etc/exim/exim.conf"
  fi

  if [[ -n "$exim_conf" ]]; then
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local backup_cmd="cp -a '$exim_conf' '${exim_conf}.bak.$timestamp' || true"
    local sed_cmd="sed -i.bak -E 's/^\\s*AUTH_CLIENT_ALLOW_NOTLS\\b.*//I' '$exim_conf' || true"

    perform_action "Backup Exim config file" "$backup_cmd"
    perform_action "Remove AUTH_CLIENT_ALLOW_NOTLS from Exim config" "$sed_cmd"
  else
    log_info "Exim configuration file not found at standard locations"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    perform_action "Restart Exim via systemctl" "systemctl restart exim4 || systemctl restart exim || true"
  else
    perform_action "Restart Exim via service" "service exim4 restart || service exim restart || true"
  fi
}

test_configuration(){
  log_info "Testing mail server configuration (these actions will be prompted separately)"
  perform_action "Postfix: basic configuration check" "postfix check"
  perform_action "Exim: basic configuration info" "exim -bV"
}

_print_summary(){
  echo -e "${BLUE}${BOLD}Summary:${RESET}"
  local i
  for i in "${!ACTION_DESCS[@]}"; do
    local d="${ACTION_DESCS[$i]}"
    local c="${ACTION_CMDS[$i]}"
    local r="${ACTION_RESULTS[$i]}"
    case "$r" in
      executed)     printf "%s %b[EXECUTED]%b — %s\n" "$((i+1))." "$GREEN" "$RESET" "$d" ;;
      failed)       printf "%s %b[FAILED]%b   — %s\n" "$((i+1))." "$RED" "$RESET" "$d" ;;
      skipped)      printf "%s %b[SKIPPED]%b  — %s\n" "$((i+1))." "$MAGENTA" "$RESET" "$d" ;;
      dry-accepted) printf "%s %b[DRY-ACCEPT]%b — %s\n" "$((i+1))." "$YELLOW" "$RESET" "$d" ;;
      *)             printf "%s [UNKNOWN] — %s\n" "$((i+1))." "$d" ;;
    esac
    printf "    Command: %s\n" "$c"
  done
}

usage(){
  cat <<EOF
Usage: $0 [--dry-run]

  --dry-run   Show what would be done without making any changes to the system.
EOF
}

main(){
  # parse args
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg"; usage; exit 2 ;;
    esac
  done

  log_info "Starting smtp-hardening (dry-run=${DRY_RUN:-false})"
  configure_firewall
  configure_postfix
  configure_exim
  test_configuration
  log_info "Completed smtp-hardening run"

  _print_summary
}

main "$@"
