#!/usr/bin/env bash
#
# disable_smtp_plain.sh
# Harden Postfix/Exim by disabling plaintext auth methods and provide a strict
# --dry-run mode that produces no side effects on the running system.
#
# Display change in this revision:
# - The "[INFO] Detected mail server" line now prints the service with:
#     CapitalizedName (version) (assumed cPanel)
#   Examples:
#     [INFO] Detected mail server: Exim (4.94) (assumed cPanel)
#     [INFO] Detected mail server: Exim (4.94) (cPanel)
#     [INFO] Detected mail server: Postfix
#
# Other behavior: backups are non-interactive and use .link0; commands logged
# to LOG_FILE only. Edits/restarts remain interactive.
#
set -euo pipefail

# Colors (fallback) - ensure defined before any logging when set -u is used
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="/var/log/linkzero-smtp-security.log"
DRY_RUN="${DRY_RUN:-false}"

# Colors only when stdout is a terminal
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'; CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; RESET=''
fi

declare -a ACTION_DESCS
declare -a ACTION_CMDS
declare -a ACTION_RESULTS

MAIL_SERVER_VARIANT=""
MAIL_SERVER_VARIANT_ASSUMED=""  # "assumed" when variant inferred from cPanel markers only
EXIM_VERSION="unknown"

# hide timestamp-prefixed lines on terminal
filter_out_timestamp_lines() {
  local re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  while IFS= read -r line; do
    if [[ ! $line =~ $re ]]; then printf '%s\n' "$line"; fi
  done
}

log_to_file() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
  local level="$1"; shift
  local msg="$*"
  log_to_file "$level" "$msg"
  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ -t 1 ]]; then printf '[%s] %s\n' "$level" "$msg"; else printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg"; fi
  else
    if [[ -t 1 ]]; then printf '[%s] %s\n' "$level" "$msg" | filter_out_timestamp_lines; else printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg"; fi
  fi
}
log_info(){ log "INFO" "$@"; }
log_error(){ log "ERROR" "$@"; }
log_success(){ log "SUCCESS" "$@"; }

# write full command to logfile only
log_command_to_file_only() {
  local level="$1"; shift
  local msg="$1"; shift
  local cmd="$*"
  log_to_file "$level" "$msg: $cmd"
}

# non-interactive backup (no "Action:" prompt). Respects DRY_RUN.
perform_backup() {
  local desc="$1"; shift
  local cmd="$*"
  ACTION_DESCS+=("$desc")
  ACTION_CMDS+=("$cmd")
  log_command_to_file_only "INFO" "Planned backup" "$cmd"
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf "%b%s%b\n" "${GREEN}" "Backup recorded (dry-run)" "${RESET}"
    ACTION_RESULTS+=("dry-accepted")
    log_command_to_file_only "INFO" "DRY-RUN: would run backup" "$cmd"
    return 0
  fi
  log_command_to_file_only "INFO" "Executing backup" "$cmd"
  if eval "$cmd"; then
    printf "%b%s%b\n" "${GREEN}" "Backup completed" "${RESET}"
    ACTION_RESULTS+=("executed"); log_success "$desc"; return 0
  else
    printf "%b%s%b\n" "${RED}" "Backup failed" "${RESET}"
    ACTION_RESULTS+=("failed"); log_error "$desc failed"; return 1
  fi
}

# interactive yes/no chooser
# Updated: read from /dev/tty (or SUDO_TTY) to ensure prompts work even when stdin is redirected.
# Returns 0 for Yes, 1 for No. If no tty available, defaults to No (returns 1) and informs user.
choose_yes_no() {
  local prompt="$1"
  local ttydev=""

  # Prefer /dev/tty, fall back to SUDO_TTY if present and readable
  if [[ -r /dev/tty ]]; then
    ttydev="/dev/tty"
  elif [[ -n "${SUDO_TTY:-}" && -r "${SUDO_TTY}" ]]; then
    ttydev="${SUDO_TTY}"
  fi

  if [[ -z "$ttydev" ]]; then
    # Non-interactive environment: do not attempt to prompt; default to No
    echo "$prompt"
    echo "Non-interactive terminal: defaulting to 'No'"
    return 1
  fi

  # Open tty for reading single-key input on fd 3
  exec 3<"$ttydev" 2>/dev/null || return 1

  local sel=0 key rest
  tput civis >/dev/null 2>&1 || true
  while true; do
    # Print prompt to tty (clearing the line first)
    printf '\r\033[K' >"$ttydev"
    if [[ $sel -eq 0 ]]; then option_yes="${GREEN}YES${RESET}"; option_no="NO"; else option_yes="YES"; option_no="${RED}NO${RESET}"; fi
    printf "%b%s%b   [ %b ]  [ %b ]" "${CYAN}${BOLD}" "$prompt" "${RESET}" "$option_yes" "$option_no" >"$ttydev"

    # Read a single key (handle escape sequences for arrows)
    IFS= read -r -n1 -u 3 key 2>/dev/null || key=''
    if [[ $key == $'\x1b' ]]; then
      # attempt to read the rest of the escape sequence
      IFS= read -r -n2 -t 0.0005 -u 3 rest 2>/dev/null || rest=''
      key+="$rest"
    fi

    case "$key" in
      $'\n'|$'\r'|'')
        printf "\n" >"$ttydev"
        tput cnorm >/dev/null 2>&1 || true
        exec 3<&- 2>/dev/null || true
        [[ $sel -eq 0 ]] && return 0 || return 1
        ;;
      $'\x1b[C'|$'\x1b[D')
        # toggle selection on left/right arrows (also works with up/down if terminal maps)
        sel=$((1 - sel))
        ;;
      $'\x1b[A'|$'\x1b[B')
        # Up/Down arrows behave the same
        sel=$((1 - sel))
        ;;
      h|H|l|L)
        sel=$((1 - sel))
        ;;
      q|Q)
        printf "\n" >"$ttydev"
        echo -e "${RED}Aborted by user.${RESET}" >"$ttydev"
        tput cnorm >/dev/null 2>&1 || true
        exec 3<&- 2>/dev/null || true
        exit 1
        ;;
      *)
        # ignore other keys
        ;;
    esac
  done
}

perform_action(){
  local desc="$1"; shift
  local cmd="$*"
  echo -e "${CYAN}${BOLD}Action:${RESET} ${desc}"
  ACTION_DESCS+=("$desc")
  ACTION_CMDS+=("$cmd")
  log_command_to_file_only "INFO" "Planned command" "$cmd"
  if choose_yes_no "Apply?"; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      printf "%b%s%b\n" "${GREEN}" "Changes has been applied (dry-run)" "${RESET}"
      ACTION_RESULTS+=("dry-accepted"); log_command_to_file_only "INFO" "DRY-RUN: would run" "$cmd"; return 0
    fi
    log_command_to_file_only "INFO" "Executing command" "$cmd"
    if eval "$cmd"; then printf "%b%s%b\n" "${GREEN}" "Changes has been successfully applied" "${RESET}"; log_success "$desc"; ACTION_RESULTS+=("executed"); return 0
    else printf "%b%s%b\n" "${RED}" "Changes failed during execution" "${RESET}"; log_error "$desc failed"; ACTION_RESULTS+=("failed"); return 1; fi
  else
    printf "%b%s%b\n" "${RED}" "Changes has been rejected by user" "${RESET}"
    ACTION_RESULTS+=("skipped"); log_command_to_file_only "INFO" "User rejected action" "$desc -- command: $cmd"; return 0
  fi
}

# firewall detection helpers (kept minimal)
csf_present() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet csf 2>/dev/null || systemctl is-active --quiet lfd 2>/dev/null; then return 0; fi
  fi
  if pgrep -x csf >/dev/null 2>&1 || pgrep -x lfd >/dev/null 2>&1 || pgrep -f '/usr/local/csf' >/dev/null 2>&1; then return 0; fi
  [[ -d /etc/csf || -d /usr/local/csf || -x /usr/sbin/csf ]] && return 0
  return 1
}
detect_active_firewall() {
  if csf_present; then echo "csf"; return 0; fi
  if command -v nft >/dev/null 2>&1; then if systemctl is-active --quiet nftables 2>/dev/null || nft list ruleset >/dev/null 2>&1; then echo "nftables"; return 0; fi; fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then echo "firewalld"; return 0; fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then echo "firewalld"; return 0; fi
  fi
  if command -v iptables-save >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then echo "iptables"; return 0; fi
  echo "none"; return 0
}

# simple extraction check for firewall changes (kept compact)
firewall_change_exists() {
  local manager="$1"; shift
  local cmd="$*"
  local ports; ports="$(echo "$cmd" | grep -oE '([0-9]{2,5})' | tr '\n' ' ' | tr ' ' '\n' | sort -u || true)"
  if [[ -z "$ports" ]]; then return 1; fi
  for port in $ports; do
    case "$manager" in
      nftables) nft list ruleset 2>/dev/null | grep -E -q "dport[[:space:]]+$port" && return 0 ;;
      firewalld) firewall-cmd --permanent --list-ports 2>/dev/null | tr ' ' '\n' | grep -xq "${port}/tcp" && return 0 ;;
      iptables) if command -v iptables >/dev/null 2>&1; then iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 && return 0; fi ;;
      csf)
        if [[ -r /etc/csf/csf.conf ]]; then
          local line; line="$(grep -i '^TCP_IN' /etc/csf/csf.conf 2>/dev/null | head -n1 || true)"
          line="${line#*=}"; line="${line//\"/}"; line="${line//\'/}"; line="${line// /}"
          for p in 25 465 587; do grep -q "^$p\$" <<<"${line//,/\\n}" && return 0 || true; done
        fi ;;
    esac
  done
  return 1
}

precheck_and_perform_firewall_action() {
  local manager="$1"; shift
  local desc="$1"; shift
  local cmd="$*"
  if firewall_change_exists "$manager" "$cmd"; then
    printf "%b%s%b\n" "${BLUE}" "Firewall changes aren't necessary — already present" "${RESET}"
    ACTION_DESCS+=("$desc"); ACTION_CMDS+=("$cmd"); ACTION_RESULTS+=("already"); log_info "Skipped firewall action (already present): $desc"; return 0
  fi
  perform_action "$desc" "$cmd"
}

configure_firewall() {
  local fw; fw="$(detect_active_firewall)"; log_info "Detected firewall manager: ${fw}"
  case "$fw" in
    nftables)
      log_info "Managing nftables"
      local nft_base="nft add table inet linkzero >/dev/null 2>&1 || true; nft add chain inet linkzero input '{ type filter hook input priority 0 ; }' >/dev/null 2>&1 || true;"
      precheck_and_perform_firewall_action "nftables" "Ensure nftables table/chain exists" "$nft_base"
      precheck_and_perform_firewall_action "nftables" "Allow Submission (port 587)" "$nft_base nft add rule inet linkzero input tcp dport 587 accept >/dev/null 2>&1 || true"
      precheck_and_perform_firewall_action "nftables" "Allow SMTP (port 25)" "$nft_base nft add rule inet linkzero input tcp dport 25 accept >/dev/null 2>&1 || true"
      precheck_and_perform_firewall_action "nftables" "Allow SMTPS (port 465)" "$nft_base nft add rule inet linkzero input tcp dport 465 accept >/dev/null 2>&1 || true"
      ;;
    csf)
      log_info "Managing CSF"
      perform_action "Reload CSF firewall" "csf -r || true"
      precheck_and_perform_firewall_action "csf" "Ensure /etc/csf/csf.conf has TCP_IN 25,587,465" "printf '%s\n' 'Please edit /etc/csf/csf.conf and ensure TCP_IN includes 25,587,465' >&2"
      ;;
    firewalld)
      log_info "Managing firewalld"
      precheck_and_perform_firewall_action "firewalld" "Open port 587/tcp permanently" "firewall-cmd --permanent --add-port=587/tcp"
      precheck_and_perform_firewall_action "firewalld" "Open port 25/tcp permanently" "firewall-cmd --permanent --add-port=25/tcp"
      precheck_and_perform_firewall_action "firewalld" "Open port 465/tcp permanently" "firewall-cmd --permanent --add-port=465/tcp"
      precheck_and_perform_firewall_action "firewalld" "Reload firewalld" "firewall-cmd --reload"
      ;;
    iptables)
      log_info "Managing iptables only"
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

# Mail-server detection: cPanel -> exim -> postfix -> none
detect_active_mailserver() {
  MAIL_SERVER_VARIANT=""; MAIL_SERVER_VARIANT_ASSUMED=""; EXIM_VERSION="unknown"

  # Broad cPanel detection; if found, assume Exim (cPanel).
  # If cPanel markers found but exim binary is not visible, mark as "assumed".
  if [[ -d /usr/local/cpanel ]] || [[ -d /var/cpanel ]] || [[ -f /usr/local/cpanel/version ]] || \
     [[ -f /var/cpanel/exim.conf ]] || [[ -f /var/cpanel/main_exim.conf ]] || \
     [[ -x /usr/local/cpanel/bin/rebuildeximconf ]] || [[ -x /scripts/rebuildeximconf ]]; then
    MAIL_SERVER_VARIANT="cPanel"
    if command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then
      MAIL_SERVER_VARIANT_ASSUMED=""
      # capture version
      local ev; ev="$(exim -bV 2>&1 || true)"
      EXIM_VERSION="$(printf '%s\n' "$ev" | sed -nE 's/^[[:space:]]*Exim version[[:space:]]*(.+)$/\1/ip' | head -n1 || true)"
      EXIM_VERSION="${EXIM_VERSION:-$(printf '%s\n' "$ev" | sed -n '1p' | xargs || true)}"
      EXIM_VERSION="${EXIM_VERSION:-unknown}"
    else
      MAIL_SERVER_VARIANT_ASSUMED="assumed"
      EXIM_VERSION="unknown"
    fi
    echo "exim"; return 0
  fi

  # If not cPanel, detect exim binary and version
  if command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then
    local ev; ev="$(exim -bV 2>&1 || true)"
    EXIM_VERSION="$(printf '%s\n' "$ev" | sed -nE 's/^[[:space:]]*Exim version[[:space:]]*(.+)$/\1/ip' | head -n1 || true)"
    EXIM_VERSION="${EXIM_VERSION:-$(printf '%s\n' "$ev" | sed -n '1p' | xargs || true)}"
    EXIM_VERSION="${EXIM_VERSION:-unknown}"
    # if output references cPanel, mark variant (not assumed)
    if printf '%s\n' "$ev" | grep -qiE 'cpanel|/var/cpanel|/usr/local/cpanel'; then MAIL_SERVER_VARIANT="cPanel"; MAIL_SERVER_VARIANT_ASSUMED=""; fi
    echo "exim"; return 0
  fi

  # Postfix fallback
  if command -v postconf >/dev/null 2>&1 || command -v postfix >/dev/null 2>&1; then
    echo "postfix"; return 0
  fi

  echo "none"; return 0
}

# Capitalize first letter for display
capitalize_first() {
  local s="$1"; [[ -z "$s" ]] && { echo ""; return; }
  local first="${s:0:1}"; local rest="${s:1}"
  printf '%s%s' "${first^^}" "$rest"
}

configure_postfix(){
  log_info "Configuring Postfix to require TLS for AUTH"
  if ! command -v postconf >/dev/null 2>&1; then log_info "postconf not present; skipping Postfix configuration"; return 0; fi
  perform_action "Set Postfix: smtpd_tls_auth_only = yes" "postconf -e 'smtpd_tls_auth_only = yes'"
  perform_action "Set Postfix: smtpd_tls_security_level = may" "postconf -e 'smtpd_tls_security_level = may'"
  perform_action "Set Postfix: smtpd_sasl_auth_enable = yes" "postconf -e 'smtpd_sasl_auth_enable = yes'"
  if command -v systemctl >/dev/null 2>&1; then perform_action "Restart Postfix via systemctl" "systemctl restart postfix"; else perform_action "Restart Postfix via service" "service postfix restart"; fi
}

configure_exim(){
  log_info "Configuring Exim to require TLS for AUTH (if Exim present or cPanel assumed)"

  if ! command -v exim >/dev/null 2>&1 && ! command -v exim4 >/dev/null 2>&1 && [[ -z "${MAIL_SERVER_VARIANT}" ]]; then
    log_info "Exim not present; skipping Exim configuration"
    return 0
  fi

  local exim_conf=""
  if [[ -f /etc/exim4/exim4.conf.template ]]; then exim_conf="/etc/exim4/exim4.conf.template"
  elif [[ -f /etc/exim/exim.conf ]]; then exim_conf="/etc/exim/exim.conf"
  elif [[ -f /etc/exim.conf ]]; then exim_conf="/etc/exim.conf"; fi

  if [[ -z "$exim_conf" && "${MAIL_SERVER_VARIANT}" == "cPanel" ]]; then
    local candidates=( "/var/cpanel/exim.conf" "/var/cpanel/main_exim.conf" "/var/cpanel/exim.conf.local" "/etc/exim.conf" "/etc/exim.conf.local" "/var/cpanel/userdata/*/exim.conf" )
    for p in "${candidates[@]}"; do
      for f in $p; do [[ -f "$f" ]] && { exim_conf="$f"; break 2; } done
    done
    if [[ -z "$exim_conf" ]]; then
      local found; found="$(find /var/cpanel /etc -maxdepth 2 -type f -iname '*exim*.conf' 2>/dev/null | head -n1 || true)"
      [[ -n "$found" ]] && exim_conf="$found"
    fi
    if [[ -n "$exim_conf" ]]; then log_info "Detected Exim (cPanel) installation; using config: ${exim_conf}"; else log_info "cPanel detected but Exim config not found in common cPanel locations; proceeding to search"; fi
  fi

  if [[ -z "$exim_conf" ]]; then
    if command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then
      local ev; ev="$(exim -bV 2>&1 || true)"
      exim_conf="$(printf '%s\n' "$ev" | sed -nE 's/.*Configuration file[^:]*:[[:space:]]*(.+)$/\1/p' | head -n1 || true)"
      if [[ -z "$exim_conf" && printf '%s\n' "$ev" | grep -qi '/etc/exim4'; then
        if [[ -f /etc/exim4/exim4.conf.template ]]; then exim_conf="/etc/exim4/exim4.conf.template"; elif [[ -d /etc/exim4 ]]; then exim_conf="/etc/exim4"; fi
      fi
      exim_conf="$(echo "$exim_conf" | xargs || true)"
      if [[ -n "$exim_conf" && -f "$exim_conf" ]]; then log_info "Discovered Exim configuration via 'exim -bV': ${exim_conf}"; else
        if [[ -d /etc/exim4/conf.d ]]; then exim_conf="/etc/exim4"; log_info "Detected exim4 split-config directory: ${exim_conf}"; else exim_conf=""; fi
      fi
    fi
  fi

  if [[ -n "$exim_conf" ]]; then
    local timestamp; timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if [[ -d "$exim_conf" && "$(basename "$exim_conf")" == "exim4" ]]; then
      local backup_cmd="tar -czf '${exim_conf}.link0.${timestamp}.tgz' -C '$(dirname "$exim_conf")' '$(basename "$exim_conf")' || true"
      perform_backup "Backup Exim split-config directory" "$backup_cmd"
      perform_action "Remove AUTH_CLIENT_ALLOW_NOTLS from Exim split-config (conf.d) files" "grep -R --line-number 'AUTH_CLIENT_ALLOW_NOTLS' '$exim_conf' || true; sed -i.link0 -E '/AUTH_CLIENT_ALLOW_NOTLS/Id' '$exim_conf' || true"
    else
      local backup_cmd="cp -a '$exim_conf' '${exim_conf}.link0.${timestamp}' || true"
      local sed_cmd="sed -i.link0 -E 's/^\\s*AUTH_CLIENT_ALLOW_NOTLS\\b.*//I' '$exim_conf' || true"
      perform_backup "Backup Exim config file" "$backup_cmd"
      perform_action "Remove AUTH_CLIENT_ALLOW_NOTLS from Exim config" "$sed_cmd"
    fi
  else
    log_info "Exim configuration not located; skipping config-file edits"
  fi

  if command -v systemctl >/dev/null 2>&1; then perform_action "Restart Exim via systemctl" "systemctl restart exim4 || systemctl restart exim || true"
  else perform_action "Restart Exim via service" "service exim4 restart || service exim restart || true"; fi
}

test_configuration(){
  log_info "Running basic mail-server checks (prompted)"
  if command -v postfix >/dev/null 2>&1 || command -v postconf >/dev/null 2>&1; then perform_action "Postfix: basic configuration check" "postfix check"; fi
  if [[ "${MAIL_SERVER_VARIANT}" == "cPanel" ]] || command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then perform_action "Exim: basic configuration info" "exim -bV"; fi
}

_print_summary(){
  echo -e "${BLUE}${BOLD}Summary:${RESET}"
  local i
  for i in "${!ACTION_DESCS[@]}"; do
    local d="${ACTION_DESCS[$i]}"; local r="${ACTION_RESULTS[$i]}"
    case "$r" in
      executed) printf "%s %b[EXECUTED]%b — %s\n" "$((i+1))." "$GREEN" "$RESET" "$d" ;;
      failed) printf "%s %b[FAILED]%b   — %s\n" "$((i+1))." "$RED" "$RESET" "$d" ;;
      skipped) printf "%s %b[REJECTED]%b — %s\n" "$((i+1))." "$MAGENTA" "$RESET" "$d" ;;
      dry-accepted) printf "%s %b[DRY-RUN]%b  — %s\n" "$((i+1))." "$YELLOW" "$RESET" "$d" ;;
      already) printf "%s %b[MATCH]%b    — %s\n" "$((i+1))." "$BLUE" "$RESET" "$d" ;;
      *) printf "%s [UNKNOWN] — %s\n" "$((i+1))." "$d" ;;
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
if [[ -t 1 ]]; then tput clear 2>/dev/null || printf '\033[H\033[2J'; fi
  
# Big pixel-art QHTL logo (with double space between T and L)
echo -e "${GREEN}"
echo -e "   █████  █   █  █████        █      █        █   "
echo -e "  █     █ █   █    █          █               █  █"
echo -e "  █     █ █   █    █          █      █  █     █ █ "
echo -e "  █     █ █████    █          █      █  ████  ██  "
echo -e "  █     █ █   █    █          █      █  █   █ █ █ "
echo -e "   █████  █   █    █          █████  █  █   █ █  █"
echo -e "${NC}"

# Red bold capital Daniel Nowakowski below logo
echo -e "${RED}${BOLD} a u t h o r :    D A N I E L    N O W A K O W S K I${NC}"

# Display QHTL Zero header
echo -e "${BLUE}========================================================"
echo -e "        QHTL Zero Configurator SMTP Hardening    "
echo -e "========================================================${NC}"
echo -e ""

  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg"; usage; exit 2 ;;
    esac
  done

  log_info "Starting smtp-hardening (dry-run=${DRY_RUN:-false})"

  configure_firewall

  local mail_svc
  mail_svc="$(detect_active_mailserver)"

  # Build display label: CapitalizedName (version) (assumed cPanel)
  local svc_disp; svc_disp="$(capitalize_first "$mail_svc")"
  local variant_display=""
  if [[ -n "${MAIL_SERVER_VARIANT}" ]]; then
    if [[ "${MAIL_SERVER_VARIANT_ASSUMED}" == "assumed" ]]; then
      variant_display=" (assumed ${MAIL_SERVER_VARIANT})"
    else
      variant_display=" (${MAIL_SERVER_VARIANT})"
    fi
  fi
  local version_display=""
  if [[ "${mail_svc}" == "exim" ]]; then version_display=" (${EXIM_VERSION:-unknown})"; fi

  log_info "Detected mail server: ${svc_disp}${version_display}${variant_display}"

  case "$mail_svc" in
    exim)
      if [[ -n "${MAIL_SERVER_VARIANT}" ]]; then log_info "Exim detected (variant: ${MAIL_SERVER_VARIANT}${MAIL_SERVER_VARIANT_ASSUMED:+, ${MAIL_SERVER_VARIANT_ASSUMED}}) — running Exim-specific tasks."; else log_info "Exim detected — running Exim-specific tasks."; fi
      configure_exim; test_configuration
      ;;
    postfix)
      log_info "Postfix detected — running Postfix-specific tasks."
      configure_postfix; test_configuration
      ;;
    none|*)
      log_info "No mail server detected; attempting both Exim and Postfix tasks (fallback)."
      configure_exim; configure_postfix; test_configuration
      ;;
  esac

  log_info "Completed smtp-hardening run"
  _print_summary
}

main "$@"
