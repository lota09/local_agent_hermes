#!/usr/bin/env bash
# =============================================================================
# AnythingLLM 설치 스크립트 (베어메탈 / Docker 미사용)
# 대상: Docker(dockerd)를 쓸 수 없는 환경 — chroot, proot-distro(Termux) 등
# LLM 백엔드: OpenAI API 호환 엔드포인트 전부 지원 (generic-openai 프로바이더)
# 참고: AnythingLLM 공식 BARE_METAL.md 기준 설치 절차
#       (공식 문서에도 "core team이 지원하지 않는 방식"이라고 명시되어 있음)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }

# 이 스크립트를 절대 sudo로 감싸서 실행하지 않도록 막는다.
# sudo로 실행하면 $HOME이 실행 계정(n20u 등)이 아니라 root의 홈으로 바뀌어서
# 설치 위치가 /root/anythingllm 로 조용히 바뀌는 사고가 난다 (실제로 겪었던 문제).
# 이 스크립트는 항상 일반 사용자로 실행하고, root 권한이 필요한 개별 명령만
# 내부에서 알아서 sudo를 사용한다.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo -e "${RED}[ERROR]${NC} 이 스크립트는 sudo로 실행하지 마세요."
    echo "  sudo ./install_AnythingLLM_baremetal.sh 처럼 실행하면 \$HOME이 /root로 바뀌어서"
    echo "  설치가 엉뚱하게 /root 밑에 들어갑니다."
    echo
    echo "  일반 사용자로 다시 실행하세요 (root 권한이 필요하면 스크립트가 알아서 물어봅니다):"
    echo "    ./install_AnythingLLM_baremetal.sh"
    exit 1
fi

ANYTHINGLLM_DIR="$HOME/anythingllm"
STORAGE_DIR="$ANYTHINGLLM_DIR/server/storage"
ENV_FILE="$ANYTHINGLLM_DIR/server/.env"
MCP_DIR="$STORAGE_DIR/plugins"
MCP_CONFIG="$MCP_DIR/anythingllm_mcp_servers.json"
ANYTHINGLLM_PORT=3001
PM2_SERVER="anythingllm-server"
PM2_COLLECTOR="anythingllm-collector"
MIN_NODE_MAJOR=18

FS_HOST_PATH=""   # File System Agent에 노출할 호스트 경로 (비우면 비활성)

# ── 환경 감지: sudo / systemd (chroot·proot 등 최소 환경 대비) ────────────
# 그냥 계정이 root인지(EUID 0)만으로도 충분하고, 아니라면 sudo "권한이 있는지"를
# 확인한다. 이때 -n(비대화형)만 쓰면 "비밀번호 없이 즉시 되는 경우"만 잡혀서
# 비밀번호가 필요한 일반적인 sudo 계정은 전부 "sudo 없음"으로 오판하게 된다
# (curl 자동설치가 계속 실패했던 원인). 그래서 -n이 실패하면 대화형 sudo -v로
# 한 번 더 확인하고, 이후엔 백그라운드에서 타임스탬프를 갱신해 설치 도중
# 비밀번호를 여러 번 묻지 않게 한다.
HAS_SUDO=false
_SUDO_KEEPALIVE_PID=""

_stop_sudo_keepalive() {
    [[ -n "$_SUDO_KEEPALIVE_PID" ]] && kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap _stop_sudo_keepalive EXIT

if [[ $EUID -eq 0 ]]; then
    HAS_SUDO=true
elif command -v sudo &>/dev/null; then
    if sudo -n true 2>/dev/null; then
        HAS_SUDO=true
    else
        info "일부 설치 단계에 관리자 권한이 필요합니다. sudo 비밀번호를 입력해주세요."
        if sudo -v 2>/dev/null; then
            HAS_SUDO=true
            ( while true; do sleep 60; sudo -n true 2>/dev/null || exit; done ) &
            _SUDO_KEEPALIVE_PID=$!
        fi
    fi
fi

HAS_SYSTEMD=false
[[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null && HAS_SYSTEMD=true

_APT_UPDATED=false
_apt_update_once() {
    [[ "$_APT_UPDATED" == true ]] && return 0
    info "apt 패키지 목록 갱신 중..."
    if sudo apt-get update -qq 2>/dev/null; then
        _APT_UPDATED=true
    else
        warn "apt update 실패 — 문제 있는 저장소를 비활성화하고 재시도합니다"
        sudo find /etc/apt/sources.list.d/ -name "*.list" \
            -exec bash -c 'sudo apt-get update 2>&1 | grep -q "$(basename "$1" .list)" && sudo mv "$1" "$1.disabled"' _ {} \; 2>/dev/null || true
        sudo apt-get update -qq 2>/dev/null && _APT_UPDATED=true
    fi
}

# 명령어가 없으면 apt로 자동 설치 — curl/wget/git/python3/openssl/build-essential
# 처럼 최소 chroot·proot 환경엔 아예 없을 수 있는 기본 도구들을 대비
ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    command -v "$cmd" &>/dev/null && return 0

    info "${cmd} 없음 — 설치를 시도합니다..."

    if ! command -v apt-get &>/dev/null; then
        error "${cmd}이(가) 없고 apt-get도 사용할 수 없는 환경입니다.
  이 환경의 패키지 매니저로 직접 설치해주세요: ${pkg}"
    fi
    if [[ "$HAS_SUDO" != true ]]; then
        error "${cmd}이(가) 없고 sudo 권한도 없습니다.
  관리자에게 요청: sudo apt install -y ${pkg}"
    fi

    _apt_update_once
    sudo apt-get install -y -qq "$pkg" \
        || error "${pkg} 설치 실패. 관리자에게 'sudo apt install -y ${pkg}' 요청하세요."

    command -v "$cmd" &>/dev/null || error "${cmd} 설치 후에도 PATH에서 찾을 수 없습니다."
    ok "${cmd} 설치 완료"
}

# node-gyp 네이티브 모듈 빌드용 (better-sqlite3 등) — 커맨드가 아니라
# 메타 패키지라 make/gcc 존재 여부로 우회 확인
ensure_build_tools() {
    ensure_cmd make build-essential
    ensure_cmd gcc  build-essential
}

# Node.js: v18 미만이거나 없으면 NodeSource로 설치/업그레이드
ensure_node() {
    if command -v node &>/dev/null; then
        local major
        major="$(node -v | sed 's/^v//' | cut -d. -f1)"
        if [[ "$major" -ge "$MIN_NODE_MAJOR" ]]; then
            ok "Node.js $(node -v) (요구 조건 충족: v${MIN_NODE_MAJOR}+)"
            return 0
        fi
        warn "설치된 Node.js가 너무 오래됨: $(node -v) (v${MIN_NODE_MAJOR}+ 필요) — NodeSource로 업그레이드합니다"
    else
        info "Node.js 없음 — NodeSource로 설치합니다..."
    fi

    command -v apt-get &>/dev/null || error "apt-get이 없어 Node.js를 자동 설치할 수 없습니다. Node.js v${MIN_NODE_MAJOR}+ 를 직접 설치해주세요."
    ensure_cmd curl curl
    [[ "$HAS_SUDO" == true ]] || error "sudo 권한이 없어 Node.js를 설치할 수 없습니다.
  관리자에게 요청:
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs"

    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - \
        || error "NodeSource 저장소 설정 실패"
    sudo apt-get install -y -qq nodejs \
        || error "Node.js 설치 실패"

    command -v node &>/dev/null || error "Node.js 설치 후에도 찾을 수 없습니다."
    ok "Node.js $(node -v) 설치 완료"
}

# npm install -g는 NodeSource로 설치한 Node처럼 전역 모듈 경로
# (/usr/lib/node_modules 등)가 root 소유인 경우 EACCES로 실패한다.
# 에러를 숨기지 않고 보여주되, sudo가 가능하면 자동으로 재시도한다.
_npm_install_global() {
    local pkg="$1"
    if npm install -g "$pkg"; then
        return 0
    fi

    if [[ "$HAS_SUDO" == true ]]; then
        warn "일반 권한으로 설치 실패 (전역 npm 디렉터리가 root 소유일 가능성) — sudo로 재시도합니다"
        sudo npm install -g "$pkg" && return 0
    fi

    return 1
}

ensure_yarn() {
    if command -v yarn &>/dev/null; then
        ok "yarn $(yarn --version)"
        return 0
    fi
    info "yarn 없음 — npm으로 설치합니다..."
    _npm_install_global yarn || error "yarn 설치 실패 (npm install -g yarn)"
    command -v yarn &>/dev/null || error "yarn 설치 후에도 PATH에서 찾을 수 없습니다.
  npm 전역 bin 경로를 확인하세요: npm config get prefix"
    ok "yarn $(yarn --version) 설치 완료"
}

ensure_pm2() {
    if command -v pm2 &>/dev/null; then
        ok "pm2 $(pm2 -v)"
        return 0
    fi
    info "pm2 없음 — npm으로 설치합니다..."
    _npm_install_global pm2 || error "pm2 설치 실패 (npm install -g pm2)"
    command -v pm2 &>/dev/null || error "pm2 설치 후에도 PATH에서 찾을 수 없습니다.
  npm 전역 bin 경로를 확인하세요: npm config get prefix"
    ok "pm2 설치 완료"
}

# ── 1. 사전 조건 확인 ──────────────────────────────────────────────────────
check_prerequisites() {
    step "사전 조건 확인 (베어메탈)"

    ensure_cmd curl curl
    ensure_cmd wget wget
    ensure_cmd git git
    ensure_cmd python3 python3
    ensure_cmd openssl openssl
    ensure_build_tools
    ensure_node
    ensure_yarn

    if [[ "$HAS_SYSTEMD" == true ]]; then
        ok "systemd 감지됨 — pm2 startup 등록을 시도합니다"
    else
        warn "systemd 없음 (chroot/proot 등 최소 환경) — 자동 시작은 pm2가 직접 관리, 재진입 시 수동 복구가 필요합니다"
    fi

    ok "사전 조건 확인 완료"
}

# ── 2. 소스 클론 ───────────────────────────────────────────────────────────
clone_anythingllm() {
    step "AnythingLLM 소스 클론"

    if [[ -d "$ANYTHINGLLM_DIR/.git" ]]; then
        warn "이미 클론된 소스 발견 ($ANYTHINGLLM_DIR)"
        read -rp "최신 버전으로 업데이트하시겠습니까? [y/N]: " UPDATE
        if [[ "${UPDATE,,}" == "y" ]]; then
            info "업데이트 중..."
            cd "$ANYTHINGLLM_DIR"
            git fetch origin master
            git reset --hard FETCH_HEAD
            ok "최신 버전으로 업데이트 완료"
        else
            ok "기존 버전 유지"
        fi
    else
        info "클론 중 → $ANYTHINGLLM_DIR"
        git clone --depth=1 https://github.com/Mintplex-Labs/anything-llm.git "$ANYTHINGLLM_DIR"
        ok "클론 완료"
    fi

    cd "$ANYTHINGLLM_DIR"
}

# ── 3. 의존성 설치 ─────────────────────────────────────────────────────────
install_deps() {
    step "의존성 설치 (yarn setup)"

    cd "$ANYTHINGLLM_DIR"
    info "root / server / frontend / collector 의존성 설치 중... (수 분 소요될 수 있음)"
    yarn setup || error "yarn setup 실패. 위 로그를 확인하세요.
  (better-sqlite3 등 네이티브 모듈 빌드 실패라면 build-essential/python3 설치 여부를 확인하세요)"
    ok "의존성 설치 완료"
}

# ── 4. LLM 백엔드 설정 ─────────────────────────────────────────────────────
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
    [[ -z "$API_KEY" ]] && API_KEY="local"

    # 베어메탈은 컨테이너 네트워크 격리가 없으므로 host.docker.internal 변환이 불필요함
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

    ok "LLM 설정 완료: ${MODEL_NAME} @ ${API_BASE_URL}"
}

# ── 5. File System Agent 설정 ──────────────────────────────────────────────
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
        ok "File System Agent 활성화: ${FS_HOST_PATH}"
        info "설치 후 UI에서 켜야 합니다: Settings → Agent Skills → File System"
    else
        FS_HOST_PATH=""
        info "File System Agent 비활성 (나중에 install 스크립트 재실행으로 추가 가능)"
    fi
}

# ── 6. MCP 서버 설정 ───────────────────────────────────────────────────────
configure_mcp() {
    step "MCP 서버 설정 (네이티브 지원)"

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

    info "MCP 설정 파일 생성 중: $MCP_CONFIG"
    mkdir -p "$MCP_DIR"

    # 베어메탈은 컨테이너 경로 변환이 필요 없으므로 실제 호스트 경로를 그대로 사용
    python3 - <<PYEOF
import json, os

fs_path = "${FS_HOST_PATH}"
tavily_key = "${TAVILY_KEY}"
brave_key = "${BRAVE_KEY}"

config = {"mcpServers": {}}

if fs_path:
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

# ── 7. server/.env 생성 ────────────────────────────────────────────────────
write_env() {
    step "server/.env 생성"

    info "보안 키 자동 생성 중..."
    JWT_SECRET="$(openssl rand -hex 32)"
    SIG_KEY="$(openssl rand -hex 32)"
    SIG_SALT="$(openssl rand -hex 32)"

    mkdir -p "$STORAGE_DIR"

    cat > "$ENV_FILE" <<EOF
# AnythingLLM 설정 (자동 생성 — install_AnythingLLM_baremetal.sh)
# 수정 후 ./run_AnythingLLM_baremetal.sh restart 로 적용

# ── 서버 ────────────────────────────────────────────
SERVER_PORT=${ANYTHINGLLM_PORT}
STORAGE_DIR="${STORAGE_DIR}"

# ── 보안 키 (자동 생성, 멀티유저 모드 사용 시 필요) ──
JWT_SECRET=${JWT_SECRET}
SIG_KEY=${SIG_KEY}
SIG_SALT=${SIG_SALT}

# ── LLM 백엔드 (OpenAI 호환 커스텀 엔드포인트) ──────
LLM_PROVIDER='generic-openai'
GENERIC_OPEN_AI_BASE_PATH='${API_BASE_URL}'
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

# ── 8. 프론트엔드 빌드 및 배포 ─────────────────────────────────────────────
build_frontend() {
    step "프론트엔드 빌드"

    cd "$ANYTHINGLLM_DIR/frontend"
    echo "VITE_API_BASE='/api'" > .env

    info "빌드 중... (수 분 소요될 수 있음)"
    yarn build || error "프론트엔드 빌드 실패"

    rm -rf "$ANYTHINGLLM_DIR/server/public"
    cp -R dist "$ANYTHINGLLM_DIR/server/public"
    ok "프론트엔드 빌드 및 배포 완료"

    cd "$ANYTHINGLLM_DIR"
}

# ── 9. 데이터베이스 마이그레이션 ───────────────────────────────────────────
setup_database() {
    step "데이터베이스 마이그레이션 (Prisma)"

    cd "$ANYTHINGLLM_DIR/server"
    npx prisma generate --schema=./prisma/schema.prisma || error "prisma generate 실패"
    npx prisma migrate deploy --schema=./prisma/schema.prisma || error "prisma migrate 실패"
    ok "데이터베이스 준비 완료"

    cd "$ANYTHINGLLM_DIR"
}

# ── 10. pm2로 시작 ─────────────────────────────────────────────────────────
start_anythingllm() {
    step "AnythingLLM 시작 (pm2)"

    ensure_pm2

    pm2 delete "$PM2_SERVER" &>/dev/null || true
    pm2 delete "$PM2_COLLECTOR" &>/dev/null || true

    info "서버 프로세스 시작 중..."
    (cd "$ANYTHINGLLM_DIR/server" && NODE_ENV=production pm2 start index.js --name "$PM2_SERVER" --time)

    info "collector 프로세스 시작 중..."
    (cd "$ANYTHINGLLM_DIR/collector" && NODE_ENV=production pm2 start index.js --name "$PM2_COLLECTOR" --time)

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
        pm2 logs "$PM2_SERVER" --lines 30 --nostream
        warn "잠시 후: ./run_AnythingLLM_baremetal.sh status"
    fi
}

# ── 11. 자동 시작 설정 ─────────────────────────────────────────────────────
install_autostart() {
    step "자동 시작 설정"

    if [[ "$HAS_SYSTEMD" == true && "$HAS_SUDO" == true ]]; then
        info "pm2 startup 등록 시도 중..."
        local startup_cmd
        startup_cmd="$(pm2 startup systemd -u "$USER" --hp "$HOME" 2>/dev/null | grep -E '^sudo ' | tail -1 || true)"
        if [[ -n "$startup_cmd" ]]; then
            eval "$startup_cmd" &>/dev/null \
                && ok "pm2 startup 등록 완료 (재부팅 시 자동 시작)" \
                || warn "pm2 startup 등록 실패 — 수동 실행: $startup_cmd"
        else
            warn "pm2 startup 명령을 파싱하지 못했습니다 — 수동으로 'pm2 startup' 실행 후 안내를 따르세요"
        fi
    else
        warn "systemd 또는 sudo를 사용할 수 없습니다 (chroot/proot 등 최소 환경) — 자동 시작 등록을 건너뜁니다"
        info "pm2 자체는 계속 백그라운드에서 실행되지만, 환경을 새로 시작(재부팅/새 세션 진입)하면"
        info "직접 복구해야 합니다:  pm2 resurrect   (또는) ./run_AnythingLLM_baremetal.sh start"
    fi

    pm2 save
    ok "pm2 프로세스 목록 저장 완료 (pm2 resurrect로 복구 가능)"
}

# ── 12. 완료 요약 ──────────────────────────────────────────────────────────
print_summary() {
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR_SERVER_IP')"

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   AnythingLLM 설치 완료! (베어메탈)      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
    echo "  ─ 첫 접속 ──────────────────────────────────────────"
    echo "  브라우저에서: http://localhost:${ANYTHINGLLM_PORT}"
    echo "  외부 접속:    http://${LOCAL_IP}:${ANYTHINGLLM_PORT}"
    echo
    echo -e "  ${YELLOW}※ 첫 접속 시 관리자 계정을 생성하게 됩니다.${NC}"
    echo
    if [[ "$HAS_SYSTEMD" == true && "$HAS_SUDO" == true ]]; then
        echo "  자동 시작: pm2 startup 등록 시도됨 (재부팅 시 자동 시작)"
    else
        echo "  자동 시작: systemd 없음 → pm2 자체 관리로 대체"
        echo "            새 세션/재부팅 후에는 'pm2 resurrect' 또는 ./run_AnythingLLM_baremetal.sh start 로 복구"
    fi
    echo
    echo "  ─ 서비스 관리 ──────────────────────────────────────"
    echo "  ./run_AnythingLLM_baremetal.sh start    # 시작"
    echo "  ./run_AnythingLLM_baremetal.sh stop     # 정지"
    echo "  ./run_AnythingLLM_baremetal.sh status   # 상태 확인"
    echo "  ./run_AnythingLLM_baremetal.sh logs     # 실시간 로그"
    echo "  ./run_AnythingLLM_baremetal.sh update   # 최신 버전 업데이트"
    echo "  ./run_AnythingLLM_baremetal.sh config   # LLM/설정 변경"
    echo "  ./run_AnythingLLM_baremetal.sh mcp      # MCP 서버 목록 확인"
    echo
    echo "  ─ 설정 파일 위치 ────────────────────────────────────"
    echo "  소스:        ${ANYTHINGLLM_DIR}"
    echo "  .env:        ${ENV_FILE}"
    echo "  MCP 설정:    ${MCP_CONFIG}"
    echo "  저장소:      ${STORAGE_DIR}"
    [[ -n "$FS_HOST_PATH" ]] && echo "  파일 에이전트 허용 경로: ${FS_HOST_PATH}"
    echo
    echo -e "  ${YELLOW}※ 베어메탈 배포는 AnythingLLM 공식 core team이 지원하지 않는 방식입니다.${NC}"
    echo -e "  ${YELLOW}  Docker를 쓸 수 있는 환경이 생기면 install_AnythingLLM.sh 사용을 권장합니다.${NC}"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}==================================================${NC}"
    echo -e "${BOLD}   AnythingLLM 설치 스크립트 (베어메탈)          ${NC}"
    echo -e "${BOLD}   Docker 미사용 | chroot/proot 호환             ${NC}"
    echo -e "${BOLD}==================================================${NC}"
    echo

    check_prerequisites
    clone_anythingllm
    install_deps
    configure_llm
    configure_filesystem_agent
    configure_mcp
    write_env
    build_frontend
    setup_database
    start_anythingllm
    install_autostart
    print_summary
}

main "$@"
