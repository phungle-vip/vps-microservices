# RideHub VPS Microservices (vps-microservices)

Cụm điều phối và triển khai ứng dụng microservices tự động hoàn toàn cho hệ thống **RideHub**, chạy trên VPS sử dụng Docker Compose, tích hợp Cloudflare Tunnel và Nginx Dynamic Reverse Proxy.

---

## 1. Kiến trúc tổng quan (Architecture Overview)

Cụm Microservices kết nối vào mạng `ridehub-network` và tương tác với cụm hạ tầng trung tâm (`vps-infra`) từ xa:

```
                              INTERNET (Public Users)
                                         │
                             Cloudflare Tunnel Ingress
                                         │
                                         ▼
                                 ms-nginx (Reverse Proxy)
           ┌──────────────┬──────────────┼──────────────┬──────────────┐
           ▼              ▼              ▼              ▼              ▼
        gateway        ms_route       ms_user       ms_booking    ms_promotion
      (Port 8080)    (Port 8082)    (Port 8083)    (Port 8084)    (Port 8085)
           │              │              │              │              │
           ▼              ▼              ▼              ▼              ▼
         (none)      ms_route-db    ms_user-db    ms_booking-db  ms_promotion-db
                     (Port 3307)    (Port 3308)    (Port 3309)    (Port 3310)
```

---

## 2. Cấu trúc cây thư mục (Directory Structure)

Ở thư mục gốc chỉ xuất hiện file điều phối và tài liệu, toàn bộ cấu hình & scripts được gom gọn vào thư mục `config/`:

```
infra/vps-microservices/
├── .env.example                               # File mẫu biến môi trường (copy sang .env)
├── docker-compose.yml                         # Cấu hình lõi (Nginx, Tunnel, Webhook, Autoheal) + include
├── README.md                                  # Tài liệu kiến trúc & hướng dẫn vận hành
├── .generated/                                # Thư mục sinh tự động (được gitignore hoàn toàn)
│   ├── services.env                           # Biến môi trường, port và subdomain động
│   └── docker-compose.services.yml            # Khối dịch vụ microservices & databases tự sinh
│
└── config/                                    # Toàn bộ cấu hình & scripts vận hành
    ├── scripts/                               # Các script tự động hoá
    │   ├── auto-deploy.sh                     # [MASTER] Script tự động hoá A-Z
    │   ├── generate-configs.sh                # Script quét backend & sinh config
    │   └── cli.txt                            # Hướng dẫn thao tác nhanh
    │
    ├── cloudflared/                           # Cấu hình Cloudflare Tunnel
    │   ├── config.yml                         # Ingress rules trỏ domain về ms-nginx:80
    │   ├── credentials.json.example           # Mẫu credentials của Cloudflare Tunnel
    │   └── setup-tunnel.sh                    # Script thiết lập Tunnel & định tuyến DNS
    │
    ├── nginx/                                 # Reverse Proxy động
    │   ├── nginx.conf                         # Cấu hình lõi Nginx
    │   └── default.conf.template              # Template server blocks (sinh tự động)
    │
    ├── webhook/                               # Service restart container từ xa
    │   ├── Dockerfile                         # Build webhook container
    │   ├── hooks.json                         # Định nghĩa endpoint restart bảo vệ bằng token
    │   └── scripts/restart.sh                 # Script thực thi restart app/database
    │
    └── microservices/                         # Dữ liệu khởi tạo (Liquibase CSV)
        └── data/msroute/                      # Dữ liệu mẫu CSV (tuyến đường, trạm, xe,...)
```

---

## 3. Hướng dẫn vận hành

### A. Triển khai tự động hoàn toàn (Khuyên dùng)

Chỉ bằng **1 lệnh duy nhất**, hệ thống sẽ:
1. Kéo Git mới nhất (Root repo + đệ quy Submodules `backend/*`).
2. Tự quét thư mục `backend/` tìm microservices (loại trừ `docker-compose`).
3. Mò vào từng service trong `backend/<service>/` đọc file `consul-kv.yml` và đẩy lên Consul KV.
4. Tự sinh `config/services.env`, `docker-compose.yml`, `config/nginx/default.conf.template`, cập nhật DNS và Webhook.
4. Tự sinh `.generated/services.env`, `docker-compose.yml`, `config/nginx/default.conf.template`, cập nhật DNS và Webhook.
5. Tự build Docker Image qua Maven Jib cho từng service.
6. Chạy `docker compose up -d --remove-orphans` và restart Nginx.

```bash
cd infra/vps-microservices
./config/scripts/auto-deploy.sh
```

### B. Các tuỳ chọn nâng cao

```bash
# Bỏ qua bước git pull (dùng mã nguồn hiện tại trên VPS)
./config/scripts/auto-deploy.sh --skip-pull

# Bỏ qua bước build image Docker (chỉ cập nhật config và reload container)
./config/scripts/auto-deploy.sh --skip-build

# Chỉ quét service và sinh lại toàn bộ file cấu hình
./config/scripts/auto-deploy.sh --config-only

# Hoặc chỉ chạy script sinh cấu hình độc lập:
./config/scripts/generate-configs.sh
```

---

## 4. Quản lý cấu hình Consul KV theo chuẩn Microservices

- Mỗi microservice tự đóng gói file cấu hình Consul của chính nó tại:
  `backend/<service>/consul-kv.yml`
- Khi tạo service mới (ví dụ `backend/ms_payment`), script sẽ tự tạo sẵn file `consul-kv.yml` ngay trong thư mục service đó và đẩy lên Consul mà không cần bất kỳ thao tác thủ công nào.

