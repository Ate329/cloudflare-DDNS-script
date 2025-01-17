#!/usr/bin/env bash

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
    
    # Replace the old script with the new one
    if ! cp -p "$TEMP_UPDATE_DIR/update.sh" "$SCRIPT_PATH"; then
        log_error "Failed to replace update script"
        exit 1
    fi
    
    # Update git's state to recognize the new script
    git add update.sh
    git reset HEAD update.sh
    
    log_info "Update script has been updated. Proceeding with remaining updates..."
    
    # Continue with the current script (no restart needed)
    # The script is already replaced, and git state is updated
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
            if [ "$file" != "update.sh" ]; then
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
    if [ "$CHANGES_STASHED" -eq 1 ] && [ -f "${BACKUP_DIR}/.stashed" ]; then
        log_info "Restoring your saved local changes..."
        if git stash pop; then
            touch "${BACKUP_DIR}/.stash_restored"
            log_info "Your local changes have been restored successfully"
            CHANGES_STASHED=0
        else
            log_error "Failed to restore your local changes automatically."
            log_info "Your changes are saved and can be restored manually with: git stash pop"
            # Don't exit with error since the update itself was successful
        fi
    fi
}

# Trap for cleanup on script exit
cleanup() {
    local exit_code=$?
    cleanup_temp_files
    # Always try to restore stashed changes on exit if they weren't restored already
    restore_stashed_changes
    exit $exit_code
}
trap cleanup EXIT

# Function to add temporary file for cleanup
add_temp_file() {
    TEMP_FILES+=("$1")
}

# Function to create backup
create_backup() {
    log_info "Creating backup of current configuration..."
    local failed=0
    
    if [ -f cloudflare-dns-update.conf ]; then
        cp -p cloudflare-dns-update.conf "$BACKUP_DIR/" || failed=1
    fi
    if [ -f cloudflare-dns-update.log ]; then
        cp -p cloudflare-dns-update.log "$BACKUP_DIR/" || failed=1
    fi
    # Backup the update script itself
    cp -p "$SCRIPT_PATH" "$BACKUP_DIR/" || failed=1
    
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
        cp -p "$backup_dir/cloudflare-dns-update.conf" ./cloudflare-dns-update.conf || failed=1
    fi
    if [ -f "$backup_dir/cloudflare-dns-update.log" ]; then
        cp -p "$backup_dir/cloudflare-dns-update.log" ./cloudflare-dns-update.log || failed=1
    fi
    if [ -f "$backup_dir/update.sh" ]; then
        cp -p "$backup_dir/update.sh" ./update.sh || failed=1
        chmod +x ./update.sh || failed=1
    fi
    
    if [ $failed -eq 1 ]; then
        log_error "Failed to restore complete backup"
        return 1
    fi
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
    declare -A sections_seen
    declare -A options_added
    declare -A section_comments

    # Verify input files exist and are readable
    if [ ! -f "$user_config" ] || [ ! -r "$user_config" ]; then
        return 1
    fi
    if [ ! -f "$new_config" ] || [ ! -r "$new_config" ]; then
        return 1
    fi

    # First pass: read user's config and mark all sections, options, and their comments
    local last_comments=""
    while IFS= read -r line; do
        # Track comments
        if [[ "$line" =~ ^#[[:space:]].*$ ]]; then
            [ -n "$last_comments" ] && last_comments+=$'\n'
            last_comments+="$line"
            continue
        fi

        # Track sections
        if [[ "$line" =~ ^###[[:space:]]*(.*)[[:space:]]*$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            sections_seen["$current_section"]=1
            section_comments["$current_section"]="$last_comments"
            last_comments=""
            continue
        fi

        # Track existing options
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            options_added["${BASH_REMATCH[1]}"]=1
            last_comments=""
        fi
    done < "$user_config"

    # Create merged config starting with user's config
    cp "$user_config" "$merged_config"

    # Second pass: process new config and add new options in correct sections
    current_section=""
    local temp_section_content=""
    local in_matching_section=false
    last_comments=""

    while IFS= read -r line; do
        # Track comments
        if [[ "$line" =~ ^#[[:space:]].*$ ]]; then
            [ -n "$last_comments" ] && last_comments+=$'\n'
            last_comments+="$line"
            continue
        fi

        # Detect section headers
        if [[ "$line" =~ ^###[[:space:]]*(.*)[[:space:]]*$ ]]; then
            # If we have pending content from previous section, append it
            if [ -n "$temp_section_content" ] && [ "$in_matching_section" = true ]; then
                echo "$temp_section_content" >> "$merged_config"
            fi
            
            current_section="${BASH_REMATCH[1]}"
            temp_section_content=""
            in_matching_section=false

            # If this is a new section, add it at the end
            if [ -z "${sections_seen[$current_section]:-}" ]; then
                has_new_options=true
                log_warn "New section found: $current_section"
                echo "" >> "$merged_config"  # Add newline for readability
                [ -n "$last_comments" ] && echo "$last_comments" >> "$merged_config"
                echo "### $current_section" >> "$merged_config"
                sections_seen["$current_section"]=1
                section_comments["$current_section"]="$last_comments"
                in_matching_section=true
            fi
            last_comments=""
            continue
        fi

        # Process options
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            
            # If option doesn't exist in user's config
            if [ -z "${options_added[$key]:-}" ]; then
                has_new_options=true
                log_warn "New option found: $key in section: $current_section"
                
                # Add to temporary section content
                if [ -n "$temp_section_content" ]; then
                    temp_section_content+=$'\n'
                fi
                [ -n "$last_comments" ] && temp_section_content+=$'\n'"$last_comments"
                temp_section_content+=$'\n'"# New option added by update"$'\n'"$line"
                options_added["$key"]=1
                in_matching_section=true
            fi
            last_comments=""
        fi
    done < "$new_config"

    # Append any remaining section content
    if [ -n "$temp_section_content" ] && [ "$in_matching_section" = true ]; then
        echo "$temp_section_content" >> "$merged_config"
    fi

    if [ "$has_new_options" = true ]; then
        log_info "New configuration options have been added to your config file"
        cp -p "$merged_config" "${user_config}.new"  # Create a new file for review
        if ! mv "$merged_config" "$user_config"; then
            rm -f "$merged_config"
            return 1
        fi
        log_info "A copy of the new configuration has been saved as ${user_config}.new for review"
        return 0
    else
        log_info "No new configuration options found"
        rm -f "$merged_config"
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
        # If empty or not a number, use default
        if [ -z "$max_backups" ] || ! [[ "$max_backups" =~ ^[0-9]+$ ]]; then
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
    local file=$1
    if [ ! -f "$file" ]; then
        return 1
    fi
    if [ ! -r "$file" ]; then
        return 1
    fi
    if [ ! -s "$file" ]; then
        return 1
    fi
    if [ ! -x "$file" ] && [[ "$file" =~ \.(sh|bash)$ ]]; then
        return 1
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
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_branch" != "main" ]; then
    log_warn "You are not on the main branch. Current branch: $current_branch"
    read -p "Do you want to continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if we're behind origin/main
COMMITS_BEHIND=$(git rev-list HEAD..origin/main --count)
if [ "$COMMITS_BEHIND" -eq 0 ]; then
    # Even if there are no git updates, we should check if the config needs updating
    if [ -f cloudflare-dns-update.conf ]; then
        log_info "Checking if configuration needs updating..."
        # Create temporary copy of current config for comparison
        cp cloudflare-dns-update.conf cloudflare-dns-update.conf.current
        add_temp_file "cloudflare-dns-update.conf.current"
        # Try merging to see if there are differences
        if merge_configs cloudflare-dns-update.conf.current cloudflare-dns-update.conf > /dev/null 2>&1; then
            log_info "Configuration is up to date."
        else
            log_warn "Configuration file needs updating despite no git changes."
            # Actual merge with the real file
            merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf
        fi
    fi
    log_info "Already up to date."
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
    
    # Create temporary copy of new config
    cp cloudflare-dns-update.conf cloudflare-dns-update.conf.new
    add_temp_file "cloudflare-dns-update.conf.new"
    
    # Add new option if it doesn't exist
    if ! grep -q "^max_update_backups=" cloudflare-dns-update.conf; then
        echo -e "\n### Update script settings" >> cloudflare-dns-update.conf
        echo "max_update_backups=10  # Number of update backups to keep (default: 10)" >> cloudflare-dns-update.conf
    fi
    
    # Restore user's config for merging
    cp "$BACKUP_DIR/cloudflare-dns-update.conf" ./cloudflare-dns-update.conf
    
    # Normal merge without stashed changes
    if ! merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf.new; then
        log_error "Failed to merge configuration files"
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
if [ -f "${BACKUP_DIR}/.stashed" ]; then
    log_info "Restoring your saved local changes..."
    if git stash pop; then
        touch "${BACKUP_DIR}/.stash_restored"
        log_info "Your local changes have been restored successfully"
    else
        log_error "Failed to restore your local changes automatically."
        log_info "Your changes are saved and can be restored manually with: git stash pop"
        # Don't exit with error since the update itself was successful
    fi
fi

log_info "Update completed successfully!"
log_info "Please review your configuration file for any new options that were added."
log_info "All previous files have been backed up to: $BACKUP_DIR" 