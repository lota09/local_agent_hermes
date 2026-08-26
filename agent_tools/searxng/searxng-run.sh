#!/usr/bin/env bash
# =============================================================================
# SearXNG 서비스 관리 스크립트
# 사용법: ./searxng-run.sh [start|stop|restart|status|logs|test|update|help]
#
# 이 스크립트는 띄우고 내리는 일만 한다. 검색 동작 설정은 settings.yml 에 있다.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE=""
for _c in "${SEARXNG_HOME:-}/searxng.env" "$SCRIPT_DIR/.searxng/searxng.env" "$HOME/.searxng/searxng.env"; do
    [[ -n "$_c" && -f "$_c" ]] && { ENV_FILE="$_c"; break; }
done
[[ -n "$ENV_FILE" ]] || error "기동 파라미터를 찾을 수 없다.\n  searxng-install.sh 를 먼저 실행하라."

set -a; . "$ENV_FILE"; set +a

VENV="$SEARXNG_VENV"; SRC="$SEARXNG_SRC"
SX_HOME="$SEARXNG_HOME"; SETTINGS="$SEARXNG_SETTINGS_PATH"

# ── 자가 치유: 도구 디렉터리를 옮기면 env 파일의 절대경로가 죽는다.
#    venv 와 src 는 언제나 이 스크립트 옆에 있으므로 SCRIPT_DIR 기준으로 되찾는다.
_healed=false
[[ -x "$VENV/bin/python" ]] || { VENV="$SCRIPT_DIR/.venv";  _healed=true; }
[[ -d "$SRC/searx"       ]] || { SRC="$SCRIPT_DIR/src";     _healed=true; }
if [[ "$_healed" == true ]]; then
    [[ -x "$VENV/bin/python" && -d "$SRC/searx" ]] \
        || error "venv/src 를 찾을 수 없다: $SCRIPT_DIR\n  searxng-install.sh 를 다시 실행하라."
    warn "경로가 바뀌었다 — 기동 파라미터를 현재 위치로 갱신한다"
    sed -i "s|^SEARXNG_VENV=.*|SEARXNG_VENV=\"$VENV\"|; s|^SEARXNG_SRC=.*|SEARXNG_SRC=\"$SRC\"|" "$ENV_FILE"
    ok "갱신됨: $ENV_FILE"
    # systemd 유닛도 절대경로를 담고 있으므로 함께 손본다
    _unit="$HOME/.config/systemd/user/searxng.service"
    if [[ -f "$_unit" ]]; then
        sed -i "s|^Environment=PYTHONPATH=.*|Environment=PYTHONPATH=$SRC|; s|^ExecStart=.*|ExecStart=$VENV/bin/python -m searx.webapp|" "$_unit"
        systemctl --user daemon-reload 2>/dev/null || true
        ok "systemd 유닛도 갱신됨"
    fi
fi
PID_FILE="$SX_HOME/searxng.pid"
LOG_FILE="$SX_HOME/logs/searxng.log"

[[ -f "$SETTINGS" ]] || error "설정 파일 없음: $SETTINGS"
PORT=$(awk '/^  port:/{print $2}' "$SETTINGS")
HOST=$(awk -F'"' '/^  bind_address:/{print $2}' "$SETTINGS")
PROBE_HOST="$HOST"; [[ "$PROBE_HOST" == "0.0.0.0" ]] && PROBE_HOST="127.0.0.1"

USE_SYSTEMD=false
systemctl --user cat searxng.service &>/dev/null && USE_SYSTEMD=true

is_running() {
    if [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user is-active --quiet searxng.service
    else
        [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
    fi
}
check_up() { curl -sf --max-time 3 "http://${PROBE_HOST}:${PORT}/" &>/dev/null; }

cmd_start() {
    if is_running; then warn "이미 실행 중이다"; echo; cmd_status; return; fi

    mkdir -p "$(dirname "$LOG_FILE")"
    info "SearXNG 시작 중..."

    if [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user start searxng.service
    else
        cd "$SX_HOME"
        SEARXNG_SETTINGS_PATH="$SETTINGS" PYTHONPATH="$SRC" \
            nohup "$VENV/bin/python" -m searx.webapp < /dev/null >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
    fi

    local i
    for i in $(seq 1 60); do
        check_up && { ok "기동 완료 (${i}초)"; echo; cmd_status; return; }
        is_running || { warn "기동 실패 — 로그:"; tail -20 "$LOG_FILE"; return 1; }
        sleep 1
    done
    warn "60초 안에 응답이 없다 — $0 logs"
    return 1
}

cmd_stop() {
    info "SearXNG 정지 중..."
    if [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user stop searxng.service && ok "정지 완료"; return
    fi
    [[ -f "$PID_FILE" ]] || { warn "실행 중인 SearXNG 없음"; return; }
    local pid; pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then warn "이미 정지됨"; rm -f "$PID_FILE"; return; fi
    kill "$pid" 2>/dev/null || true
    local i; for i in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && { warn "SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
    rm -f "$PID_FILE"
    ok "정지 완료 (PID: $pid)"
}

cmd_restart() { cmd_stop; sleep 2; cmd_start; }

cmd_status() {
    echo -e "${BOLD}── SearXNG ──────────────────────────────────${NC}"
    if is_running; then
        [[ "$USE_SYSTEMD" == true ]] && ok "실행 중 (systemd --user)" || ok "실행 중 (PID: $(cat "$PID_FILE"))"
        check_up && ok "HTTP 응답 정상" || warn "HTTP 무응답 (기동 중일 수 있다)"
    else
        warn "정지됨"
    fi
    info "설정: $SETTINGS"
    info "리비전: $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '?')"
    echo
    echo -e "${BOLD}── Open WebUI 에 넣을 값 ────────────────────${NC}"
    info "쿼리 URL: http://${PROBE_HOST}:${PORT}/search?q=<query>"
    if [[ "$HOST" == "0.0.0.0" ]]; then warn "0.0.0.0 바인딩 — 외부 노출 중"; fi
    # 함수의 반환값은 마지막 명령의 종료 코드다. 상태 출력이 실패로 오인되지 않게 고정.
    return 0
}

cmd_test() {
    is_running || error "SearXNG 가 실행 중이 아니다. 먼저: $0 start"
    local q="${2:-open webui}"
    info "JSON 검색 시도: '$q'"
    local out
    out=$(curl -sf --max-time 25 --get --data-urlencode "q=${q}" --data "format=json" \
        "http://${PROBE_HOST}:${PORT}/search") || error "요청 실패"
    echo "$out" | "$VENV/bin/python" -c '
import json, sys
d = json.load(sys.stdin)
rs = d.get("results", [])
print(f"  결과 {len(rs)}건 · 응답 엔진: {", ".join(sorted(set(e for r in rs for e in r.get("engines", []))))[:120]}")
for r in rs[:5]:
    print("  -", (r.get("title") or "")[:70])
    print("   ", (r.get("url") or "")[:90])
'
    echo
    info "결과가 0건이면 settings.yml 의 search.formats 에 json 이 있는지 확인하라"
}

cmd_logs() {
    if [[ "$USE_SYSTEMD" == true ]]; then journalctl --user -u searxng.service -f
    elif [[ -f "$LOG_FILE" ]]; then info "실시간 로그: $LOG_FILE"; tail -f "$LOG_FILE"
    else warn "로그 파일 없음: $LOG_FILE"; fi
}

cmd_update() {
    local was=false; is_running && was=true
    [[ "$was" == true ]] && { info "업데이트를 위해 정지"; cmd_stop; }
    info "현재: $(git -C "$SRC" rev-parse --short HEAD)"
    git -C "$SRC" fetch --depth 1 origin master && git -C "$SRC" checkout -q FETCH_HEAD
    uv pip install --python "$VENV/bin/python" -r "$SRC/requirements.txt"
    ok "갱신: $(git -C "$SRC" rev-parse --short HEAD)"
    info "settings.yml 은 건드리지 않았다 (use_default_settings 로 새 기본값을 상속한다)"
    [[ "$was" == true ]] && cmd_start
}

cmd_help() {
    cat <<EOU
SearXNG 관리

  ./searxng-run.sh start        시작
  ./searxng-run.sh stop         정지
  ./searxng-run.sh restart      재시작
  ./searxng-run.sh status       상태 + Open WebUI 에 넣을 URL
  ./searxng-run.sh test [질의]  JSON 검색이 실제로 되는지 확인
  ./searxng-run.sh logs         실시간 로그
  ./searxng-run.sh update       소스 갱신

  검색 엔진 목록·필터 등은 settings.yml 에서 바꾼다:
    $SETTINGS
EOU
}

case "${1:-help}" in
    start) cmd_start ;;  stop) cmd_stop ;;  restart) cmd_restart ;;
    status) cmd_status ;;  test) cmd_test "$@" ;;  logs) cmd_logs ;;
    update) cmd_update ;;  help|-h|--help) cmd_help ;;
    *) error "알 수 없는 명령: $1  (help 참고)" ;;
esac
