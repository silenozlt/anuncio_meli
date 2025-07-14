# Uses a lightweight Debian base image, which is good for Bash scripts
FROM debian:stable-slim

# Explicitly set the shell for RUN commands to ensure consistent behavior
SHELL ["/bin/bash", "-c"]

# Defines environment variables to avoid localization warnings and for cron
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo # Define your timezone here, e.g.: America/Sao_Paulo, America/New_York, Europe/London

# Installs necessary dependencies:
# curl: for making HTTP requests
# jq: for parsing JSON
# default-mysql-client: for interacting with MySQL
# cron: for task scheduling
# procps: for the 'ps' command used in some startup scripts
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    default-mysql-client \
    cron \
    procps \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Creates a working directory inside the container
WORKDIR /app

# Copies the Bash script to the working directory
COPY mercadolibre_script.sh /app/mercadolibre_script.sh

# Grants execution permission to the script
RUN chmod +x /app/mercadolibre_script.sh

# Creates a log file for cron and grants permissions
RUN touch /var/log/cron.log && chmod 644 /var/log/cron.log

# Optional: Creates a persistence file for the refresh token
# This file will be used by the Bash script to save the refresh token
RUN touch /app/.ml_refresh_token && chmod 600 /app/.ml_refresh_token

# Exposes a port if the script had a web service, but for this script, it's not necessary.
# EXPOSE 8080

# Container startup command
# If the CRON_SCHEDULE environment variable is defined, it configures cron.
# Otherwise, it runs the script once.
CMD if [ -n "$CRON_SCHEDULE" ]; then \
        echo "$CRON_SCHEDULE /app/mercadolibre_script.sh >> /var/log/cron.log 2>&1" | crontab -; \
        echo "Cron job configured: $CRON_SCHEDULE /app/mercadolibre_script.sh"; \
        cron -f; \
    else \
        echo "CRON_SCHEDULE not defined. Running the script once..."; \
        /app/mercadolibre_script.sh; \
    fi


