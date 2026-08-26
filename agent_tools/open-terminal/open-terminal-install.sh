#!/usr/bin/env bash
# =============================================================================
# Open Terminal 설치 스크립트 — 격리 주체를 고른다
# 대상: Ubuntu · Open WebUI 의 "통합 > 터미널" 백엔드
#
# 철학: 설치 과정에 있어서 사용자는 스크립트 밖에서 아무것도 하지 않는다.
#
# ⚠ 이 도구는 LLM 에게 셸을 준다. 위험의 실체는 "모델이 나빠진다" 가 아니라
#   **프롬프트 인젝션** 이다 — 웹 검색으로 들어온 페이지의 문장이 셸을 움직인다.
#   그래서 '무엇으로 실행하는가'(주체)를 반드시 고르게 한다.
#
# ── 주체 (--mode) ─────────────────────────────────────────────────────────
#   sandbox  (기본) **작업 디렉터리에서만 읽기·쓰기·생성·삭제, sudo 금지.**
#                   bubblewrap 이 루트를 읽기 전용으로 걸고 당신 홈은 덮어 가린다.
#                   sudo 는 커널이 막는다(no_new_privs). 설치에 sudo 불필요.
#   agent           전용 계정으로 돌린다. 당신 홈을 물리적으로 못 읽는다.
#                   유출 차단(nftables)이 가능한 유일한 주체. sudo 1회 필요.
#   self            당신 계정 그대로. 쉽고 유용하고 무방비. 확인을 받는다.
#   docker          컨테이너. 격리는 최고지만 호스트 서비스를 못 본다.
#
# ── 이 박스에서 실측한 근거 ───────────────────────────────────────────────
#   · bwrap 0.11.1 비특권 동작 확인. --tmpfs 로 홈을 덮으면 내용 0개.
#   · bwrap 안에서 NoNewPrivs=1 → sudo 가 "prevents sudo from running as root"
#   · 일반 권한만으로는 부족하다 — /var/tmp 와 /dev/shm 은 누구나 쓸 수 있어
#     실측에서 쓰기가 성공했다. 그래서 루트를 --ro-bind 로 읽기 전용에 건다.
#   · /home/lota 는 drwxr-x--- → 전용 계정은 당신 홈을 못 읽는다.
#   · systemd 사용자 유닛의 IPAddressDeny= 는 **조용히 무시된다**(실측).
#     그래서 유출 차단은 nftables(agent) 또는 netns 격리(sandbox/docker)로만 한다.
#   · /proc 에 hidepid 가 없다 → 다른 사용자의 명령줄은 읽힌다(환경변수는 안전).
#
# 공식 문서: https://github.com/open-webui/open-terminal
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="sandbox"
PY_VERSION="3.12"                                   # open-terminal 요구: >=3.11
VENV="$SCRIPT_DIR/.venv"
OT_HOME="${OPEN_TERMINAL_HOME:-$HOME/.open-terminal}"
ENV_FILE="$OT_HOME/open-terminal.env"
LOG_DIR="$OT_HOME/logs"

OT_PORT="8022"          # 8000 은 vLLM 자리다
WORKSPACE="$HOME/agent-workspace"
AGENT_USER="owt-agent"
BLOCK_EGRESS=false
READ_SCOPE="system"     # system=시스템 읽기 허용(기본) · minimal=--strict
EXPOSE=()               # --expose <경로>[:ro]  (기본 rw)
ASSUME_YES=false
DO_SERVICE=false

usage() {
    cat <<EOU
사용법: $(basename "$0") [옵션]

  --mode MODE        sandbox | agent | self | docker   (기본 sandbox)
  --port N           기동 포트 (기본 ${OT_PORT}; 8000 은 vLLM 이 쓴다)
  --workspace PATH   에이전트가 자유롭게 쓸 디렉터리 (기본 ${WORKSPACE})
  --expose PATH[:ro] 샌드박스에 추가로 열어줄 경로. 여러 번 지정 가능.
                     기본은 읽기·쓰기. :ro 를 붙이면 읽기 전용.
                     예) --expose ~/Developments/vllm:ro
  --strict           읽기 범위까지 좁힌다 (sandbox 모드 전용).
                     /usr /etc 등 셸 동작에 꼭 필요한 것만 열고
                     /var /opt /srv /root /boot /media /mnt /snap 은 아예 없앤다.
                     기본값은 '쓰기만 제한' 이라 시스템 읽기가 가능하다.
  --block-egress     외부 네트워크 차단 (모드별로 의미가 다르다 — 아래 참고)
  --agent-user NAME  agent 모드에서 만들 계정 이름 (기본 ${AGENT_USER})
  --service          systemd 사용자 서비스로 등록
  --yes              위험 확인 프롬프트를 건너뜀 (self 모드 자동화용)
  -h, --help         이 도움말

  --block-egress 의 모드별 실제 동작:
    agent    nftables 로 **선택적 차단** — 로컬(vLLM 등)은 살리고 외부만 막는다
    sandbox  netns 분리로 **전면 차단** — vLLM·SearXNG 도 함께 끊긴다
    docker   --network none 으로 전면 차단
    self     불가. 요청하면 거부한다.
EOU
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)         MODE="$2"; shift 2 ;;
        --port)         OT_PORT="$2"; shift 2 ;;
        --workspace)    WORKSPACE="$2"; shift 2 ;;
        --expose)       EXPOSE+=("$2"); shift 2 ;;
        --strict)       READ_SCOPE="minimal"; shift ;;
        --block-egress) BLOCK_EGRESS=true; shift ;;
        --agent-user)   AGENT_USER="$2"; shift 2 ;;
        --service)      DO_SERVICE=true; shift ;;
        --yes|-y)       ASSUME_YES=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              error "알 수 없는 옵션: $1  (--help 참고)" ;;
    esac
done

case "$MODE" in
    sandbox|agent|self|docker) ;;
    *) error "알 수 없는 모드: $MODE  (sandbox|agent|self|docker)" ;;
esac

# ── 0. 모드별 위험 고지 ────────────────────────────────────────────────────
confirm_mode() {
    step "격리 주체: ${BOLD}${MODE}${NC}"

    case "$MODE" in
      sandbox)
        echo "  프로세스 주체 : $(id -un) (당신)"
        echo "  당신 홈       : bubblewrap 이 가린다 — 보이지 않음"
        echo "  쓰기 가능     : ${BOLD}작업공간뿐${NC} (+ 사설 /tmp, --expose 로 연 경로)"
        echo "                  생성·수정·삭제 모두 작업공간 안에서만 된다"
        if [[ "$READ_SCOPE" == "minimal" ]]; then
        echo -e "  그 밖         : ${BOLD}대부분 보이지 않는다${NC} (--strict)"
        echo "                  /usr /etc 만 읽기 전용으로 열고"
        echo "                  /var /opt /srv /root /boot /media /mnt /snap 은 없앤다"
        else
        echo "  그 밖         : 읽기는 가능, 쓰기는 전부 거부"
        echo "                  읽기까지 막으려면 --strict 로 재설치하라"
        fi
        echo "  sudo          : 커널이 차단 (no_new_privs)"
        echo "  호스트 서비스 : 보인다 (vLLM·SearXNG 접근 가능)"
        [[ "$BLOCK_EGRESS" == true ]] && \
        warn "--block-egress: netns 를 분리한다 → 외부와 함께 **vLLM 도 끊긴다**"
        ;;
      agent)
        echo "  프로세스 주체 : ${AGENT_USER} (신규 전용 계정)"
        echo "  당신 홈       : 못 읽는다 (/home/$(id -un) 은 drwxr-x---)"
        echo "  sudo          : 계정에 권한을 주지 않는다"
        echo "  ※ /proc 에 hidepid 가 없어 당신 프로세스의 '명령줄'은 읽힌다"
        echo "    (환경변수는 소유자 전용이라 안전. 명령줄에 토큰을 넣지 말 것)"
        warn "계정 생성과 uv 배치에 sudo 가 필요하다"
        ;;
      self)
        echo -e "  ${RED}${BOLD}격리 없음.${NC}"
        echo "  이 모드에서 LLM 은 당신 계정 권한을 그대로 가진다:"
        echo "    · ~/.ssh 키, git 자격증명, ~/.claude 설정을 읽을 수 있다"
        echo "    · ~/Developments/vllm 을 고치거나 지울 수 있다"
        echo "    · 실행 중인 vLLM 을 죽일 수 있다"
        echo "    · 읽은 것을 외부로 보낼 수 있다 (차단 수단 없음)"
        echo
        echo "  현실적인 공격 경로는 이렇다:"
        echo "    웹 검색 결과의 숨은 지시문 → 셸을 가진 모델이 실행 → 유출"
        ;;
      docker)
        echo "  프로세스 주체 : 컨테이너 내부 사용자"
        echo "  격리          : 최고 (파일시스템·프로세스·네트워크 분리)"
        warn "컨테이너는 호스트의 vLLM/ComfyUI/SearXNG 를 보지 못한다"
        warn "  '이 박스 운용 조수'로 쓸 수 없다. 독립 실험장 용도다."
        echo "  ※ docker.sock 은 절대 마운트하지 않는다 (루트 등가)"
        ;;
    esac
    echo

    if [[ "$MODE" == "self" && "$ASSUME_YES" != true ]]; then
        if [[ -t 0 ]]; then
            read -rp "  위 내용을 이해했으며 self 모드로 진행합니까? [yes/N]: " a
            [[ "$a" == "yes" ]] || { info "취소됨. --mode sandbox 를 권한다."; exit 0; }
        else
            error "self 모드는 확인이 필요하다. 대화형 터미널에서 실행하거나 --yes 를 붙여라."
        fi
    fi

    if [[ "$MODE" == "self" && "$BLOCK_EGRESS" == true ]]; then
        error "self 모드에서는 유출 차단이 불가능하다.\n  당신 UID 를 막으면 당신 셸도 함께 막힌다. --mode agent 를 쓰라."
    fi
}

# ── 1. 사전 점검 ───────────────────────────────────────────────────────────
check_prerequisites() {
    step "사전 점검"

    command -v curl &>/dev/null || error "curl 이 필요하다"

    if [[ "$OT_PORT" == "8000" ]]; then
        error "포트 8000 은 vLLM 자리다. --port 로 다른 값을 지정하라."
    fi

    OUR_INSTANCE=false
    if curl -sf --max-time 3 "http://127.0.0.1:${OT_PORT}/" &>/dev/null; then
        if [[ -f "$OT_HOME/open-terminal.pid" ]] && kill -0 "$(cat "$OT_HOME/open-terminal.pid")" 2>/dev/null; then
            OUR_INSTANCE=true
        elif [[ "$MODE" == "docker" ]] && docker ps --filter name=open-terminal -q 2>/dev/null | grep -q .; then
            OUR_INSTANCE=true
        fi
    fi
    if [[ "$OUR_INSTANCE" == true ]]; then
        warn "이미 이 스크립트가 띄운 Open Terminal 이 포트 ${OT_PORT} 에서 돌고 있다"
        warn "  설치는 계속한다 (내리지 않는다)"
    elif command -v ss &>/dev/null && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${OT_PORT}$"; then
        error "포트 ${OT_PORT} 가 이미 사용 중이다. --port 로 바꿔라."
    else
        ok "포트 ${OT_PORT} 사용 가능"
    fi

    case "$MODE" in
      sandbox)
        command -v bwrap &>/dev/null || error "bubblewrap 이 필요하다: sudo apt install bubblewrap"
        # 실제로 비특권 동작하는지 확인한다 (AppArmor 가 userns 를 막는 배포판이 있다)
        bwrap --ro-bind / / --dev /dev --unshare-pid true 2>/dev/null \
            || error "bwrap 이 비특권으로 동작하지 않는다.\n  --mode agent 또는 --mode docker 를 쓰라."
        ok "bubblewrap $(bwrap --version | awk '{print $NF}') — 비특권 동작 확인"
        ;;
      agent)
        sudo -n true 2>/dev/null || [[ -t 0 ]] \
            || error "agent 모드는 sudo 가 필요하다 (계정 생성). 대화형 터미널에서 실행하라."
        if [[ "$BLOCK_EGRESS" == true ]]; then
            command -v nft &>/dev/null || error "--block-egress 에는 nftables 가 필요하다: sudo apt install nftables"
        fi
        ;;
      docker)
        command -v docker &>/dev/null || error \
"docker 가 없다. 설치는 시스템 전역 변경이라 이 스크립트가 대신하지 않는다.
  설치:  curl -fsSL https://get.docker.com | sudo sh
         sudo usermod -aG docker \$USER   (재로그인 필요)
  또는 --mode sandbox 를 쓰라 (docker 불필요)."
        docker info &>/dev/null || error "docker 데몬에 접근할 수 없다 (docker 그룹 확인 후 재로그인)"
        ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
        ;;
    esac
}

# ── 2. uv ──────────────────────────────────────────────────────────────────
install_uv() {
    [[ "$MODE" == "docker" ]] && return 0
    step "uv 확인"
    if command -v uv &>/dev/null; then
        ok "uv $(uv --version | awk '{print $2}') — 이미 설치됨"
        return
    fi
    info "uv 설치 중..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv &>/dev/null || error "uv 설치 실패"
    ok "uv 설치 완료"
}

# ── 3. 설치 ────────────────────────────────────────────────────────────────
install_package() {
    [[ "$MODE" == "docker" ]] && return 0
    step "open-terminal 설치 (Python ${PY_VERSION})"

    if [[ -x "$VENV/bin/python" ]]; then
        local cur; cur=$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        [[ "$cur" == "$PY_VERSION" ]] || { warn "Python ${cur} → ${PY_VERSION} 재생성"; rm -rf "$VENV"; }
    fi
    [[ -d "$VENV" ]] || uv venv --python "$PY_VERSION" "$VENV"
    uv pip install --python "$VENV/bin/python" open-terminal
    [[ -x "$VENV/bin/open-terminal" ]] || error "open-terminal 실행파일이 생기지 않았다"

    local v; v=$("$VENV/bin/python" -c "from importlib.metadata import version; print(version('open-terminal'))" 2>/dev/null || echo '?')
    ok "open-terminal ${v}"

    local gi="$SCRIPT_DIR/.gitignore"
    for e in '.venv/' '.open-terminal'; do
        grep -qxF "$e" "$gi" 2>/dev/null || echo "$e" >> "$gi"
    done
}

# ── 4. 전용 계정 (agent 모드) ──────────────────────────────────────────────
setup_agent_user() {
    [[ "$MODE" == "agent" ]] || return 0
    step "전용 계정 ${AGENT_USER}"

    if id "$AGENT_USER" &>/dev/null; then
        ok "이미 존재하는 계정을 재사용한다"
    else
        info "계정 생성 중 (sudo 필요)..."
        sudo useradd --create-home --shell /bin/bash \
            --comment "Open Terminal agent (no sudo)" "$AGENT_USER"
        ok "생성됨: $AGENT_USER"
    fi

    # sudo 그룹에 절대 들어가지 않게 확인
    if id -nG "$AGENT_USER" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
        error "$AGENT_USER 가 sudo 그룹에 있다. 이 모드의 전제가 깨진다."
    fi
    ok "sudo 권한 없음 확인"

    # 이 계정이 쓸 uv — 당신 홈은 0750 이라 읽을 수 없으므로 전역에 배치한다
    if [[ ! -x /usr/local/bin/uv ]]; then
        info "uv 를 /usr/local/bin 에 배치 중 (전용 계정이 쓰려면 필요)..."
        sudo install -m 0755 "$(command -v uv)" /usr/local/bin/uv
    fi
    ok "/usr/local/bin/uv"

    # 작업공간을 전용 계정 소유로
    sudo mkdir -p "$WORKSPACE"
    sudo chown "$AGENT_USER:$AGENT_USER" "$WORKSPACE"
    ok "작업공간 소유권: $AGENT_USER → $WORKSPACE"

    info "패키지 설치 중 (전용 계정으로)..."
    sudo -u "$AGENT_USER" -H /usr/local/bin/uv tool install open-terminal
    ok "설치 완료"
}

# ── 5. 유출 차단 (agent 모드, nftables) ────────────────────────────────────
setup_egress_block() {
    [[ "$BLOCK_EGRESS" == true && "$MODE" == "agent" ]] || return 0
    step "유출 차단 (nftables)"

    local uid; uid=$(id -u "$AGENT_USER")
    info "${AGENT_USER}(uid ${uid}) 의 외부 아웃바운드를 차단한다"

    sudo nft -f - <<NFTEOF
table inet owt {
    chain output {
        type filter hook output priority 0; policy accept;
        meta skuid ${uid} ip  daddr 127.0.0.0/8 accept
        meta skuid ${uid} ip6 daddr ::1         accept
        meta skuid ${uid} counter drop
    }
}
NFTEOF
    ok "규칙 적용됨 — 로컬은 허용, 외부는 차단"
    warn "재부팅하면 사라진다. 영구화하려면:  sudo nft list table inet owt | sudo tee -a /etc/nftables.conf"
    warn "DNS 주의: 127.0.0.53(systemd-resolved)은 허용되고 resolved 가 대신 외부로 나간다."
    warn "  DNS 를 통한 소량 유출까지 막으려면 resolved 도 차단해야 한다."
}

# ── 6. API 키 + 기동 파라미터 ──────────────────────────────────────────────
write_launch_params() {
    step "기동 파라미터"

    mkdir -p "$OT_HOME" "$LOG_DIR"
    [[ "$MODE" == "agent" ]] || mkdir -p "$WORKSPACE"

    local key
    if [[ -f "$ENV_FILE" ]] && grep -q '^OPEN_TERMINAL_API_KEY=' "$ENV_FILE"; then
        key=$(grep '^OPEN_TERMINAL_API_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')
        info "기존 API 키 유지 (Open WebUI 에 다시 넣을 필요 없다)"
    else
        key=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
    fi

    # --expose 를 bwrap 인자로 미리 굳혀 둔다 (run 스크립트가 그대로 쓴다)
    local expose_args="" e p m
    for e in ${EXPOSE[@]+"${EXPOSE[@]}"}; do
        p="${e%:ro}"; m="bind"
        [[ "$e" == *:ro ]] && m="ro-bind"
        p="$(readlink -f "$p")" || error "존재하지 않는 경로: $e"
        expose_args+="--${m} ${p} ${p} "
    done

    cat > "$ENV_FILE" <<ENVEOF
# Open Terminal 기동 파라미터 — open-terminal-run.sh 가 읽는다.
OPEN_TERMINAL_MODE="${MODE}"
OPEN_TERMINAL_VENV="${VENV}"
OPEN_TERMINAL_HOME="${OT_HOME}"
OPEN_TERMINAL_PORT="${OT_PORT}"
OPEN_TERMINAL_WORKSPACE="${WORKSPACE}"
OPEN_TERMINAL_API_KEY="${key}"
OPEN_TERMINAL_AGENT_USER="${AGENT_USER}"
OPEN_TERMINAL_BLOCK_EGRESS="${BLOCK_EGRESS}"
# system: 루트를 읽기 전용으로 통째 바인드 (쓰기만 제한)
# minimal: 셸에 꼭 필요한 것만 바인드 (읽기 범위도 제한)
OPEN_TERMINAL_READ_SCOPE="${READ_SCOPE}"
# bwrap 추가 바인드 (sandbox 모드에서만 쓰인다)
OPEN_TERMINAL_EXPOSE="${expose_args}"
ENVEOF
    chmod 600 "$ENV_FILE"
    ok "$ENV_FILE"

    [[ -e "$SCRIPT_DIR/.open-terminal" ]] || ln -s "$OT_HOME" "$SCRIPT_DIR/.open-terminal"
}

# ── 7. 검증 ────────────────────────────────────────────────────────────────
smoke_test() {
    step "격리 검증"
    # 기동만 보는 게 아니라 **격리가 실제로 걸렸는지** 본다.
    "$SCRIPT_DIR/open-terminal-run.sh" verify || warn "검증에서 경고가 나왔다 — 위 출력을 확인하라"
}

# ── 8. systemd (선택) ──────────────────────────────────────────────────────
install_service() {
    [[ "$DO_SERVICE" == true ]] || return 0
    step "systemd 사용자 서비스"
    local unit_dir="$HOME/.config/systemd/user"; mkdir -p "$unit_dir"

    cat > "$unit_dir/open-terminal.service" <<SVCEOF
[Unit]
Description=Open Terminal (mode=${MODE})
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${OT_HOME}
ExecStart=${SCRIPT_DIR}/open-terminal-run.sh foreground
Restart=on-failure
RestartSec=10
# 파일시스템 하드닝 — 사용자 유닛에서도 실제로 동작한다.
# (IPAddressDeny= 는 사용자 유닛에서 조용히 무시되므로 넣지 않는다)
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${OT_HOME} ${WORKSPACE}

[Install]
WantedBy=default.target
SVCEOF

    if ! systemctl --user daemon-reload 2>/dev/null; then
        warn "systemd 사용자 세션 없음 — 유닛 파일만 남긴다"
        return 0
    fi
    systemctl --user enable open-terminal.service
    ok "등록됨: systemctl --user start open-terminal"
}

print_summary() {
    step "설치 완료"
    local key; key=$(grep '^OPEN_TERMINAL_API_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')
    echo
    echo -e "  ${BOLD}격리 주체${NC} : ${MODE}"
    echo "  작업공간   : $WORKSPACE"
    echo "  파라미터   : $ENV_FILE"
    echo
    echo -e "  ${BOLD}실행${NC}"
    echo "  ./open-terminal-run.sh start | stop | status | verify | logs"
    echo
    echo -e "  ${BOLD}Open WebUI 에 붙이기${NC}  (관리자 패널 > 통합 > 터미널 열기 > +)"
    echo "    URL     : http://127.0.0.1:${OT_PORT}"
    echo "    API Key : ${key}"
    echo
    echo "  ./open-terminal-run.sh key  로 언제든 다시 볼 수 있다"
    echo
    if [[ "$MODE" == "self" ]]; then
        warn "self 모드다. 웹 검색과 터미널을 같은 대화에서 함께 켜지 않기를 권한다."
    fi
}

main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   Open Terminal 설치                       ${NC}"
    echo -e "${BOLD}   LLM 에게 셸을 준다 — 주체를 고른다        ${NC}"
    echo -e "${BOLD}============================================${NC}"

    confirm_mode
    check_prerequisites
    install_uv
    install_package
    setup_agent_user
    setup_egress_block
    write_launch_params
    smoke_test
    install_service
    print_summary
}

main "$@"
