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
GENERATED_DIR="$MICROSERVICES_DIR/.generated"
mkdir -p "$GENERATED_DIR"
SERVICES_ENV_FILE="$GENERATED_DIR/services.env"
COMPOSE_FILE="$MICROSERVICES_DIR/docker-compose.yml"
SERVICES_COMPOSE_FILE="$GENERATED_DIR/docker-compose.services.yml"
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
if [ -f "$MICROSERVICES_DIR/.env" ]; then
  set -a
  source "$MICROSERVICES_DIR/.env" 2>/dev/null || true
  set +a
fi
if [ -f "$SERVICES_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$SERVICES_ENV_FILE" 2>/dev/null || true
  set +a
elif [ -f "$CONFIG_DIR/services.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_DIR/services.env" 2>/dev/null || true
  set +a
fi
if [ -f "$REPO_ROOT/infra/vps-infra/central-server-config/consul/consul-tokens.env" ]; then
  set -a
  source "$REPO_ROOT/infra/vps-infra/central-server-config/consul/consul-tokens.env" 2>/dev/null || true
  set +a
fi
if [ -f "$REPO_ROOT/infra/vps-infra/central-server-config/vault/vault-tokens.env" ]; then
  set -a
  source "$REPO_ROOT/infra/vps-infra/central-server-config/vault/vault-tokens.env" 2>/dev/null || true
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
echo "TZ=\${TZ:-Asia/Ho_Chi_Minh}" >> "$SERVICES_ENV_FILE"
echo "ACTIVE_SERVICES=\"${DISCOVERED_SERVICES[*]}\"" >> "$SERVICES_ENV_FILE"
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
        limit_except GET POST OPTIONS {
            deny all;
        }

        if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, X-Admin-Token';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, X-Admin-Token' always;

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
        if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, X-Admin-Token';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, X-Admin-Token' always;

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

# 5. Sinh file cấu hình microservices: .generated/docker-compose.services.yml
echo -e "\n${BLUE}[4/6] Đang sinh file cấu hình microservices: ${GREEN}${SERVICES_COMPOSE_FILE}${NC}..."
cat << 'EOF' > "$SERVICES_COMPOSE_FILE"
# ===== Common anchors =====
x-mysql-env: &mysql_env
  MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-${APP_F4_PASS}}
  TZ: ${TZ:-Asia/Ho_Chi_Minh}

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
      --default-time-zone=+07:00
  volumes:
    - /etc/localtime:/etc/localtime:ro
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
  JAVA_OPTIONS: ${JAVA_OPTIONS:-"-Xmx512m -Xms256m -Duser.timezone=Asia/Ho_Chi_Minh"}
  TZ: ${TZ:-Asia/Ho_Chi_Minh}
  F4_PASSWORD: ${APP_F4_PASS}
  VAULT_TOKEN: ${VAULT_TOKEN:-${APP_F4_PASS}}
  SPRING_CLOUD_VAULT_TOKEN: ${VAULT_TOKEN:-${APP_F4_PASS}}
  DOMAIN: ${DOMAIN}
  REDIS_HOST: ${REDIS_HOST:-host.docker.internal}
  REDIS_PORT: ${REDIS_PORT:-6379}
  REDIS_PASSWORD: ${APP_F4_PASS}
  KAFKA_BROKERS: ${KAFKA_BROKERS:-kafka.phungvip.io.vn:9093}
  ELASTICSEARCH_URIS: ${ELASTICSEARCH_URIS:-http://host.docker.internal:9200}
  SPRING_CLOUD_CONSUL_HOST: ${CONSUL_HOST:-consul.${DOMAIN}}
  SPRING_CLOUD_CONSUL_PORT: ${CONSUL_PORT:-443}
  SPRING_CLOUD_CONSUL_SCHEME: ${CONSUL_SCHEME:-https}
  SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS: ${CONSUL_DISCOVERY_PREFER_IP_ADDRESS:-true}
  SPRING_CLOUD_CONSUL_DISCOVERY_SCHEME: ${CONSUL_DISCOVERY_SCHEME:-https}
  SPRING_CLOUD_CONSUL_DISCOVERY_PORT: ${CONSUL_DISCOVERY_PORT:-443}
  CONSUL_HEALTH_ENABLED: ${CONSUL_HEALTH_ENABLED:-true}
  MANAGEMENT_HEALTH_CONSUL_ENABLED: ${CONSUL_HEALTH_ENABLED:-true}

  SPRING_DATASOURCE_USERNAME: root
  SPRING_DATASOURCE_PASSWORD: ${MYSQL_ROOT_PASSWORD:-${APP_F4_PASS}}
  SPRING_LIQUIBASE_USER: root
  SPRING_LIQUIBASE_PASSWORD: ${MYSQL_ROOT_PASSWORD:-${APP_F4_PASS}}

x-common-extra-hosts: &common-extra-hosts
  - "host.docker.internal:host-gateway"
  - "kafka.phungvip.io.vn:host-gateway"
  - "redis.phungvip.io.vn:host-gateway"
  - "phungvip.io.vn:host-gateway"

services:
  # ===== MySQL Databases =====
EOF

# MySQL container cho từng microservice (trừ gateway)
for svc in "${DISCOVERED_SERVICES[@]}"; do
  [ "$svc" = "gateway" ] && continue
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  cat << EOF >> "$SERVICES_COMPOSE_FILE"
  ${svc}-mysql:
    <<: *mysql_common
    environment:
      <<: *mysql_env
      MYSQL_DATABASE: ${svc}
    ports: [ "127.0.0.1:\${${svc_upper}_DB_PORT:-${SVC_DB_PORT[$svc]}}:3306" ]

EOF
done

cat << 'EOF' >> "$SERVICES_COMPOSE_FILE"
  # ===== Microservices & Gateway =====
EOF

# Gateway Service
if [[ " ${DISCOVERED_SERVICES[*]} " =~ " gateway " ]]; then
cat << 'EOF' >> "$SERVICES_COMPOSE_FILE"
  gateway:
    image: gateway
    restart: unless-stopped
    networks: [ ticket_net ]
    extra_hosts: *common-extra-hosts
    environment:
      <<: *common-variables
      SERVER_NAME: ${GATEWAY_SERVER_NAME:-apigateway}
      SERVER_PORT: ${GATEWAY_PORT:-8080}
      SPRING_CLOUD_CONSUL_DISCOVERY_IP_ADDRESS: ${GATEWAY_DISCOVERY_ADDRESS:-apigateway.${DOMAIN}}
      CONSUL_TOKEN: ${CONSUL_TOKEN_APIGATEWAY:-${APP_F4_PASS}}
      SPRING_CLOUD_CONSUL_CONFIG_ACL_TOKEN: ${CONSUL_TOKEN_APIGATEWAY:-${APP_F4_PASS}}
      SPRING_CLOUD_CONSUL_DISCOVERY_ACL_TOKEN: ${CONSUL_TOKEN_APIGATEWAY:-${APP_F4_PASS}}
    ports: [ "${GATEWAY_PORT:-8080}:8080" ]
    healthcheck:
      test: [ "CMD", "curl", "-fsS", "http://localhost:${GATEWAY_PORT:-8080}/management/health" ]
      interval: 5s
      timeout: 5s
      retries: 40
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ../config/microservices/:/app/config/:ro
    labels:
      - autoheal=true
    depends_on:
EOF
  # Gateway depends on all mysqls to be healthy
  for svc in "${DISCOVERED_SERVICES[@]}"; do
    [ "$svc" = "gateway" ] && continue
    echo "      ${svc}-mysql: { condition: service_healthy }" >> "$SERVICES_COMPOSE_FILE"
  done
  echo "" >> "$SERVICES_COMPOSE_FILE"
fi

# Chaining microservices start order:
# gateway -> ms_1 -> ms_2 -> ms_3... to avoid OOM crash on VPS
prev_service="gateway"
for svc in "${DISCOVERED_SERVICES[@]}"; do
  [ "$svc" = "gateway" ] && continue
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  clean_name="$(echo "$svc" | tr -d '_')"
  clean_upper="$(echo "$clean_name" | tr '[:lower:]' '[:upper:]')"

  cat << EOF >> "$SERVICES_COMPOSE_FILE"
  ${svc}:
    image: ${svc}
    restart: unless-stopped
    networks: [ ticket_net ]
    extra_hosts: *common-extra-hosts
    environment:
      <<: *common-variables
      SERVER_NAME: \${${svc_upper}_SERVER_NAME:-${clean_name}}
      SERVER_PORT: \${${svc_upper}_PORT:-${SVC_PORT[$svc]}}
      CONSUL_TOKEN: \${CONSUL_TOKEN_${clean_upper}:-\${CONSUL_TOKEN_${svc_upper}:-\${APP_F4_PASS}}}
      SPRING_CLOUD_CONSUL_CONFIG_ACL_TOKEN: \${CONSUL_TOKEN_${clean_upper}:-\${CONSUL_TOKEN_${svc_upper}:-\${APP_F4_PASS}}}
      SPRING_CLOUD_CONSUL_DISCOVERY_ACL_TOKEN: \${CONSUL_TOKEN_${clean_upper}:-\${CONSUL_TOKEN_${svc_upper}:-\${APP_F4_PASS}}}
      SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS: "true"
      SPRING_CLOUD_CONSUL_DISCOVERY_HOSTNAME: \${${svc_upper}_DISCOVERY_HOSTNAME:-${clean_name}.\${DOMAIN}}
      SPRING_CLOUD_CONSUL_DISCOVERY_IP_ADDRESS: \${${svc_upper}_DISCOVERY_ADDRESS:-${clean_name}.\${DOMAIN}}
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
      - /etc/localtime:/etc/localtime:ro
      - ../config/microservices/:/app/config/:ro
    labels: [ "autoheal=true" ]
    depends_on:
      ${svc}-mysql: { condition: service_healthy }
EOF

  if [ -n "$prev_service" ]; then
    echo "      ${prev_service}: { condition: service_healthy } # chain after ${prev_service}" >> "$SERVICES_COMPOSE_FILE"
  fi
  echo "" >> "$SERVICES_COMPOSE_FILE"
  prev_service="$svc"
done

echo -e "${GREEN}✓ Đã cập nhật .generated/docker-compose.services.yml thành công.${NC}"

# Cập nhật root docker-compose.yml (chỉ chứa core infra & include file động)
echo -e "  -> Cập nhật ${GREEN}${COMPOSE_FILE}${NC} (root infrastructure)..."
cat << 'EOF' > "$COMPOSE_FILE"
# Nhúng cấu hình microservices được tự động sinh (zero-hardcode trong repo Git)
include:
  - .generated/docker-compose.services.yml

# ===== Networks & Volumes =====
networks:
  ticket_net:
    name: ridehub-ms-network
    driver: bridge

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
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock

  # ===== Reverse Proxy & Ingress =====
  nginx:
    image: nginx:alpine
    container_name: ms-nginx
    restart: unless-stopped
    networks: [ ticket_net ]
    ports:
      - "127.0.0.1:8088:80" # localhost access; public traffic routes via cloudflared tunnel
    env_file:
      - path: ./.generated/services.env
        required: false
      - path: .env
        required: false
    environment:
      - TZ=${TZ:-Asia/Ho_Chi_Minh}
      - DOMAIN=${DOMAIN:-phungvip.io.vn}
      - NGINX_ENVSUBST_FILTER=^(DOMAIN|GATEWAY_|MS_|WEBHOOK_)
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/default.conf.template:/etc/nginx/templates/default.conf.template:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF

if [[ " ${DISCOVERED_SERVICES[*]} " =~ " gateway " ]]; then
cat << 'EOF' >> "$COMPOSE_FILE"
    depends_on:
      gateway: { condition: service_healthy }
EOF
fi

cat << 'EOF' >> "$COMPOSE_FILE"
    labels:
      autoheal: "true"

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: ms-cloudflared
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
      TUNNEL_TOKEN: ${TUNNEL_TOKEN:-}
    command: tunnel --metrics 0.0.0.0:2000 --config /etc/cloudflared/config.yml --no-autoupdate run
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config/cloudflared:/etc/cloudflared:ro
    depends_on:
      - nginx
    labels:
      autoheal: "true"

  # ===== Docker API Proxy & Webhook =====
  docker_api:
    image: tecnativa/docker-socket-proxy:latest
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      CONTAINERS: 1
      POST: 1
      EXEC: 1
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels: [ "autoheal=true" ]

  restarter:
    build: ./config/webhook
    restart: unless-stopped
    networks: [ ticket_net ]
    environment:
      ADMIN_TOKEN: ${ADMIN_TOKEN:-${APP_F4_PASS}}
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config/webhook/hooks.json:/etc/webhook/hooks.json:ro
      - ./config/webhook/scripts:/scripts:ro
      - ./config/webhook/triggers:/triggers
    command: [ "-verbose", "-hooks=/etc/webhook/hooks.json", "-hotreload", "-template", "-debug" ]
    depends_on:
      - docker_api
    labels: [ "autoheal=true" ]

  # ===== Observability Agents (Push to Central Monitor in vps-infra) =====
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: ms-cadvisor
    restart: unless-stopped
    networks: [ ticket_net ]
    privileged: true
    environment:
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
    devices:
      - /dev/kmsg:/dev/kmsg
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    labels: [ "autoheal=true" ]

  promtail:
    image: grafana/promtail:3.1.1
    container_name: ms-promtail
    restart: unless-stopped
    networks: [ ticket_net ]
    user: "0"
    command: -config.file=/etc/promtail/promtail-config.yaml -config.expand-env=true
    environment:
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
      LOKI_URL: ${LOKI_URL:-http://host.docker.internal:3100}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - ./config/observability/promtail-config.yaml:/etc/promtail/promtail-config.yaml:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    labels: [ "autoheal=true" ]

  prom-agent:
    image: prom/prometheus:v3.3.1
    container_name: ms-prom-agent
    restart: unless-stopped
    networks: [ ticket_net ]
    command:
      - "--agent"
      - "--config.file=/etc/prometheus/prometheus-agent.yml"
      - "--storage.agent.path=/prometheus"

    environment:
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
      PROMETHEUS_REMOTE_WRITE_URL: ${PROMETHEUS_REMOTE_WRITE_URL:-http://host.docker.internal:9090/api/v1/write}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config/observability/prometheus-agent.yml:/etc/prometheus/prometheus-agent.yml:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    labels: [ "autoheal=true" ]
EOF

echo -e "${GREEN}✓ Đã cập nhật docker-compose.yml (root infrastructure) thành công.${NC}"

# 5b. Tự động sinh file cấu hình Prometheus Agent: config/observability/prometheus-agent.yml
echo -e "\n${BLUE}[4b/6] Đang sinh file cấu hình Prometheus Agent: ${GREEN}${CONFIG_DIR}/observability/prometheus-agent.yml${NC}..."
mkdir -p "$CONFIG_DIR/observability"
TARGET_REMOTE_WRITE_URL="${PROMETHEUS_REMOTE_WRITE_URL:-http://host.docker.internal:9090/api/v1/write}"
cat << AGENT_EOF > "$CONFIG_DIR/observability/prometheus-agent.yml"
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    vps: 'vps-microservices'
    cluster: 'microservices'

remote_write:
  - url: ${TARGET_REMOTE_WRITE_URL}
    queue_config:
      max_samples_per_send: 1000
      max_shards: 10
      capacity: 5000


scrape_configs:
  - job_name: 'vps-microservices-cadvisor'
    scrape_interval: 10s
    static_configs:
      - targets: ['cadvisor:8080']
        labels:
          vps: 'vps-microservices'
          cluster: 'microservices'

  - job_name: 'spring-boot-microservices'
    scrape_interval: 10s
    metrics_path: /management/prometheus
    static_configs:
AGENT_EOF

if [[ " ${DISCOVERED_SERVICES[*]} " =~ " gateway " ]]; then
  cat << 'GW_EOF' >> "$CONFIG_DIR/observability/prometheus-agent.yml"
      - targets: ['gateway:8080']
        labels:
          application: 'gateway'
          vps: 'vps-microservices'
GW_EOF
fi

for svc in "${DISCOVERED_SERVICES[@]}"; do
  [ "$svc" = "gateway" ] && continue
  clean_name="$(echo "$svc" | tr -d '_')"
  app_port="${SVC_PORT[$svc]:-8080}"
  cat << MS_EOF >> "$CONFIG_DIR/observability/prometheus-agent.yml"
      - targets: ['${svc}:${app_port}']
        labels:
          application: '${clean_name}'
          vps: 'vps-microservices'
MS_EOF
done

echo -e "${GREEN}✓ Đã cập nhật prometheus-agent.yml thành công.${NC}"


# 6. Cập nhật cloudflared/setup-tunnel.sh
echo -e "\n${BLUE}[5/6] cloudflared/setup-tunnel.sh tự động định tuyến DNS theo ACTIVE_SERVICES từ services.env.${NC}"

# 7. Cập nhật webhook/scripts/restart.sh
echo -e "\n${BLUE}[6/6] webhook/scripts/restart.sh tự động phát hiện targets qua Docker API (zero-hardcode).${NC}"

# 8. Đồng bộ & Khởi tạo cấu hình Consul KV (Centralized External Configuration)
echo -e "\n${BLUE}[6/6] Kiểm tra & Đồng bộ cấu hình Consul KV tập trung...${NC}"
CONSUL_TOKEN="${CONSUL_TOKEN:-${APP_F4_PASS:-}}"
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



