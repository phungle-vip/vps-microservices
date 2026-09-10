#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script tự động thiết lập Cloudflare Tunnel cho cụm VPS-MICROSERVICES
# Tự động: Tạo Tunnel -> Sao chép credentials -> Cập nhật config.yml -> Định tuyến DNS
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MICROSERVICES_DIR=""

# Xác định thư mục gốc của vps-microservices
if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
  MICROSERVICES_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/../docker-compose.yml" ]; then
  MICROSERVICES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -f "$SCRIPT_DIR/../../docker-compose.yml" ]; then
  MICROSERVICES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  echo -e "${RED}❌ Không tìm thấy thư mục vps-microservices!${NC}"
  exit 1
fi

CLOUDFLARED_DIR="$SCRIPT_DIR"
CONFIG_FILE="$CLOUDFLARED_DIR/config.yml"
CREDS_TARGET="$CLOUDFLARED_DIR/credentials.json"

# Nạp file .env nếu có
ENV_FILE="$MICROSERVICES_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo -e "${BLUE}-> Đang đọc biến môi trường từ $ENV_FILE...${NC}"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Nạp file services.env nếu có (chứa cấu hình dynamic service names & subdomains)
SERVICES_ENV="$MICROSERVICES_DIR/config/services.env"
if [ ! -f "$SERVICES_ENV" ] && [ -f "$MICROSERVICES_DIR/.generated/services.env" ]; then
  SERVICES_ENV="$MICROSERVICES_DIR/.generated/services.env"
elif [ ! -f "$SERVICES_ENV" ] && [ -f "$MICROSERVICES_DIR/services.env" ]; then
  SERVICES_ENV="$MICROSERVICES_DIR/services.env"
fi
if [ -f "$SERVICES_ENV" ]; then
  echo -e "${BLUE}-> Đang đọc cấu hình service động từ $SERVICES_ENV...${NC}"
  set -a
  # shellcheck disable=SC1090
  source "$SERVICES_ENV"
  set +a
fi

DOMAIN="${DOMAIN:-phungvip.io.vn}"
TUNNEL_NAME="${1:-ridehub-ms-tunnel}"

echo -e "${BLUE}====================================================================${NC}"
echo -e "${GREEN}  THIẾT LẬP CLOUDFLARE TUNNEL: ${TUNNEL_NAME}${NC}"
echo -e "${GREEN}  Tên miền mục tiêu: ${DOMAIN}${NC}"
echo -e "${BLUE}====================================================================${NC}"

# 1. Kiểm tra cloudflared CLI
if ! command -v cloudflared >/dev/null 2>&1; then
  echo -e "${RED}❌ Chưa cài đặt 'cloudflared' CLI!${NC}"
  echo "Vui lòng cài đặt cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  exit 1
fi

# 2. Tạo Tunnel mới hoặc lấy Tunnel ID nếu đã tồn tại
echo -e "\n${BLUE}[1/5] Kiểm tra / Tạo Tunnel: ${TUNNEL_NAME}...${NC}"
TUNNEL_ID=""

# Kiểm tra xem tunnel đã tồn tại chưa
EXISTING_ID=$(cloudflared tunnel list --output json 2>/dev/null | grep -o '"id":"[^"]*' | grep -B1 "\"name\":\"${TUNNEL_NAME}\"" | head -n1 | cut -d'"' -f4 || true)

if [ -z "$EXISTING_ID" ]; then
  # Thử tìm bằng regex nếu output json dạng mảng
  EXISTING_ID=$(cloudflared tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" '$2 == name {print $1}' || true)
fi

if [ -n "$EXISTING_ID" ]; then
  echo -e "${YELLOW}ℹ Tunnel '${TUNNEL_NAME}' đã tồn tại với ID: ${EXISTING_ID}${NC}"
  TUNNEL_ID="$EXISTING_ID"
else
  echo "-> Đang tạo tunnel mới '${TUNNEL_NAME}'..."
  CREATE_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
  echo "$CREATE_OUTPUT"
  TUNNEL_ID=$(echo "$CREATE_OUTPUT" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -n1 || true)
fi

if [ -z "$TUNNEL_ID" ]; then
  echo -e "${RED}❌ Không thể lấy được Tunnel ID. Hãy đảm bảo bạn đã chạy 'cloudflared tunnel login' trước đó!${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Tunnel ID: ${TUNNEL_ID}${NC}"

# 3. Lấy Tunnel Token và lưu vào .env (Token-Based / Cloud-Managed)
echo -e "\n${BLUE}[2/5] Trích xuất TUNNEL_TOKEN vào file .env...${NC}"
TOKEN_OUTPUT=$(cloudflared tunnel token "$TUNNEL_NAME" 2>/dev/null || true)

if [ -n "$TOKEN_OUTPUT" ]; then
  if [ -f "$ENV_FILE" ]; then
    if grep -q "^TUNNEL_TOKEN=" "$ENV_FILE"; then
      sed -i -E "s|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=${TOKEN_OUTPUT}|" "$ENV_FILE"
    else
      echo "TUNNEL_TOKEN=${TOKEN_OUTPUT}" >> "$ENV_FILE"
    fi
    echo -e "${GREEN}✓ Đã cập nhật TUNNEL_TOKEN vào ${ENV_FILE}${NC}"
  fi
else
  echo -e "${YELLOW}ℹ Không trích xuất được token tự động, tiếp tục với file config cục bộ.${NC}"
fi

# 4. Cập nhật Tunnel ID vào file config.yml
echo -e "\n${BLUE}[3/5] Cập nhật Tunnel ID vào config.yml...${NC}"
if [ -f "$CONFIG_FILE" ]; then
  sed -i -E "s/^tunnel: .*/tunnel: ${TUNNEL_ID}/" "$CONFIG_FILE"
  echo -e "${GREEN}✓ Đã cập nhật dòng 'tunnel: ${TUNNEL_ID}' trong ${CONFIG_FILE}${NC}"
else
  echo -e "${RED}❌ Không tìm thấy file ${CONFIG_FILE}!${NC}"
  exit 1
fi

# 5. Định tuyến DNS trên Cloudflare về Tunnel
echo -e "\n${BLUE}[4/5] Định tuyến DNS các subdomains về Tunnel '${TUNNEL_NAME}'...${NC}"

SUBDOMAINS=(
  "${DOMAIN}"
  "${WEBHOOK_SUBDOMAIN:-webhook}.${DOMAIN}"
)

# Thêm Gateway subdomains nếu có
if [ -n "${GATEWAY_SUBDOMAIN:-}" ]; then
  SUBDOMAINS+=("${GATEWAY_SUBDOMAIN}.${DOMAIN}")
fi
if [ -n "${GATEWAY_ALT_SUBDOMAIN:-}" ]; then
  SUBDOMAINS+=("${GATEWAY_ALT_SUBDOMAIN}.${DOMAIN}")
fi

# Tự động duyệt qua tất cả active microservices
for svc in ${ACTIVE_SERVICES:-}; do
  [ "$svc" = "gateway" ] && continue
  svc_upper="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  clean_name="$(echo "$svc" | tr -d '_')"
  var="${svc_upper}_SUBDOMAIN"
  sub="${!var:-$clean_name}"
  SUBDOMAINS+=("${sub}.${DOMAIN}")
done

for sub in "${SUBDOMAINS[@]}"; do
  echo -n "-> Trỏ DNS cho [${sub}]... "
  if cloudflared tunnel route dns -f "$TUNNEL_NAME" "$sub" >/dev/null 2>&1; then
    echo -e "${GREEN}Thành công${NC}"
  else
    echo -e "${YELLOW}Đã tồn tại hoặc bỏ qua cảnh báo${NC}"
  fi
done

# 6. Đăng ký Private Network (Layer 4) cho Docker Subnet
echo -e "\n${BLUE}[5/5] Cấu hình Private Network Routing cho mạng nội bộ...${NC}"
MS_SUBNET=$(docker network inspect ridehub-ms-network 2>/dev/null | grep -o '"Subnet": "[^"]*' | cut -d'"' -f4 | head -n1 || true)
if [ -n "$MS_SUBNET" ]; then
  echo "-> Đăng ký subnet [${MS_SUBNET}] vào Tunnel '${TUNNEL_NAME}'..."
  cloudflared tunnel route ip add "$MS_SUBNET" "$TUNNEL_NAME" >/dev/null 2>&1 || echo -e "${YELLOW}ℹ Route IP đã tồn tại hoặc đã được đăng ký.${NC}"
  echo -e "${GREEN}✓ Hoàn tất cấu hình Layer 4 Private Network.${NC}"
else
  echo -e "${YELLOW}ℹ Mạng Docker 'ridehub-ms-network' chưa khởi tạo, bỏ qua đăng ký Private Route (sẽ tự nhận khi chạy docker compose).${NC}"
fi

echo -e "\n${GREEN}====================================================================${NC}"
echo -e "${GREEN}🎉 HOÀN TẤT THIẾT LẬP TUNNEL CHO VPS-MICROSERVICES!${NC}"
echo -e "${GREEN}====================================================================${NC}"
echo -e "Bây giờ bạn có thể khởi chạy hệ thống bằng lệnh:"
echo -e "  ${BLUE}cd ${MICROSERVICES_DIR}${NC}"
echo -e "  ${BLUE}docker compose up -d${NC}\n"

