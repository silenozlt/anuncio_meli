FROM debian:stable-slim

SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo

RUN apt-get update && apt-get install -y \
    curl \
    jq \
    default-mysql-client \
    cron \
    procps \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY mercadolibre_script.sh /app/mercadolibre_script.sh

RUN chmod +x /app/mercadolibre_script.sh

RUN touch /var/log/cron.log && chmod 644 /var/log/cron.log

RUN touch /app/.ml_refresh_token && chmod 600 /app/.ml_refresh_token

CMD if [ -n "$CRON_SCHEDULE" ]; then \
        echo "$CRON_SCHEDULE /app/mercadolibre_script.sh >> /var/log/cron.log 2>&1" | crontab -; \
        echo "Cron job configured: $CRON_SCHEDULE /app/mercadolibre_script.sh"; \
        cron -f; \
    else \
        echo "CRON_SCHEDULE not defined. Running the script once..."; \
        /app/mercadolibre_script.sh; \
    fi

