#!/usr/bin/env bash

set -euo pipefail

### Function to log messages
log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") $1" | tee -a "$LOG_FILE"
}

### Create cloudflare-dns-update.log file of the last run for debug
parent_path="$(dirname "${BASH_SOURCE[0]}")"
LOG_FILE="${parent_path}/cloudflare-dns-update.log"
touch "$LOG_FILE"

log "==> Script started"

### Validate if config-file exists
config_file="${1:-${parent_path}/cloudflare-dns-update.conf}"
if ! source "$config_file"; then
    log "Error! Missing configuration file $config_file or invalid syntax!"
    exit 1
fi

### Check validity of parameters
if ! [[ "$ttl" =~ ^[0-9]+$ ]] || { [ "$ttl" -lt 120 ] || [ "$ttl" -gt 7200 ]; } && [ "$ttl" -ne 1 ]; then
    log "Error! ttl must be 1 or between 120 and 7200"
    exit 1
fi

if [[ "$proxied" != "false" && "$proxied" != "true" ]]; then
    log 'Error! Incorrect "proxied" parameter, choose "true" or "false"'
    exit 1
fi

### Valid IPv4 and IPv6 Regex
IPV4_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
IPV6_REGEX='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'

### Function to get external IP (IPv4 or IPv6)
get_external_ip() {
    local ip_type=$1
    local sources=()

    case "$ip_type" in
        ipv4)
            sources=("https://api.ipify.org" "https://checkip.amazonaws.com" "https://ifconfig.me/ip")
            ;;
        ipv6)
            sources=("https://api64.ipify.org" "https://ifconfig.co/ip")
            ;;
        *)
            log "Error! Invalid IP type specified"
            return 1
            ;;
    esac

    for source in "${sources[@]}"; do
        local ip
        if ip=$(curl -"${ip_type:3:1}" -s "$source" --max-time 10); then
            if [[ "$ip" =~ ${!ip_type^}_REGEX ]]; then
                echo "$ip"
                return 0
            fi
        fi
    done

    log "Error! Unable to retrieve $ip_type address from any source."
    return 1
}

### Get external IPs
ipv4=$(get_external_ip "ipv4") || true
ipv6=$(get_external_ip "ipv6") || true

[ -n "$ipv4" ] && log "==> External IPv4 is: $ipv4"
[ -n "$ipv6" ] && log "==> External IPv6 is: $ipv6"

### Function to extract value from JSON
json_extract() {
    local key=$1
    sed -n 's/.*"'"$key"'":"\?\([^,"]*\)"\?.*/\1/p'
}

### Function to update DNS record
update_dns_record() {
    local record=$1
    local ip=$2
    local type=$3

    # Get the DNS record information from Cloudflare API
    local cloudflare_record_info
    cloudflare_record_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records?type=$type&name=$record" \
        -H "Authorization: Bearer $cloudflare_zone_api_token" \
        -H "Content-Type: application/json")

    if [[ $cloudflare_record_info == *"\"success\":false"* ]]; then
        log "Error! Can't get $record ($type) record information from Cloudflare API"
        return 1
    fi

    # Get the current IP and proxy status from the API response
    local current_ip
    current_ip=$(echo "$cloudflare_record_info" | json_extract "content")
    local current_proxied
    current_proxied=$(echo "$cloudflare_record_info" | json_extract "proxied")

    # Check if IP or proxy have changed
    if [ "$current_ip" == "$ip" ] && [ "$current_proxied" == "$proxied" ]; then
        log "==> DNS $type record of $record is $current_ip, no changes needed."
        return 0
    fi

    log "==> DNS $type record of $record is: $current_ip. Trying to update..."

    # Get the DNS record ID from response
    local cloudflare_dns_record_id
    cloudflare_dns_record_id=$(echo "$cloudflare_record_info" | json_extract "id")

    # Push new DNS record information to Cloudflare API
    local update_dns_record
    update_dns_record=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$cloudflare_dns_record_id" \
        -H "Authorization: Bearer $cloudflare_zone_api_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$type\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}")

    if [[ $update_dns_record == *"\"success\":false"* ]]; then
        log "Error! Update failed for $record ($type)"
        return 1
    fi

    log "==> Success!"
    log "==> $record DNS $type Record updated to: $ip, ttl: $ttl, proxied: $proxied"

    # Telegram notification
    if [ "${notify_me_telegram}" == "yes" ]; then
        local telegram_notification
        telegram_notification=$(
            curl -s -X POST "https://api.telegram.org/bot${telegram_bot_API_Token}/sendMessage" \
                -H "Content-Type: application/json" \
                --data "{\"chat_id\":\"${telegram_chat_id}\",\"text\":\"${record} DNS ${type} record updated to: ${ip}\"}"
        )
        if [[ $telegram_notification != *"\"ok\":true"* ]]; then
            log "Error! Telegram notification failed for $record ($type)"
        fi
    fi
}

# Update DNS records
IFS=',' read -ra dns_records <<< "$dns_record"
for record in "${dns_records[@]}"; do
    [ -n "$ipv4" ] && update_dns_record "$record" "$ipv4" "A"
    [ -n "$ipv6" ] && update_dns_record "$record" "$ipv6" "AAAA"
done

log "==> Script finished"