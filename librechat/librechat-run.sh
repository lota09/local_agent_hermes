#!/usr/bin/env bash
# =============================================================================
# LibreChat 서비스 관리 스크립트
# 사용법: ./librechat-run.sh [start|stop|restart|status|logs|update|config|help]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 설정 로드 ──────────────────────────────────────────────────────────────
LIBRECHAT_DIR="$HOME/librechat"
LIBRECHAT_PORT=3080

[[ -d "$LIBRECHAT_DIR" ]] || error "LibreChat 디렉터리가 없습니다: $LIBRECHAT_DIR
  librechat-install.sh를 먼저 실행하세요."

# docker-compose.override.yml에서 포트 읽기
if [[ -f "$LIBRECHAT_DIR/docker-compose.override.yml" ]]; then
    _port=$(grep -oP '"\K\d+(?=:3080")' "$LIBRECHAT_DIR/docker-compose.override.yml" 2>/dev/null | head -1 || true)
    [[ -n "$_port" ]] && LIBRECHAT_PORT="$_port"
fi

# LLM URL 읽기 (상태 표시용)
LLM_URL=""
if [[ -f "$LIBRECHAT_DIR/librechat.yaml" ]]; then
    LLM_URL=$(grep -oP '(?<=baseURL: ").*(?=")' "$LIBRECHAT_DIR/librechat.yaml" 2>/dev/null | head -1 || true)
fi

# LLM 서버 상태 확인 (host.docker.internal → localhost 변환)
check_llm_server() {
    local test_url="${LLM_URL//host.docker.internal/localhost}"
    [[ -z "$test_url" ]] && return 1
    curl -sf "${test_url}/models" &>/dev/null
}

# ── 명령어 함수들 ──────────────────────────────────────────────────────────

cmd_start() {
    info "LibreChat 시작 중..."
    cd "$LIBRECHAT_DIR"

    if ! check_llm_server; then
        warn "LLM 서버에 연결할 수 없습니다: ${LLM_URL//host.docker.internal/localhost}"
        warn "LLM 서버를 먼저 시작하세요."
        read -rp "그래도 계속하시겠습니까? [y/N]: " CONT
        [[ "${CONT,,}" == "y" ]] || { info "취소됨"; exit 0; }
    fi

    docker compose up -d
    sleep 3
    cmd_status
}

cmd_stop() {
    info "LibreChat 정지 중..."
    cd "$LIBRECHAT_DIR"
    docker compose down
    ok "정지 완료"
}

cmd_restart() {
    info "LibreChat 재시작 중..."
    cd "$LIBRECHAT_DIR"
    docker compose down
    sleep 2
    docker compose up -d
    sleep 3
    cmd_status
}

cmd_status() {
    cd "$LIBRECHAT_DIR"
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"

    echo -e "${BOLD}── LibreChat 서비스 상태 ────────────────────${NC}"
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
        docker compose ps

    echo
    echo -e "${BOLD}── LLM 서버 상태 ────────────────────────────${NC}"
    local llm_display="${LLM_URL//host.docker.internal/localhost}"
    if [[ -z "$llm_display" ]]; then
        warn "librechat.yaml에서 LLM URL을 읽을 수 없습니다"
    elif check_llm_server; then
        ok "LLM 서버 응답 확인 (${llm_display})"
        curl -sf "${llm_display}/models" \
            | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for m in d.get('data',[])[:5]: print(f'  - {m.get(\"id\",\"?\")}')
except: pass
" 2>/dev/null || true
    else
        warn "LLM 서버 응답 없음 (${llm_display})"
    fi

    echo
    echo -e "${BOLD}── 접속 정보 ────────────────────────────────${NC}"
    if curl -sf "http://localhost:${LIBRECHAT_PORT}" &>/dev/null; then
        ok "LibreChat 응답 중"
        info "로컬:  http://localhost:${LIBRECHAT_PORT}"
        info "외부:  http://${LOCAL_IP}:${LIBRECHAT_PORT}"
    else
        warn "LibreChat 응답 없음 (포트 ${LIBRECHAT_PORT})"
        info "로그 확인: ./librechat-run.sh logs"
    fi
}

cmd_logs() {
    cd "$LIBRECHAT_DIR"
    echo
    echo "  서비스 선택 (Enter = 전체):"
    echo "  1) 전체"
    echo "  2) api    (LibreChat 서버)"
    echo "  3) mongodb"
    echo "  4) meilisearch"
    echo "  5) rag_api"
    echo
    read -rp "선택 [1-5] (기본값 1): " SVC_CHOICE
    SVC_CHOICE="${SVC_CHOICE:-1}"

    case "$SVC_CHOICE" in
        2) SVC="api"         ;;
        3) SVC="mongodb"     ;;
        4) SVC="meilisearch" ;;
        5) SVC="rag_api"     ;;
        *) SVC=""            ;;
    esac

    info "실시간 로그 출력 중 (Ctrl+C로 중단)..."
    # shellcheck disable=SC2086
    docker compose logs -f --tail=50 $SVC
}

cmd_update() {
    info "LibreChat 업데이트 중..."
    cd "$LIBRECHAT_DIR"

    # 서비스 정지
    docker compose down

    # 소스 최신화
    info "소스 업데이트 중..."
    git fetch origin main
    git reset --hard FETCH_HEAD

    # 기존 이미지 제거 후 최신 pull
    info "Docker 이미지 업데이트 중..."
    docker images -a | grep "librechat" | awk '{print $3}' | xargs docker rmi 2>/dev/null || true
    docker compose pull

    # 재시작
    docker compose up -d
    sleep 3
    ok "업데이트 완료"
    cmd_status
}

cmd_config() {
    echo
    echo "  설정 파일 선택:"
    echo "  1) librechat.yaml  — LLM 엔드포인트, 모델 설정"
    echo "  2) .env            — 환경 변수, 보안 키, 기능 플래그"
    echo
    read -rp "선택 [1/2] (기본값 1): " CFG_CHOICE
    CFG_CHOICE="${CFG_CHOICE:-1}"

    case "$CFG_CHOICE" in
        2) CFG_FILE="$LIBRECHAT_DIR/.env" ;;
        *) CFG_FILE="$LIBRECHAT_DIR/librechat.yaml" ;;
    esac

    "${EDITOR:-nano}" "$CFG_FILE"

    echo
    read -rp "변경사항을 적용하기 위해 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_restart
}

cmd_help() {
    echo
    echo -e "${BOLD}LibreChat 관리 스크립트${NC}"
    echo
    echo "사용법: $0 <명령어>"
    echo
    echo -e "${BOLD}서비스 관리:${NC}"
    echo "  start    LibreChat 시작"
    echo "  stop     LibreChat 정지"
    echo "  restart  재시작"
    echo "  status   서비스 상태 + LLM 서버 상태 확인"
    echo "  logs     실시간 로그 (서비스 선택 가능)"
    echo
    echo -e "${BOLD}관리:${NC}"
    echo "  update   최신 버전으로 업데이트"
    echo "  config   설정 파일 편집 (librechat.yaml / .env)"
    echo
    echo -e "${BOLD}예시:${NC}"
    echo "  $0 start"
    echo "  $0 logs        # 서비스 선택 후 실시간 로그"
    echo "  $0 config      # LLM 엔드포인트 변경"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
case "${1:-help}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    logs)    cmd_logs    ;;
    update)  cmd_update  ;;
    config)  cmd_config  ;;
    help|-h|--help) cmd_help ;;
    *)
        error "알 수 없는 명령어: $1 (./librechat-run.sh help 참고)"
        ;;
esac
