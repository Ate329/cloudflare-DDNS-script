# Cloudflare DDNS Script

A robust Bash script to automatically update Cloudflare DNS records with your current public IPv4 and IPv6 addresses.

## Features

- Updates both A (IPv4) and AAAA (IPv6) records
- Supports multiple domains
- Uses multiple sources to reliably fetch public IP addresses
- Configurable Time To Live (TTL) and proxy settings
- Optional Telegram notifications for successful updates
- Detailed logging for easy troubleshooting

## Prerequisites

- Bash shell
- `curl` command-line tool
- A Cloudflare account with the domain(s) you want to update
- Cloudflare API token with the necessary permissions

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/cloudflare-DDNS-script.git
   cd cloudflare-DDNS-script
   ```

2. Make the script executable:
   ```bash
   chmod +x cloudflare-dns-update.sh
   ```

3. Create a configuration file named `cloudflare-dns-update.conf` in the same directory as the script (see Configuration section below).

## Configuration

The configuration is in a file named `cloudflare-dns-update.conf` with the following content:

```bash
zoneid="your_cloudflare_zone_id"
cloudflare_zone_api_token="your_cloudflare_api_token"
dns_record="example.com,subdomain.example.com"  # Comma-separated list of domains
ttl=1  # Or any value between 120 and 7200 (1 for automatic)
proxied=false  # Or true
notify_me_telegram="no"  # Or "yes"
telegram_bot_API_Token="your_telegram_bot_token"  # If using Telegram notifications
telegram_chat_id="your_telegram_chat_id"  # If using Telegram notifications
```

Replace the placeholder values with your actual Cloudflare and Telegram (if used) credentials.

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

And add the following:
```bash
*/5 * * * * /path/to/cloudflare-dns-update.sh
```

### For NixOS

It's a better idea to do this declaratively in NixOS:
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

And you might need to install cron:
```nix
  environment.systemPackages = [
    pkgs.cron
  ];
```

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
- Motivated by [DDNS-Cloudflare-Bash](https://github.com/fire1ce/DDNS-Cloudflare-Bash)
