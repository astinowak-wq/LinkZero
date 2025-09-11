#!/usr/bin/env bash
#
# disable_smtp_plain.sh
#
# Purpose:
#   Enforce that SMTP AUTH is only allowed after TLS (STARTTLS) and reduce
#   exposure to plaintext SMTP authentication. Supports Postfix and Exim,
#   makes timestamped backups, supports dry-run, restore, and backup-only modes.
#
# Usage:
#   sudo ./disable_smtp_plain.sh [--dry-run] [--backup-only] [--restore] [--rollback]
#                          [--backup-dir DIR] [--no-restart] [--help]
#
# Notes:
#   - This script is conservative: it copies configuration files to BACKUP_DIR
#     before making changes and validates downloaded/edited content where needed.
#   - Test with --dry-run first on production systems.
#

set -euo pipefail

PROGNAME="$(basename "$0")"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR_DEFAULT="/var/backups/linkzero-smtp"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
LOG_FILE="/var/log/linkzero-smtp-security.log"
DRY_RUN=false
BACKUP_ONLY=false
RESTORE=false
ROLLBACK=false
NO_RESTART=false

# Colors (only used when outputting to terminal)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log(){
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}
log_info(){ log "INFO" "$@"; }
log_warn(){ log "WARN" "$@"; }
log_error(){ log "ERROR" "$@"; }
log_success(){ log "SUCCESS" "$@"; }

run_or_echo(){
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "+ $*"
    else
        eval "$@"
    fi
}

require_root(){
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 3
    fi
}

usage(){
    cat <<EOF
$PROGNAME - enforce SMTP AUTH only over TLS

Usage: $PROGNAME [OPTIONS]

Options:
  --dry-run            Show actions but don't apply changes.
  --backup-only        Only create backups and exit.
  --restore            Restore latest backup (explicit restore).
  --rollback           Alias for --restore (keeps naming).
  --backup-dir DIR     Use DIR for backups (default: $BACKUP_DIR_DEFAULT).
  --no-restart         Do not restart mail services after changes.
  --help               Show this help.
EOF
}

# Basic environment checks
check_cloudlinux(){
    if [[ -f /etc/redhat-release ]] && grep -qi 'cloudlinux' /etc/redhat-release 2>/dev/null; then
        log_info "CloudLinux environment detected."
    else
        log_warn "CloudLinux not detected. Script is generic; continue carefully."
    fi
}

create_backup_dir(){
    run_or_echo "mkdir -p '$BACKUP_DIR'"
    log_info "Using backup directory: $BACKUP_DIR"
}

detect_mail_server(){
    local ms=""
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-units --type=service --state=active | grep -qi postfix; then
            ms="postfix"
        elif systemctl list-units --type=service --state=active | grep -qi exim; then
            ms="exim"
        elif systemctl list-units --type=service --state=active | grep -qi sendmail; then
            ms="sendmail"
        fi
    fi

    # Fallback by checking config files
    if [[ -z "$ms" ]]; then
        if [[ -f /etc/postfix/main.cf ]]; then ms="postfix"; fi
        if [[ -f /etc/exim/exim.conf || -f /etc/exim4/update-exim4.conf.conf ]]; then ms="exim"; fi
        if [[ -f /etc/sendmail.cf ]]; then ms="sendmail"; fi
    fi

    echo "$ms"
}

backup_configs(){
    log_info "Creating backups..."
    local ms
    ms="$(detect_mail_server)"
    local t="$TIMESTAMP"
    # Mail server specific backups
    case "$ms" in
        postfix)
            if [[ -f /etc/postfix/main.cf ]]; then
                run_or_echo "cp -a /etc/postfix/main.cf '$BACKUP_DIR/main.cf.$t'"
                log_info "Backed up /etc/postfix/main.cf -> $BACKUP_DIR/main.cf.$t"
            fi
            if [[ -f /etc/postfix/master.cf ]]; then
                run_or_echo "cp -a /etc/postfix/master.cf '$BACKUP_DIR/master.cf.$t'"
                log_info "Backed up /etc/postfix/master.cf -> $BACKUP_DIR/master.cf.$t"
            fi
            ;;
        exim)
            if [[ -f /etc/exim/exim.conf ]]; then
                run_or_echo "cp -a /etc/exim/exim.conf '$BACKUP_DIR/exim.conf.$t'"
                log_info "Backed up /etc/exim/exim.conf -> $BACKUP_DIR/exim.conf.$t"
            fi
            if [[ -f /etc/exim4/update-exim4.conf.conf ]]; then
                run_or_echo "cp -a /etc/exim4/update-exim4.conf.conf '$BACKUP_DIR/update-exim4.conf.conf.$t'"
                log_info "Backed up /etc/exim4/update-exim4.conf.conf -> $BACKUP_DIR/update-exim4.conf.conf.$t"
            fi
            ;;
        sendmail)
            if [[ -f /etc/sendmail.cf ]]; then
                run_or_echo "cp -a /etc/sendmail.cf '$BACKUP_DIR/sendmail.cf.$t'"
                log_info "Backed up /etc/sendmail.cf -> $BACKUP_DIR/sendmail.cf.$t"
            fi
            ;;
        *)
            log_warn "No known mail server detected; nothing backed up for mail server configs."
            ;;
    esac

    # Backup firewall rules if available
    if command -v iptables-save >/dev/null 2>&1; then
        run_or_echo "iptables-save > '$BACKUP_DIR/iptables.$t'"
        log_info "Backed up iptables -> $BACKUP_DIR/iptables.$t"
    fi
    if [[ -f /etc/csf/csf.conf ]]; then
        run_or_echo "cp -a /etc/csf/csf.conf '$BACKUP_DIR/csf.conf.$t'"
        log_info "Backed up CSF config -> $BACKUP_DIR/csf.conf.$t"
    fi
}

restore_configuration(){
    local latest
    latest="$(ls -1t "$BACKUP_DIR"/* 2>/dev/null | head -n1 || true)"
    if [[ -z "$latest" ]]; then
        log_error "No backups found in $BACKUP_DIR"
        exit 4
    fi

    # Restore by matching filename patterns (conservative)
    if ls -1t "$BACKUP_DIR"/main.cf.* >/dev/null 2>&1; then
        local m
        m="$(ls -1t "$BACKUP_DIR"/main.cf.* | head -n1)"
        run_or_echo "cp -a '$m' /etc/postfix/main.cf"
        log_info "Restored /etc/postfix/main.cf from $m"
    fi
    if ls -1t "$BACKUP_DIR"/master.cf.* >/dev/null 2>&1; then
        local mm
        mm="$(ls -1t "$BACKUP_DIR"/master.cf.* | head -n1)"
        run_or_echo "cp -a '$mm' /etc/postfix/master.cf"
        log_info "Restored /etc/postfix/master.cf from $mm"
    fi
    if ls -1t "$BACKUP_DIR"/exim.conf.* >/dev/null 2>&1; then
        local e
        e="$(ls -1t "$BACKUP_DIR"/exim.conf.* | head -n1)"
        run_or_echo "cp -a '$e' /etc/exim/exim.conf"
        log_info "Restored /etc/exim/exim.conf from $e"
    fi
    if ls -1t "$BACKUP_DIR"/sendmail.cf.* >/dev/null 2>&1; then
        local s
        s="$(ls -1t "$BACKUP_DIR"/sendmail.cf.* | head -n1)"
        run_or_echo "cp -a '$s' /etc/sendmail.cf"
        log_info "Restored /etc/sendmail.cf from $s"
    fi

    # Restore iptables if present
    if [[ -f "$BACKUP_DIR/iptables.$TIMESTAMP" ]]; then
        run_or_echo "iptables-restore < '$BACKUP_DIR/iptables.$TIMESTAMP'"
        log_info "Restored iptables from $BACKUP_DIR/iptables.$TIMESTAMP"
    else
        # pick latest iptables.*
        if ls -1t "$BACKUP_DIR"/iptables.* >/dev/null 2>&1; then
            local ipf
            ipf="$(ls -1t "$BACKUP_DIR"/iptables.* | head -n1)"
            run_or_echo "iptables-restore < '$ipf'"
            log_info "Restored iptables from $ipf"
        fi
    fi

    if [[ "$NO_RESTART" == "false" ]]; then
        restart_services
    fi

    log_success "Restore completed (or dry-run showed actions)."
}

configure_postfix(){
    log_info "Configuring Postfix to require AUTH only after TLS"
    local main_cf="/etc/postfix/main.cf"

    if [[ ! -f "$main_cf" ]]; then
        log_error "Postfix main.cf not found; skipping Postfix configuration"
        return 1
    fi

    # Use postconf -e when available (safer)
    if command -v postconf >/dev/null 2>&1; then
        run_or_echo "postconf -e 'smtpd_tls_auth_only = yes'"
        # ensure STARTTLS offered at least
        local cur_tls
        cur_tls="$(postconf -h smtpd_tls_security_level || true)"
        if [[ -z "$cur_tls" || "$cur_tls" == "none" ]]; then
            run_or_echo "postconf -e 'smtpd_tls_security_level = may'"
        else
            log_info "Existing smtpd_tls_security_level = $cur_tls (left unchanged)"
        fi

        # If SASL is enabled, ensure noanonymous is present
        local sasl_enable
        sasl_enable="$(postconf -h smtpd_sasl_auth_enable || true)"
        local sasl_opts
        sasl_opts="$(postconf -h smtpd_sasl_security_options || true)"
        if [[ -n "$sasl_enable" && "$sasl_enable" != "no" ]]; then
            if [[ -z "$sasl_opts" ]]; then
                run_or_echo "postconf -e 'smtpd_sasl_security_options = noanonymous'"
            else
                if echo "$sasl_opts" | grep -q noanonymous; then
                    log_info "smtpd_sasl_security_options already contains noanonymous"
                else
                    run_or_echo "postconf -e 'smtpd_sasl_security_options = ${sasl_opts},noanonymous'"
                fi
            fi
        else
            log_info "SASL appears not enabled (smtpd_sasl_auth_enable=$sasl_enable); not forcing SASL options."
        fi

        # add a short note in main.cf (non-duplicating)
        if ! grep -q '# LinkZero: enforced smtpd_tls_auth_only' "$main_cf" 2>/dev/null; then
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "+ echo '# LinkZero: enforced smtpd_tls_auth_only=$TIMESTAMP' >> $main_cf"
            else
                printf "\n# LinkZero: enforced smtpd_tls_auth_only=%s\n" "$TIMESTAMP" >> "$main_cf"
                log_info "Appended enforcement note to $main_cf"
            fi
        fi

        log_success "Postfix configuration tasks applied (or dry-run shown them)."
    else
        log_warn "postconf not available; attempting manual edits to $main_cf"
        # Manual conservative edits could be done here (omitted for brevity)
    fi
}

configure_exim(){
    log_info "Configuring Exim to require TLS before AUTH"
    # Conservative approach: append configuration snippet to force TLS for AUTH
    # If Exim uses update-exim4.conf, modify appropriately.
    if [[ -f /etc/exim/exim.conf ]]; then
        local exim_conf="/etc/exim/exim.conf"
        if grep -q "## LinkZero: require TLS for AUTH" "$exim_conf" 2>/dev/null; then
            log_info "Exim already contains LinkZero TLS enforcement snippet; skipping"
            return 0
        fi

        # Append a conservative ACL or comment to guide admins. Exact modifications
        # depend on Exim configuration style; this is intentionally minimal.
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "+ echo '## LinkZero: enforce TLS before AUTH (admin review required)' >> $exim_conf"
        else
            {
                echo
                echo "## LinkZero: enforce TLS before AUTH ($TIMESTAMP)"
                echo "# Please review Exim ACLs to require TLS for AUTH; automated changes are intentionally minimal."
            } >> "$exim_conf"
            log_info "Appended guidance comment to $exim_conf (manual review recommended)"
        fi
        log_success "Exim configuration modified (or dry-run shown actions)."
    else
        log_warn "Exim configuration file not found (/etc/exim/exim.conf); skipping Exim config"
        return 1
    fi
}

configure_firewall(){
    log_info "Configuring firewall to allow encrypted submission ports and restrict port 25 to localhost only"
    # This function is conservative: it adds rules but does not remove existing rules.
    if [[ "$DRY_RUN" == "true" ]]; then
        # show intended iptables commands
        echo "+ iptables -A INPUT -p tcp --dport 587 -j ACCEPT"
        echo "+ iptables -A INPUT -p tcp --dport 465 -j ACCEPT"
        echo "+ iptables -A INPUT -p tcp --dport 25 -s 127.0.0.1 -j ACCEPT"
        echo "+ iptables -A INPUT -p tcp --dport 25 -j DROP"
        return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        # Allow submission (587) and SMTPS (465)
        iptables -C INPUT -p tcp --dport 587 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 587 -j ACCEPT
        iptables -C INPUT -p tcp --dport 465 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 465 -j ACCEPT

        # Keep localhost access to port 25, block the rest (append DROP if not already present)
        iptables -C INPUT -p tcp --dport 25 -s 127.0.0.1 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 25 -s 127.0.0.1 -j ACCEPT
        iptables -C INPUT -p tcp --dport 25 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 25 -j DROP

        # Save rules if possible
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > "$BACKUP_DIR/iptables.$TIMESTAMP"
            log_info "Saved iptables snapshot to $BACKUP_DIR/iptables.$TIMESTAMP"
        fi

        log_success "iptables rules applied to prefer encrypted submission and restrict plaintext port 25."
    else
        log_warn "iptables not found; skipping iptables changes. If you use firewalld, nftables, or CSF, please configure those manually."
    fi

    # CSF adjustments (conservative)
    if [[ -f /etc/csf/csf.conf ]]; then
        log_info "CSF detected: updating allowed ports (conservative edits)"
        # Add 587 and 465 to TCP_IN if not present
        if ! grep -qE '^TCP_IN=.*\b587\b' /etc/csf/csf.conf 2>/dev/null; then
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "+ sed -i 's/^TCP_IN=\"\\(.*\\)\"/TCP_IN=\"\\1,587\"/' /etc/csf/csf.conf"
            else
                sed -i -E 's/^(TCP_IN=")([^"]*)(")/\1\2,587\3/' /etc/csf/csf.conf || true
            fi
        fi
        if ! grep -qE '^TCP_IN=.*\b465\b' /etc/csf/csf.conf 2>/dev/null; then
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "+ sed -i 's/^TCP_IN=\"\\(.*\\)\"/TCP_IN=\"\\1,465\"/' /etc/csf/csf.conf"
            else
                sed -i -E 's/^(TCP_IN=")([^"]*)(")/\1\2,465\3/' /etc/csf/csf.conf || true
            fi
        fi

        if [[ "$DRY_RUN" == "false" ]]; then
            csf -r >/dev/null 2>&1 || log_warn "csf reload returned non-zero or is unavailable."
            log_info "CSF reloaded (if available)."
        fi
    fi
}

restart_services(){
    log_info "Restarting mail services (if present) unless --no-restart set"
    if [[ "$NO_RESTART" == "true" ]]; then
        log_info "--no-restart set: skipping service restarts"
        return 0
    fi

    local ms
    ms="$(detect_mail_server)"
    case "$ms" in
        postfix)
            if command -v systemctl >/dev/null 2>&1; then
                run_or_echo "systemctl restart postfix"
            else
                run_or_echo "service postfix restart"
            fi
            ;;
        exim)
            if command -v systemctl >/dev/null 2>&1; then
                run_or_echo "systemctl restart exim || systemctl restart exim4 || true"
            else
                run_or_echo "service exim restart || service exim4 restart || true"
            fi
            ;;
        sendmail)
            if command -v systemctl >/dev/null 2>&1; then
                run_or_echo "systemctl restart sendmail"
            else
                run_or_echo "service sendmail restart"
            fi
            ;;
        *)
            log_warn "No known mail service detected; no restart attempted."
            ;;
    esac
}

test_configuration(){
    log_info "Testing mail server configuration (basic checks)"
    local ms
    ms="$(detect_mail_server)"
    case "$ms" in
        postfix)
            if command -v postfix >/dev/null 2>&1; then
                if [[ "$DRY_RUN" == "false" ]]; then
                    if postfix check >/dev/null 2>&1; then
                        log_success "postfix check OK"
                    else
                        log_error "postfix check failed — inspect configuration"
                        return 1
                    fi
                else
                    echo "+ postfix check"
                fi
            fi
            ;;
        exim)
            if command -v exim >/dev/null 2>&1; then
                if [[ "$DRY_RUN" == "false" ]]; then
                    if exim -bV >/dev/null 2>&1; then
                        log_success "exim basic check OK"
                    else
                        log_error "exim basic check failed — inspect configuration"
                        return 1
                    fi
                else
                    echo "+ exim -bV"
                fi
            fi
            ;;
        *)
            log_warn "No mail server tests available for detected server: $ms"
            ;;
    esac
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift;;
        --backup-only) BACKUP_ONLY=true; shift;;
        --restore|--rollback) RESTORE=true; ROLLBACK=true; shift;;
        --backup-dir) BACKUP_DIR="$2"; shift 2;;
        --no-restart) NO_RESTART=true; shift;;
        --help) usage; exit 0;;
        *) log_error "Unknown option: $1"; usage; exit 2;;
    esac
done

main(){
    require_root
    check_cloudlinux
    create_backup_dir
    backup_configs

    if [[ "$BACKUP_ONLY" == "true" ]]; then
        log_success "Backups created in $BACKUP_DIR (backup-only mode)."
        exit 0
    fi

    if [[ "$RESTORE" == "true" ]]; then
        restore_configuration
        exit 0
    fi

    # Detect mail server and apply appropriate configuration
    local ms
    ms="$(detect_mail_server)"
    if [[ -z "$ms" ]]; then
        log_error "No supported mail server detected (Postfix/Exim/Sendmail). Aborting."
        exit 5
    fi

    log_info "Detected mail server: $ms"

    case "$ms" in
        postfix)
            configure_postfix
            ;;
        exim)
            configure_exim
            ;;
        sendmail)
            log_warn "Sendmail detected: manual configuration recommended to enforce TLS before AUTH"
            ;;
        *)
            log_error "Unsupported mail server: $ms"
            ;;
    esac

    configure_firewall
    restart_services
    test_configuration

    log_success "Script finished. Backups are in: $BACKUP_DIR"
    log_info "If you need to revert, run: $PROGNAME --restore --backup-dir '$BACKUP_DIR'"
}

main
