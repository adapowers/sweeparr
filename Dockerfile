# Use an Alpine base image
FROM alpine:latest

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

# Use tini as the entrypoint
ENTRYPOINT ["/sbin/tini", "--"]

# Default command to keep the container running
CMD ["tail", "-f", "/dev/null"]
