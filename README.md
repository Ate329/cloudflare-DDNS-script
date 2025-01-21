# cloudflare DDNS Script

cloudflare-DDNS-script is a Bash script that automatically updates Cloudflare DNS records with your current external IP address. It supports both IPv4 and IPv6, and can update multiple domains across different Cloudflare zones simultaneously. This script is particularly useful for any user who has a dynamic IP address and wants to keep their Cloudflare DNS records up to date without having an additional DDNS provider.

## Features

- Updates both A (IPv4) and AAAA (IPv6) records
- Supports multiple domains across different Cloudflare zones
- Configurable automatic creation of non-existent DNS records
- Uses multiple sources to reliably fetch public IP addresses
- Configurable Time To Live (TTL) and proxy settings
- Backup and restore functionality for DNS records
- Optional Telegram notifications for updates
- Command-line options for configuration overrides
- Detailed logging with automatic cleanup of old entries
- Detailed logging for easy troubleshooting (including API responses)
- Robust update system with automatic backups and configuration merging
- Safe handling of local changes during updates

## Prerequisites

- Bash shell
- `git` command-line tool (for installation and updates)
- `curl` command-line tool
- `jq` command-line tool (for backup/restore functionality)
- A Cloudflare account with the domain(s) you want to update
- Cloudflare API token with the necessary permissions

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/Ate329/cloudflare-DDNS-script.git
   cd cloudflare-DDNS-script
   ```

2. Make the scripts executable:
   ```bash
   chmod +x cloudflare-dns-update.sh update.sh
   ```

3. Change the configurations in the configuration file named `cloudflare-dns-update.conf` in the same directory as the script based on your needs (see Configuration section below).

## Updating

The script includes a robust update mechanism that preserves your configuration while safely adding any new options. To update to the latest version:

1. Simply run:
   ```bash
   ./update.sh
   ```

The update script will:
- Create a timestamped backup of your current configuration, log files, and the update script itself
- Maintain a configurable history of backups (default: 10) for safety
- Check if you're in a git repository and on the main branch
- Check for any local changes and offer to stash them safely
- Verify the git repository and remote configuration
- Check if the update script itself needs updating (and if so, update it first)
- Pull the latest changes from the repository
- Intelligently merge any new configuration options while:
  - Preserving all your existing settings, comments, and file permissions
  - Adding new options in their correct sections with descriptive comments
  - Maintaining proper section order and formatting
- Restore your configuration and log files
- Restore any stashed local changes
- Verify the integrity of all updated files
- Make sure all scripts are executable

### Safety Features

The update process includes several safety measures:
- All operations are atomic (they either complete fully or not at all)
- File permissions are preserved during backup and restore
- Stashed changes are automatically restored even if the script is interrupted
- File integrity is verified at multiple steps
- Backup directory names include timestamps and process IDs to prevent conflicts
- The update script updates itself first to ensure the latest update logic is used
- Configuration merging preserves all user customizations, comments, and sections
- Automatic rollback on failure
- Handles new configuration sections and options seamlessly

### Backup System

The script maintains two types of backups in separate directories:

1. Update script backups in `./backups/`:
```
backups/
├── YYYYMMDD_HHMMSS_PID/  (most recent)
│   ├── cloudflare-dns-update.conf
│   ├── cloudflare-dns-update.log
│   └── update.sh
├── YYYYMMDD_HHMMSS_PID/  (previous)
│   └── ...
└── ...
```

2. DNS record backups in `./dns_backups/`:
```
dns_backups/
├── dns_backup_20240101_120000.json  (most recent)
├── dns_backup_20240101_115500.json
├── dns_backup_20240101_115000.json
└── ...
```

The number of backups kept in each directory is configurable through:
- `max_update_backups` setting for update script backups (default: 10)
- `max_dns_backups` setting for DNS record backups (default: 10)

Each backup type serves a different purpose:
- Update script backups preserve your configuration and scripts during updates
- DNS record backups store your DNS records for disaster recovery

### Update Troubleshooting

Common issues and solutions:

1. **Git Not Found**
   - Error: "git is not installed"
   - Solution: Install git using your system's package manager

2. **Permission Denied**
   - Error: "Permission denied" when running update.sh
   - Solution: Make sure the script is executable: `chmod +x update.sh`

3. **Local Changes Conflict**
   - Issue: You have local changes that conflict with updates
   - Solution: Either commit your changes or allow the script to stash them
   - Note: Stashed changes will be automatically restored after the update

4. **Configuration Merge Issues**
   - Issue: New configuration options or sections not appearing correctly
   - Solution: The script will automatically merge new options while preserving your settings
   - Note: Your original configuration is always backed up before any changes

5. **Update Script Modified**
   - Issue: Update script was modified during update
   - Solution: Run the update script again as prompted
   - Note: The old version is safely backed up before any changes

6. **Script Interruption**
   - Issue: Update process was interrupted
   - Solution: Run the update script again
   - Note: The script will automatically clean up and restore stashed changes

For other issues:
- Check the log file (`cloudflare-dns-update.log`) for detailed error messages
- Look in the backup directory for previous versions of your files
- The script will automatically roll back changes if any part of the update fails

## Usage

The script can be run in several ways:

1. Basic usage:
   ```bash
   ./cloudflare-dns-update.sh
   ```

2. With command-line options:
   ```bash
   ./cloudflare-dns-update.sh -c custom.conf -d "zoneid:domain.com" -6 yes
   ```

3. Backup DNS records:
   ```bash
   ./cloudflare-dns-update.sh --backup
   ```

4. Restore from backup:
   ```bash
   # Restore using relative path (will look in dns_backups directory)
   ./cloudflare-dns-update.sh --restore dns_backup_20240101_120000.json

   # Or using absolute/custom path
   ./cloudflare-dns-update.sh --restore /path/to/backup/dns_backup_20240101_120000.json
   ```

### Automatic Updates

For automatic updates, you can set up a cron job. For example, to run the script every 5 minutes:

#### In most Linux/Unix Distributions
Run the command:
```bash
crontab -e
```

And add the following:
```bash
*/5 * * * * /path/to/cloudflare-dns-update.sh
```

#### For NixOS
It's recommended to do this declaratively in NixOS.

In your configuration.nix:
```nix
services.cron = {
  enable = true;
  systemCronJobs = [
    "*/5 * * * *   [username]   /path/to/cloudflare-dns-update.sh"
  ];
};

# You might need to install cron as well
environment.systemPackages = [
  pkgs.cron
];
```

Example:
```nix
services.cron = {
  enable = true;
  systemCronJobs = [
    "*/5 * * * *   guest   /home/guest/cloudflare-DDNS-script/cloudflare-dns-update.sh"
  ];
};
```

### Command-line Options

| Option | Description |
|--------|-------------|
| `-c, --config FILE` | Use specified config file |
| `-d, --domains STRING` | Override domain configs |
| `-t, --token STRING` | Override Cloudflare API token |
| `-6, --ipv6 yes/no` | Enable/disable IPv6 support |
| `-p, --proxy true/false` | Enable/disable Cloudflare proxy |
| `-l, --ttl NUMBER` | Set TTL (1 or 120-7200) |
| `--backup` | Backup current DNS records and update DNS records |
| `--backup-only` | Backup current DNS records without updating DNS records |
| `--restore FILE` | Restore DNS records from backup file |
| `-h, --help` | Show help message |

### Backup and Restore

The script provides two types of backup operations:

1. **Backup with DNS Update (`--backup`)**:
   ```bash
   ./cloudflare-dns-update.sh --backup
   ```
   This will:
   - Update your DNS records first
   - Create a backup of your DNS records after the update
   - Store the backup in the `dns_backups` directory

2. **Backup Only (`--backup-only`)**:
   ```bash
   ./cloudflare-dns-update.sh --backup-only
   ```
   This will:
   - Only create a backup of your current DNS records
   - Skip any DNS record updates
   - Store the backup in the `dns_backups` directory

3. **Restore from Backup**:
   ```bash
   # Restore using relative path (will look in dns_backups directory)
   ./cloudflare-dns-update.sh --restore dns_backup_20240101_120000.json

   # Or using absolute/custom path
   ./cloudflare-dns-update.sh --restore /path/to/backup/dns_backup_20240101_120000.json
   ```

Backups are automatically managed:
- Old backups are cleaned up based on the `max_dns_backups` setting
- Each backup includes a timestamp for easy identification
- Backups are stored in JSON format for easy inspection and portability

## Configuration

The configuration file `cloudflare-dns-update.conf` supports the following settings:

### Domain Configurations
```bash
### Domain configurations
# Format: domain_configs="zoneid1:domain1.com,domain2.com;zoneid2:domain3.com,domain4.com"
domain_configs="your_cloudflare_zone_id1:example1.com,sub1.example1.com;your_cloudflare_zone_id2:example2.com,sub2.example2.com"
```

### Global Settings
```bash
### Global settings
cloudflare_zone_api_token="your_cloudflare_api_token"
enable_ipv6="no"  # Set to "yes" to enable IPv6 updates
use_same_record_for_ipv6="yes"  # Set to "no" to use different records for IPv6
dns_record_ipv6=""  # Only used if use_same_record_for_ipv6 is set to "no"
ttl=1  # Or any value between 120 and 7200 (1 for automatic)
proxied=false  # Or true
auto_create_records="yes"  # Set to "no" to skip creating non-existent records
max_dns_backups=10  # Number of DNS record backups to keep (default: 10)
```

### Error Handling Settings
```bash
### Error handling settings
max_retries=3  # Maximum number of retry attempts for failed API calls
retry_delay=5  # Initial delay between retries in seconds (will increase exponentially)
max_retry_delay=60  # Maximum delay between retries in seconds
```

### Log Settings
```bash
### Log settings
log_cleanup_days=7  # Number of days to keep logs (0 to disable cleanup)
```

### Update Script Settings
```bash
### Update script settings
max_update_backups=10  # Number of update backups to keep (default: 10)
```

### Telegram Notification Settings (Optional)
```bash
### Telegram notification settings (optional)
notify_telegram="no"  # Or "yes"
telegram_bot_token="your_telegram_bot_token"  # If using Telegram notifications
telegram_chat_id="your_telegram_chat_id"  # If using Telegram notifications
```

You can find your Zone IDs in the Cloudflare dashboard under the domain's overview page.

This is where you can get your API Tokens: https://dash.cloudflare.com/profile/api-tokens   
***You should get the API Tokens by clicking the "Create Token" button instead of the API Keys.***

### Configuration Tips

1. **API Token Permissions**
   - The API token needs the following permissions:
     - Zone:Read (for listing zones)
     - DNS:Edit (for managing DNS records)
   - Create a custom token with these specific permissions for better security

2. **IPv6 Configuration**
   - Enable IPv6 only if your network supports it
   - When using the same record for IPv6, the script will update both A and AAAA records
   - For different IPv6 records, specify the record name in `dns_record_ipv6`

3. **TTL Settings**
   - Use `ttl=1` for automatic TTL management by Cloudflare
   - For custom TTL, use values between 120 and 7200 seconds
   - Lower TTL values mean faster propagation but more DNS queries

4. **Proxy Settings**
   - Set `proxied=true` to enable Cloudflare's proxy features (recommended)
   - This enables DDoS protection, caching, and other Cloudflare features
   - Some services may require direct access (set to false for these)

5. **Backup Management**
   - Two types of backups are maintained in separate directories:
     - Update script backups: in `./backups/`, controlled by `max_update_backups`
     - DNS record backups: in `./dns_backups/`, controlled by `max_dns_backups`
   - DNS backups are stored in JSON format with timestamps
   - Each DNS backup includes all DNS records for configured domains
   - Backups are automatically cleaned up based on these settings
   - DNS backups can be restored using the `--restore` option
   - When restoring, you can use either the filename (looks in `dns_backups/`) or full path

6. **Log Management**
   - Set `log_cleanup_days` to control log retention
   - Set to 0 to disable automatic log cleanup
   - Logs include detailed API responses for troubleshooting

7. **Error Handling**
   - Adjust retry settings based on your network reliability
   - `max_retries` controls how many times to retry failed operations
   - Retry delay increases exponentially up to `max_retry_delay`

## Logging

The script creates a log file named `cloudflare-dns-update.log` in the same directory. This log file contains information about each run of the script, including any errors encountered.

## Contributing

Contributions are welcome! Please feel free to submit Pull Requests, Questions or Feature Requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Disclaimer

This script is provided as-is, without any warranties. Always test thoroughly before using in a production environment.

## Acknowledgments

- Thanks to Cloudflare for providing a robust API.
- Thanks to various public IP services for enabling reliable IP address retrieval.
- Thanks to ChatGPT for generating this README as well.
- Motivated by [DDNS-Cloudflare-Bash](https://github.com/fire1ce/DDNS-Cloudflare-Bash)
