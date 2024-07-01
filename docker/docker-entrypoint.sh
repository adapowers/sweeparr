#!/bin/bash

# Log function for uniform log formatting
log() {
    local message="$1"
    local log_file="${LOG_FILE_PATH:-/sweeparr/sweeparr.log}"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" >> "$log_file"
}

log "Container started or restarted."

# Set PUID and PGID if provided
PUID=${PUID:-1000}
PGID=${PGID:-1000}

# Create group if it doesn't exist
if ! getent group sweeparr >/dev/null 2>&1; then
    addgroup -g "$PGID" sweeparr
fi

# Create user if it doesn't exist
if ! getent passwd sweeparr >/dev/null 2>&1; then
    adduser -D -H -u "$PUID" -G sweeparr sweeparr
fi

# Copy the script from the temporary location to the shared volume directory
cp /tmp/sweeparr/sweeparr.sh /sweeparr/sweeparr.sh
log "Script 'sweeparr.sh' copied to /sweeparr."

# Initialize blank .env config and log files if they don't exist
CONFIG_FILE=${CONFIG_FILE_PATH:-/sweeparr/.env}
LOG_FILE=${LOG_FILE_PATH:-/sweeparr/sweeparr.log}

if [ ! -f "$CONFIG_FILE" ]; then
    cat <<EOF > "$CONFIG_FILE"
# If enabled, will simply tell you the files/folders it would delete
DRY_RUN=true

# Logging level. Options: DEBUG, INFO, WARNING, ERROR
LOG_LEVEL=DEBUG

# Sweeparr will protect deletion of these folders at any cost
DOWNLOAD_FOLDERS="/full/path/to/download/folder,/another/full/path/to/download/folder"

# If enabled, will move to trash folder instead of deleting (you'll be responsible for that)
USE_TRASH=false

# Full path to trash folder (must be writable by Sonarr/Radarr)
TRASH_FOLDER=""

# Time to wait before execution
WAIT_TIME=45
EOF
    chown sweeparr:sweeparr "$CONFIG_FILE"
    log "Log file $CONFIG_FILE created and ownership set to user 'sweeparr'."
fi

# Create the log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chown sweeparr:sweeparr "$LOG_FILE"
    log "Log file $LOG_FILE created and ownership set to user 'sweeparr'."
fi

# Set ownership of the shared volume directory
chown -R sweeparr:sweeparr /sweeparr
log "Set ownership of /sweeparr to user 'sweeparr'."

# Tail the log file in the background to stdout
tail -F "$LOG_FILE" &
log "Started tailing $LOG_FILE to stdout."

# Function to log and execute the command
log_and_exec() {
    log "Executed command: $*"
    exec "$@"
}

# Execute the passed command
log_and_exec "$@"
