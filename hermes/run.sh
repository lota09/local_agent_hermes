#!/usr/bin/env bash
# =============================================================================
# Hermes Agent 서비스 관리 스크립트
# 사용법: ./run.sh [start|stop|restart|status|logs|chat|update|model|webui|webui-stop]
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── hermes 바이너리 경로 확인 ──────────────────────────────────────────────
HERMES=""
for candidate in \
    "$(command -v hermes 2>/dev/null)" \
    "$HOME/.local/bin/hermes" \
    "$HOME/.hermes/hermes-agent/venv/bin/hermes"
do
    if [[ -f "$candidate" ]]; then
        HERMES="$candidate"
        break
    fi
done

[[ -n "$HERMES" ]] || error "hermes를 찾을 수 없습니다. install.sh를 먼저 실행하세요."

# ── LLM 백엔드 설정 로드 ───────────────────────────────────────────────────
# install.sh가 저장한 ~/.hermes/llm-backend.env 읽기
LLM_BASE_URL="http://localhost:8080/v1"   # 기본값 (llama.cpp)
LLM_API_KEY="none"
LLM_MODEL="default"
if [[ -f "$HOME/.hermes/llm-backend.env" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.hermes/llm-backend.env"
fi

# LLM 서버 상태 확인 헬퍼
check_llm_server() {
    curl -sf \
        -H "Authorization: Bearer ${LLM_API_KEY}" \
        "${LLM_BASE_URL}/models" \
        &>/dev/null
}

# ── 명령어 함수들 ──────────────────────────────────────────────────────────

cmd_start() {
    info "Hermes 게이트웨이 시작 중..."

    # LLM 서버 연결 확인
    if ! check_llm_server; then
        warn "LLM 서버에 연결할 수 없습니다: ${LLM_BASE_URL}"
        warn "서버를 먼저 시작하세요. 예)"
        warn "  llama.cpp : llama-server -m model.gguf --port 8080"
        warn "  Ollama    : ollama serve"
        read -rp "그래도 계속하시겠습니까? [y/N]: " CONT
        [[ "${CONT,,}" == "y" ]] || { info "취소됨"; exit 0; }
    fi

    "$HERMES" gateway start
    sleep 2
    cmd_status
    echo
    ok "Discord 앱에서 봇에 메시지를 보내보세요!"
}

cmd_stop() {
    info "Hermes 게이트웨이 정지 중..."
    "$HERMES" gateway stop
    ok "정지 완료"
}

cmd_restart() {
    info "Hermes 게이트웨이 재시작 중..."
    "$HERMES" gateway stop 2>/dev/null || true
    sleep 2
    cmd_start
}

cmd_status() {
    echo -e "${BOLD}── Hermes 서비스 상태 ───────────────────────${NC}"
    "$HERMES" gateway status || true

    echo
    echo -e "${BOLD}── LLM 서버 상태 (${LLM_BASE_URL}) ──────────${NC}"
    if check_llm_server; then
        ok "LLM 서버 응답 확인"
        info "모델: ${LLM_MODEL}"
        # /v1/models 로 목록 출력 (OpenAI 표준)
        curl -sf \
            -H "Authorization: Bearer ${LLM_API_KEY}" \
            "${LLM_BASE_URL}/models" \
            | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d.get('data', [])[:5]:
        print(f'  - {m.get(\"id\",\"?\")}')
except: pass
" 2>/dev/null || true
    else
        warn "LLM 서버 응답 없음 (${LLM_BASE_URL})"
        info "서버 시작 예시:"
        info "  llama.cpp : llama-server -m /path/to/model.gguf --port 8080"
        info "  Ollama    : ollama serve"
    fi
}

cmd_logs() {
    info "실시간 로그 출력 중 (Ctrl+C로 중단)..."
    # systemd user service 로그 우선, 없으면 파일 로그
    if systemctl --user is-active hermes-gateway &>/dev/null 2>&1; then
        journalctl --user -u hermes-gateway -f --output=short-precise
    elif [[ -f "$HOME/.hermes/logs/gateway.log" ]]; then
        tail -f "$HOME/.hermes/logs/gateway.log"
    else
        warn "로그를 찾을 수 없습니다."
        info "서비스가 실행 중인지 확인: ./run.sh status"
    fi
}

cmd_chat() {
    info "터미널 채팅 모드 시작 (Ctrl+C 또는 /exit 로 종료)..."
    echo
    "$HERMES" chat
}

cmd_update() {
    info "Hermes Agent 업데이트 중..."
    "$HERMES" update
    ok "업데이트 완료"
    echo
    read -rp "서비스를 재시작하시겠습니까? [Y/n]: " RESTART
    [[ "${RESTART,,}" != "n" ]] && cmd_restart
}

cmd_model() {
    info "LLM 모델 설정 (대화형)..."
    "$HERMES" model
}

cmd_webui() {
    # Hermes 자체 웹 대시보드 사용 (포트 9119)
    # hermes dashboard: Hermes의 모든 에이전트 기능(도구, 메모리, 코드실행)이 포함된 공식 WebUI
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")"

    info "Hermes 대시보드 시작 중..."
    info "브라우저/스마트폰 접속 주소: http://${LOCAL_IP}:9119"
    info "(같은 네트워크에 있어야 합니다)"
    echo
    "$HERMES" dashboard
}

cmd_webui_stop() {
    info "Hermes 대시보드 정지 중..."
    "$HERMES" dashboard --stop
    ok "대시보드 정지 완료"
}

cmd_doctor() {
    info "Hermes 환경 진단 중..."
    "$HERMES" doctor
}

cmd_setup() {
    info "Hermes 초기 설정 마법사 (대화형)..."
    "$HERMES" setup
}

cmd_help() {
    echo
    echo -e "${BOLD}Hermes Agent 관리 스크립트${NC}"
    echo
    echo "사용법: $0 <명령어>"
    echo
    echo -e "${BOLD}서비스 관리:${NC}"
    echo "  start      게이트웨이 시작 (Discord 봇 활성화)"
    echo "  stop       게이트웨이 정지"
    echo "  restart    재시작"
    echo "  status     서비스 상태 + LLM 서버 상태 확인"
    echo "  logs       실시간 로그 보기 (Ctrl+C로 중단)"
    echo
    echo -e "${BOLD}사용:${NC}"
    echo "  chat       터미널에서 직접 대화"
    echo "  webui      Hermes 웹 대시보드 시작 (포트 9119, 스마트폰 접속 가능)"
  echo "  webui-stop 웹 대시보드 정지"
    echo
    echo -e "${BOLD}설정:${NC}"
    echo "  model      LLM 모델 변경"
    echo "  setup      초기 설정 마법사 재실행"
    echo "  update     최신 버전으로 업데이트"
    echo "  doctor     환경 진단"
    echo
    echo -e "${BOLD}예시:${NC}"
    echo "  $0 start"
    echo "  $0 logs"
    echo "  $0 webui     # Hermes 대시보드 (포트 9119) 시작"
    echo
    echo -e "${BOLD}Discord 채팅 내 명령어:${NC}"
    echo "  /new        대화 초기화"
    echo "  /model      모델 변경"
    echo "  /stop       현재 작업 중단"
    echo "  /approve    위험 명령어 승인"
    echo "  /deny       위험 명령어 거부"
    echo "  /background <작업>   백그라운드로 긴 작업 실행"
    echo "  /help       전체 명령어 목록"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
case "${1:-help}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    logs)    cmd_logs    ;;
    chat)    cmd_chat    ;;
    webui)      cmd_webui      ;;
    webui-stop) cmd_webui_stop ;;
    update)  cmd_update  ;;
    model)   cmd_model   ;;
    setup)   cmd_setup   ;;
    doctor)  cmd_doctor  ;;
    help|-h|--help) cmd_help ;;
    *)
        error "알 수 없는 명령어: $1 (./run.sh help 참고)"
        ;;
esac
