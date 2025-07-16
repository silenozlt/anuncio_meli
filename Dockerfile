FROM debian:stable-slim

SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo

RUN apt-get update && apt-get install -y \
    curl \
    jq \
    default-mysql-client \
    procps \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY mercadolibre_script.sh /app/mercadolibre_script.sh

RUN chmod +x /app/mercadolibre_script.sh

RUN mkdir -p /var/log/mercadolibre && chmod 755 /var/log/mercadolibre

RUN touch /app/.ml_refresh_token && chmod 600 /app/.ml_refresh_token

CMD /app/mercadolibre_script.sh >> /var/log/mercadolibre/script.log 2>&1

