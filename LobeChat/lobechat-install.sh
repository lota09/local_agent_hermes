#!/usr/bin/env bash
# =============================================================================
# LobeChat 설치 스크립트 (Docker 전용)
# 대상: Ubuntu
# LLM 백엔드: OpenAI API 호환 엔드포인트 전부 지원
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }

LOBECHAT_HOME="$HOME/.lobechat"
LOBECHAT_ENV="$LOBECHAT_HOME/.env"
LOBECHAT_MCP="$LOBECHAT_HOME/mcp-config.json"
LOBECHAT_PORT=3210

# ── 1. 사전 조건 확인 ──────────────────────────────────────────────────────
check_prerequisites() {
    step "사전 조건 확인"

    # ── Docker 확인 ────────────────────────────────────────────────────────
    if ! command -v docker &>/dev/null; then
        # Docker 바이너리 자체가 없음 → sudo로 설치 시도
        info "Docker가 없습니다. sudo로 설치를 시도합니다..."

        if ! sudo -n true 2>/dev/null; then
            error "Docker가 없고 sudo 권한도 없습니다.
  관리자에게 아래 명령어 실행을 요청하세요:
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker ${USER}"
        fi

        # 만료된 서드파티 저장소가 apt를 막는 경우 비활성화
        info "apt 저장소 정리 중..."
        sudo apt-get update -qq 2>/dev/null || {
            warn "apt update 실패 — 문제 있는 저장소를 비활성화합니다"
            sudo find /etc/apt/sources.list.d/ -name "*.list" \
                -exec bash -c 'sudo apt-get update 2>&1 | grep -q "$(basename "$1" .list)" && sudo mv "$1" "$1.disabled"' _ {} \; 2>/dev/null || true
        }

        curl -fsSL https://get.docker.com | sudo sh \
            || error "Docker 설치 실패. 위 오류를 확인하세요."
        sudo systemctl enable --now docker
        info "Docker 설치 완료"
    fi

    # ── Docker 권한 확인 ───────────────────────────────────────────────────
    if ! docker info &>/dev/null 2>&1; then
        # Docker는 있지만 현재 사용자에게 권한 없음
        warn "현재 사용자(${USER})가 docker 그룹에 없습니다."

        if sudo -n true 2>/dev/null; then
            info "sudo로 docker 그룹에 추가합니다..."
            sudo usermod -aG docker "$USER"
            ok "docker 그룹 추가 완료"
        else
            error "docker 그룹 권한이 없고 sudo도 불가합니다.
  관리자에게 아래 명령어 실행을 요청하세요:
    sudo usermod -aG docker ${USER}
  이후 재로그인하고 install.sh를 다시 실행하세요."
        fi

        warn "그룹 변경 적용을 위해 재로그인이 필요합니다."
        warn "재로그인 후 lobechat-install.sh를 다시 실행하세요."
        warn "또는 지금 바로 적용하려면: newgrp docker (이후 install.sh 재실행)"
        exit 0
    fi

    ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

    # ── curl, python3 확인 ─────────────────────────────────────────────────
    command -v curl   &>/dev/null || error "curl 없음. 관리자에게 'sudo apt install curl' 요청하세요."
    command -v python3 &>/dev/null || error "python3 없음. 관리자에게 'sudo apt install python3' 요청하세요."
    ok "사전 조건 확인 완료"
}

# ── 2. LobeChat 이미지 다운로드 ────────────────────────────────────────────
install_lobechat() {
    step "LobeChat Docker 이미지 다운로드"

    info "lobehub/lobe-chat:latest 다운로드 중..."
    docker pull lobehub/lobe-chat:latest
    ok "이미지 다운로드 완료"
}

# ── 3. LLM 프로바이더 설정 ─────────────────────────────────────────────────
configure_llm() {
    step "LLM 프로바이더 설정"

    echo "  지원 백엔드 (OpenAI API 호환이면 전부 동작):"
    echo
    echo "  1) llama.cpp   기본 포트 8080  → http://localhost:8080/v1"
    echo "  2) llama.cpp   기본 포트 11436 → http://localhost:11436/v1"
    echo "  3) Ollama      기본 포트 11434 → http://localhost:11434/v1"
    echo "  4) LM Studio   기본 포트 1234  → http://localhost:1234/v1"
    echo "  5) vLLM        기본 포트 8000  → http://localhost:8000/v1"
    echo "  6) Jan.ai      기본 포트 1337  → http://localhost:1337/v1"
    echo "  7) 직접 입력"
    echo

    read -rp "백엔드 선택 [1-7] (기본값 2, llama.cpp:11436): " BACKEND_CHOICE
    BACKEND_CHOICE="${BACKEND_CHOICE:-2}"

    case "$BACKEND_CHOICE" in
        1) DEFAULT_URL="http://localhost:8080/v1";  DEFAULT_KEY="" ;;
        2) DEFAULT_URL="http://localhost:11436/v1"; DEFAULT_KEY="" ;;
        3) DEFAULT_URL="http://localhost:11434/v1"; DEFAULT_KEY="ollama" ;;
        4) DEFAULT_URL="http://localhost:1234/v1";  DEFAULT_KEY="lm-studio" ;;
        5) DEFAULT_URL="http://localhost:8000/v1";  DEFAULT_KEY="" ;;
        6) DEFAULT_URL="http://localhost:1337/v1";  DEFAULT_KEY="jan" ;;
        *) DEFAULT_URL=""; DEFAULT_KEY="" ;;
    esac

    echo
    read -rp "API Base URL [기본: ${DEFAULT_URL:-직접입력}]: " API_BASE_URL
    API_BASE_URL="${API_BASE_URL:-$DEFAULT_URL}"
    [[ -n "$API_BASE_URL" ]] || error "API Base URL을 입력해야 합니다."

    read -rp "API Key [기본: '${DEFAULT_KEY}'] (로컬 서버는 빈칸도 가능): " API_KEY
    API_KEY="${API_KEY:-$DEFAULT_KEY}"

    # 연결 테스트
    echo
    info "LLM 서버 연결 테스트 중: ${API_BASE_URL}/models"
    if curl -sf \
        ${API_KEY:+-H "Authorization: Bearer ${API_KEY}"} \
        "${API_BASE_URL}/models" &>/dev/null; then
        ok "LLM 서버 응답 확인"
        curl -sf \
            ${API_KEY:+-H "Authorization: Bearer ${API_KEY}"} \
            "${API_BASE_URL}/models" \
            | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    models = [m.get('id','?') for m in data.get('data', [])]
    for m in models[:10]: print(f'    - {m}')
    if len(models) > 10: print(f'    ... 외 {len(models)-10}개')
except: pass
" 2>/dev/null || true
    else
        warn "LLM 서버에 연결할 수 없습니다. LobeChat 실행 전에 먼저 시작하세요."
    fi

    echo
    read -rp "기본 모델명 입력 (예: Gemma-4-E4B-Uncensored-HauhauCS-Aggressive): " MODEL_NAME
    MODEL_NAME="${MODEL_NAME:-default}"

    echo
    info "웹 UI 접근 비밀번호 설정 (외부 노출 시 권장)"
    read -rp "접근 코드(비밀번호) 입력 (없으면 Enter): " ACCESS_CODE

    # Docker는 host.docker.internal로 호스트에 접근
    # localhost → host.docker.internal 자동 변환
    DOCKER_LLM_URL="${API_BASE_URL//localhost/host.docker.internal}"

    mkdir -p "$LOBECHAT_HOME"
    cat > "$LOBECHAT_ENV" <<EOF
# LobeChat 설정 (자동 생성)
# 수정 후 ./lobechat-run.sh restart 로 적용

# ── 포트 ────────────────────────────────────────────
LOBECHAT_PORT=${LOBECHAT_PORT}

# ── LLM 백엔드 ──────────────────────────────────────
# Docker 컨테이너 내부에서 호스트 접근: host.docker.internal
OPENAI_API_KEY=${API_KEY}
OPENAI_PROXY_URL=${DOCKER_LLM_URL}
CUSTOM_MODELS=${MODEL_NAME}
DEFAULT_MODEL=${MODEL_NAME}

# ── 보안 ────────────────────────────────────────────
ACCESS_CODE=${ACCESS_CODE}

# ── 기능 플래그 ─────────────────────────────────────
FEATURE_FLAGS="-dalle"
EOF

    ok "LLM 설정 완료: ${MODEL_NAME} @ ${API_BASE_URL}"
    info "Docker용 URL 변환: ${API_BASE_URL} → ${DOCKER_LLM_URL}"
    info "설정 파일: $LOBECHAT_ENV"
}

# ── 4. MCP 서버 설정 ───────────────────────────────────────────────────────
configure_mcp() {
    step "MCP 서버 설정"

    echo
    echo "  MCP 서버는 npx로 실행 — 별도 설치 없이 자동 다운로드됩니다."
    echo "  API 키가 필요한 서버만 입력받습니다."
    echo

    echo "  ─ 웹검색 ────────────────────────────────────────────────"
    echo "  Tavily  : https://app.tavily.com       (월 1,000회 무료)"
    echo "  Brave   : https://api.search.brave.com (월 2,000회 무료)"
    echo
    read -rp "Tavily API 키 (없으면 Enter): " TAVILY_KEY
    read -rp "Brave Search API 키 (없으면 Enter): " BRAVE_KEY
    echo

    echo "  ─ 파일시스템 접근 경로 ──────────────────────────────────"
    echo "  AI가 읽기/쓰기할 수 있는 디렉터리를 지정합니다."
    read -rp "허용 경로 [기본: $HOME]: " FS_PATH
    FS_PATH="${FS_PATH:-$HOME}"
    echo

    info "MCP 설정 파일 생성 중: $LOBECHAT_MCP"

    python3 - <<PYEOF
import json, os

fs_path = "${FS_PATH}"
tavily_key = "${TAVILY_KEY}"
brave_key = "${BRAVE_KEY}"

config = {"mcpServers": {}}

config["mcpServers"]["filesystem"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", fs_path],
    "description": "파일 읽기/쓰기/검색"
}
config["mcpServers"]["fetch"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-fetch"],
    "description": "URL 내용 가져오기"
}
config["mcpServers"]["puppeteer"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-puppeteer"],
    "description": "브라우저 자동화"
}
config["mcpServers"]["sequential-thinking"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"],
    "description": "단계별 복잡한 추론"
}
config["mcpServers"]["memory"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-memory"],
    "description": "세션 간 영구 메모리"
}

if tavily_key:
    config["mcpServers"]["tavily-search"] = {
        "command": "npx",
        "args": ["-y", "tavily-mcp@0.1.4"],
        "env": {"TAVILY_API_KEY": tavily_key},
        "description": "Tavily 웹검색"
    }

if brave_key:
    config["mcpServers"]["brave-search"] = {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-brave-search"],
        "env": {"BRAVE_API_KEY": brave_key},
        "description": "Brave 웹검색"
    }

if not tavily_key and not brave_key:
    print("\033[1;33m[WARN]  웹검색 API 키 미설정\033[0m")

os.makedirs(os.path.dirname("${LOBECHAT_MCP}"), exist_ok=True)
with open("${LOBECHAT_MCP}", "w") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print(f"\033[0;32m[OK]    MCP 설정 완료 ({len(config['mcpServers'])}개 서버)\033[0m")
for name, cfg in config["mcpServers"].items():
    print(f"         • {name}: {cfg.get('description', '')}")
PYEOF

    echo
    info "LobeChat 웹 UI에서 MCP 활성화:"
    info "  Settings → Tools → MCP Servers"
    info "  설정 파일 참조: $LOBECHAT_MCP"
}

# ── 5. systemd 사용자 서비스 등록 ─────────────────────────────────────────
install_service() {
    step "systemd 사용자 서비스 등록"

    mkdir -p "$HOME/.config/systemd/user"
    SERVICE_FILE="$HOME/.config/systemd/user/lobechat.service"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=LobeChat (Docker)
After=docker.service network.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker stop lobechat
ExecStartPre=-/usr/bin/docker rm lobechat
ExecStart=/usr/bin/docker run --rm --name lobechat \\
    -p ${LOBECHAT_PORT}:3210 \\
    --add-host=host.docker.internal:host-gateway \\
    --env-file ${LOBECHAT_ENV} \\
    lobehub/lobe-chat:latest
ExecStop=/usr/bin/docker stop lobechat

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable lobechat
    ok "lobechat systemd 서비스 등록 완료"

    # loginctl linger: 로그아웃 후에도 서비스 유지
    if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
        ok "loginctl linger 활성화 → 로그아웃 후에도 서비스 유지"
    else
        warn "linger 미활성화 (sudo 필요)"
        warn "관리자에게 요청: sudo loginctl enable-linger ${USER}"
        warn "미설정 시 SSH 세션 종료 시 서비스도 종료될 수 있음"
    fi
}

# ── 6. Caddy 설정 안내 ─────────────────────────────────────────────────────
print_caddy_hint() {
    step "Caddy 리버스프록시 설정 안내"

    echo
    echo "  외부에서 안전하게 접속하려면 Caddyfile에 아래 블록을 추가하세요:"
    echo
    echo -e "${BOLD}  ── 추가할 Caddyfile 블록 ───────────────────────────────${NC}"
    echo
    cat <<CADDY
  your-domain.com:포트번호 {
      basicauth {
          아이디 \$해시값   # caddy hash-password 로 생성
      }
      reverse_proxy localhost:${LOBECHAT_PORT}
      tls internal
  }
CADDY
    echo
    info "적용: caddy reload --config ~/.caddy/Caddyfile"
    info "포트 ${LOBECHAT_PORT} 외부 직접접근 차단: sudo ufw deny ${LOBECHAT_PORT}"
}

# ── 7. 완료 요약 ───────────────────────────────────────────────────────────
print_summary() {
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR_SERVER_IP')"

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        LobeChat 설치 완료!               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
    echo "  ─ 서비스 관리 ──────────────────────────────────────"
    echo "  ./lobechat-run.sh start     # 시작"
    echo "  ./lobechat-run.sh stop      # 정지"
    echo "  ./lobechat-run.sh status    # 상태 확인"
    echo "  ./lobechat-run.sh logs      # 실시간 로그"
    echo "  ./lobechat-run.sh update    # 최신 버전 업데이트"
    echo "  ./lobechat-run.sh config    # LLM 설정 변경"
    echo
    echo "  ─ 접속 주소 ─────────────────────────────────────────"
    echo "  로컬:  http://localhost:${LOBECHAT_PORT}"
    echo "  외부:  http://${LOCAL_IP}:${LOBECHAT_PORT} (Caddy 통해 접속 권장)"
    echo
    echo "  ─ 설정 파일 ─────────────────────────────────────────"
    echo "  LLM/설정: $LOBECHAT_ENV"
    echo "  MCP 참조: $LOBECHAT_MCP"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   LobeChat 설치 스크립트 (Docker 전용)    ${NC}"
    echo -e "${BOLD}   Ubuntu | llama.cpp / OpenAI 호환        ${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo

    check_prerequisites
    install_lobechat
    configure_llm
    configure_mcp
    install_service
    print_caddy_hint
    print_summary
}

main "$@"
