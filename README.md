# LinkZero

Disable unencrypted communication on port 25.

## About

LinkZero is a CloudLinux SMTP security script that disables unencrypted SMTP communication on port 25 for CloudLinux environments by configuring mail servers to require TLS/SSL.

## Installation

```bash
# Quick installation
curl -sSL https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash

# Or using wget
wget -O - https://raw.githubusercontent.com/astinowak-wq/LinkZero/main/install.sh | sudo bash
```

## Usage

```bash
# Show help
linkzero-smtp --help

# Preview changes (dry run)
linkzero-smtp --dry-run

# Backup configuration only
linkzero-smtp --backup-only

# Apply security configuration
linkzero-smtp
```

## Author

Author: Daniel Nowakowski

## License

See LICENSE file for details.
