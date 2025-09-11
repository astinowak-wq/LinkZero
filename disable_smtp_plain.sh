#!/usr/bin/env bash
#
# disable_smtp_plain.sh
# Harden Postfix/Exim by disabling plaintext auth methods and provide a strict
# --dry-run mode that produces no side effects on the running system.
#
# Notes:
# - Backups now always use the ".link0" suffix instead of ".bak".
# - Backup actions are non-interactive (no accept/reject prompt); they run
#   automatically (or are recorded in dry-run).
# - Other actions (edits, restarts, firewall changes) remain interactive.
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
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; RESET=''
fi

# Arrays for summary
declare -a ACTION_DESCS
declare -a ACTION_CMDS
declare -a ACTION_RESULTS   # values: executed / skipped / dry-accepted / failed / already

# Mail server variant (populated by detect_active_mailserver)
MAIL_SERVER_VARIANT=""

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

# Write a timestamped entry to logfile (always). Best-effort: do not fail if write fails.
log_to_file() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# Standard logger for simple messages (no commands). Keeps timestamps in logfile,
# and prints clean level-prefixed lines to interactive terminal.
log() {
  local level="$1"; shift
  local msg="$*"
  log_to_file "$level" "$msg"

  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ -t 1 ]]; then
      printf '[%s] %s\n' "$level" "$msg"
    else
      local ts
      ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      printf '%s [%s] %s\n' "$ts" "$level" "$msg"
    fi
  else
    if [[ -t 1 ]]; then
      printf '[%s] %s\n' "$level" "$msg" | filter_out_timestamp_lines
    else
      local ts
      ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      printf '%s [%s] %s\n' "$ts" "$level" "$msg"
    fi
  fi
}
log_info(){ log "INFO" "$@"; }
log_error(){ log "ERROR" "$@"; }
log_success(){ log "SUCCESS" "$@"; }

# Helper that records a message including a command to the logfile only, but
# does NOT print that line to the terminal. Use this for any "Planned command",
# "DRY-RUN: would run", "Executing command for action", and "User rejected action".
log_command_to_file_only() {
  local level="$1"; shift
  local msg="$1"; shift
  local cmd="$*"
  log_to_file "$level" "$msg: $cmd"
  # intentionally silent on stdout/stderr
}

# Non-interactive backup action: does not prompt. Respects DRY_RUN.
# Records planned backup to logfile and executes the backup (or marks dry-run).
perform_backup() {
  local desc="$1"; shift
  local cmd="$*"

  echo -e "${CYAN}${BOLD}Action:${RESET} ${desc}"

  ACTION_DESCS+=("$desc")
  ACTION_CMDS+=("$cmd")

  # Record the planned backup to logfile only
  log_command_to_file_only "INFO" "Planned backup for action" "$cmd"

  if [[ "${DRY_RUN}" == "true" ]]; then
    printf "%b%s%b\n" "${GREEN}" "Backup recorded (dry-run)" "${RESET}"
    ACTION_RESULTS+=("dry-accepted")
    log_command_to_file_only "INFO" "DRY-RUN: would run backup" "$cmd"
    return 0
  fi

  # Execute backup (no prompt)
  log_command_to_file_only "INFO" "Executing backup for action" "$cmd"
  if eval "$cmd"; then
    printf "%b%s%b\n" "${GREEN}" "Backup completed" "${RESET}"
    ACTION_RESULTS+=("executed")
    log_success "$desc"
    return 0
  else
    printf "%b%s%b\n" "${RED}" "Backup failed" "${RESET}"
    ACTION_RESULTS+=("failed")
    log_error "$desc failed"
    return 1
  fi
}

# Robust CSF presence check.
csf_present() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet csf 2>/dev/null || systemctl is-active --quiet lfd 2>/dev/null; then
      return 0
    fi
  fi
  if pgrep -x csf >/dev/null 2>&1 || pgrep -x lfd >/dev/null 2>&1 || pgrep -f '/usr/local/csf' >/dev/null 2>&1; then
    return 0
  fi
  if [[ -d /etc/csf ]] || [[ -d /usr/local/csf ]] || [[ -x /usr/sbin/csf ]] || [[ -x /usr/local/sbin/csf ]]; then
    return 0
  fi
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

  if command -v nft >/dev/null 2>&1; then
    if systemctl is-active --quiet nftables 2>/dev/null || nft list ruleset >/dev/null 2>&1; then
      echo "nftables"
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

  if command -v iptables-save >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then
    echo "iptables"
    return 0
  fi

  echo "none"
  return 0
}

# Firewall existence checks (unchanged)
firewall_change_exists() {
  local manager="$1"; shift
  local cmd="$*"

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

# perform_action: user sees only the Action and the result; full commands are logged only
perform_action(){
  local desc="$1"; shift
  local cmd="$*"

  echo -e "${CYAN}${BOLD}Action:${RESET} ${desc}"

  ACTION_DESCS+=("$desc")
  ACTION_CMDS+=("$cmd")

  # record planned command in logfile only
  log_command_to_file_only "INFO" "Planned command for action" "$cmd"

  if choose_yes_no "Apply?"; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      printf "%b%s%b\n" "${GREEN}" "Changes has been successfully applied (dry-run)" "${RESET}"
      ACTION_RESULTS+=("dry-accepted")
      log_command_to_file_only "INFO" "DRY-RUN: would run" "$cmd"
      return 0
    fi

    # Record execution attempt to logfile only (no command printed to terminal)
    log_command_to_file_only "INFO" "Executing command for action" "$cmd"
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
    log_command_to_file_only "INFO" "User rejected action" "$desc -- command: $cmd"
    return 0
  fi
}

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

# MAIL SERVER DETECTION
# Priority: exim > postfix > none
# Also sets MAIL_SERVER_VARIANT to "cPanel" if cPanel-related layout is detected.
detect_active_mailserver() {
  MAIL_SERVER_VARIANT=""

  # Exim: check for binary first
  if command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then
    # detect cPanel presence by typical markers
    if [[ -d /usr/local/cpanel ]] || [[ -d /var/cpanel ]] || [[ -f /var/cpanel/exim.conf ]] || [[ -f /var/cpanel/main_exim.conf ]]; then
      MAIL_SERVER_VARIANT="cPanel"
    fi
    echo "exim"
    return 0
  fi

  # Postfix
  if command -v postconf >/dev/null 2>&1 || command -v postfix >/dev/null 2>&1; then
    # No specific postfix variant detection at present
    echo "postfix"
    return 0
  fi

  echo "none"
  return 0
}

# Configure Postfix
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

# Configure Exim
# Single canonical configure_exim() - checks standard locations first, then cPanel locations,
# and finally tries parsing exim -bV / detecting split-config (/etc/exim4/conf.d).
configure_exim(){
  log_info "Configuring Exim to require TLS for AUTH (if Exim is present)"

  if ! command -v exim >/dev/null 2>&1 && ! command -v exim4 >/dev/null 2>&1; then
    log_info "Exim not present; skipping Exim configuration"
    return 0
  fi

  local exim_conf=""
  # Common Debian/Ubuntu exim config
  if [[ -f /etc/exim4/exim4.conf.template ]]; then
    exim_conf="/etc/exim4/exim4.conf.template"
  elif [[ -f /etc/exim/exim.conf ]]; then
    exim_conf="/etc/exim/exim.conf"
  elif [[ -f /etc/exim.conf ]]; then
    exim_conf="/etc/exim.conf"
  fi

  # cPanel-aware candidates
  if [[ -z "$exim_conf" ]]; then
    if [[ -d /usr/local/cpanel ]] || [[ -d /var/cpanel ]]; then
      local candidates=(
        "/var/cpanel/exim.conf"
        "/var/cpanel/main_exim.conf"
        "/var/cpanel/exim.conf.local"
        "/etc/exim.conf"
        "/etc/exim.conf.local"
        "/var/cpanel/userdata/*/exim.conf"
      )
      for p in "${candidates[@]}"; do
        for f in $p; do
          if [[ -f "$f" ]]; then
            exim_conf="$f"
            break 2
          fi
        done
      done

      if [[ -z "$exim_conf" ]]; then
        local found
        found="$(find /var/cpanel /etc -maxdepth 2 -type f -iname '*exim*.conf' 2>/dev/null | head -n1 || true)"
        if [[ -n "$found" ]]; then
          exim_conf="$found"
        fi
      fi

      if [[ -n "$exim_conf" ]]; then
        log_info "Detected Exim (cPanel) installation; using config: ${exim_conf}"
      else
        # leave message to indicate cPanel present but config not located here
        if [[ -d /usr/local/cpanel ]] || [[ -d /var/cpanel ]]; then
          log_info "cPanel detected but Exim config file not found in common cPanel locations"
        fi
      fi
    fi
  fi

  # If still not found, try parsing `exim -bV` for the configuration file or directory
  if [[ -z "$exim_conf" ]]; then
    if command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then
      local exim_v
      exim_v="$(exim -bV 2>&1 || true)"
      # Attempt a few patterns commonly output by exim -bV
      exim_conf="$(printf '%s\n' "$exim_v" | sed -nE 's/.*Configuration file[^:]*:[[:space:]]*(.+)$/\1/p' | head -n1 || true)"
      if [[ -z "$exim_conf" ]]; then
        # look for references to /etc/exim4
        if printf '%s\n' "$exim_v" | grep -qi '/etc/exim4'; then
          if [[ -f /etc/exim4/exim4.conf.template ]]; then
            exim_conf="/etc/exim4/exim4.conf.template"
          elif [[ -d /etc/exim4 ]]; then
            exim_conf="/etc/exim4"
          fi
        fi
      fi
      exim_conf="$(echo "$exim_conf" | xargs || true)"
      if [[ -n "$exim_conf" && -f "$exim_conf" ]]; then
        log_info "Discovered Exim configuration via 'exim -bV': ${exim_conf}"
      else
        if [[ -d /etc/exim4/conf.d ]]; then
          exim_conf="/etc/exim4"
          log_info "Detected exim4 split-config directory: ${exim_conf}"
        else
          exim_conf=""
        fi
      fi
    fi
  fi

  if [[ -n "$exim_conf" ]]; then
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

    if [[ -d "$exim_conf" && "$(basename "$exim_conf")" == "exim4" ]]; then
      # backup the conf.d directory (non-interactive)
      local backup_cmd="tar -czf '${exim_conf}.link0.$timestamp.tgz' -C '$(dirname "$exim_conf")' '$(basename "$exim_conf")' || true"
      perform_backup "Backup Exim split-config directory" "$backup_cmd"
      # apply edits cautiously: sed will create .link0 backups for files it modifies
      perform_action "Remove AUTH_CLIENT_ALLOW_NOTLS from Exim split-config (conf.d) files" "grep -R --line-number 'AUTH_CLIENT_ALLOW_NOTLS' '$exim_conf' || true; sed -i.link0 -E '/AUTH_CLIENT_ALLOW_NOTLS/Id' \$(grep -R --files-with-matches 'AUTH_CLIENT_ALLOW_NOTLS' '$exim_conf' || true) || true"
    else
      local backup_cmd="cp -a '$exim_conf' '${exim_conf}.link0.$timestamp' || true"
      local sed_cmd="sed -i.link0 -E 's/^\\s*AUTH_CLIENT_ALLOW_NOTLS\\b.*//I' '$exim_conf' || true"
      perform_backup "Backup Exim config file" "$backup_cmd"
      perform_action "Remove AUTH_CLIENT_ALLOW_NOTLS from Exim config" "$sed_cmd"
    fi
  else
    log_info "Exim configuration file not found at standard, cPanel, or discovered locations; skipping Exim config edits"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    perform_action "Restart Exim via systemctl" "systemctl restart exim4 || systemctl restart exim || true"
  else
    perform_action "Restart Exim via service" "service exim4 restart || service exim restart || true"
  fi
}

test_configuration(){
  log_info "Testing mail server configuration (these actions will be prompted separately)"
  if command -v postfix >/dev/null 2>&1 || command -v postconf >/dev/null 2>&1; then
    perform_action "Postfix: basic configuration check" "postfix check"
  fi
  if command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then
    perform_action "Exim: basic configuration info" "exim -bV"
  fi
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

  # Mail server selection & execution policy:
  # Priority: exim -> postfix -> none (fallback: prompt for both)
  local mail_svc
  mail_svc="$(detect_active_mailserver)"

  # Build display label including variant if detected
  local display_label="$mail_svc"
  if [[ -n "${MAIL_SERVER_VARIANT}" ]]; then
    display_label="${mail_svc} (${MAIL_SERVER_VARIANT})"
  fi

  log_info "Detected mail server: ${display_label}"

  case "$mail_svc" in
    exim)
      if [[ -n "${MAIL_SERVER_VARIANT}" ]]; then
        log_info "Exim detected (variant: ${MAIL_SERVER_VARIANT}): only running Exim-related configuration and checks."
      else
        log_info "Exim detected: only running Exim-related configuration and checks."
      fi
      configure_exim
      test_configuration
      ;;
    postfix)
      log_info "Postfix detected (no Exim): only running Postfix-related configuration and checks."
      configure_postfix
      test_configuration
      ;;
    none|*)
      log_info "No specific mail server detected; prompting for both Exim and Postfix configuration (fallback)."
      configure_exim
      configure_postfix
      test_configuration
      ;;
  esac

  log_info "Completed smtp-hardening run"

  _print_summary
}

main "$@"
