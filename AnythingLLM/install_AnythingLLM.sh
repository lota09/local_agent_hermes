#!/usr/bin/env bash
# =============================================================================
# AnythingLLM 설치 스크립트 (Docker 전용)
# 대상: Ubuntu
# LLM 백엔드: OpenAI API 호환 엔드포인트 전부 지원 (generic-openai 프로바이더)
# 특징: 네이티브 MCP 지원, File System Agent(로컬 파일 읽기/쓰기), 내장 임베딩/벡터DB
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }

ANYTHINGLLM_HOME="$HOME/.anythingllm"
STORAGE_LOCATION="$ANYTHINGLLM_HOME/storage"
ENV_FILE="$STORAGE_LOCATION/.env"
MCP_DIR="$STORAGE_LOCATION/plugins"
MCP_CONFIG="$MCP_DIR/anythingllm_mcp_servers.json"
ANYTHINGLLM_PORT=3001
CONTAINER_NAME="anythingllm"
IMAGE="mintplexlabs/anythingllm:latest"

FS_HOST_PATH=""   # File System Agent에 노출할 호스트 경로 (비우면 비활성)

# ── 1. 사전 조건 확인 ──────────────────────────────────────────────────────
check_prerequisites() {
    step "사전 조건 확인"

    # ── Docker 확인 ────────────────────────────────────────────────────────
    if ! command -v docker &>/dev/null; then
        info "Docker가 없습니다. sudo로 설치를 시도합니다..."

        if ! sudo -n true 2>/dev/null; then
            error "Docker가 없고 sudo 권한도 없습니다.
  관리자에게 아래 명령어 실행을 요청하세요:
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker ${USER}"
        fi

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
        warn "현재 사용자(${USER})가 docker 그룹에 없습니다."

        if sudo -n true 2>/dev/null; then
            info "sudo로 docker 그룹에 추가합니다..."
            sudo usermod -aG docker "$USER"
            ok "docker 그룹 추가 완료"
        else
            error "docker 그룹 권한이 없고 sudo도 불가합니다.
  관리자에게 아래 명령어 실행을 요청하세요:
    sudo usermod -aG docker ${USER}
  이후 재로그인하고 install_AnythingLLM.sh를 다시 실행하세요."
        fi

        warn "그룹 변경 적용을 위해 재로그인이 필요합니다."
        warn "재로그인 후 install_AnythingLLM.sh를 다시 실행하세요."
        warn "또는 지금 바로 적용하려면: newgrp docker (이후 install 스크립트 재실행)"
        exit 0
    fi

    ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

    command -v curl    &>/dev/null || error "curl 없음. 관리자에게 'sudo apt install curl' 요청하세요."
    command -v python3 &>/dev/null || error "python3 없음. 관리자에게 'sudo apt install python3' 요청하세요."
    command -v openssl &>/dev/null || error "openssl 없음. 관리자에게 'sudo apt install openssl' 요청하세요."
    ok "사전 조건 확인 완료"
}

# ── 2. AnythingLLM 이미지 다운로드 ────────────────────────────────────────
pull_image() {
    step "AnythingLLM Docker 이미지 다운로드"

    info "${IMAGE} 다운로드 중..."
    docker pull "$IMAGE"
    ok "이미지 다운로드 완료"

    mkdir -p "$STORAGE_LOCATION" "$MCP_DIR"
    touch "$ENV_FILE"
    ok "저장소 디렉터리 준비 완료: $STORAGE_LOCATION"
}

# ── 3. LLM 백엔드 설정 ─────────────────────────────────────────────────────
configure_llm() {
    step "LLM 백엔드 설정 (generic-openai 프로바이더)"

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

    read -rp "API Key [기본: '${DEFAULT_KEY}'] (로컬 서버는 아무 값이나 입력): " API_KEY
    API_KEY="${API_KEY:-$DEFAULT_KEY}"
    # AnythingLLM은 빈 API 키를 거부함 → 로컬 서버용 placeholder 자동 설정
    [[ -z "$API_KEY" ]] && API_KEY="local"

    # 연결 테스트 및 모델 목록 자동 조회
    echo
    info "LLM 서버 연결 테스트 중: ${API_BASE_URL}/models"
    MODEL_NAME="default"
    if curl -sf \
        ${API_KEY:+-H "Authorization: Bearer ${API_KEY}"} \
        "${API_BASE_URL}/models" &>/dev/null; then
        ok "LLM 서버 응답 확인"
        FIRST_MODEL=$(curl -sf \
            ${API_KEY:+-H "Authorization: Bearer ${API_KEY}"} \
            "${API_BASE_URL}/models" \
            | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    models=[m.get('id','') for m in d.get('data',[])]
    for m in models[:10]: print(f'    - {m}')
    print('__FIRST__:' + models[0] if models else '')
except: pass
" 2>/dev/null | tee /dev/stderr | grep '__FIRST__:' | cut -d: -f2 || true)
        [[ -n "$FIRST_MODEL" ]] && MODEL_NAME="$FIRST_MODEL"
    else
        warn "LLM 서버에 연결할 수 없습니다. 나중에 시작 후 설정에서 변경 가능합니다."
    fi

    echo
    read -rp "사용할 모델명 [기본: ${MODEL_NAME}]: " INPUT_MODEL
    MODEL_NAME="${INPUT_MODEL:-$MODEL_NAME}"

    read -rp "모델 컨텍스트 토큰 한도 [기본: 8192]: " TOKEN_LIMIT
    TOKEN_LIMIT="${TOKEN_LIMIT:-8192}"

    # Docker 컨테이너 내부에서 호스트 접근: localhost → host.docker.internal
    DOCKER_LLM_URL="${API_BASE_URL//localhost/host.docker.internal}"

    ok "LLM 설정 완료: ${MODEL_NAME} @ ${API_BASE_URL}"
    info "Docker용 URL: ${DOCKER_LLM_URL}"
}

# ── 4. File System Agent 설정 (로컬 파일 읽기/쓰기) ───────────────────────
configure_filesystem_agent() {
    step "File System Agent 설정 (로컬 파일 읽기/쓰기)"

    echo "  AnythingLLM 에이전트가 호스트의 특정 폴더를 읽고 쓸 수 있게 합니다."
    echo "  보안을 위해 폴더 단위로만 허용되며, 기본은 비활성입니다."
    echo
    read -rp "File System Agent를 활성화하시겠습니까? [y/N]: " ENABLE_FS
    if [[ "${ENABLE_FS,,}" == "y" ]]; then
        read -rp "허용할 호스트 경로 [기본: $HOME]: " FS_HOST_PATH
        FS_HOST_PATH="${FS_HOST_PATH:-$HOME}"
        [[ -d "$FS_HOST_PATH" ]] || error "경로가 존재하지 않습니다: $FS_HOST_PATH"
        ok "File System Agent 활성화: ${FS_HOST_PATH} (컨테이너 내부: /app/server/storage/anythingllm-fs)"
        info "설치 후 UI에서 켜야 합니다: Settings → Agent Skills → File System"
    else
        FS_HOST_PATH=""
        info "File System Agent 비활성 (나중에 install 스크립트 재실행으로 추가 가능)"
    fi
}

# ── 5. MCP 서버 설정 ───────────────────────────────────────────────────────
configure_mcp() {
    step "MCP 서버 설정 (네이티브 지원)"

    echo
    echo "  MCP 서버는 컨테이너 내부에서 npx로 실행 — 별도 설치 없이 자동 다운로드됩니다."
    echo "  API 키가 필요한 서버만 입력받습니다."
    echo

    echo "  ─ 웹검색 ────────────────────────────────────────────────"
    echo "  Tavily  : https://app.tavily.com       (월 1,000회 무료)"
    echo "  Brave   : https://api.search.brave.com (월 2,000회 무료)"
    echo
    read -rp "Tavily API 키 (없으면 Enter): " TAVILY_KEY
    read -rp "Brave Search API 키 (없으면 Enter): " BRAVE_KEY
    echo

    info "MCP 설정 파일 생성 중: $MCP_CONFIG"
    mkdir -p "$MCP_DIR"

    python3 - <<PYEOF
import json, os

fs_path = "${FS_HOST_PATH}"
tavily_key = "${TAVILY_KEY}"
brave_key = "${BRAVE_KEY}"

config = {"mcpServers": {}}

if fs_path:
    config["mcpServers"]["filesystem"] = {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/app/server/storage/anythingllm-fs"],
        "description": "파일 읽기/쓰기/검색"
    }
config["mcpServers"]["fetch"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-fetch"],
    "description": "URL 내용 가져오기"
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

os.makedirs(os.path.dirname("${MCP_CONFIG}"), exist_ok=True)
with open("${MCP_CONFIG}", "w") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print(f"\033[0;32m[OK]    MCP 설정 완료 ({len(config['mcpServers'])}개 서버)\033[0m")
for name, cfg in config["mcpServers"].items():
    print(f"         • {name}: {cfg.get('description', '')}")
PYEOF

    echo
    info "AnythingLLM 웹 UI에서 MCP 확인/활성화:"
    info "  Settings → Agent Skills → MCP Servers"
    info "  설정 파일 참조: $MCP_CONFIG"
}

# ── 6. .env 파일 생성 ──────────────────────────────────────────────────────
write_env() {
    step ".env 생성"

    info "보안 키 자동 생성 중..."
    JWT_SECRET="$(openssl rand -hex 32)"
    SIG_KEY="$(openssl rand -hex 32)"
    SIG_SALT="$(openssl rand -hex 32)"

    cat > "$ENV_FILE" <<EOF
# AnythingLLM 설정 (자동 생성 — install_AnythingLLM.sh)
# 수정 후 ./run_AnythingLLM.sh restart 로 적용

# ── 서버 ────────────────────────────────────────────
SERVER_PORT=3001
STORAGE_DIR="/app/server/storage"

# ── 보안 키 (자동 생성, 멀티유저 모드 사용 시 필요) ──
JWT_SECRET=${JWT_SECRET}
SIG_KEY=${SIG_KEY}
SIG_SALT=${SIG_SALT}

# ── LLM 백엔드 (OpenAI 호환 커스텀 엔드포인트) ──────
LLM_PROVIDER='generic-openai'
GENERIC_OPEN_AI_BASE_PATH='${DOCKER_LLM_URL}'
GENERIC_OPEN_AI_MODEL_PREF='${MODEL_NAME}'
GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT=${TOKEN_LIMIT}
GENERIC_OPEN_AI_API_KEY=${API_KEY}

# ── 임베딩 / 벡터DB (경량 내장형 기본값, 별도 서버 불필요) ──
EMBEDDING_ENGINE='native'
VECTOR_DB='lancedb'

# ── 스크립트 전용 설정 (앱 자체에서는 사용하지 않음) ──
ANYTHINGLLM_PORT=${ANYTHINGLLM_PORT}
FS_HOST_PATH=${FS_HOST_PATH}
EOF

    ok ".env 생성 완료: $ENV_FILE"
}

# ── 7. 컨테이너 시작 ───────────────────────────────────────────────────────
start_anythingllm() {
    step "AnythingLLM 시작"

    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm   "$CONTAINER_NAME" 2>/dev/null || true

    FS_ARGS=""
    [[ -n "$FS_HOST_PATH" ]] && FS_ARGS="-v ${FS_HOST_PATH}:/app/server/storage/anythingllm-fs"

    info "컨테이너 시작 중..."
    # shellcheck disable=SC2086
    docker run -d \
        --name "$CONTAINER_NAME" \
        --cap-add SYS_ADMIN \
        -p "${ANYTHINGLLM_PORT}:3001" \
        --add-host=host.docker.internal:host-gateway \
        -v "${STORAGE_LOCATION}:/app/server/storage" \
        -v "${ENV_FILE}:/app/server/.env" \
        $FS_ARGS \
        "$IMAGE" \
        > /dev/null

    info "서비스 기동 대기 중..."
    for i in $(seq 1 12); do
        sleep 5
        if curl -sf "http://localhost:${ANYTHINGLLM_PORT}" &>/dev/null; then
            ok "AnythingLLM 응답 확인 (${i}번째 시도, $((i*5))초)"
            break
        fi
        info "  대기 중... ($((i*5))초)"
    done

    if ! curl -sf "http://localhost:${ANYTHINGLLM_PORT}" &>/dev/null; then
        warn "60초 내 응답 없음 — 로그 확인:"
        docker logs --tail=30 "$CONTAINER_NAME"
        warn "서비스가 아직 초기화 중일 수 있습니다. 잠시 후: ./run_AnythingLLM.sh status"
    fi
}

# ── 8. systemd 사용자 서비스 등록 ─────────────────────────────────────────
install_service() {
    step "systemd 사용자 서비스 등록"

    mkdir -p "$HOME/.config/systemd/user"
    SERVICE_FILE="$HOME/.config/systemd/user/anythingllm.service"

    FS_ARGS=""
    [[ -n "$FS_HOST_PATH" ]] && FS_ARGS="-v ${FS_HOST_PATH}:/app/server/storage/anythingllm-fs"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnythingLLM (Docker)
After=docker.service network.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker stop ${CONTAINER_NAME}
ExecStartPre=-/usr/bin/docker rm ${CONTAINER_NAME}
ExecStart=/usr/bin/docker run --rm --name ${CONTAINER_NAME} --cap-add SYS_ADMIN -p ${ANYTHINGLLM_PORT}:3001 --add-host=host.docker.internal:host-gateway -v ${STORAGE_LOCATION}:/app/server/storage -v ${ENV_FILE}:/app/server/.env ${FS_ARGS} ${IMAGE}
ExecStop=/usr/bin/docker stop ${CONTAINER_NAME}

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable anythingllm
    ok "anythingllm systemd 서비스 등록 완료 (부팅 시 자동 시작)"

    if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
        ok "loginctl linger 활성화 → 로그아웃 후에도 서비스 유지"
    else
        warn "linger 미활성화 (sudo 필요)"
        warn "관리자에게 요청: sudo loginctl enable-linger ${USER}"
        warn "미설정 시 SSH 세션 종료 시 서비스도 종료될 수 있음"
    fi
}

# ── 9. 완료 요약 ───────────────────────────────────────────────────────────
print_summary() {
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR_SERVER_IP')"

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        AnythingLLM 설치 완료!            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
    echo "  ─ 첫 접속 ──────────────────────────────────────────"
    echo "  브라우저에서: http://localhost:${ANYTHINGLLM_PORT}"
    echo "  외부 접속:    http://${LOCAL_IP}:${ANYTHINGLLM_PORT}"
    echo
    echo -e "  ${YELLOW}※ 첫 접속 시 관리자 계정을 생성하게 됩니다.${NC}"
    echo
    echo "  ─ 서비스 관리 ──────────────────────────────────────"
    echo "  ./run_AnythingLLM.sh start    # 시작"
    echo "  ./run_AnythingLLM.sh stop     # 정지"
    echo "  ./run_AnythingLLM.sh status   # 상태 확인"
    echo "  ./run_AnythingLLM.sh logs     # 실시간 로그"
    echo "  ./run_AnythingLLM.sh update   # 최신 버전 업데이트"
    echo "  ./run_AnythingLLM.sh config   # LLM/설정 변경"
    echo "  ./run_AnythingLLM.sh mcp      # MCP 서버 목록 확인"
    echo
    echo "  ─ 설정 파일 위치 ────────────────────────────────────"
    echo "  .env:        ${ENV_FILE}"
    echo "  MCP 설정:    ${MCP_CONFIG}"
    echo "  저장소:      ${STORAGE_LOCATION}"
    [[ -n "$FS_HOST_PATH" ]] && echo "  파일 에이전트 허용 경로: ${FS_HOST_PATH}"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   AnythingLLM 설치 스크립트 (Docker 전용) ${NC}"
    echo -e "${BOLD}   Ubuntu | llama.cpp / OpenAI 호환        ${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo

    check_prerequisites
    pull_image
    configure_llm
    configure_filesystem_agent
    configure_mcp
    write_env
    start_anythingllm
    install_service
    print_summary
}

main "$@"
