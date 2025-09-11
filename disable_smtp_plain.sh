#!/usr/bin/env bash
#
# disable_smtp_plain.sh
# Harden Postfix/Exim by disabling plaintext auth methods and provide a strict
# --dry-run mode that produces no side effects on the running system.
#
# Changes in this revision:
# - Fix visibility of the interactive chooser: unselected answers are rendered
#   in the terminal default color (no explicit "white" color sequence) so they
#   aren't invisible on white/bright backgrounds. The currently-selected
#   option is rendered in color (green for YES, red for NO) while you move
#   the arrows. Options remain non-bold per your earlier request.
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

# Detect the active firewall manager. Priority:
# - nftables (preferred)
# - csf (ConfigServer)
# - firewalld
# - iptables (fallback)
# - none (if nothing detected)
detect_active_firewall() {
  if command -v nft >/dev/null 2>&1; then
    if systemctl is-active --quiet nftables 2>/dev/null || nft list ruleset >/dev/null 2>&1; then
      echo "nftables"
      return 0
    fi
  fi

  if command -v csf >/dev/null 2>&1 || [[ -d /etc/csf ]]; then
    if command -v csf >/dev/null 2>&1; then
      echo "csf"
      return 0
    fi
    if [[ -d /etc/csf ]]; then
      echo "csf"
      return 0
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      if firewall-cmd --state 2>/dev/null | grep -qi running; then
        echo "firewalld"
        return 0
      fi
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
      echo "firewalld"
      return 0
    fi
  fi

  if command -v iptables-save >/dev/null 2>&1; then
    echo "iptables"
    return 0
  fi

  echo "none"
  return 0
}

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
    # clear line and render prompt with colored selected option
    printf '\r\033[K'

    # IMPORTANT: unselected option uses the terminal default color (no explicit white),
    # selected option uses green (YES) or red (NO) so it's visible on any background.
    if [[ $sel -eq 0 ]]; then
      option_yes="${GREEN}YES${RESET}"
      option_no="NO"
    else
      option_yes="YES"
      option_no="${RED}NO${RESET}"
    fi

    # Prompt remains highlighted so it's obvious what you're answering; options are not bold.
    printf "%b%s%b   [ %b ]  [ %b ]" "${CYAN}${BOLD}" "$prompt" "${RESET}" "$option_yes" "$option_no"

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

# Configure firewall: only act on the detected active firewall manager.
configure_firewall() {
  local fw
  fw="$(detect_active_firewall)"
  log_info "Detected firewall manager: ${fw}"

  case "$fw" in
    nftables)
      log_info "Managing nftables only; csf/firewalld/iptables will be muted."
      local nft_base="nft add table inet linkzero >/dev/null 2>&1 || true; \
nft add chain inet linkzero input '{ type filter hook input priority 0 ; }' >/dev/null 2>&1 || true;"
      perform_action "Ensure nftables table/chain exists (linkzero inet filter)" \
        "$nft_base"

      perform_action "Allow Submission (port 587) in nftables" \
        "$nft_base nft add rule inet linkzero input tcp dport 587 accept >/dev/null 2>&1 || true"
      perform_action "Allow SMTP (port 25) in nftables" \
        "$nft_base nft add rule inet linkzero input tcp dport 25 accept >/dev/null 2>&1 || true"
      perform_action "Allow SMTPS (port 465) in nftables" \
        "$nft_base nft add rule inet linkzero input tcp dport 465 accept >/dev/null 2>&1 || true"
      ;;
    csf)
      log_info "Managing CSF only; firewalld/iptables will be muted."
      perform_action "Reload CSF (ConfigServer) firewall" "csf -r || true"
      perform_action "Notify to ensure /etc/csf/csf.conf includes TCP_IN ports 25,587,465" \
        "printf '%s\n' 'Please edit /etc/csf/csf.conf and ensure TCP_IN includes 25,587,465' >&2"
      ;;
    firewalld)
      log_info "Managing firewalld only; csf/iptables will be muted."
      perform_action "Open port 587/tcp permanently in firewalld" "firewall-cmd --permanent --add-port=587/tcp"
      perform_action "Open port 25/tcp permanently in firewalld" "firewall-cmd --permanent --add-port=25/tcp"
      perform_action "Open port 465/tcp permanently in firewalld" "firewall-cmd --permanent --add-port=465/tcp"
      perform_action "Reload firewalld to apply permanent changes" "firewall-cmd --reload"
      ;;
    iptables)
      log_info "Managing iptables only (no higher-level manager detected)."
      perform_action "Allow Submission (port 587)" "iptables -I INPUT -p tcp --dport 587 -j ACCEPT"
      perform_action "Allow SMTP (port 25)" "iptables -I INPUT -p tcp --dport 25 -j ACCEPT"
      perform_action "Allow SMTPS (port 465)" "iptables -I INPUT -p tcp --dport 465 -j ACCEPT"
      ;;
    none|*)
      log_info "No recognized firewall manager detected; skipping firewall changes."
      echo -e "${YELLOW}No active firewall manager detected (nftables, csf, firewalld, iptables).${RESET}"
      ;;
  esac
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
