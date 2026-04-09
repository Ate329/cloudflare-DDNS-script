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
readonly CLOUDFLARE_API_BASE_URL="https://api.cloudflare.com/client/v4"
readonly DNS_RECORDS_PER_PAGE=100

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
    -l, --ttl NUMBER         Set TTL (1 or 30-86400; 30 is Enterprise-only)
    --backup                 Backup current DNS records and update DNS records
    --backup-only            Backup current DNS records without updating DNS records
    --restore FILE           Restore DNS records from backup file
    -h, --help              Show this help message
EOF
    exit 0
}

### Parse command line arguments
if ! TEMP=$(getopt -o 'hc:d:t:6:p:l:' --long 'help,config:,domains:,token:,ipv6:,proxy:,ttl:,backup,backup-only,restore:' -n "$(basename "$0")" -- "$@"); then
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

### Function to read Retry-After headers from HTTP responses
get_retry_after_seconds() {
    local headers_file=$1
    local header_line
    local header_value

    while IFS= read -r header_line || [ -n "$header_line" ]; do
        header_line=${header_line%$'\r'}
        case "$header_line" in
            [Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:*)
                header_value=${header_line#*:}
                header_value=${header_value#"${header_value%%[![:space:]]*}"}
                header_value=${header_value%"${header_value##*[![:space:]]}"}
                if [[ "$header_value" =~ ^[0-9]+$ ]]; then
                    echo "$header_value"
                    return 0
                fi
                ;;
        esac
    done < "$headers_file"

    return 1
}

### Function to perform Cloudflare API requests with retries and backoff
cloudflare_api_request() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    local attempt=0
    local max_attempts=$((max_retries + 1))
    local delay=$retry_delay
    local headers_file
    local body_file
    local body=""
    local http_code="000"
    local curl_status=0
    local retry_after=""
    local sleep_delay=0

    headers_file=$(mktemp) || {
        log "Error! Failed to create a temporary headers file"
        return 1
    }
    body_file=$(mktemp) || {
        rm -f "$headers_file"
        log "Error! Failed to create a temporary response file"
        return 1
    }

    while [ "$attempt" -lt "$max_attempts" ]; do
        : > "$headers_file"
        : > "$body_file"
        curl_status=0
        retry_after=""

        if [ -n "$data" ]; then
            http_code=$(curl -sS -D "$headers_file" -o "$body_file" -w "%{http_code}" \
                -X "$method" "${CLOUDFLARE_API_BASE_URL}${endpoint}" \
                -H "Authorization: Bearer $cloudflare_zone_api_token" \
                -H "Content-Type: application/json" \
                --data "$data") || curl_status=$?
        else
            http_code=$(curl -sS -D "$headers_file" -o "$body_file" -w "%{http_code}" \
                -X "$method" "${CLOUDFLARE_API_BASE_URL}${endpoint}" \
                -H "Authorization: Bearer $cloudflare_zone_api_token" \
                -H "Content-Type: application/json") || curl_status=$?
        fi

        body=$(<"$body_file")

        if [ "$curl_status" -eq 0 ] && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            printf '%s' "$body"
            rm -f "$headers_file" "$body_file"
            return 0
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ] || { [ "$curl_status" -eq 0 ] && [ "$http_code" != "429" ] && ! [[ "$http_code" =~ ^5[0-9][0-9]$ ]]; }; then
            break
        fi

        if retry_after=$(get_retry_after_seconds "$headers_file" 2>/dev/null); then
            sleep_delay=$retry_after
        else
            sleep_delay=$delay
        fi

        log "Warning! Cloudflare API request failed (method=$method endpoint=$endpoint status=${http_code:-curl-$curl_status}). Retrying in ${sleep_delay}s..."
        sleep "$sleep_delay"

        if [ "$delay" -lt "$max_retry_delay" ]; then
            delay=$((delay * 2))
            if [ "$delay" -gt "$max_retry_delay" ]; then
                delay=$max_retry_delay
            fi
        fi
    done

    printf '%s' "$body"
    rm -f "$headers_file" "$body_file"
    return 1
}

### Function to fetch plain text URLs with retries
fetch_text_with_retries() {
    local ip_flag=$1
    local url=$2
    local timeout=$3
    local attempt=0
    local max_attempts=$((max_retries + 1))
    local delay=$retry_delay
    local response=""

    while [ "$attempt" -lt "$max_attempts" ]; do
        if response=$(timeout "$timeout" curl "-$ip_flag" -sS --max-time "$timeout" --connect-timeout 2 "$url" 2>/dev/null); then
            printf '%s' "$response"
            return 0
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            break
        fi

        log_to_file "Warning! Failed to fetch $url. Retrying in ${delay}s..."
        sleep "$delay"

        if [ "$delay" -lt "$max_retry_delay" ]; then
            delay=$((delay * 2))
            if [ "$delay" -gt "$max_retry_delay" ]; then
                delay=$max_retry_delay
            fi
        fi
    done

    return 1
}

### Function to cleanup old log entries
cleanup_logs() {
    local days=$1
    local max_size=$((100 * 1024 * 1024))
    local file_size
    local total_lines
    local kept_lines=0
    local cutoff_date
    local temp_log
    local line

    log "==> Starting log cleanup process..."
    
    if [ "$days" -gt 0 ]; then
        cutoff_date=$(date -d "$days days ago" +%Y-%m-%d)
        log "==> Cutoff date for cleanup: $cutoff_date"

        file_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE")
        
        if [ "$file_size" -gt "$max_size" ]; then
            log "Warning! Log file exceeds 100MB. Truncating to last 10000 lines."
            tail -n 10000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
        
        total_lines=$(wc -l < "$LOG_FILE")
        temp_log=$(mktemp) || {
            log "Error! Failed to create a temporary log file"
            return 1
        }

        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]] ]] && [[ "${BASH_REMATCH[1]}" < "$cutoff_date" ]]; then
                continue
            fi

            printf '%s\n' "$line" >> "$temp_log"
            kept_lines=$((kept_lines + 1))
        done < "$LOG_FILE"

        mv "$temp_log" "$LOG_FILE"
         
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
    local backup_file
    local temp_file
    local zones_json='{}'
    local zone_records
    local success=true
    local zoneid
    declare -A seen_zones=()

    backup_file="${backup_dir}/dns_backup_$(date +%Y%m%d_%H%M%S).json"

    temp_file=$(mktemp) || { log "Error! Failed to create a temporary backup file"; return 1; }

    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir" || {
            log "Error! Failed to create DNS backups directory"
            rm -f "$temp_file"
            return 1
        }
    fi

    log "==> Starting DNS records backup..."

    IFS=';' read -ra zone_configs <<< "$domain_configs"
    for zone_config in "${zone_configs[@]}"; do
        IFS=':' read -r zoneid _ <<< "$zone_config"
        [ -n "${seen_zones[$zoneid]:-}" ] && continue
        seen_zones[$zoneid]=1

        if ! zone_records=$(fetch_zone_dns_records "$zoneid"); then
            log "Error! Failed to get DNS records for zone $zoneid"
            success=false
            continue
        fi

        zones_json=$(jq -cn --arg zoneid "$zoneid" --argjson zones "$zones_json" --argjson records "$zone_records" '$zones + {($zoneid): $records}')
    done

    if [ "$success" != true ]; then
        rm -f "$temp_file"
        log "Error! Backup failed"
        return 1
    fi

    if ! jq -cn --arg backup_date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson zones "$zones_json" '{backup_date: $backup_date, zones: $zones}' > "$temp_file"; then
        rm -f "$temp_file"
        log "Error! Failed to assemble DNS backup JSON"
        return 1
    fi

    if ! jq empty "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        log "Error! Generated DNS backup file is invalid JSON"
        return 1
    fi

    mv "$temp_file" "$backup_file"
    log "==> DNS records backed up to: $backup_file"

    if [ -n "${max_dns_backups:-}" ] && [ "$max_dns_backups" -gt 0 ]; then
        cleanup_dns_backups "$max_dns_backups"
    fi
}

### Function to restore DNS records
restore_dns_records() {
    local backup_file="$1"
    local success=true
    local zones
    local zoneid
    local records
    local live_records
    local record
    local payload
    local record_name
    local record_type
    local existing_record
    local live_payload
    local record_id
    local api_response
    local api_error
    local updated_record

    # If backup_file doesn't contain a path, look in the dns_backups directory
    if [[ "$backup_file" != *"/"* ]]; then
        backup_file="${parent_path}/dns_backups/$backup_file"
    fi

    if [ ! -f "$backup_file" ]; then
        log "Error! Backup file not found: $backup_file"
        return 1
    fi

    if ! jq empty "$backup_file" >/dev/null 2>&1; then
        log "Error! Backup file is not valid JSON: $backup_file"
        return 1
    fi

    log "==> Starting DNS records restore from: $backup_file"

    zones=$(jq -r '.zones | keys[]?' "$backup_file")
    if [ -z "$zones" ]; then
        log "Error! Backup file does not contain any zones: $backup_file"
        return 1
    fi

    for zoneid in $zones; do
        log "==> Processing zone: $zoneid"
        if ! live_records=$(fetch_zone_dns_records "$zoneid"); then
            log "Error! Failed to fetch current DNS records for zone $zoneid"
            success=false
            continue
        fi

        records=$(jq -c ".zones[\"$zoneid\"][]?" "$backup_file")

        while IFS= read -r record; do
            [ -z "$record" ] && continue

            if ! payload=$(sanitize_record_payload "$record"); then
                log "Error! Failed to sanitize backup record for zone $zoneid"
                success=false
                continue
            fi

            record_name=$(jq -r '.name // empty' <<< "$payload")
            record_type=$(jq -r '.type // empty' <<< "$payload")

            if [ -z "$record_name" ] || [ -z "$record_type" ]; then
                log "Error! Backup record is missing a name or type in zone $zoneid"
                success=false
                continue
            fi

            existing_record=$(find_restore_target_record "$live_records" "$payload")

            if [ -n "$existing_record" ]; then
                if ! live_payload=$(sanitize_record_payload "$existing_record"); then
                    log "Error! Failed to sanitize live record for $record_name ($record_type)"
                    success=false
                    continue
                fi

                if record_payloads_equal "$live_payload" "$payload"; then
                    log "==> Record already matches backup: $record_name ($record_type)"
                    continue
                fi

                record_id=$(jq -r '.id // empty' <<< "$existing_record")
                if [ -z "$record_id" ]; then
                    log "Error! Failed to determine record ID for $record_name ($record_type)"
                    success=false
                    continue
                fi

                if ! api_response=$(cloudflare_api_request PATCH "/zones/$zoneid/dns_records/$record_id" "$payload"); then
                    api_error=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
                    log "Error! Failed to update record: $record_name ($record_type): $api_error"
                    success=false
                    continue
                fi

                if ! echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
                    api_error=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
                    log "Error! Failed to update record: $record_name ($record_type): $api_error"
                    success=false
                    continue
                fi

                log "==> Updated record from backup: $record_name ($record_type)"
            else
                if ! api_response=$(cloudflare_api_request POST "/zones/$zoneid/dns_records" "$payload"); then
                    api_error=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
                    log "Error! Failed to recreate missing record: $record_name ($record_type): $api_error"
                    success=false
                    continue
                fi

                if ! echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
                    api_error=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
                    log "Error! Failed to recreate missing record: $record_name ($record_type): $api_error"
                    success=false
                    continue
                fi

                log "==> Recreated missing record from backup: $record_name ($record_type)"
            fi

            updated_record=$(echo "$api_response" | jq -c '.result' 2>/dev/null || true)
            if [ -n "$updated_record" ] && [ "$updated_record" != "null" ]; then
                live_records=$(jq -cn --argjson records "$live_records" --argjson updated "$updated_record" '($records | map(select(.id != $updated.id))) + [$updated]')
            fi

            invalidate_dns_cache "$zoneid" "$record_type"
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

### Function to invalidate cached DNS records
invalidate_dns_cache() {
    local zoneid=$1
    local type=${2:-}

    unset "dns_records_cache[${zoneid}_ALL]"
    unset "dns_records_cache_time[${zoneid}_ALL]"

    if [ -n "$type" ]; then
        unset "dns_records_cache[${zoneid}_${type}]"
        unset "dns_records_cache_time[${zoneid}_${type}]"
    fi
}

### Function to fetch DNS records from Cloudflare with pagination
fetch_zone_dns_records() {
    local zoneid=$1
    local type=${2:-}
    local cache_key="${zoneid}_${type:-ALL}"
    local response
    local endpoint
    local page=1
    local total_pages=1
    local page_records='[]'
    local all_records='[]'
    local api_error

    if response=$(get_cached_dns_records "$cache_key"); then
        log_to_file "==> Using cached DNS records for zone $zoneid type ${type:-ALL}"
        printf '%s' "$response"
        return 0
    fi

    while [ "$page" -le "$total_pages" ]; do
        endpoint="/zones/$zoneid/dns_records?per_page=${DNS_RECORDS_PER_PAGE}&page=${page}"
        if [ -n "$type" ]; then
            endpoint="${endpoint}&type=${type}"
        fi

        if ! response=$(cloudflare_api_request GET "$endpoint"); then
            api_error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
            log "Error! Can't get DNS records information from Cloudflare API for zone $zoneid: $api_error"
            return 1
        fi

        if ! echo "$response" | jq empty >/dev/null 2>&1; then
            log "Error! Invalid JSON response from Cloudflare API for zone $zoneid"
            log_to_file "Invalid response: $response"
            return 1
        fi

        if ! echo "$response" | jq -e '.success' >/dev/null 2>&1; then
            api_error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
            log "Error! Can't get DNS records information from Cloudflare API for zone $zoneid: $api_error"
            return 1
        fi

        page_records=$(echo "$response" | jq -c '.result // []')
        all_records=$(jq -cn --argjson current "$all_records" --argjson page_records "$page_records" '$current + $page_records')
        total_pages=$(echo "$response" | jq -r '.result_info.total_pages // 1')

        if ! [[ "$total_pages" =~ ^[0-9]+$ ]] || [ "$total_pages" -lt 1 ]; then
            total_pages=1
        fi

        page=$((page + 1))
    done

    set_cached_dns_records "$cache_key" "$all_records"
    log_to_file "==> Cached DNS records for zone $zoneid type ${type:-ALL}"
    printf '%s' "$all_records"
}

### Function to sanitize a backup record before create/update requests
sanitize_record_payload() {
    local record=$1

    jq -c 'del(
        .id,
        .zone_id,
        .zone_name,
        .created_on,
        .modified_on,
        .meta,
        .proxiable,
        .comment_modified_on,
        .tags_modified_on,
        .locked
    ) | with_entries(select(.value != null))' <<< "$record"
}

### Function to normalize a payload before equality checks
normalize_record_payload() {
    local record=$1

    jq -S -c 'if (.tags? | type) == "array" then .tags |= sort else . end' <<< "$record"
}

### Function to compare writable record payloads
record_payloads_equal() {
    local left=$1
    local right=$2

    [ "$(normalize_record_payload "$left")" = "$(normalize_record_payload "$right")" ]
}

### Function to find the best existing live record for a backup record
find_restore_target_record() {
    local live_records=$1
    local record=$2
    local record_name
    local record_type
    local record_content

    record_name=$(jq -r '.name // empty' <<< "$record")
    record_type=$(jq -r '.type // empty' <<< "$record")
    record_content=$(jq -r '.content // empty' <<< "$record")

    jq -c --arg name "$record_name" --arg type "$record_type" --arg content "$record_content" '
        ([ .[] | select(.name == $name and .type == $type and ((.content // "") == $content)) ] | first)
        // ([ .[] | select(.name == $name and .type == $type) ] | if length == 1 then .[0] else empty end)
    ' <<< "$live_records"
}

### Create log file
parent_path="$(dirname "${BASH_SOURCE[0]}")"
LOG_FILE="${parent_path}/cloudflare-dns-update.log"
touch "$LOG_FILE"

log "==> Script started"

### Validate config file
config_file="${config_override:-${1:-${parent_path}/cloudflare-dns-update.conf}}"
# shellcheck source=/dev/null
if ! source "$config_file"; then
    log "Error! Missing configuration file $config_file or invalid syntax!"
    exit 1
fi

# Default values for optional settings
domain_configs=${domain_configs:-""}
cloudflare_zone_api_token=${cloudflare_zone_api_token:-""}
enable_ipv6=${enable_ipv6:-"no"}
use_same_record_for_ipv6=${use_same_record_for_ipv6:-"yes"}
dns_record_ipv6=${dns_record_ipv6:-""}
ttl=${ttl:-1}
proxied=${proxied:-false}
auto_create_records=${auto_create_records:-"yes"}
max_dns_backups=${max_dns_backups:-10}
max_retries=${max_retries:-3}
retry_delay=${retry_delay:-5}
max_retry_delay=${max_retry_delay:-60}
log_cleanup_days=${log_cleanup_days:-7}
notify_telegram=${notify_telegram:-"no"}

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

if ! [[ "$ttl" =~ ^[0-9]+$ ]] || { [ "$ttl" -lt 30 ] || [ "$ttl" -gt 86400 ]; } && [ "$ttl" -ne 1 ]; then
    log "Error! ttl must be 1 or between 30 and 86400 (30 is Enterprise-only; most zones require 60+)"
    exit 1
fi

if ! [[ "$max_retries" =~ ^[0-9]+$ ]]; then
    log "Error! max_retries must be a non-negative integer"
    exit 1
fi

if ! [[ "$retry_delay" =~ ^[0-9]+$ ]]; then
    log "Error! retry_delay must be a non-negative integer"
    exit 1
fi

if ! [[ "$max_retry_delay" =~ ^[0-9]+$ ]] || [ "$max_retry_delay" -lt 1 ]; then
    log "Error! max_retry_delay must be a positive integer"
    exit 1
fi

if [ "$retry_delay" -gt "$max_retry_delay" ]; then
    log "Error! retry_delay cannot be greater than max_retry_delay"
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

if ! [[ "$max_dns_backups" =~ ^[0-9]+$ ]]; then
    log "Error! max_dns_backups must be a non-negative integer"
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
        if response=$(fetch_text_with_retries "${ip_type:3:1}" "$source" "$timeout") && [ -n "$response" ]; then
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
    local cloudflare_records_info
    local matching_records
    local matching_count=0
    local cloudflare_record_info
    local api_response
    local payload
    local current_ip
    local current_proxied
    local current_ttl
    local cloudflare_dns_record_id
    local error_message
    local update_failed=false
    local updated_any=false

    if ! cloudflare_records_info=$(fetch_zone_dns_records "$zoneid" "$type"); then
        return 1
    fi

    matching_records=$(jq -c --arg record "$record" '[ .[] | select(.name == $record) ]' <<< "$cloudflare_records_info") || {
        log "Error! Failed to parse cached DNS records for zone $zoneid"
        return 1
    }
    matching_count=$(jq -r 'length' <<< "$matching_records")

    log_to_file "Cloudflare API response for $record: $matching_records"

    if [ "$matching_count" -eq 0 ]; then
        if [ "$auto_create_records" == "no" ]; then
            log "==> DNS $type record for $record does not exist. Skipping (auto_create_records is disabled)."
            return 0
        fi
        
        log "==> DNS $type record for $record does not exist. Creating..."
        payload=$(jq -cn --arg type "$type" --arg name "$record" --arg content "$ip" --argjson ttl "$ttl" --argjson proxied "$proxied" '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')

        if ! api_response=$(cloudflare_api_request POST "/zones/$zoneid/dns_records" "$payload"); then
            error_message=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
            log "Error! Failed to create DNS record for $record ($type): $error_message"
            return 1
        fi

        if ! echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
            error_message=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
            log "Error! Failed to create DNS record for $record ($type): $error_message"
            return 1
        fi

        log "==> Success!"
        log "==> Created new DNS $type Record for $record with IP: $ip, ttl: $ttl, proxied: $proxied"

        invalidate_dns_cache "$zoneid" "$type"

        if [ "${notify_telegram:-no}" == "yes" ]; then
            send_telegram_notification "$record" "$type" "$ip" "created"
        fi
        return 0
    fi

    if [ "$matching_count" -gt 1 ]; then
        log "Warning! Found $matching_count DNS $type records for $record. Updating all matching records."
    fi

    while IFS= read -r cloudflare_record_info; do
        [ -z "$cloudflare_record_info" ] && continue

        current_ip=$(jq -r '.content // empty' <<< "$cloudflare_record_info")
        current_proxied=$(jq -r '(.proxied // false) | tostring' <<< "$cloudflare_record_info")
        current_ttl=$(jq -r '.ttl // empty' <<< "$cloudflare_record_info")
        cloudflare_dns_record_id=$(jq -r '.id // empty' <<< "$cloudflare_record_info")

        if [ -z "$current_ip" ] || [ -z "$cloudflare_dns_record_id" ]; then
            log "Error! Failed to extract current record information for $record"
            update_failed=true
            continue
        fi

        if [ "$current_ip" == "$ip" ] && [ "$current_proxied" == "$proxied" ] && [ "$current_ttl" == "$ttl" ]; then
            continue
        fi

        log "==> DNS $type record of $record is: $current_ip. Trying to update..."
        payload=$(jq -cn --arg type "$type" --arg name "$record" --arg content "$ip" --argjson ttl "$ttl" --argjson proxied "$proxied" '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')

        if ! api_response=$(cloudflare_api_request PATCH "/zones/$zoneid/dns_records/$cloudflare_dns_record_id" "$payload"); then
            error_message=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
            log "Error! Update failed for $record ($type): $error_message"
            update_failed=true
            continue
        fi

        if ! echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
            error_message=$(echo "$api_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Unknown error")
            log "Error! Update failed for $record ($type): $error_message"
            update_failed=true
            continue
        fi

        updated_any=true
        log "==> Success!"
        log "==> $record DNS $type Record updated to: $ip, ttl: $ttl, proxied: $proxied"
    done < <(jq -c '.[]' <<< "$matching_records")

    if [ "$update_failed" = true ]; then
        return 1
    fi

    if [ "$updated_any" = false ]; then
        log "==> DNS $type record of $record already matches IP $ip, ttl $ttl, proxied $proxied. No changes needed."
        return 0
    fi

    invalidate_dns_cache "$zoneid" "$type"

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
    
    # Validate zone ID format (32 hexadecimal characters)
    if ! [[ "$zoneid" =~ ^[[:xdigit:]]{32}$ ]]; then
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
