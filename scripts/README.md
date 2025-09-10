# LinkZero Scripts

This directory contains utility scripts for the LinkZero project.

## firewalld-support.sh

A comprehensive firewall management script that provides unified port management across different firewall systems, with intelligent detection and support for:
- **firewalld** (default Red Hat/CentOS/Fedora firewall)
- **CSF (ConfigServer Security & Firewall)** (common on cPanel/WHM hosting environments)
- **cPanel integration**

### Features

- **Intelligent Detection**: Automatically detects cPanel and CSF installations
- **Smart Port Management**: Uses CSF when available, falls back to firewalld
- **Safety First**: Backs up configurations before making changes
- **Root Required**: Enforces root privileges for all firewall operations
- **Idempotent**: Safe to run multiple times with same parameters
- **Comprehensive**: Supports all common firewall operations

### Usage

```bash
# Basic operations
./scripts/firewalld-support.sh status                    # Show firewall status
./scripts/firewalld-support.sh enable                    # Enable firewalld
./scripts/firewalld-support.sh add-port 8080 tcp         # Add port (uses CSF if available)
./scripts/firewalld-support.sh remove-port 8080 tcp      # Remove port (uses CSF if available)

# Advanced firewalld operations (always use firewalld regardless of CSF)
./scripts/firewalld-support.sh add-interface eth0        # Add interface to zone
./scripts/firewalld-support.sh remove-interface eth0     # Remove interface from zone
./scripts/firewalld-support.sh add-masquerade           # Enable IP masquerading
./scripts/firewalld-support.sh remove-masquerade        # Disable IP masquerading

# Port forwarding
./scripts/firewalld-support.sh add-forward 8080 tcp 10.0.0.5 80     # Forward port 8080 to 10.0.0.5:80
./scripts/firewalld-support.sh remove-forward 8080 tcp 10.0.0.5 80  # Remove port forwarding

# Direct iptables rules
./scripts/firewalld-support.sh direct-add 'ipv4 filter INPUT 0 -p tcp --dport 443 -j ACCEPT'
./scripts/firewalld-support.sh direct-remove 'ipv4 filter INPUT 0 -p tcp --dport 443 -j ACCEPT'
```

### Environment Variables

- `FIREWALLD_ZONE`: Set the firewalld zone (default: `public`)

```bash
# Use different zone
FIREWALLD_ZONE=dmz ./scripts/firewalld-support.sh add-port 8080 tcp
```

### CSF Integration

When CSF is detected and enabled (not in testing mode), the script will:

1. **Detect CSF**: Checks for `/etc/csf/csf.conf` and `csf` command
2. **Check Status**: Verifies CSF is not in testing mode (`TESTING = "0"`)
3. **Backup Configuration**: Creates timestamped backup in `/var/backups/linkzero-csf/`
4. **Modify Configuration**: Adds/removes ports from `TCP_IN` or `UDP_IN` sections
5. **Restart CSF**: Runs `csf -r` to apply changes
6. **Handle Errors**: Provides clear feedback on success/failure

#### CSF Port Management

The script modifies CSF configuration as follows:

- **TCP ports**: Added to/removed from `TCP_IN` setting
- **UDP ports**: Added to/removed from `UDP_IN` setting
- **Duplicates**: Automatically handled - won't add existing ports
- **Cleanup**: Removes empty comma entries and formatting issues
- **Backup**: Always creates backup before making changes

### Detection Logic

The script provides comprehensive environment detection:

```bash
./scripts/firewalld-support.sh status
```

Output example:
```
firewalld: active
cPanel: detected
CSF: installed
CSF: enabled (production mode)
```

#### cPanel Detection

Checks for these cPanel indicators:
- `/usr/local/cpanel/cpanel` (main cPanel binary)
- `/usr/local/cpanel/` directory
- `/etc/wwwacct.conf` (cPanel configuration)

#### CSF Detection  

Checks for these CSF indicators:
- `/etc/csf/csf.conf` exists and is readable
- `csf` command is available and executable
- `TESTING = "0"` for production mode (vs testing mode)

### Error Handling

The script includes robust error handling:

- **Root Check**: All firewall operations require root privileges
- **Service Check**: Verifies firewalld is running before operations
- **CSF Restart**: Handles CSF restart failures gracefully
- **Input Validation**: Validates all command arguments
- **Backup Failure**: Continues operation even if backup fails (with warning)

### Security Considerations

- **Root Required**: All firewall modifications require root privileges
- **Configuration Backup**: Always backs up CSF config before changes
- **Idempotent**: Safe to run multiple times
- **Error Recovery**: CSF restart failures are logged but don't break the system
- **Input Validation**: All inputs are validated before use

### Compatibility

- **CentOS/RHEL 7+**: Full support
- **Ubuntu/Debian**: firewalld support (CSF also compatible)
- **cPanel/WHM**: Full CSF integration
- **CloudLinux**: Full CSF integration (common hosting environment)

### Examples

#### Basic Port Management

```bash
# Add web server ports
sudo ./scripts/firewalld-support.sh add-port 80 tcp
sudo ./scripts/firewalld-support.sh add-port 443 tcp

# Add custom application port
sudo ./scripts/firewalld-support.sh add-port 8080 tcp

# Remove port when no longer needed
sudo ./scripts/firewalld-support.sh remove-port 8080 tcp
```

#### cPanel/CSF Environment

```bash
# In cPanel environment with CSF, these will use CSF automatically
sudo ./scripts/firewalld-support.sh add-port 25 tcp     # SMTP
sudo ./scripts/firewalld-support.sh add-port 587 tcp    # SMTP submission
sudo ./scripts/firewalld-support.sh add-port 993 tcp    # IMAPS
```

#### Mixed Environment Management

```bash
# Port operations use CSF when available
sudo ./scripts/firewalld-support.sh add-port 3306 tcp

# Other operations always use firewalld
sudo ./scripts/firewalld-support.sh add-interface eth1
sudo ./scripts/firewalld-support.sh add-masquerade
```

### Troubleshooting

1. **Permission Denied**: Ensure running as root
2. **CSF Not Restarting**: Check CSF service status and logs
3. **firewalld Not Found**: Install firewalld package
4. **Backup Directory Issues**: Ensure `/var/backups/` is writable

### Testing

The script includes comprehensive error checking and can be tested safely:

```bash
# Check status without modifications
./scripts/firewalld-support.sh status

# Validate arguments without running as root
./scripts/firewalld-support.sh add-port 8080 tcp  # Shows root requirement error

# Test help system
./scripts/firewalld-support.sh --help
```