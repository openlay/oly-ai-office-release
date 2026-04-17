#!/bin/bash
# OlyAI Office - Install & Update Script
# Download:
#   curl -fsSL https://raw.githubusercontent.com/openlay/oly-ai-office-release/main/olyai.sh -o olyai.sh && chmod +x olyai.sh
# Install:  sudo bash olyai.sh install
# Update:   sudo bash olyai.sh update

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
err()    { echo -e "${RED}[✗]${NC} $1"; }
header() { echo -e "\n${CYAN}--- $1 ---${NC}"; }

APP_DIR="/opt/oly-ai-office"
REPO_URL="https://github.com/openlay/oly-ai-office-release.git"
TMP_DIR="/tmp/oly-ai-office-release"

# ==================== INSTALL ====================

do_install() {
    echo "============================================"
    echo "  OlyAI Office - Full Installation"
    echo "============================================"

    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        err "Cannot detect OS"; exit 1
    fi
    log "OS: $OS $VERSION_ID"

    # ---------- System packages ----------
    header "System dependencies"

    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y -qq \
            postgresql postgresql-contrib redis-server \
            python3 python3-pip python3-venv \
            build-essential postgresql-server-dev-all \
            git curl rsync poppler-utils
    elif [[ "$OS" == "rocky" || "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
        dnf install -y \
            postgresql-server postgresql-contrib redis \
            python3 python3-pip python3-devel \
            gcc make postgresql-devel \
            git curl rsync poppler-utils
        postgresql-setup --initdb 2>/dev/null || true
    else
        err "Unsupported OS: $OS"; exit 1
    fi
    log "Done"

    # ---------- PostgreSQL ----------
    header "PostgreSQL"

    systemctl enable postgresql && systemctl start postgresql
    sudo -u postgres psql -c "CREATE DATABASE olyai;" 2>/dev/null && log "Database created" || warn "Database exists"
    sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';" 2>/dev/null

    # pgvector
    if ! sudo -u postgres psql -d olyai -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null; then
        warn "Building pgvector from source..."
        cd /tmp && rm -rf pgvector
        git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git
        cd pgvector && make -j$(nproc) 2>&1 | tail -1 && make install 2>&1 | tail -1
        sudo -u postgres psql -d olyai -c "CREATE EXTENSION IF NOT EXISTS vector;"
    fi
    log "pgvector ready"

    # Allow local auth
    PG_HBA=$(find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1)
    if [ -n "$PG_HBA" ]; then
        sed -i 's/local.*all.*postgres.*peer/local   all   postgres   trust/' "$PG_HBA" 2>/dev/null || true
        systemctl restart postgresql
    fi
    log "PostgreSQL ready"

    # ---------- Redis ----------
    header "Redis"
    systemctl enable redis-server 2>/dev/null || systemctl enable redis 2>/dev/null
    systemctl start redis-server 2>/dev/null || systemctl start redis 2>/dev/null
    log "Redis ready"

    # ---------- GPU check ----------
    header "GPU"
    if command -v nvidia-smi &>/dev/null; then
        GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
        log "$GPU_COUNT GPU(s): $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
    else
        warn "No GPU detected — vLLM requires CUDA GPU"
    fi

    # ---------- vLLM + Ollama (for embeddings) ----------
    header "LLM servers"

    # Ollama for embeddings only
    if ! command -v ollama &>/dev/null; then
        curl -fsSL https://ollama.com/install.sh | sh
    fi
    systemctl enable ollama 2>/dev/null || true
    systemctl start ollama 2>/dev/null || true
    sleep 3

    # Pull embedding model (small)
    ollama pull nomic-embed-text 2>&1 | tail -1
    log "Ollama (embeddings) ready"

    # vLLM for chat models
    pip3 install vllm -q 2>&1 | tail -1 || warn "vLLM install failed"

    # vLLM 32B service (Qwen 32B on GPU 0+1 TP=2)
    cat > /etc/systemd/system/vllm.service << 'VEOF'
[Unit]
Description=vLLM 32B Model Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-32B-Instruct \
    --served-model-name olyai-fast \
    --tensor-parallel-size 2 \
    --max-model-len 32768 \
    --port 8001 \
    --trust-remote-code \
    --gpu-memory-utilization 0.65
Restart=always
RestartSec=10
Environment=CUDA_VISIBLE_DEVICES=0,1
Environment=HF_HOME=/root/.cache/huggingface

[Install]
WantedBy=multi-user.target
VEOF

    # vLLM 7B service (on GPU 1)
    cat > /etc/systemd/system/vllm-7b.service << 'VEOF'
[Unit]
Description=vLLM 7B Model Server
After=vllm.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-7B-Instruct \
    --served-model-name olyai-dev \
    --max-model-len 16384 \
    --port 8002 \
    --trust-remote-code \
    --gpu-memory-utilization 0.25
Restart=always
RestartSec=10
Environment=CUDA_VISIBLE_DEVICES=1
Environment=HF_HOME=/root/.cache/huggingface

[Install]
WantedBy=multi-user.target
VEOF

    systemctl daemon-reload
    systemctl enable vllm vllm-7b 2>/dev/null || true
    log "vLLM services configured (will start after model download)"

    # ---------- MongoDB (optional datasource) ----------
    header "MongoDB (optional)"
    if ! command -v mongosh &>/dev/null; then
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
            echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list
            apt-get update -qq && apt-get install -y -qq mongodb-org
            systemctl enable mongod && systemctl start mongod
            log "MongoDB 7.0 installed"
        else
            warn "MongoDB skip — install manually if needed"
        fi
    else
        log "MongoDB already installed"
    fi

    # ---------- Download release code ----------
    header "Download OlyAI code"

    rm -rf "$TMP_DIR"
    git clone "$REPO_URL" "$TMP_DIR"

    mkdir -p "$APP_DIR/uploads"
    rsync -a --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
        "$TMP_DIR/backend/" "$APP_DIR/backend/"
    log "Code copied to $APP_DIR"

    setup_backend

    # ---------- Systemd for backend ----------
    header "Backend systemd service"

    cat > /etc/systemd/system/olyai.service << SEOF
[Unit]
Description=OlyAI Office Backend
After=network.target postgresql.service redis.service vllm.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR/backend
Environment=PYTHONPATH=$APP_DIR/backend
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=$APP_DIR/backend/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --timeout-keep-alive 0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SEOF
    systemctl daemon-reload
    systemctl enable olyai
    systemctl restart olyai
    log "Backend service started"

    print_summary
}

# ==================== UPDATE ====================

do_update() {
    echo "============================================"
    echo "  OlyAI Office - Update"
    echo "============================================"

    header "Pull latest code from release repo"
    if [ -d "$TMP_DIR/.git" ]; then
        cd "$TMP_DIR" && git pull origin main 2>&1 | tail -3
    else
        rm -rf "$TMP_DIR"
        git clone "$REPO_URL" "$TMP_DIR"
    fi
    log "Code updated"

    header "Sync backend"
    rsync -a --exclude='.git' --exclude='.venv' --exclude='__pycache__' --exclude='.env' --exclude='alembic/versions' \
        "$TMP_DIR/backend/" "$APP_DIR/backend/"
    cp -n "$TMP_DIR/backend/alembic/versions/"*.py "$APP_DIR/backend/alembic/versions/" 2>/dev/null || true
    log "Files synced"

    setup_backend

    header "Restart"
    systemctl restart olyai
    sleep 2
    if systemctl is-active --quiet olyai; then
        log "Service restarted"
    else
        warn "Service failed. Check: journalctl -u olyai -n 20"
    fi

    sleep 1
    HEALTH=$(curl -s http://localhost:8000/health 2>/dev/null)
    if echo "$HEALTH" | grep -q "ok"; then
        log "Health: $HEALTH"
    else
        warn "API not ready yet"
    fi

    echo ""
    echo -e "${GREEN}Update complete!${NC}"
}

# ==================== SHARED ====================

setup_backend() {
    header "Python dependencies"
    cd "$APP_DIR/backend"
    [ -d ".venv" ] || python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip -q
    pip install \
        fastapi "uvicorn[standard]" "sqlalchemy[asyncio]" asyncpg alembic \
        pydantic pydantic-settings openai "python-jose[cryptography]" \
        bcrypt python-multipart redis sse-starlette pgvector httpx \
        email-validator openpyxl python-docx aiomysql motor \
        google-api-python-client google-auth-httplib2 google-auth-oauthlib \
        google-cloud-bigquery duckduckgo-search \
        -q 2>&1 | tail -1
    log "Dependencies installed"

    # .env
    if [ ! -f .env ]; then
        header "Creating .env"
        SECRET=$(openssl rand -hex 32)
        cat > .env << EOF
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/olyai
REDIS_URL=redis://localhost:6379/0
OLLAMA_BASE_URL=http://localhost:8001/v1
OLLAMA_MODEL=olyai-fast
OLLAMA_EMBEDDING_MODEL=nomic-embed-text
EMBEDDING_BASE_URL=http://localhost:11434
SECRET_KEY=$SECRET
DEBUG=false
EOF
        log ".env created (uses vLLM at port 8001, Ollama at 11434 for embeddings)"
    fi

    # Migrations
    header "Database migrations"
    export PYTHONPATH="$APP_DIR/backend"
    alembic upgrade head 2>&1 | tail -3
    log "Migrations applied"
}

print_summary() {
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo ""
    echo "============================================"
    echo -e "  ${GREEN}Installation Complete!${NC}"
    echo "============================================"
    echo ""
    echo "  Backend API:  http://$IP:8000"
    echo "  API Docs:     http://$IP:8000/docs"
    echo "  Health:       http://$IP:8000/health"
    echo ""
    echo "  LLM Servers:"
    echo "    vLLM 32B:   http://$IP:8001/v1  (Qwen 32B)"
    echo "    vLLM 7B:    http://$IP:8002/v1  (Qwen 7B)"
    echo "    Ollama:     http://$IP:11434    (embeddings)"
    echo ""
    echo "  Start vLLM (downloads models on first start):"
    echo "    systemctl start vllm       # Qwen 32B (~65GB download)"
    echo "    systemctl start vllm-7b    # Qwen 7B (~15GB download)"
    echo ""
    echo "  Commands:"
    echo "    systemctl status olyai"
    echo "    systemctl restart olyai"
    echo "    journalctl -u olyai -f"
    echo "    journalctl -u vllm -f"
    echo ""
    echo "  Update:  sudo bash olyai.sh update"
    echo "============================================"
}

# ==================== MAIN ====================

case "${1:-}" in
    install)
        do_install
        ;;
    update)
        do_update
        ;;
    *)
        echo "Usage: sudo bash olyai.sh [install|update]"
        echo ""
        echo "  install  - Full installation (first time)"
        echo "  update   - Pull latest code & restart"
        exit 1
        ;;
esac
