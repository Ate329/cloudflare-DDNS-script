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

# Create backup directory with timestamp and pid for uniqueness
BACKUP_DIR="${SCRIPT_DIR}/backups/$(date +%Y%m%d_%H%M%S)_$$"
mkdir -p "$BACKUP_DIR"

# Trap for cleanup on script exit
cleanup() {
    local exit_code=$?
    # If we have stashed changes and haven't restored them
    if [ -f "${BACKUP_DIR}/.stashed" ] && [ ! -f "${BACKUP_DIR}/.stash_restored" ]; then
        log_warn "Script interrupted. Attempting to restore stashed changes..."
        if git stash pop; then
            log_info "Stashed changes restored."
        else
            log_error "Failed to restore stashed changes. They remain in the stash."
            log_info "You can restore them manually with: git stash pop"
        fi
    fi
    exit $exit_code
}
trap cleanup EXIT

# Function to create backup
create_backup() {
    log_info "Creating backup of current configuration..."
    if [ -f cloudflare-dns-update.conf ]; then
        cp -p cloudflare-dns-update.conf "$BACKUP_DIR/"
    fi
    if [ -f cloudflare-dns-update.log ]; then
        cp -p cloudflare-dns-update.log "$BACKUP_DIR/"
    fi
    # Backup the update script itself
    cp -p "$SCRIPT_PATH" "$BACKUP_DIR/"
    log_info "Backup created in: $BACKUP_DIR"
    return 0
}

# Function to restore from backup
restore_from_backup() {
    local backup_dir=$1
    log_info "Restoring from backup: $backup_dir"
    if [ -f "$backup_dir/cloudflare-dns-update.conf" ]; then
        cp -p "$backup_dir/cloudflare-dns-update.conf" ./cloudflare-dns-update.conf
    fi
    if [ -f "$backup_dir/cloudflare-dns-update.log" ]; then
        cp -p "$backup_dir/cloudflare-dns-update.log" ./cloudflare-dns-update.log
    fi
    if [ -f "$backup_dir/update.sh" ]; then
        cp -p "$backup_dir/update.sh" ./update.sh
        chmod +x ./update.sh
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
    local max_backups=10  # Keep last 10 backups
    local backup_count
    
    # Only count directories that match our timestamp_pid pattern
    backup_count=$(find "${SCRIPT_DIR}/backups/" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" 2>/dev/null | wc -l)
    
    if [ "$backup_count" -gt "$max_backups" ]; then
        log_info "Cleaning up old backups..."
        find "${SCRIPT_DIR}/backups/" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" -printf "%T@ %p\n" | \
            sort -n | head -n -${max_backups} | cut -d' ' -f2- | xargs rm -rf
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

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    log_warn "You have uncommitted changes"
    read -p "Do you want to stash them and continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    log_info "Stashing local changes..."
    if git stash; then
        touch "${BACKUP_DIR}/.stashed"
    else
        log_error "Failed to stash changes"
        exit 1
    fi
fi

# Fetch updates first to check if they exist
log_info "Checking for updates..."
git fetch origin main

# Check if we're behind origin/main
if [ "$(git rev-list HEAD..origin/main --count)" -eq 0 ]; then
    # Even if there are no git updates, we should check if the config needs updating
    if [ -f cloudflare-dns-update.conf ]; then
        log_info "Checking if configuration needs updating..."
        # Create temporary copy of current config for comparison
        cp cloudflare-dns-update.conf cloudflare-dns-update.conf.current
        # Try merging to see if there are differences
        if merge_configs cloudflare-dns-update.conf.current cloudflare-dns-update.conf > /dev/null 2>&1; then
            log_info "Configuration is up to date."
        else
            log_warn "Configuration file needs updating despite no git changes."
            # Actual merge with the real file
            merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf
        fi
        rm -f cloudflare-dns-update.conf.current
    fi
    log_info "Already up to date."
    exit 0
fi

# Update from git
log_info "Fetching updates from repository..."

# First, check if update.sh will be modified
git fetch origin main
if ! git diff --name-only HEAD..origin/main | grep -q "^update.sh$"; then
    UPDATE_SCRIPT_CHANGED=1
else
    UPDATE_SCRIPT_CHANGED=0
fi

if [ $UPDATE_SCRIPT_CHANGED -eq 0 ]; then
    log_info "Update script needs updating. Updating it first..."
    # Temporarily save the update script
    cp -p update.sh update.sh.updating
    
    # Pull only the update script
    if ! git checkout origin/main -- update.sh; then
        log_error "Failed to update the script"
        mv update.sh.updating update.sh
        exit 1
    fi
    
    if ! verify_file update.sh; then
        log_error "New update script is invalid"
        mv update.sh.updating update.sh
        exit 1
    fi
    
    # Make the new script executable
    chmod +x update.sh
    
    log_info "Update script has been updated. Restarting update process..."
    rm -f update.sh.updating
    
    # Execute the new update script and exit
    exec ./update.sh
    exit $?
fi

# If we get here, the update script doesn't need updating, proceed with normal updates
if ! git pull origin main; then
    log_error "Failed to pull updates. Please check your internet connection or repository access."
    # Restore from latest backup
    restore_from_backup "$BACKUP_DIR"
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
    
    # Restore user's config for merging
    cp "$BACKUP_DIR/cloudflare-dns-update.conf" ./cloudflare-dns-update.conf
    
    # If we have stashed changes and the config was modified, we need special handling
    if [ -f "${BACKUP_DIR}/.stashed" ]; then
        # Save current index state
        git stash push -m "Temporary stash for config merge"
        
        # Try to apply original stashed changes
        if ! git stash apply stash@{1}; then
            log_warn "Could not apply original changes automatically"
            git stash pop stash@{0}  # Restore current state
            log_info "Your original changes are in stash@{0}, please merge them manually"
            rm -f "${BACKUP_DIR}/.stashed"  # Prevent further stash operations
        else
            # Now we have the original changes applied
            # Save the current state of the config
            cp cloudflare-dns-update.conf cloudflare-dns-update.conf.original
            
            # Pop the temporary stash to get back to our state
            git stash pop
            
            # Now merge the configs
            if ! merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf.new; then
                log_error "Failed to merge configuration files"
                cp cloudflare-dns-update.conf.original cloudflare-dns-update.conf
                rm -f cloudflare-dns-update.conf.new cloudflare-dns-update.conf.original
                restore_from_backup "$BACKUP_DIR"
                exit 1
            fi
            
            rm -f cloudflare-dns-update.conf.original
        fi
    else
        # Normal merge without stashed changes
        if ! merge_configs cloudflare-dns-update.conf cloudflare-dns-update.conf.new; then
            log_error "Failed to merge configuration files"
            restore_from_backup "$BACKUP_DIR"
            rm -f cloudflare-dns-update.conf.new
            exit 1
        fi
    fi
    
    # Cleanup temporary file
    rm -f cloudflare-dns-update.conf.new
fi

# Restore log file if needed
if [ -f "$BACKUP_DIR/cloudflare-dns-update.log" ]; then
    log_info "Restoring your log file..."
    cp "$BACKUP_DIR/cloudflare-dns-update.log" ./cloudflare-dns-update.log
fi

# Make scripts executable
chmod +x cloudflare-dns-update.sh update.sh

# Verify script integrity after update
if ! verify_file update.sh || ! verify_file cloudflare-dns-update.sh; then
    log_error "Script files are invalid after update"
    restore_from_backup "$BACKUP_DIR"
    exit 1
fi

# If update.sh itself was modified, notify user to run again
if ! cmp -s "$BACKUP_DIR/update.sh" ./update.sh; then
    log_warn "The update script itself has been modified."
    log_warn "Please run the update script again to ensure all changes are applied correctly."
    log_info "Your previous version has been backed up to: $BACKUP_DIR/update.sh"
    
    # Make sure the new update script is executable
    chmod +x ./update.sh
    
    # Verify the new update script is valid
    if ! verify_file update.sh; then
        log_error "New update script is invalid"
        restore_from_backup "$BACKUP_DIR"
        exit 1
    fi
fi

# Pop stashed changes if any
if [ -f "${BACKUP_DIR}/.stashed" ]; then
    log_info "Restoring local changes..."
    if git stash pop; then
        touch "${BACKUP_DIR}/.stash_restored"
        log_info "Local changes restored successfully"
    else
        log_error "Failed to restore local changes. Please resolve conflicts manually."
        log_info "Your changes are still in the stash and can be restored with 'git stash pop'"
        # Don't exit with error since the update itself was successful
    fi
fi

log_info "Update completed successfully!"
log_info "Please review your configuration file for any new options that were added."
log_info "All previous files have been backed up to: $BACKUP_DIR" 