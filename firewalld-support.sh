#!/bin/bash
#
# LinkZero Firewall Support Helper
# Handles firewalld and cPanel/CSF integration
#

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Check if CSF (ConfigServer Security & Firewall) is installed
is_csf_installed() {
    [[ -f /etc/csf/csf.conf ]] && command -v csf >/dev/null 2>&1
}

# Check if firewalld is running
is_firewalld_running() {
    systemctl is-active --quiet firewalld 2>/dev/null
}

# CSF operations
csf_add_port() {
    local port="$1"
    local protocol="$2"
    
    log_info "Adding port $port/$protocol to CSF"
    
    # Add to TCP_IN or UDP_IN in csf.conf
    if [[ "$protocol" == "tcp" ]]; then
        if ! grep -q "TCP_IN.*$port" /etc/csf/csf.conf; then
            sed -i "/^TCP_IN = / s/\"/,$port\"/" /etc/csf/csf.conf
            log_info "Added TCP port $port to CSF configuration"
        fi
    elif [[ "$protocol" == "udp" ]]; then
        if ! grep -q "UDP_IN.*$port" /etc/csf/csf.conf; then
            sed -i "/^UDP_IN = / s/\"/,$port\"/" /etc/csf/csf.conf
            log_info "Added UDP port $port to CSF configuration"
        fi
    fi
    
    # Restart CSF
    if command -v csf >/dev/null 2>&1; then
        csf -r >/dev/null 2>&1 || log_warn "CSF restart failed, manual restart may be required"
    fi
}

# Firewalld operations
firewalld_enable() {
    if ! is_firewalld_running; then
        log_info "Starting and enabling firewalld"
        systemctl start firewalld
        systemctl enable firewalld
    fi
}

firewalld_add_interface() {
    local interface="$1"
    local zone="$2"
    
    log_info "Adding interface $interface to zone $zone"
    firewall-cmd --permanent --zone="$zone" --add-interface="$interface" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1
}

firewalld_add_masquerade() {
    local zone="$1"
    
    log_info "Enabling masquerading for zone $zone"
    firewall-cmd --permanent --zone="$zone" --add-masquerade >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1
}

firewalld_add_port() {
    local port="$1"
    local protocol="$2" 
    local zone="$3"
    
    if is_csf_installed; then
        log_info "CSF detected, delegating port management to CSF"
        csf_add_port "$port" "$protocol"
    else
        log_info "Adding port $port/$protocol to firewalld zone $zone"
        firewall-cmd --permanent --zone="$zone" --add-port="$port/$protocol" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# Main command dispatch
case "${1:-}" in
    "enable")
        firewalld_enable
        ;;
    "add-interface")
        if [[ $# -lt 3 ]]; then
            log_error "Usage: $0 add-interface <interface> <zone>"
            exit 1
        fi
        firewalld_add_interface "$2" "$3"
        ;;
    "add-masquerade") 
        if [[ $# -lt 2 ]]; then
            log_error "Usage: $0 add-masquerade <zone>"
            exit 1
        fi
        firewalld_add_masquerade "$2"
        ;;
    "add-port")
        if [[ $# -lt 4 ]]; then
            log_error "Usage: $0 add-port <port> <protocol> <zone>"
            exit 1
        fi
        firewalld_add_port "$2" "$3" "$4"
        ;;
    *)
        echo "Usage: $0 {enable|add-interface|add-masquerade|add-port}"
        echo ""
        echo "Commands:"
        echo "  enable                          - Start and enable firewalld"
        echo "  add-interface <iface> <zone>    - Add interface to zone"
        echo "  add-masquerade <zone>           - Enable masquerading for zone"  
        echo "  add-port <port> <proto> <zone>  - Add port to zone (delegates to CSF if present)"
        exit 1
        ;;
esac