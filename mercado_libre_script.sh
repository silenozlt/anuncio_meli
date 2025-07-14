#!/bin/bash

# Script para consultar todos os produtos de um seller e salvar/atualizar no MySQL
# Foco nos dados essenciais: status, estoque, preço, vendas
# INCLUI REVALIDAÇÃO DO ACCESS_TOKEN A CADA 50 SOLICITAÇÕES
# VERSÃO OTIMIZADA: Com renovação preventiva de token mais frequente e persistência do refresh token
# NOVIDADE: Adicionada verificação e criação da tabela 'produtos_ml' se não existir.
# ALTERADO: Agora grava produtos com estoque zero no MySQL.
# NOVO: Implementada abordagem com search_type=scan para lidar com mais de 1000 registros
# MODIFICADO: Coleta todos os produtos juntos, sem distinguir por status
# ATENÇÃO: Variáveis de configuração agora lidas de variáveis de ambiente para segurança.

# --- Variáveis de Configuração do Mercado Livre (Lidas de variáveis de ambiente) ---
CLIENT_ID="${CLIENT_ID}"
CLIENT_SECRET="${CLIENT_SECRET}"
REFRESH_TOKEN="${REFRESH_TOKEN}" # Este valor será sobrescrito se um refresh token for encontrado no arquivo de persistência.
SELLER_ID="${SELLER_ID}"
BASE_URL="https://api.mercadolibre.com"

# --- Variáveis de Configuração do MySQL (Lidas de variáveis de ambiente) ---
DB_HOST="${DB_HOST}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_NAME="${DB_NAME}"
DB_TABLE="produtos_meli" # Mantido fixo ou pode ser variável de ambiente também

# --- Cores ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Variáveis para controle de token ---
ACCESS_TOKEN=""
REQUEST_COUNT=0
TOKEN_REFRESH_INTERVAL=50 # Renovar token a cada 50 requests
REFRESH_TOKEN_FILE="/app/.ml_refresh_token" # Caminho para o arquivo de persistência do refresh token dentro do container

# --- Função para Refresh do Token ---
refresh_access_token() {
    echo -e "${YELLOW}🔄 Tentando revalidar o Access Token...${NC}"

    TOKEN_RESPONSE=$(curl -s -X POST \
        "$BASE_URL/oauth/token" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "grant_type=refresh_token&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&refresh_token=$REFRESH_TOKEN")

    if ! echo "$TOKEN_RESPONSE" | jq empty 2>/dev/null; then
        echo -e "${RED}❌ Erro ao obter novo token: Resposta inválida da API.${NC}"
        echo "Resposta da API: $TOKEN_RESPONSE"
        exit 1
    fi

    NEW_ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // ""')
    NEW_REFRESH_TOKEN_FROM_API=$(echo "$TOKEN_RESPONSE" | jq -r '.refresh_token // ""')
    EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // 0')

    if [ -z "$NEW_ACCESS_TOKEN" ]; then
        echo -e "${RED}❌ Falha ao revalidar o Access Token. Verifique CLIENT_ID, CLIENT_SECRET ou REFRESH_TOKEN.${NC}"
        echo "Resposta da API: $TOKEN_RESPONSE"
        exit 1
    else
        ACCESS_TOKEN="$NEW_ACCESS_TOKEN"
        REQUEST_COUNT=0 # Reset contador após renovação

        # Persistir o novo refresh token se ele for diferente
        if [ -n "$NEW_REFRESH_TOKEN_FROM_API" ] && [ "$NEW_REFRESH_TOKEN_FROM_API" != "$REFRESH_TOKEN" ]; then
            REFRESH_TOKEN="$NEW_REFRESH_TOKEN_FROM_API" # Atualiza a variável no script
            echo "$NEW_REFRESH_TOKEN_FROM_API" > "$REFRESH_TOKEN_FILE"
            echo -e "${GREEN}✅ Novo Refresh Token salvo em $REFRESH_TOKEN_FILE${NC}"
        fi

        echo -e "${GREEN}✅ Access Token revalidado com sucesso! Expira em ${EXPIRES_IN} segundos.${NC}"
    fi
}

# --- Função para verificar se precisa renovar token ---
check_token_renewal() {
    if [ $REQUEST_COUNT -ge $TOKEN_REFRESH_INTERVAL ]; then
        echo -e "${YELLOW}🔄 Renovando token preventivamente após $REQUEST_COUNT requests...${NC}"
        refresh_access_token
    fi
}

# --- Função para executar comandos SQL e retornar o resultado limpo (para SELECTs) ---
execute_sql_query() {
    local sql_query="$1"
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -Bse "$sql_query" 2>/dev/null | tr -d '\n' | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# --- Função para executar comandos SQL (INSERT/UPDATE/DELETE) sem retorno de valor ---
execute_sql_command() {
    local sql_command="$1"
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -Bse "$sql_command" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ ERRO FATAL ao executar comando SQL${NC}" >&2
    fi
}

# --- Função para fazer requisições API com controle de token ---
make_api_request() {
    local url="$1"
    local max_retries=3
    local retry_count=0
    local wait_time=2

    # Incrementar contador de requests
    ((REQUEST_COUNT++))

    # Verificar se precisa renovar token
    check_token_renewal

    while [ $retry_count -lt $max_retries ]; do
        local response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            "$url")

        local http_status=$(echo "$response" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
        local body=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')

        if [ "$http_status" = "200" ]; then
            echo "$body"
            return 0
        elif [ "$http_status" = "429" ]; then
            echo -e "${YELLOW}⚠️ Rate limit atingido (429). Aguardando ${wait_time}s antes da próxima tentativa...${NC}" >&2
            sleep $wait_time
            retry_count=$((retry_count + 1))
            wait_time=$((wait_time * 2)) # Backoff exponencial
        elif [ "$http_status" = "400" ]; then
            echo -e "${RED}❌ Erro HTTP 400 (Bad Request) para URL: $url. Tentativa $((retry_count + 1))/${max_retries}${NC}" >&2
            echo -e "${RED}Corpo da resposta 400: $body${NC}" >&2 # Log do corpo da resposta

            sleep $wait_time
            retry_count=$((retry_count + 1))
            wait_time=$((wait_time * 2))
        elif [ "$http_status" = "401" ]; then
            echo -e "${RED}❌ Erro HTTP 401 (Unauthorized). Renovando token...${NC}" >&2
            refresh_access_token
            retry_count=$((retry_count + 1))
        elif [ "$http_status" = "500" ] || [ "$http_status" = "502" ] || [ "$http_status" = "503" ]; then
            echo -e "${RED}❌ Erro do servidor HTTP $http_status. Tentativa $((retry_count + 1))/${max_retries}${NC}" >&2
            sleep $wait_time
            retry_count=$((retry_count + 1))
            wait_time=$((wait_time * 2))
        else
            echo -e "${RED}❌ Erro HTTP $http_status. Tentativa $((retry_count + 1))/${max_retries}${NC}" >&2
            sleep $wait_time
            retry_count=$((retry_count + 1))
            wait_time=$((wait_time * 2))
        fi
    done

    echo -e "${RED}❌ Falha após $max_retries tentativas para URL: $url${NC}" >&2
    return 1
}

# --- Função para buscar todos os produtos com search_type=scan (sem filtro de status) ---
collect_all_product_ids_with_scan() {
    local temp_file="$1"

    echo -e "${YELLOW}📋 Coletando todos os IDs com search_type=scan (sem filtro de status)${NC}"

    local total_collected=0
    local scroll_id=""
    local page_count=0

    # Primeira requisição com search_type=scan (SEM filtro de status)
    local request_url="$BASE_URL/users/$SELLER_ID/items/search?search_type=scan"

    echo -e "${BLUE}📦 Iniciando coleta unificada com search_type=scan${NC}"

    while true; do
        ((page_count++))

        # Se temos scroll_id, usar ele na requisição
        if [ -n "$scroll_id" ]; then
            request_url="$BASE_URL/users/$SELLER_ID/items/search?search_type=scan&scroll_id=$scroll_id"
        fi

        if [ $((REQUEST_COUNT % 50)) -eq 0 ]; then
            echo -e "${BLUE}📊 Requests realizados: $REQUEST_COUNT | Página: $page_count | Total coletado: $total_collected${NC}"
        fi

        # Fazer requisição
        local response=$(make_api_request "$request_url")
        local api_status=$?

        if [ "$api_status" -eq 0 ] && echo "$response" | jq empty 2>/dev/null; then
            # Extrair IDs dos resultados
            local current_ids=$(echo "$response" | jq -r '.results[]?' 2>/dev/null)

            # Extrair novo scroll_id para próxima requisição
            local new_scroll_id=$(echo "$response" | jq -r '.scroll_id // ""' 2>/dev/null)

            if [ -n "$current_ids" ]; then
                echo "$current_ids" >> "$temp_file"
                local ids_count=$(echo "$current_ids" | wc -l)
                total_collected=$((total_collected + ids_count))

                echo -e "${GREEN}✅ Página $page_count: $ids_count IDs coletados (Total: $total_collected)${NC}"
            else
                echo -e "${YELLOW}⚠️ Nenhum ID retornado na página $page_count${NC}"
            fi

            # Verificar se temos um novo scroll_id
            if [ -n "$new_scroll_id" ] && [ "$new_scroll_id" != "null" ]; then
                scroll_id="$new_scroll_id"
                echo -e "${BLUE}🔄 Novo scroll_id obtido para próxima página${NC}"
            else
                echo -e "${GREEN}✅ Fim da coleta - scroll_id expirou ou chegou ao fim${NC}"
                break
            fi
        else
            echo -e "${RED}❌ Erro na requisição de coleta com scan na página $page_count${NC}"
            break
        fi

        # Sleep entre requisições
        sleep 1.5
    done

    echo -e "${GREEN}📊 Coleta finalizada: $total_collected IDs em $page_count páginas${NC}"
    return $total_collected
}

# --- Função para verificar e criar a tabela MySQL se não existir ---
check_and_create_table() {
    echo -e "${BLUE}⚙️ Verificando se a tabela '$DB_TABLE' existe no banco de dados '$DB_NAME'...${NC}"

    TABLE_EXISTS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -Bse "SHOW TABLES LIKE '$DB_TABLE';" 2>/dev/null)

    if [ -z "$TABLE_EXISTS" ]; then
        echo -e "${YELLOW}⚠️ Tabela '$DB_TABLE' não encontrada. Criando a tabela...${NC}"
        local CREATE_TABLE_SQL="CREATE TABLE \`$DB_TABLE\` (
            \`ID\` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL,
            \`Titulo\` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
            \`status_atual\` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL,
            \`status_anterior\` varchar(20) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
            \`Estoque\` int(11) DEFAULT NULL,
            \`Preco\` decimal(10,2) DEFAULT NULL,
            \`Vendas\` int(11) DEFAULT NULL,
            PRIMARY KEY (\`ID\`)
        ) ENGINE=MyISAM DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"

        execute_sql_command "$CREATE_TABLE_SQL"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Tabela '$DB_TABLE' criada com sucesso!${NC}"
        else
            echo -e "${RED}❌ Erro ao criar a tabela '$DB_TABLE'. Verifique as permissões do usuário MySQL e a sintaxe SQL.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}✅ Tabela '$DB_TABLE' já existe.${NC}"
    fi
}

echo -e "${YELLOW}🔍 Buscando todos os produtos do seller: $SELLER_ID${NC}"
echo -e "${BLUE}⚙️ Configuração: Renovação de token a cada $TOKEN_REFRESH_INTERVAL requests${NC}"
echo -e "${BLUE}🆕 Usando search_type=scan para coleta unificada (todos os status)${NC}"
echo "=================================================="

# Verificar se as variáveis de ambiente essenciais estão definidas
if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$REFRESH_TOKEN" ] || [ -z "$SELLER_ID" ] || \
   [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
    echo -e "${RED}❌ Erro: Uma ou mais variáveis de ambiente de configuração estão faltando.${NC}"
    echo "Certifique-se de definir CLIENT_ID, CLIENT_SECRET, REFRESH_TOKEN, SELLER_ID, DB_HOST, DB_USER, DB_PASS, DB_NAME."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq não está instalado${NC}"
    echo "Instale com: sudo apt install jq"
    exit 1
fi

if ! command -v mysql &> /dev/null; then
    echo -e "${RED}❌ mysql client não está instalado${NC}"
    echo "Instale com: sudo apt install mysql-client"
    exit 1
fi

# --- Carregar Refresh Token do arquivo se existir ---
# O caminho é absoluto dentro do ambiente do usuário
if [ -f "$REFRESH_TOKEN_FILE" ]; then
    REFRESH_TOKEN=$(cat "$REFRESH_TOKEN_FILE")
    echo -e "${BLUE}ℹ️ Refresh Token carregado do arquivo: $REFRESH_TOKEN_FILE${NC}"
else
    echo -e "${YELLOW}⚠️ Nenhum Refresh Token salvo encontrado. Usando o valor da variável de ambiente.${NC}"
fi

# --- VERIFICAR E CRIAR TABELA MySQL ---
check_and_create_table

# --- PRIMEIRA RENOVAÇÃO DO TOKEN ---
refresh_access_token

# ========================================
# FASE 1: COLETAR TODOS OS IDs DOS PRODUTOS COM SCAN (UNIFICADO)
# ========================================

echo -e "${YELLOW}📋 FASE 1: Coletando todos os IDs dos produtos com search_type=scan...${NC}"

# Criar arquivo temporário para IDs
temp_ids_file="/tmp/ml_product_ids_$$"
> "$temp_ids_file" # Limpa o arquivo antes de começar

# Coletar todos os IDs sem filtro de status
collect_all_product_ids_with_scan "$temp_ids_file"
total_ids_collected=$?

# Remover IDs duplicados, caso existam
sort -u "$temp_ids_file" -o "$temp_ids_file"
total_ids_collected_unique=$(wc -l < "$temp_ids_file")

echo ""
echo -e "${GREEN}📦 RESUMO DA COLETA DE IDs COM SCAN:${NC}"
echo "=================================================="
echo -e "Total de IDs coletados: ${GREEN}$total_ids_collected${NC}"
echo -e "Total de IDs únicos coletados: ${GREEN}$total_ids_collected_unique${NC}"
echo -e "Requests realizados: ${BLUE}$REQUEST_COUNT${NC}"

# ========================================
# FASE 2: BAIXAR DETALHES DOS PRODUTOS
# ========================================

echo -e "${YELLOW}🚀 FASE 2: Baixando detalhes dos produtos...${NC}"
echo "=================================================="

# Ler IDs do arquivo (agora com IDs únicos)
mapfile -t item_ids_array < "$temp_ids_file"
total_to_process=${#item_ids_array[@]}

# Array para dados dos produtos
declare -A products_data
count=0
active=0
paused=0
closed=0
errors=0
under_review_count=0

for item_id in "${item_ids_array[@]}"; do
    # Limpar ID
    item_id=$(echo "$item_id" | tr -d '\n\r ' | sed 's/[[:space:]]*$//')

    if [ -z "$item_id" ]; then
        continue
    fi

    ((count++))

    # Fazer requisição dos detalhes
    product=$(make_api_request "$BASE_URL/items/$item_id" 2>/dev/null)

    if [ $? -eq 0 ] && echo "$product" | jq empty 2>/dev/null; then
        status=$(echo "$product" | jq -r '.status // "N/A"')
        estoque=$(echo "$product" | jq -r '.available_quantity // 0')
        preco=$(echo "$product" | jq -r '.price // 0.0' | sed 's/,/./g')
        vendas=$(echo "$product" | jq -r '.sold_quantity // 0')
        titulo=$(echo "$product" | jq -r '.title // "N/A"' | sed 's/[",]//g' | cut -c1-255)

        # Armazenar dados
        products_data["$item_id"]="$status|$estoque|$preco|$vendas|$titulo"

        case $status in
            "active") ((active++)) ;;
            "paused") ((paused++)) ;;
            "closed") ((closed++)) ;;
            "under_review") ((under_review_count++)) ;;
        esac
    else
        ((errors++))
        products_data["$item_id"]="ERROR|0|0|0|Erro na consulta"
    fi

    # Mostrar progresso a cada 25 produtos processados
    if [ $((count % 25)) -eq 0 ]; then
        percentage=$((count * 100 / total_to_process))
        echo -e "${BLUE}📊 Progresso: $count/$total_to_process ($percentage%) | Req: $REQUEST_COUNT | Ativos: $active | Pausados: $paused | Fechados: $closed | Em Revisão: $under_review_count | Erros: $errors${NC}"
    fi

    # Sleep entre requisições
    if [ "$count" -lt "$total_to_process" ]; then
        sleep 0.7
    fi
done

# Limpeza do arquivo temporário
rm -f "$temp_ids_file"

echo ""
echo -e "${GREEN}📊 RESUMO DOS DOWNLOADS:${NC}"
echo "=================================================="
echo -e "Total baixados: ${GREEN}$count${NC}"
echo -e "Ativos: ${GREEN}$active${NC}"
echo -e "Pausados: ${YELLOW}$paused${NC}"
echo -e "Fechados: ${RED}$closed${NC}"
echo -e "Em Revisão: ${YELLOW}$under_review_count${NC}"
echo -e "Erros: ${RED}$errors${NC}"
echo -e "Total requests: ${BLUE}$REQUEST_COUNT${NC}"
echo ""

# ========================================
# FASE 3: GRAVAR NO BANCO DE DADOS
# ========================================

echo -e "${YELLOW}💾 FASE 3: Gravando dados no MySQL...${NC}"
echo "=================================================="

processed_db=0
updated_db=0
inserted_db=0
errors_db=0

for item_id in "${item_ids_array[@]}"; do
    # Limpar ID
    item_id=$(echo "$item_id" | tr -d '\n\r ' | sed 's/[[:space:]]*$//')

    if [ -z "$item_id" ]; then
        continue
    fi

    ((processed_db++))

    # Recuperar dados
    product_data="${products_data[$item_id]}"

    if [ -z "$product_data" ]; then
        ((errors_db++))
        continue
    fi

    # Separar dados
    IFS='|' read -r new_status estoque preco vendas titulo <<< "$product_data"

    # Verificar se produto já existe
    OLD_STATUS=$(execute_sql_query "SELECT status_atual FROM $DB_TABLE WHERE ID = '$item_id'" 2>/dev/null)

    if [ -n "$OLD_STATUS" ]; then
        SQL_QUERY="UPDATE $DB_TABLE SET status_anterior = '$OLD_STATUS', status_atual = '$new_status', Estoque = $estoque, Preco = $preco, Vendas = $vendas, Titulo = '$titulo' WHERE ID = '$item_id';"
        ((updated_db++))
    else
        SQL_QUERY="INSERT INTO $DB_TABLE (ID, Titulo, status_atual, status_anterior, Estoque, Preco, Vendas) VALUES ('$item_id', '$titulo', '$new_status', NULL, $estoque, $preco, $vendas);"
        ((inserted_db++))
    fi

    execute_sql_command "$SQL_QUERY" >/dev/null 2>&1

    # Mostrar progresso a cada 50 registros processados
    if [ $((processed_db % 50)) -eq 0 ]; then
        percentage=$((processed_db * 100 / total_to_process))
        echo -e "${BLUE}💾 Progresso DB: $processed_db/$total_to_process ($percentage%) | Inseridos: $inserted_db | Atualizados: $updated_db | Erros: $errors_db${NC}"
    fi
done

echo ""
echo -e "${GREEN}📊 RESUMO FINAL:${NC}"
echo "=================================================="
echo -e "Total IDs únicos coletados: ${GREEN}$total_ids_collected_unique${NC}"
echo -e "Total detalhes baixados: ${GREEN}$count${NC}"
echo -e "Total processados no DB: ${GREEN}$processed_db${NC}"
echo -e "Inseridos: ${GREEN}$inserted_db${NC}"
echo -e "Atualizados: ${YELLOW}$updated_db${NC}"
echo -e "Erros download: ${RED}$errors${NC}"
echo -e "Erros database: ${RED}$errors_db${NC}"
echo -e "Total requests realizados: ${BLUE}$REQUEST_COUNT${NC}"
echo -e "Renovações de token: ${YELLOW}$((REQUEST_COUNT / TOKEN_REFRESH_INTERVAL))${NC}"
echo ""
echo -e "Produtos por status descobertos:"
echo -e "Ativos: ${GREEN}$active${NC}"
echo -e "Pausados: ${YELLOW}$paused${NC}"
echo -e "Fechados: ${RED}$closed${NC}"
echo -e "Em Revisão: ${YELLOW}$under_review_count${NC}"
echo ""

echo -e "${GREEN}✅ Processo concluído com search_type=scan unificado! Dados atualizados no MySQL na tabela '$DB_TABLE'.${NC}"
echo -e "${BLUE}ℹ️ Esta abordagem coleta todos os produtos que a API retorna, independente do status${NC}"



