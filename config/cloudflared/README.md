# 🌐 Cloudflare Tunnel - VPS Microservices

Thư mục này chứa cấu hình mạng Ingress và script tự động hóa Tunnel dành riêng cho cụm **VPS Microservices** (Gateway, User, Route, Booking, Promotion, và các MySQL riêng).

---

## 📁 Danh mục các file & kịch bản (Scripts)

| Tên File | Chức năng | Đối tượng áp dụng |
|---|---|---|
| `config.yml` | Cấu hình Ingress đón toàn bộ lưu lượng API công khai qua Wildcard `*.phungvip.io.vn` chuyển tới `ms-nginx:80`. | Container `ms-cloudflared`. |
| `credentials.json` | Khóa xác thực Tunnel của cụm Microservices (bảo vệ trong `.gitignore`). | Container `ms-cloudflared`. |
| `setup-tunnel.sh` | **Script thiết lập Tunnel**: Tự động tạo Tunnel, trỏ DNS các subdomain microservices (`apigateway`, `msuser`, `msroute`...), và đăng ký dải mạng nội bộ `172.19.0.0/16` cho WARP. | DevOps chạy khi triển khai VPS Microservices. |

---

## 🚀 Hướng dẫn sử dụng nhanh

### Khởi tạo hoặc cập nhật Tunnel & Định tuyến DNS Microservices:
```bash
./setup-tunnel.sh [tên_tunnel]
# Ví dụ: ./setup-tunnel.sh ridehub-ms-tunnel
```

---

## 🔗 Tích hợp mạng riêng cho Local Dev (WARP Private Network)
- Cụm Microservices chạy trên mạng Docker `ridehub-ms-network` với dải IP CIDR `172.19.0.0/16`.
- Script `setup-tunnel.sh` tự động đăng ký route `172.19.0.0/16` vào Tunnel. Khi dev bật Cloudflare WARP trên laptop cá nhân, dev có thể chọc thẳng vào MySQL của từng service (port 3306, 3307, 3308, 3309, 3310) để debug mà không cần public port ra ngoài Internet.
