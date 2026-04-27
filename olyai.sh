#!/bin/bash
# OlyAI Office - Install & Update Script (binary-based, no Python needed)
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
REPO_RAW="https://raw.githubusercontent.com/openlay/oly-ai-office-release/main"
BINARY_URL="$REPO_RAW/bin/olyai-backend-linux-x86_64"

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        err "Cannot detect OS"; exit 1
    fi
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
        err "Unsupported architecture: $ARCH (only x86_64 supported)"; exit 1
    fi
    log "OS: $OS $VERSION_ID ($ARCH)"
}

install_system_deps() {
    header "System dependencies"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y -qq \
            postgresql postgresql-contrib redis-server \
            build-essential postgresql-server-dev-all \
            git curl rsync poppler-utils openssl
    elif [[ "$OS" == "rocky" || "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
        dnf install -y \
            postgresql-server postgresql-contrib redis \
            gcc make postgresql-devel \
            git curl rsync poppler-utils openssl
        postgresql-setup --initdb 2>/dev/null || true
    else
        err "Unsupported OS: $OS"; exit 1
    fi
    log "Done"
}

setup_postgres() {
    header "PostgreSQL + pgvector"
    systemctl enable postgresql && systemctl start postgresql
    sudo -u postgres psql -c "CREATE DATABASE olyai;" 2>/dev/null && log "Database created" || warn "Database exists"
    sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';" 2>/dev/null

    if ! sudo -u postgres psql -d olyai -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null; then
        warn "Building pgvector from source..."
        cd /tmp && rm -rf pgvector
        git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git
        cd pgvector && make -j$(nproc) 2>&1 | tail -1 && make install 2>&1 | tail -1
        sudo -u postgres psql -d olyai -c "CREATE EXTENSION IF NOT EXISTS vector;"
    fi

    PG_HBA=$(find /etc/postgresql /var/lib/pgsql -name pg_hba.conf 2>/dev/null | head -1)
    if [ -n "$PG_HBA" ]; then
        sed -i 's/local.*all.*postgres.*peer/local   all   postgres   trust/' "$PG_HBA" 2>/dev/null || true
        systemctl restart postgresql
    fi
    log "PostgreSQL ready"
}

setup_redis() {
    header "Redis"
    systemctl enable redis-server 2>/dev/null || systemctl enable redis 2>/dev/null
    systemctl start redis-server 2>/dev/null || systemctl start redis 2>/dev/null
    log "Redis ready"
}

setup_ollama_embedding() {
    header "Ollama (for document embeddings)"
    if command -v ollama >/dev/null 2>&1; then
        log "Ollama already installed: $(ollama --version 2>&1 | head -1)"
    else
        warn "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh 2>&1 | tail -3
        log "Ollama installed"
    fi

    # Make sure service is running (install script usually does this on systemd hosts)
    systemctl enable ollama 2>/dev/null || true
    systemctl start ollama 2>/dev/null || true
    sleep 2

    # Wait up to 30s for the API to be ready
    for i in {1..15}; do
        if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    # Pull the embedding model (idempotent — skips if already present)
    if curl -sf http://localhost:11434/api/tags 2>/dev/null | grep -q nomic-embed-text; then
        log "nomic-embed-text already pulled"
    else
        warn "Pulling nomic-embed-text (~270MB, one-time)..."
        ollama pull nomic-embed-text 2>&1 | tail -3
        log "nomic-embed-text ready"
    fi
}

download_binary() {
    header "Download OlyAI binary"
    mkdir -p "$APP_DIR"
    curl -fSL "$BINARY_URL" -o "$APP_DIR/olyai-backend"
    chmod +x "$APP_DIR/olyai-backend"
    SIZE=$(du -h "$APP_DIR/olyai-backend" | cut -f1)
    log "Binary downloaded ($SIZE)"
}

setup_env() {
    header "Environment config"
    mkdir -p "$APP_DIR/uploads"
    if [ ! -f "$APP_DIR/.env" ]; then
        SECRET=$(openssl rand -hex 32)
        cat > "$APP_DIR/.env" << EOF
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/olyai
REDIS_URL=redis://localhost:6379/0
OLLAMA_BASE_URL=http://localhost:8001/v1
OLLAMA_MODEL=olyai-fast
OLLAMA_EMBEDDING_MODEL=nomic-embed-text
EMBEDDING_BASE_URL=http://localhost:11434
SECRET_KEY=$SECRET
DEBUG=false
EOF
        log ".env created at $APP_DIR/.env"
    else
        log ".env exists"
    fi
}

run_migrations() {
    header "Database migrations"
    cd "$APP_DIR"
    set -a; source .env; set +a
    ./olyai-backend --run-migrations 2>&1 | tail -5
    log "Migrations done"
}

create_service() {
    header "Systemd service"
    cat > /etc/systemd/system/olyai.service << SEOF
[Unit]
Description=OlyAI Office Backend
After=network.target postgresql.service redis.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=$APP_DIR/olyai-backend
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SEOF
    systemctl daemon-reload
    systemctl enable olyai
    systemctl restart olyai
    log "Service created & started"
}

# ==================== INSTALL ====================

do_install() {
    echo "============================================"
    echo "  OlyAI Office - Full Installation"
    echo "============================================"

    detect_os
    install_system_deps
    setup_postgres
    setup_redis
    setup_ollama_embedding
    download_binary
    setup_env
    run_migrations
    create_service

    print_summary
}

# ==================== UPDATE ====================

do_update() {
    echo "============================================"
    echo "  OlyAI Office - Update"
    echo "============================================"

    detect_os

    # Capture BEFORE version (from running service if alive)
    OLD_VER=$(curl -s --max-time 3 http://localhost:8000/api/v1/admin/version 2>/dev/null \
              | grep -oE '"current"[^,}]*' | grep -oE '"[0-9.]+"' | tr -d '"' | head -1)
    [ -z "$OLD_VER" ] && OLD_VER="unknown"

    header "Check remote version"
    REMOTE_VER=$(curl -s --max-time 5 "$REPO_RAW/VERSION" 2>/dev/null | tr -d '[:space:]')
    [ -z "$REMOTE_VER" ] && REMOTE_VER="unknown"
    echo -e "  Current:  ${YELLOW}${OLD_VER}${NC}"
    echo -e "  Remote:   ${GREEN}${REMOTE_VER}${NC}"
    if [ "$OLD_VER" = "$REMOTE_VER" ] && [ "$OLD_VER" != "unknown" ]; then
        warn "Already on latest version ${REMOTE_VER}. Re-installing anyway..."
    fi

    header "Download latest binary"
    curl -fSL "$BINARY_URL" -o "$APP_DIR/olyai-backend.new"
    chmod +x "$APP_DIR/olyai-backend.new"
    mv "$APP_DIR/olyai-backend.new" "$APP_DIR/olyai-backend"
    SIZE=$(du -h "$APP_DIR/olyai-backend" | cut -f1)
    log "Binary updated ($SIZE)"

    run_migrations

    header "Restart"
    systemctl restart olyai
    sleep 2
    if systemctl is-active --quiet olyai; then
        log "Service restarted"
    else
        warn "Service failed. Check: journalctl -u olyai -n 30"
    fi

    # Wait up to 20s for API
    NEW_VER="unknown"
    for i in {1..10}; do
        sleep 2
        HEALTH=$(curl -s --max-time 3 http://localhost:8000/health 2>/dev/null)
        if echo "$HEALTH" | grep -q "ok"; then
            VER_RESP=$(curl -s --max-time 3 http://localhost:8000/api/v1/admin/version 2>/dev/null)
            NEW_VER=$(echo "$VER_RESP" | grep -oE '"current"[^,}]*' | grep -oE '"[0-9.]+"' | tr -d '"' | head -1)
            [ -z "$NEW_VER" ] && NEW_VER="unknown"
            break
        fi
    done

    echo ""
    echo "============================================"
    if [ "$NEW_VER" = "$REMOTE_VER" ] && [ "$NEW_VER" != "unknown" ]; then
        echo -e "  ${GREEN}✓ UPDATE SUCCESS${NC}"
        echo -e "    ${YELLOW}${OLD_VER}${NC}  →  ${GREEN}${NEW_VER}${NC}"
    elif [ "$NEW_VER" != "unknown" ]; then
        echo -e "  ${YELLOW}⚠ UPDATE PARTIAL${NC}"
        echo -e "    Running: ${YELLOW}${NEW_VER}${NC}  (expected ${REMOTE_VER})"
        echo "    Maybe restart didn't pick up new binary? Try:"
        echo "      sudo systemctl restart olyai"
    else
        echo -e "  ${RED}✗ UPDATE INCOMPLETE${NC} — service not responding"
        echo "    Check: sudo journalctl -u olyai -n 50 --no-pager"
    fi
    echo "============================================"
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
    echo "  LLM server:"
    echo "    Set OLLAMA_BASE_URL in $APP_DIR/.env to point to your"
    echo "    vLLM/Ollama server (default: http://localhost:8001/v1)"
    echo "    Then: sudo systemctl restart olyai"
    echo ""
    echo "  Commands:"
    echo "    systemctl status olyai"
    echo "    systemctl restart olyai"
    echo "    journalctl -u olyai -f"
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
        echo "  update   - Download latest binary & restart"
        exit 1
        ;;
esac
