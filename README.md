# OlyAI Office — Server Installation

Internal AI assistant. Backend runs as a **binary** (no Python/pip required). LLM (vLLM) runs on a separate server.

## Architecture

```
┌─────────────────────┐       ┌──────────────────────┐
│  Backend Server     │       │  LLM Server          │
│  (this server)      │ ────▶ │  (separate, GPU)     │
│                     │       │                      │
│  - olyai-backend    │       │  - vLLM              │
│  - PostgreSQL       │       │  - Ollama (embed)    │
│  - Redis            │       │                      │
└─────────────────────┘       └──────────────────────┘
```

## Requirements

**Backend server** (this server):
- OS: Ubuntu 22.04+ / Debian 12+ / Rocky/RHEL 9+
- x86_64 architecture
- 4GB RAM, 20GB disk

**LLM server** (separate, with GPU):
- vLLM or Ollama exposing an OpenAI-compatible API
- Default endpoint: `http://your-llm-server:8001/v1`

## Quick install (1 command)

```bash
curl -fsSL https://raw.githubusercontent.com/openlay/oly-ai-office-release/main/olyai.sh -o olyai.sh \
  && chmod +x olyai.sh \
  && sudo bash olyai.sh install
```

The script automatically:
1. Installs PostgreSQL + pgvector + Redis
2. Downloads the `olyai-backend` binary into `/opt/oly-ai-office/`
3. Creates `.env` with default config
4. Runs database migrations
5. Starts the systemd service on port 8000

## Configure the LLM server

After install, edit `/opt/oly-ai-office/.env`:

```bash
sudo nano /opt/oly-ai-office/.env
```

Update URLs:
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

## Connect from Mac/iOS app

Open **OlyAI Office** app → Workspace picker → enter:
```
http://YOUR_SERVER_IP:8000
```

## Update

```bash
sudo bash olyai.sh update
```

The script:
1. Downloads the latest binary
2. Runs new migrations (if any)
3. Restarts the service

## Management commands

```bash
sudo systemctl status olyai
sudo systemctl restart olyai
sudo journalctl -u olyai -f         # Real-time log
sudo journalctl -u olyai -n 100     # Last 100 log lines
```

## Ports

| Port | Service |
|------|---------|
| 8000 | Backend API (olyai-backend) |
| 5432 | PostgreSQL |
| 6379 | Redis |

Open firewall for the API:
```bash
sudo ufw allow 8000
```

## Directory structure

```
/opt/oly-ai-office/
├── olyai-backend        # Binary executable (~80MB)
├── .env                 # Config
└── uploads/             # Uploaded documents

/etc/systemd/system/
└── olyai.service        # Systemd unit
```

## Troubleshooting

### Service fails to start
```bash
sudo journalctl -u olyai -n 50 --no-pager
```

### Port 8000 in use
```bash
sudo lsof -i :8000
```

### Reset database (careful!)
```bash
sudo -u postgres psql -c "DROP DATABASE olyai;"
sudo -u postgres psql -c "CREATE DATABASE olyai;"
sudo -u postgres psql -d olyai -c "CREATE EXTENSION vector;"
cd /opt/oly-ai-office && ./olyai-backend --run-migrations
sudo systemctl restart olyai
```

### Cannot connect to LLM
Verify the endpoint in `.env`:
```bash
curl http://your-llm-server:8001/v1/models
```

## LLM server setup (reference)

On a separate GPU server, install vLLM:

```bash
# vLLM Qwen 32B (requires 2x GPU 80GB+)
pip install vllm
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --served-model-name olyai-fast \
  --tensor-parallel-size 2 \
  --max-model-len 32768 \
  --port 8001

# Ollama for embeddings
curl -fsSL https://ollama.com/install.sh | sh
ollama pull nomic-embed-text
```

## License

Internal use only.

## Support

Issues: [GitHub Issues](https://github.com/openlay/oly-ai-office-release/issues)
