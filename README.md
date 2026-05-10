# Cloudflare DDNS Script

`cloudflare-DDNS-script` is a Bash script that keeps Cloudflare DNS records pointed at your current public IP address. It supports IPv4 `A` records, optional IPv6 `AAAA` records, multiple zones, DNS record backups, restore, retries, logging, and optional Telegram notifications.

## Features

- Updates Cloudflare `A` records with your current public IPv4 address
- Optionally updates `AAAA` records with your current public IPv6 address
- Supports multiple domains across multiple Cloudflare zones
- Can create missing DNS records when `auto_create_records="yes"`
- Uses multiple public IP lookup services with retry/backoff handling
- Supports Cloudflare TTL and proxy settings
- Can back up and restore DNS records for configured zones
- Logs runs to `cloudflare-dns-update.log`
- Can send Telegram notifications after record creation or updates

## Requirements

- Bash
- `curl`
- `jq`
- `git` for cloning or manually updating this repository
- A Cloudflare account with the zone(s) you want to update
- A Cloudflare API token with DNS edit access for those zone(s)

## Cloudflare API Token

Create a scoped API token instead of using a global API key.

1. Open <https://dash.cloudflare.com/profile/api-tokens>.
2. Choose `Create Token`.
3. Use the `Edit zone DNS` template or create a custom token.
4. Grant these permissions:
   - `Zone:Read`
   - `DNS:Edit`
5. Restrict the token to the zone(s) this script should manage.
6. Copy the token into `cloudflare_zone_api_token` in `cloudflare-dns-update.conf`.

Your Zone ID is available in the Cloudflare dashboard on the zone overview page.

## Installation

```bash
git clone https://github.com/Ate329/cloudflare-DDNS-script.git
cd cloudflare-DDNS-script
chmod +x cloudflare-dns-update.sh
```

Edit `cloudflare-dns-update.conf` before running the script.

## Configuration

The default config file is `cloudflare-dns-update.conf` in the same directory as the script.

### Domains

```bash
domain_configs="zoneid1:example.com,sub.example.com;zoneid2:example.net"
```

Use this format:

```text
zone_id:record1,record2;another_zone_id:record3,record4
```

Each zone ID must be the 32-character Cloudflare Zone ID. Each record should be the full DNS name to update, such as `example.com` or `home.example.com`.

### Global Settings

```bash
cloudflare_zone_api_token="your_cloudflare_api_token"
enable_ipv6="no"
use_same_record_for_ipv6="yes"
dns_record_ipv6=""
ttl=1
proxied=false
auto_create_records="yes"
max_dns_backups=10
```

- `cloudflare_zone_api_token`: Cloudflare API token used for DNS operations.
- `enable_ipv6`: Set to `yes` to update `AAAA` records.
- `use_same_record_for_ipv6`: Set to `yes` to update `AAAA` records for the same names in `domain_configs`.
- `dns_record_ipv6`: Comma-separated IPv6-specific record names when `use_same_record_for_ipv6="no"`.
- `ttl`: Use `1` for Cloudflare automatic TTL, or a value from `30` to `86400`. Most zones require `60` or higher for manual TTL.
- `proxied`: Set to `true` to enable Cloudflare proxying for updated records.
- `auto_create_records`: Set to `no` to skip missing records instead of creating them.
- `max_dns_backups`: Number of DNS backup files to keep in `dns_backups/`.

### Retry And Log Settings

```bash
max_retries=3
retry_delay=5
max_retry_delay=60
log_cleanup_days=7
```

- `max_retries`: Number of retry attempts for failed IP lookups and Cloudflare API calls.
- `retry_delay`: Initial retry delay in seconds.
- `max_retry_delay`: Maximum retry delay in seconds after exponential backoff.
- `log_cleanup_days`: Number of days to keep log entries. Use `0` to disable cleanup.

### Telegram Notifications

```bash
notify_telegram="no"
telegram_bot_token="your_telegram_bot_token"
telegram_chat_id="your_telegram_chat_id"
```

Set `notify_telegram="yes"` and fill in the token and chat ID to receive notifications after DNS records are created or updated.

## Usage

Run with the default config:

```bash
./cloudflare-dns-update.sh
```

Use a custom config file:

```bash
./cloudflare-dns-update.sh --config custom.conf
```

Override domains, token, IPv6, proxy, or TTL at runtime:

```bash
./cloudflare-dns-update.sh \
  --domains "zoneid:home.example.com" \
  --token "your_cloudflare_api_token" \
  --ipv6 no \
  --proxy false \
  --ttl 1
```

Show all options:

```bash
./cloudflare-dns-update.sh --help
```

## DNS Backups

Back up DNS records without updating them:

```bash
./cloudflare-dns-update.sh --backup-only
```

Update DNS records first, then create a backup:

```bash
./cloudflare-dns-update.sh --backup
```

Restore from a backup in `dns_backups/`:

```bash
./cloudflare-dns-update.sh --restore dns_backup_20240101_120000.json
```

Restore from a specific path:

```bash
./cloudflare-dns-update.sh --restore /path/to/dns_backup_20240101_120000.json
```

Restore mode creates missing backed-up records and updates existing backed-up records when they differ. It does not delete unrelated live DNS records.

## Scheduled Runs

For a dynamic IP, run the script on a schedule.

Cron example, every 5 minutes:

```cron
*/5 * * * * /path/to/cloudflare-DDNS-script/cloudflare-dns-update.sh
```

Systemd timer example:

```ini
[Unit]
Description=Update Cloudflare DDNS records

[Service]
Type=oneshot
WorkingDirectory=/path/to/cloudflare-DDNS-script
ExecStart=/path/to/cloudflare-DDNS-script/cloudflare-dns-update.sh
```

```ini
[Unit]
Description=Run Cloudflare DDNS update every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=cloudflare-ddns.service

[Install]
WantedBy=timers.target
```

## Updating This Repository

There is no separate update script. Update the repository with Git.

If you have customized `cloudflare-dns-update.conf`, back it up first:

```bash
cp cloudflare-dns-update.conf cloudflare-dns-update.conf.backup
git pull
chmod +x cloudflare-dns-update.sh
```

After pulling, compare your config with the latest `cloudflare-dns-update.conf` and copy over any new options you want to use.

If you keep private credentials in `cloudflare-dns-update.conf`, avoid committing that file to a public fork.

## Troubleshooting

- Check `cloudflare-dns-update.log` for detailed run information.
- Run `./cloudflare-dns-update.sh --help` to confirm available options.
- Verify `curl` and `jq` are installed if the script exits immediately.
- Verify the Cloudflare token has `DNS:Edit` permission and is scoped to the correct zone.
- Verify each zone ID is the 32-character Zone ID from Cloudflare, not the domain name.
- Use `auto_create_records="no"` if you want the script to skip missing records instead of creating them.
- Use `ttl=1` if Cloudflare rejects a manual TTL value.
- Test with a dedicated hostname first, such as `ddns-test.example.com`, before managing important records.

## Security Notes

- Use a scoped Cloudflare API token, not a global API key.
- Restrict the token to only the zones this script needs to update.
- Keep `cloudflare-dns-update.conf` readable only by trusted users when it contains real credentials.
- Avoid sharing logs if they include sensitive domain or API response details.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- Cloudflare for the DNS API.
- The public IP services used by the script for address detection.
- Inspired by [DDNS-Cloudflare-Bash](https://github.com/fire1ce/DDNS-Cloudflare-Bash).
