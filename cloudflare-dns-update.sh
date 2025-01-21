#!/usr/bin/env bash

set -euo pipefail

# Check for required commands
if ! command -v curl &> /dev/null; then
    echo "Error! curl command not found. Please install curl first."
    exit 1
fi

### Function to show usage/help
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -c, --config FILE         Use specified config file
    -d, --domains STRING      Override domain configs (format: "zoneid1:domain1.com,domain2.com;zoneid2:domain3.com")
    -t, --token STRING       Override Cloudflare API token
    -6, --ipv6 yes/no        Enable/disable IPv6 support
    -p, --proxy true/false   Enable/disable Cloudflare proxy
    -l, --ttl NUMBER         Set TTL (1 or 120-7200)
    --backup                 Backup current DNS records and update DNS records
    --backup-only            Backup current DNS records without updating DNS records
    --restore FILE           Restore DNS records from backup file
    -h, --help              Show this help message
EOF
    exit 0
}

### Parse command line arguments
TEMP=$(getopt -o 'hc:d:t:6:p:l:' --long 'help,config:,domains:,token:,ipv6:,proxy:,ttl:,backup,backup-only,restore:' -n "$(basename "$0")" -- "$@")

if [ $? -ne 0 ]; then
    echo 'Terminating...' >&2
    exit 1
fi

# Note the quotes around "$TEMP": they are essential!
eval set -- "$TEMP"
unset TEMP

# Initialize variables for overrides
config_override=""
domains_override=""
token_override=""
ipv6_override=""
proxy_override=""
ttl_override=""
do_backup=false
backup_only=false
restore_file=""

while true; do
    case "$1" in
        '-h'|'--help')
            show_help
            ;;
        '-c'|'--config')
            config_override="$2"
            shift 2
            continue
            ;;
        '-d'|'--domains')
            domains_override="$2"
            shift 2
            continue
            ;;
        '-t'|'--token')
            token_override="$2"
            shift 2
            continue
            ;;
        '-6'|'--ipv6')
            ipv6_override="$2"
            shift 2
            continue
            ;;
        '-p'|'--proxy')
            proxy_override="$2"
            shift 2
            continue
            ;;
        '-l'|'--ttl')
            ttl_override="$2"
            shift 2
            continue
            ;;
        '--backup')
            do_backup=true
            shift
            continue
            ;;
        '--backup-only')
            do_backup=true
            backup_only=true
            shift
            continue
            ;;
        '--restore')
            restore_file="$2"
            shift 2
            continue
            ;;
        '--')
            shift
            break
            ;;
        *)
            echo 'Internal error!' >&2
            exit 1
            ;;
    esac
done

### Function to log messages
log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") $1" | tee -a "$LOG_FILE" >&2
}

### Function to log messages only to the log file
log_to_file() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") $1" >> "$LOG_FILE"
}

### Function to cleanup old log entries
cleanup_logs() {
    local days=$1
    log "==> Starting log cleanup process..."
    
    if [ "$days" -gt 0 ]; then
        # Calculate the cutoff date in seconds since epoch
        local cutoff_date
        cutoff_date=$(date -d "$days days ago" +%Y-%m-%d)
        log "==> Cutoff date for cleanup: $cutoff_date"
        
        # Use awk for more efficient processing
        local temp_file
        temp_file=$(mktemp)
        log "==> Created temporary file: $temp_file"
        
        # Count total lines before cleanup
        local total_lines
        total_lines=$(wc -l < "$LOG_FILE")
        log "==> Total log lines before cleanup: $total_lines"
        
        # Process the file with awk - much faster than bash loop
        awk -v cutoff="$cutoff_date" '
            function parse_date(dt) {
                # Extract YYYY-MM-DD from the timestamp
                return substr(dt, 1, 10)
            }
            {
                if (parse_date($1) >= cutoff) {
                    print $0
                }
            }' "$LOG_FILE" > "$temp_file"
        
        # Count kept lines
        local kept_lines
        kept_lines=$(wc -l < "$temp_file")
        
        # Replace the old log file with the cleaned one
        mv "$temp_file" "$LOG_FILE"
        log "==> Cleaned up log entries older than $days days (Kept $kept_lines/$total_lines lines)"
    else
        log "==> Log cleanup skipped (days = 0)"
    fi
}

### Function to cleanup old DNS backups
cleanup_dns_backups() {
    local max_backups=$1
    local backup_dir="${parent_path}/dns_backups"
    local backup_pattern="dns_backup_*.json"
    
    # Create backup directory if it doesn't exist
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir" || {
            log "Error! Failed to create DNS backups directory"
            return 1
        }
    fi
    
    # Only proceed if we have more backups than the limit
    local backup_count
    backup_count=$(find "$backup_dir" -maxdepth 1 -name "$backup_pattern" | wc -l)
    
    if [ "$backup_count" -gt "$max_backups" ]; then
        log "==> Cleaning up old DNS backups (keeping last $max_backups)..."
        find "$backup_dir" -maxdepth 1 -name "$backup_pattern" -printf "%T@ %p\n" | \
            sort -n | head -n -"$max_backups" | cut -d' ' -f2- | \
            while read -r backup; do
                rm -f "$backup"
                log_to_file "==> Removed old DNS backup: $backup"
            done
    fi
}

### Function to backup DNS records
backup_dns_records() {
    local backup_dir="${parent_path}/dns_backups"
    local backup_file="${backup_dir}/dns_backup_$(date +%Y%m%d_%H%M%S).json"
    local temp_file
    temp_file=$(mktemp)
    local success=true

    # Create backup directory if it doesn't exist
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir" || {
            log "Error! Failed to create DNS backups directory"
            rm -f "$temp_file"
            return 1
        }
    fi

    log "==> Starting DNS records backup..."
    echo "{" > "$temp_file"
    echo "  \"backup_date\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"," >> "$temp_file"
    echo "  \"zones\": {" >> "$temp_file"

    # Process each zone
    IFS=';' read -ra zone_configs <<< "$domain_configs"
    local first_zone=true
    for zone_config in "${zone_configs[@]}"; do
        # Split zone ID and domains
        IFS=':' read -r zoneid _ <<< "$zone_config"
        
        [ "$first_zone" = true ] || echo "," >> "$temp_file"
        first_zone=false
        
        # Get all DNS records for the zone
        local zone_records
        if ! zone_records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records" \
            -H "Authorization: Bearer $cloudflare_zone_api_token" \
            -H "Content-Type: application/json"); then
            log "Error! Failed to get DNS records for zone $zoneid"
            success=false
            continue
        fi

        # Add zone records to backup file
        echo "    \"$zoneid\": $zone_records" >> "$temp_file"
    done

    echo "  }" >> "$temp_file"
    echo "}" >> "$temp_file"

    if [ "$success" = true ]; then
        mv "$temp_file" "$backup_file"
        log "==> DNS records backed up to: $backup_file"
        
        # Cleanup old backups if max_dns_backups is set
        if [ -n "${max_dns_backups:-}" ] && [ "$max_dns_backups" -gt 0 ]; then
            cleanup_dns_backups "$max_dns_backups"
        fi
    else
        rm -f "$temp_file"
        log "Error! Backup failed"
        return 1
    fi
}

### Function to restore DNS records
restore_dns_records() {
    local backup_file="$1"
    local success=true

    # If backup_file doesn't contain a path, look in the dns_backups directory
    if [[ "$backup_file" != *"/"* ]]; then
        backup_file="${parent_path}/dns_backups/$backup_file"
    fi

    if [ ! -f "$backup_file" ]; then
        log "Error! Backup file not found: $backup_file"
        return 1
    fi

    log "==> Starting DNS records restore from: $backup_file"

    # Read backup file
    local zones
    zones=$(jq -r '.zones | keys[]' "$backup_file")

    for zoneid in $zones; do
        log "==> Processing zone: $zoneid"
        
        # Get records for this zone
        local records
        records=$(jq -r ".zones[\"$zoneid\"].result[]" "$backup_file")

        # Process each record
        while IFS= read -r record; do
            [ -z "$record" ] && continue

            local record_id
            local record_type
            local record_name
            local record_content
            local record_proxied
            local record_ttl

            record_id=$(echo "$record" | jq -r '.id')
            record_type=$(echo "$record" | jq -r '.type')
            record_name=$(echo "$record" | jq -r '.name')
            record_content=$(echo "$record" | jq -r '.content')
            record_proxied=$(echo "$record" | jq -r '.proxied')
            record_ttl=$(echo "$record" | jq -r '.ttl')

            # Create/Update record
            if ! curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$record_id" \
                -H "Authorization: Bearer $cloudflare_zone_api_token" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$record_content\",\"ttl\":$record_ttl,\"proxied\":$record_proxied}" | grep -q '"success":true'; then
                log "Error! Failed to restore record: $record_name ($record_type)"
                success=false
            else
                log "==> Restored record: $record_name ($record_type)"
            fi
        done <<< "$records"
    done

    if [ "$success" = true ]; then
        log "==> DNS records restored successfully"
    else
        log "Warning! Some records failed to restore"
        return 1
    fi
}

### Create log file
parent_path="$(dirname "${BASH_SOURCE[0]}")"
LOG_FILE="${parent_path}/cloudflare-dns-update.log"
touch "$LOG_FILE"

log "==> Script started"

### Validate config file
config_file="${config_override:-${1:-${parent_path}/cloudflare-dns-update.conf}}"
if ! source "$config_file"; then
    log "Error! Missing configuration file $config_file or invalid syntax!"
    exit 1
fi

# Apply command line overrides
[ -n "$domains_override" ] && domain_configs="$domains_override"
[ -n "$token_override" ] && cloudflare_zone_api_token="$token_override"
[ -n "$ipv6_override" ] && enable_ipv6="$ipv6_override"
[ -n "$proxy_override" ] && proxied="$proxy_override"
[ -n "$ttl_override" ] && ttl="$ttl_override"

### Check validity of parameters
# Validate domain configurations
if [[ -z "$domain_configs" ]] || ! [[ "$domain_configs" =~ .*:.* ]]; then
    log "Error! Invalid or empty domain_configs format. Expected format: zoneid1:domain1.com,domain2.com;zoneid2:domain3.com"
    exit 1
fi

# Validate Cloudflare API token
if [[ -z "$cloudflare_zone_api_token" ]]; then
    log "Error! Cloudflare API token is required"
    exit 1
fi

if ! [[ "$ttl" =~ ^[0-9]+$ ]] || { [ "$ttl" -lt 120 ] || [ "$ttl" -gt 7200 ]; } && [ "$ttl" -ne 1 ]; then
    log "Error! ttl must be 1 or between 120 and 7200"
    exit 1
fi

if [[ "$proxied" != "false" && "$proxied" != "true" ]]; then
    log 'Error! Incorrect "proxied" parameter, choose "true" or "false"'
    exit 1
fi

if [[ "$auto_create_records" != "yes" && "$auto_create_records" != "no" ]]; then
    log 'Error! Incorrect "auto_create_records" parameter, choose "yes" or "no"'
    exit 1
fi

if [[ "$enable_ipv6" != "yes" && "$enable_ipv6" != "no" ]]; then
    log 'Error! Incorrect "enable_ipv6" parameter, choose "yes" or "no"'
    exit 1
fi

if [[ "$enable_ipv6" == "yes" ]]; then
    if [[ "$use_same_record_for_ipv6" != "yes" && "$use_same_record_for_ipv6" != "no" ]]; then
        log 'Error! Incorrect "use_same_record_for_ipv6" parameter, choose "yes" or "no"'
        exit 1
    fi
    
    if [[ "$use_same_record_for_ipv6" == "no" ]]; then
        if [[ -z "$dns_record_ipv6" ]]; then
            log 'Error! IPv6 is enabled with different records but dns_record_ipv6 is empty'
            exit 1
        fi
        if ! [[ "$dns_record_ipv6" =~ .*\..* ]]; then
            log "Error! Invalid IPv6 DNS records format. Expected comma-separated domain names"
            exit 1
        fi
    fi
fi

if ! [[ "$log_cleanup_days" =~ ^[0-9]+$ ]]; then
    log "Error! log_cleanup_days must be a non-negative integer"
    exit 1
fi

# Validate Telegram settings if enabled
if [[ "${notify_telegram:-no}" == "yes" ]]; then
    if [[ -z "${telegram_bot_token:-}" || -z "${telegram_chat_id:-}" ]]; then
        log "Error! Telegram notifications enabled but token or chat ID is missing"
        exit 1
    fi
fi

# Clean up old log entries if enabled
log "==> Starting log cleanup with log_cleanup_days=$log_cleanup_days"
cleanup_logs "$log_cleanup_days"

# Check if IPv6 is enabled
log "==> Checking IPv6 configuration"
ipv6_enabled=$([ "$enable_ipv6" == "yes" ] && echo true || echo false)
log "==> IPv6 enabled: $ipv6_enabled"

### Valid IPv4 and IPv6 Regex
readonly IPV4_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
readonly IPV6_REGEX='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'

### Valid domain name regex (basic validation)
readonly DOMAIN_REGEX='^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

### Function to validate domain name
validate_domain() {
    local domain=$1
    if ! [[ "$domain" =~ $DOMAIN_REGEX ]]; then
        log "Error! Invalid domain name format: $domain"
        return 1
    fi
    return 0
}

### Function to get external IP (IPv4 or IPv6)
get_external_ip() {
    local ip_type=$1
    local sources=()
    local regex
    local timeout=3
    local temp_file
    temp_file=$(mktemp)

    case "$ip_type" in
        ipv4)
            sources=("https://api.ipify.org" "https://checkip.amazonaws.com" "https://ifconfig.me/ip")
            regex="$IPV4_REGEX"
            ;;
        ipv6)
            sources=("https://api64.ipify.org" "https://ifconfig.co/ip")
            regex="$IPV6_REGEX"
            ;;
        *)
            log "Error! Invalid IP type specified: $ip_type"
            rm -f "$temp_file"
            return 1
            ;;
    esac

    log "==> Attempting to get $ip_type address from ${#sources[@]} sources (timeout: ${timeout}s)"
    
    # Try all sources in parallel and use the first valid response
    local pids=()
    for source in "${sources[@]}"; do
        {
            log "==> Trying source: $source"
            if ip=$(curl -"${ip_type:3:1}" -s "$source" --max-time "$timeout"); then
                log "==> Got response from $source: $ip"
                if [[ "$ip" =~ $regex ]]; then
                    echo "$ip" > "$temp_file"
                    log "==> Valid $ip_type found from $source: $ip"
                    # Kill other running curl processes
                    for pid in "${pids[@]}"; do
                        kill -9 "$pid" 2>/dev/null || true
                    done
                else
                    log "==> Invalid $ip_type format from $source: $ip"
                fi
            else
                log "==> Failed to get response from $source"
            fi
        } &
        pids+=($!)
    done

    # Wait for all background processes to finish
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    # Check if we got a valid IP
    if [ -s "$temp_file" ]; then
        local result
        result=$(cat "$temp_file")
        rm -f "$temp_file"
        echo "$result"
        return 0
    fi

    rm -f "$temp_file"
    log "Error! Unable to retrieve $ip_type address from any source."
    return 1
}

### Get external IPs
log "==> Starting IP address detection"
ipv4=$(get_external_ip "ipv4") || ipv4=""
[ "$ipv6_enabled" = true ] && ipv6=$(get_external_ip "ipv6") || ipv6=""

[ -n "$ipv4" ] && log "==> External IPv4 is: $ipv4"
[ "$ipv6_enabled" = true ] && [ -n "$ipv6" ] && log "==> External IPv6 is: $ipv6"

### Function to extract value from JSON
json_extract() {
    local key=$1
    sed -n 's/.*"'"$key"'":"\?\([^,"]*\)"\?.*/\1/p'
}

### Function to send notification
send_notification() {
    local record=$1
    local type=$2
    local ip=$3
    local action=${4:-"updated"}

    # Telegram notification
    if [ "${notify_telegram:-no}" == "yes" ]; then
        send_telegram_notification "$record" "$type" "$ip" "$action"
    fi
}

### Function to send Telegram notification
send_telegram_notification() {
    local record=$1
    local type=$2
    local ip=$3
    local action=$4

    if ! curl -s -X POST "https://api.telegram.org/bot${telegram_bot_token}/sendMessage" \
        -H "Content-Type: application/json" \
        --data "{\"chat_id\":\"${telegram_chat_id}\",\"text\":\"${record} DNS ${type} record ${action} to: ${ip}\"}" | grep -q '"ok":true'; then
        log "Error! Telegram notification failed for $record ($type)"
    fi
}

### Function to update DNS record
update_dns_record() {
    local zoneid=$1
    local record=$2
    local ip=$3
    local type=$4
    local cache_key="${zoneid}_${type}"

    # Use cached records if available for this zone and type
    if [ -z "${dns_records_cache[$cache_key]}" ]; then
        # Get all DNS records of this type for the zone at once
        local cloudflare_records_info
        cloudflare_records_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records?type=$type" \
            -H "Authorization: Bearer $cloudflare_zone_api_token" \
            -H "Content-Type: application/json")

        if [[ $cloudflare_records_info == *"\"success\":false"* ]]; then
            log "Error! Can't get $type records information from Cloudflare API for zone $zoneid"
            return 1
        fi

        dns_records_cache[$cache_key]="$cloudflare_records_info"
    fi

    local cloudflare_record_info
    cloudflare_record_info=$(echo "${dns_records_cache[$cache_key]}" | jq -r ".result[] | select(.name==\"$record\")")
    
    log_to_file "Cloudflare API response for $record: $cloudflare_record_info" # Log the API response to file for debugging

    # Check if the record exists
    if [ -z "$cloudflare_record_info" ]; then
        if [ "$auto_create_records" == "no" ]; then
            log "==> DNS $type record for $record does not exist. Skipping (auto_create_records is disabled)."
            return 0
        fi
        
        log "==> DNS $type record for $record does not exist. Creating..."
        
        # Create new DNS record
        if ! curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records" \
            -H "Authorization: Bearer $cloudflare_zone_api_token" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$type\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}" | grep -q '"success":true'; then
            log "Error! Failed to create DNS record for $record ($type)"
            return 1
        fi

        log "==> Success!"
        log "==> Created new DNS $type Record for $record with IP: $ip, ttl: $ttl, proxied: $proxied"

        # Update cache
        dns_records_cache[$cache_key]=""  # Invalidate cache

        # Telegram notification
        if [ "${notify_telegram:-no}" == "yes" ]; then
            send_telegram_notification "$record" "$type" "$ip" "created"
        fi
        return 0
    fi

    # Get the current IP and proxy status
    local current_ip
    current_ip=$(echo "$cloudflare_record_info" | jq -r '.content')
    local current_proxied
    current_proxied=$(echo "$cloudflare_record_info" | jq -r '.proxied')

    # Check if IP or proxy have changed
    if [ "$current_ip" == "$ip" ] && [ "$current_proxied" == "$proxied" ]; then
        log "==> DNS $type record of $record is $current_ip, no changes needed."
        return 0
    fi

    log "==> DNS $type record of $record is: $current_ip. Trying to update..."

    # Get the DNS record ID
    local cloudflare_dns_record_id
    cloudflare_dns_record_id=$(echo "$cloudflare_record_info" | jq -r '.id')

    # Push new DNS record information to Cloudflare API
    if ! curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$cloudflare_dns_record_id" \
        -H "Authorization: Bearer $cloudflare_zone_api_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$type\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}" | grep -q '"success":true'; then
        log "Error! Update failed for $record ($type)"
        return 1
    fi

    log "==> Success!"
    log "==> $record DNS $type Record updated to: $ip, ttl: $ttl, proxied: $proxied"

    # Update cache
    dns_records_cache[$cache_key]=""  # Invalidate cache

    # Telegram notification
    if [ "${notify_telegram:-no}" == "yes" ]; then
        send_telegram_notification "$record" "$type" "$ip" "updated"
    fi
}

# Initialize DNS records cache
declare -A dns_records_cache

# Handle backup/restore if requested
if [ "$do_backup" = true ] || [ -n "$restore_file" ]; then
    if ! command -v jq &> /dev/null; then
        log "Error! jq command not found. Please install jq for backup/restore functionality."
        exit 1
    fi
fi

# Process restore operation if requested
if [ -n "$restore_file" ]; then
    restore_dns_records "$restore_file"
    restore_status=$?
    if [ $restore_status -eq 0 ]; then
        log "==> Script finished"
    fi
    exit $restore_status
fi

# Exit early if backup-only mode
if [ "$backup_only" = true ]; then
    backup_dns_records
    backup_status=$?
    if [ $backup_status -ne 0 ]; then
        log "Error! Backup failed"
        exit $backup_status
    fi
    log "==> Script finished (backup only)"
    exit 0
fi

# Process each zone and its domains
if [[ -z "$ipv4" ]] && [[ "$ipv6_enabled" != "yes" || -z "$ipv6" ]]; then
    log "Error! No valid IP addresses available. IPv4: ${ipv4:-none}, IPv6: ${ipv6:-none}"
    exit 1
fi

log "==> Processing zone configurations"
IFS=';' read -ra zone_configs <<< "$domain_configs"
log "==> Found ${#zone_configs[@]} zone(s) to process"

for zone_config in "${zone_configs[@]}"; do
    # Split zone ID and domains
    IFS=':' read -r zoneid domains <<< "$zone_config"
    log "==> Processing zone: $zoneid"
    
    # Validate zone ID format (32 hex characters)
    if ! [[ "$zoneid" =~ ^[0-9a-f]{32}$ ]]; then
        log "Error! Invalid zone ID format: $zoneid"
        exit 1
    fi
    
    # Process each domain for this zone
    IFS=',' read -ra domain_list <<< "$domains"
    log "==> Found ${#domain_list[@]} domain(s) in zone $zoneid"
    
    for domain in "${domain_list[@]}"; do
        log "==> Processing domain: $domain"
        # Validate domain name format
        if ! validate_domain "$domain"; then
            exit 1
        fi
        
        [ -n "$ipv4" ] && update_dns_record "$zoneid" "$domain" "$ipv4" "A"
        
        if [ "$ipv6_enabled" = true ]; then
            if [ "$use_same_record_for_ipv6" == "yes" ]; then
                [ -n "$ipv6" ] && update_dns_record "$zoneid" "$domain" "$ipv6" "AAAA"
            else
                log "==> Processing IPv6-specific records for $domain"
                IFS=',' read -ra dns_records_ipv6 <<< "$dns_record_ipv6"
                for record in "${dns_records_ipv6[@]}"; do
                    log "==> Processing IPv6 record: $record"
                    [ -n "$ipv6" ] && update_dns_record "$zoneid" "$record" "$ipv6" "AAAA"
                done
            fi
        fi
    done
done

# Perform backup if requested (after DNS updates)
if [ "$do_backup" = true ]; then
    backup_dns_records
    backup_status=$?
    if [ $backup_status -ne 0 ]; then
        log "Error! Backup failed"
        exit $backup_status
    fi
fi

log "==> Script finished"
