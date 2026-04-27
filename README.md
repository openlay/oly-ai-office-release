# OlyAI Office — Server Installation

Internal AI assistant. Backend runs as a **binary** (no Python/pip required). LLM (vLLM) runs on a separate server.

**Current release: v1.3.0** — see [CHANGELOG](#changelog) below.

## Downloads

| Artifact | File | Size |
|---|---|---|
| Backend (Linux x86_64, systemd) | [`bin/olyai-backend-linux-x86_64`](bin/olyai-backend-linux-x86_64) | ~83 MB |
| macOS app (Universal: Intel + Apple Silicon) | [`bin/OlyAI-macOS.zip`](bin/OlyAI-macOS.zip) | ~4 MB |

### macOS app — install in 30 seconds

```bash
# Download + unzip
curl -fsSL https://raw.githubusercontent.com/openlay/oly-ai-office-release/main/bin/OlyAI-macOS.zip -o OlyAI.zip
unzip OlyAI.zip -d /Applications/
xattr -cr /Applications/OlyAI.app    # required: clear quarantine attr from download
open /Applications/OlyAI.app
```

If macOS still warns *"App can't be opened because Apple cannot check it"*: System Settings → Privacy & Security → scroll to "OlyAI was blocked..." → **Open Anyway**. After first run, no more prompts.

App runs on: **macOS 14.0+** (Sonoma), Intel + Apple Silicon. Ad-hoc signed (no Apple Developer account needed for end users).

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

### v1.3.0 (2026-04-27)

**New features:**
- **Document editor in app.** New "Tạo mới (editor)" entry in the Documents menu opens a Markdown editor with toolbar (Bold, Italic, H1-H3, lists, code, links, table template), live split preview, multi-context picker (attach to 1+ contexts), and a "Test Summary" button that previews the AI's understanding before saving.
- **Edit existing text-authored docs.** Tap a row that was created via the editor to re-open and edit. Backend re-chunks + re-embeds + regenerates summary on save.
- **App icon.** Added `Assets.xcassets/AppIcon.appiconset` with 22 sizes generated from `icons/ai-ai-svgrepo-com.svg`. Icon shows in Dock, Cmd-Tab switcher, Finder.
- **macOS app available as binary.** Universal (Intel + Apple Silicon), ad-hoc signed, ships in `bin/OlyAI-macOS.zip`. End users need no Apple Developer account.

**API additions:**
- `POST   /api/v1/documents/text` — body `{filename, content, context_ids[]}`
- `PATCH  /api/v1/documents/{id}/text` — partial update; soft-deletes old chunks + re-embeds when content changes
- `POST   /api/v1/documents/preview-summary` — body `{content}` → AI summary without saving

**Schema:**
- `documents.raw_content TEXT NULL` — added (auto-migrated via `Base.metadata.create_all` on startup). NULL for uploaded files; Markdown source for text-authored docs.

**Internal:**
- `apple/Config/Shared.xcconfig` — added `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
- `apple/Config/Local.xcconfig.template` — documented Mode A (Apple ID) vs Mode B (no signing) so devs without an Apple Developer account can still open Xcode IDE

### v1.2.0 (2026-04-20)

**New features:**
- **Google Sheets API — configure once in Settings.** New section in Settings to paste the service-account JSON one time; all Google Sheets datasources automatically share those credentials. No more copy-pasting the JSON into every datasource form. Service account email is displayed prominently so you know which address to share the sheet with.
- **Add Google Sheets datasource simplified.** The form now asks only for the sheet ID or URL — you can paste the full `https://docs.google.com/spreadsheets/d/.../edit#gid=0` link and the app extracts the ID automatically (both client-side and server-side as a safety net). The form also displays the service-account email with a one-click Copy button.
- **New `user_settings` table.** Per-user global settings (currently only Google service-account JSON, extensible to other API keys in the future). Auto-created on backend startup via `Base.metadata.create_all`.
- **Anti-hallucination on database tool failure.** When a `query_database` call fails (sheet not found, permission denied, etc.), the tool response now explicitly lists available tables/sheets and instructs the LLM not to fabricate data. Previously the AI would invent plausible numbers when it couldn't read the sheet.

**Bug fixes:**
- Fixed `sqlalchemy.exc.InvalidRequestError: A transaction is already begun on this Session` when querying Google Sheets mid-chat — `resolve_google_credentials` now uses a fresh DB session instead of reusing the request's active session.
- Fixed `POST /api/v1/models` returning 500 on missing fields — now validates via Pydantic `CustomModelCreate` → 422 with detail.
- Fixed stale signing settings (`DEVELOPMENT_TEAM = <team>`) being written into `apple/OlyAI.xcodeproj/project.pbxproj` every time a dev with a different Apple ID opened Xcode. Moved signing config to xcconfig files so pbxproj stays clean across machines.
- Fixed `build_cli.sh` leaving a stripped `project.pbxproj` on disk if the build failed or was interrupted (`trap` now always restores the backup).
- Added `.gitattributes` with `merge=union` for `project.pbxproj` to reduce merge conflicts when multiple devs add files simultaneously.

**API additions:**
- `GET /api/v1/user-settings` — returns `{google_service_account: {configured, client_email}}` with secrets masked.
- `PUT /api/v1/user-settings/google-service-account` — body `{credentials_json}`; validates JSON is a `service_account` with `client_email`.
- `DELETE /api/v1/user-settings/google-service-account` — clears stored credentials.

**Internal:**
- Added `backend/run_testcases.py` improvements — now 50 auto-run test cases including 9 new tests for `/api/v1/user-settings` and Google Sheets URL auto-extract.
- `backend/tests/testcase.md` — test-case specification expanded.

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
