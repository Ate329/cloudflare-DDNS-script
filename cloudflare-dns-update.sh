#!/usr/bin/env bash

set -euo pipefail

# Check for required commands
if ! command -v curl &> /dev/null; then
    echo "Error! curl command not found. Please install curl first."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error! jq command not found. Please install jq first."
    exit 1
fi

# Enable associative array support and make it global
declare -g -A dns_records_cache=()
declare -g -A dns_records_cache_time=()
readonly DNS_CACHE_TTL=300  # 5 minutes cache TTL

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
        # Calculate the cutoff date
        local cutoff_date
        cutoff_date=$(date -d "$days days ago" +%Y-%m-%d)
        log "==> Cutoff date for cleanup: $cutoff_date"
        
        # Check file size first
        local max_size=$((100*1024*1024))  # 100MB in bytes
        local file_size
        file_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE")
        
        if [ "$file_size" -gt "$max_size" ]; then
            log "Warning! Log file exceeds 100MB. Truncating to last 10000 lines."
            tail -n 10000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
        
        # Get line count before cleanup
        local total_lines
        total_lines=$(wc -l < "$LOG_FILE")
        
        # Use sed for in-place editing with efficient date comparison
        cutoff_date_epoch=$(date -d "$days days ago" +%s)
        sed -i.tmp -E "/^([0-9]{4}-[0-9]{2}-[0-9]{2})/ {
            s//\1/
            h
            s/-//g
            /^$cutoff_date$/! { x; d; }
            x
        }" "$LOG_FILE"
        
        # Get line count after cleanup
        local kept_lines
        kept_lines=$(wc -l < "$LOG_FILE")
        
        # Remove temporary file
        rm -f "$LOG_FILE.tmp"
        
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
    backup_count=$(find "$backup_dir" -maxdepth 1 -type f -name "$backup_pattern" | wc -l)
    
    if [ "$backup_count" -gt "$max_backups" ]; then
        log "==> Cleaning up old DNS backups (keeping last $max_backups)..."
        
        # Use a more efficient single-command approach
        find "$backup_dir" -maxdepth 1 -type f -name "$backup_pattern" -printf '%T@ %p\n' | \
            sort -n | \
            head -n -"$max_backups" | \
            cut -d' ' -f2- | \
            xargs -r rm -f
            
        # Log the cleanup results
        local new_count
        new_count=$(find "$backup_dir" -maxdepth 1 -type f -name "$backup_pattern" | wc -l)
        log "==> Removed $((backup_count - new_count)) old DNS backups"
    fi
}

### Function to backup DNS records
backup_dns_records() {
    local backup_dir="${parent_path}/dns_backups"
    local backup_file="${backup_dir}/dns_backup_$(date +%Y%m%d_%H%M%S).json"
    local temp_file
    temp_file=$(mktemp) || { log "Error creating temp file"; return 1; }
    trap 'rm -f "$temp_file"' EXIT
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
        if ! curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records" \
            -H "Authorization: Bearer $cloudflare_zone_api_token" \
            -H "Content-Type: application/json" > "$temp_file"; then
            log "Error! Failed to get DNS records for zone $zoneid"
            success=false
            continue
        fi

        if ! jq -e '.success' < "$temp_file" >/dev/null; then
            log "Error! Invalid response from Cloudflare API for zone $zoneid"
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
        records=$(jq -c ".zones[\"$zoneid\"].result[]" "$backup_file")

        # Process each record
        while IFS= read -r record; do
            [ -z "$record" ] && continue

            local record_id
            local record_type
            local record_name
            local record_content
            local record_proxied
            local record_ttl

            record_id=$(jq -r '.id' <<< "$record")
            record_type=$(jq -r '.type' <<< "$record")
            record_name=$(jq -r '.name' <<< "$record")
            record_content=$(jq -r '.content' <<< "$record")
            record_proxied=$(jq -r '.proxied' <<< "$record")
            record_ttl=$(jq -r '.ttl' <<< "$record")

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

### Function to get cached DNS records
get_cached_dns_records() {
    local cache_key=$1
    local current_time
    current_time=$(date +%s)
    
    # Check if we have a valid cache entry
    if [ -n "${dns_records_cache[$cache_key]:-}" ] && \
       [ -n "${dns_records_cache_time[$cache_key]:-}" ] && \
       [ $((current_time - dns_records_cache_time[$cache_key])) -lt $DNS_CACHE_TTL ]; then
        echo "${dns_records_cache[$cache_key]}"
        return 0
    fi
    return 1
}

### Function to set cached DNS records
set_cached_dns_records() {
    local cache_key=$1
    local records=$2
    dns_records_cache[$cache_key]="$records"
    dns_records_cache_time[$cache_key]=$(date +%s)
}

### Create log file
parent_path="$(dirname "${BASH_SOURCE[0]}")"
LOG_FILE="${parent_path}/cloudflare-dns-update.log"
touch "$LOG_FILE"

log "==> Script started"

### Validate config file
config_file="${config_override:-${1:-${parent_path}/cloudflare-dns-update.json}}"
if [ ! -f "$config_file" ]; then
    log "Error! Configuration file $config_file not found!"
    exit 1
fi

# Load JSON configuration values using jq
domain_configs=$(jq -r '.domain_configs' "$config_file")
cloudflare_zone_api_token=$(jq -r '.cloudflare_zone_api_token' "$config_file")
enable_ipv6=$(jq -r '.enable_ipv6' "$config_file")
use_same_record_for_ipv6=$(jq -r '.use_same_record_for_ipv6' "$config_file")
dns_record_ipv6=$(jq -r '.dns_record_ipv6' "$config_file")
ttl=$(jq -r '.ttl' "$config_file")
proxied=$(jq -r '.proxied' "$config_file")
auto_create_records=$(jq -r '.auto_create_records' "$config_file")
max_dns_backups=$(jq -r '.max_dns_backups' "$config_file")
max_retries=$(jq -r '.max_retries' "$config_file")
retry_delay=$(jq -r '.retry_delay' "$config_file")
max_retry_delay=$(jq -r '.max_retry_delay' "$config_file")
log_cleanup_days=$(jq -r '.log_cleanup_days' "$config_file")
max_update_backups=$(jq -r '.max_update_backups' "$config_file")
notify_telegram=$(jq -r '.notify_telegram' "$config_file")
telegram_bot_token=$(jq -r '.telegram_bot_token' "$config_file")
telegram_chat_id=$(jq -r '.telegram_chat_id' "$config_file")

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
    local ip=""
    local response=""

    # Input validation
    if [ -z "$ip_type" ]; then
        log "Error! IP type not specified"
        return 1
    fi

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
            return 1
            ;;
    esac

    # Validate that we have sources to try
    if [ ${#sources[@]} -eq 0 ]; then
        log "Error! No sources defined for $ip_type"
        return 1
    fi

    log "==> Attempting to get $ip_type address from ${#sources[@]} sources (timeout: ${timeout}s)"
    
    for source in "${sources[@]}"; do
        [ -z "$source" ] && continue  # Skip empty sources
        
        log "==> Trying source: $source"
        # Use -4/-6 flag only for specific IP version
        if response=$(timeout "$timeout" curl -"${ip_type:3:1}" -s --max-time "$timeout" --connect-timeout 2 "$source" 2>/dev/null) && [ -n "$response" ]; then
            # Trim whitespace from response
            response=$(echo "$response" | tr -d '[:space:]')
            
            log "==> Got response from $source: $response"
            if [ -n "$response" ] && [[ "$response" =~ $regex ]]; then
                ip="$response"
                log "==> Valid $ip_type found from $source: $ip"
                break
            else
                log "==> Invalid $ip_type format from $source: $response"
            fi
        else
            log "==> Failed to get response from $source"
        fi
    done

    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    log "Error! Unable to retrieve $ip_type address from any source."
    return 1
}

### Get external IPs
log "==> Starting IP address detection"
ipv4=""
ipv6=""

# Get IPv4 address
if ! ipv4=$(get_external_ip "ipv4"); then
    log "Warning! Failed to get IPv4 address"
else
    if [ -n "$ipv4" ]; then
        log "==> External IPv4 is: $ipv4"
    else
        log "Warning! Empty IPv4 address received"
    fi
fi

# Get IPv6 address if enabled
if [ "$ipv6_enabled" = true ]; then
    if ! ipv6=$(get_external_ip "ipv6"); then
        log "Warning! Failed to get IPv6 address"
    else
        if [ -n "$ipv6" ]; then
            log "==> External IPv6 is: $ipv6"
        else
            log "Warning! Empty IPv6 address received"
        fi
    fi
fi

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
    local cloudflare_records_info
    local api_response
    
    # Try to get records from cache first
    cloudflare_records_info=$(get_cached_dns_records "$cache_key")
    
    # If not in cache or expired, fetch from API
    if [ $? -ne 0 ]; then
        log_to_file "==> Cache miss for zone $zoneid type $type, fetching from API"
        api_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records?type=$type" \
            -H "Authorization: Bearer $cloudflare_zone_api_token" \
            -H "Content-Type: application/json")

        if [ -z "$api_response" ]; then
            log "Error! Empty response from Cloudflare API for zone $zoneid"
            return 1
        fi

        # Check if the response is valid JSON
        if ! echo "$api_response" | jq empty 2>/dev/null; then
            log "Error! Invalid JSON response from Cloudflare API for zone $zoneid"
            log_to_file "Invalid response: $api_response"
            return 1
        fi

        cloudflare_records_info="$api_response"

        if [[ $cloudflare_records_info == *"\"success\":false"* ]]; then
            local error_message
            error_message=$(echo "$cloudflare_records_info" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
            log "Error! Can't get $type records information from Cloudflare API for zone $zoneid: $error_message"
            return 1
        fi

        # Cache the results
        set_cached_dns_records "$cache_key" "$cloudflare_records_info"
        log_to_file "==> Cached DNS records for zone $zoneid type $type"
    else
        log_to_file "==> Using cached DNS records for zone $zoneid type $type"
    fi

    local cloudflare_record_info
    cloudflare_record_info=$(echo "$cloudflare_records_info" | jq -r ".result[] | select(.name==\"$record\")" 2>/dev/null)
    
    log_to_file "Cloudflare API response for $record: $cloudflare_record_info" # Log the API response to file for debugging

    # Check if the record exists
    if [ -z "$cloudflare_record_info" ]; then
        if [ "$auto_create_records" == "no" ]; then
            log "==> DNS $type record for $record does not exist. Skipping (auto_create_records is disabled)."
            return 0
        fi
        
        log "==> DNS $type record for $record does not exist. Creating..."
        
        # Create new DNS record
        api_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records" \
            -H "Authorization: Bearer $cloudflare_zone_api_token" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$type\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}")

        if [ -z "$api_response" ]; then
            log "Error! Empty response when creating DNS record for $record ($type)"
            return 1
        fi

        if ! echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
            local error_message
            error_message=$(echo "$api_response" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
            log "Error! Failed to create DNS record for $record ($type): $error_message"
            return 1
        fi

        log "==> Success!"
        log "==> Created new DNS $type Record for $record with IP: $ip, ttl: $ttl, proxied: $proxied"

        # Invalidate cache after creating new record
        unset dns_records_cache["$cache_key"]
        unset dns_records_cache_time["$cache_key"]

        # Telegram notification
        if [ "${notify_telegram:-no}" == "yes" ]; then
            send_telegram_notification "$record" "$type" "$ip" "created"
        fi
        return 0
    fi

    # Get the current IP and proxy status
    local current_ip
    current_ip=$(echo "$cloudflare_record_info" | jq -r '.content' 2>/dev/null)
    local current_proxied
    current_proxied=$(echo "$cloudflare_record_info" | jq -r '.proxied' 2>/dev/null)

    # Check if we got valid values
    if [ -z "$current_ip" ] || [ -z "$current_proxied" ]; then
        log "Error! Failed to extract current record information for $record"
        return 1
    fi

    # Check if IP or proxy have changed
    if [ "$current_ip" == "$ip" ] && [ "$current_proxied" == "$proxied" ]; then
        log "==> DNS $type record of $record is $current_ip, no changes needed."
        return 0
    fi

    log "==> DNS $type record of $record is: $current_ip. Trying to update..."

    # Get the DNS record ID
    local cloudflare_dns_record_id
    cloudflare_dns_record_id=$(echo "$cloudflare_record_info" | jq -r '.id' 2>/dev/null)

    if [ -z "$cloudflare_dns_record_id" ]; then
        log "Error! Failed to get record ID for $record"
        return 1
    fi

    # Push new DNS record information to Cloudflare API
    api_response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$cloudflare_dns_record_id" \
        -H "Authorization: Bearer $cloudflare_zone_api_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$type\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}")

    if [ -z "$api_response" ]; then
        log "Error! Empty response when updating DNS record for $record ($type)"
        return 1
    fi

    if ! echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
        local error_message
        error_message=$(echo "$api_response" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
        log "Error! Update failed for $record ($type): $error_message"
        return 1
    fi

    log "==> Success!"
    log "==> $record DNS $type Record updated to: $ip, ttl: $ttl, proxied: $proxied"

    # Invalidate cache after update
    unset dns_records_cache["$cache_key"]
    unset dns_records_cache_time["$cache_key"]

    # Telegram notification
    if [ "${notify_telegram:-no}" == "yes" ]; then
        send_telegram_notification "$record" "$type" "$ip" "updated"
    fi
}

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
            log "Error! Skipping invalid domain: $domain"
            continue
        fi
        
        if [ -n "$ipv4" ]; then
            if ! update_dns_record "$zoneid" "$domain" "$ipv4" "A"; then
                log "Warning! Failed to update A record for $domain"
            fi
        fi
        
        if [ "$ipv6_enabled" = true ]; then
            if [ "$use_same_record_for_ipv6" == "yes" ]; then
                if [ -n "$ipv6" ]; then
                    if ! update_dns_record "$zoneid" "$domain" "$ipv6" "AAAA"; then
                        log "Warning! Failed to update AAAA record for $domain"
                    fi
                fi
            else
                log "==> Processing IPv6-specific records for $domain"
                IFS=',' read -ra dns_records_ipv6 <<< "$dns_record_ipv6"
                for record in "${dns_records_ipv6[@]}"; do
                    log "==> Processing IPv6 record: $record"
                    if [ -n "$ipv6" ]; then
                        if ! update_dns_record "$zoneid" "$record" "$ipv6" "AAAA"; then
                            log "Warning! Failed to update AAAA record for $record"
                        fi
                    fi
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
