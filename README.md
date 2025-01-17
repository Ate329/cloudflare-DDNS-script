# cloudflare DDNS Script

cloudflare-DDNS-script is a Bash script that automatically updates Cloudflare DNS records with your current external IP address. It supports both IPv4 and IPv6, and can update multiple domains across different Cloudflare zones simultaneously. This script is particularly useful for any user who has a dynamic IP address and wants to keep their Cloudflare DNS records up to date without having an additional DDNS provider.

## Features

- Updates both A (IPv4) and AAAA (IPv6) records
- Supports multiple domains across different Cloudflare zones
- Configurable automatic creation of non-existent DNS records
- Uses multiple sources to reliably fetch public IP addresses
- Configurable Time To Live (TTL) and proxy settings
- Optional Telegram notifications for successful updates and record creation
- Detailed logging for easy troubleshooting (including API responses)

## Prerequisites

- Bash shell
- `curl` command-line tool
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

## Configuration

The configuration is in a file named `cloudflare-dns-update.conf` with the following content:

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

### Telegram notification settings (optional)
notify_me_telegram="no"  # Or "yes"
telegram_bot_API_Token="your_telegram_bot_token"  # If using Telegram notifications
telegram_chat_id="your_telegram_chat_id"  # If using Telegram notifications
```

Replace the placeholder values with your actual Cloudflare and Telegram (if used) credentials.

### Configuration Options

The script supports the following configuration options:

| Option | Values | Description |
|--------|--------|-------------|
| `domain_configs` | string | Semicolon-separated list of zone configurations (see Domain Configuration Format section) |
| `cloudflare_zone_api_token` | string | Your Cloudflare API token |
| `enable_ipv6` | "yes"/"no" | Whether to update AAAA (IPv6) records |
| `use_same_record_for_ipv6` | "yes"/"no" | Whether to use the same domain names for IPv6 records |
| `dns_record_ipv6` | string | Comma-separated list of IPv6 domains (only used if use_same_record_for_ipv6 is "no") |
| `ttl` | 1 or 120-7200 | Time To Live in seconds (1 for automatic) |
| `proxied` | true/false | Whether to proxy the DNS records through Cloudflare |
| `auto_create_records` | "yes"/"no" | Whether to automatically create non-existent DNS records |
| `notify_me_telegram` | "yes"/"no" | Whether to send Telegram notifications |
| `telegram_bot_API_Token` | string | Your Telegram bot API token (if notifications enabled) |
| `telegram_chat_id` | string | Your Telegram chat ID (if notifications enabled) |

### Domain Configuration Format

The `domain_configs` parameter uses the following format:
- Multiple zone configurations are separated by semicolons (;)
- Each zone configuration consists of a zone ID and its domains, separated by a colon (:)
- Multiple domains within a zone are separated by commas (,)

Example:
```bash
domain_configs="abc123:example1.com,www.example1.com;def456:example2.com,blog.example2.com"
```

This configuration will update:
- `example1.com` and `www.example1.com` using zone ID `abc123`
- `example2.com` and `blog.example2.com` using zone ID `def456`

You can find your Zone IDs in the Cloudflare dashboard under the domain's overview page.

This is where you can get your API Tokens: https://dash.cloudflare.com/profile/api-tokens   
***You should get the API Tokens by clicking the "Create Token" button instead of the API Keys.   
(API Tokens and keys are DIFFERENT)***

## Usage

Run the script manually:

```bash
./cloudflare-dns-update.sh
```

For automatic updates, you can set up a cron job. For example, to run the script every 5 minutes:

Run the command:
```bash
crontab -e
```

And add the following (it means running the config once per 5 minutes):
```bash
*/5 * * * * /path/to/cloudflare-dns-update.sh
```

### For NixOS

It's a better idea to do this declaratively in NixOS.

In your configuration.nix (the default configuration file for NixOS):
```nix
  services.cron = {
    enable = true;
    systemCronJobs = [
        
      "* * * * *   [username]   /your/path/to/cloudflare-dns-update.sh"
    ];
  };
```

Example:
```nix
  services.cron = {
    enable = true;
    systemCronJobs = [
        
      "* * * * *   guest   /home/guest/cloudflare-DDNS-script/cloudflare-dns-update.sh"
    ];
  };
```

And you might need to install cron as well:
```nix
  environment.systemPackages = [
    pkgs.cron
  ];
```

Tested on my raspberrypi 4 with NixOS installed and it was working perfectly.

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
