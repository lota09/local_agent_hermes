#!/usr/bin/env bash
# =============================================================================
# Open Terminal 서비스 관리
# 사용법: ./open-terminal-run.sh [start|stop|restart|status|verify|key|logs|foreground|help]
#
# 격리 주체(mode)에 따라 기동 방식이 완전히 다르다. 그 분기가 이 파일의 핵심이다.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE=""
for _c in "${OPEN_TERMINAL_HOME:-}/open-terminal.env" \
          "$SCRIPT_DIR/.open-terminal/open-terminal.env" \
          "$HOME/.open-terminal/open-terminal.env"; do
    [[ -n "$_c" && -f "$_c" ]] && { ENV_FILE="$_c"; break; }
done
[[ -n "$ENV_FILE" ]] || error "기동 파라미터를 찾을 수 없다.\n  open-terminal-install.sh 를 먼저 실행하라."

set -a; . "$ENV_FILE"; set +a

MODE="$OPEN_TERMINAL_MODE"
VENV="$OPEN_TERMINAL_VENV"
OT_HOME="$OPEN_TERMINAL_HOME"
PORT="$OPEN_TERMINAL_PORT"
WORKSPACE="$OPEN_TERMINAL_WORKSPACE"
API_KEY="$OPEN_TERMINAL_API_KEY"
AGENT_USER="$OPEN_TERMINAL_AGENT_USER"
BLOCK_EGRESS="$OPEN_TERMINAL_BLOCK_EGRESS"
EXPOSE_ARGS="${OPEN_TERMINAL_EXPOSE:-}"
READ_SCOPE="${OPEN_TERMINAL_READ_SCOPE:-system}"
OT_DIE_WITH_PARENT=""   # 포그라운드(systemd)에서만 켠다 — 아래 cmd_foreground 참고

PID_FILE="$OT_HOME/open-terminal.pid"
LOG_FILE="$OT_HOME/logs/open-terminal.log"

# 자가 치유: 디렉터리를 옮기면 venv 절대경로가 죽는다
if [[ "$MODE" != "docker" && ! -x "$VENV/bin/open-terminal" && -x "$SCRIPT_DIR/.venv/bin/open-terminal" ]]; then
    warn "경로가 바뀌었다 — 기동 파라미터를 갱신한다"
    VENV="$SCRIPT_DIR/.venv"
    sed -i "s|^OPEN_TERMINAL_VENV=.*|OPEN_TERMINAL_VENV=\"$VENV\"|" "$ENV_FILE"
    ok "갱신됨"
fi

USE_SYSTEMD=false
systemctl --user cat open-terminal.service &>/dev/null && USE_SYSTEMD=true

# 샌드박스에서 파이썬을 살리는 데 필요한 읽기 전용 바인드 목록
_python_binds() {
    local out=""
    # uv 관리 인터프리터 루트 (심볼릭 링크 중간 경로까지 포함)
    [[ -d "$HOME/.local/share/uv/python" ]] && out+="--ro-bind $HOME/.local/share/uv/python $HOME/.local/share/uv/python "
    # uv 밖의 인터프리터를 쓰는 경우를 위한 폴백
    local real; real="$(readlink -f "$VENV/bin/python" 2>/dev/null || true)"
    if [[ -n "$real" && "$real" != "$HOME/.local/share/uv/python"* ]]; then
        local base; base="$(dirname "$(dirname "$real")")"
        [[ -d "$base" ]] && out+="--ro-bind $base $base "
    fi
    printf '%s' "$out"
}

# ── 기동 명령 조립 ─────────────────────────────────────────────────────────
# 모드별로 '누가 실행하는가'가 달라진다. 이게 이 도구의 전부다.
build_cmd() {
    case "$MODE" in
      sandbox)
        # 목표: **작업공간에서만 읽기·쓰기·생성·삭제, sudo 금지.**
        #
        #   --ro-bind / /        루트 전체를 읽기 전용으로 건다.
        #                        일반 권한만으로는 부족하다 — /var/tmp, /dev/shm 처럼
        #                        누구나 쓸 수 있는 곳이 남기 때문이다(실측 확인).
        #   --tmpfs $HOME        당신 홈은 아예 보이지 않게 덮는다.
        #   --bind $WORKSPACE    여기만 완전한 쓰기(생성·삭제 포함).
        #   --tmpfs /tmp         쓸 수 있지만 사설이라 호스트를 오염시키지 않는다.
        #                        (대부분의 도구가 /tmp 없이는 동작하지 않는다)
        #   no_new_privs         bwrap 이 자동으로 켠다 → setuid 무효화 → sudo 불가.
        #
        # venv 와 파이썬 인터프리터가 홈 아래에 있으므로 tmpfs 뒤에 다시 열어준다.
        # venv/bin/python 은 심볼릭 링크 체인이라 최종 실체만 바인드하면
        # 중간 경로가 tmpfs 아래로 사라져 shebang 이 깨진다(bad interpreter).
        # uv 의 python 루트를 통째로 연다. 바인드 마운트라 비용은 없다.
        local pybinds; pybinds="$(_python_binds)"
        local net=(); [[ "$BLOCK_EGRESS" == true ]] && net=(--unshare-net)
        local base=()
        if [[ "$READ_SCOPE" == "minimal" ]]; then
            # 셸이 돌아가는 데 꼭 필요한 것만 연다. 나머지는 존재하지 않는다.
            # (/bin /sbin /lib /lib64 는 우분투에서 usr 로 가는 심볼릭 링크다)
            # /etc/resolv.conf 는 우분투에서 /run/systemd/resolve/... 로 가는
            # 심볼릭 링크다. /run 을 안 열면 DNS 만 조용히 죽는다 — IP 직접 접속은
            # 되는데 이름 해석만 안 되는, 차단된 것처럼 보이지만 아닌 상태가 된다.
            # 읽기 범위 제한과 네트워크 차단은 별개 축이므로(--block-egress)
            # 여기서는 이름 해석에 필요한 최소한만 되살린다.
            base=(--ro-bind /usr /usr --ro-bind /etc /etc
                  --ro-bind-try /run/systemd/resolve /run/systemd/resolve
                  --symlink usr/bin /bin --symlink usr/sbin /sbin
                  --symlink usr/lib /lib --symlink usr/lib64 /lib64)
        else
            # 루트를 읽기 전용으로 통째 건다 → 읽기는 되고 쓰기는 막힌다
            base=(--ro-bind / / --tmpfs "$HOME")
        fi
        CMD=(bwrap
            "${base[@]}"
            --ro-bind "$VENV" "$VENV"
            $pybinds
            --bind "$WORKSPACE" "$WORKSPACE"
            --tmpfs /tmp
            --dev /dev --proc /proc
            --unshare-pid
            ${OT_DIE_WITH_PARENT:+--die-with-parent}
            "${net[@]}"
            $EXPOSE_ARGS
            --chdir "$WORKSPACE"
            -- "$VENV/bin/open-terminal" run
               --host 127.0.0.1 --port "$PORT" --api-key "$API_KEY")
        ;;
      agent)
        CMD=(sudo -u "$AGENT_USER" -H
             "/home/$AGENT_USER/.local/bin/open-terminal" run
             --host 127.0.0.1 --port "$PORT" --api-key "$API_KEY")
        ;;
      self)
        CMD=(env -C "$WORKSPACE" "$VENV/bin/open-terminal" run
             --host 127.0.0.1 --port "$PORT" --api-key "$API_KEY")
        ;;
      docker)
        local net=(); [[ "$BLOCK_EGRESS" == true ]] && net=(--network none)
        # docker.sock 은 마운트하지 않는다 — 루트 등가다.
        CMD=(docker run --rm --name open-terminal
             -p "127.0.0.1:${PORT}:8000"
             -v open-terminal:/home/user
             -e "OPEN_TERMINAL_API_KEY=${API_KEY}"
             "${net[@]}"
             ghcr.io/open-webui/open-terminal)
        ;;
    esac
}

is_running() {
    if [[ "$MODE" == "docker" ]]; then
        docker ps --filter name=open-terminal --filter status=running -q 2>/dev/null | grep -q .
    elif [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user is-active --quiet open-terminal.service
    else
        [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
    fi
}
# open-terminal 은 '/' 에 라우트가 없다(404). 헬스는 /health 다.
check_up() { curl -sf --max-time 3 -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null; }

# systemd 가 감독할 때는 부모와 함께 죽는 편이 맞다.
cmd_foreground() { OT_DIE_WITH_PARENT=1; build_cmd; exec "${CMD[@]}"; }

cmd_start() {
    is_running && { warn "이미 실행 중이다"; echo; cmd_status; return; }
    mkdir -p "$(dirname "$LOG_FILE")" "$WORKSPACE" 2>/dev/null || true
    info "Open Terminal 시작 중 (mode=${MODE})..."

    if [[ "$USE_SYSTEMD" == true && "$MODE" != "docker" ]]; then
        systemctl --user start open-terminal.service
    else
        build_cmd
        # setsid 는 이 문맥에서 fork 없이 exec 하므로 PID = PGID = SID 가 된다(실측).
        # 덕분에 아래 cmd_stop 이 `kill -- -PID` 로 샌드박스 전체를 정리할 수 있다.
        setsid "${CMD[@]}" < /dev/null >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
    fi

    local i
    for i in $(seq 1 45); do
        check_up && { ok "기동 완료 (${i}초)"; echo; cmd_status; return; }
        is_running || { warn "기동 실패 — 로그:"; tail -20 "$LOG_FILE" 2>/dev/null; return 1; }
        sleep 1
    done
    warn "45초 안에 응답이 없다 — $0 logs"
    return 1
}

cmd_stop() {
    info "정지 중..."
    if [[ "$MODE" == "docker" ]]; then
        docker stop open-terminal &>/dev/null && ok "정지 완료" || warn "실행 중인 컨테이너 없음"
        return
    fi
    if [[ "$USE_SYSTEMD" == true ]]; then
        systemctl --user stop open-terminal.service && ok "정지 완료"; return
    fi
    [[ -f "$PID_FILE" ]] || { warn "실행 중인 Open Terminal 없음"; return; }
    local pid; pid=$(cat "$PID_FILE")
    kill -0 "$pid" 2>/dev/null || { warn "이미 정지됨"; rm -f "$PID_FILE"; _assert_port_free; return; }

    # 프로세스 그룹 전체 (bwrap + pidns init + 서버)
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    local i; for i in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then
        warn "정상 종료 실패 — 그룹에 SIGKILL"
        kill -KILL -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE"
    ok "정지 완료 (PID: $pid)"
    _assert_port_free
}

# 정지했다고 말하기 전에 포트가 실제로 풀렸는지 본다.
_assert_port_free() {
    sleep 0.5
    if curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null; then
        warn "포트 ${PORT} 를 아직 무언가가 물고 있다:"
        ss -ltnp 2>/dev/null | grep ":${PORT}" | sed 's/^/    /' || true
        warn "  수동 정리: pkill -f 'open-terminal run'"
        return 1
    fi
    return 0
}

cmd_restart() { cmd_stop; sleep 2; cmd_start; }

cmd_status() {
    echo -e "${BOLD}── Open Terminal ────────────────────────────${NC}"
    if is_running; then
        ok "실행 중 (mode=${MODE})"
        check_up && ok "HTTP 응답 정상" || warn "HTTP 무응답"
    else
        warn "정지됨 (mode=${MODE})"
    fi
    info "작업공간: $WORKSPACE"
    case "$MODE" in
      sandbox) info "격리: bubblewrap — 홈 가림 + sudo 커널 차단" ;;
      agent)   info "격리: 전용 계정 ${AGENT_USER}" ;;
      self)    warn "격리: 없음 (self 모드)" ;;
      docker)  info "격리: 컨테이너 (호스트 서비스 접근 불가)" ;;
    esac
    [[ "$BLOCK_EGRESS" == true ]] && info "유출 차단: 켜짐" || info "유출 차단: 꺼짐"
    echo
    echo -e "${BOLD}── Open WebUI 에 넣을 값 ────────────────────${NC}"
    info "URL     : http://127.0.0.1:${PORT}"
    info "API Key : $0 key"
    return 0
}

cmd_key() { echo "$API_KEY"; }

# ── 격리가 실제로 걸렸는지 확인한다 ────────────────────────────────────────
# 설정이 '적용됨'으로 보고되는 것과 실제로 동작하는 것은 다르다.
# (systemd 의 IPAddressDeny 가 조용히 무시된 사례를 겪었다)
cmd_verify() {
    echo -e "${BOLD}── 격리 실측 (mode=${MODE}) ─────────────────${NC}"

    case "$MODE" in
      sandbox)
        # venv/bin/python 은 심볼릭 링크 체인이라 최종 실체만 바인드하면
        # 중간 경로가 tmpfs 아래로 사라져 shebang 이 깨진다(bad interpreter).
        # uv 의 python 루트를 통째로 연다. 바인드 마운트라 비용은 없다.
        local pybinds; pybinds="$(_python_binds)"
        local net=(); [[ "$BLOCK_EGRESS" == true ]] && net=(--unshare-net)
        local base=()
        if [[ "$READ_SCOPE" == "minimal" ]]; then
            # /etc/resolv.conf 는 우분투에서 /run/systemd/resolve/... 로 가는
            # 심볼릭 링크다. /run 을 안 열면 DNS 만 조용히 죽는다 — IP 직접 접속은
            # 되는데 이름 해석만 안 되는, 차단된 것처럼 보이지만 아닌 상태가 된다.
            # 읽기 범위 제한과 네트워크 차단은 별개 축이므로(--block-egress)
            # 여기서는 이름 해석에 필요한 최소한만 되살린다.
            base=(--ro-bind /usr /usr --ro-bind /etc /etc
                  --ro-bind-try /run/systemd/resolve /run/systemd/resolve
                  --symlink usr/bin /bin --symlink usr/sbin /sbin
                  --symlink usr/lib /lib --symlink usr/lib64 /lib64)
        else
            base=(--ro-bind / / --tmpfs "$HOME")
        fi
        echo "  읽기 범위     : $READ_SCOPE"
        bwrap "${base[@]}" \
              --ro-bind "$VENV" "$VENV" $pybinds \
              --bind "$WORKSPACE" "$WORKSPACE" --tmpfs /tmp \
              --dev /dev --proc /proc --unshare-pid --die-with-parent \
              "${net[@]}" $EXPOSE_ARGS \
              bash -c '
                echo "  / 에 보이는 것: $(ls / | tr "\n" " ")"
                n=$(ls -A "'"$HOME"'" 2>/dev/null | wc -l)
                echo "  당신 홈       : ${n}개 항목만 보임 (마운트 지점뿐)"
                grep -q "NoNewPrivs:.1" /proc/self/status \
                  && echo "  sudo          : 불가 (no_new_privs=1)" || echo "  sudo          : 가능 ← 문제!"
                echo "  ── 작업공간 안 (전부 가능해야 정상) ──"
                w="'"$WORKSPACE"'"
                ( mkdir -p "$w/.owt/sub" && echo hi > "$w/.owt/sub/f" \
                  && [ "$(cat "$w/.owt/sub/f")" = hi ] && rm -rf "$w/.owt" ) \
                  && echo "    생성·쓰기·읽기·삭제: 전부 성공" \
                  || echo "    작업 실패 ← 문제!"
                # /tmp 와 /dev/shm 은 bwrap 이 만든 **사설 tmpfs** 다.
                # 쓸 수 있지만 호스트에 남지 않고 종료 시 사라진다(실측 확인).
                # 대부분의 프로그램이 이 둘 없이는 동작하지 않으므로 의도적으로 둔다.
                echo "  ── 사설 스크래치 (써도 호스트에 안 남음) ──"
                for p in /tmp /dev/shm; do
                  if touch "$p/.owt-probe" 2>/dev/null; then
                    rm -f "$p/.owt-probe"
                    echo "    $p : 쓰기 가능 (사설 tmpfs — 호스트에 안 남음)"
                  else
                    echo "    $p : 쓰기 불가 — 일부 도구가 실패할 수 있다"
                  fi
                done
                echo "  ── 호스트 파일시스템 (전부 거부되어야 정상) ──"
                for p in /usr/bin /etc /var/tmp /opt /srv; do
                  if touch "$p/.owt-probe" 2>/dev/null; then
                    echo "    $p : 쓰기 성공 ← 문제!"; rm -f "$p/.owt-probe"
                  else
                    echo "    $p : 거부됨"
                  fi
                done
                echo "  ── 네트워크 ──"
                if command -v curl >/dev/null; then
                  curl -sf --max-time 5 -o /dev/null https://example.com \
                    && echo "    외부       : 열림" || echo "    외부       : 차단"
                  curl -sf --max-time 3 -o /dev/null http://127.0.0.1:8000/v1/models \
                    && echo "    호스트 vLLM: 접근 가능" || echo "    호스트 vLLM: 접근 불가"
                fi
              ' 2>&1
        ;;
      agent)
        id "$AGENT_USER" &>/dev/null || { warn "계정 없음: $AGENT_USER"; return 1; }
        echo "  주체        : $AGENT_USER (uid $(id -u "$AGENT_USER"))"
        id -nG "$AGENT_USER" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel' \
            && echo -e "  sudo 그룹   : ${RED}포함됨 ← 문제!${NC}" || echo "  sudo 그룹   : 없음"
        sudo -u "$AGENT_USER" test -r "$HOME" 2>/dev/null \
            && echo -e "  당신 홈 읽기: ${RED}가능 ← 문제!${NC}" || echo "  당신 홈 읽기: 불가"
        sudo -u "$AGENT_USER" test -w "$WORKSPACE" 2>/dev/null \
            && echo "  작업공간    : 쓰기 가능" || echo "  작업공간    : 쓰기 불가 ← 문제!"
        if [[ "$BLOCK_EGRESS" == true ]]; then
            sudo -u "$AGENT_USER" curl -sf --max-time 6 -o /dev/null https://example.com \
                && echo -e "  외부 네트워크: ${RED}열림 ← 차단 실패!${NC}" || echo "  외부 네트워크: 차단됨"
            sudo -u "$AGENT_USER" curl -sf --max-time 3 -o /dev/null http://127.0.0.1:8000/v1/models \
                && echo "  호스트 vLLM : 접근 가능" || echo "  호스트 vLLM : 접근 불가"
        fi
        ;;
      self)
        echo -e "  ${RED}격리 없음.${NC} LLM 이 $(id -un) 권한을 그대로 갖는다."
        echo "  · ~/.ssh, git 자격증명, ~/Developments 전부 읽기·쓰기 가능"
        echo "  · 유출 차단 수단 없음"
        warn "웹 검색과 터미널을 같은 대화에서 함께 켜지 않기를 권한다"
        ;;
      docker)
        command -v docker &>/dev/null || { warn "docker 없음"; return 1; }
        echo "  격리: 컨테이너"
        echo "  호스트 vLLM/ComfyUI/SearXNG 접근 불가 (설계상 의도)"
        docker ps --filter name=open-terminal --format "  컨테이너: {{.Names}} {{.Status}}" 2>/dev/null || true
        ;;
    esac
}

cmd_logs() {
    if [[ "$MODE" == "docker" ]]; then docker logs -f open-terminal
    elif [[ "$USE_SYSTEMD" == true ]]; then journalctl --user -u open-terminal.service -f
    elif [[ -f "$LOG_FILE" ]]; then tail -f "$LOG_FILE"
    else warn "로그 없음: $LOG_FILE"; fi
}

cmd_help() {
    cat <<EOU
Open Terminal 관리  (현재 mode=${MODE})

  ./open-terminal-run.sh start        시작
  ./open-terminal-run.sh stop         정지
  ./open-terminal-run.sh restart      재시작
  ./open-terminal-run.sh status       상태
  ./open-terminal-run.sh verify       격리가 실제로 걸렸는지 실측
  ./open-terminal-run.sh key          API 키 출력
  ./open-terminal-run.sh logs         실시간 로그
  ./open-terminal-run.sh foreground   포그라운드 실행 (systemd 용)

  주체를 바꾸려면 재설치한다:
    ./open-terminal-install.sh --mode agent --block-egress
EOU
}

case "${1:-help}" in
    start) cmd_start ;;  stop) cmd_stop ;;  restart) cmd_restart ;;
    status) cmd_status ;;  verify) cmd_verify ;;  key) cmd_key ;;
    logs) cmd_logs ;;  foreground) cmd_foreground ;;
    help|-h|--help) cmd_help ;;
    *) error "알 수 없는 명령: $1" ;;
esac
