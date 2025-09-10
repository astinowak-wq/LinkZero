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
#   ./scripts/firewalld-support.sh direct-add 'ACCEPT -p tcp --dport 22 -j ACCEPT'   # direct iptables rule
#   ./scripts/firewalld-support.sh direct-remove 'ACCEPT -p tcp --dport 22 -j ACCEPT'
#   ./scripts/firewalld-support.sh reload                 # reload firewalld configuration
#
# Requires root access for all operations except status.
#

set -euo pipefail

# Default zone for operations
DEFAULT_ZONE="public"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
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

# Check if firewalld is available
check_firewalld() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        log_error "firewall-cmd not found. Please install firewalld package."
        exit 1
    fi
}

# Check if running as root (for operations that require it)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This operation requires root privileges. Please run with sudo."
        exit 1
    fi
}

# Show firewalld status
show_status() {
    check_firewalld
    
    echo "=== FirewallD Status ==="
    if systemctl is-active --quiet firewalld; then
        log_info "firewalld is running"
        echo "Default zone: $(firewall-cmd --get-default-zone 2>/dev/null || echo 'unknown')"
        echo "Active zones:"
        firewall-cmd --get-active-zones 2>/dev/null || log_warn "Could not get active zones"
    else
        log_warn "firewalld is not running"
    fi
    
    if systemctl is-enabled --quiet firewalld; then
        log_info "firewalld is enabled at boot"
    else
        log_warn "firewalld is not enabled at boot"
    fi
}

# Enable and start firewalld
enable_firewalld() {
    check_firewalld
    check_root
    
    log_info "Enabling and starting firewalld..."
    systemctl enable firewalld
    systemctl start firewalld
    
    # Set default zone to public if not set
    local current_zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "")
    if [[ -z "$current_zone" ]]; then
        firewall-cmd --set-default-zone="$DEFAULT_ZONE"
        log_info "Set default zone to $DEFAULT_ZONE"
    fi
    
    log_info "firewalld enabled and started successfully"
}

# Add port to zone
add_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local zone="${3:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Adding port $port/$protocol to zone $zone"
    if firewall-cmd --permanent --zone="$zone" --add-port="$port/$protocol"; then
        log_info "Port $port/$protocol added successfully"
    else
        log_warn "Port $port/$protocol may already exist or failed to add"
    fi
}

# Remove port from zone
remove_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local zone="${3:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Removing port $port/$protocol from zone $zone"
    if firewall-cmd --permanent --zone="$zone" --remove-port="$port/$protocol"; then
        log_info "Port $port/$protocol removed successfully"
    else
        log_warn "Port $port/$protocol may not exist or failed to remove"
    fi
}

# Add interface to zone
add_interface() {
    local interface="$1"
    local zone="${2:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Adding interface $interface to zone $zone"
    if firewall-cmd --permanent --zone="$zone" --add-interface="$interface"; then
        log_info "Interface $interface added to zone $zone successfully"
    else
        log_warn "Interface $interface may already exist or failed to add"
    fi
}

# Remove interface from zone
remove_interface() {
    local interface="$1"
    local zone="${2:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Removing interface $interface from zone $zone"
    if firewall-cmd --permanent --zone="$zone" --remove-interface="$interface"; then
        log_info "Interface $interface removed from zone $zone successfully"
    else
        log_warn "Interface $interface may not exist or failed to remove"
    fi
}

# Enable masquerade
add_masquerade() {
    local zone="${1:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Enabling masquerade in zone $zone"
    if firewall-cmd --permanent --zone="$zone" --add-masquerade; then
        log_info "Masquerade enabled successfully"
        
        # Enable IP forwarding
        if sysctl -w net.ipv4.ip_forward=1; then
            log_info "IP forwarding enabled"
            # Make it persistent
            echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-linkzero-forwarding.conf
            log_info "IP forwarding configured to persist across reboots"
        else
            log_warn "Failed to enable IP forwarding"
        fi
    else
        log_warn "Masquerade may already be enabled or failed to add"
    fi
}

# Disable masquerade
remove_masquerade() {
    local zone="${1:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Disabling masquerade in zone $zone"
    if firewall-cmd --permanent --zone="$zone" --remove-masquerade; then
        log_info "Masquerade disabled successfully"
    else
        log_warn "Masquerade may not be enabled or failed to remove"
    fi
}

# Add port forwarding
add_forward() {
    local local_port="$1"
    local protocol="$2"
    local dest_addr="$3"
    local dest_port="$4"
    local zone="${5:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Adding port forward: $local_port/$protocol -> $dest_addr:$dest_port in zone $zone"
    if firewall-cmd --permanent --zone="$zone" --add-forward-port="port=$local_port:proto=$protocol:toaddr=$dest_addr:toport=$dest_port"; then
        log_info "Port forwarding added successfully"
    else
        log_warn "Port forwarding may already exist or failed to add"
    fi
}

# Remove port forwarding
remove_forward() {
    local local_port="$1"
    local protocol="$2"
    local dest_addr="$3"
    local dest_port="$4"
    local zone="${5:-$DEFAULT_ZONE}"
    
    check_firewalld
    check_root
    
    log_info "Removing port forward: $local_port/$protocol -> $dest_addr:$dest_port in zone $zone"
    if firewall-cmd --permanent --zone="$zone" --remove-forward-port="port=$local_port:proto=$protocol:toaddr=$dest_addr:toport=$dest_port"; then
        log_info "Port forwarding removed successfully"
    else
        log_warn "Port forwarding may not exist or failed to remove"
    fi
}

# Add direct iptables rule
direct_add() {
    local rule="$1"
    
    check_firewalld
    check_root
    
    log_info "Adding direct iptables rule: $rule"
    if firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 $rule; then
        log_info "Direct rule added successfully"
    else
        log_warn "Direct rule may already exist or failed to add"
    fi
}

# Remove direct iptables rule
direct_remove() {
    local rule="$1"
    
    check_firewalld
    check_root
    
    log_info "Removing direct iptables rule: $rule"
    if firewall-cmd --permanent --direct --remove-rule ipv4 filter INPUT 0 $rule; then
        log_info "Direct rule removed successfully"
    else
        log_warn "Direct rule may not exist or failed to remove"
    fi
}

# Reload firewalld configuration
reload_firewalld() {
    check_firewalld
    check_root
    
    log_info "Reloading firewalld configuration..."
    if firewall-cmd --reload; then
        log_info "firewalld configuration reloaded successfully"
    else
        log_error "Failed to reload firewalld configuration"
        exit 1
    fi
}

# Show usage information
show_usage() {
    echo "Usage: $0 <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  status                                   Show firewalld status"
    echo "  enable                                   Enable and start firewalld"
    echo "  add-port <port> [protocol] [zone]        Add port (default: tcp, public)"
    echo "  remove-port <port> [protocol] [zone]     Remove port (default: tcp, public)"
    echo "  add-interface <interface> [zone]         Add interface to zone (default: public)"
    echo "  remove-interface <interface> [zone]      Remove interface from zone (default: public)"
    echo "  add-masquerade [zone]                    Enable masquerade (default: public)"
    echo "  remove-masquerade [zone]                 Disable masquerade (default: public)"
    echo "  add-forward <port> <proto> <addr> <port> [zone]  Add port forwarding"
    echo "  remove-forward <port> <proto> <addr> <port> [zone]  Remove port forwarding"
    echo "  direct-add '<rule>'                      Add direct iptables rule"
    echo "  direct-remove '<rule>'                   Remove direct iptables rule"
    echo "  reload                                   Reload firewalld configuration"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 enable"
    echo "  $0 add-port 51820 udp"
    echo "  $0 add-interface eth0"
    echo "  $0 add-masquerade"
    echo "  $0 direct-add '-p tcp --dport 22 -j ACCEPT'"
    echo "  $0 reload"
}

# Main script logic
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        "status")
            show_status
            ;;
        "enable")
            enable_firewalld
            ;;
        "add-port")
            if [[ $# -lt 1 ]]; then
                log_error "add-port requires at least a port number"
                exit 1
            fi
            add_port "$@"
            ;;
        "remove-port")
            if [[ $# -lt 1 ]]; then
                log_error "remove-port requires at least a port number"
                exit 1
            fi
            remove_port "$@"
            ;;
        "add-interface")
            if [[ $# -lt 1 ]]; then
                log_error "add-interface requires an interface name"
                exit 1
            fi
            add_interface "$@"
            ;;
        "remove-interface")
            if [[ $# -lt 1 ]]; then
                log_error "remove-interface requires an interface name"
                exit 1
            fi
            remove_interface "$@"
            ;;
        "add-masquerade")
            add_masquerade "$@"
            ;;
        "remove-masquerade")
            remove_masquerade "$@"
            ;;
        "add-forward")
            if [[ $# -lt 4 ]]; then
                log_error "add-forward requires: <port> <protocol> <dest_addr> <dest_port>"
                exit 1
            fi
            add_forward "$@"
            ;;
        "remove-forward")
            if [[ $# -lt 4 ]]; then
                log_error "remove-forward requires: <port> <protocol> <dest_addr> <dest_port>"
                exit 1
            fi
            remove_forward "$@"
            ;;
        "direct-add")
            if [[ $# -lt 1 ]]; then
                log_error "direct-add requires an iptables rule"
                exit 1
            fi
            direct_add "$@"
            ;;
        "direct-remove")
            if [[ $# -lt 1 ]]; then
                log_error "direct-remove requires an iptables rule"
                exit 1
            fi
            direct_remove "$@"
            ;;
        "reload")
            reload_firewalld
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run the main function with all arguments
main "$@"