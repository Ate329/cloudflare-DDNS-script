#!/usr/bin/env bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script must be run with bash."
    exit 1
fi

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log helper functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if git is installed
if ! command -v git &> /dev/null; then
    log_error "git is not installed. Please install git first."
    exit 1
fi

# Save current directory and script path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${BASH_SOURCE[0]}"
cd "$SCRIPT_DIR"

# Create temporary directory for script update
TEMP_UPDATE_DIR=$(mktemp -d) || {
    log_error "Failed to create temporary directory for update"
    exit 1
}

# Cleanup temporary files on exit
cleanup_temp() {
    set +e
    [ -d "$TEMP_UPDATE_DIR" ] && rm -rf "$TEMP_UPDATE_DIR"
}
trap cleanup_temp EXIT

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    log_error "Not in a git repository. Please run this script from the project directory."
    exit 1
fi

# Verify remote exists
if ! git remote get-url origin >/dev/null 2>&1; then
    log_error "No 'origin' remote found. Please ensure the repository is properly configured."
    exit 1
fi

# Fetch updates once at the beginning
log_info "Checking for updates..."
if ! git fetch origin main; then
    log_error "Failed to fetch updates. Please check your internet connection."
    exit 1
fi

# Check if update.sh needs updating (do this before any other operations)
if git diff --name-only HEAD..origin/main | grep -q "^update.sh$"; then
    log_info "Update script needs updating. Updating it first..."
    
    # Get the new version in a temporary location first
    if ! git show origin/main:update.sh > "$TEMP_UPDATE_DIR/update.sh"; then
        log_error "Failed to get new update script"
        exit 1
    fi
    
    # Verify the new script
    if ! bash -n "$TEMP_UPDATE_DIR/update.sh"; then
        log_error "New update script contains syntax errors"
        exit 1
    fi
    
    # Make the new script executable
    chmod +x "$TEMP_UPDATE_DIR/update.sh"
    
    # Replace the old script with the new one atomically
    if ! mv "$TEMP_UPDATE_DIR/update.sh" "$SCRIPT_PATH"; then
        log_error "Failed to replace update script"
        exit 1
    fi
    
    # Stage the updated update.sh file
    git add update.sh
    
    log_info "Update script has been updated. Proceeding with remaining updates..."
    
    # Prevent infinite recursion by checking an environment variable
    if [ -z "${REEXECED:-}" ]; then
        export REEXECED=1
        exec bash "$SCRIPT_PATH"
    fi
fi

# Temporary files cleanup
declare -a TEMP_FILES=()
cleanup_temp_files() {
    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        for file in "${TEMP_FILES[@]}"; do
            [ -f "$file" ] && rm -f "$file"
        done
    fi
}

# Create backup directory with timestamp and pid for uniqueness
if [ ! -d "${SCRIPT_DIR}/backups" ]; then
    mkdir -p "${SCRIPT_DIR}/backups" || {
        log_error "Failed to create backups directory"
        exit 1
    }
fi

BACKUP_DIR=$(mktemp -d "${SCRIPT_DIR}/backups/$(date +%Y%m%d_%H%M%S)_XXXXXX") || {
    log_error "Failed to create backup directory"
    exit 1
}

# Global variable to track if we've already stashed changes
CHANGES_STASHED=0

# Function to handle stashing
handle_local_changes() {
    # Only stash if we haven't already
    if [ "$CHANGES_STASHED" -eq 0 ] && { ! git diff --quiet || ! git diff --cached --quiet; }; then
        # Check if there are changes other than update.sh
        local has_other_changes=0
        while IFS= read -r file; do
            if [ "${file}" != "update.sh" ]; then
                has_other_changes=1
                break
            fi
        done < <(git diff --name-only; git diff --cached --name-only)

        if [ "$has_other_changes" -eq 1 ]; then
            log_warn "You have local changes to your configuration"
            read -p "Do you want to temporarily save these changes and continue? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
            log_info "Saving your local changes..."
            
            # First, reset update.sh if it has changes
            if git diff --quiet update.sh || git diff --cached --quiet update.sh; then
                git checkout -- update.sh 2>/dev/null || true
            fi
            
            # Now try to stash other changes
            if git stash push -- ':!update.sh'; then
                CHANGES_STASHED=1
                touch "${BACKUP_DIR}/.stashed"
            else
                log_error "Failed to save local changes"
                exit 1
            fi
        fi
    fi
}

# Function to restore stashed changes
restore_stashed_changes() {
    if [ "$CHANGES_STASHED" -eq 1 ] && [ -f "${BACKUP_DIR}/.stashed" ] && [ ! -f "${BACKUP_DIR}/.stash_restored" ]; then
        log_info "Restoring your saved local changes..."
        if git stash pop; then
            touch "${BACKUP_DIR}/.stash_restored"
            log_info "Your local changes have been restored successfully"
            CHANGES_STASHED=0
        else
            log_error "Failed to restore your local changes automatically."
            log_info "Your changes are saved and can be restored manually with: git stash pop"
            # Restore failed; do not alter CHANGES_STASHED
        fi
    fi
}

# Function to cleanup on script exit
cleanup() {
    set +e
    local exit_code=$?
    cleanup_temp_files
    # Only try to restore stashed changes if they weren't restored already
    if [ "$CHANGES_STASHED" -eq 1 ] && [ ! -f "${BACKUP_DIR}/.stash_restored" ]; then
        restore_stashed_changes
    fi
    exit $exit_code
}
trap cleanup EXIT

# Function to add temporary file for cleanup
add_temp_file() {
    if [[ ! " ${TEMP_FILES[@]} " =~ " $1 " ]]; then
        TEMP_FILES+=("$1")
    fi
}

# Function to create backup
create_backup() {
    log_info "Creating backup of current configuration..."
    local failed=0
    local files_to_backup=("cloudflare-dns-update.conf" "cloudflare-dns-update.log" "$SCRIPT_PATH")
    
    for file in "${files_to_backup[@]}"; do
        if [ -f "$file" ]; then
            cp -p "$file" "$BACKUP_DIR/" || failed=1
        fi
    done
    
    if [ $failed -eq 1 ]; then
        log_error "Failed to create complete backup"
        return 1
    fi
    
    log_info "Backup created in: $BACKUP_DIR"
    return 0
}

# Function to restore from backup
restore_from_backup() {
    local backup_dir=$1
    local failed=0

    log_info "Restoring from backup: $backup_dir"
    if [ -f "$backup_dir/cloudflare-dns-update.conf" ]; then
        cp -p "$backup_dir/cloudflare-dns-update.conf" ./cloudflare-dns-update.conf || {
            log_error "Failed to restore 'cloudflare-dns-update.conf' from backup."
            failed=1
        }
    fi
    if [ -f "$backup_dir/cloudflare-dns-update.log" ]; then
        cp -p "$backup_dir/cloudflare-dns-update.log" ./cloudflare-dns-update.log || {
            log_error "Failed to restore 'cloudflare-dns-update.log' from backup."
            failed=1
        }
    fi
    if [ -f "$backup_dir/update.sh" ]; then
        cp -p "$backup_dir/update.sh" ./update.sh || {
            log_error "Failed to restore 'update.sh' from backup."
            failed=1
        }
        chmod +x ./update.sh || {
            log_error "Failed to set executable permission for 'update.sh' after restoration."
            failed=1
        }
    fi

    if [ $failed -eq 1 ]; then
        log_error "One or more files failed to restore from backup."
        return 1
    fi

    # Ensure restored scripts have executable permissions
    if [[ "$backup_dir/update.sh" == *.sh ]]; then
        chmod +x ./update.sh || {
            log_error "Failed to set executable permission for 'update.sh'."
            failed=1
        }
    fi

    if [ $failed -eq 1 ]; then
        log_error "Failed to fully restore all files from backup."
        return 1
    fi
    log_info "Backup restored successfully from: $backup_dir"
    return 0
}

# Function to extract configuration value
get_config_value() {
    local config_file=$1
    local key=$2
    local value
    value=$(grep "^${key}=" "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
    echo "$value"
    return 0
}

# Function to merge configurations
merge_configs() {
    local user_config=$1
    local new_config=$2
    local merged_config="${user_config}.merged"
    local has_new_options=false
    local current_section=""
    
    # Define required sections in order
    declare -a section_order=(
        "Domain configurations"
        "Global settings"
        "Error handling settings"
        "Log settings"
        "Update script settings"
        "Telegram notification settings"
    )
    
    declare -A sections_seen
    declare -A options_added
    declare -A user_values
    declare -A user_comments
    declare -A valid_sections

    # Initialize valid sections
    for section in "${section_order[@]}"; do
        valid_sections["$section"]=1
    done

    # Verify input files exist and are readable
    if [ ! -f "$user_config" ] || [ ! -r "$user_config" ]; then
        log_error "Merge failed: Unable to read user config file '$user_config'."
        return 1
    fi
    if [ ! -f "$new_config" ] || [ ! -r "$new_config" ]; then
        log_error "Merge failed: Unable to read new config file '$new_config'."
        return 1
    fi

    # Validate option name function
    validate_option_name() {
        local option=$1
        if ! [[ "$option" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log_error "Invalid option name format: $option"
            return 1
        fi
        return 0
    }

    # First pass: read user's config to store all current values and mark sections
    local last_comment=""
    local line_continuation=false
    local current_value=""
    local current_key=""

    while IFS= read -r line || [ -n "$line" ]; do
        # Handle line continuation
        if [ "$line_continuation" = true ]; then
            current_value+=$'\n'"$line"
            if [[ ! "$line" =~ \\$ ]]; then
                user_values["$current_key"]="$current_value"
                line_continuation=false
                current_value=""
                current_key=""
            fi
            continue
        fi

        # Handle comments
        if [[ "$line" =~ ^[[:space:]]*#.*$ ]] || [[ -z "$line" && -n "$last_comment" ]]; then
            if [ -n "$last_comment" ]; then
                last_comment+=$'\n'
            fi
            last_comment+="$line"
            continue
        fi

        # Handle empty lines
        if [[ -z "$line" ]]; then
            last_comment=""
            continue
        fi

        # Detect section headers
        if [[ "$line" =~ ^###[[:space:]]*(.*)[[:space:]]*$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            if [ -z "${valid_sections[$current_section]:-}" ]; then
                log_warn "Unknown section found: $current_section"
            fi
            sections_seen["$current_section"]=1
            [ -n "$last_comment" ] && user_comments["section_${current_section}"]="$last_comment"
            last_comment=""
            continue
        fi

        # Store existing options and their values
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Validate option name
            if ! validate_option_name "$key"; then
                continue
            fi

            # Handle multi-line values
            if [[ "$value" =~ \\$ ]]; then
                line_continuation=true
                current_key="$key"
                current_value="$value"
                continue
            fi

            # Store single-line value
            user_values["$key"]="$value"
            options_added["$key"]=1
            [ -n "$last_comment" ] && user_comments["option_${key}"]="$last_comment"
            last_comment=""
        fi
    done < "$user_config"

    # Verify required sections in new config
    local found_sections=()
    local current_order=0
    local last_section_order=-1
    while IFS= read -r line; do
        if [[ "$line" =~ ^###[[:space:]]*(.*)[[:space:]]*$ ]]; then
            local section="${BASH_REMATCH[1]}"
            if [ -n "${valid_sections[$section]:-}" ]; then
                found_sections+=("$section")
                # Check section order
                for ((i=0; i<${#section_order[@]}; i++)); do
                    if [ "$section" = "${section_order[$i]}" ]; then
                        current_order=$i
                        break
                    fi
                done
                if [ $current_order -lt $last_section_order ]; then
                    log_error "Sections are not in the correct order in new config"
                    return 1
                fi
                last_section_order=$current_order
            fi
        fi
    done < "$new_config"

    # Check for missing required sections
    for section in "${section_order[@]}"; do
        if [[ ! " ${found_sections[@]} " =~ " ${section} " ]] && [ "$section" != "Telegram notification settings" ]; then
            log_error "Missing required section in new config: $section"
            return 1
        fi
    done

    # Second pass: create merged config
    local temp_file
    temp_file=$(mktemp)
    add_temp_file "$temp_file"

    while IFS= read -r line || [ -n "$line" ]; do
        # Pass through comments and empty lines unchanged
        if [[ "$line" =~ ^[[:space:]]*#.*$ ]] || [[ -z "$line" ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi

        # Process options
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            
            # If user has this option configured, use their value and comment
            if [ -n "${user_values[$key]:-}" ]; then
                # Add user's comment if exists
                if [ -n "${user_comments["option_${key}"]:-}" ]; then
                    echo "${user_comments["option_${key}"]}" >> "$temp_file"
                fi
                # Preserve the exact value from user's config
                echo "$key=${user_values[$key]}" >> "$temp_file"
            else
                has_new_options=true
                log_warn "New option found: $key in section: $current_section"
                echo "$line" >> "$temp_file"
            fi
            continue
        fi

        # Process section headers
        if [[ "$line" =~ ^###[[:space:]]*(.*)[[:space:]]*$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            # Add user's section comment if exists
            if [ -n "${user_comments["section_${current_section}"]:-}" ]; then
                # Add a newline before section if not at start of file
                if [ -s "$temp_file" ]; then
                    echo "" >> "$temp_file"
                fi
                echo "${user_comments["section_${current_section}"]}" >> "$temp_file"
            fi
            echo "$line" >> "$temp_file"
            continue
        fi

        # Pass through any other lines unchanged
        echo "$line" >> "$temp_file"
    done < "$new_config"

    # Move temp file to final location
    if [ "$has_new_options" = true ]; then
        # Create a copy for review first
        cp -p "$temp_file" "${user_config}.new" || {
            log_error "Failed to create review copy of merged configuration."
            rm -f "$temp_file"
            return 1
        }
        add_temp_file "${user_config}.new"

        # Now move the temp file to replace the user config
        if ! mv "$temp_file" "$user_config"; then
            log_error "Failed to apply merged configuration."
            rm -f "$temp_file"
            return 1
        fi
        return 0
    else
        rm -f "$temp_file"
        return 0
    fi
}

# Function to cleanup old backups
cleanup_old_backups() {
    local default_max_backups=10  # Default to keep last 10 backups
    local max_backups

    # Try to get max_backups from config file, use default if not found or invalid
    if [ -f cloudflare-dns-update.conf ]; then
        max_backups=$(get_config_value cloudflare-dns-update.conf "max_update_backups")
        # If empty, not a number, or not a positive integer, use default
        if ! [[ "$max_backups" =~ ^[1-9][0-9]*$ ]]; then
            log_warn "Invalid or missing 'max_update_backups' in config. Using default value: $default_max_backups"
            max_backups=$default_max_backups
        fi
    else
        max_backups=$default_max_backups
    fi

    local backup_count
    local backup_dirs

    # Only count directories that match our timestamp pattern
    backup_dirs=$(find "${SCRIPT_DIR}/backups/" -maxdepth 1 -type d -name "[0-9]*_*" 2>/dev/null) || return 0
    backup_count=$(echo "$backup_dirs" | wc -l)

    if [ "$backup_count" -gt "$max_backups" ]; then
        log_info "Cleaning up old backups (keeping last $max_backups)..."
        echo "$backup_dirs" | xargs -d '\n' stat --format '%Y %n' 2>/dev/null | \
            sort -n | head -n -${max_backups} | cut -d' ' -f2- | \
            while read -r dir; do
                [ -d "$dir" ] && rm -rf "$dir"
            done
    fi
    return 0
}

# Function to verify file integrity
verify_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log_error "Verification failed: '${file}' does not exist."
        return 1
    fi
    if [ ! -r "$file" ]; then
        log_error "Verification failed: '${file}' is not readable."
        return 1
    fi
    if [ ! -s "$file" ]; then
        log_error "Verification failed: '${file}' is empty."
        return 1
    fi
    if [[ "$file" =~ \.(sh|bash)$ ]]; then
        if [ ! -x "$file" ]; then
            log_error "Verification failed: '${file}' is not executable."
            return 1
        fi
        # Check for shebang
        if ! grep -q "^#\!/" "$file"; then
            log_error "Verification failed: '${file}' is missing a shebang (#!)."
            return 1
        fi
    fi
    return 0
}

# Create backup before anything else
if ! create_backup; then
    log_error "Failed to create backup"
    exit 1
fi

# Cleanup old backups
cleanup_old_backups

# Check if we're on the main branch
check_main_branch() {
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "main" ]; then
        log_warn "You are not on the main branch. Current branch: $current_branch"
        read -p "Do you want to continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Invoke branch check
check_main_branch

# Check if we're behind origin/main
COMMITS_BEHIND=$(git rev-list HEAD..origin/main --count)
if [ "$COMMITS_BEHIND" -eq 0 ]; then
    # Even if there are no git updates, we should check if the config needs updating
    if [ -f cloudflare-dns-update.conf ]; then
        log_info "Checking if configuration needs updating..."
        # Get the template config from the repository
        if ! git show "origin/main:cloudflare-dns-update.conf" > "cloudflare-dns-update.conf.template"; then
            log_error "Failed to get template configuration"
            exit 1
        fi
        add_temp_file "cloudflare-dns-update.conf.template"

        # Try merging to see if there are differences
        if merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf.template; then
            if [ -f "${user_config}.new" ]; then
                log_info "Configuration has been updated with new options"
                log_info "Please review the changes in ${user_config}.new"
            else
                log_info "Configuration is up to date"
            fi
        else
            log_warn "Failed to update configuration"
            # Restore from backup
            if ! restore_from_backup "$BACKUP_DIR"; then
                log_error "Failed to restore from backup after merge failure"
                exit 1
            fi
            # Attempt merge again with restored config
            if ! merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf.template; then
                log_error "Failed to merge configuration files after restore"
                exit 1
            fi
        fi
    fi
    log_info "No updates required"
    exit 0
fi

# Only check for local changes if we actually need to update
handle_local_changes

# If we get here, the update script doesn't need updating, proceed with normal updates
if ! git pull origin main; then
    log_error "Failed to pull updates. Please check your internet connection or repository access."
    # Restore from latest backup
    restore_from_backup "$BACKUP_DIR"
    restore_stashed_changes
    exit 1
fi

# Handle configuration updates
if [ -f "$BACKUP_DIR/cloudflare-dns-update.conf" ] && [ -f cloudflare-dns-update.conf ]; then
    log_info "Checking for new configuration options..."
    if ! verify_file cloudflare-dns-update.conf; then
        log_error "New configuration file is invalid"
        restore_from_backup "$BACKUP_DIR"
        exit 1
    fi

    # Get the template config from the repository
    if ! git show "origin/main:cloudflare-dns-update.conf" > "cloudflare-dns-update.conf.template"; then
        log_error "Failed to get template configuration"
        restore_from_backup "$BACKUP_DIR"
        exit 1
    fi
    add_temp_file "cloudflare-dns-update.conf.template"

    # Restore user's config for merging
    cp "$BACKUP_DIR/cloudflare-dns-update.conf" ./cloudflare-dns-update.conf || {
        log_error "Failed to restore backup configuration for merging."
        restore_from_backup "$BACKUP_DIR"
        exit 1
    }

    # Save any local changes to the config file before merging
    if [ -f "${BACKUP_DIR}/.stashed" ]; then
        git stash save --keep-index "Temporary save of config changes during update" >/dev/null 2>&1 || {
            log_error "Failed to stash local configuration changes."
            restore_from_backup "$BACKUP_DIR"
            exit 1
        }
    fi

    # Merge configurations using the template
    if ! merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf.template; then
        log_error "Failed to merge configuration files"
        restore_from_backup "$BACKUP_DIR"
        exit 1
    fi

    # Final verification of merged configuration
    if ! verify_file cloudflare-dns-update.conf; then
        log_error "Merged configuration file is invalid"
        restore_from_backup "$BACKUP_DIR"
        exit 1
    fi
fi

# Restore log file if needed
if [ -f "$BACKUP_DIR/cloudflare-dns-update.log" ]; then
    log_info "Restoring your log file..."
    cp "$BACKUP_DIR/cloudflare-dns-update.log" ./cloudflare-dns-update.log
fi

# Make scripts executable
for script in cloudflare-dns-update.sh update.sh; do
    if ! chmod +x "$script"; then
        log_error "Failed to make $script executable"
        restore_from_backup "$BACKUP_DIR"
        exit 1
    fi
done

# Verify script integrity after update
if ! verify_file update.sh || ! verify_file cloudflare-dns-update.sh; then
    log_error "Script files are invalid after update"
    restore_from_backup "$BACKUP_DIR"
    exit 1
fi

# Pop stashed changes if any
if [ -f "${BACKUP_DIR}/.stashed" ] && [ ! -f "${BACKUP_DIR}/.stash_restored" ]; then
    restore_stashed_changes
fi

log_info "Update completed successfully!"
log_info "Please review your configuration file for any new options that were added."
log_info "All previous files have been backed up to: $BACKUP_DIR" 