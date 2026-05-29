#!/usr/bin/env bash
# =============================================================================
# LobeChat 서비스 관리 스크립트
# 사용법: ./lobechat-run.sh [start|stop|restart|status|logs|update|config|help]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 설정 로드 ──────────────────────────────────────────────────────────────
LOBECHAT_HOME="$HOME/.lobechat"
LOBECHAT_ENV="$LOBECHAT_HOME/.env"
LOBECHAT_DIR="$HOME/lobechat"
PID_FILE="$LOBECHAT_HOME/lobechat.pid"
LOG_FILE="$LOBECHAT_HOME/logs/lobechat.log"

# 기본값
LOBECHAT_RUNTIME="docker"
LOBECHAT_PORT=3210
OPENAI_PROXY_URL="http://localhost:11436/v1"
OPENAI_API_KEY=""
DEFAULT_MODEL="default"

[[ -f "$LOBECHAT_ENV" ]] || error "설정 파일 없음: $LOBECHAT_ENV\n  lobechat-install.sh를 먼저 실행하세요."
# shellcheck disable=SC1090
source "$LOBECHAT_ENV"

# LLM 서버 응답 확인 헬퍼
check_llm_server() {
    curl -sf \
        ${OPENAI_API_KEY:+-H "Authorization: Bearer ${OPENAI_API_KEY}"} \
        "${OPENAI_PROXY_URL}/models" \
        &>/dev/null
}

# ── 명령어 함수들 ──────────────────────────────────────────────────────────

cmd_start() {
    info "LobeChat 시작 중..."

    # LLM 서버 연결 확인
    if ! check_llm_server; then
        warn "LLM 서버에 연결할 수 없습니다: ${OPENAI_PROXY_URL}"
        warn "LLM 서버를 먼저 시작하세요."
        read -rp "그래도 계속하시겠습니까? [y/N]: " CONT
        [[ "${CONT,,}" == "y" ]] || { info "취소됨"; exit 0; }
    fi

    mkdir -p "$LOBECHAT_HOME/logs"

    if [[ "$LOBECHAT_RUNTIME" == "docker" ]]; then
        # ── Docker 실행 ──────────────────────────────────────────────────
        # 기존 컨테이너 정리
        docker stop lobechat 2>/dev/null || true
        docker rm   lobechat 2>/dev/null || true

        docker run -d \
            --name lobechat \
            -p "${LOBECHAT_PORT}:3210" \
            --env-file "$LOBECHAT_ENV" \
            --restart unless-stopped \
            lobehub/lobe-chat:latest \
            > /dev/null

        sleep 2
        if docker ps --filter "name=lobechat" --filter "status=running" -q | grep -q .; then
            ok "LobeChat 시작됨 (Docker, 포트 ${LOBECHAT_PORT})"
        else
            warn "컨테이너 시작 실패 — 로그 확인:"
            docker logs lobechat 2>&1 | tail -20
        fi

    else
        # ── Node.js 실행 ─────────────────────────────────────────────────
        # 이미 실행 중인지 확인
        if [[ -f "$PID_FILE" ]]; then
            OLD_PID=$(cat "$PID_FILE")
            if kill -0 "$OLD_PID" 2>/dev/null; then
                warn "이미 실행 중입니다 (PID: $OLD_PID)"
                return
            fi
        fi

        cd "$LOBECHAT_DIR"
        nohup env $(grep -v '^#' "$LOBECHAT_ENV" | grep -v '^$' | xargs) \
            node node_modules/.bin/next start -p "${LOBECHAT_PORT}" \
            > "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        sleep 3

        if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            ok "LobeChat 시작됨 (Node.js, PID: $(cat "$PID_FILE"), 포트: ${LOBECHAT_PORT})"
        else
            warn "시작 실패 — 로그 확인: tail -20 $LOG_FILE"
        fi
    fi

    cmd_status
    echo
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"
    ok "브라우저에서 접속: http://${LOCAL_IP}:${LOBECHAT_PORT}"
}

cmd_stop() {
    info "LobeChat 정지 중..."

    if [[ "$LOBECHAT_RUNTIME" == "docker" ]]; then
        docker stop lobechat 2>/dev/null && ok "정지 완료" || warn "실행 중인 컨테이너 없음"

    else
        if [[ -f "$PID_FILE" ]]; then
            PID=$(cat "$PID_FILE")
            if kill -0 "$PID" 2>/dev/null; then
                kill "$PID"
                rm -f "$PID_FILE"
                ok "정지 완료 (PID: $PID)"
            else
                warn "이미 정지된 프로세스 (PID: $PID)"
                rm -f "$PID_FILE"
            fi
        else
            warn "실행 중인 LobeChat 없음"
        fi
    fi
}

cmd_restart() {
    info "LobeChat 재시작 중..."
    cmd_stop
    sleep 2
    cmd_start
}

cmd_status() {
    echo -e "${BOLD}── LobeChat 상태 ────────────────────────────${NC}"

    if [[ "$LOBECHAT_RUNTIME" == "docker" ]]; then
        if docker ps --filter "name=lobechat" --filter "status=running" -q | grep -q .; then
            ok "실행 중 (Docker)"
            docker ps --filter "name=lobechat" --format "  컨테이너: {{.Names}}  상태: {{.Status}}"
        else
            warn "정지됨 (Docker)"
        fi
    else
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            ok "실행 중 (Node.js, PID: $(cat "$PID_FILE"))"
        else
            warn "정지됨 (Node.js)"
        fi
    fi

    echo
    echo -e "${BOLD}── LLM 서버 상태 (${OPENAI_PROXY_URL}) ──────${NC}"
    if check_llm_server; then
        ok "LLM 서버 응답 확인"
        info "모델: ${DEFAULT_MODEL}"
        curl -sf \
            ${OPENAI_API_KEY:+-H "Authorization: Bearer ${OPENAI_API_KEY}"} \
            "${OPENAI_PROXY_URL}/models" \
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
    info "로컬:  http://localhost:${LOBECHAT_PORT}"
    info "외부:  http://${LOCAL_IP}:${LOBECHAT_PORT} (Caddy 통해 접속 권장)"
}

cmd_logs() {
    info "실시간 로그 출력 중 (Ctrl+C로 중단)..."

    if [[ "$LOBECHAT_RUNTIME" == "docker" ]]; then
        docker logs -f lobechat
    else
        if [[ -f "$LOG_FILE" ]]; then
            tail -f "$LOG_FILE"
        else
            warn "로그 파일 없음: $LOG_FILE"
            info "서비스가 실행 중인지 확인: ./lobechat-run.sh status"
        fi
    fi
}

cmd_update() {
    info "LobeChat 업데이트 중..."

    if [[ "$LOBECHAT_RUNTIME" == "docker" ]]; then
        docker pull lobehub/lobe-chat:latest
        ok "이미지 업데이트 완료"
    else
        cd "$LOBECHAT_DIR"
        git pull origin main
        pnpm install --frozen-lockfile
        pnpm build
        ok "빌드 완료"
    fi

    echo
    read -rp "서비스를 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_restart
}

cmd_config() {
    info "설정 파일 편집 중..."
    "${EDITOR:-nano}" "$LOBECHAT_ENV"
    echo
    read -rp "변경사항을 적용하기 위해 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_restart
}

cmd_mcp() {
    info "MCP 설정 파일: $LOBECHAT_HOME/mcp-config.json"
    echo
    if [[ -f "$LOBECHAT_HOME/mcp-config.json" ]]; then
        python3 -c "
import json
with open('$LOBECHAT_HOME/mcp-config.json') as f:
    cfg = json.load(f)
servers = cfg.get('mcpServers', {})
print(f'  등록된 MCP 서버: {len(servers)}개')
for name, s in servers.items():
    desc = s.get('description', '')
    print(f'  • {name}: {desc}')
"
    else
        warn "MCP 설정 파일 없음"
        info "lobechat-install.sh를 재실행해 MCP를 설정하세요."
    fi
    echo
    info "LobeChat 웹 UI에서 MCP 활성화:"
    info "  Settings → Tools → MCP Servers"
}

cmd_help() {
    echo
    echo -e "${BOLD}LobeChat 관리 스크립트${NC}"
    echo
    echo "사용법: $0 <명령어>"
    echo
    echo -e "${BOLD}서비스 관리:${NC}"
    echo "  start      LobeChat 시작"
    echo "  stop       LobeChat 정지"
    echo "  restart    재시작"
    echo "  status     서비스 상태 + LLM 서버 상태 확인"
    echo "  logs       실시간 로그 (Ctrl+C로 중단)"
    echo
    echo -e "${BOLD}관리:${NC}"
    echo "  update     최신 버전으로 업데이트"
    echo "  config     설정 파일 편집 (.env)"
    echo "  mcp        MCP 서버 목록 확인"
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
    help|-h|--help) cmd_help ;;
    *)
        error "알 수 없는 명령어: $1 (./lobechat-run.sh help 참고)"
        ;;
esac
