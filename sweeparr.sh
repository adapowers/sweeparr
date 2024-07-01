#!/usr/bin/env bash

# Sweeparr for Sonarr/Radarr
# Author: @adapowers
# Version: 2024.30.06
# --------------------------------

# NOTE:
# This script is intended to be called automatically by Sonarr/Radarr.
# It uses environment variables set by these applications at runtime.
# It will do nothing (or worse) if run directly from the command line.

# --------------------------------

# Enable strict mode for better error handling
set -euo pipefail

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set default log file if not defined in .env
: "${LOG_FILE:=$SCRIPT_DIR/sweeparr.log}"

# Define default config file location
CONFIG_FILE="$SCRIPT_DIR/.env"

# Override config file location if provided
CONFIG_FILE="${CONFIG_FILE_PATH:-$CONFIG_FILE}"

# Source the configuration file if it exists
if [ -f "$CONFIG_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
else
    echo "Configuration file not found at $CONFIG_FILE. Exiting."
    exit 1
fi

# Logging configuration
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)

# Function to handle errors
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"  # Default to exit code 1 if not provided
    log_message "ERROR" "$error_message"
    exit "$exit_code"
}

# Function to log and echo messages
log_message() {
    local level="$1"
    local message="$2"
    local tag="Sweeparr"
    local process="${app_name:+$app_name:}$$"
    if [[ ${LOG_LEVELS[$level]} -ge ${LOG_LEVELS[$LOG_LEVEL]} ]]; then
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$timestamp] [$level] [$process] $message" | tee -a "$LOG_FILE"
        echo "[$tag] [$process] $message"
    fi
}

# Convert comma-separated string to array
IFS=',' read -r -a DOWNLOAD_FOLDERS <<< "$DOWNLOAD_FOLDERS"
unset IFS

# Log script start
log_message "DEBUG" "Starting script"

# Ensure TRASH_FOLDER is set if using trash option
[[ "$USE_TRASH" == true && -z "$TRASH_FOLDER" ]] && handle_error "TRASH_FOLDER is not set even though USE_TRASH is on. Exiting."

# Ensure DOWNLOAD_FOLDERS is set
[[ -z "${DOWNLOAD_FOLDERS[*]}" ]] && handle_error "DOWNLOAD_FOLDERS not set. Exiting."

# Ensure DOWNLOAD_FOLDERS are readable
for folder in "${DOWNLOAD_FOLDERS[@]}"; do
    [ ! -r "$folder" ] && handle_error "Download folder $folder is not readable. Exiting."
done

# Log configuration
log_message "INFO" "Configuration: DRY_RUN=$DRY_RUN, USE_TRASH=$USE_TRASH, TRASH_FOLDER=$TRASH_FOLDER, LOG_FILE=$LOG_FILE, LOG_LEVEL=$LOG_LEVEL, WAIT_TIME=$WAIT_TIME"
log_message "INFO" "Download folders: ${DOWNLOAD_FOLDERS[*]}"

# Function to set variables based on whether Sonarr or Radarr is calling the script
set_variables() {
    if [[ -n "${sonarr_eventtype:-}" ]]; then
        event_type="${sonarr_eventtype}"
        app_name="Sonarr"
    elif [[ -n "${radarr_eventtype:-}" ]]; then
        event_type="${radarr_eventtype}"
        app_name="Radarr"
    else
        handle_error "Neither Sonarr nor Radarr environment variables detected. (This is to be expected if you're running the script manually.)"
    fi

    # Log event type
    log_message "INFO" "Event type: $event_type"

    # Handle different event types
    case "$event_type" in
    # Handle test event type
    Test)
        log_message "INFO" "Test event detected. Exiting script."
        exit 0
        ;;

    # Handle import event type
    Download|Import)
        if [[ "$app_name" == "Sonarr" ]]; then
            source_path="${sonarr_episodefile_sourcepath:-}"
            source_folder="${sonarr_episodefile_sourcefolder:-}"
            dest_path="${sonarr_episodefile_path:-}"
        elif [[ "$app_name" == "Radarr" ]]; then
            source_path="${radarr_moviefile_sourcepath:-}"
            source_folder="${radarr_moviefile_sourcefolder:-}"
            dest_path="${radarr_moviefile_path:-}"
        else
            handle_error "No $app_name import event environment variables detected. (This is to be expected if you're running the script manually.)"
        fi
        # Log paths
        log_message "DEBUG" "Set variables: source_path=$source_path, source_folder=$source_folder, dest_path=$dest_path"
        ;;

    *)
        handle_error "This script is only designed for the 'Import' or 'Download' event types."
        ;;
    esac
}

# Function to check if a folder contains video files recursively
recursive_contains_video_files() {
    # returns 0 on true, 1 on false
    find "$1" -type f | grep -qE "$VIDEO_EXTENSIONS"
}

declare -A trie

build_trie() {
    trie=()
    for path in "${DOWNLOAD_FOLDERS[@]}"; do
        local current=""
        for component in ${path//\// }; do
            current+="/$component"
            trie["$current"]=1
        done
        trie["$path:end"]=1
    done
}

find_safe_parent() {
    local folder="$1"
    local current=""
    local longest_protected=""

    log_message "DEBUG" "Starting find_safe_parent with folder: $folder"

    # Check if the folder is a protected folder or its parent
    if [[ ${trie["$folder:end"]} -eq 1 ]] || [[ ${trie["$folder"]} -eq 1 ]]; then
        log_message "DEBUG" "Folder $folder is protected or parent of protected"
        echo "protected"
        return
    fi

    # Find the longest protected prefix
    for component in ${folder//\// }; do
        current+="/$component"
        if [[ ${trie["$current"]} -eq 1 ]]; then
            longest_protected="$current"
        fi
    done

    # If no protected prefix found, it's outside
    if [[ -z "$longest_protected" ]]; then
        log_message "DEBUG" "Returning highest safe parent folder: outside"
        echo "outside"
        return
    fi

    # Find the highest safe parent
    local safe_parent="$folder"
    while [[ "$safe_parent" != "$longest_protected" && "$safe_parent" != "/" ]]; do
        local parent
        parent=$(dirname "$safe_parent")
        if [[ "$parent" == "$longest_protected" ]]; then
            break
        fi
        safe_parent="$parent"
    done

    log_message "DEBUG" "Returning highest safe parent folder: $safe_parent"
    echo "$safe_parent"
}

# Function to generate a unique name for moving to trash
generate_trashed_path() {
    local target="$1"
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S) || handle_error "Failed to generate timestamp"
    local trashed_path
    trashed_path="${TRASH_FOLDER}/$(basename "$target")_${timestamp}_$$"
    [[ -z "$trashed_path" ]] && handle_error "Failed to generate trashed path for: $target"
    echo "$trashed_path"
}

handle_symlink() {
    local target="$1"
    local operation="$2"  # 'delete' or 'trash'
    
    if [[ -L "$target" ]]; then
        local link_target
        link_target=$(readlink -f "$target")
        log_message "INFO" "Handling symbolic link: $target -> $link_target"
        
        if [[ "$operation" == "delete" ]]; then
            rm "$target" || handle_error "Failed to delete symbolic link: $target"
            log_message "INFO" "Deleted symbolic link: $target"
        elif [[ "$operation" == "trash" ]]; then
            local trashed_name
            trashed_name=$(generate_trashed_path "$target")
            mv "$target" "$trashed_name" || handle_error "Failed to move symbolic link to trash: $target"
            log_message "INFO" "Moved symbolic link to trash: $target -> $trashed_name"
        fi
        
        return 0
    fi
    
    return 1
}

check_trash_quota() {
    local required_space="$1"
    
    # Get available space in KB
    local available_space
    available_space=$(df -Pk "$TRASH_FOLDER" | awk 'NR==2 {print $4}')
    
    # Convert to bytes
    available_space=$((available_space * 1024))
    
    log_message "DEBUG" "Available space in trash folder: $available_space bytes"
    log_message "DEBUG" "Required space for operation: $required_space bytes"
    
    if [[ "$available_space" -lt "$required_space" ]]; then
        log_message "WARNING" "Not enough space in trash folder. Available: $available_space bytes, Required: $required_space bytes"
        return 1
    fi
    
    return 0
}

# Function to safely remove files or directories
safe_remove() {
    local target="$1"
    local is_dir="$2"
    
    # Handle symlink first
    if handle_symlink "$target" "${USE_TRASH:+trash}${USE_TRASH:-delete}"; then
        return 0
    fi

    local operation_type="file"
    local operation_desc="delete"  # Default operation description
    local trashed_name

    [[ "$is_dir" == true ]] && operation_type="folder"

    # Determine the operation description based on trash or delete
    if $USE_TRASH; then
        operation_desc="move to trash"
        trashed_name=$(generate_trashed_path "$target")  # Generate trash name only if needed
    fi

    # Check if it's a dry run, and log what would happen.
    if $DRY_RUN; then
        if $USE_TRASH; then
            log_message "INFO" "[DRY RUN] Would $operation_desc ($operation_type): $target -> $trashed_name"
        else
            log_message "INFO" "[DRY RUN] Would $operation_desc ($operation_type): $target"
        fi
        return 0
    fi

    # Attempt to get the size of the file/folder
    local size
    size=$(du -sb "$target" | cut -f1) || handle_error "Failed to get size for $target"

    # Perform the actual operation based on whether trash is used
    if $USE_TRASH; then
        if ! check_trash_quota "$size"; then
            log_message "ERROR" "Not enough space in trash folder to move: $target"
            return 1
        fi
        mv "$target" "$trashed_name" || handle_error "Failed to $operation_desc ($operation_type): $target"
        log_message "INFO" "Successfully $operation_desc ($operation_type): $target -> $trashed_name"
        ((items_trashed++))
        ((space_freed+=size))
    else
        if [[ "$is_dir" == true ]]; then
            rm -r "$target" || handle_error "Failed to $operation_desc ($operation_type): $target"
            log_message "INFO" "Successfully $operation_desc ($operation_type): $target"
            ((dirs_deleted++))
            ((space_freed+=size))
        else
            rm "$target" || handle_error "Failed to $operation_desc ($operation_type): $target"
            log_message "INFO" "Successfully $operation_desc ($operation_type): $target"
            ((files_deleted++))
            ((space_freed+=size))
        fi
    fi
}

check_filesystem() {
    local path="$1"
    local fs_type
    fs_type=$(stat -f -c %T "$path")
    
    log_message "DEBUG" "Filesystem type for $path: $fs_type"
    
    # List of supported filesystems
    local supported_fs=("ext4" "xfs" "btrfs" "zfs")
    
    if [[ ! ${supported_fs[*]} =~ ${fs_type} ]]; then
        log_message "WARNING" "Unsupported filesystem ($fs_type) for $path. Operations may fail."
    fi
}

# Function to attempt deletion or moving of file and folder
start_cleanup() {
    log_message "INFO" "Checking if deletion/moving is possible..."
    
    check_filesystem "$source_folder"

    # Attempt to delete or move the source file first
    if [[ -f "$source_path" ]]; then
        local file_operation_type="single file"
        log_message "INFO" "Attempting to ${USE_TRASH:+move to trash}${USE_TRASH:-delete} ($file_operation_type): $source_path"
        safe_remove "$source_path" false
    else
        log_message "INFO" "Source file already deleted or moved: $source_path"
    fi

    # Check if the source folder exists before proceeding
    if [[ -d "$source_folder" ]]; then
        log_message "INFO" "Checking to see if folder can be deleted: $source_folder"
        # Find the highest-level containing folder that's still a subpath of a download folder
        local target_folder
        target_folder=$(find_safe_parent "$source_folder")
        log_message "DEBUG" "Safe parent folder determined: $target_folder"

        case "$target_folder" in
        protected)
            log_message "INFO" "Known download folder, will not be deleted: $source_folder"
            ;;
        outside)
            log_message "INFO" "Folder outside known locations, will not be deleted: $source_folder"
            ;;
        *)
            log_message "INFO" "Checking for remaining video files in: $target_folder"
            if recursive_contains_video_files "$target_folder"; then
                log_message "INFO" "Video files found. Not ${USE_TRASH:+moving}${USE_TRASH:-deleting} folder: $target_folder"
            else
                    local folder_operation_type="folder"
                    log_message "INFO" "No video files found. Attempting to ${USE_TRASH:+move to trash}${USE_TRASH:-delete} ($folder_operation_type): $target_folder"
                    if [[ -d "$target_folder" ]]; then
                        safe_remove "$target_folder" true
                    else
                        log_message "INFO" "Entire source folder already deleted or moved: $target_folder"
                    fi
            fi
            ;;
        esac
    else
        log_message "INFO" "Source folder already deleted or moved: $source_folder"
    fi
}

# --- MAIN LOGIC

# Call the function to set variables
set_variables

# Build the trie when your script starts
build_trie

# Initialize statistics
files_deleted=0
dirs_deleted=0
items_trashed=0
space_freed=0

# Log initial information
log_message "INFO" "Running cleanup script for $app_name"
log_message "INFO" "Source: $source_path"
log_message "INFO" "Destination: $dest_path"
log_message "INFO" "Waiting $WAIT_TIME seconds for operations to complete..."
sleep "$WAIT_TIME" || handle_error "Sleep command failed"

# Attempt to delete/move file and/or folder
start_cleanup

# Prepare the summary message
if $USE_TRASH; then
formatted_space=$(numfmt --to=iec-i --suffix=B "$space_freed") || handle_error "Failed to format space freed"
    summary="Cleanup complete. Items moved to trash: $items_trashed. Space freed: $formatted_space."
else
    formatted_space=$(numfmt --to=iec-i --suffix=B "$space_freed") || handle_error "Failed to format space freed"
    summary="Cleanup complete. Files deleted: $files_deleted. Directories deleted: $dirs_deleted. Space freed: $formatted_space."
fi

log_message "INFO" "$summary"
