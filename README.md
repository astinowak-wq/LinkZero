# LinkZero - SMTP Security for CloudLinux

Disable unencrypted communication on port 25 and enforce secure SMTP connections.

## Features

- **Automatic Detection**: Identifies Postfix, Exim, and Sendmail configurations
- **Smart Backup**: Creates timestamped backups before making changes
- **Dry Run Mode**: Preview changes without modification
- **Secure Enforcement**: Disables plain text authentication on port 25
- **TLS/SSL Ports**: Configures encrypted ports 587 (STARTTLS) and 465 (SSL/TLS)
- **Firewall Integration**: Automatic firewall rule management for iptables and CSF
- **CloudLinux Compatible**: Optimized for CloudLinux environments

## Quick Installation

```bash
# One-line installer (recommended)
curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash

# Alternative with wget
wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash
```

## Usage

### Basic Usage

```bash
# Apply security configuration
sudo linkzero-smtp

# Preview changes (recommended first)
sudo linkzero-smtp --dry-run

# Show all options
linkzero-smtp --help
```

### Command Line Options

```bash
linkzero-smtp [OPTIONS]

Options:
  --help          Show this help message
  --dry-run       Preview changes without applying them
  --backup-only   Create backups without modifying configurations
  --restore       Restore from backup (interactive)
  --force         Skip confirmation prompts
  --version       Show version information
```

### What It Does

1. **Backup Creation**: Automatically backs up mail server configurations
2. **Plain Auth Disable**: Disables `auth_plain` and `auth_login` on port 25
3. **Secure Ports**: Ensures ports 587 and 465 are properly configured for TLS
4. **Firewall Rules**: Updates firewall to allow secure SMTP ports
5. **Service Restart**: Safely restarts mail services with validation

## Firewall Support

| Firewall | Configuration | Status |
|----------|---------------|--------|
| iptables | Native rules | ✅ Supported |
| CSF | `/etc/csf/csf.conf` | ✅ Supported |
| firewalld | System service | ✅ Supported |

If your system uses cPanel/CSF, the installer will detect CSF and use it to open ports via `/etc/csf/csf.conf`. Firewalld is supported via `scripts/firewalld-support.sh`.

## Supported Mail Servers

| Mail Server | Configuration File | Status |
|-------------|-------------------|--------|
| Postfix | `/etc/postfix/main.cf` | ✅ Fully Supported |
| Exim | `/etc/exim/exim.conf` | ✅ Fully Supported |
| Sendmail | `/etc/sendmail.cf` | ⚠️ Backup Only |

## Installation Steps

1. **Download and Run**: Use the one-line installer above
2. **Review Changes**: Run with `--dry-run` first to see what will change
3. **Apply Configuration**: Run without options to apply changes
4. **Test Configuration**: Verify mail sending/receiving works properly
5. **Monitor Logs**: Check `/var/log/linkzero-smtp-security.log` for any issues

## Troubleshooting

### Common Issues

**Script requires root permissions:**
```bash
sudo ./disable_smtp_plain.sh
```

**Mail server not detected:**
- Ensure Postfix, Exim, or Sendmail is installed
- Check if the service is running: `systemctl status postfix`

**Configuration test fails:**
- Review the log file: `/var/log/linkzero-smtp-security.log`
- Test mail server syntax: `postfix check` or `exim -bV`

**Mail clients cannot connect:**
- Verify clients use port 587 (STARTTLS) or 465 (SSL/TLS)
- Check firewall allows these ports: `netstat -tlnp | grep -E ':(587|465)'`

### Restoration

If issues occur, restore the original configuration:
```bash
sudo ./disable_smtp_plain.sh --restore
```

## Security Considerations

- **TLS Certificates**: Ensure valid SSL/TLS certificates are installed
- **Client Configuration**: Update all mail clients to use encrypted connections  
- **Monitoring**: Regularly check logs for connection attempts and errors
- **Testing**: Verify mail flow after implementation

## Contributing

This project welcomes contributions! Please:

1. Fork the repository
2. Create a feature branch  
3. Test your changes thoroughly
4. Submit a pull request

## License

See the [LICENSE](LICENSE) file for license information.

## Support

For issues and questions:

- Review the troubleshooting section above
- Check the log file: `/var/log/linkzero-smtp-security.log`  
- Open an issue on GitHub with relevant log excerpts

---

**⚠️ Important Notice**: Always backup your configuration and test in a non-production environment first. This script modifies critical mail server settings that can affect email delivery.