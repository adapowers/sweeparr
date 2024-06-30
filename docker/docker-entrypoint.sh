#!/bin/bash

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

# Initialize a blank .env config file if it doesn't exist
CONFIG_FILE=${CONFIG_FILE_PATH:-/sweeparr/.env}

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
    echo "Created a new configuration file at $CONFIG_FILE. Please customize it as needed."
fi

# Set ownership of the shared volume directory
chown -R sweeparr:sweeparr /sweeparr

# Execute the passed command
exec "$@"
