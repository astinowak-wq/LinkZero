#!/usr/bin/env bash
#
# scripts/firewalld-support.sh
#
# Simple helper to manage firewalld rules for LinkZero.
# Usage:
#   ./scripts/firewalld-support.sh status
#   ./scripts/firewalld-support.sh enable                 # enable & start firewalld
#   ./scripts/firewalld-support.sh add-port 8080 tcp     # add port to zone (default: public)
#   ./scripts/firewalld-support.sh remove-port 8080 tcp
#   ./scripts/firewalld-support.sh add-interface eth0     # add interface to public zone
#   ./scripts/firewalld-support.sh remove-interface eth0
#   ./scripts/firewalld-support.sh add-masquerade         # enable masquerade in zone (default: public)
#   ./scripts/firewalld-support.sh remove-masquerade
#   ./scripts/firewalld-support.sh add-forward 8080 tcp 10.0.0.5 80  # forward port -> addr:port
#   ./scripts/firewalld-support.sh remove-forward 8080 tcp 10.0.0.5 80
#   ./scripts/firewalld-support.sh direct-add 'rule ipv4 filter INPUT 0 -p tcp --dport 443 -j ACCEPT'
#   ./scripts/firewalld-support.sh direct-remove 'rule ipv4 filter INPUT 0 -p tcp --dport 443 -j ACCEPT'
#
# When CSF is detected, add-port/remove-port operations will use CSF instead of firewalld.
# All other operations continue to use firewalld as normal.

set -euo pipefail

# Configuration
ZONE="${FIREWALLD_ZONE:-public}"
CSF_CONF="/etc/csf/csf.conf"
CSF_BACKUP_DIR="/var/backups/linkzero-csf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Detect if cPanel is installed
detect_cpanel() {
    [[ -f /usr/local/cpanel/cpanel || -d /usr/local/cpanel || -f /etc/wwwacct.conf ]]
}

# Detect if CSF is installed and active
detect_csf() {
    [[ -f "$CSF_CONF" && -x "$(command -v csf)" ]]
}

# Check if CSF is enabled (not in testing mode)
csf_is_enabled() {
    if detect_csf; then
        local testing
        testing=$(grep -E '^TESTING\s*=' "$CSF_CONF" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d ' ')
        [[ "$testing" != "1" ]]
    else
        return 1
    fi
}

# Backup CSF configuration
backup_csf_conf() {
    if [[ -f "$CSF_CONF" ]]; then
        mkdir -p "$CSF_BACKUP_DIR"
        local backup_file
        backup_file="$CSF_BACKUP_DIR/csf.conf.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CSF_CONF" "$backup_file"
        log_info "CSF configuration backed up to: $backup_file"
    fi
}

# Add port to CSF configuration
csf_add_port() {
    local port="$1"
    local protocol="$2"
    
    backup_csf_conf
    
    # Add to TCP_IN or UDP_IN depending on protocol
    if [[ "$protocol" == "tcp" ]]; then
        # Check if port is already in TCP_IN
        if ! grep -E "^TCP_IN\s*=" "$CSF_CONF" | grep -q "\b$port\b"; then
            sed -i "s/^TCP_IN\s*=\s*\"\([^\"]*\)\"/TCP_IN = \"\1,$port\"/" "$CSF_CONF"
            # Clean up any double commas or leading commas
            sed -i "s/TCP_IN = \",/TCP_IN = \"/" "$CSF_CONF"
            sed -i "s/,,/,/g" "$CSF_CONF"
            log_info "Added port $port/tcp to CSF TCP_IN"
        else
            log_info "Port $port/tcp already exists in CSF TCP_IN"
        fi
    elif [[ "$protocol" == "udp" ]]; then
        # Check if port is already in UDP_IN
        if ! grep -E "^UDP_IN\s*=" "$CSF_CONF" | grep -q "\b$port\b"; then
            sed -i "s/^UDP_IN\s*=\s*\"\([^\"]*\)\"/UDP_IN = \"\1,$port\"/" "$CSF_CONF"
            # Clean up any double commas or leading commas
            sed -i "s/UDP_IN = \",/UDP_IN = \"/" "$CSF_CONF"
            sed -i "s/,,/,/g" "$CSF_CONF"
            log_info "Added port $port/udp to CSF UDP_IN"
        else
            log_info "Port $port/udp already exists in CSF UDP_IN"
        fi
    fi
    
    # Restart CSF to apply changes
    if ! csf -r &>/dev/null; then
        log_warn "Failed to restart CSF. Changes may not be active."
        return 1
    else
        log_success "CSF restarted successfully"
    fi
}

# Remove port from CSF configuration
csf_remove_port() {
    local port="$1"
    local protocol="$2"
    
    backup_csf_conf
    
    # Remove from TCP_IN or UDP_IN depending on protocol
    if [[ "$protocol" == "tcp" ]]; then
        # Remove port from TCP_IN
        sed -i "s/\b,$port\b//g; s/\b$port,\b//g; s/\b$port\b//g" "$CSF_CONF"
        # Clean up any double commas
        sed -i "s/,,/,/g" "$CSF_CONF"
        log_info "Removed port $port/tcp from CSF TCP_IN"
    elif [[ "$protocol" == "udp" ]]; then
        # Remove port from UDP_IN
        sed -i "s/\b,$port\b//g; s/\b$port,\b//g; s/\b$port\b//g" "$CSF_CONF"
        # Clean up any double commas
        sed -i "s/,,/,/g" "$CSF_CONF"
        log_info "Removed port $port/udp from CSF UDP_IN"
    fi
    
    # Restart CSF to apply changes
    if ! csf -r &>/dev/null; then
        log_warn "Failed to restart CSF. Changes may not be active."
        return 1
    else
        log_success "CSF restarted successfully"
    fi
}

# Check if firewalld is available and running
check_firewalld() {
    if ! command -v firewall-cmd &>/dev/null; then
        log_error "firewall-cmd not found. Please install firewalld."
        return 1
    fi
    
    if ! systemctl is-active --quiet firewalld; then
        log_warn "firewalld is not running"
        return 1
    fi
    
    return 0
}

# Enable and start firewalld
enable_firewalld() {
    check_root
    
    if ! command -v firewall-cmd &>/dev/null; then
        log_error "firewall-cmd not found. Please install firewalld first."
        return 1
    fi
    
    systemctl enable firewalld
    systemctl start firewalld
    log_success "firewalld enabled and started"
}

# Get firewalld status
get_status() {
    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active --quiet firewalld; then
            echo "firewalld: active"
            firewall-cmd --state 2>/dev/null || echo "firewalld: failed to get detailed status"
        else
            echo "firewalld: inactive"
        fi
    else
        echo "firewalld: not installed"
    fi
    
    if detect_cpanel; then
        echo "cPanel: detected"
    else
        echo "cPanel: not detected"
    fi
    
    if detect_csf; then
        echo "CSF: installed"
        if csf_is_enabled; then
            echo "CSF: enabled (production mode)"
        else
            echo "CSF: testing mode"
        fi
    else
        echo "CSF: not installed"
    fi
}

# Add port to firewall
add_port() {
    local port="$1"
    local protocol="$2"
    
    check_root
    
    # Use CSF if available and enabled
    if detect_csf && csf_is_enabled; then
        log_info "CSF detected - using CSF for port management"
        csf_add_port "$port" "$protocol"
        return $?
    fi
    
    # Fall back to firewalld
    if ! check_firewalld; then
        log_error "Neither CSF nor firewalld is available"
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --add-port="$port/$protocol" --permanent
    firewall-cmd --reload
    log_success "Added port $port/$protocol to firewalld zone $ZONE"
}

# Remove port from firewall
remove_port() {
    local port="$1"
    local protocol="$2"
    
    check_root
    
    # Use CSF if available and enabled
    if detect_csf && csf_is_enabled; then
        log_info "CSF detected - using CSF for port management"
        csf_remove_port "$port" "$protocol"
        return $?
    fi
    
    # Fall back to firewalld
    if ! check_firewalld; then
        log_error "Neither CSF nor firewalld is available"
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --remove-port="$port/$protocol" --permanent
    firewall-cmd --reload
    log_success "Removed port $port/$protocol from firewalld zone $ZONE"
}

# Add interface to zone
add_interface() {
    local interface="$1"
    
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --add-interface="$interface" --permanent
    firewall-cmd --reload
    log_success "Added interface $interface to firewalld zone $ZONE"
}

# Remove interface from zone
remove_interface() {
    local interface="$1"
    
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --remove-interface="$interface" --permanent
    firewall-cmd --reload
    log_success "Removed interface $interface from firewalld zone $ZONE"
}

# Enable masquerade
add_masquerade() {
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --add-masquerade --permanent
    firewall-cmd --reload
    log_success "Enabled masquerade in firewalld zone $ZONE"
}

# Disable masquerade
remove_masquerade() {
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --remove-masquerade --permanent
    firewall-cmd --reload
    log_success "Disabled masquerade in firewalld zone $ZONE"
}

# Add port forwarding
add_forward() {
    local from_port="$1"
    local protocol="$2"
    local to_addr="$3"
    local to_port="$4"
    
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --add-forward-port="port=$from_port:proto=$protocol:toaddr=$to_addr:toport=$to_port" --permanent
    firewall-cmd --reload
    log_success "Added port forward $from_port/$protocol -> $to_addr:$to_port in firewalld zone $ZONE"
}

# Remove port forwarding
remove_forward() {
    local from_port="$1"
    local protocol="$2"
    local to_addr="$3"
    local to_port="$4"
    
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --zone="$ZONE" --remove-forward-port="port=$from_port:proto=$protocol:toaddr=$to_addr:toport=$to_port" --permanent
    firewall-cmd --reload
    log_success "Removed port forward $from_port/$protocol -> $to_addr:$to_port from firewalld zone $ZONE"
}

# Add direct rule
direct_add() {
    local rule="$1"
    
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --direct --add-rule "$rule" --permanent
    firewall-cmd --reload
    log_success "Added direct rule: $rule"
}

# Remove direct rule
direct_remove() {
    local rule="$1"
    
    check_root
    
    if ! check_firewalld; then
        return 1
    fi
    
    firewall-cmd --direct --remove-rule "$rule" --permanent
    firewall-cmd --reload
    log_success "Removed direct rule: $rule"
}

# Display usage
usage() {
    cat << 'EOF'
LinkZero Firewall Support Script

Usage: ./scripts/firewalld-support.sh [COMMAND] [ARGUMENTS...]

Commands:
    status                                   Show firewall status and detection info
    enable                                   Enable and start firewalld
    add-port PORT PROTOCOL                   Add port to firewall (uses CSF if available)
    remove-port PORT PROTOCOL                Remove port from firewall (uses CSF if available)
    add-interface INTERFACE                  Add interface to public zone (firewalld only)
    remove-interface INTERFACE               Remove interface from public zone (firewalld only)
    add-masquerade                          Enable masquerade in public zone (firewalld only)
    remove-masquerade                       Disable masquerade in public zone (firewalld only)
    add-forward PORT PROTO ADDR PORT        Add port forwarding (firewalld only)
    remove-forward PORT PROTO ADDR PORT     Remove port forwarding (firewalld only)
    direct-add 'RULE'                       Add direct iptables rule (firewalld only)
    direct-remove 'RULE'                    Remove direct iptables rule (firewalld only)

Environment Variables:
    FIREWALLD_ZONE                          Set firewalld zone (default: public)

Examples:
    ./scripts/firewalld-support.sh status
    ./scripts/firewalld-support.sh add-port 8080 tcp
    ./scripts/firewalld-support.sh remove-port 8080 tcp
    ./scripts/firewalld-support.sh add-interface eth0
    ./scripts/firewalld-support.sh add-forward 8080 tcp 10.0.0.5 80

Notes:
    - When CSF is detected and enabled, add-port/remove-port will use CSF
    - All other operations use firewalld regardless of CSF presence
    - Root privileges are required for all firewall operations
    - CSF configuration is automatically backed up before changes

EOF
}

# Main script logic
main() {
    case "${1:-}" in
        "status")
            get_status
            ;;
        "enable")
            enable_firewalld
            ;;
        "add-port")
            if [[ $# -lt 3 ]]; then
                log_error "Usage: $0 add-port PORT PROTOCOL"
                exit 1
            fi
            add_port "$2" "$3"
            ;;
        "remove-port")
            if [[ $# -lt 3 ]]; then
                log_error "Usage: $0 remove-port PORT PROTOCOL"
                exit 1
            fi
            remove_port "$2" "$3"
            ;;
        "add-interface")
            if [[ $# -lt 2 ]]; then
                log_error "Usage: $0 add-interface INTERFACE"
                exit 1
            fi
            add_interface "$2"
            ;;
        "remove-interface")
            if [[ $# -lt 2 ]]; then
                log_error "Usage: $0 remove-interface INTERFACE"
                exit 1
            fi
            remove_interface "$2"
            ;;
        "add-masquerade")
            add_masquerade
            ;;
        "remove-masquerade")
            remove_masquerade
            ;;
        "add-forward")
            if [[ $# -lt 5 ]]; then
                log_error "Usage: $0 add-forward PORT PROTOCOL ADDR PORT"
                exit 1
            fi
            add_forward "$2" "$3" "$4" "$5"
            ;;
        "remove-forward")
            if [[ $# -lt 5 ]]; then
                log_error "Usage: $0 remove-forward PORT PROTOCOL ADDR PORT"
                exit 1
            fi
            remove_forward "$2" "$3" "$4" "$5"
            ;;
        "direct-add")
            if [[ $# -lt 2 ]]; then
                log_error "Usage: $0 direct-add 'RULE'"
                exit 1
            fi
            direct_add "$2"
            ;;
        "direct-remove")
            if [[ $# -lt 2 ]]; then
                log_error "Usage: $0 direct-remove 'RULE'"
                exit 1
            fi
            direct_remove "$2"
            ;;
        "help"|"--help"|"-h"|"")
            usage
            ;;
        *)
            log_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"