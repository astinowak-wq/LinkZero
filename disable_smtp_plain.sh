#!/usr/bin/env bash
#
# disable_smtp_plain.sh
# Harden Postfix/Exim by disabling plaintext auth methods and provide a strict
# --dry-run mode that produces no side effects on the running system.
#
# Changes in this revision:
# - Do not print lines that begin with an ISO timestamp (e.g. 2025-09-11T04:37:56Z)
#   to the terminal. Those lines will still be written to the logfile when not
#   running in dry-run. Interactive terminal output will not include those
#   timestamp-prefix lines.
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
declare -a ACTION_RESULTS   # values: executed / skipped / dry-accepted / failed / already

# Filter function: read stdin and drop any line that starts with an ISO timestamp
# Pattern: YYYY-MM-DDTHH:MM:SSZ (e.g. 2025-09-11T04:37:56Z)
filter_out_timestamp_lines() {
  local re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  while IFS= read -r line; do
    if [[ ! $line =~ $re ]]; then
      printf '%s\n' "$line"
    fi
  done
}

# Improved log(): keep timestamps in logfile (and non-interactive output),
# but when printing to an interactive terminal, do not print any lines that
# start with the ISO timestamp pattern.
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  if [[ "${DRY_RUN}" == "true" ]]; then
    # In dry-run mode: interactive -> show concise "[LEVEL] message" (no timestamp)
    # non-interactive -> include timestamp
    if [[ -t 1 ]]; then
      printf '[%s] %s\n' "$level" "$msg" | filter_out_timestamp_lines
    else
      printf '%s [%s] %s\n' "$ts" "$level" "$msg"
    fi
  else
    # Persist the full timestamped log entry to logfile (best-effort)
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true

    # Print to stdout:
    if [[ -t 1 ]]; then
      # Interactive: print the concise "[LEVEL] message" but pipe through filter to
      # drop any accidental lines that start with timestamp.
      printf '[%s] %s\n' "$level" "$msg" | filter_out_timestamp_lines
    else
      # Non-interactive: print full timestamped line
      printf '%s [%s] %s\n' "$ts" "$level" "$msg"
    fi
  fi
}
log_info(){ log "INFO" "$@"; }
log_error(){ log "ERROR" "$@"; }
log_success(){ log "SUCCESS" "$@"; }

# Robust CSF presence check.
csf_present() {
  # 1) systemctl services
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet csf 2>/dev/null || systemctl is-active --quiet lfd 2>/dev/null; then
      return 0
    fi
  fi

  # 2) running processes (csf or lfd)
  if pgrep -x csf >/dev/null 2>&1 || pgrep -x lfd >/dev/null 2>&1 || pgrep -f '/usr/local/csf' >/dev/null 2>&1; then
    return 0
  fi

  # 3) common install paths
  if [[ -d /etc/csf ]] || [[ -d /usr/local/csf ]] || [[ -x /usr/sbin/csf ]] || [[ -x /usr/local/sbin/csf ]]; then
    return 0
  fi

  # 4) cPanel indicator + csf dir (often cPanel systems have /usr/local/cpanel)
  if [[ -d /usr/local/cpanel ]] && ([[ -d /etc/csf ]] || [[ -d /usr/local/csf ]]); then
    return 0
  fi

  return 1
}

# Detect the active firewall manager.
# Priority: csf > nftables > firewalld > iptables > none
detect_active_firewall() {
  if csf_present; then
    echo "csf"
    return 0
  fi

  # nftables next
  if command -v nft >/dev/null 2>&1; then
    if systemctl is-active --quiet nftables 2>/dev/null || nft list ruleset >/dev/null 2>&1; then
      echo "nftables"
      return 0
    fi
  fi

  # firewalld
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

  # iptables fallback
  if command -v iptables-save >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then
    echo "iptables"
    return 0
  fi

  echo "none"
  return 0
}

# Firewall existence checks
# Returns 0 when the given command/change already exists on the system for the given manager.
firewall_change_exists() {
  local manager="$1"; shift
  local cmd="$*"

  # helper: check presence of a single port in various managers
  port_present_in_nft() {
    local port="$1"
    nft list ruleset 2>/dev/null | grep -E -q "dport[[:space:]]+$port|dport[[:space:]]+${port}[[:space:]]" && nft list ruleset 2>/dev/null | grep -q "accept"
  }

  port_present_in_firewalld() {
    local port="$1"
    firewall-cmd --permanent --list-ports 2>/dev/null | tr ' ' '\n' | grep -xq "${port}/tcp"
  }

  port_present_in_iptables() {
    local port="$1"
    if command -v iptables >/dev/null 2>&1; then
      iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 && return 0 || return 1
    fi
    return 1
  }

  csf_tcp_in_contains_ports() {
    local want_ports=("$@")
    local line
    if [[ -r /etc/csf/csf.conf ]]; then
      line="$(sed -nE 's/^[[:space:]]*TCP_IN[[:space:]]*=[[:space:]]*//Ip' /etc/csf/csf.conf | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
      if [[ -z "$line" ]]; then
        line="$(grep -i '^TCP_IN' /etc/csf/csf.conf 2>/dev/null | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//')"
        line="$(echo "$line" | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
      fi
      if [[ -z "$line" ]]; then
        return 1
      fi
      IFS=',' read -ra existing <<< "$line"
      for want in "${want_ports[@]}"; do
        local found=1
        for ex in "${existing[@]}"; do
          if [[ "$ex" == "$want" ]]; then
            found=0
            break
          fi
        done
        if [[ $found -ne 0 ]]; then
          return 1
        fi
      done
      return 0
    fi
    return 1
  }

  # Look for obvious port numbers referenced in the command
  local ports_found=()
  while read -r p; do
    [[ -n "$p" ]] && ports_found+=("$p")
  done < <(echo "$cmd" | grep -oE '([0-9]{2,5})' | tr '\n' ' ' | tr ' ' '\n' | sort -u)

  if [[ "$manager" == "csf" ]]; then
    if echo "$cmd" | grep -qi "TCP_IN"; then
      local want=("25" "587" "465")
      if csf_tcp_in_contains_ports "${want[@]}"; then
        return 0
      else
        return 1
      fi
    fi
  fi

  if [[ "${#ports_found[@]}" -eq 0 ]]; then
    return 1
  fi

  for port in "${ports_found[@]}"; do
    if ((port < 1 || port > 65535)); then
      continue
    fi
    case "$manager" in
      nftables)
        if port_present_in_nft "$port"; then
          return 0
        fi
        ;;
      firewalld)
        if port_present_in_firewalld "$port"; then
          return 0
        fi
        ;;
      iptables)
        if port_present_in_iptables "$port"; then
          return 0
        fi
        ;;
      csf)
        ;;
    esac
  done

  return 1
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

  local sel=0
  local key

  tput civis 2>/dev/null || true

  while true; do
    printf '\r\033[K'

    if [[ $sel -eq 0 ]]; then
      option_yes="${GREEN}YES${RESET}"
      option_no="NO"
    else
      option_yes="YES"
      option_no="${RED}NO${RESET}"
    fi

    printf "%b%s%b   [ %b ]  [ %b ]" "${CYAN}${BOLD}" "$prompt" "${RESET}" "$option_yes" "$option_no"

    IFS= read -rsn1 key 2>/dev/null || key=''

    if [[ $key == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.0005 rest 2>/dev/null || rest=''
      key+="$rest"
    fi

    case "$key" in
      $'\n'|$'\r'|'')
        printf "\n"
        tput cnorm 2>/dev/null || true
        if [[ $sel -eq 0 ]]; then
          return 0
        else
          return 1
        fi
        ;;
      $'\x1b[C'|$'\x1b[D')
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

  # Show only the action (no "Command:" printed to terminal)
  echo -e "${CYAN}${BOLD}Action:${RESET} ${desc}"

  ACTION_DESCS+=("$desc")
  ACTION_CMDS+=("$cmd")
  log_info "Planned command for action: $cmd"

  if choose_yes_no "Apply?"; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      printf "%b%s%b\n" "${GREEN}" "Changes has been successfully applied (dry-run)" "${RESET}"
      ACTION_RESULTS+=("dry-accepted")
      log_info "DRY-RUN: would run: $cmd"
      return 0
    fi

    if eval "$cmd"; then
      printf "%b%s%b\n" "${GREEN}" "Changes has been successfully applied" "${RESET}"
      log_success "$desc"
      ACTION_RESULTS+=("executed")
      return 0
    else
      printf "%b%s%b\n" "${RED}" "Changes failed during execution" "${RESET}"
      log_error "$desc failed"
      ACTION_RESULTS+=("failed")
      return 1
    fi
  else
    printf "%b%s%b\n" "${RED}" "Changes has been rejected by user" "${RESET}"
    ACTION_RESULTS+=("skipped")
    log_info "User rejected action: $desc (command: $cmd)"
    return 0
  fi
}

# Wrapper that checks whether the firewall change is already present and only prompts
# if it is not present.
precheck_and_perform_firewall_action() {
  local manager="$1"; shift
  local desc="$1"; shift
  local cmd="$*"

  if firewall_change_exists "$manager" "$cmd"; then
    printf "%b%s%b\n" "${BLUE}" "Firewall changes aren't necessary as looks like already matching" "${RESET}"
    ACTION_DESCS+=("$desc")
    ACTION_CMDS+=("$cmd")
    ACTION_RESULTS+=("already")
    log_info "Skipped firewall action (already present): $desc"
    return 0
  fi

  perform_action "$desc" "$cmd"
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
      precheck_and_perform_firewall_action "nftables" "Ensure nftables table/chain exists (linkzero inet filter)" \
        "$nft_base"

      precheck_and_perform_firewall_action "nftables" "Allow Submission (port 587) in nftables" \
        "$nft_base nft add rule inet linkzero input tcp dport 587 accept >/dev/null 2>&1 || true"
      precheck_and_perform_firewall_action "nftables" "Allow SMTP (port 25) in nftables" \
        "$nft_base nft add rule inet linkzero input tcp dport 25 accept >/dev/null 2>&1 || true"
      precheck_and_perform_firewall_action "nftables" "Allow SMTPS (port 465) in nftables" \
        "$nft_base nft add rule inet linkzero input tcp dport 465 accept >/dev/null 2>&1 || true"
      ;;
    csf)
      log_info "Managing CSF only; firewalld/iptables/nftables will be muted."
      perform_action "Reload CSF (ConfigServer) firewall" "csf -r || true"

      precheck_and_perform_firewall_action "csf" "Notify to ensure /etc/csf/csf.conf includes TCP_IN ports 25,587,465" \
        "printf '%s\n' 'Please edit /etc/csf/csf.conf and ensure TCP_IN includes 25,587,465' >&2"
      ;;
    firewalld)
      log_info "Managing firewalld only; csf/iptables will be muted."
      precheck_and_perform_firewall_action "firewalld" "Open port 587/tcp permanently in firewalld" "firewall-cmd --permanent --add-port=587/tcp"
      precheck_and_perform_firewall_action "firewalld" "Open port 25/tcp permanently in firewalld" "firewall-cmd --permanent --add-port=25/tcp"
      precheck_and_perform_firewall_action "firewalld" "Open port 465/tcp permanently in firewalld" "firewall-cmd --permanent --add-port=465/tcp"
      precheck_and_perform_firewall_action "firewalld" "Reload firewalld to apply permanent changes" "firewall-cmd --reload"
      ;;
    iptables)
      log_info "Managing iptables only (no higher-level manager detected)."
      precheck_and_perform_firewall_action "iptables" "Allow Submission (port 587)" "iptables -I INPUT -p tcp --dport 587 -j ACCEPT"
      precheck_and_perform_firewall_action "iptables" "Allow SMTP (port 25)" "iptables -I INPUT -p tcp --dport 25 -j ACCEPT"
      precheck_and_perform_firewall_action "iptables" "Allow SMTPS (port 465)" "iptables -I INPUT -p tcp --dport 465 -j ACCEPT"
      ;;
    none|*)
      log_info "No recognized firewall manager detected; skipping firewall changes."
      echo -e "${YELLOW}No active firewall manager detected (csf, nftables, firewalld, iptables).${RESET}"
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
    local r="${ACTION_RESULTS[$i]}"
    case "$r" in
      executed)     printf "%s %b[EXECUTED]%b — %s\n" "$((i+1))." "$GREEN" "$RESET" "$d" ;;
      failed)       printf "%s %b[FAILED]%b   — %s\n" "$((i+1))." "$RED" "$RESET" "$d" ;;
      skipped)      printf "%s %b[REJECTED]%b — %s\n" "$((i+1))." "$MAGENTA" "$RESET" "$d" ;;
      dry-accepted) printf "%s %b[DRY-RUN]%b  — %s\n" "$((i+1))." "$YELLOW" "$RESET" "$d" ;;
      already)      printf "%s %b[MATCH]%b    — %s\n" "$((i+1))." "$BLUE" "$RESET" "$d" ;;
      *)             printf "%s [UNKNOWN] — %s\n" "$((i+1))." "$d" ;;
    esac
  done
}

usage(){
  cat <<EOF
Usage: $0 [--dry-run]

  --dry-run   Show what would be done without making any changes to the system.
EOF
}

main(){
  # Clear the screen at the beginning of every run so the interactive menu is visible.
  if [[ -t 1 ]]; then
    tput clear 2>/dev/null || printf '\033[H\033[2J'
  fi

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
