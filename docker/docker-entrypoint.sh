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

# Set ownership of the shared volume directory
chown -R sweeparr:sweeparr /sweeparr.sh

# Execute the passed command
exec "$@"
