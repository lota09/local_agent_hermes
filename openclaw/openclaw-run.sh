#!/usr/bin/env bash
# =============================================================================
# OpenClaw 서비스 관리 스크립트
# 사용법: ./openclaw-run.sh [start|stop|restart|status|logs|ui|update|chat|doctor|help]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── openclaw 바이너리 확인 ─────────────────────────────────────────────────
OPENCLAW=""
for candidate in \
    "$(command -v openclaw 2>/dev/null)" \
    "$HOME/.local/bin/openclaw" \
    "$HOME/.npm-global/bin/openclaw" \
    "$(npm config get prefix 2>/dev/null)/bin/openclaw"
do
    [[ -n "$candidate" ]] && [[ -x "$candidate" ]] && { OPENCLAW="$candidate"; break; }
done

[[ -n "$OPENCLAW" ]] || error "openclaw를 찾을 수 없습니다. openclaw-install.sh를 먼저 실행하세요."

GATEWAY_PORT=18789

# LLM 서버 상태 확인 (설정 파일에서 URL 읽기 시도)
_check_llm() {
    local config_file="${OPENCLAW_HOME:-$HOME/.openclaw}/config.json"
    local base_url=""

    if [[ -f "$config_file" ]]; then
        base_url=$(python3 -c "
import json, sys
try:
    with open('$config_file') as f:
        cfg = json.load(f)
    url = cfg.get('model', {}).get('baseUrl', '') or \
          cfg.get('providers', {}).get('openai', {}).get('baseUrl', '')
    print(url.rstrip('/'))
except: pass
" 2>/dev/null || true)
    fi

    # 설정에서 못 찾으면 알려진 포트 스캔
    if [[ -z "$base_url" ]]; then
        for port in 11436 8080 11434 1234; do
            if curl -sf --max-time 1 "http://localhost:${port}/v1/models" &>/dev/null; then
                base_url="http://localhost:${port}/v1"
                break
            fi
        done
    fi

    [[ -n "$base_url" ]] && curl -sf --max-time 2 "${base_url}/models" &>/dev/null
}

# ── 명령어 함수들 ──────────────────────────────────────────────────────────

cmd_start() {
    info "OpenClaw Gateway 시작 중..."

    if "$OPENCLAW" gateway status 2>/dev/null | grep -qi "running\|active"; then
        ok "Gateway 이미 실행 중"
        return
    fi

    "$OPENCLAW" gateway start \
        || error "Gateway 시작 실패. 로그 확인: ./openclaw-run.sh logs"

    sleep 2
    cmd_status
    echo
    ok "Gateway 시작됨 (포트 ${GATEWAY_PORT})"
    info "웹 UI: openclaw-run.sh ui"
}

cmd_stop() {
    info "OpenClaw Gateway 정지 중..."
    "$OPENCLAW" gateway stop 2>/dev/null && ok "정지 완료" || warn "이미 정지되어 있을 수 있음"
}

cmd_restart() {
    info "OpenClaw Gateway 재시작 중..."
    "$OPENCLAW" gateway restart 2>/dev/null \
        || { cmd_stop; sleep 2; cmd_start; }
    sleep 2
    cmd_status
}

cmd_status() {
    echo -e "${BOLD}── OpenClaw Gateway 상태 ─────────────────────${NC}"
    "$OPENCLAW" gateway status 2>/dev/null || warn "Gateway 상태를 가져올 수 없습니다"

    echo
    echo -e "${BOLD}── LLM 서버 상태 ─────────────────────────────${NC}"
    if _check_llm; then
        ok "LLM 서버 응답 확인"
    else
        warn "LLM 서버 응답 없음"
        info "llama.cpp 시작 예시:"
        info "  llama-server -m model.gguf --port 11436"
    fi

    echo
    echo -e "${BOLD}── 접속 정보 ─────────────────────────────────${NC}"
    if curl -sf --max-time 2 "http://localhost:${GATEWAY_PORT}" &>/dev/null; then
        ok "대시보드 응답 중"
        info "웹 UI: http://localhost:${GATEWAY_PORT}"
    else
        warn "대시보드 응답 없음 (포트 ${GATEWAY_PORT})"
    fi
}

cmd_logs() {
    info "실시간 로그 출력 중 (Ctrl+C로 중단)..."
    "$OPENCLAW" logs --follow 2>/dev/null \
        || "$OPENCLAW" gateway logs --follow 2>/dev/null \
        || {
            # 로그 파일 직접 tail
            local log_file="${OPENCLAW_HOME:-$HOME/.openclaw}/logs/gateway.log"
            if [[ -f "$log_file" ]]; then
                tail -f "$log_file"
            else
                warn "로그를 찾을 수 없습니다."
                info "Gateway 실행 후 다시 시도하세요: ./openclaw-run.sh start"
            fi
        }
}

cmd_ui() {
    info "OpenClaw 웹 대시보드 열기..."
    "$OPENCLAW" dashboard \
        || {
            warn "dashboard 명령 실패"
            info "브라우저에서 직접 접속: http://localhost:${GATEWAY_PORT}"
        }
}

cmd_update() {
    info "OpenClaw 최신 버전으로 업데이트 중..."

    local current_ver
    current_ver=$("$OPENCLAW" --version 2>/dev/null | head -1 || echo "unknown")
    info "현재 버전: ${current_ver}"

    # Gateway 정지 후 업데이트 후 재시작
    "$OPENCLAW" gateway stop 2>/dev/null || true
    sleep 1

    npm install -g openclaw@latest \
        || error "업데이트 실패. 위 오류를 확인하세요."

    local new_ver
    new_ver=$("$OPENCLAW" --version 2>/dev/null | head -1 || echo "unknown")
    ok "업데이트 완료: ${current_ver} → ${new_ver}"

    echo
    read -rp "Gateway를 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_start
}

cmd_chat() {
    info "터미널 채팅 모드 (Ctrl+C로 종료)..."
    echo
    "$OPENCLAW" agent --interactive 2>/dev/null \
        || "$OPENCLAW" chat 2>/dev/null \
        || {
            warn "대화형 모드를 찾을 수 없습니다."
            info "단일 메시지 전송: openclaw agent -m '메시지'"
        }
}

cmd_doctor() {
    info "OpenClaw 환경 진단 중..."
    "$OPENCLAW" doctor
}

cmd_help() {
    echo
    echo -e "${BOLD}OpenClaw 관리 스크립트${NC}"
    echo
    echo "사용법: $0 <명령어>"
    echo
    echo -e "${BOLD}서비스 관리:${NC}"
    echo "  start    Gateway 시작"
    echo "  stop     Gateway 정지"
    echo "  restart  재시작"
    echo "  status   Gateway + LLM 서버 상태 확인"
    echo "  logs     실시간 로그 (Ctrl+C로 중단)"
    echo
    echo -e "${BOLD}사용:${NC}"
    echo "  ui       웹 대시보드 열기 (포트 18789)"
    echo "  chat     터미널 대화 모드"
    echo "  doctor   환경 진단"
    echo
    echo -e "${BOLD}관리:${NC}"
    echo "  update   최신 버전으로 업데이트"
    echo
    echo -e "${BOLD}직접 명령어:${NC}"
    echo "  openclaw onboard        # 설정 마법사 재실행"
    echo "  openclaw gateway --help # Gateway 상세 옵션"
    echo "  openclaw doctor         # 환경 진단"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
case "${1:-help}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    logs)    cmd_logs    ;;
    ui)      cmd_ui      ;;
    update)  cmd_update  ;;
    chat)    cmd_chat    ;;
    doctor)  cmd_doctor  ;;
    help|-h|--help) cmd_help ;;
    *)
        error "알 수 없는 명령어: $1 (./openclaw-run.sh help 참고)"
        ;;
esac
