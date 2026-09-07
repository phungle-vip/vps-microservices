#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script tự động quét backend microservices và sinh toàn bộ cấu hình đồng bộ:
# 1. services.env
# 2. docker-compose.yml
# 3. nginx/default.conf.template
# 4. cloudflared/setup-tunnel.sh
# 5. webhook/scripts/restart.sh
# 6. infra/vps-infra/central-server-config/consul/KV/<service>.yml & Hot Update
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MICROSERVICES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Tìm thư mục root của repository
if [ -d "$MICROSERVICES_DIR/../../backend" ]; then
  REPO_ROOT="$(cd "$MICROSERVICES_DIR/../.." && pwd)"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT/backend" ]; then
  echo -e "${YELLOW}⚠️ Không tìm thấy thư mục backend! Đang sử dụng đường dẫn tương đối...${NC}"
  REPO_ROOT="$(cd "$MICROSERVICES_DIR/../.." && pwd)"
fi

BACKEND_DIR="$REPO_ROOT/backend"
SERVICES_ENV_FILE="$CONFIG_DIR/services.env"
COMPOSE_FILE="$MICROSERVICES_DIR/docker-compose.yml"
NGINX_TEMPLATE="$CONFIG_DIR/nginx/default.conf.template"
SETUP_TUNNEL_SCRIPT="$CONFIG_DIR/cloudflared/setup-tunnel.sh"
WEBHOOK_RESTART_SCRIPT="$CONFIG_DIR/webhook/scripts/restart.sh"

echo -e "${BLUE}====================================================================${NC}"
echo -e "${CYAN}🚀 BẮT ĐẦU TỰ ĐỘNG PHÁT HIỆN SERVICES & SINH CẤU HÌNH HỆ THỐNG${NC}"
echo -e "${BLUE}====================================================================${NC}"
echo -e "Thư mục Backend: ${GREEN}$BACKEND_DIR${NC}"
echo -e "Thư mục Microservices: ${GREEN}$MICROSERVICES_DIR${NC}"

# 1. Quét tìm tất cả các microservices trong backend/ (loại trừ docker-compose)
DISCOVERED_SERVICES=()
for item in "$BACKEND_DIR"/*; do
  [ -d "$item" ] || continue
  dirname="$(basename "$item")"
  [ "$dirname" = "docker-compose" ] && continue
  
  # Kiểm tra xem thư mục có pom.xml hoặc Dockerfile không
  if [ -f "$item/pom.xml" ] || [ -f "$item/Dockerfile" ] || [ -f "$item/package.json" ]; then
    DISCOVERED_SERVICES+=("$dirname")
  fi
done

echo -e "\n${BLUE}[1/6] Đã phát hiện ${#DISCOVERED_SERVICES[@]} services:${NC} ${GREEN}${DISCOVERED_SERVICES[*]}${NC}"

# Đọc file services.env hiện tại để giữ nguyên port và subdomain cũ nếu đã có
DOMAIN="phungvip.io.vn"
if [ -f "$SERVICES_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$SERVICES_ENV_FILE" 2>/dev/null || true
  set +a
fi
DOMAIN="${DOMAIN:-phungvip.io.vn}"

# 2. Tính toán Port & Subdomain cho từng service
# Dải port mặc định nếu chưa có
declare -A SVC_SUBDOMAIN
declare -A SVC_HOST
declare -A SVC_PORT
declare -A SVC_DB_PORT
declare -A SVC_SERVER_NAME

# Thu thập các port đã được sử dụng để tránh xung đột
USED_APP_PORTS=()
USED_DB_PORTS=()

# Các port tiêu chuẩn mặc định
DEFAULT_PORT_gateway=8080
DEFAULT_PORT_ms_route=8082
DEFAULT_DB_PORT_ms_route=3307
DEFAULT_PORT_ms_user=8083
DEFAULT_DB_PORT_ms_user=3308
DEFAULT_PORT_ms_booking=8084
DEFAULT_DB_PORT_ms_booking=3309
DEFAULT_PORT_ms_promotion=8085
DEFAULT_DB_PORT_ms_promotion=3310

find_next_free_port() {
  local start=$1
  shift
  local used=("$@")
  local candidate=$start
  while true; do
    local conflict=false
    for p in "${used[@]}"; do
      if [ "$p" -eq "$candidate" ]; then
        conflict=true
        break
      fi
    done
    if [ "$conflict" = false ]; then
      echo "$candidate"
      return
    fi
    candidate=$((candidate + 1))
  done
}

# Đăng ký thông tin cho từng service
for svc in "${DISCOVERED_SERVICES[@]}"; do
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  clean_name="$(echo "$svc" | tr -d '_')"

  # Subdomain
  subdomain_var="${svc_upper}_SUBDOMAIN"
  if [ -n "${!subdomain_var:-}" ]; then
    SVC_SUBDOMAIN[$svc]="${!subdomain_var}"
  else
    if [ "$svc" = "gateway" ]; then
      SVC_SUBDOMAIN[$svc]="gateway"
    else
      SVC_SUBDOMAIN[$svc]="$clean_name"
    fi
  fi

  # Host
  SVC_HOST[$svc]="$svc"

  # Server Name
  server_name_var="${svc_upper}_SERVER_NAME"
  if [ -n "${!server_name_var:-}" ]; then
    SVC_SERVER_NAME[$svc]="${!server_name_var}"
  else
    if [ "$svc" = "gateway" ]; then
      SVC_SERVER_NAME[$svc]="apigateway"
    else
      SVC_SERVER_NAME[$svc]="$clean_name"
    fi
  fi

  # App Port
  port_var="${svc_upper}_PORT"
  if [ -n "${!port_var:-}" ]; then
    SVC_PORT[$svc]="${!port_var}"
  else
    def_var="DEFAULT_PORT_${svc}"
    if [ -n "${!def_var:-}" ]; then
      SVC_PORT[$svc]="${!def_var}"
    else
      SVC_PORT[$svc]=""
    fi
  fi
  [ -n "${SVC_PORT[$svc]}" ] && USED_APP_PORTS+=("${SVC_PORT[$svc]}")

  # DB Port (chỉ dành cho microservices khác gateway)
  if [ "$svc" != "gateway" ]; then
    db_port_var="${svc_upper}_DB_PORT"
    if [ -n "${!db_port_var:-}" ]; then
      SVC_DB_PORT[$svc]="${!db_port_var}"
    else
      def_db_var="DEFAULT_DB_PORT_${svc}"
      if [ -n "${!def_db_var:-}" ]; then
        SVC_DB_PORT[$svc]="${!def_db_var}"
      else
        SVC_DB_PORT[$svc]=""
      fi
    fi
    [ -n "${SVC_DB_PORT[$svc]}" ] && USED_DB_PORTS+=("${SVC_DB_PORT[$svc]}")
  fi
done

# Cấp phát port tự động cho các service mới chưa có port
for svc in "${DISCOVERED_SERVICES[@]}"; do
  if [ -z "${SVC_PORT[$svc]}" ]; then
    next_port=$(find_next_free_port 8086 "${USED_APP_PORTS[@]}")
    SVC_PORT[$svc]="$next_port"
    USED_APP_PORTS+=("$next_port")
    echo -e "  -> Cấp phát APP_PORT mới cho [${svc}]: ${GREEN}$next_port${NC}"
  fi

  if [ "$svc" != "gateway" ] && [ -z "${SVC_DB_PORT[$svc]}" ]; then
    next_db_port=$(find_next_free_port 3311 "${USED_DB_PORTS[@]}")
    SVC_DB_PORT[$svc]="$next_db_port"
    USED_DB_PORTS+=("$next_db_port")
    echo -e "  -> Cấp phát DB_PORT mới cho [${svc}]: ${GREEN}$next_db_port${NC}"
  fi
done

# 3. Ghi file services.env
echo -e "\n${BLUE}[2/6] Đang sinh file: ${GREEN}${SERVICES_ENV_FILE}${NC}..."
cat << 'EOF' > "$SERVICES_ENV_FILE"
# ==============================================================================
# RIDEHUB MICROSERVICES - DYNAMIC SERVICE & SUBDOMAIN CONFIGURATION
# File này được sinh tự động bởi script generate-configs.sh
# ==============================================================================

EOF
echo "DOMAIN=$DOMAIN" >> "$SERVICES_ENV_FILE"
echo "" >> "$SERVICES_ENV_FILE"

idx=1
for svc in "${DISCOVERED_SERVICES[@]}"; do
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  echo "# ------------------------------------------------------------------------------" >> "$SERVICES_ENV_FILE"
  echo "# $idx. $svc" >> "$SERVICES_ENV_FILE"
  echo "# ------------------------------------------------------------------------------" >> "$SERVICES_ENV_FILE"
  echo "${svc_upper}_SUBDOMAIN=${SVC_SUBDOMAIN[$svc]}" >> "$SERVICES_ENV_FILE"
  if [ "$svc" = "gateway" ]; then
    echo "GATEWAY_ALT_SUBDOMAIN=${GATEWAY_ALT_SUBDOMAIN:-apigateway}" >> "$SERVICES_ENV_FILE"
  fi
  echo "${svc_upper}_HOST=${SVC_HOST[$svc]}" >> "$SERVICES_ENV_FILE"
  echo "${svc_upper}_PORT=${SVC_PORT[$svc]}" >> "$SERVICES_ENV_FILE"
  if [ "$svc" != "gateway" ]; then
    echo "${svc_upper}_DB_PORT=${SVC_DB_PORT[$svc]}" >> "$SERVICES_ENV_FILE"
  fi
  echo "" >> "$SERVICES_ENV_FILE"
  idx=$((idx + 1))
done

cat << 'EOF' >> "$SERVICES_ENV_FILE"
# ------------------------------------------------------------------------------
# Webhook Service (Quản trị restart container từ xa)
# ------------------------------------------------------------------------------
WEBHOOK_SUBDOMAIN=webhook
WEBHOOK_HOST=restarter
WEBHOOK_PORT=9000
EOF

echo -e "${GREEN}✓ Đã cập nhật services.env thành công.${NC}"

# 4. Sinh file nginx/default.conf.template
echo -e "\n${BLUE}[3/6] Đang sinh file: ${GREEN}${NGINX_TEMPLATE}${NC}..."
cat << 'EOF' > "$NGINX_TEMPLATE"
# ==============================================================================
# RideHub Nginx Configuration Template for Cloudflare Tunnel (vps-microservices)
# Dynamic subdomains and service hosts are injected from services.env
# File này được sinh tự động bởi generate-configs.sh
# ==============================================================================

EOF

# Server block cho Gateway
if [[ " ${DISCOVERED_SERVICES[*]} " =~ " gateway " ]]; then
cat << 'EOF' >> "$NGINX_TEMPLATE"
# ------------------------------------------------------------------------------
# 1. API Gateway & Web Frontend
# ------------------------------------------------------------------------------
server {
    listen 80;
    server_name ${GATEWAY_SUBDOMAIN}.${DOMAIN} ${GATEWAY_ALT_SUBDOMAIN}.${DOMAIN} ${DOMAIN};

    client_max_body_size 50m;

    # Webhook restart (chỉ endpoint quản trị)
    location /admin/restart {
        limit_except GET POST {
            deny all;
        }

        resolver 127.0.0.11 valid=30s ipv6=off;
        set $upstream_restarter http://${WEBHOOK_HOST}:${WEBHOOK_PORT};
        proxy_pass $upstream_restarter/hooks/restart$is_args$args;

        proxy_set_header X-Admin-Token $http_x_admin_token;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    # Gateway proxy
    location / {
        resolver 127.0.0.11 valid=30s ipv6=off;
        set $upstream_gateway http://${GATEWAY_HOST}:${GATEWAY_PORT};
        proxy_pass $upstream_gateway;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;

        proxy_read_timeout 75s;
        proxy_send_timeout 75s;
        proxy_connect_timeout 5s;

        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 2;
    }
}

EOF
fi

# Server block cho từng microservice
ms_idx=2
for svc in "${DISCOVERED_SERVICES[@]}"; do
  [ "$svc" = "gateway" ] && continue
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  clean_name="$(echo "$svc" | tr -d '_')"

  cat << EOF >> "$NGINX_TEMPLATE"
# ------------------------------------------------------------------------------
# $ms_idx. $svc
# ------------------------------------------------------------------------------
server {
    listen 80;
    server_name \${${svc_upper}_SUBDOMAIN}.\${DOMAIN};

    client_max_body_size 50m;

    location / {
        resolver 127.0.0.11 valid=30s ipv6=off;
        set \$upstream_${clean_name} http://\${${svc_upper}_HOST}:\${${svc_upper}_PORT};
        proxy_pass \$upstream_${clean_name};

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 75s;
        proxy_send_timeout 75s;
        proxy_connect_timeout 5s;

        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 2;
    }
}

EOF
  ms_idx=$((ms_idx + 1))
done

# Server block cho Webhook
cat << 'EOF' >> "$NGINX_TEMPLATE"
# ------------------------------------------------------------------------------
# Webhook Service
# ------------------------------------------------------------------------------
server {
    listen 80;
    server_name ${WEBHOOK_SUBDOMAIN}.${DOMAIN};

    client_max_body_size 10m;

    location / {
        resolver 127.0.0.11 valid=30s ipv6=off;
        set $upstream_webhook http://${WEBHOOK_HOST}:${WEBHOOK_PORT};
        proxy_pass $upstream_webhook;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 180s;
        proxy_send_timeout 180s;
    }
}
EOF

echo -e "${GREEN}✓ Đã cập nhật nginx/default.conf.template thành công.${NC}"

# 5. Sinh file docker-compose.yml
echo -e "\n${BLUE}[4/6] Đang sinh file: ${GREEN}${COMPOSE_FILE}${NC}..."
cat << 'EOF' > "$COMPOSE_FILE"
version: '3.8'

# ===== Networks & Volumes =====
networks:
  ticket_net:
    name: ridehub-ms-network
    driver: bridge

# ===== Common anchors =====
x-mysql-env: &mysql_env
  MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-${APP_F4_PASS}}
  TZ: "Asia/Ho_Chi_Minh"

x-mysql-common: &mysql_common
  image: mysql:8.4
  restart: unless-stopped
  networks: [ ticket_net ]
  environment:
    <<: *mysql_env
  command: >
    mysqld
      --lower_case_table_names=1
      --skip-mysqlx
      --skip-name-resolve
      --character_set_server=utf8mb4
      --collation_server=utf8mb4_unicode_ci
      --explicit_defaults_for_timestamp
      --local-infile=1
  healthcheck:
    test: [ "CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$${MYSQL_ROOT_PASSWORD:-$${APP_F4_PASS}}\" --silent || mysqladmin ping -h 127.0.0.1 -uroot --silent" ]
    interval: 5s
    timeout: 5s
    retries: 20
    start_period: 10s
  labels:
    autoheal: "true"

x-common-variables: &common-variables
  SPRING_PROFILES_ACTIVE: ${SPRING_PROFILES_ACTIVE:-prod,api-docs}
  JAVA_OPTIONS: ${JAVA_OPTIONS:-"-Xmx512m -Xms256m"}
  F4_PASSWORD: ${APP_F4_PASS}
  DOMAIN: ${DOMAIN}

services:
  # ===== Auto-heal (restart unhealthy containers) =====
  autoheal:
    image: willfarrell/autoheal:latest
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      AUTOHEAL_INTERVAL: "5"
      AUTOHEAL_START_PERIOD: "0"
      AUTOHEAL_DEFAULT_STOP_TIMEOUT: "70"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  # ===== MySQL Databases =====
EOF

# MySQL container cho từng microservice (trừ gateway)
for svc in "${DISCOVERED_SERVICES[@]}"; do
  [ "$svc" = "gateway" ] && continue
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  cat << EOF >> "$COMPOSE_FILE"
  ${svc}-mysql:
    <<: *mysql_common
    environment:
      <<: *mysql_env
      MYSQL_DATABASE: ${svc}
    ports: [ "127.0.0.1:\${${svc_upper}_DB_PORT:-${SVC_DB_PORT[$svc]}}:3306" ]

EOF
done

cat << 'EOF' >> "$COMPOSE_FILE"
  # ===== Microservices & Gateway =====
EOF

# Gateway Service
if [[ " ${DISCOVERED_SERVICES[*]} " =~ " gateway " ]]; then
cat << 'EOF' >> "$COMPOSE_FILE"
  gateway:
    image: gateway
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      <<: *common-variables
      SERVER_NAME: ${GATEWAY_SERVER_NAME:-apigateway}
      SERVER_PORT: ${GATEWAY_PORT:-8080}
    ports: [ "${GATEWAY_PORT:-8080}:8080" ]
    healthcheck:
      test: [ "CMD", "curl", "-fsS", "http://localhost:${GATEWAY_PORT:-8080}/management/health" ]
      interval: 5s
      timeout: 5s
      retries: 40
    volumes:
      - ./config/microservices/:/app/config/:ro
    labels:
      - autoheal=true
    depends_on:
EOF
  # Gateway depends on all mysqls to be healthy
  for svc in "${DISCOVERED_SERVICES[@]}"; do
    [ "$svc" = "gateway" ] && continue
    echo "      ${svc}-mysql: { condition: service_healthy }" >> "$COMPOSE_FILE"
  done
  echo "" >> "$COMPOSE_FILE"
fi

# Chaining microservices start order:
# gateway -> ms_1 -> ms_2 -> ms_3... to avoid OOM crash on VPS
prev_service="gateway"
for svc in "${DISCOVERED_SERVICES[@]}"; do
  [ "$svc" = "gateway" ] && continue
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  clean_name="$(echo "$svc" | tr -d '_')"

  cat << EOF >> "$COMPOSE_FILE"
  ${svc}:
    image: ${svc}
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      <<: *common-variables
      SERVER_NAME: \${${svc_upper}_SERVER_NAME:-${clean_name}}
      SERVER_PORT: \${${svc_upper}_PORT:-${SVC_PORT[$svc]}}
      SPRING_DATASOURCE_URL: jdbc:mysql://${svc}-mysql:3306/${svc}?useUnicode=true&characterEncoding=utf8&useSSL=false&allowPublicKeyRetrieval=true&createDatabaseIfNotExist=true&allowLoadLocalInfile=true
      SPRING_LIQUIBASE_URL: jdbc:mysql://${svc}-mysql:3306/${svc}?useUnicode=true&characterEncoding=utf8&useSSL=false&allowPublicKeyRetrieval=true&createDatabaseIfNotExist=true&allowLoadLocalInfile=true
    ports:
      - "\${${svc_upper}_PORT:-${SVC_PORT[$svc]}}:${SVC_PORT[$svc]}"
    healthcheck:
      test: [ "CMD", "curl", "-fsS", "http://localhost:\${${svc_upper}_PORT:-${SVC_PORT[$svc]}}/management/health" ]
      interval: 5s
      timeout: 5s
      retries: 40
    volumes:
      - ./config/microservices/:/app/config/:ro
    labels: [ "autoheal=true" ]
    depends_on:
      ${svc}-mysql: { condition: service_healthy }
EOF

  if [ -n "$prev_service" ]; then
    echo "      ${prev_service}: { condition: service_healthy } # chain after ${prev_service}" >> "$COMPOSE_FILE"
  fi
  echo "" >> "$COMPOSE_FILE"
  prev_service="$svc"
done

# Nginx container
cat << 'EOF' >> "$COMPOSE_FILE"
  # ===== Reverse Proxy & Supporting Services =====
  nginx:
    image: nginx:alpine
    container_name: ms-nginx
    restart: unless-stopped
    networks: [ ticket_net ]
    ports:
      - "127.0.0.1:8088:80" # localhost access; public traffic routes via cloudflared tunnel
    env_file:
      - path: ./config/services.env
        required: false
      - path: .env
        required: false
    environment:
      - DOMAIN=${DOMAIN:-phungvip.io.vn}
EOF

# Inject dynamic environment variables for Nginx
for svc in "${DISCOVERED_SERVICES[@]}"; do
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  clean_name="$(echo "$svc" | tr -d '_')"
  echo "      - ${svc_upper}_SUBDOMAIN=\${${svc_upper}_SUBDOMAIN:-${clean_name}}" >> "$COMPOSE_FILE"
  if [ "$svc" = "gateway" ]; then
    echo "      - GATEWAY_ALT_SUBDOMAIN=\${GATEWAY_ALT_SUBDOMAIN:-apigateway}" >> "$COMPOSE_FILE"
  fi
  echo "      - ${svc_upper}_HOST=\${${svc_upper}_HOST:-${svc}}" >> "$COMPOSE_FILE"
  echo "      - ${svc_upper}_PORT=\${${svc_upper}_PORT:-${SVC_PORT[$svc]}}" >> "$COMPOSE_FILE"
done

echo "      - WEBHOOK_SUBDOMAIN=\${WEBHOOK_SUBDOMAIN:-webhook}" >> "$COMPOSE_FILE"
echo "      - WEBHOOK_HOST=\${WEBHOOK_HOST:-restarter}" >> "$COMPOSE_FILE"
echo "      - WEBHOOK_PORT=\${WEBHOOK_PORT:-9000}" >> "$COMPOSE_FILE"

# Sinh NGINX_ENVSUBST_FILTER
filter_vars="DOMAIN"
for svc in "${DISCOVERED_SERVICES[@]}"; do
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  filter_vars="$filter_vars ${svc_upper}_SUBDOMAIN"
  if [ "$svc" = "gateway" ]; then
    filter_vars="$filter_vars GATEWAY_ALT_SUBDOMAIN"
  fi
  filter_vars="$filter_vars ${svc_upper}_HOST ${svc_upper}_PORT"
done
filter_vars="$filter_vars WEBHOOK_SUBDOMAIN WEBHOOK_HOST WEBHOOK_PORT"

echo "      - NGINX_ENVSUBST_FILTER=$filter_vars" >> "$COMPOSE_FILE"

cat << 'EOF' >> "$COMPOSE_FILE"
    volumes:
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/default.conf.template:/etc/nginx/templates/default.conf.template:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      gateway: { condition: service_healthy }
    labels:
      autoheal: "true"

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: ms-cloudflared
    restart: unless-stopped
    networks: [ ticket_net ]
    command: tunnel --config /etc/cloudflared/config.yml --no-autoupdate run
    volumes:
      - ./config/cloudflared:/etc/cloudflared:ro
    depends_on:
      - nginx
    labels:
      autoheal: "true"

  docker_api:
    image: tecnativa/docker-socket-proxy:latest
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      CONTAINERS: 1
      POST: 1
      EXEC: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels: [ "autoheal=true" ]

  restarter:
    build: ./config/webhook
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      ADMIN_TOKEN: f4security
    volumes:
      - ./config/webhook/hooks.json:/etc/webhook/hooks.json:ro
      - ./config/webhook/scripts:/scripts:ro
      - ./config/webhook/triggers:/triggers
    command: [ "-verbose", "-hooks=/etc/webhook/hooks.json", "-hotreload", "-debug" ]
    depends_on:
      - docker_api
    labels: [ "autoheal=true" ]
EOF

echo -e "${GREEN}✓ Đã cập nhật docker-compose.yml thành công.${NC}"

# 6. Cập nhật cloudflared/setup-tunnel.sh
if [ -f "$SETUP_TUNNEL_SCRIPT" ]; then
  echo -e "\n${BLUE}[5/6] Cập nhật danh sách DNS trong: ${GREEN}${SETUP_TUNNEL_SCRIPT}${NC}..."
  
  # Tạo danh sách subdomain
  dns_subdomains_block="SUBDOMAINS=(\n"
  for svc in "${DISCOVERED_SERVICES[@]}"; do
    svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
    clean_name="$(echo "$svc" | tr -d '_')"
    if [ "$svc" = "gateway" ]; then
      dns_subdomains_block+="  \"\${GATEWAY_SUBDOMAIN:-gateway}.\${DOMAIN}\"\n"
      dns_subdomains_block+="  \"\${GATEWAY_ALT_SUBDOMAIN:-apigateway}.\${DOMAIN}\"\n"
    else
      dns_subdomains_block+="  \"\${${svc_upper}_SUBDOMAIN:-${clean_name}}.\${DOMAIN}\"\n"
    fi
  done
  dns_subdomains_block+="  \"\${WEBHOOK_SUBDOMAIN:-webhook}.\${DOMAIN}\"\n"
  dns_subdomains_block+="  \"\${DOMAIN}\"\n"
  dns_subdomains_block+=")"

  # Thay thế block SUBDOMAINS=(...) trong setup-tunnel.sh
  python3 -c "
import re
path = '$SETUP_TUNNEL_SCRIPT'
with open(path, 'r') as f:
    content = f.read()

replacement = '''$dns_subdomains_block'''
content = re.sub(r'SUBDOMAINS=\([^)]*\)', replacement, content, count=1)

with open(path, 'w') as f:
    f.write(content)
"
  echo -e "${GREEN}✓ Đã đồng bộ danh sách DNS routes trong setup-tunnel.sh.${NC}"
fi

# 7. Cập nhật webhook/scripts/restart.sh
if [ -f "$WEBHOOK_RESTART_SCRIPT" ]; then
  echo -e "\n${BLUE}[6/6] Cập nhật webhook targets trong: ${GREEN}${WEBHOOK_RESTART_SCRIPT}${NC}..."
  
  # Tạo đoạn case và for loop
  case_entries=""
  all_targets=""
  for svc in "${DISCOVERED_SERVICES[@]}"; do
    all_targets="$all_targets $svc"
    if [ "$svc" = "gateway" ]; then
      case_entries+="  gateway)      SVCS_APP=\"gateway\";      SVC_DB=\"\";                   DBNAME=\"\" ;;\n"
    else
      case_entries+="  ${svc})     SVCS_APP=\"${svc}\";     SVC_DB=\"${svc}-mysql\";     DBNAME=\"${svc}\" ;;\n"
    fi
  done

  python3 -c "
import re
path = '$WEBHOOK_RESTART_SCRIPT'
with open(path, 'r') as f:
    content = f.read()

new_case = '''case \"\$TARGET\" in
$case_entries  all)
    # For 'all', we’ll process each group sequentially
    for t in$all_targets; do
      \"\$0\" \"\$t\" || true
    done
    echo \"ok\"
    exit 0
    ;;
  *) echo \"unknown target: \$TARGET\"; exit 2 ;;
esac'''

content = re.sub(r'case \"\$TARGET\" in.*?esac', new_case, content, flags=re.DOTALL, count=1)

with open(path, 'w') as f:
    f.write(content)
"
  echo -e "${GREEN}✓ Đã đồng bộ webhook targets trong restart.sh.${NC}"
fi

# 8. Đồng bộ & Khởi tạo cấu hình Consul KV (Centralized External Configuration)
echo -e "\n${BLUE}[6/6] Kiểm tra & Đồng bộ cấu hình Consul KV tập trung...${NC}"
CONSUL_TOKEN="${CONSUL_TOKEN:-f4security}"
CONSUL_URL="https://consul.${DOMAIN}"
CENTRAL_KV_DIR="$REPO_ROOT/infra/vps-infra/central-server-config/consul/KV"
mkdir -p "$CENTRAL_KV_DIR"

for svc in "${DISCOVERED_SERVICES[@]}"; do
  clean_name="$(echo "$svc" | tr -d '_')"
  [ "$svc" = "gateway" ] && clean_name="apigateway"
  app_port="${SVC_PORT[$svc]:-8080}"
  db_port="${SVC_DB_PORT[$svc]:-3306}"

  if command -v curl >/dev/null 2>&1; then
    echo -n "  -> Kiểm tra KV [${clean_name}] trên Consul (${CONSUL_URL})... "
    http_code=$(curl -s -k -o /dev/null -w "%{http_code}" \
      -H "X-Consul-Token: ${CONSUL_TOKEN}" \
      "${CONSUL_URL}/v1/kv/config/${clean_name}/data" 2>/dev/null || true)
    http_code="${http_code:-000}"
    http_code="${http_code: -3}"

    if [ "$http_code" = "200" ]; then
      echo -e "${GREEN}Đã tồn tại (HTTP 200). Giữ nguyên (quản lý qua Consul UI)${NC}"
    elif [ "$http_code" = "404" ]; then
      echo -e "${YELLOW}Chưa có (HTTP 404). Đang khởi tạo từ template...${NC}"
      kv_file="$CENTRAL_KV_DIR/${clean_name}.yml"

      # Nếu chưa có file tĩnh, tạo file tĩnh từ template
      if [ ! -f "$kv_file" ]; then
        if [ "$svc" = "gateway" ]; then
          cat << 'GATEWAY_EOF' > "$kv_file"
server:
  port: 8080

spring:
  cloud:
    gateway:
      default-filters:
        - TokenRelay
      discovery:
        locator:
          enabled: true
          lower-case-service-id: true
          predicates:
            - name: Path
              args:
                pattern: "'/services/'+serviceId.toLowerCase()+'/**'"
          filters:
            - StripPrefix=2
      httpclient:
        pool:
          max-connections: 1000

jhipster:
  clientApp:
    name: 'gatewayApp'
  cors:
    allowed-origins: "http://localhost:5173,http://localhost:8100,http://localhost:9000,https://apigateway.phungvip.io.vn"
    allowed-methods: "*"
    allowed-headers: "*"
    exposed-headers: "Authorization,Link,X-Total-Count,X-${jhipster.clientApp.name}-alert,X-${jhipster.clientApp.name}-error,X-${jhipster.clientApp.name}-params"
    allow-credentials: true
    max-age: 1800
GATEWAY_EOF
        else
          cat << TEMPLATE_EOF > "$kv_file"
server:
  port: ${app_port}

spring:
  application:
    name: ${clean_name}
  datasource:
    url: jdbc:mysql://${svc}-mysql:3306/${svc}?useUnicode=true&characterEncoding=utf8&useSSL=false&allowPublicKeyRetrieval=true&createDatabaseIfNotExist=true
    username: root
    password: \${APP_F4_PASS}
  jpa:
    database-platform: org.hibernate.dialect.MySQLDialect
    hibernate:
      ddl-auto: validate
  cloud:
    function:
      definition: kafkaProducer;kafkaConsumer;dlqConsumer
    stream:
      bindings:
        kafkaConsumer-in-0:
          destination: \${server.name}.events
          content-type: application/*+avro
          group: \${server.name}-group
          consumer:
            use-native-decoding: true
            max-attempts: 3
            back-off-initial-interval: 1000
            back-off-multiplier: 2.0
            back-off-max-interval: 10000
            enable-dlq: true
            dlq-name: \${server.name}.events.dlq
            republish-to-dlq: true
            concurrency: 2

        kafkaProducer-out-0:
          destination: \${server.name}.events
          contentType: application/*+avro
          producer:
            useNativeEncoding: true

        dlqConsumer-in-0:
          destination: \${server.name}.events.dlq
          content-type: application/octet-stream
          group: \${server.name}-dlq-group
          consumer:
            use-native-decoding: true
            max-attempts: 1

      kafka:
        bindings:
          kafkaConsumer-in-0:
            consumer:
              enableDlq: true
              dlqName: \${server.name}.events.dlq
              dlqProducerProperties:
                key.serializer: org.apache.kafka.common.serialization.StringSerializer
                value.serializer: org.apache.kafka.common.serialization.ByteArraySerializer

          dlqConsumer-in-0:
            consumer:
              startOffset: latest
TEMPLATE_EOF
        fi
      fi

      # Nạp lần đầu lên Consul KV
      res=$(curl -s -k -w "%{http_code}" -o /dev/null -X PUT \
        -H "X-Consul-Token: ${CONSUL_TOKEN}" \
        --data-binary @"$kv_file" \
        "${CONSUL_URL}/v1/kv/config/${clean_name}/data" 2>/dev/null || true)
      code="${res:-000}"
      code="${code: -3}"
      if [ "$code" = "200" ]; then
        echo -e "     ${GREEN}Khởi tạo thành công lên Consul (HTTP 200)${NC}"
      else
        echo -e "     ${YELLOW}Không thể nạp lên Consul (HTTP ${code})${NC}"
      fi
    else
      echo -e "${YELLOW}Bỏ qua (HTTP ${http_code} - chưa kết nối được Consul)${NC}"
    fi
  fi
done

echo -e "\n${GREEN}====================================================================${NC}"
echo -e "${GREEN}🎉 HOÀN TẤT SINH CẤU HÌNH TỰ ĐỘNG CHO TOÀN BỘ MICROSERVICES!${NC}"
echo -e "${GREEN}====================================================================${NC}"



