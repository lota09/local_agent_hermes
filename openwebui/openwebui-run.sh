#!/usr/bin/env bash
# =============================================================================
# Open WebUI 서비스 관리 스크립트
# 사용법: ./openwebui-run.sh [start|stop|restart|status|logs|health|update|params|help]
#
# 이 스크립트는 '띄우고 내리는' 일만 한다. Open WebUI 의 설정은 앱 안에 있다.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 기동 파라미터 위치를 '가정'하지 않고 찾는다:
#   1) OPENWEBUI_HOME 환경변수
#   2) 설치 스크립트가 만든 심볼릭 링크 (--home 으로 옮겨도 여기서 따라간다)
#   3) 기본 경로
ENV_FILE=""
for _cand in \
    "${OPENWEBUI_HOME:-}/openwebui.env" \
    "$SCRIPT_DIR/.open-webui/openwebui.env" \
    "$HOME/.open-webui/openwebui.env"
do
    [[ -n "$_cand" && -f "$_cand" ]] && { ENV_FILE="$_cand"; break; }
done

[[ -n "$ENV_FILE" ]] || error "기동 파라미터를 찾을 수 없다.\n  openwebui-install.sh 를 먼저 실행하거나 OPENWEBUI_HOME 을 지정하라."

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

VENV="${OPENWEBUI_VENV:-$SCRIPT_DIR/.venv}"
OW_BIN="$VENV/bin/open-webui"
OW_HOME="${OPENWEBUI_HOME:-$(dirname "$ENV_FILE")}"
OW_DATA="${OPENWEBUI_DATA_DIR:-$OW_HOME/data}"
HOST="${OPENWEBUI_HOST:-127.0.0.1}"
PORT="${OPENWEBUI_PORT:-8080}"
LLM_URL="${STATUS_LLM_URL:-}"
LLM_KEY="${STATUS_LLM_KEY:-}"

PID_FILE="$OW_HOME/openwebui.pid"
LOG_FILE="$OW_HOME/logs/openwebui.log"

# ── 자가 치유: 도구 디렉터리를 옮기면 env 파일의 절대경로가 죽는다.
if [[ ! -x "$OW_BIN" && -x "$SCRIPT_DIR/.venv/bin/open-webui" ]]; then
    warn "경로가 바뀌었다 — 기동 파라미터를 현재 위치로 갱신한다"
    VENV="$SCRIPT_DIR/.venv"; OW_BIN="$VENV/bin/open-webui"
    sed -i "s|^OPENWEBUI_VENV=.*|OPENWEBUI_VENV=\"$VENV\"|" "$ENV_FILE"
    _unit="$HOME/.config/systemd/user/openwebui.service"
    if [[ -f "$_unit" ]]; then
        sed -i "s|^ExecStart=.*|ExecStart=$VENV/bin/open-webui serve --host $HOST --port $PORT|" "$_unit"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    ok "갱신됨: $ENV_FILE"
fi

[[ -x "$OW_BIN" ]] || error "실행파일 없음: $OW_BIN\n  openwebui-install.sh 를 먼저 실행하라."

USE_SYSTEMD=false
if systemctl --user cat openwebui.service &>/dev/null; then
    USE_SYSTEMD=true
fi

# agent_tools 통합 실행 스크립트. 이름이 바뀌면 이 한 줄을 고친다.
TOOLS_SH="$SCRIPT_DIR/../agent_tools/run_tools.sh"

WITH_TOOLS=false   # --with-tools 로 켜진다

# agent_tools 통합 실행 스크립트를 그대로 호출한다 (인자 없으면 대화형 다중 선택)
cmd_tools() {
    [[ -x "$TOOLS_SH" ]] || error "실행할 수 없다: $TOOLS_SH"
    if [[ $# -gt 0 ]]; then "$TOOLS_SH" "$@"; else "$TOOLS_SH"; fi
}

# ── 헬퍼 ───────────────────────────────────────────────────────────────────
# open-webui 0.11.0 CLI 에는 --version 이 없다. 패키지 메타데이터에서 읽는다.
ow_version() {
    "$VENV/bin/python" -c \
        "from importlib.metadata import version; print(version('open-webui'))" 2>/dev/null || echo '?'
}

is_running() {
    if [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user is-active --quiet openwebui.service
    else
        [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
    fi
}

check_health() {
    curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q 'true'
}

wait_healthy() {
    local i
    for i in $(seq 1 120); do
        check_health && return 0
        is_running || return 1
        sleep 1
    done
    return 1
}

# ── 명령어 ─────────────────────────────────────────────────────────────────
cmd_start() {
    # Open WebUI 는 도구(SearXNG·터미널)에 붙어 도니 도구를 먼저 올린다.
    if [[ "$WITH_TOOLS" == true ]]; then
        if [[ -x "$TOOLS_SH" ]]; then
            info "agent_tools 를 먼저 기동한다"
            "$TOOLS_SH" start --all || warn "일부 도구 기동 실패 — 계속 진행한다"
            echo
        else
            warn "agent_tools 를 찾지 못했다: $TOOLS_SH — 건너뜀"
        fi
    fi

    if is_running; then
        warn "이미 실행 중이다"
        echo; cmd_status
        return
    fi

    mkdir -p "$(dirname "$LOG_FILE")" "$OW_DATA"
    info "Open WebUI 시작 중..."

    if [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user start openwebui.service
    else
        # cwd 고정이 중요하다: 앱은 .webui_secret_key 를 cwd 에 만든다
        # (backend/open_webui/__init__.py:13). 여기가 흔들리면 매 기동마다
        # 새 키가 생겨 로그인 세션이 전부 끊긴다.
        #
        # ⚠ 서브셸 ( ... & echo $! ) 로 감싸면 $! 가 데몬이 아니라 서브셸 PID 를
        #   가리킨다. 그러면 stop 이 엉뚱한 프로세스를 죽이고, 살아남은 서브셸이
        #   부모의 파이프를 붙들어 `start | tee` 같은 호출이 멈춘다.
        #   그래서 서브셸 없이 현재 셸에서 직접 띄운다.
        cd "$OW_HOME"
        DATA_DIR="$OW_DATA" nohup "$OW_BIN" serve --host "$HOST" --port "$PORT" \
            < /dev/null >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
    fi

    if wait_healthy; then
        ok "기동 완료"
    else
        warn "기동 확인 실패 — 로그를 보라: $0 logs"
        [[ -f "$LOG_FILE" ]] && tail -20 "$LOG_FILE"
        return 1
    fi

    echo
    cmd_status
}

cmd_stop() {
    info "Open WebUI 정지 중..."
    # 정지는 역순 — 프런트를 먼저 내리고 도구를 내린다. (아래 _stop_tools 에서)

    if [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user stop openwebui.service && ok "정지 완료"
        return
    fi

    if [[ ! -f "$PID_FILE" ]]; then
        warn "실행 중인 Open WebUI 없음"
        return
    fi

    local pid
    pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        warn "이미 정지된 프로세스 (PID: $pid)"
        rm -f "$PID_FILE"
        return
    fi

    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 15); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        warn "정상 종료 실패 — SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    ok "정지 완료 (PID: $pid)"
}

_stop_tools() {
    [[ "$WITH_TOOLS" == true ]] || return 0
    [[ -x "$TOOLS_SH" ]] || { warn "agent_tools 를 찾을 수 없다: $TOOLS_SH — 건너뜀"; return 0; }
    echo; info "agent_tools 정지한다"
    "$TOOLS_SH" stop --all || warn "일부 도구 정지 실패"
}

cmd_restart() { cmd_stop; sleep 2; cmd_start; }

cmd_status() {
    echo -e "${BOLD}── Open WebUI ───────────────────────────────${NC}"

    if is_running; then
        if [[ "$USE_SYSTEMD" == true ]]; then
            ok "실행 중 (systemd --user)"
        else
            ok "실행 중 (PID: $(cat "$PID_FILE"))"
        fi
        check_health && ok "/health 정상" || warn "/health 무응답 (기동 중일 수 있다)"
    else
        warn "정지됨"
    fi
    info "버전: $(ow_version)"
    info "데이터: $OW_DATA"

    # 참고 표시일 뿐이다. Open WebUI 가 실제로 어디에 붙는지는 앱의 DB 가 안다.
    echo
    if [[ -z "$LLM_URL" ]]; then
        echo -e "${BOLD}── LLM 백엔드 ───────────────────────────────${NC}"
        info "표시용 주소 미설정 — 연결 상태는 관리자 패널 > Connections 에서 확인하라"
        info "여기에 표시하려면 openwebui.env 의 STATUS_LLM_URL 을 채워라"
    else
    echo -e "${BOLD}── LLM 백엔드 (참고: ${LLM_URL}) ──${NC}"
    if curl -sf --max-time 5 ${LLM_KEY:+-H "Authorization: Bearer ${LLM_KEY}"} "${LLM_URL}/models" &>/dev/null; then
        ok "응답 확인"
        curl -sf --max-time 5 ${LLM_KEY:+-H "Authorization: Bearer ${LLM_KEY}"} "${LLM_URL}/models" | "$VENV/bin/python" -c '
import json, sys
try:
    for m in json.load(sys.stdin).get("data", [])[:10]:
        print("  - " + str(m.get("id", "?")))
except Exception:
    pass
' 2>/dev/null || true
        info "실제 연결 설정은 관리자 패널 > Connections 에서 확인하라"
    else
        warn "응답 없음 — 백엔드가 떠 있는지, 인증 키가 필요한지 확인하라"
    fi
    fi

    echo
    echo -e "${BOLD}── GPU ──────────────────────────────────────${NC}"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader | sed 's/^/  /'
    else
        info "nvidia-smi 없음"
    fi

    echo
    echo -e "${BOLD}── 접속 ─────────────────────────────────────${NC}"
    info "로컬: http://127.0.0.1:${PORT}"
    if [[ "$HOST" == "0.0.0.0" ]]; then
        info "외부: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}  (외부 노출 중)"
    else
        info "바인딩 ${HOST} — 로컬 전용"
    fi
}

# 대화 기록 조회 — 디버깅할 때 화면을 복사해 붙일 필요를 없앤다.
cmd_chats() {
    local db="$OW_DATA/webui.db"
    [[ -f "$db" ]] || error "DB 없음: $db"
    [[ -f "$SCRIPT_DIR/chatlog.py" ]] || error "chatlog.py 없음: $SCRIPT_DIR"
    "$VENV/bin/python" "$SCRIPT_DIR/chatlog.py" "$db" "$@"
}

# 삭제한 대화의 잔여 흔적 진단·정리 (기본은 진단만, --apply 로 실행)
cmd_purge() {
    local db="$OW_DATA/webui.db"
    [[ -f "$db" ]] || error "DB 없음: $db"
    if [[ " $* " == *" --apply "* ]]; then
        is_running && error "실행 중에는 정리할 수 없다. 먼저: $0 stop"
        warn "되돌릴 수 없다. 백업을 권한다:"
        warn "  cp $db ${db}.bak"
    fi
    # 로그는 Open WebUI 것과 SearXNG 것 둘 다 본다 (검색어가 남는 쪽은 SearXNG 다)
    local logs=(--log "$LOG_FILE")
    [[ -f "$HOME/.searxng/logs/searxng.log" ]] && logs+=(--log "$HOME/.searxng/logs/searxng.log")
    "$VENV/bin/python" "$SCRIPT_DIR/purge.py" "$db" \
        --uploads "$OW_DATA/uploads" "${logs[@]}" "$@"
}

cmd_logs() {
    if [[ "$USE_SYSTEMD" == true ]]; then
        journalctl --user -u openwebui.service -f
    elif [[ -f "$LOG_FILE" ]]; then
        info "실시간 로그 (Ctrl+C 로 중단): $LOG_FILE"
        tail -f "$LOG_FILE"
    else
        warn "로그 파일 없음: $LOG_FILE"
    fi
}

cmd_health() {
    check_health && ok "정상" || error "무응답 — http://127.0.0.1:${PORT}/health"
}

cmd_update() {
    local was_running=false
    is_running && was_running=true

    if [[ "$was_running" == true ]]; then
        info "업데이트를 위해 정지한다"
        cmd_stop
    fi

    info "현재: $(ow_version)"
    warn "DB 마이그레이션은 다음 기동 때 자동 실행된다. 백업을 권한다:"
    warn "  cp ${OW_DATA}/webui.db ${OW_DATA}/webui.db.bak"
    uv pip install --python "$VENV/bin/python" --upgrade open-webui
    ok "업데이트 후: $(ow_version)"

    [[ "$was_running" == true ]] && cmd_start
}

cmd_params() {
    info "기동 파라미터: $ENV_FILE"
    info "(Open WebUI 의 '설정'이 아니다 — 그건 관리자 패널에 있다)"
    echo
    grep -vE '^\s*#|^\s*$' "$ENV_FILE" | sed 's/^/  /'
}

cmd_help() {
    cat <<EOU
Open WebUI 관리

  ./openwebui-run.sh start      시작 (기동 완료까지 대기)
  ./openwebui-run.sh stop       정지
  ./openwebui-run.sh restart    재시작
  ./openwebui-run.sh status     상태 + 참고용 LLM 백엔드 + GPU
  ./openwebui-run.sh logs       실시간 로그
  ./openwebui-run.sh health     헬스체크만
  ./openwebui-run.sh update     최신 버전으로 업그레이드
  ./openwebui-run.sh params     기동 파라미터 출력

  ── agent_tools 연동 ──
  ./openwebui-run.sh tools [인자…]       통합 실행 스크립트 호출
                                         (인자 없으면 대화형 다중 선택)
  ./openwebui-run.sh start --with-tools  도구 먼저 올리고 Open WebUI 기동
  ./openwebui-run.sh stop  --with-tools  Open WebUI 내리고 도구도 정지

  ── 대화 기록 ──
  ./openwebui-run.sh chats               대화 목록
  ./openwebui-run.sh chats <번호|id>     대화 내용 (도구 호출·출처 포함)
  ./openwebui-run.sh chats <번호> --full 잘라내지 않고 전부
  ./openwebui-run.sh purge               삭제한 대화의 잔여 흔적 진단
  ./openwebui-run.sh purge --apply       삭제한 대화의 잔여물 정리 (정지 상태에서)
  ./openwebui-run.sh purge --everything  살아있는 대화까지 전부 지울 때 무엇이
                                         지워지는지 미리 보기
  ./openwebui-run.sh purge --everything --apply
                                         대화 기록 전부 소거 (설정·산출물은 유지)

  ※ LLM 연결·모델·음성·이미지 설정은 브라우저의 관리자 패널에서 한다.

기동 파라미터 : $ENV_FILE
venv          : $VENV
EOU
}

# --with-tools 를 먼저 걷어낸다 (start/stop/restart 공통)
ARGS=()
for _a in "$@"; do
    case "$_a" in
        --with-tools|-T) WITH_TOOLS=true ;;
        *) ARGS+=("$_a") ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "${1:-help}" in
    start)   cmd_start   ;;
    stop)    cmd_stop; _stop_tools ;;
    restart) cmd_restart ;;
    tools)   shift; cmd_tools "$@" ;;
    chats)   shift; cmd_chats "$@" ;;
    purge)   shift; cmd_purge "$@" ;;
    status)  cmd_status  ;;
    logs)    cmd_logs    ;;
    health)  cmd_health  ;;
    update)  cmd_update  ;;
    params)  cmd_params  ;;
    help|-h|--help) cmd_help ;;
    *)       error "알 수 없는 명령: $1  (help 참고)" ;;
esac
