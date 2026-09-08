#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Master Auto-Deploy Script for VPS-MICROSERVICES (RideHub)
# 1. Kéo Git mới nhất (Root + Submodules remote)
# 2. Quét service backend và sinh toàn bộ cấu hình (Nginx, Compose, Cloudflare, Consul)
# 3. Build Docker Images cho toàn bộ microservices
# 4. Khởi chạy / Restart hệ thống Docker Compose
# 5. Kiểm tra Healthcheck và hiển thị bảng trạng thái
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MICROSERVICES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Xác định root repository
if [ -d "$MICROSERVICES_DIR/../../backend" ]; then
  REPO_ROOT="$(cd "$MICROSERVICES_DIR/../.." && pwd)"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT/backend" ]; then
  echo -e "${RED}❌ Không tìm thấy thư mục gốc chứa backend!${NC}"
  exit 1
fi

TARGET_SERVICES=()
FORCE_BUILD=false
SKIP_PULL=false
SKIP_BUILD=false
CONFIG_ONLY=false

# Xử lý tham số dòng lệnh
while [ $# -gt 0 ]; do
  case "$1" in
    --service|--services|-s)
      shift
      if [ $# -gt 0 ]; then
        IFS=',' read -ra ADDR <<< "$1"
        for s in "${ADDR[@]}"; do
          s_trimmed="$(echo "$s" | xargs)"
          [ -n "$s_trimmed" ] && TARGET_SERVICES+=("$s_trimmed")
        done
      fi
      ;;
    --all|--force-build|-a)
      FORCE_BUILD=true
      ;;
    --skip-pull)
      SKIP_PULL=true
      ;;
    --skip-build)
      SKIP_BUILD=true
      ;;
    --config-only)
      CONFIG_ONLY=true
      ;;
    -h|--help)
      echo -e "${BOLD}CÁCH DÙNG:${NC} ./auto-deploy.sh [OPTIONS]"
      echo ""
      echo "Tùy chọn:"
      echo "  -s, --service <name>   Chỉ định service(s) cần build (phân tách bằng dấu phẩy, vd: ms_user,ms_route)"
      echo "  -a, --all, --force     Ép build toàn bộ services (không lọc theo commit thay đổi)"
      echo "  --skip-pull            Bỏ qua bước kéo git mới nhất"
      echo "  --skip-build           Bỏ qua bước build image Docker"
      echo "  --config-only          Chỉ quét service và sinh file cấu hình (không build & không up)"
      echo "  -h, --help             Hiển thị trợ giúp này"
      exit 0
      ;;
    *)
      echo -e "${YELLOW}⚠️ Tùy chọn không xác định: $1${NC}"
      ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# KHÓA TIẾN TRÌNH (CONCURRENCY MUTEX LOCK)
# Ngăn chặn xung đột khi nhiều submodule cùng gọi trigger deploy đồng thời.
# Các tiến trình sau sẽ tự động xếp hàng (queue) chờ tiến trình trước hoàn tất.
# ------------------------------------------------------------------------------
LOCK_FILE="/tmp/ridehub_auto_deploy.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo -e "${YELLOW}⏳ Đang có tiến trình deploy khác đang chạy. Đang xếp hàng chờ (queue)...${NC}"
  flock -x 200
  echo -e "${GREEN}✓ Đã đến lượt! Bắt đầu thực thi tiến trình mới...${NC}"
fi

echo -e "${CYAN}====================================================================${NC}"
echo -e "${GREEN}${BOLD}  RIDEHUB AUTO-DEPLOY PIPELINE (VPS-MICROSERVICES)${NC}"
echo -e "${CYAN}====================================================================${NC}"
echo -e "Repo Root: ${BLUE}$REPO_ROOT${NC}"
echo -e "Microservices Dir: ${BLUE}$MICROSERVICES_DIR${NC}\n"

BACKEND_DIR="$REPO_ROOT/backend"
declare -A BEFORE_HASH
DETECTED_CHANGED_SERVICES=()

# ------------------------------------------------------------------------------
# BƯỚC 1: GIT PULL ROOT & RECURSIVE SUBMODULES (PHÁT HIỆN THAY ĐỔI)
# ------------------------------------------------------------------------------
if [ "$SKIP_PULL" = true ]; then
  echo -e "${YELLOW}⏭ [1/4] Bỏ qua bước Git Pull (--skip-pull)${NC}"
else
  # Ghi lại commit SHA hiện tại của từng submodule trước khi pull
  for svc_dir in "$BACKEND_DIR"/*; do
    [ -d "$svc_dir" ] || continue
    s="$(basename "$svc_dir")"
    [ "$s" = "docker-compose" ] && continue
    if [ -d "$svc_dir/.git" ] || [ -f "$svc_dir/.git" ]; then
      BEFORE_HASH["$s"]="$(git -C "$svc_dir" rev-parse HEAD 2>/dev/null || echo "")"
    else
      BEFORE_HASH["$s"]=""
    fi
  done

  echo -e "${BLUE}▶ [1/4] Đang cập nhật Git mới nhất cho Root & Submodules...${NC}"
  cd "$REPO_ROOT"

  # Kiểm tra git repo
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'main')"
    echo -e "  -> Kéo nhánh root [${CURRENT_BRANCH}]..."
    git pull origin "$CURRENT_BRANCH" || git pull || echo -e "${YELLOW}⚠️ Không thể pull root (tiếp tục với mã nguồn hiện tại)${NC}"

    echo -e "  -> Cập nhật đệ quy các Submodules lên remote mới nhất..."
    git submodule sync --recursive 2>/dev/null || true
    git submodule update --init --recursive --remote 2>/dev/null || git submodule update --init --recursive || true
    echo -e "${GREEN}✓ Hoàn tất cập nhật Git.${NC}"

    # So sánh commit SHA sau khi pull để tìm TẤT CẢ các submodule bị thay đổi
    echo -e "\n${BLUE}🔍 Kiểm tra thay đổi trong các Submodules:${NC}"
    for svc_dir in "$BACKEND_DIR"/*; do
      [ -d "$svc_dir" ] || continue
      s="$(basename "$svc_dir")"
      [ "$s" = "docker-compose" ] && continue

      AFTER_HASH="$(git -C "$svc_dir" rev-parse HEAD 2>/dev/null || echo "")"
      b_hash="${BEFORE_HASH[$s]:-}"

      if [ -n "$b_hash" ] && [ "$b_hash" != "$AFTER_HASH" ]; then
        DETECTED_CHANGED_SERVICES+=("$s")
        echo -e "  • [THAY ĐỔI] Service [${GREEN}$s${NC}]: ${YELLOW}${b_hash:0:7}${NC} -> ${GREEN}${AFTER_HASH:0:7}${NC}"
      elif [ -z "$b_hash" ] && [ -n "$AFTER_HASH" ]; then
        DETECTED_CHANGED_SERVICES+=("$s")
        echo -e "  • [MỚI] Submodule mới [${GREEN}$s${NC}]: ${GREEN}${AFTER_HASH:0:7}${NC}"
      else
        echo -e "  • [GIỮ NGUYÊN] Service [${CYAN}$s${NC}]: Không có commit mới"
      fi
    done
  else
    echo -e "${YELLOW}⚠️ Thư mục không phải git repo, bỏ qua git pull.${NC}"
  fi
fi

# Xác định danh sách services cần build
SERVICES_TO_BUILD=()
if [ ${#TARGET_SERVICES[@]} -gt 0 ]; then
  SERVICES_TO_BUILD=("${TARGET_SERVICES[@]}")
  echo -e "\n${CYAN}🎯 Chế độ chỉ định dịch vụ (--service): ${GREEN}${SERVICES_TO_BUILD[*]}${NC}"
elif [ "$FORCE_BUILD" = true ]; then
  for svc_dir in "$BACKEND_DIR"/*; do
    [ -d "$svc_dir" ] || continue
    s="$(basename "$svc_dir")"
    [ "$s" = "docker-compose" ] && continue
    SERVICES_TO_BUILD+=("$s")
  done
  echo -e "\n${CYAN}⚡ Chế độ ép build toàn bộ (--all): ${GREEN}${SERVICES_TO_BUILD[*]}${NC}"
else
  SERVICES_TO_BUILD=("${DETECTED_CHANGED_SERVICES[@]}")
  if [ ${#SERVICES_TO_BUILD[@]} -gt 0 ]; then
    echo -e "\n${CYAN}🎯 Phát hiện ${#SERVICES_TO_BUILD[@]} service(s) thay đổi cần build: ${GREEN}${SERVICES_TO_BUILD[*]}${NC}"
  else
    echo -e "\n${YELLOW}☕ Không phát hiện thay đổi trong submodule nào.${NC}"
  fi
fi

# ------------------------------------------------------------------------------
# BƯỚC 2: TỰ ĐỘNG QUÉT & SINH CẤU HÌNH ĐỒNG BỘ
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}▶ [2/4] Chạy kịch bản tự động quét và sinh file cấu hình...${NC}"
cd "$MICROSERVICES_DIR"
chmod +x "$SCRIPT_DIR/generate-configs.sh"
"$SCRIPT_DIR/generate-configs.sh"

if [ "$CONFIG_ONLY" = true ]; then
  echo -e "\n${GREEN}🎉 Đã hoàn tất chế độ sinh cấu hình (--config-only). Dừng tại đây.${NC}"
  exit 0
fi

# Đọc lại file services.env vừa sinh
if [ -f "$MICROSERVICES_DIR/.generated/services.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$MICROSERVICES_DIR/.generated/services.env"
  set +a
elif [ -f "$CONFIG_DIR/services.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_DIR/services.env"
  set +a
fi
DOMAIN="${DOMAIN:-phungvip.io.vn}"

# ------------------------------------------------------------------------------
# BƯỚC 3: BUILD DOCKER IMAGES (CHỈ BUILD CÁC SERVICE CẦN THIẾT)
# ------------------------------------------------------------------------------
if [ "$SKIP_BUILD" = true ]; then
  echo -e "\n${YELLOW}⏭ [3/4] Bỏ qua bước Build Docker Images (--skip-build)${NC}"
elif [ ${#SERVICES_TO_BUILD[@]} -eq 0 ]; then
  echo -e "\n${GREEN}⏭ [3/4] Bỏ qua build: Không có service nào thay đổi.${NC}"
else
  echo -e "\n${BLUE}▶ [3/4] Bắt đầu build ${#SERVICES_TO_BUILD[@]} service(s) thay đổi (tuần tự tránh đầy RAM)...${NC}"
  
  idx=1
  for svc_name in "${SERVICES_TO_BUILD[@]}"; do
    svc_dir="$BACKEND_DIR/$svc_name"
    if [ ! -d "$svc_dir" ]; then
      echo -e "${YELLOW}⚠️ Không tìm thấy thư mục service: $svc_dir, bỏ qua.${NC}"
      continue
    fi

    echo -e "\n${CYAN}--------------------------------------------------------------------${NC}"
    echo -e "${CYAN}🛠 [${idx}/${#SERVICES_TO_BUILD[@]}] Đang build image cho: ${GREEN}${svc_name}${NC}"
    echo -e "${CYAN}--------------------------------------------------------------------${NC}"

    if [ -f "$svc_dir/pom.xml" ]; then
      (
        cd "$svc_dir"
        if [ -f "./mvnw" ]; then
          chmod +x ./mvnw
          ./mvnw -Pprod verify jib:dockerBuild -DskipTests -T 2 || ./mvnw -Pprod verify jib:dockerBuild -DskipTests
        elif command -v mvn >/dev/null 2>&1; then
          mvn -Pprod verify jib:dockerBuild -DskipTests -T 2 || mvn -Pprod verify jib:dockerBuild -DskipTests
        else
          echo -e "${RED}❌ Không tìm thấy mvnw hoặc mvn để build ${svc_name}!${NC}"
          exit 1
        fi
      )
      echo -e "${GREEN}✓ Build thành công image [${svc_name}]${NC}"
    elif [ -f "$svc_dir/Dockerfile" ]; then
      echo -e "${CYAN}🛠 Đang build Dockerfile cho: ${GREEN}${svc_name}${NC}"
      docker build -t "${svc_name}:latest" "$svc_dir"
      echo -e "${GREEN}✓ Build Dockerfile thành công cho [${svc_name}]${NC}"
    else
      echo -e "${YELLOW}⚠️ Không có pom.xml hoặc Dockerfile trong ${svc_name}, bỏ qua build.${NC}"
    fi

    idx=$((idx + 1))
  done
  echo -e "\n${GREEN}✓ Đã hoàn tất build toàn bộ service được chọn.${NC}"
fi

# ------------------------------------------------------------------------------
# BƯỚC 4: TRIỂN KHAI & RESTART DOCKER COMPOSE
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}▶ [4/4] Khởi chạy và cập nhật Docker Compose...${NC}"
cd "$MICROSERVICES_DIR"

# Đảm bảo network độc lập tồn tại
if ! docker network inspect ridehub-ms-network >/dev/null 2>&1; then
  echo "-> Đang tạo network độc lập 'ridehub-ms-network'..."
  docker network create ridehub-ms-network || true
fi

if [ "$FORCE_BUILD" = true ] || [ ${#TARGET_SERVICES[@]} -eq 0 ]; then
  echo "-> Khởi chạy và đảm bảo toàn bộ cụm container hoạt động (up -d --remove-orphans)..."
  docker compose up -d --remove-orphans
elif [ ${#SERVICES_TO_BUILD[@]} -gt 0 ]; then
  echo "-> Khởi chạy / Cập nhật lại các container được chọn: ${SERVICES_TO_BUILD[*]}..."
  docker compose up -d --no-deps "${SERVICES_TO_BUILD[@]}"
else
  echo "-> Đảm bảo toàn bộ cụm container đang chạy (up -d --remove-orphans)..."
  docker compose up -d --remove-orphans
fi

echo "-> Khởi động lại ms-nginx để nạp template cấu hình mới..."
docker compose restart nginx

echo -e "\n${BLUE}Kiểm tra sức khoẻ hệ thống (Health Check chờ 10s)...${NC}"
sleep 10

echo -e "\n${GREEN}====================================================================${NC}"
echo -e "${GREEN}${BOLD}  TRẠNG THÁI CÁC DỊCH VỤ SAU KHI TRIỂN KHAI${NC}"
echo -e "${GREEN}====================================================================${NC}"
docker compose ps

echo -e "\n${CYAN}====================================================================${NC}"
echo -e "${CYAN}${BOLD}  DANH SÁCH ĐƯỜNG DẪN TRUY CẬP (ENDPOINTS)${NC}"
echo -e "${CYAN}====================================================================${NC}"

for svc_dir in "$BACKEND_DIR"/*; do
  [ -d "$svc_dir" ] || continue
  s="$(basename "$svc_dir")"
  [ "$s" = "docker-compose" ] && continue

  s_upper="$(echo "$s" | tr '[:lower:]' '[:upper:]')"
  sub_var="${s_upper}_SUBDOMAIN"
  port_var="${s_upper}_PORT"
  sub="${!sub_var:-$s}"
  p="${!port_var:-8080}"

  if [ "$s" = "gateway" ]; then
    printf "  • %-15s : %-35s (Local: :%s)\n" "Gateway/Web" "https://${DOMAIN}" "$p"
    printf "  • %-15s : %-35s\n" "API Gateway" "https://${sub}.${DOMAIN}"
  else
    printf "  • %-15s : %-35s (Local: :%s)\n" "$s" "https://${sub}.${DOMAIN}" "$p"
  fi
done

printf "  • %-15s : %-35s (Local: :9000)\n" "Webhook Restart" "https://webhook.${DOMAIN}"
echo -e "${CYAN}====================================================================${NC}"
echo -e "${GREEN}🎉 HỆ THỐNG ĐÃ TỰ ĐỘNG TRIỂN KHAI HOÀN TẤT VÀ SẴN SÀNG!${NC}"

