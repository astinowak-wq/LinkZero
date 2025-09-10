# LinkZero - SMTP Security for CloudLinux

A comprehensive shell script solution for CloudLinux environments to disable unencrypted SMTP communication on port 25, enhancing email security by enforcing TLS/SSL encryption.

## Features

- **Multi-Mail Server Support**: Works with Postfix, Exim, and Sendmail
- **CloudLinux Optimized**: Designed specifically for CloudLinux environments
- **Automatic Backup**: Creates backups before making any changes
- **Firewall Integration**: Configures iptables and CSF (ConfigServer Security & Firewall)
- **Dry Run Mode**: Preview changes before applying them
- **Comprehensive Logging**: Detailed logging for audit and troubleshooting
- **Easy Restoration**: Simple backup restoration functionality

## Quick Installation

```bash
# Method 1: Direct download and run
curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash

# Method 2: Manual download
wget https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/disable_smtp_plain.sh
chmod +x disable_smtp_plain.sh
```

## Usage

### Basic Usage

```bash
# Preview changes (recommended first step)
sudo ./disable_smtp_plain.sh --dry-run

# Create backup only
sudo ./disable_smtp_plain.sh --backup-only

# Apply security configuration
sudo ./disable_smtp_plain.sh

# Restore from backup if needed
sudo ./disable_smtp_plain.sh --restore
```

### Command Line Options

- `--help` - Display usage information
- `--dry-run` - Preview changes without applying them
- `--backup-only` - Create configuration backup without changes
- `--restore` - Restore configuration from backup

## What It Does

### Mail Server Configuration

**Postfix:**
- Sets `smtpd_tls_security_level = encrypt`
- Enables `smtpd_tls_auth_only = yes`
- Configures strong TLS protocols and ciphers
- Disables weak encryption protocols (SSLv2, SSLv3, TLSv1, TLSv1.1)

**Exim:**
- Configures TLS enforcement for SMTP connections
- Sets up secure TLS advertising
- Requires authentication over TLS only

### Firewall Configuration

- **Blocks** unencrypted SMTP on port 25 for external connections
- **Allows** localhost connections on port 25 for local mail delivery
- **Opens** secure SMTP ports (587 for STARTTLS, 465 for SSL/TLS)
- **Integrates** with CSF (ConfigServer Security & Firewall) if present

### Security Enhancements

- Forces TLS encryption for all SMTP communications
- Implements strong cipher suites
- Disables weak encryption protocols
- Maintains local mail delivery functionality

## Requirements

- **Operating System**: CloudLinux (recommended) or CentOS/RHEL
- **Permissions**: Root access required
- **Mail Server**: Postfix, Exim, or Sendmail installed
- **Dependencies**: Standard Linux utilities (awk, sed, grep, etc.)

## File Locations

- **Script**: `/usr/local/bin/linkzero-smtp` (after installation)
- **Log File**: `/var/log/linkzero-smtp-security.log`
- **Backups**: `/var/backups/linkzero-YYYYMMDD-HHMMSS/`

## Post-Installation

After running the script successfully:

1. **Update Mail Clients**: Configure email clients to use secure ports:
   - **Port 587** (STARTTLS) - Recommended for most clients
   - **Port 465** (SSL/TLS) - For clients requiring SSL from connection start

2. **Test Configuration**: Verify mail sending/receiving works properly

3. **Monitor Logs**: Check `/var/log/linkzero-smtp-security.log` for any issues

## Supported Mail Servers

| Mail Server | Configuration File | Status |
|-------------|-------------------|---------|
| Postfix | `/etc/postfix/main.cf` | ✅ Fully Supported |
| Exim | `/etc/exim/exim.conf` | ✅ Fully Supported |
| Sendmail | `/etc/sendmail.cf` | ⚠️ Backup Only |

## Firewall Support

| Firewall | Configuration | Status |
|----------|---------------|---------|
| iptables | Native rules | ✅ Supported |
| CSF | `/etc/csf/csf.conf` | ✅ Supported |
| firewalld | System service | 🔄 Planned |

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