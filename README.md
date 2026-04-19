# OlyAI Office — Server Installation

Internal AI assistant. Backend runs as a **binary** (no Python/pip required). LLM (vLLM) runs on a separate server.

**Current release: v1.1.0** — see [CHANGELOG](#changelog) below.

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

## Changelog

### v1.1.0 (2026-04-19)

**New features:**
- **Deep Research** — multi-step AI research agent. Toggle 🔬 in chat → planner breaks question into sub-questions → tool loop (web_search + fetch_url + query_database + search_documents) → synthesizes Markdown report with `[^N]` citations.
- **Default model auto-seed** — new users automatically get `olyai-fast`, `olyai-dev`, `olyai-deepseek` without manual setup. Seeded from `app/services/model_seed.py` on registration.
- **Preflight model check** — before starting research, backend pings the selected model. If unreachable, returns a clear error: `"⚠️ Model 'X' KHÔNG HOẠT ĐỘNG — server tại ... đang TẮT (cổng không mở). Hãy chọn model khác..."` instead of triple-erroring through planning + step + synthesis.
- **Conversation context for follow-ups** — follow-up research questions like "lập báo cáo từng tháng" after an oil-price research now reuse prior subject instead of generating generic plans.
- **Report copy** — research bubble has a "Copy" pill + right-click menu (Copy report / Copy with sources / Copy sources only).

**Bug fixes:**
- Fixed `GET /messages` returning 500 for conversations with research metadata — was caused by Pydantic `alias="metadata"` + `populate_by_name` reading SQLAlchemy's built-in `MetaData` registry instead of the `metadata_` column.
- Fixed assistant message not persisting after research — `sse_starlette` cancels the generator after the last `yield`, so save logic must run before yielding the final `done` event.
- Fixed Swift SSE parser getting stuck at "Các bước (0)" — `URLSessionAsyncBytes.lines` splits on `\n` only, so CRLF frame separators appear as `"\r"` strings, not empty. Parser now strips trailing `\r`.
- Fixed error banner ("Could not connect to the server") persisting across chat switches — `ChatViewModel.setConversation()` now clears `errorMessage` and `researchLive`.
- Fixed ResearchBubble disappearing on error — now retains the bubble with a red error banner inside, showing partial plan/steps if any.
- Fixed `POST /api/v1/models` returning 500 on missing fields — now validates via Pydantic `CustomModelCreate` → 422 with detail.
- Fixed `get_client_for_model` failing with "Multiple rows" when multiple users have the same model_id — query now scopes by `user_id`.

**Testing:**
- New `backend/tests/testcase.md` — 140-case specification document in Vietnamese
- New `backend/run_testcases.py` — standalone runner with per-case report, `--priority P0` smoke mode, `--markdown` export
- New `backend/tests/` pytest suite — 34 cases across 8 files (metadata, SSE format, persistence, context, preflight, errors, model seed, long conversation)

### v1.0.2

Initial binary release.
