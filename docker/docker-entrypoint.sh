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

# Set ownership of the shared volume directory
chown -R sweeparr:sweeparr /sweeparr

# Execute the passed command
exec "$@"
