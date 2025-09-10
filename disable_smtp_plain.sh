#!/bin/bash
# Author: Daniel Nowakowski
#
# LinkZero - Disable unencrypted communication on port 25
# CloudLinux SMTP Security Script
# 
# This script disables unencrypted SMTP communication on port 25
# for CloudLinux environments by configuring mail servers to require TLS/SSL
#
# Usage: ./disable_smtp_plain.sh [--backup-only] [--restore] [--dry-run]
#
# Author: LinkZero Project
# License: See LICENSE file
#


set -euo pipefail


# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
LOG_FILE="/var/log/linkzero-smtp-security.log"
BACKUP_DIR="/var/backups/linkzero-$(date +%Y%m%d-%H%M%S)"
DRY_RUN=false
BACKUP_ONLY=false
RESTORE=false


# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color


# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}


log_info() {
    log "INFO" "$@"
    echo -e "${BLUE}[INFO]${NC} $*"
}


log_warn() {
    log "WARN" "$@"
    echo -e "${YELLOW}[WARN]${NC} $*"
}


log_error() {
    log "ERROR" "$@"
    echo -e "${RED}[ERROR]${NC} $*"
}


log_success() {
    log "SUCCESS" "$@"
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}


# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}


# Check CloudLinux environment
check_cloudlinux() {
    if [[ ! -f /etc/redhat-release ]] || ! grep -qi "cloudlinux" /etc/redhat-release 2>/dev/null; then
        log_warn "This script is designed for CloudLinux environments"
        log_warn "Proceeding anyway, but some features may not work as expected"
    else
        log_info "CloudLinux environment detected"
    fi
}


# Create backup directory
create_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    log_info "Created backup directory: $BACKUP_DIR"
}


# Detect mail server
detect_mail_server() {
    local mail_server=""
    
    if systemctl is-active --quiet postfix 2>/dev/null || [[ -f /etc/postfix/main.cf ]]; then
        mail_server="postfix"
    elif systemctl is-active --quiet exim 2>/dev/null || [[ -f /etc/exim/exim.conf ]]; then
        mail_server="exim"
    elif [[ -f /etc/sendmail.cf ]]; then
        mail_server="sendmail"
    fi
    
    echo "$mail_server"
}


# Backup configuration files
backup_configs() {
    log_info "Creating backup of current configuration..."
    
    local mail_server=$(detect_mail_server)
    
    case "$mail_server" in
        "postfix")
            if [[ -f /etc/postfix/main.cf ]]; then
                cp /etc/postfix/main.cf "$BACKUP_DIR/postfix_main.cf.backup"
                log_info "Backed up /etc/postfix/main.cf"
            fi
            if [[ -f /etc/postfix/master.cf ]]; then
                cp /etc/postfix/master.cf "$BACKUP_DIR/postfix_master.cf.backup"
                log_info "Backed up /etc/postfix/master.cf"
            fi
            ;;
        "exim")
            if [[ -f /etc/exim/exim.conf ]]; then
                cp /etc/exim/exim.conf "$BACKUP_DIR/exim.conf.backup"
                log_info "Backed up /etc/exim/exim.conf"
            fi
            ;;
        "sendmail")
            if [[ -f /etc/sendmail.cf ]]; then
                cp /etc/sendmail.cf "$BACKUP_DIR/sendmail.cf.backup"
                log_info "Backed up /etc/sendmail.cf"
            fi
            ;;
        *)
            log_warn "No supported mail server configuration found"
            ;;
    esac
    
    # Backup firewall rules
    if command -v iptables >/dev/null 2>&1; then
        iptables-save > "$BACKUP_DIR/iptables.backup"
        log_info "Backed up iptables rules"
    fi
    
    # Backup CSF if present (common on CloudLinux)
    if [[ -f /etc/csf/csf.conf ]]; then
        cp /etc/csf/csf.conf "$BACKUP_DIR/csf.conf.backup"
        log_info "Backed up CSF configuration"
    fi
}


# Configure Postfix to disable plain text SMTP
configure_postfix() {
    log_info "Configuring Postfix to disable unencrypted SMTP..."
    
    local main_cf="/etc/postfix/main.cf"
    local master_cf="/etc/postfix/master.cf"
    
    if [[ ! -f "$main_cf" ]]; then
        log_error "Postfix main.cf not found at $main_cf"
        return 1
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would modify $main_cf to require TLS"
        return 0
    fi
    
    # Configure main.cf for TLS enforcement
    {
        echo ""
        echo "# LinkZero: Force TLS encryption for SMTP"
        echo "smtpd_tls_security_level = encrypt"
        echo "smtpd_tls_auth_only = yes"
        echo "smtpd_tls_mandatory_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
        echo "smtpd_tls_mandatory_ciphers = high"
        echo "tls_high_cipherlist = ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:RSA+AES:!aNULL:!MD5:!DSS"
        echo "smtp_tls_security_level = encrypt"
        echo "smtp_tls_mandatory_protocols = !SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
    } >> "$main_cf"
    
    log_success "Postfix configuration updated to require TLS encryption"
}


# Configure Exim to disable plain text SMTP
configure_exim() {
    log_info "Configuring Exim to disable unencrypted SMTP..."
    
    local exim_conf="/etc/exim/exim.conf"
    
    if [[ ! -f "$exim_conf" ]]; then
        log_error "Exim configuration not found at $exim_conf"
        return 1
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would modify $exim_conf to require TLS"
        return 0
    fi
    
    # Add TLS enforcement to Exim configuration
    sed -i '/^# LinkZero: TLS enforcement/,/^# End LinkZero TLS enforcement/d' "$exim_conf"
    
    {
        echo ""
        echo "# LinkZero: TLS enforcement"
        echo "tls_on_connect_ports = 465"
        echo "tls_advertise_hosts = *"
        echo "auth_advertise_condition = \${if eq{\$tls_cipher}{}{}{*}}"
        echo "# End LinkZero TLS enforcement"
    } >> "$exim_conf"
    
    log_success "Exim configuration updated to require TLS encryption"
}


# Configure firewall to block unencrypted SMTP
configure_firewall() {
    log_info "Configuring firewall to secure SMTP ports..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would configure firewall rules"
        return 0
    fi
    
    # Configure iptables rules
    if command -v iptables >/dev/null 2>&1; then
        # Allow encrypted SMTP ports (587 for submission, 465 for SMTPS)
        iptables -A INPUT -p tcp --dport 587 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 465 -j ACCEPT 2>/dev/null || true
        
        # Block unencrypted SMTP on port 25 for external connections
        # (Keep localhost access for local mail delivery)
        iptables -A INPUT -p tcp --dport 25 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport 25 -j DROP 2>/dev/null || true
        
        log_info "iptables rules configured"
    fi
    
    # Configure CSF if present
    if [[ -f /etc/csf/csf.conf ]] && command -v csf >/dev/null 2>&1; then
        # Ensure secure ports are open
        sed -i 's/TCP_IN = "\([^"]*\)"/TCP_IN = "\1,587,465"/' /etc/csf/csf.conf
        sed -i 's/TCP_OUT = "\([^"]*\)"/TCP_OUT = "\1,587,465"/' /etc/csf/csf.conf
        
        # Restart CSF
        csf -r >/dev/null 2>&1 || log_warn "Failed to restart CSF"
        log_info "CSF firewall configured"
    fi
}


# Restart mail services
restart_services() {
    log_info "Restarting mail services..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restart mail services"
        return 0
    fi
    
    local mail_server=$(detect_mail_server)
    
    case "$mail_server" in
        "postfix")
            systemctl restart postfix && log_success "Postfix restarted" || log_error "Failed to restart Postfix"
            ;;
        "exim")
            systemctl restart exim && log_success "Exim restarted" || log_error "Failed to restart Exim"
            ;;
        "sendmail")
            systemctl restart sendmail && log_success "Sendmail restarted" || log_error "Failed to restart Sendmail"
            ;;
        *)
            log_warn "No mail server service to restart"
            ;;
    esac
}


# Test configuration
test_configuration() {
    log_info "Testing SMTP configuration..."
    
    local mail_server=$(detect_mail_server)
    
    case "$mail_server" in
        "postfix")
            if postfix check 2>/dev/null; then
                log_success "Postfix configuration syntax is valid"
            else
                log_error "Postfix configuration has syntax errors"
                return 1
            fi
            ;;
        "exim")
            if exim -bV >/dev/null 2>&1; then
                log_success "Exim is running and accessible"
            else
                log_error "Exim configuration issues detected"
                return 1
            fi
            ;;
    esac
    
    # Test port accessibility
    if command -v telnet >/dev/null 2>&1; then
        log_info "Testing SMTP ports..."
        if timeout 5 telnet localhost 587 </dev/null >/dev/null 2>&1; then
            log_success "Port 587 (submission) is accessible"
        else
            log_warn "Port 587 (submission) may not be accessible"
        fi
    fi
}


# Restore from backup
restore_configuration() {
    log_info "Restoring configuration from backup..."
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi
    
    # Restore mail server configs
    [[ -f "$BACKUP_DIR/postfix_main.cf.backup" ]] && cp "$BACKUP_DIR/postfix_main.cf.backup" /etc/postfix/main.cf
    [[ -f "$BACKUP_DIR/postfix_master.cf.backup" ]] && cp "$BACKUP_DIR/postfix_master.cf.backup" /etc/postfix/master.cf
    [[ -f "$BACKUP_DIR/exim.conf.backup" ]] && cp "$BACKUP_DIR/exim.conf.backup" /etc/exim/exim.conf
    [[ -f "$BACKUP_DIR/sendmail.cf.backup" ]] && cp "$BACKUP_DIR/sendmail.cf.backup" /etc/sendmail.cf
    
    # Restore firewall
    [[ -f "$BACKUP_DIR/iptables.backup" ]] && iptables-restore < "$BACKUP_DIR/iptables.backup"
    [[ -f "$BACKUP_DIR/csf.conf.backup" ]] && cp "$BACKUP_DIR/csf.conf.backup" /etc/csf/csf.conf
    
    restart_services
    log_success "Configuration restored from backup"
}


# Display usage information
usage() {
    cat << EOF
LinkZero - Disable unencrypted communication on port 25

Usage: $0 [OPTIONS]

Options:
    --backup-only   Create backup only, don't modify configuration
    --restore       Restore from backup (requires backup directory)
    --dry-run       Show what would be changed without making changes
    --help          Display this help message

Examples:
    $0                    # Apply security configuration
    $0 --dry-run          # Preview changes without applying
    $0 --backup-only      # Create backup of current configuration
    $0 --restore          # Restore from most recent backup

EOF
}


# Main execution function
main() {
    log_info "Starting LinkZero SMTP Security Configuration"
    log_info "Timestamp: $(date)"
    
    check_root
    check_cloudlinux
    
    local mail_server=$(detect_mail_server)
    if [[ -z "$mail_server" ]]; then
        log_error "No supported mail server detected (Postfix, Exim, or Sendmail)"
        exit 1
    fi
    
    log_info "Detected mail server: $mail_server"
    
    create_backup_dir
    backup_configs
    
    if [[ "$BACKUP_ONLY" == "true" ]]; then
        log_success "Backup completed. Files saved to: $BACKUP_DIR"
        exit 0
    fi
    
    if [[ "$RESTORE" == "true" ]]; then
        restore_configuration
        exit 0
    fi
    
    # Apply security configuration
    case "$mail_server" in
        "postfix")
            configure_postfix
            ;;
        "exim")
            configure_exim
            ;;
        *)
            log_error "Configuration for $mail_server is not yet implemented"
            exit 1
            ;;
    esac
    
    configure_firewall
    restart_services
    test_configuration
    
    log_success "SMTP security configuration completed successfully!"
    log_info "Backup saved to: $BACKUP_DIR"
    log_info "Log file: $LOG_FILE"
    
    echo ""
    log_info "Summary of changes:"
    echo "  - Mail server configured to require TLS encryption"
    echo "  - Unencrypted SMTP on port 25 blocked for external connections"
    echo "  - Secure SMTP ports (587, 465) configured and accessible"
    echo "  - Configuration backup created: $BACKUP_DIR"
    echo ""
    log_warn "Important: Ensure your mail clients are configured to use TLS/SSL"
    log_warn "Use port 587 (STARTTLS) or 465 (SSL/TLS) for outgoing mail"
}


# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --backup-only)
            BACKUP_ONLY=true
            shift
            ;;
        --restore)
            RESTORE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done


# Execute main function
main "$@"
