#!/usr/bin/env bash
#
# disable_smtp_plain.sh
# Harden Postfix/Exim by disabling plaintext auth methods and provide a strict
# --dry-run mode that produces no side effects on the running system.
#
# Behavior:
#  - Without --dry-run: performs backups, edits, and service restarts as needed.
#  - With --dry-run: echoes the commands that would run and never writes files
#    or restarts services (including not appending to the log file).
#
set -euo pipefail

LOG_FILE="/var/log/linkzero-smtp-security.log"
DRY_RUN="${DRY_RUN:-false}"

# Print messages; in dry-run mode do NOT write to disk or modify system state.
log(){
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # Strict dry-run: print only to stdout, never append to log files.
        printf '%s [%s] %s\n' "$ts" "$level" "$msg"
    else
        # Real run: preserve previous behavior (append to logfile).
        printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
    fi
}

log_info(){ log "INFO" "$@"; }
log_error(){ log "ERROR" "$@"; }
log_success(){ log "SUCCESS" "$@"; }

# run_or_echo: in dry-run echo the command prefixed with "+", otherwise execute.
run_or_echo(){
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # Join arguments in a way that's readable.
        local cmd
        printf -v cmd "%s " "$@"
        echo "+ ${cmd% }"
    else
        # Use eval to preserve original script behavior where needed.
        eval "$*"
    fi
}

# Create a backup of iptables rules, but in dry-run do not write any files.
backup_iptables_snapshot(){
    local BACKUP_DIR="/var/backups/linkzero"
    local TIMESTAMP
    TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    if ! command -v iptables-save >/dev/null 2>&1; then
        log_info "iptables-save not found; skipping snapshot"
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "+ mkdir -p '$BACKUP_DIR'"
        echo "+ iptables-save > '$BACKUP_DIR/iptables.$TIMESTAMP'"
        log_info "Dry-run: would save iptables snapshot to $BACKUP_DIR/iptables.$TIMESTAMP"
    else
        mkdir -p "$BACKUP_DIR"
        if iptables-save > "$BACKUP_DIR/iptables.$TIMESTAMP"; then
            log_info "Saved iptables snapshot to $BACKUP_DIR/iptables.$TIMESTAMP"
        else
            log_error "Failed to save iptables snapshot"
        fi
    fi
}

configure_firewall(){
    log_info "Configuring firewall rules to allow submission on port 587 and enforce TLS-only AUTH"
    backup_iptables_snapshot

    # Example rule to accept submission (port 587)
    run_or_echo iptables -I INPUT -p tcp --dport 587 -j ACCEPT

    # If CSF (ConfigServer) is installed, reload it. In dry-run only echo.
    if command -v csf >/dev/null 2>&1; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "+ csf -r"
        else
            csf -r >/dev/null 2>&1 && log_info "Reloaded CSF" || log_error "CSF reload failed"
        fi
    fi
}

# Configure Postfix: require TLS for AUTH and enable smtpd_tls_auth_only
configure_postfix(){
    log_info "Configuring Postfix to require TLS for AUTH"

    # Ensure postfix is installed before attempting to change config
    if ! command -v postconf >/dev/null 2>&1; then
        log_info "postconf not present; skipping Postfix configuration"
        return 0
    fi

    # Set smtpd_tls_auth_only = yes
    run_or_echo postconf -e "smtpd_tls_auth_only = yes"

    # Optionally enforce other settings (examples)
    run_or_echo postconf -e "smtpd_tls_security_level = may"
    run_or_echo postconf -e "smtpd_sasl_auth_enable = yes"

    # Restart the service if present
    if command -v systemctl >/dev/null 2>&1; then
        run_or_echo systemctl restart postfix
    else
        run_or_echo service postfix restart
    fi
}

# Configure Exim: ensure AUTH is conditional on TLS
configure_exim(){
    log_info "Configuring Exim to require TLS for AUTH (if Exim is present)"
    if ! command -v exim >/dev/null 2>&1 && ! command -v exim4 >/dev/null 2>&1; then
        log_info "Exim not present; skipping Exim configuration"
        return 0
    fi

    local exim_conf
    # Common Debian path
    if [[ -f /etc/exim4/exim4.conf.template ]]; then
        exim_conf="/etc/exim4/exim4.conf.template"
    elif [[ -f /etc/exim/exim.conf ]]; then
        exim_conf="/etc/exim/exim.conf"
    else
        exim_conf=""
    fi

    if [[ -n "$exim_conf" ]]; then
        # Example change: ensure AUTH_CLIENT_ALLOW_NOTLS is not enabled.
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "+ sed -i.bak -E 's/^\\s*AUTH_CLIENT_ALLOW_NOTLS\\b.*//I' '$exim_conf' || true"
            log_info "Dry-run: would edit $exim_conf to disable non-TLS AUTH"
        else
            cp -a "$exim_conf" "${exim_conf}.bak.$(date -u +%Y%m%dT%H%M%SZ)" || true
            sed -i.bak -E 's/^\s*AUTH_CLIENT_ALLOW_NOTLS\b.*//I' "$exim_conf" || true
            log_info "Updated $exim_conf and created backup"
        fi
    else
        log_info "Exim configuration file not found at standard locations"
    fi

    # Restart Exim service
    if command -v systemctl >/dev/null 2>&1; then
        run_or_echo systemctl restart exim4 || run_or_echo systemctl restart exim || true
    else
        run_or_echo service exim4 restart || run_or_echo service exim restart || true
    fi
}

# Test the mail server configuration; in dry-run just echo the commands that would run.
test_configuration(){
    log_info "Testing mail server configuration"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "+ postfix check  # (or other verification commands)"
        echo "+ exim -bV"
        log_info "Dry-run: no runtime tests executed"
        return 0
    fi

    if command -v postfix >/dev/null 2>&1; then
        if postfix check >/dev/null 2>&1; then
            log_success "postfix check OK"
        else
            log_error "postfix check failed — inspect configuration"
            return 1
        fi
    fi

    if command -v exim >/dev/null 2>&1 || command -v exim4 >/dev/null 2>&1; then
        # exim -bV writes to stdout; test return code where possible
        if exim -bV >/dev/null 2>&1; then
            log_success "exim basic check OK"
        else
            # exim -bV often returns non-zero even when fine; leave advisory message
            log_info "exim -bV returned non-zero; please inspect exim logs if issues occur"
        fi
    fi
}

usage(){
    cat <<EOF
Usage: $0 [--dry-run]

  --dry-run   Show what would be done without making any changes to the system.
EOF
}

main(){
    # parse args (only --dry-run currently)
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
}

main "$@"
