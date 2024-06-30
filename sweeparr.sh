#!/bin/bash

# Sweeparr for Sonarr/Radarr
# Author: @adapowers
# Version: 2024.29.06
# --------------------------------

# NOTE:
# This script is intended to be called automatically by Sonarr/Radarr.
# It uses environment variables set by these applications at runtime.
# It will do nothing (or worse) if run directly from the command line.

# --- SETUP

# Enable strict mode for better error handling
set -euo pipefail

# Logging levels
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)

# Get the directory of the script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Unified function to log and echo messages
log_message() {
    local level="$1"
    local message="$2"
    local tag="[Sweeparr]"
    if [[ ${LOG_LEVELS[$level]} -ge ${LOG_LEVELS[$LOG_LEVEL]} ]]; then
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
        echo "$tag $message"
    fi
}

# Function to handle errors
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"  # Default to exit code 1 if not provided
    log_message "ERROR" "$error_message"
    exit "$exit_code"
}

# --- CONFIGURATION: MANUAL

# Check if running in Docker mode or manual mode
RUN_MODE=${RUN_MODE:-"manual"}

# Customize these if you're running the script yourself locally
if [ "$RUN_MODE" == "manual" ]; then

    # Set to true for dry run mode (no actual deletions or moves)
    DRY_RUN=false

    # Set to true to move files to trash instead of deleting
    USE_TRASH=false

    # Location of the trash folder (only used if USE_TRASH is true)
    TRASH_FOLDER="/full/path/to/trash/folder"

    # Log location (change if desired; default location is next to script file)
    LOG_FILE="$SCRIPT_DIR/sweeparr.log"

    # Logging level (DEBUG, INFO, WARNING, ERROR)
    LOG_LEVEL="INFO"

    # Wait time before execution (in seconds)
    WAIT_TIME=45

    # Full paths to your download folders
    # (Sweeparr will not delete these folders)
    DOWNLOAD_FOLDERS=(
        "/full/path/to/download/folders/here"
        "/another/full/path/to/download/folders/here"
    )

    # Regular expression for video file extensions
    # (Used to determine if a folder is empty of video files before deleting)
    VIDEO_EXTENSIONS='\.(3gp|3g2|asf|wmv|avi|divx|evo|f4v|flv|h265|hevc|mkv|mk3d|mp4|mpg|mpeg|m2p|ps|ts|m2ts|mxf|ogg|mov|qt|rmvb|vob|webm)$'

# --- CONFIGURATION: DOCKER

elif [ "$RUN_MODE" == "docker" ]; then
    DRY_RUN=${DRY_RUN:-false}
    USE_TRASH=${USE_TRASH:-false}
    TRASH_FOLDER=${TRASH_FOLDER:-""}
    LOG_FILE=${LOG_FILE:-"$SCRIPT_DIR/sweeparr.log"}
    LOG_LEVEL=${LOG_LEVEL:-"INFO"}
    WAIT_TIME=${WAIT_TIME:-45}

    # Ensure TRASH_FOLDER is set if using trash option
    [[ -n "$USE_TRASH" && -z "$TRASH_FOLDER" ]] && handle_error "TRASH_FOLDER environment variable is not set even though USE_TRASH is on. Exiting."

    # shellcheck disable=SC2178
    DOWNLOAD_FOLDERS=${DOWNLOAD_FOLDERS:-""}

    # Load YAML list from docker-compose to array
    IFS=',' read -r -a DOWNLOAD_FOLDERS <<< "${DOWNLOAD_FOLDERS//[[$'\n'] ]/,}" || handle_error "Failed setting DOWNLOAD_FOLDERS from ENV. Did you specify them in Docker command/compose?"
    unset IFS

    # Regular expression for video file extensions
    VIDEO_EXTENSIONS=${VIDEO_EXTENSIONS:-'\.(3gp|3g2|asf|wmv|avi|divx|evo|f4v|flv|h265|hevc|mkv|mk3d|mp4|mpg|mpeg|m2p|ps|ts|m2ts|mxf|ogg|mov|qt|rmvb|vob|webm)$'}
fi

# --- CHECKS

# Ensure TRASH_FOLDER is set if using trash option
[[ -n "$USE_TRASH" && -z "$TRASH_FOLDER" ]] && handle_error "TRASH_FOLDER is not set even though USE_TRASH is on. Exiting."

# Ensure DOWNLOAD_FOLDERS is set
# shellcheck disable=SC2128
[[ -z "$DOWNLOAD_FOLDERS" ]] && handle_error "DOWNLOAD_FOLDERS environment variable is not set. Exiting."

# --- MAIN FUNCTIONS

# Function to set variables based on whether Sonarr or Radarr is calling the script
set_variables() {
    if [[ -n "${sonarr_episodefile_sourcepath:-}" ]]; then
        source_path="$sonarr_episodefile_sourcepath"
        # shellcheck disable=SC2154
        source_folder="$sonarr_episodefile_sourcefolder"
        # shellcheck disable=SC2154
        dest_path="$sonarr_episodefile_path"
        app_name="Sonarr"
    elif [[ -n "${radarr_moviefile_sourcepath:-}" ]]; then
        source_path="$radarr_moviefile_sourcepath"
        # shellcheck disable=SC2154
        source_folder="$radarr_moviefile_sourcefolder"
        # shellcheck disable=SC2154
        dest_path="$radarr_moviefile_path"
        app_name="Radarr"
    else
        handle_error "Neither Sonarr nor Radarr environment variables detected."
    fi

    # Validate the paths
    [[ -z "$source_path" || ! -e "$source_path" ]] && handle_error "Invalid or non-existent source path: $source_path"
    [[ -z "$source_folder" || ! -d "$source_folder" ]] && handle_error "Invalid or non-existent source folder: $source_folder"
    [[ -z "$dest_path" || ! -e "$dest_path" ]] && handle_error "Invalid or non-existent destination path: $dest_path"
}

# Function to check if a folder contains video files recursively
recursive_contains_video_files() {
    local folder="$1"
    if find "$folder" -type f | grep -qE "$VIDEO_EXTENSIONS"; then
        return 0  # True, contains video files
    else
        return 1  # False, doesn't contain video files
    fi
}

# Function to determine operation eligibility and identify highest safe folder
find_safe_parent() {
    local folder="$1"
    local find_safe_parent=""

    # Check if the folder directly matches any protected folder
    for download_folder in "${DOWNLOAD_FOLDERS[@]}"; do
        [[ "$folder" == "$download_folder" ]] && { echo "protected"; return; }
    done

    # Initialize to the source folder in case no higher match is found
    find_safe_parent="$folder"

    # Traverse up from the folder to find the highest safe folder
    while [[ "$folder" != "/" ]]; do
        folder=$(dirname "$folder")
        for download_folder in "${DOWNLOAD_FOLDERS[@]}"; do
            if [[ "$folder" == "$download_folder"* ]]; then
                find_safe_parent="$folder"
                break
            fi
        done
        # If a higher-level matching folder is found, return it
        [[ "$find_safe_parent" != "$folder" ]] && { echo "$find_safe_parent"; return; }
    done

    # If no suitable parent is found, deem the operation outside
    echo "outside"
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

# Function to safely remove files or directories
safe_remove() {
    local target="$1"
    local is_dir="$2"
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
            log_message "DEBUG" "[DRY RUN] Would $operation_desc ($operation_type): $target -> $trashed_name"
        else
            log_message "DEBUG" "[DRY RUN] Would $operation_desc ($operation_type): $target"
        fi
        return 0
    fi

    # Attempt to get the size of the file/folder
    local size
    size=$(du -sb "$target" | cut -f1) || handle_error "Failed to get size for $target"

    # Perform the actual operation based on whether trash is used
    if $USE_TRASH; then
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

# Function to attempt deletion or moving of file and folder
start_cleanup() {
    log_message "INFO" "Checking if deletion/moving is possible..."

    # Always attempt to delete or move the source file first
    if [[ -f "$source_path" ]]; then
        local file_operation_type="single file"
        log_message "INFO" "Attempting to ${USE_TRASH:+move to trash}${USE_TRASH:-delete} ($file_operation_type): $source_path"
        safe_remove "$source_path" false
    else
        log_message "WARNING" "Source file already deleted or moved: $source_path"
    fi

    local target_folder
    target_folder=$(find_safe_parent "$source_folder") || handle_error "Failed to determine safe parent folder"

    case "$target_folder" in
        protected)
            log_message "INFO" "Known download folder, will not be deleted: $source_folder"
            ;;
        outside)
            log_message "WARNING" "Folder outside known locations, will not be deleted: $source_folder"
            ;;
        *)
            log_message "INFO" "Checking for remaining video files in: $target_folder"
            if recursive_contains_video_files "$target_folder"; then
                log_message "INFO" "Video files found. Not ${USE_TRASH:+moving}${USE_TRASH:-deleting} folder: $target_folder"
            else
                local folder_operation_type="folder"
                log_message "INFO" "No video files found. Attempting to ${USE_TRASH:+move to trash}${USE_TRASH:-delete} ($folder_operation_type): $target_folder"
                safe_remove "$target_folder" true
            fi
            ;;
    esac
}

# --- MAIN LOGIC

# Call the function to set variables
set_variables

# Log initial information
log_message "INFO" "Running cleanup script for $app_name"
log_message "INFO" "Source: $source_path"
log_message "INFO" "Destination: $dest_path"
log_message "INFO" "Waiting $WAIT_TIME seconds for operations to complete..."
sleep "$WAIT_TIME" || handle_error "Sleep command failed"

# Initialize statistics
files_deleted=0
dirs_deleted=0
items_trashed=0
space_freed=0

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
