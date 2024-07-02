#!/usr/bin/env bash

# Sweeparr for Sonarr/Radarr
# Author: @adapowers
# Version: 2024.01.07
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

# Set default log file if not defined in .env
: "${LOG_FILE:=$SCRIPT_DIR/sweeparr.log}"
# Set default video extensions if not defined in .env
: "${VIDEO_EXTENSIONS:=3gp,3g2,asf,wmv,avi,divx,evo,f4v,flv,h265,hevc,mkv,mk3d,mp4,mpg,mpeg,m2p,ps,ts,m2ts,mxf,ogg,mov,qt,rmvb,vob,webm}"

# Logging configuration
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)

# Function to handle errors
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"  # Default to exit code 1 if not provided
    log_message "ERROR" "$error_message"
    exit "$exit_code"
}

log_message() {
    local level="$1"
    local message="$2"
    local tag="Sweeparr"
    local process="${app_name:+$app_name:}$$"
    
    if [[ ${LOG_LEVELS[$level]} -ge ${LOG_LEVELS[$LOG_LEVEL]} ]]; then
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        
        # Format for log file
        local log_format="[$timestamp] [$level] [$process] $message"
        
        # Format for console
        local console_format="[$tag] [$process] $message"
        
        # Write to log file
        echo "$log_format" >> "$LOG_FILE"
        
        # Write to console
        echo "$console_format"
    fi
}

# Convert comma-separated string to array
IFS=',' read -r -a DOWNLOAD_FOLDERS <<<"$DOWNLOAD_FOLDERS"
unset IFS

if [[ "$USE_TRASH" == true ]]; then
    OPERATION="trash"
else
    OPERATION="delete"
fi

TARGET_FOLDER=""

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
    log_message "DEBUG" "Event type: $event_type"

    # Handle different event types
    case "$event_type" in
    Test)
        log_message "INFO" "Test event detected. Exiting script."
        exit 0
        ;;
    Download)
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

sanitize_and_format_video_extensions() {
    # Remove any surrounding quotes
    VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS#\"}"
    VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS%\"}"

    # Remove spaces and dots
    VIDEO_EXTENSIONS=$(echo "$VIDEO_EXTENSIONS" | tr -d ' .')

    # Replace commas with pipes
    VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS//,/|}"

    # Ensure it's in the correct regex format
    VIDEO_EXTENSIONS="\\.($VIDEO_EXTENSIONS)$"

    log_message "DEBUG" "Formatted VIDEO_EXTENSIONS: $VIDEO_EXTENSIONS"
}

validate_video_extensions() {
    local regex
    regex="^[a-zA-Z0-9,. ]+$"
    if [[ ! "$VIDEO_EXTENSIONS" =~ $regex ]]; then
        log_message "ERROR" "VIDEO_EXTENSIONS contains invalid characters. It should be a comma-separated list of file extensions."
        exit 1
    fi
}

# Function to check if a folder contains video files recursively
recursive_contains_video_files() {
    local folder
    folder=$1

    # returns 0 on true, 1 on false
    find "$folder" -type f | grep -qE "$VIDEO_EXTENSIONS"
}

declare -A trie

# Function to build trie structure for download folders
build_trie() {
    trie=()
    #log_message "DEBUG" "Building trie" # Enable if extra trie debugging needed
    for path in "${DOWNLOAD_FOLDERS[@]}"; do
        local current=""
        for component in ${path//\// }; do
            current+="/$component"
            #log_message "DEBUG" "Checking component: $current" # Enable if extra trie debugging needed
            trie["$current"]=1
        done
        trie["$path:end"]=1
        #log_message "DEBUG" "Added $path to trie" # Enable if extra trie debugging needed
    done
    log_message "DEBUG" "Trie built with keys: ${!trie[*]}"
}

# Function to find the highest safe parent folder
find_safe_parent() {
    local folder="$1"
    local longest_protected=""

    # Check if the folder is a protected folder or its parent
    if [[ ${trie["$folder:end"]:-0} -eq 1 ]] || [[ ${trie["$folder"]:-0} -eq 1 ]]; then
        log_message "DEBUG" "Folder $folder is protected or parent of protected"
        TARGET_FOLDER="protected"
        return
    fi

    # Find the longest protected prefix
    local current=""
    IFS='/' read -ra path_components <<< "$folder"
    for component in "${path_components[@]}"; do
        [[ -z "$component" ]] && continue
        current+="/$component"
        if [[ ${trie["$current"]:-0} -eq 1 ]]; then
            longest_protected="$current"
        fi
    done

    # If no protected prefix found, it's outside
    if [[ -z "$longest_protected" ]]; then
        TARGET_FOLDER="outside"
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
    TARGET_FOLDER="$safe_parent"
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

# Function to handle symbolic links

handle_symlink() {
    local target="$1"

    if [[ ! -L "$target" ]]; then
        log_message "DEBUG" "No symlink found: $target"
        return 1
    fi

    local link_target
    link_target=$(readlink -f "$target") || handle_error "Failed to resolve symlink: $target"
    log_message "INFO" "Handling symbolic link: $target -> $link_target"
    if [[ $DRY_RUN == true ]]; then
            log_message "DEBUG" "[DRY RUN] Would handle symlink: $target -> $link_target"
            return 0  # Pretend handled for dry run
    fi
    if [[ "$USE_TRASH" == true ]]; then
        local trashed_name
        trashed_name=$(generate_trashed_path "$target")
        mv "$target" "$trashed_name" || handle_error "Failed to move symbolic link to trash: $target"
        log_message "INFO" "Moved symbolic link to trash: $target -> $trashed_name"
    else
        rm "$target" || handle_error "Failed to delete symbolic link: $target"
        log_message "INFO" "Deleted symbolic link: $target"
    fi

    return 0
}

# Function to check available space in trash folder
check_trash_quota() {
    local required_space="$1"

    # Get available space in KB
    local available_space
    available_space=$(df -Pk "$TRASH_FOLDER" | awk 'NR==2 {print $4}') || handle_error "Couldn't get available space"

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
    if handle_symlink "$target"; then
        log_message "DEBUG" "Exiting"
        return 0
    fi

    local trashed_name

    if [[ $USE_TRASH == "true" ]]; then
        trashed_name=$(generate_trashed_path "$target") || handle_error "Failed to generate trashed path for $target"
    fi

    if $DRY_RUN; then
        if $USE_TRASH; then
            log_message "DEBUG" "[DRY RUN] Would trash: $target -> $trashed_name"
        else
            log_message "DEBUG" "[DRY RUN] Would delete: $target"
        fi
        return 0
    fi
    
    # Attempt to get the size of the file/folder
    local size
    size=$(du -sb "$target" | cut -f1) || handle_error "Failed to get size for $target"

    if $USE_TRASH; then
        check_trash_quota "$size" || {
            log_message "ERROR" "Not enough space in trash folder to move: $target"
            return 1
        }
        # if $DRY_RUN; then
        #     log_message "INFO" "[DRY RUN] Would try to trash: $target -> $trashed_name"
        #     ((items_trashed++))
        #     ((space_freed += size))
        #     return 0
        # fi
        mv "$target" "$trashed_name" || handle_error "Failed to trash: $target"
        log_message "INFO" "Successfully trashed: $target -> $trashed_name"
        ((items_trashed++))
        ((space_freed += size))
    else
        if [[ "$is_dir" == "true" ]]; then
            # if $DRY_RUN; then
            #     log_message "INFO" "[DRY RUN] Would try to delete: $target"
            #     ((dirs_deleted++))
            #     return 0
            # fi
            rm -r "$target" || handle_error "Failed to delete folder: $target"
            log_message "INFO" "Successfully deleted folder: $target"
            ((dirs_deleted++))
        else
            # if $DRY_RUN; then
            #     log_message "INFO" "[DRY RUN] Would try to delete file: $target"
            #     ((files_deleted++))
            #     return 0
            # fi
            rm "$target" || handle_error "Failed to delete file: $target"
            log_message "INFO" "Successfully deleted file: $target"
            ((files_deleted++))
        fi
        ((space_freed += size))
    fi
}

# Function to check the filesystem type of a path
check_filesystem() {
    local path="$1"
    local fs_type
    fs_type=$(stat -f -c %T "$path")

    log_message "DEBUG" "Filesystem type for $path: $fs_type"

    # List of supported filesystems
    local supported_fs=(
    "ext4" "ext3" "ext2"  # Extended filesystems
    "xfs"                 # XFS
    "btrfs"               # B-tree FS
    "zfs"                 # ZFS
    "ufs"                 # Unix File System
    "jfs"                 # JFS
    "reiserfs"            # ReiserFS
    "ntfs"                # NTFS (via NTFS-3G driver in Linux)
    "vfat" "fat32"        # FAT filesystems
    "exfat"               # exFAT
    "hfs" "hfsplus"       # HFS and HFS+
    "apfs"                # Apple File System
    "f2fs"                # Flash-Friendly File System
    "overlay" "overlayfs" # Overlay Filesystem
    "aufs"                # Another Union FS
    "fuse" "fuseblk"      # FUSE-based filesystems
    "nfs" "nfs4"          # Network File System
    "cifs" "smb"          # CIFS/SMB
    "glusterfs"           # Gluster Filesystem
    "ocfs2"               # Oracle Cluster Filesystem
    )
    local regex
    regex="(^| )${fs_type}( |$)"
    log_message "DEBUG" "Supported filesystems: ${supported_fs[*]}"
    if [[ ! "${supported_fs[*]}" =~ $regex ]]; then
            log_message "WARNING" "Unsupported filesystem ($fs_type) for $path. Operations may fail."
    fi
}

# Function to attempt deletion or moving of file and folder
start_cleanup() {
    log_message "INFO" "Checking if removing is possible..."

    check_filesystem "$source_folder"

    # Attempt to delete or move the source file first
    if [[ -f "$source_path" ]]; then
        log_message "INFO" "Attempting to $OPERATION file: $source_path"
        safe_remove "$source_path" false
    else
        log_message "INFO" "Source file already deleted or moved: $source_path"
    fi

    # Check if the source folder exists before proceeding
    if [[ -d "$source_folder" ]]; then
        log_message "INFO" "Checking to see if folder can be removed: $source_folder"

        # Find the highest parent of $source_folder that can be deleted (if any)
        find_safe_parent "$source_folder" # will output to $TARGET_FOLDER

        case "$TARGET_FOLDER" in
        protected)
            log_message "INFO" "Known download folder, will not be deleted: $source_folder"
            ;;
        outside)
            log_message "INFO" "Folder outside known locations, will not be deleted: $source_folder"
            ;;
        *)
            log_message "INFO" "Checking for remaining video files in: $TARGET_FOLDER"
            if recursive_contains_video_files "$TARGET_FOLDER"; then
                log_message "INFO" "Video files found. Won't $OPERATION folder: $TARGET_FOLDER"
            else
                log_message "INFO" "No video files found. Attempting to $OPERATION folder: $TARGET_FOLDER"

                if [[ -d "$TARGET_FOLDER" ]]; then
                    safe_remove "$TARGET_FOLDER" true
                else
                    log_message "INFO" "Entire source folder already deleted or moved: $TARGET_FOLDER"
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
build_trie

# Prepare video extensions
validate_video_extensions
sanitize_and_format_video_extensions

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
dry_run_tag=""
if [[ $DRY_RUN == true ]]; then
    dry_run_tag="[DRY RUN] "
fi
formatted_space=$(numfmt --to=iec-i --suffix=B "$space_freed") || handle_error "Failed to format space freed"
if $USE_TRASH; then
    summary="${dry_run_tag}Cleanup complete. Items moved to trash: $items_trashed. Space freed: $formatted_space."
else
    summary="${dry_run_tag}Cleanup complete. Files deleted: $files_deleted. Directories deleted: $dirs_deleted. Space freed: $formatted_space."
fi

log_message "INFO" "$summary"
