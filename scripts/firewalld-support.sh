#!/bin/bash
#
# LinkZero Firewall Support Helper
# Handles firewalld and cPanel/CSF integration with robust parsing
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

# Robust CSF port management with atomic updates
csf_add_port() {
    local port="$1"
    local protocol="$2"
    local csf_conf="/etc/csf/csf.conf"
    local temp_conf
    
    log_info "Adding port $port/$protocol to CSF configuration"
    
    # Create a temporary file for atomic updates
    temp_conf=$(mktemp)
    trap 'rm -f "$temp_conf"' EXIT
    
    # Copy current configuration
    cp "$csf_conf" "$temp_conf"
    
    # Determine which variable to update
    local var_name
    if [[ "$protocol" == "tcp" ]]; then
        var_name="TCP_IN"
    elif [[ "$protocol" == "udp" ]]; then
        var_name="UDP_IN"
    else
        log_error "Unsupported protocol: $protocol"
        return 1
    fi
    
    # Extract current port list
    local current_ports
    current_ports=$(grep "^${var_name} = " "$temp_conf" | sed 's/^[^=]*= *"\([^"]*\)"/\1/' || echo "")
    
    # Check if port already exists
    if [[ "$current_ports" =~ (^|,)$port($|,) ]]; then
        log_info "Port $port/$protocol already exists in CSF configuration"
        return 0
    fi
    
    # Add port to the list
    local new_ports
    if [[ -z "$current_ports" ]]; then
        new_ports="$port"
    else
        new_ports="${current_ports},${port}"
    fi
    
    # Update the configuration atomically
    sed -i "s/^${var_name} = \"[^\"]*\"/${var_name} = \"${new_ports}\"/" "$temp_conf"
    
    # Verify the change was made correctly
    if grep -q "^${var_name} = \".*${port}.*\"" "$temp_conf"; then
        # Atomic move to replace original
        mv "$temp_conf" "$csf_conf"
        log_info "Added $protocol port $port to CSF configuration"
        
        # Restart CSF to apply changes
        if command -v csf >/dev/null 2>&1; then
            if csf -r >/dev/null 2>&1; then
                log_info "CSF restarted successfully"
            else
                log_warn "CSF restart failed, manual restart may be required"
            fi
        fi
    else
        log_error "Failed to update CSF configuration"
        return 1
    fi
}

# Firewalld operations
firewalld_enable() {
    if ! is_firewalld_running; then
        log_info "Starting and enabling firewalld"
        systemctl start firewalld
        systemctl enable firewalld
    else
        log_info "Firewalld is already running"
    fi
}

firewalld_add_interface() {
    local interface="$1"
    local zone="$2"
    
    log_info "Adding interface $interface to zone $zone"
    
    # Check if interface is already in the zone
    if firewall-cmd --zone="$zone" --query-interface="$interface" >/dev/null 2>&1; then
        log_info "Interface $interface already in zone $zone"
    else
        if firewall-cmd --permanent --zone="$zone" --add-interface="$interface" >/dev/null 2>&1; then
            firewall-cmd --reload >/dev/null 2>&1
            log_info "Interface $interface added to zone $zone"
        else
            log_warn "Failed to add interface $interface to zone $zone"
        fi
    fi
}

firewalld_add_masquerade() {
    local zone="$1"
    
    log_info "Enabling masquerading for zone $zone"
    
    # Check if masquerading is already enabled
    if firewall-cmd --zone="$zone" --query-masquerade >/dev/null 2>&1; then
        log_info "Masquerading already enabled for zone $zone"
    else
        if firewall-cmd --permanent --zone="$zone" --add-masquerade >/dev/null 2>&1; then
            firewall-cmd --reload >/dev/null 2>&1
            log_info "Masquerading enabled for zone $zone"
        else
            log_warn "Failed to enable masquerading for zone $zone"
        fi
    fi
}

firewalld_add_port() {
    local port="$1"
    local protocol="$2" 
    local zone="$3"
    
    # If CSF is installed, delegate port management to CSF
    if is_csf_installed; then
        log_info "CSF detected, delegating port management to CSF"
        csf_add_port "$port" "$protocol"
    else
        log_info "Adding port $port/$protocol to firewalld zone $zone"
        
        # Check if port is already open
        if firewall-cmd --zone="$zone" --query-port="$port/$protocol" >/dev/null 2>&1; then
            log_info "Port $port/$protocol already open in zone $zone"
        else
            if firewall-cmd --permanent --zone="$zone" --add-port="$port/$protocol" >/dev/null 2>&1; then
                firewall-cmd --reload >/dev/null 2>&1
                log_info "Port $port/$protocol added to zone $zone"
            else
                log_warn "Failed to add port $port/$protocol to zone $zone"
            fi
        fi
    fi
}

# Show usage
show_usage() {
    cat << EOF
Usage: $(basename "$0") {enable|add-interface|add-masquerade|add-port}

Commands:
  enable                          - Start and enable firewalld
  add-interface <iface> <zone>    - Add interface to zone
  add-masquerade <zone>           - Enable masquerading for zone  
  add-port <port> <proto> <zone>  - Add port to zone (delegates to CSF if present)

Examples:
  $(basename "$0") enable
  $(basename "$0") add-interface eth0 public
  $(basename "$0") add-masquerade public
  $(basename "$0") add-port 51820 udp public

Notes:
  - If CSF is detected, port operations will use CSF instead of firewalld
  - All operations include safety checks to prevent duplicate configurations
  - Atomic configuration updates ensure consistency
EOF
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
    "--help"|"-h"|"help")
        show_usage
        ;;
    *)
        log_error "Invalid command: ${1:-}"
        show_usage
        exit 1
        ;;
esac