# Usa uma imagem base leve do Debian, que é boa para scripts Bash
FROM debian:stable-slim

# Define variáveis de ambiente para evitar avisos de localização e para o cron
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo # Defina seu fuso horário aqui, ex: America/Sao_Paulo, America/New_York, Europe/London

# Instala as dependências necessárias:
# curl: para fazer requisições HTTP
# jq: para parsear JSON
# default-mysql-client: para interagir com o MySQL
# cron: para agendamento de tarefas
# procps: para o comando 'ps' usado em alguns scripts de inicialização
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    default-mysql-client \
    cron \
    procps \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Cria um diretório de trabalho dentro do contêiner
WORKDIR /app

# Copia o script Bash para o diretório de trabalho
COPY mercadolibre_script.sh /app/mercadolibre_script.sh

# Dá permissão de execução ao script
RUN chmod +x /app/mercadolibre_script.sh

# Cria um arquivo de log para o cron e dá permissões
RUN touch /var/log/cron.log && chmod 644 /var/log/cron.log

# Opcional: Cria um arquivo de persistência para o refresh token
# Este arquivo será usado pelo script Bash para salvar o refresh token
RUN touch /app/.ml_refresh_token && chmod 600 /app/.ml_refresh_token

# Expõe uma porta se o script tivesse um serviço web, mas para este script, não é necessário.
# EXPOSE 8080

# Comando de inicialização do contêiner
# Se a variável de ambiente CRON_SCHEDULE for definida, configura o cron.
# Caso contrário, executa o script uma única vez.
CMD if [ -n "$CRON_SCHEDULE" ]; then \
        echo "$CRON_SCHEDULE /app/mercadolibre_script.sh >> /var/log/cron.log 2>&1" | crontab -; \
        echo "Cron job configurado: $CRON_SCHEDULE /app/mercadolibre_script.sh"; \
        cron -f; \
    else \
        echo "CRON_SCHEDULE não definido. Executando o script uma vez..."; \
        /app/mercadolibre_script.sh; \
    fi

