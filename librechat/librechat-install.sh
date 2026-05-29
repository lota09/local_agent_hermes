#!/usr/bin/env bash
# =============================================================================
# LibreChat 설치 스크립트 (Docker Compose 기반)
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

LIBRECHAT_DIR="$HOME/librechat"
LIBRECHAT_PORT=3080

# ── 1. 사전 조건 확인 및 자동 설치 ────────────────────────────────────────
check_prerequisites() {
    step "사전 조건 확인"

    # ── git ───────────────────────────────────────────────────────────────
    if ! command -v git &>/dev/null; then
        info "git 없음 — sudo로 설치합니다..."
        sudo -n true 2>/dev/null || error "git이 없고 sudo 권한도 없습니다.
  관리자에게 요청: sudo apt install -y git"
        sudo apt-get install -y -qq git
    fi
    ok "git $(git --version | awk '{print $3}')"

    # ── openssl (보안 키 생성용) ──────────────────────────────────────────
    if ! command -v openssl &>/dev/null; then
        info "openssl 없음 — sudo로 설치합니다..."
        sudo -n true 2>/dev/null || error "openssl이 없고 sudo 권한도 없습니다.
  관리자에게 요청: sudo apt install -y openssl"
        sudo apt-get install -y -qq openssl
    fi
    ok "openssl $(openssl version | awk '{print $2}')"

    # ── Docker ────────────────────────────────────────────────────────────
    if ! command -v docker &>/dev/null; then
        info "Docker 없음 — 공식 설치 스크립트 실행 중..."
        sudo -n true 2>/dev/null || error "Docker가 없고 sudo 권한도 없습니다.
  관리자에게 요청:
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker ${USER}"

        # 만료된 서드파티 저장소가 apt를 막는 경우 대비
        sudo apt-get update -qq 2>/dev/null || {
            warn "apt update 실패 — 문제 있는 저장소 비활성화 시도"
            sudo find /etc/apt/sources.list.d/ -name "*.list" \
                -exec bash -c \
                'out=$(apt-get update 2>&1); echo "$out" | grep -q "$(basename "$1" .list)" && mv "$1" "$1.disabled"' \
                _ {} \; 2>/dev/null || true
        }
        curl -fsSL https://get.docker.com | sudo sh \
            || error "Docker 설치 실패. 위 오류를 확인하세요."
        sudo systemctl enable --now docker
    fi

    # docker 권한 확인 — 없으면 그룹 추가 후 newgrp으로 즉시 적용
    if ! docker info &>/dev/null 2>&1; then
        warn "현재 사용자(${USER})가 docker 그룹에 없습니다."
        sudo -n true 2>/dev/null || error "docker 그룹 권한이 없고 sudo도 불가합니다.
  관리자에게 요청: sudo usermod -aG docker ${USER}
  이후 재로그인 후 install.sh를 다시 실행하세요."
        sudo usermod -aG docker "$USER"
        ok "docker 그룹 추가 완료 — 세션에 즉시 적용합니다"
        exec newgrp docker
    fi
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

    # ── Docker Compose ────────────────────────────────────────────────────
    if ! docker compose version &>/dev/null 2>&1; then
        info "Docker Compose 플러그인 없음 — 설치 중..."
        sudo -n true 2>/dev/null || error "Docker Compose가 없고 sudo 권한도 없습니다.
  관리자에게 요청: sudo apt install -y docker-compose-plugin"
        sudo apt-get install -y -qq docker-compose-plugin \
            || error "Docker Compose 설치 실패."
    fi
    ok "Docker Compose $(docker compose version --short)"

    ok "사전 조건 확인 완료"
}

# ── 2. LibreChat 소스 클론 ─────────────────────────────────────────────────
clone_librechat() {
    step "LibreChat 소스 클론"

    if [[ -d "$LIBRECHAT_DIR/.git" ]]; then
        warn "이미 설치된 LibreChat 발견 ($LIBRECHAT_DIR)"
        read -rp "최신 버전으로 업데이트하시겠습니까? [y/N]: " UPDATE
        if [[ "${UPDATE,,}" == "y" ]]; then
            info "업데이트 중..."
            cd "$LIBRECHAT_DIR"
            git fetch origin main
            git reset --hard FETCH_HEAD
            ok "최신 버전으로 업데이트 완료"
        else
            ok "기존 버전 유지"
        fi
    else
        info "LibreChat 클론 중 → $LIBRECHAT_DIR"
        git clone --depth=1 https://github.com/danny-avila/LibreChat.git "$LIBRECHAT_DIR"
        ok "클론 완료"
    fi

    cd "$LIBRECHAT_DIR"
}

# ── 3. .env 파일 생성 및 보안 키 자동 생성 ────────────────────────────────
setup_env() {
    step ".env 설정"

    cd "$LIBRECHAT_DIR"

    if [[ ! -f .env ]]; then
        cp .env.example .env
        info ".env.example → .env 복사 완료"
    else
        warn ".env 이미 존재 — 보안 키만 미설정 항목에 한해 생성합니다"
    fi

    # 보안 키 자동 생성 (이미 기본값이 아닌 값이 있으면 건너뜀)
    _replace_if_default() {
        local key="$1"
        local new_val="$2"
        local default_pattern="$3"
        if grep -q "^${key}=${default_pattern}" .env 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${new_val}|" .env
            ok "${key} 자동 생성"
        else
            ok "${key} 이미 설정됨 — 유지"
        fi
    }

    info "보안 키 자동 생성 중..."
    _replace_if_default "CREDS_IV"           "$(openssl rand -hex 16)" "e2341419ec3dd3d19b13a1a87fafcbfb"
    _replace_if_default "CREDS_KEY"          "$(openssl rand -hex 32)" "f34be427ebb29de8d88c107a71546019685ed8b241d8f2ed00c3df97ad2566f0"
    _replace_if_default "JWT_SECRET"         "$(openssl rand -hex 32)" "16f8c0ef4a5d391b26034086c628469d3f9f497f08163ab9b40137092f2909ef"
    _replace_if_default "JWT_REFRESH_SECRET" "$(openssl rand -hex 32)" "eaa5191f2914e30b9387fd84e254e4ba6fc51b4654968a9b0803b456a54b8418"

    ok ".env 설정 완료"
}

# ── 4. LLM 백엔드 설정 → librechat.yaml 생성 ──────────────────────────────
configure_llm() {
    step "LLM 백엔드 설정"

    cd "$LIBRECHAT_DIR"

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
        1) DEFAULT_URL="http://localhost:8080/v1"  ;;
        2) DEFAULT_URL="http://localhost:11436/v1" ;;
        3) DEFAULT_URL="http://localhost:11434/v1" ;;
        4) DEFAULT_URL="http://localhost:1234/v1"  ;;
        5) DEFAULT_URL="http://localhost:8000/v1"  ;;
        6) DEFAULT_URL="http://localhost:1337/v1"  ;;
        *) DEFAULT_URL="" ;;
    esac

    echo
    read -rp "API Base URL [기본: ${DEFAULT_URL:-직접입력}]: " API_BASE_URL
    API_BASE_URL="${API_BASE_URL:-$DEFAULT_URL}"
    [[ -n "$API_BASE_URL" ]] || error "API Base URL을 입력해야 합니다."

    # 연결 테스트 및 모델 목록 자동 조회
    echo
    info "LLM 서버 연결 테스트 중: ${API_BASE_URL}/models"
    MODEL_NAME="default"
    if curl -sf "${API_BASE_URL}/models" &>/dev/null; then
        ok "LLM 서버 응답 확인"
        # 첫 번째 모델명 자동 추출
        FIRST_MODEL=$(curl -sf "${API_BASE_URL}/models" \
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
        warn "LLM 서버에 연결할 수 없습니다. 나중에 시작 후 재설정 가능합니다."
    fi

    echo
    read -rp "사용할 모델명 [기본: ${MODEL_NAME}]: " INPUT_MODEL
    MODEL_NAME="${INPUT_MODEL:-$MODEL_NAME}"

    # Docker 내부에서 호스트 접근: localhost → host.docker.internal
    DOCKER_LLM_URL="${API_BASE_URL//localhost/host.docker.internal}"

    # librechat.yaml 생성
    info "librechat.yaml 생성 중..."
    cat > "$LIBRECHAT_DIR/librechat.yaml" <<EOF
# LibreChat 설정 (자동 생성 — librechat-install.sh)
# 수정 후 ./librechat-run.sh restart 로 적용
# 전체 설정: https://www.librechat.ai/docs/configuration/librechat_yaml

version: 1.3.5
cache: true

endpoints:
  custom:
    - name: "Local LLM"
      apiKey: "local"
      baseURL: "${DOCKER_LLM_URL}"
      models:
        default: ["${MODEL_NAME}"]
        fetch: true
      titleConvo: true
      titleModel: "current_model"
      modelDisplayLabel: "Local LLM"
EOF

    ok "librechat.yaml 생성 완료"
    info "  엔드포인트: Local LLM → ${API_BASE_URL}"
    info "  Docker URL: ${DOCKER_LLM_URL}"
}

# ── 5. docker-compose.override.yml 생성 ───────────────────────────────────
setup_compose_override() {
    step "Docker Compose 설정"

    cd "$LIBRECHAT_DIR"

    cat > docker-compose.override.yml <<EOF
# docker-compose.override.yml (자동 생성 — librechat-install.sh)
# librechat.yaml 마운트 및 호스트 LLM 접근 설정

services:
  api:
    ports:
      - "${LIBRECHAT_PORT}:3080"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - type: bind
        source: ./librechat.yaml
        target: /app/librechat.yaml
EOF

    ok "docker-compose.override.yml 생성 완료 (포트: ${LIBRECHAT_PORT})"
}

# ── 6. Docker 이미지 pull 및 서비스 시작 ──────────────────────────────────
start_librechat() {
    step "LibreChat 시작"

    cd "$LIBRECHAT_DIR"

    info "Docker 이미지 다운로드 중... (처음 실행 시 수 분 소요)"
    docker compose pull

    info "서비스 시작 중..."
    docker compose up -d

    # 최대 60초 대기하며 응답 확인
    info "서비스 기동 대기 중..."
    for i in $(seq 1 12); do
        sleep 5
        if curl -sf "http://localhost:${LIBRECHAT_PORT}" &>/dev/null; then
            ok "LibreChat 응답 확인 (${i}번째 시도, $((i*5))초)"
            break
        fi
        info "  대기 중... ($((i*5))초)"
    done

    if ! curl -sf "http://localhost:${LIBRECHAT_PORT}" &>/dev/null; then
        warn "60초 내 응답 없음 — 로그 확인:"
        docker compose logs --tail=20 api
        warn "서비스가 아직 초기화 중일 수 있습니다."
        warn "잠시 후 확인: ./librechat-run.sh status"
    fi
}

# ── 7. systemd 사용자 서비스 등록 ─────────────────────────────────────────
install_service() {
    step "systemd 사용자 서비스 등록"

    mkdir -p "$HOME/.config/systemd/user"
    SERVICE_FILE="$HOME/.config/systemd/user/librechat.service"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=LibreChat (Docker Compose)
After=docker.service network.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${LIBRECHAT_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable librechat
    ok "librechat systemd 서비스 등록 완료 (부팅 시 자동 시작)"

    # loginctl linger: 로그아웃 후에도 서비스 유지
    if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
        ok "loginctl linger 활성화 → 로그아웃 후에도 서비스 유지"
    else
        warn "linger 미활성화 (sudo 필요)"
        warn "관리자에게 요청: sudo loginctl enable-linger ${USER}"
        warn "미설정 시 SSH 세션 종료 시 서비스도 종료될 수 있음"
    fi
}

# ── 8. 완료 요약 ───────────────────────────────────────────────────────────
print_summary() {
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR_SERVER_IP')"

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        LibreChat 설치 완료!              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
    echo "  ─ 첫 접속 ──────────────────────────────────────────"
    echo "  브라우저에서: http://localhost:${LIBRECHAT_PORT}"
    echo "  외부 접속:    http://${LOCAL_IP}:${LIBRECHAT_PORT}"
    echo
    echo -e "  ${YELLOW}※ 첫 번째로 가입하는 계정이 관리자가 됩니다.${NC}"
    echo -e "  ${YELLOW}  가입 후 다른 사람의 가입을 막으려면:${NC}"
    echo -e "  ${YELLOW}  ./librechat-run.sh config 에서 ALLOW_REGISTRATION=false 설정${NC}"
    echo
    echo "  ─ 서비스 관리 ──────────────────────────────────────"
    echo "  ./librechat-run.sh start    # 시작"
    echo "  ./librechat-run.sh stop     # 정지"
    echo "  ./librechat-run.sh status   # 상태 확인"
    echo "  ./librechat-run.sh logs     # 실시간 로그"
    echo "  ./librechat-run.sh update   # 최신 버전 업데이트"
    echo "  ./librechat-run.sh config   # LLM/설정 변경"
    echo
    echo "  ─ 설정 파일 위치 ────────────────────────────────────"
    echo "  LLM 엔드포인트: ${LIBRECHAT_DIR}/librechat.yaml"
    echo "  환경 변수:      ${LIBRECHAT_DIR}/.env"
    echo "  Compose 설정:   ${LIBRECHAT_DIR}/docker-compose.override.yml"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   LibreChat 설치 스크립트                 ${NC}"
    echo -e "${BOLD}   Ubuntu | Docker Compose | OpenAI 호환   ${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo

    check_prerequisites
    clone_librechat
    setup_env
    configure_llm
    setup_compose_override
    start_librechat
    install_service
    print_summary
}

main "$@"
