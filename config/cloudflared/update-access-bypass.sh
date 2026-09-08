#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script tự động cấu hình Bypass IP trên Cloudflare Zero Trust Access
# LƯU Ý: Consul và Vault hiện nay đã được cấu hình bảo mật trực tiếp bằng
# Token / ACL nội tại và đã gỡ bỏ Cloudflare Access, do đó script này
# không còn bắt buộc khi chạy đa VPS qua domain.
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MICROSERVICES_DIR=""

if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
  MICROSERVICES_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/../docker-compose.yml" ]; then
  MICROSERVICES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -f "$SCRIPT_DIR/../../docker-compose.yml" ]; then
  MICROSERVICES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

# 1. Đọc biến môi trường từ .env
ENV_FILE=""
if [ -n "$MICROSERVICES_DIR" ] && [ -f "$MICROSERVICES_DIR/.env" ]; then
  ENV_FILE="$MICROSERVICES_DIR/.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
  ENV_FILE="$SCRIPT_DIR/.env"
elif [ -f "./.env" ]; then
  ENV_FILE="./.env"
fi

if [ -n "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

DOMAIN="${DOMAIN:-phungvip.io.vn}"

# 2. Tự động nhận diện CF_ACCOUNT_ID từ credentials.json nếu chưa set
if [ -z "${CF_ACCOUNT_ID:-}" ]; then
  CREDS_FILE=""
  if [ -f "$SCRIPT_DIR/credentials.json" ]; then
    CREDS_FILE="$SCRIPT_DIR/credentials.json"
  elif [ -n "$MICROSERVICES_DIR" ] && [ -f "$MICROSERVICES_DIR/config/cloudflared/credentials.json" ]; then
    CREDS_FILE="$MICROSERVICES_DIR/config/cloudflared/credentials.json"
  fi

  if [ -n "$CREDS_FILE" ] && [ -f "$CREDS_FILE" ]; then
    CF_ACCOUNT_ID=$(grep -o '"AccountTag":"[^"]*' "$CREDS_FILE" 2>/dev/null | cut -d'"' -f4 || true)
  fi
fi

# 3. Lấy IP Public của VPS hiện tại (hoặc từ tham số dòng lệnh $1)
VPS_IP="${1:-}"
if [ -z "$VPS_IP" ]; then
  echo -e "${BLUE}-> Đang xác định IP Public của máy chủ...${NC}"
  VPS_IP=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 5 https://icanhazip.com 2>/dev/null \
    || true)
  VPS_IP=$(echo "$VPS_IP" | tr -d '[:space:]')
fi

if [ -z "$VPS_IP" ]; then
  echo -e "${RED}❌ Không thể lấy được IP Public của máy chủ! Bạn có thể truyền thủ công: $0 <IP>${NC}"
  exit 1
fi

echo -e "${BLUE}====================================================================${NC}"
echo -e "${GREEN}  CẬP NHẬT CLOUDFLARE ACCESS BYPASS CHO VPS MICROSERVICES${NC}"
echo -e "  IP VPS Microservices : ${YELLOW}${VPS_IP}${NC}"
echo -e "  Tên miền gốc         : ${DOMAIN}"
echo -e "${BLUE}====================================================================${NC}"

# 4. Kiểm tra biến bắt buộc
MISSING=()
[ -z "${CF_ACCOUNT_ID:-}" ] && MISSING+=("CF_ACCOUNT_ID (hoặc credentials.json)")
[ -z "${CF_API_TOKEN:-}" ] && MISSING+=("CF_API_TOKEN")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${RED}❌ Thiếu các cấu hình sau: ${MISSING[*]}${NC}"
  echo "Vui lòng thêm vào file .env của vps-microservices:"
  echo "  CF_API_TOKEN=\"your_cloudflare_api_token\""
  exit 1
fi

# 5. Lấy danh sách Access Applications từ Cloudflare
API_BASE="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/access/apps"

echo -e "\n${BLUE}[1/2] Lấy danh sách ứng dụng Access từ Cloudflare...${NC}"
APPS_RES=$(curl -fsS -X GET "${API_BASE}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" 2>/dev/null || echo '{"result":[]}')

# Danh sách dịch vụ cần mở Bypass cho VPS Microservices
TARGET_SERVICES=(
  "Consul:consul.${DOMAIN}"
  "HashiCorp Vault:vault.${DOMAIN}"
)

echo -e "\n${BLUE}[2/2] Cập nhật rule Bypass IP cho các dịch vụ...${NC}"

for item in "${TARGET_SERVICES[@]}"; do
  SVC_NAME="${item%%:*}"
  SVC_DOMAIN="${item##*:}"

  APP_ID=$(echo "$APPS_RES" | jq -r ".result[] | select(.domain == \"${SVC_DOMAIN}\") | .id" | head -n1 || true)

  if [ -z "$APP_ID" ] || [ "$APP_ID" = "null" ]; then
    echo -e "${YELLOW}⚠️ Không tìm thấy Access App cho [${SVC_DOMAIN}] (có thể chưa bật Access cho subdomain này). Bỏ qua.${NC}"
    continue
  fi

  echo -n "-> Cấu hình Bypass cho ${SVC_NAME} (${SVC_DOMAIN})... "

  # Lấy danh sách policies hiện có
  POLICIES_RES=$(curl -fsS -X GET "${API_BASE}/${APP_ID}/policies" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"result":[]}')

  POLICY_ID=$(echo "$POLICIES_RES" | jq -r '.result[]? | select(.name == "Bypass VPS IP" or .decision == "bypass") | .id' | head -n1 || true)

  POLICY_PAYLOAD=$(cat <<EOF
{
  "name": "Bypass VPS IP",
  "decision": "bypass",
  "precedence": 1,
  "include": [
    {
      "ip": {
        "ip": "${VPS_IP}/32"
      }
    }
  ]
}
EOF
)

  if [ -n "$POLICY_ID" ] && [ "$POLICY_ID" != "null" ]; then
    # Cập nhật policy hiện có
    curl -fsS -X PUT "${API_BASE}/${APP_ID}/policies/${POLICY_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${POLICY_PAYLOAD}" >/dev/null
    echo -e "${GREEN}✓ Đã cập nhật Policy Bypass (IP: ${VPS_IP}/32)${NC}"
  else
    # Tạo mới policy
    curl -fsS -X POST "${API_BASE}/${APP_ID}/policies" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${POLICY_PAYLOAD}" >/dev/null
    echo -e "${GREEN}✓ Đã tạo mới Policy Bypass (IP: ${VPS_IP}/32)${NC}"
  fi
done

echo -e "\n${GREEN}🎉 Hoàn tất! VPS Microservices (${VPS_IP}) giờ đây có thể kết nối trực tiếp tới Consul & Vault qua domain!${NC}\n"

