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
    header "Download latest binary"
    curl -fSL "$BINARY_URL" -o "$APP_DIR/olyai-backend.new"
    chmod +x "$APP_DIR/olyai-backend.new"
    mv "$APP_DIR/olyai-backend.new" "$APP_DIR/olyai-backend"
    log "Binary updated"

    run_migrations

    header "Restart"
    systemctl restart olyai
    sleep 2
    if systemctl is-active --quiet olyai; then
        log "Service restarted"
    else
        warn "Service failed. Check: journalctl -u olyai -n 30"
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
