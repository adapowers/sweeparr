# Use an Alpine base image
FROM alpine:latest

# Install necessary packages
RUN apk add --no-cache bash coreutils tini

# Create a shared volume directory
RUN mkdir -p /sweeparr /tmp/sweeparr

# Copy the script and entrypoint into the shared volume directory
COPY /sweeparr.sh /tmp/sweeparr/sweeparr.sh
COPY /docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Make the script and entrypoint executable
RUN chmod +x /tmp/sweeparr/sweeparr.sh /usr/local/bin/docker-entrypoint.sh

# Set environment variable for mode
ENV RUN_MODE=docker

# Use tini as the entrypoint
ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]

# Default command to keep the container running
CMD ["tail", "-f", "/dev/null"]
