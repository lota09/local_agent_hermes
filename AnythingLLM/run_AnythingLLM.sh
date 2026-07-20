#!/usr/bin/env bash
# =============================================================================
# AnythingLLM 서비스 관리 스크립트
# 사용법: ./run_AnythingLLM.sh [start|stop|restart|status|logs|update|config|mcp|fs|help]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 설정 로드 ──────────────────────────────────────────────────────────────
ANYTHINGLLM_HOME="$HOME/.anythingllm"
STORAGE_LOCATION="$ANYTHINGLLM_HOME/storage"
ENV_FILE="$STORAGE_LOCATION/.env"
MCP_CONFIG="$STORAGE_LOCATION/plugins/anythingllm_mcp_servers.json"
CONTAINER_NAME="anythingllm"
IMAGE="mintplexlabs/anythingllm:latest"

[[ -f "$ENV_FILE" ]] || error "설정 파일 없음: $ENV_FILE\n  install_AnythingLLM.sh를 먼저 실행하세요."

# 기본값 (소싱 전 대비)
ANYTHINGLLM_PORT=3001
GENERIC_OPEN_AI_BASE_PATH="http://host.docker.internal:11436/v1"
GENERIC_OPEN_AI_API_KEY=""
GENERIC_OPEN_AI_MODEL_PREF="default"
FS_HOST_PATH=""

# shellcheck disable=SC1090
source "$ENV_FILE"

# LLM 서버 응답 확인 헬퍼
# .env의 GENERIC_OPEN_AI_BASE_PATH는 Docker용(host.docker.internal) → 호스트에서 테스트 시 localhost로 변환
check_llm_server() {
    local test_url="${GENERIC_OPEN_AI_BASE_PATH//host.docker.internal/localhost}"
    curl -sf \
        ${GENERIC_OPEN_AI_API_KEY:+-H "Authorization: Bearer ${GENERIC_OPEN_AI_API_KEY}"} \
        "${test_url}/models" \
        &>/dev/null
}

build_fs_args() {
    FS_ARGS=""
    [[ -n "$FS_HOST_PATH" ]] && FS_ARGS="-v ${FS_HOST_PATH}:/app/server/storage/anythingllm-fs"
}

# ── 명령어 함수들 ──────────────────────────────────────────────────────────

cmd_start() {
    info "AnythingLLM 시작 중..."

    if ! check_llm_server; then
        warn "LLM 서버에 연결할 수 없습니다: ${GENERIC_OPEN_AI_BASE_PATH//host.docker.internal/localhost}"
        warn "LLM 서버를 먼저 시작하세요."
        read -rp "그래도 계속하시겠습니까? [y/N]: " CONT
        [[ "${CONT,,}" == "y" ]] || { info "취소됨"; exit 0; }
    fi

    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm   "$CONTAINER_NAME" 2>/dev/null || true

    build_fs_args

    # shellcheck disable=SC2086
    docker run -d \
        --name "$CONTAINER_NAME" \
        --cap-add SYS_ADMIN \
        -p "${ANYTHINGLLM_PORT}:3001" \
        --add-host=host.docker.internal:host-gateway \
        -v "${STORAGE_LOCATION}:/app/server/storage" \
        -v "${ENV_FILE}:/app/server/.env" \
        $FS_ARGS \
        --restart unless-stopped \
        "$IMAGE" \
        > /dev/null

    sleep 3
    if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" -q | grep -q .; then
        ok "AnythingLLM 시작됨 (포트 ${ANYTHINGLLM_PORT})"
    else
        warn "컨테이너 시작 실패 — 로그 확인:"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -20
    fi

    cmd_status
    echo
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"
    ok "브라우저에서 접속: http://${LOCAL_IP}:${ANYTHINGLLM_PORT}"
}

cmd_stop() {
    info "AnythingLLM 정지 중..."
    docker stop "$CONTAINER_NAME" 2>/dev/null && ok "정지 완료" || warn "실행 중인 컨테이너 없음"
}

cmd_restart() {
    info "AnythingLLM 재시작 중..."
    cmd_stop
    sleep 2
    cmd_start
}

cmd_status() {
    echo -e "${BOLD}── AnythingLLM 상태 ─────────────────────────${NC}"

    if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" -q | grep -q .; then
        ok "실행 중 (Docker)"
        docker ps --filter "name=${CONTAINER_NAME}" --format "  컨테이너: {{.Names}}  상태: {{.Status}}"
    else
        warn "정지됨 (Docker)"
    fi

    echo
    local llm_display="${GENERIC_OPEN_AI_BASE_PATH//host.docker.internal/localhost}"
    echo -e "${BOLD}── LLM 서버 상태 (${llm_display}) ──────${NC}"
    if check_llm_server; then
        ok "LLM 서버 응답 확인"
        info "모델: ${GENERIC_OPEN_AI_MODEL_PREF}"
        curl -sf \
            ${GENERIC_OPEN_AI_API_KEY:+-H "Authorization: Bearer ${GENERIC_OPEN_AI_API_KEY}"} \
            "${llm_display}/models" \
            | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d.get('data', [])[:5]:
        print(f'  - {m.get(\"id\",\"?\")}')
except: pass
" 2>/dev/null || true
    else
        warn "LLM 서버 응답 없음"
    fi

    echo
    echo -e "${BOLD}── 접속 정보 ────────────────────────────────${NC}"
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"
    if curl -sf "http://localhost:${ANYTHINGLLM_PORT}" &>/dev/null; then
        ok "AnythingLLM 응답 중"
        info "로컬:  http://localhost:${ANYTHINGLLM_PORT}"
        info "외부:  http://${LOCAL_IP}:${ANYTHINGLLM_PORT}"
    else
        warn "AnythingLLM 응답 없음 (포트 ${ANYTHINGLLM_PORT})"
        info "로그 확인: ./run_AnythingLLM.sh logs"
    fi
}

cmd_logs() {
    info "실시간 로그 출력 중 (Ctrl+C로 중단)..."
    docker logs -f --tail=50 "$CONTAINER_NAME"
}

cmd_update() {
    info "AnythingLLM 업데이트 중..."
    docker pull "$IMAGE"
    ok "이미지 업데이트 완료"

    echo
    read -rp "서비스를 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_restart
}

cmd_config() {
    info "설정 파일 편집 중..."
    "${EDITOR:-nano}" "$ENV_FILE"
    echo
    read -rp "변경사항을 적용하기 위해 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_restart
}

cmd_mcp() {
    info "MCP 설정 파일: $MCP_CONFIG"
    echo
    if [[ -f "$MCP_CONFIG" ]]; then
        python3 -c "
import json
with open('$MCP_CONFIG') as f:
    cfg = json.load(f)
servers = cfg.get('mcpServers', {})
print(f'  등록된 MCP 서버: {len(servers)}개')
for name, s in servers.items():
    desc = s.get('description', '')
    print(f'  • {name}: {desc}')
"
    else
        warn "MCP 설정 파일 없음"
        info "install_AnythingLLM.sh를 재실행해 MCP를 설정하세요."
    fi
    echo
    info "AnythingLLM 웹 UI에서 MCP 확인/활성화:"
    info "  Settings → Agent Skills → MCP Servers"
}

cmd_fs() {
    echo -e "${BOLD}── File System Agent 상태 ───────────────────${NC}"
    if [[ -n "$FS_HOST_PATH" ]]; then
        ok "활성화됨"
        info "허용 경로: ${FS_HOST_PATH}"
        info "컨테이너 경로: /app/server/storage/anythingllm-fs"
        info "UI에서 켜져 있는지 확인: Settings → Agent Skills → File System"
    else
        warn "비활성화 상태"
        info "install_AnythingLLM.sh를 재실행해 활성화할 수 있습니다."
    fi
}

cmd_help() {
    echo
    echo -e "${BOLD}AnythingLLM 관리 스크립트${NC}"
    echo
    echo "사용법: $0 <명령어>"
    echo
    echo -e "${BOLD}서비스 관리:${NC}"
    echo "  start      AnythingLLM 시작"
    echo "  stop       AnythingLLM 정지"
    echo "  restart    재시작"
    echo "  status     서비스 상태 + LLM 서버 상태 확인"
    echo "  logs       실시간 로그 (Ctrl+C로 중단)"
    echo
    echo -e "${BOLD}관리:${NC}"
    echo "  update     최신 버전으로 업데이트"
    echo "  config     설정 파일 편집 (.env)"
    echo "  mcp        MCP 서버 목록 확인"
    echo "  fs         File System Agent 상태 확인"
    echo
    echo -e "${BOLD}예시:${NC}"
    echo "  $0 start"
    echo "  $0 logs"
    echo "  $0 config   # LLM 엔드포인트, 모델 변경"
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
    mcp)     cmd_mcp     ;;
    fs)      cmd_fs      ;;
    help|-h|--help) cmd_help ;;
    *)
        error "알 수 없는 명령어: $1 (./run_AnythingLLM.sh help 참고)"
        ;;
esac
