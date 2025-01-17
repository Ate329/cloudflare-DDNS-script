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

## Prerequisites

- Bash shell
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

2. Make the script executable:
   ```bash
   chmod +x cloudflare-dns-update.sh
   ```

3. Change the configurations in the configuration file named `cloudflare-dns-update.conf` in the same directory as the script based on your needs (see Configuration section below).

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
   ./cloudflare-dns-update.sh --restore dns_backup_20240101_120000.json
   ```

### Automatic Updates

For automatic updates, you can set up a cron job. For example, to run the script every 5 minutes:

#### Standard Linux/Unix Systems
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
| `--backup` | Backup current DNS records |
| `--restore FILE` | Restore DNS records from backup file |
| `-h, --help` | Show help message |

## Configuration

The configuration is in a file named `cloudflare-dns-update.conf`. Replace the placeholder values with your actual Cloudflare credentials:

```bash
### Domain configurations
# Format: domain_configs="zoneid1:domain1.com,domain2.com;zoneid2:domain3.com,domain4.com"
domain_configs="your_cloudflare_zone_id1:example1.com,sub1.example1.com;your_cloudflare_zone_id2:example2.com,sub2.example2.com"

### Global settings
cloudflare_zone_api_token="your_cloudflare_api_token"
enable_ipv6="no"  # Set to "yes" to enable IPv6 updates
use_same_record_for_ipv6="yes"  # Set to "no" to use different records for IPv6
dns_record_ipv6=""  # Only used if use_same_record_for_ipv6 is set to "no"
ttl=1  # Or any value between 120 and 7200 (1 for automatic)
proxied=false  # Or true
auto_create_records="yes"  # Set to "no" to skip creating non-existent records

### Error handling settings
max_retries=3  # Maximum number of retry attempts for failed API calls
retry_delay=5  # Initial delay between retries in seconds (will increase exponentially)
max_retry_delay=60  # Maximum delay between retries in seconds

### Log settings
log_cleanup_days=7  # Number of days to keep logs (0 to disable cleanup)

### Telegram notification settings (optional)
notify_telegram="no"  # Or "yes"
telegram_bot_token="your_telegram_bot_token"  # If using Telegram notifications
telegram_chat_id="your_telegram_chat_id"  # If using Telegram notifications
```

You can find your Zone IDs in the Cloudflare dashboard under the domain's overview page.

This is where you can get your API Tokens: https://dash.cloudflare.com/profile/api-tokens   
***You should get the API Tokens by clicking the "Create Token" button instead of the API Keys.   
(API Tokens and keys are DIFFERENT)***

### Configuration Options

The script supports the following configuration options:

| Option | Values | Description |
|--------|--------|-------------|
| `domain_configs` | string | Semicolon-separated list of zone configurations |
| `cloudflare_zone_api_token` | string | Your Cloudflare API token |
| `enable_ipv6` | "yes"/"no" | Whether to update AAAA (IPv6) records |
| `use_same_record_for_ipv6` | "yes"/"no" | Whether to use the same domain names for IPv6 records |
| `dns_record_ipv6` | string | Comma-separated list of IPv6 domains |
| `ttl` | 1 or 120-7200 | Time To Live in seconds (1 for automatic) |
| `proxied` | true/false | Whether to proxy the DNS records through Cloudflare |
| `auto_create_records` | "yes"/"no" | Whether to automatically create non-existent DNS records |
| `max_retries` | integer | Maximum number of retry attempts for failed API calls |
| `retry_delay` | integer | Initial delay between retries in seconds |
| `max_retry_delay` | integer | Maximum delay between retries in seconds |
| `log_cleanup_days` | integer | Number of days to keep log entries |
| `notify_telegram` | "yes"/"no" | Whether to send Telegram notifications |
| `telegram_bot_token` | string | Your Telegram bot API token |
| `telegram_chat_id` | string | Your Telegram chat ID |

## Logging

The script creates a log file named `cloudflare-dns-update.log` in the same directory. This log file contains information about each run of the script, including any errors encountered.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Disclaimer

This script is provided as-is, without any warranties. Always test thoroughly before using in a production environment.

## Acknowledgments

- Thanks to Cloudflare for providing a robust API.
- Thanks to various public IP services for enabling reliable IP address retrieval.
- Thanks to ChatGPT for generating this README as well.
- Motivated by [DDNS-Cloudflare-Bash](https://github.com/fire1ce/DDNS-Cloudflare-Bash)
