# Use an Alpine base image
FROM alpine:latest

# Build arguments for PUID and PGID
ARG PUID=1000
ARG PGID=1000

# Install necessary packages
RUN apk add --no-cache bash coreutils tini

# Create a shared volume directory
RUN mkdir -p /shared/scripts

# Copy the script into the shared volume directory
COPY sweeparr.sh /shared/scripts/sweeparr.sh

# Make the script executable
RUN chmod +x /shared/scripts/sweeparr.sh

# Set environment variable for mode
ENV RUN_MODE=docker

# Direct logs to container stdout unless customized
ENV LOG_FILE=/proc/1/fd/1

# Set ownership of the shared volume directory
RUN chown -R ${PUID}:${PGID} /shared/scripts

# Use tini as the entrypoint
ENTRYPOINT ["/sbin/tini", "--"]

# Default command to keep the container running
CMD ["tail", "-f", "/dev/null"]
