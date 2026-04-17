# OlyAI Office — Server Installation

Trợ lý AI nội bộ. Backend chạy dưới dạng **binary** (không cần Python/pip). LLM (vLLM) chạy trên server khác.

## Kiến trúc

```
┌─────────────────────┐       ┌──────────────────────┐
│  Backend Server     │       │  LLM Server          │
│  (server này)       │ ────▶ │  (khác, có GPU)      │
│                     │       │                      │
│  - olyai-backend    │       │  - vLLM              │
│  - PostgreSQL       │       │  - Ollama (embed)    │
│  - Redis            │       │                      │
└─────────────────────┘       └──────────────────────┘
```

## Yêu cầu

**Backend server** (server này):
- OS: Ubuntu 22.04+ / Debian 12+ / Rocky/RHEL 9+
- x86_64
- 4GB RAM, 20GB disk

**LLM server** (riêng, có GPU):
- vLLM hoặc Ollama chạy OpenAI-compatible API
- Endpoint mặc định: `http://your-llm-server:8001/v1`

## Cài đặt nhanh (1 lệnh)

```bash
curl -fsSL https://raw.githubusercontent.com/openlay/oly-ai-office-release/main/olyai.sh -o olyai.sh \
  && chmod +x olyai.sh \
  && sudo bash olyai.sh install
```

Script tự động:
1. Cài PostgreSQL + pgvector + Redis
2. Download binary `olyai-backend` vào `/opt/oly-ai-office/`
3. Tạo `.env` với config mặc định
4. Chạy migrations
5. Khởi động systemd service trên port 8000

## Cấu hình LLM server

Sau khi cài, edit `/opt/oly-ai-office/.env`:

```bash
sudo nano /opt/oly-ai-office/.env
```

Đổi các URL:
```env
OLLAMA_BASE_URL=http://your-llm-server:8001/v1   # vLLM endpoint
EMBEDDING_BASE_URL=http://your-llm-server:11434  # Ollama for embeddings
```

Restart:
```bash
sudo systemctl restart olyai
```

## Test

```bash
# Health check
curl http://localhost:8000/health

# API docs
open http://YOUR_SERVER_IP:8000/docs
```

## Kết nối từ Mac/iOS app

Mở app **OlyAI Office** → Workspace picker → nhập:
```
http://YOUR_SERVER_IP:8000
```

## Update

```bash
sudo bash olyai.sh update
```

Script:
1. Download binary mới nhất
2. Chạy migrations mới (nếu có)
3. Restart service

## Lệnh quản lý

```bash
sudo systemctl status olyai
sudo systemctl restart olyai
sudo journalctl -u olyai -f         # Xem log real-time
sudo journalctl -u olyai -n 100     # Xem 100 dòng log gần nhất
```

## Ports

| Port | Service |
|------|---------|
| 8000 | Backend API (olyai-backend) |
| 5432 | PostgreSQL |
| 6379 | Redis |

Mở firewall cho API:
```bash
sudo ufw allow 8000
```

## Cấu trúc

```
/opt/oly-ai-office/
├── olyai-backend        # Binary executable (~80MB)
├── .env                 # Config
└── uploads/             # Uploaded documents

/etc/systemd/system/
└── olyai.service        # Systemd unit
```

## Troubleshooting

### Service không start
```bash
sudo journalctl -u olyai -n 50 --no-pager
```

### Port 8000 bị chiếm
```bash
sudo lsof -i :8000
```

### Reset database (cẩn thận!)
```bash
sudo -u postgres psql -c "DROP DATABASE olyai;"
sudo -u postgres psql -c "CREATE DATABASE olyai;"
sudo -u postgres psql -d olyai -c "CREATE EXTENSION vector;"
cd /opt/oly-ai-office && ./olyai-backend --run-migrations
sudo systemctl restart olyai
```

### Không kết nối được LLM
Kiểm tra endpoint trong `.env` có đúng không:
```bash
curl http://your-llm-server:8001/v1/models
```

## Setup LLM server (tham khảo)

Trên server GPU riêng, cài vLLM:

```bash
# vLLM Qwen 32B (2x GPU 80GB+)
pip install vllm
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --served-model-name olyai-fast \
  --tensor-parallel-size 2 \
  --max-model-len 32768 \
  --port 8001

# Ollama cho embeddings
curl -fsSL https://ollama.com/install.sh | sh
ollama pull nomic-embed-text
```

## License

Internal use only.

## Hỗ trợ

Issues: [GitHub Issues](https://github.com/openlay/oly-ai-office-release/issues)
