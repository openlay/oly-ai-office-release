# OlyAI Office — Server Installation

Trợ lý AI nội bộ chạy trên server của bạn. Backend + LLM (vLLM) + PostgreSQL + pgvector + Redis + Ollama (embeddings).

## Yêu cầu

- **OS**: Ubuntu 22.04+ / Debian 12+ / Rocky/RHEL 9+
- **GPU**: NVIDIA với CUDA (tối thiểu 1x GPU 24GB cho Qwen 7B, 2x GPU 80GB+ cho Qwen 32B)
- **RAM**: 64GB+
- **Disk**: 200GB+ SSD (model weights ~80GB)
- **Quyền**: root hoặc sudo

## Cài đặt nhanh (1 lệnh)

```bash
curl -fsSL https://raw.githubusercontent.com/openlay/oly-ai-office-release/main/olyai.sh -o olyai.sh \
  && chmod +x olyai.sh \
  && sudo bash olyai.sh install
```

Script tự động:
1. Cài PostgreSQL + pgvector + Redis + Ollama + MongoDB
2. Clone backend code từ release repo vào `/opt/oly-ai-office`
3. Tạo Python venv, cài dependencies
4. Setup systemd services: `olyai`, `vllm`, `vllm-7b`
5. Chạy database migrations
6. Khởi động backend API trên port 8000

## Sau khi cài xong

### Bước 1: Khởi động LLM servers

```bash
# vLLM Qwen 32B (sẽ tự download ~65GB, mất 30-60 phút lần đầu)
sudo systemctl start vllm

# vLLM Qwen 7B (~15GB)
sudo systemctl start vllm-7b

# Theo dõi tiến trình
sudo journalctl -u vllm -f
```

### Bước 2: Kiểm tra

```bash
# Health check
curl http://localhost:8000/health

# Backend API docs
open http://YOUR_SERVER_IP:8000/docs

# Test chat (sau khi vLLM sẵn sàng)
curl http://localhost:8001/v1/models
```

### Bước 3: Kết nối từ Mac/iOS app

Mở app **OlyAI Office** → Workspace picker → nhập URL server:
```
http://YOUR_SERVER_IP:8000
```
Đăng ký tài khoản và sử dụng.

## Cấu hình ports

| Port | Service | Mô tả |
|------|---------|-------|
| 8000 | Backend API | FastAPI (chat, contexts, documents, ...) |
| 8001 | vLLM 32B | Qwen 2.5 32B Instruct |
| 8002 | vLLM 7B | Qwen 2.5 7B Instruct |
| 11434 | Ollama | Embeddings (nomic-embed-text) |
| 5432 | PostgreSQL | Database |
| 6379 | Redis | Cache/queue |
| 27017 | MongoDB | (Tuỳ chọn) Datasource |

Mở firewall cho port 8000:
```bash
sudo ufw allow 8000
```

## Update lên phiên bản mới

```bash
sudo bash olyai.sh update
```

Script tự động:
- Pull code mới từ GitHub release repo
- Sync vào `/opt/oly-ai-office/backend`
- Chạy migrations mới (nếu có)
- Restart backend

## Lệnh quản lý

```bash
# Status
sudo systemctl status olyai vllm vllm-7b

# Restart
sudo systemctl restart olyai

# Logs
sudo journalctl -u olyai -f      # Backend
sudo journalctl -u vllm -f        # vLLM 32B
sudo journalctl -u vllm-7b -f     # vLLM 7B

# Database
sudo -u postgres psql olyai
```

## Thêm model DeepSeek V3 670B (tuỳ chọn)

Nếu có GPU ≥ 4x H100/H200:

```bash
# Cần ~380GB VRAM hoặc quantization TQ1_0 (~170GB)
ollama pull hf.co/unsloth/DeepSeek-V3.1-GGUF:TQ1_0
```

Sau đó thêm custom model qua app Settings → Thêm model:
- Server URL: `http://localhost:11434/v1`
- Model name: `hf.co/unsloth/DeepSeek-V3.1-GGUF:TQ1_0`

## Troubleshooting

### vLLM không start
```bash
# Kiểm tra GPU free memory
nvidia-smi

# Nếu GPU bị chiếm, giảm gpu-memory-utilization trong
# /etc/systemd/system/vllm.service
```

### Backend lỗi 500
```bash
sudo journalctl -u olyai -n 50 --no-pager
```

### Port conflict
```bash
sudo lsof -i :8000    # Tìm process đang chiếm port
```

### Reset database (cẩn thận - mất data!)
```bash
sudo -u postgres psql -c "DROP DATABASE olyai;"
sudo -u postgres psql -c "CREATE DATABASE olyai;"
sudo bash olyai.sh update
```

## Cấu trúc thư mục

```
/opt/oly-ai-office/
├── backend/              # FastAPI code
│   ├── app/              # Application code
│   ├── alembic/          # Database migrations
│   ├── .venv/            # Python virtualenv
│   └── .env              # Config (DATABASE_URL, SECRET_KEY, ...)
└── uploads/              # Uploaded documents

/etc/systemd/system/
├── olyai.service         # Backend
├── vllm.service          # Qwen 32B
└── vllm-7b.service       # Qwen 7B
```

## License

Internal use only — not for redistribution.

## Hỗ trợ

Issues: [GitHub Issues](https://github.com/openlay/oly-ai-office-release/issues)
