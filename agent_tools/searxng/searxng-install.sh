#!/usr/bin/env bash
# =============================================================================
# SearXNG 설치 스크립트 (Docker 없이, uv venv)
# 대상: Ubuntu · Open WebUI 의 웹 검색 백엔드로 쓰기 위한 로컬 전용 구성
#
# 철학: 설치 과정에 있어서 사용자는 스크립트 밖에서 아무것도 하지 않는다.
#
#   단, SearXNG 에는 설정 UI 가 없다. settings.yml 이 곧 그 앱의 인터페이스다.
#   그래서 이 스크립트는 settings.yml 을 만든다 — 대신 두 가지를 지킨다:
#     · `use_default_settings: true` 로 업스트림 기본값을 그대로 상속하고
#       **구조적으로 필요한 것만** 덮어쓴다 (아래 4개)
#     · 파일이 이미 있으면 **절대 건드리지 않는다**
#
# 반드시 덮어써야 하는 4가지 (근거는 아래 write_settings 주석 참조):
#   1. search.formats 에 json      — 없으면 Open WebUI 검색이 전부 빈 결과
#   2. server.limiter: false       — 봇 차단이 Open WebUI 를 막는다
#   3. server.secret_key           — 없으면 기동 거부
#   4. server.port: 8888           — 기본 8080 이 Open WebUI 와 충돌
#
# 근거 (2026-08 확인):
#   - 공식 소스 설치 : https://docs.searxng.org/admin/installation-searxng.html
#   - Open WebUI 연동: https://docs.openwebui.com/features/chat-conversations/web-search/providers/searxng/
#   - PyPI 의 `searxng` 는 0.0.0.dev0 자리표시자(7KB)다. git 설치가 유일한 경로다.
#   - 테마 빌드 산출물은 리포에 커밋돼 있다(searx/static/themes/simple/*.min.*).
#     따라서 node/npm 빌드 단계가 필요 없다.
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

PY_VERSION="3.12"                                    # SearXNG 요구: >=3.11
VENV="${SEARXNG_VENV:-$SCRIPT_DIR/.venv}"
SRC="${SEARXNG_SRC:-$SCRIPT_DIR/src}"
SX_HOME="${SEARXNG_HOME:-$HOME/.searxng}"
SETTINGS="$SX_HOME/settings.yml"
ENV_FILE="$SX_HOME/searxng.env"
LOG_DIR="$SX_HOME/logs"

SX_HOST="${SEARXNG_HOST:-127.0.0.1}"                 # 로컬 전용
SX_PORT="${SEARXNG_PORT:-8888}"                      # 8080 은 Open WebUI 자리
GIT_REF="${SEARXNG_REF:-master}"

DO_APT=true
DO_SMOKE=true
DO_SERVICE=false
OPT_HOST_SET=false; OPT_PORT_SET=false

usage() {
    cat <<EOU
사용법: $(basename "$0") [옵션]

  --port N        기동 포트 (기본 ${SX_PORT}; 8080 은 Open WebUI 가 쓴다)
  --host H        바인딩 주소 (기본 ${SX_HOST})
  --home PATH     설정·로그 위치 (기본 ${SX_HOME})
  --ref REF       체크아웃할 git 리비전 (기본 ${GIT_REF})
  --no-apt        시스템 패키지 설치 건너뜀
  --no-smoke      설치 후 검색 검증 건너뜀
  --service       systemd 사용자 서비스로 등록
  -h, --help      이 도움말
EOU
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    SX_PORT="$2"; OPT_PORT_SET=true; shift 2 ;;
        --host)    SX_HOST="$2"; OPT_HOST_SET=true; shift 2 ;;
        --home)    SX_HOME="$2"; SETTINGS="$SX_HOME/settings.yml"
                   ENV_FILE="$SX_HOME/searxng.env"; LOG_DIR="$SX_HOME/logs"; shift 2 ;;
        --ref)     GIT_REF="$2"; shift 2 ;;
        --no-apt)  DO_APT=false; shift ;;
        --no-smoke) DO_SMOKE=false; shift ;;
        --service) DO_SERVICE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         error "알 수 없는 옵션: $1  (--help 참고)" ;;
    esac
done

# ── 1. 사전 점검 ───────────────────────────────────────────────────────────
check_prerequisites() {
    step "사전 점검"

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        info "OS: ${PRETTY_NAME:-unknown}"
    fi

    command -v curl &>/dev/null || error "curl 이 필요하다"
    command -v git  &>/dev/null || error "git 이 필요하다: sudo apt install git"

    local venv_parent; venv_parent="$(dirname "$VENV")"
    mkdir -p "$venv_parent" 2>/dev/null || true
    [[ -w "$venv_parent" ]] || error "쓰기 불가: $venv_parent"
    mkdir -p "$SX_HOME" 2>/dev/null || error "생성 불가: $SX_HOME"
    [[ -w "$SX_HOME" ]] || error "쓰기 불가: $SX_HOME"

    # 이미 우리 인스턴스가 떠 있으면 막지 말고 검증만 건너뛴다
    OUR_INSTANCE=false
    if curl -sf --max-time 3 "http://127.0.0.1:${SX_PORT}/healthz" &>/dev/null \
       || curl -sf --max-time 3 "http://127.0.0.1:${SX_PORT}/" &>/dev/null; then
        if [[ -f "$SX_HOME/searxng.pid" ]] && kill -0 "$(cat "$SX_HOME/searxng.pid")" 2>/dev/null; then
            OUR_INSTANCE=true
        fi
    fi
    if [[ "$OUR_INSTANCE" == true ]]; then
        warn "이미 이 스크립트가 띄운 SearXNG 가 포트 ${SX_PORT} 에서 돌고 있다"
        warn "  설치는 계속한다. 검증은 건너뛴다 (내리지 않는다)"
        DO_SMOKE=false
        return
    fi

    local probe_host="$SX_HOST"
    [[ "$probe_host" == "0.0.0.0" || "$probe_host" == "::" ]] && probe_host="127.0.0.1"
    if command -v ss &>/dev/null; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "^(\[::\]|0\.0\.0\.0|\*|${probe_host//./\\.})[:.]${SX_PORT}$"; then
            error "포트 ${SX_PORT} 가 이미 사용 중이다. --port 로 다른 포트를 지정하라."
        fi
        ok "포트 ${SX_PORT} 사용 가능 (ss 확인)"
    elif (exec 3<>"/dev/tcp/${probe_host}/${SX_PORT}") 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        error "포트 ${SX_PORT} 에 이미 응답하는 것이 있다."
    else
        ok "포트 ${SX_PORT} 사용 가능 (ss 없음 — 접속 시도로 확인)"
    fi
}

# ── 2. uv ──────────────────────────────────────────────────────────────────
install_uv() {
    step "uv 확인"
    if command -v uv &>/dev/null; then
        ok "uv $(uv --version | awk '{print $2}') — 이미 설치됨"
        return
    fi
    info "uv 설치 중..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv &>/dev/null || error "uv 설치 실패"
    ok "uv $(uv --version | awk '{print $2}') 설치 완료"
}

# ── 3. 시스템 패키지 ───────────────────────────────────────────────────────
# 공식 소스 설치 문서의 의존성 중 컴파일에 필요한 것들.
# lxml 은 보통 휠이 있어 안 쓰이지만, 없을 때의 폴백으로 둔다.
install_system_deps() {
    step "시스템 패키지"
    [[ "$DO_APT" == true ]] || { warn "--no-apt 지정 — 건너뜀"; return; }
    command -v apt-get &>/dev/null || { warn "apt-get 없음 — 건너뜀"; return; }

    local pkgs=(build-essential python3-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev git)
    local missing=()
    for p in "${pkgs[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done

    if [[ ${#missing[@]} -eq 0 ]]; then ok "필요한 시스템 패키지가 모두 있다"; return; fi
    info "설치 필요: ${missing[*]}"

    if sudo -n true 2>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}" && ok "설치 완료"
    elif [[ -t 0 ]]; then
        info "sudo 비밀번호가 필요하다..."
        sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}" && ok "설치 완료" \
            || warn "설치 실패 — 계속 진행한다 (휠이 있으면 문제없다)"
    else
        warn "sudo 불가(비대화 세션) — 건너뜀. 필요하면: sudo apt install ${missing[*]}"
    fi
}

# ── 4. 소스 ────────────────────────────────────────────────────────────────
fetch_source() {
    step "SearXNG 소스"

    if [[ -d "$SRC/.git" ]]; then
        info "기존 소스 갱신 중..."
        git -C "$SRC" fetch --depth 1 origin "$GIT_REF"
        git -C "$SRC" checkout -q FETCH_HEAD
    else
        info "clone 중 (${GIT_REF})..."
        git clone --depth 1 --branch "$GIT_REF" https://github.com/searxng/searxng "$SRC" 2>/dev/null \
            || git clone --depth 1 https://github.com/searxng/searxng "$SRC"
    fi
    ok "소스: $SRC ($(git -C "$SRC" rev-parse --short HEAD))"

    # 테마 빌드 산출물이 커밋돼 있는지 확인 — 없으면 node 빌드가 필요해진다
    if compgen -G "$SRC/searx/static/themes/simple/*.min.css" > /dev/null; then
        ok "테마 빌드 산출물 확인 — node 빌드 불필요"
    else
        warn "테마 산출물이 없다. HTML UI 는 깨지지만 JSON API 는 동작한다"
    fi

    local gi="$SCRIPT_DIR/.gitignore"
    for e in '.venv/' 'src/' '.searxng'; do grep -qxF "$e" "$gi" 2>/dev/null || echo "$e" >> "$gi"; done
}

# ── 5. 가상환경 + 설치 ─────────────────────────────────────────────────────
install_searxng() {
    step "가상환경 및 설치 (Python ${PY_VERSION})"

    if [[ -x "$VENV/bin/python" ]]; then
        local cur; cur=$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        [[ "$cur" == "$PY_VERSION" ]] || { warn "Python ${cur} → ${PY_VERSION} 재생성"; rm -rf "$VENV"; }
    fi
    [[ -d "$VENV" ]] || uv venv --python "$PY_VERSION" "$VENV"
    ok "venv: $VENV ($("$VENV/bin/python" --version))"

    info "의존성 설치 중..."
    uv pip install --python "$VENV/bin/python" -r "$SRC/requirements.txt"

    # SearXNG 자체 (setup.py, pyproject 없음 → 빌드 격리 끄고 editable)
    if ! uv pip install --python "$VENV/bin/python" --no-build-isolation -e "$SRC" 2>/dev/null; then
        warn "editable 설치 실패 — PYTHONPATH 방식으로 전환한다"
        USE_PYTHONPATH=true
    fi

    "$VENV/bin/python" -c "import searx" 2>/dev/null \
        || PYTHONPATH="$SRC" "$VENV/bin/python" -c "import searx" 2>/dev/null \
        || error "searx 모듈을 import 할 수 없다"
    ok "SearXNG 설치 완료"
}

# ── 6. settings.yml ────────────────────────────────────────────────────────
write_settings() {
    step "settings.yml"

    mkdir -p "$SX_HOME" "$LOG_DIR"

    if [[ -f "$SETTINGS" ]]; then
        ok "기존 설정 유지 — 건드리지 않는다: $SETTINGS"
        info "  포트·바인딩을 바꾸려면 이 파일을 직접 고쳐라"
        return
    fi

    local secret
    secret=$("$VENV/bin/python" -c 'import secrets; print(secrets.token_hex(32))')

    cat > "$SETTINGS" <<YAMLEOF
# =============================================================================
# SearXNG 설정  —  searxng-install.sh 가 최초 1회만 생성한다.
# 이후 재실행해도 이 파일은 덮어쓰지 않는다. 마음껏 고쳐도 된다.
#
# use_default_settings: true  →  업스트림 기본 settings.yml 을 전부 상속하고
#                                아래에 쓴 것만 덮어쓴다. 엔진 목록·UI 설정 등은
#                                SearXNG 가 업데이트되면 자동으로 따라간다.
# =============================================================================
use_default_settings: true

server:
  # 없으면 SearXNG 가 기동을 거부한다
  secret_key: "${secret}"

  # 로컬 전용. 외부에 열려면 여기와 방화벽을 함께 손봐야 한다.
  bind_address: "${SX_HOST}"

  # 기본값 8080 은 Open WebUI 가 쓰고 있어 충돌한다
  port: ${SX_PORT}

  # SearXNG 의 봇 차단(limiter)은 Open WebUI 가 자신을
  # "Open WebUI ... RAG Bot" 이라고 밝히는 요청을 막는다.
  # 개인 인스턴스라 끈다. (켜면 valkey/redis 도 필요해진다)
  limiter: false

  image_proxy: true

search:
  # ★ 이것이 없으면 Open WebUI 의 검색이 전부 빈 결과로 돌아온다.
  #   Open WebUI 는 format=json 으로 질의하는데(retrieval/web/searxng.py),
  #   stock SearXNG 는 html 만 내준다.
  formats:
    - html
    - json
YAMLEOF

    chmod 600 "$SETTINGS"
    ok "생성: $SETTINGS"
}

# ── 7. 기동 파라미터 ───────────────────────────────────────────────────────
write_launch_params() {
    step "기동 파라미터"

    cat > "$ENV_FILE" <<ENVEOF
# SearXNG 기동 파라미터 — searxng-run.sh 가 읽는다.
# 검색 동작 설정은 여기가 아니라 settings.yml 에 있다.
SEARXNG_VENV="${VENV}"
SEARXNG_SRC="${SRC}"
SEARXNG_HOME="${SX_HOME}"
SEARXNG_SETTINGS_PATH="${SETTINGS}"
ENVEOF
    chmod 600 "$ENV_FILE"
    ok "$ENV_FILE"

    [[ -e "$SCRIPT_DIR/.searxng" ]] || ln -s "$SX_HOME" "$SCRIPT_DIR/.searxng"
}

# ── 8. 검증 ────────────────────────────────────────────────────────────────
# 기동만 보는 게 아니라 **실제로 JSON 검색이 되는지**까지 본다.
# formats 설정을 빠뜨리면 여기서 잡힌다.
smoke_test() {
    [[ "$DO_SMOKE" == true ]] || { warn "--no-smoke 지정 — 건너뜀"; return 0; }
    step "검색 검증"

    local log="$LOG_DIR/install-smoke.log"
    local port; port=$(awk '/^  port:/{print $2}' "$SETTINGS")
    local host; host=$(awk -F'"' '/^  bind_address:/{print $2}' "$SETTINGS")
    [[ "$host" == "0.0.0.0" ]] && host="127.0.0.1"

    info "SearXNG 기동 중..."
    SEARXNG_SETTINGS_PATH="$SETTINGS" PYTHONPATH="$SRC" \
        "$VENV/bin/python" -m searx.webapp < /dev/null > "$log" 2>&1 &
    local pid=$!

    local i ready=false
    for i in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || { warn "프로세스가 죽었다:"; tail -20 "$log"; error "기동 실패"; }
        if curl -sf --max-time 3 "http://${host}:${port}/" &>/dev/null; then ready=true; break; fi
        sleep 1
    done
    [[ "$ready" == true ]] || { kill "$pid" 2>/dev/null; tail -20 "$log"; error "60초 안에 응답 없음"; }
    ok "기동 확인 (${i}초)"

    info "JSON 검색 시도 중..."
    local n
    n=$(curl -sf --max-time 25 "http://${host}:${port}/search?q=open+webui&format=json" \
        | "$VENV/bin/python" -c 'import json,sys; print(len(json.load(sys.stdin).get("results",[])))' 2>/dev/null || echo 0)

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    if [[ "$n" -gt 0 ]]; then
        ok "JSON 검색 정상 — 결과 ${n}건"
    else
        warn "JSON 검색이 0건이다. 원인 후보:"
        warn "  · settings.yml 의 search.formats 에 json 이 없다"
        warn "  · 업스트림 엔진이 일시 차단됐다 (잠시 후 재시도)"
        warn "  · 이 박스에서 외부 인터넷이 막혀 있다"
        warn "  로그: $log"
    fi
}

# ── 9. systemd (선택) ──────────────────────────────────────────────────────
install_service() {
    [[ "$DO_SERVICE" == true ]] || return 0
    step "systemd 사용자 서비스"

    local unit_dir="$HOME/.config/systemd/user"; mkdir -p "$unit_dir"
    cat > "$unit_dir/searxng.service" <<SVCEOF
[Unit]
Description=SearXNG (local metasearch for Open WebUI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${SX_HOME}
Environment=SEARXNG_SETTINGS_PATH=${SETTINGS}
Environment=PYTHONPATH=${SRC}
ExecStart=${VENV}/bin/python -m searx.webapp
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

    if ! systemctl --user daemon-reload 2>/dev/null; then
        warn "systemd 사용자 세션 없음 — 유닛 파일만 남긴다: $unit_dir/searxng.service"
        return 0
    fi
    systemctl --user enable searxng.service
    ok "등록 완료: systemctl --user start searxng"
}

# ── 10. 요약 ───────────────────────────────────────────────────────────────
print_summary() {
    step "설치 완료"
    local port; port=$(awk '/^  port:/{print $2}' "$SETTINGS")

    echo
    echo -e "  ${BOLD}설치 위치${NC}"
    echo "  venv     : $VENV"
    echo "  소스     : $SRC"
    echo "  설정     : $SETTINGS   ← 검색 동작은 전부 여기"
    echo
    echo -e "  ${BOLD}실행${NC}"
    echo "  ./searxng-run.sh start | stop | status | logs | update"
    echo
    echo -e "  ${BOLD}Open WebUI 에 붙이기${NC}"
    echo "  관리자 패널 > 웹 검색"
    echo "    웹 검색            : 켜기"
    echo "    웹 검색 엔진       : searxng"
    echo "    Searxng 쿼리 URL   : http://127.0.0.1:${port}/search?q=<query>"
    echo "    Searxng 검색 언어  : ko  (한국어 결과를 원하면. 기본 all)"
    echo
    echo "  ※ 검색 엔진 목록·필터는 ${SETTINGS} 에서 조정한다"
    echo
}

main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   SearXNG 설치 스크립트                    ${NC}"
    echo -e "${BOLD}   Docker 없이 | uv venv | 로컬 전용        ${NC}"
    echo -e "${BOLD}============================================${NC}"

    check_prerequisites
    install_uv
    install_system_deps
    fetch_source
    install_searxng
    write_settings
    write_launch_params
    smoke_test
    install_service
    print_summary
}

main "$@"
