#!/usr/bin/env bash
# =============================================================================
# AnythingLLM 서비스 관리 스크립트 (베어메탈 / pm2 기반)
# 사용법: ./run_AnythingLLM_baremetal.sh [start|stop|restart|status|logs|update|config|mcp|fs|help]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 설정 로드 ──────────────────────────────────────────────────────────────
ANYTHINGLLM_DIR="$HOME/anythingllm"
STORAGE_DIR="$ANYTHINGLLM_DIR/server/storage"
ENV_FILE="$ANYTHINGLLM_DIR/server/.env"
MCP_CONFIG="$STORAGE_DIR/plugins/anythingllm_mcp_servers.json"
PM2_SERVER="anythingllm-server"
PM2_COLLECTOR="anythingllm-collector"

[[ -d "$ANYTHINGLLM_DIR" ]] || error "AnythingLLM 디렉터리가 없습니다: $ANYTHINGLLM_DIR
  install_AnythingLLM_baremetal.sh를 먼저 실행하세요."
[[ -f "$ENV_FILE" ]] || error "설정 파일 없음: $ENV_FILE
  install_AnythingLLM_baremetal.sh를 먼저 실행하세요."

command -v pm2 &>/dev/null || error "pm2가 없습니다. install_AnythingLLM_baremetal.sh를 먼저 실행하세요."

# 기본값 (소싱 전 대비)
ANYTHINGLLM_PORT=3001
GENERIC_OPEN_AI_BASE_PATH="http://localhost:11436/v1"
GENERIC_OPEN_AI_API_KEY=""
GENERIC_OPEN_AI_MODEL_PREF="default"
FS_HOST_PATH=""

# shellcheck disable=SC1090
source "$ENV_FILE"

check_llm_server() {
    curl -sf \
        ${GENERIC_OPEN_AI_API_KEY:+-H "Authorization: Bearer ${GENERIC_OPEN_AI_API_KEY}"} \
        "${GENERIC_OPEN_AI_BASE_PATH}/models" \
        &>/dev/null
}

# ── 명령어 함수들 ──────────────────────────────────────────────────────────

cmd_start() {
    info "AnythingLLM 시작 중..."

    if ! check_llm_server; then
        warn "LLM 서버에 연결할 수 없습니다: ${GENERIC_OPEN_AI_BASE_PATH}"
        warn "LLM 서버를 먼저 시작하세요."
        read -rp "그래도 계속하시겠습니까? [y/N]: " CONT
        [[ "${CONT,,}" == "y" ]] || { info "취소됨"; exit 0; }
    fi

    pm2 delete "$PM2_SERVER" &>/dev/null || true
    pm2 delete "$PM2_COLLECTOR" &>/dev/null || true

    (cd "$ANYTHINGLLM_DIR/server" && NODE_ENV=production pm2 start index.js --name "$PM2_SERVER" --time)
    (cd "$ANYTHINGLLM_DIR/collector" && NODE_ENV=production pm2 start index.js --name "$PM2_COLLECTOR" --time)
    pm2 save &>/dev/null || true

    sleep 3
    if pm2 describe "$PM2_SERVER" 2>/dev/null | grep -q "online"; then
        ok "AnythingLLM 시작됨 (포트 ${ANYTHINGLLM_PORT})"
    else
        warn "시작 실패 — 로그 확인:"
        pm2 logs "$PM2_SERVER" --lines 20 --nostream
    fi

    cmd_status
    echo
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"
    ok "브라우저에서 접속: http://${LOCAL_IP}:${ANYTHINGLLM_PORT}"
}

cmd_stop() {
    info "AnythingLLM 정지 중..."
    pm2 stop "$PM2_SERVER" &>/dev/null && ok "서버 정지됨" || warn "서버 프로세스 없음"
    pm2 stop "$PM2_COLLECTOR" &>/dev/null && ok "collector 정지됨" || warn "collector 프로세스 없음"
}

cmd_restart() {
    info "AnythingLLM 재시작 중..."
    pm2 restart "$PM2_SERVER" &>/dev/null || { warn "서버 재시작 실패 — start로 재시도"; cmd_start; return; }
    pm2 restart "$PM2_COLLECTOR" &>/dev/null || true
    sleep 3
    cmd_status
}

cmd_status() {
    echo -e "${BOLD}── AnythingLLM 상태 (pm2) ───────────────────${NC}"
    pm2 list | grep -E "anythingllm|App name" || warn "등록된 pm2 프로세스 없음"

    echo
    echo -e "${BOLD}── LLM 서버 상태 (${GENERIC_OPEN_AI_BASE_PATH}) ──${NC}"
    if check_llm_server; then
        ok "LLM 서버 응답 확인"
        info "모델: ${GENERIC_OPEN_AI_MODEL_PREF}"
        curl -sf \
            ${GENERIC_OPEN_AI_API_KEY:+-H "Authorization: Bearer ${GENERIC_OPEN_AI_API_KEY}"} \
            "${GENERIC_OPEN_AI_BASE_PATH}/models" \
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
        info "로그 확인: ./run_AnythingLLM_baremetal.sh logs"
    fi
}

cmd_logs() {
    info "실시간 로그 출력 중 (Ctrl+C로 중단)..."
    echo
    echo "  1) server    2) collector    3) 전체 (기본값)"
    read -rp "선택 [1-3] (기본값 3): " LOG_CHOICE
    case "${LOG_CHOICE:-3}" in
        1) pm2 logs "$PM2_SERVER" ;;
        2) pm2 logs "$PM2_COLLECTOR" ;;
        *) pm2 logs ;;
    esac
}

cmd_update() {
    info "AnythingLLM 업데이트 중..."
    cd "$ANYTHINGLLM_DIR"

    cmd_stop

    info "소스 업데이트 중..."
    git fetch origin master
    git reset --hard FETCH_HEAD

    info "의존성 재설치 중..."
    yarn setup

    info "프론트엔드 재빌드 중..."
    (cd frontend && yarn build)
    rm -rf server/public
    cp -R frontend/dist server/public

    info "데이터베이스 마이그레이션 적용 중..."
    (cd server && npx prisma generate --schema=./prisma/schema.prisma)
    (cd server && npx prisma migrate deploy --schema=./prisma/schema.prisma)

    ok "업데이트 완료"
    echo
    read -rp "서비스를 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_start
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
        info "install_AnythingLLM_baremetal.sh를 재실행해 MCP를 설정하세요."
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
        info "UI에서 켜져 있는지 확인: Settings → Agent Skills → File System"
    else
        warn "비활성화 상태"
        info "install_AnythingLLM_baremetal.sh를 재실행해 활성화할 수 있습니다."
    fi
}

cmd_help() {
    echo
    echo -e "${BOLD}AnythingLLM 관리 스크립트 (베어메탈)${NC}"
    echo
    echo "사용법: $0 <명령어>"
    echo
    echo -e "${BOLD}서비스 관리:${NC}"
    echo "  start      AnythingLLM 시작 (server + collector)"
    echo "  stop       AnythingLLM 정지"
    echo "  restart    재시작"
    echo "  status     서비스 상태 + LLM 서버 상태 확인"
    echo "  logs       실시간 로그 (server/collector 선택 가능)"
    echo
    echo -e "${BOLD}관리:${NC}"
    echo "  update     소스 최신화 + 재빌드 + 마이그레이션"
    echo "  config     설정 파일 편집 (server/.env)"
    echo "  mcp        MCP 서버 목록 확인"
    echo "  fs         File System Agent 상태 확인"
    echo
    echo -e "${BOLD}참고:${NC}"
    echo "  systemd가 없는 환경(chroot/proot)에서는 재부팅/새 세션 진입 시"
    echo "  pm2가 자동으로 살아나지 않을 수 있습니다 — 그럴 땐 'pm2 resurrect' 또는"
    echo "  이 스크립트의 start 명령을 다시 실행하세요."
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
        error "알 수 없는 명령어: $1 (./run_AnythingLLM_baremetal.sh help 참고)"
        ;;
esac
