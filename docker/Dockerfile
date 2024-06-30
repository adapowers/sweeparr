# Use an Alpine base image
FROM alpine:latest

# Install necessary packages
RUN apk add --no-cache bash coreutils tini

# Create a shared volume directory
RUN mkdir -p /shared/scripts

# Copy the script and entrypoint into the shared volume directory
COPY ../sweeparr.sh /shared/scripts/sweeparr.sh
COPY ./docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Make the script and entrypoint executable
RUN chmod +x /shared/scripts/sweeparr.sh /usr/local/bin/docker-entrypoint.sh

# Set environment variable for mode
ENV RUN_MODE=docker

# Direct logs to container stdout unless customized
ENV LOG_FILE=/proc/1/fd/1

# Use tini as the entrypoint
ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]

# Default command to keep the container running
CMD ["tail", "-f", "/dev/null"]
