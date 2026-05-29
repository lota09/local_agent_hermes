#!/usr/bin/env bash
# =============================================================================
# Hermes Agent 설치 스크립트
# 대상: Ubuntu, 비루트(non-root) 사용자
# LLM 백엔드: OpenAI API 호환 엔드포인트 전부 지원
#   (llama.cpp / Ollama / LM Studio / vLLM / Jan.ai 등)
# =============================================================================

set -euo pipefail

# ── 색상 출력 ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }

# ── 1. 사전 조건 확인 ──────────────────────────────────────────────────────
check_prerequisites() {
    step "사전 조건 확인"

    # git 필수
    command -v git &>/dev/null || error "git 없음. 관리자에게 'sudo apt install git' 요청하세요."
    ok "git $(git --version | awk '{print $3}')"

    # python3 확인 (스크립트 내 파싱용)
    command -v python3 &>/dev/null || error "python3 없음. 관리자에게 'sudo apt install python3' 요청하세요."
    ok "python3 $(python3 --version | awk '{print $2}')"

    ok "사전 조건 확인 완료"
    info "LLM 서버는 4단계에서 설정합니다 (llama.cpp / Ollama / 기타 모두 가능)"
}

# ── 2. Hermes Agent 설치 ───────────────────────────────────────────────────
install_hermes() {
    step "Hermes Agent 설치"

    if command -v hermes &>/dev/null || [[ -f "$HOME/.local/bin/hermes" ]]; then
        warn "이미 설치된 Hermes 발견"
        read -rp "재설치(업데이트)하시겠습니까? [y/N]: " REINSTALL
        [[ "${REINSTALL,,}" != "y" ]] && { ok "설치 건너뜀"; return; }
    fi

    info "공식 설치 스크립트 실행 중..."
    info "  --skip-browser: Chromium 시스템 라이브러리(apt) 설치 건너뜀 → 루트 불필요"
    info "  Python 3.11 / Node.js 22 / ripgrep / ffmpeg 는 자동 설치됨 (~/.hermes/ 아래)"

    curl -fsSL \
        https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
        | bash -s -- --skip-browser

    ok "Hermes Agent 설치 완료"
}

# ── 3. PATH 설정 ───────────────────────────────────────────────────────────
setup_path() {
    step "PATH 설정"

    # ~/.local/bin 이 없으면 추가
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        info "~/.local/bin → PATH 추가"
        {
            echo ''
            echo '# Hermes Agent'
            echo 'export PATH="$HOME/.local/bin:$PATH"'
        } >> ~/.bashrc
        export PATH="$HOME/.local/bin:$PATH"
        ok "~/.bashrc 업데이트 완료"
    else
        ok "PATH 이미 설정됨"
    fi

    # hermes 명령 최종 확인
    HERMES_BIN="$(command -v hermes 2>/dev/null || echo "$HOME/.local/bin/hermes")"
    [[ -f "$HERMES_BIN" ]] || error "hermes 바이너리를 찾을 수 없습니다. 설치를 확인하세요."
    ok "hermes 위치: $HERMES_BIN"
}

# ── 4. LLM 프로바이더 설정 (OpenAI 호환 엔드포인트 범용) ─────────────────
configure_llm() {
    step "LLM 프로바이더 설정"

    echo "  지원 백엔드 (OpenAI API 호환이면 전부 동작):"
    echo
    echo "  1) llama.cpp   기본 포트 8080  → http://localhost:8080/v1"
    echo "  2) Ollama      기본 포트 11434 → http://localhost:11434/v1"
    echo "  3) LM Studio   기본 포트 1234  → http://localhost:1234/v1"
    echo "  4) vLLM        기본 포트 8000  → http://localhost:8000/v1"
    echo "  5) Jan.ai      기본 포트 1337  → http://localhost:1337/v1"
    echo "  6) 직접 입력"
    echo

    read -rp "백엔드 선택 [1-6] (기본값 1, llama.cpp): " BACKEND_CHOICE
    BACKEND_CHOICE="${BACKEND_CHOICE:-1}"

    case "$BACKEND_CHOICE" in
        1) DEFAULT_URL="http://localhost:8080/v1";  DEFAULT_KEY="none" ;;
        2) DEFAULT_URL="http://localhost:11434/v1"; DEFAULT_KEY="ollama" ;;
        3) DEFAULT_URL="http://localhost:1234/v1";  DEFAULT_KEY="lm-studio" ;;
        4) DEFAULT_URL="http://localhost:8000/v1";  DEFAULT_KEY="none" ;;
        5) DEFAULT_URL="http://localhost:1337/v1";  DEFAULT_KEY="jan" ;;
        *) DEFAULT_URL=""; DEFAULT_KEY="none" ;;
    esac

    echo
    read -rp "API Base URL [기본: ${DEFAULT_URL:-직접입력}]: " API_BASE_URL
    API_BASE_URL="${API_BASE_URL:-$DEFAULT_URL}"
    [[ -n "$API_BASE_URL" ]] || error "API Base URL을 입력해야 합니다."

    read -rp "API Key [기본: ${DEFAULT_KEY}] (로컬 서버는 아무 값이나 가능): " API_KEY
    API_KEY="${API_KEY:-$DEFAULT_KEY}"

    # 연결 테스트 (OpenAI 표준 /v1/models 엔드포인트)
    echo
    info "연결 테스트 중: ${API_BASE_URL}/models"
    if curl -sf -H "Authorization: Bearer ${API_KEY}" \
            "${API_BASE_URL}/models" &>/dev/null; then
        ok "LLM 서버 응답 확인"

        # 모델 목록 출력 (OpenAI 표준 형식)
        MODEL_LIST=$(curl -sf -H "Authorization: Bearer ${API_KEY}" \
            "${API_BASE_URL}/models" \
            | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    models = [m.get('id','?') for m in data.get('data', [])]
    for m in models[:10]: print(f'    - {m}')
    if len(models) > 10: print(f'    ... 외 {len(models)-10}개')
except: pass
" 2>/dev/null || echo "")
        if [[ -n "$MODEL_LIST" ]]; then
            info "사용 가능한 모델:"
            echo "$MODEL_LIST"
        fi
    else
        warn "LLM 서버에 연결할 수 없습니다."
        warn "Hermes 실행 전에 LLM 서버를 먼저 시작하세요."
        warn "예) llama.cpp: llama-server -m model.gguf --port 8080"
    fi

    echo
    read -rp "사용할 모델명 입력 (예: llama-3.2, gemma-4-e4b, qwen3.6): " MODEL_NAME
    MODEL_NAME="${MODEL_NAME:-default}"

    # Hermes 설정 저장
    "$HERMES_BIN" config set OPENAI_BASE_URL "$API_BASE_URL"
    "$HERMES_BIN" config set OPENAI_API_KEY  "$API_KEY"
    "$HERMES_BIN" config set model           "$MODEL_NAME"

    # 설정 파일에 LLM 정보 기록 (run.sh의 상태 확인용)
    mkdir -p "$HOME/.hermes"
    cat > "$HOME/.hermes/llm-backend.env" <<EOF
LLM_BASE_URL="${API_BASE_URL}"
LLM_API_KEY="${API_KEY}"
LLM_MODEL="${MODEL_NAME}"
EOF

    ok "LLM 설정 완료: ${MODEL_NAME} @ ${API_BASE_URL}"
    info "나중에 모델 변경: hermes model"
}

# ── 5. 웹 검색 설정 ────────────────────────────────────────────────────────
configure_web_search() {
    step "웹 검색 설정 (선택사항)"

    echo
    echo "  웹 검색을 사용하려면 API 키가 필요합니다 (무료 티어 있음):"
    echo
    echo "  [권장] Tavily   : https://app.tavily.com       (월 1,000회 무료)"
    echo "         Firecrawl: https://firecrawl.dev         (500 크레딧 무료)"
    echo "         Exa      : https://exa.ai               (무료 티어 있음)"
    echo
    read -rp "Tavily API 키 (없으면 Enter로 건너뜀): " TAVILY_KEY
    echo

    if [[ -n "$TAVILY_KEY" ]]; then
        "$HERMES_BIN" config set TAVILY_API_KEY "$TAVILY_KEY"
        # config.yaml에 backend 설정
        python3 - "$HOME/.hermes/config.yaml" <<'PYEOF'
import sys, yaml, pathlib
cfg_path = pathlib.Path(sys.argv[1])
cfg = yaml.safe_load(cfg_path.read_text()) if cfg_path.exists() else {}
cfg.setdefault('web', {})['backend'] = 'tavily'
cfg_path.write_text(yaml.dump(cfg, allow_unicode=True, default_flow_style=False))
print("  web.backend = tavily 설정 완료")
PYEOF
        ok "Tavily 웹 검색 활성화"
    else
        warn "웹 검색 API 미설정 → 나중에: hermes config set TAVILY_API_KEY <키>"
    fi
}

# ── 6. Discord 봇 설정 ─────────────────────────────────────────────────────
configure_discord() {
    step "Discord 봇 설정"

    echo
    echo "  ─ Discord 봇 토큰 발급 방법 ─────────────────────────────"
    echo "  1. https://discord.com/developers/applications 접속"
    echo "  2. [New Application] → 이름 입력 (예: MyHermes)"
    echo "  3. 왼쪽 메뉴 [Bot] → [Add Bot]"
    echo "  4. [Reset Token] → 토큰 복사 (한 번만 표시됨!)"
    echo "  5. 아래 항목 ON:"
    echo "       ✓ MESSAGE CONTENT INTENT"
    echo "       ✓ SERVER MEMBERS INTENT (선택)"
    echo "  6. 왼쪽 [OAuth2] → [URL Generator]"
    echo "       Scopes: bot, applications.commands"
    echo "       Bot Permissions: Send Messages, Read Messages/View Channels"
    echo "     → 생성된 URL로 본인 서버에 봇 초대"
    echo
    echo "  ─ 내 Discord 사용자 ID 확인 ─────────────────────────────"
    echo "  Discord 앱 → 설정 → 고급 → 개발자 모드 ON"
    echo "  내 프로필 우클릭 → [사용자 ID 복사]"
    echo "  ─────────────────────────────────────────────────────────"
    echo

    read -rp "Discord 봇 토큰 (없으면 Enter로 건너뜀): " DISCORD_TOKEN
    echo

    if [[ -n "$DISCORD_TOKEN" ]]; then
        read -rp "내 Discord 사용자 ID (허용할 계정): " DISCORD_USER_ID
        echo

        "$HERMES_BIN" config set DISCORD_BOT_TOKEN "$DISCORD_TOKEN"

        if [[ -n "$DISCORD_USER_ID" ]]; then
            "$HERMES_BIN" config set DISCORD_ALLOWED_USERS "$DISCORD_USER_ID"
            ok "Discord 설정 완료 (허용 사용자: $DISCORD_USER_ID)"
        else
            warn "사용자 ID 미입력. 봇이 모든 DM을 허용합니다."
            warn "보안을 위해 나중에 반드시 설정:"
            warn "  hermes config set DISCORD_ALLOWED_USERS <내_ID>"
        fi
    else
        warn "Discord 설정 건너뜀 → 나중에: hermes gateway setup"
    fi
}

# ── 7. Open WebUI 설치 (선택) ──────────────────────────────────────────────
install_open_webui() {
    step "Open WebUI 설치 (선택사항)"

    echo
    echo "  Open WebUI: 스마트폰 브라우저로 http://서버IP:8080 접속 가능"
    echo "  Hermes API 서버에 연결해서 사용하는 웹 채팅 UI입니다"
    echo "  ※ open-webui는 Python 3.11 또는 3.12 전용 패키지입니다"
    echo
    read -rp "Open WebUI도 설치하시겠습니까? [y/N]: " INSTALL_WEBUI
    [[ "${INSTALL_WEBUI,,}" == "y" ]] || {
        info "건너뜀 (나중에 install.sh 재실행으로 추가 가능)"
        return
    }

    # open-webui는 Python 3.11 또는 3.12 전용
    # 현재 Python 버전 확인
    PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
    PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)

    WEBUI_VENV="$HOME/.venv/open-webui"
    WEBUI_BIN="${WEBUI_VENV}/bin/open-webui"

    if [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -ge 11 ]] && [[ "$PY_MINOR" -le 12 ]]; then
        # ── 현재 Python이 호환 → 그냥 venv 생성 후 설치 ─────────────────────
        ok "Python ${PY_VER} 호환됨"
        info "가상환경 생성 및 open-webui 설치 중..."
        python3 -m venv "$WEBUI_VENV"
        "${WEBUI_VENV}/bin/pip" install --quiet --upgrade pip
        "${WEBUI_VENV}/bin/pip" install --quiet open-webui

    elif command -v uv &>/dev/null; then
        # ── uv 있음 (Hermes 설치 시 자동으로 깔림) → Python 3.11 venv 생성 ──
        warn "현재 Python ${PY_VER} — open-webui는 3.11/3.12 필요"
        info "uv로 Python 3.11 가상환경 생성 중... (${WEBUI_VENV})"
        uv venv "$WEBUI_VENV" --python 3.11
        uv pip install --quiet --python "$WEBUI_VENV" open-webui

    elif command -v conda &>/dev/null; then
        # ── conda 있음 → conda run으로 안전하게 설치 ─────────────────────────
        warn "현재 Python ${PY_VER} — open-webui는 3.11/3.12 필요"
        info "Conda 전용 환경(open-webui) 생성 중..."
        conda create -n open-webui python=3.11 -y -q

        # conda run: activate 없이 지정 환경에서 직접 실행 (비대화형 셸에서 안전)
        conda run -n open-webui pip install --quiet open-webui

        CONDA_BASE=$(conda info --base)
        WEBUI_BIN="${CONDA_BASE}/envs/open-webui/bin/open-webui"
        info "설치 경로: ${WEBUI_BIN}"

    else
        # ── 호환 Python 확보 불가 → 수동 안내 후 종료 ───────────────────────
        warn "현재 Python ${PY_VER} — open-webui 설치 불가 (3.11/3.12 필요)"
        warn "uv / conda 도 없습니다. 아래 방법 중 하나를 선택하세요:"
        echo
        echo "  [방법 A] uv로 설치 (권장, 루트 불필요):"
        echo "    curl -LsSf https://astral.sh/uv/install.sh | sh"
        echo "    uv venv ~/.venv/open-webui --python 3.11"
        echo "    uv pip install --python ~/.venv/open-webui open-webui"
        echo "    ~/.venv/open-webui/bin/open-webui serve --host 0.0.0.0 --port 8080"
        echo
        echo "  [방법 B] conda 환경 사용:"
        echo "    conda create -n open-webui python=3.11 -y"
        echo "    conda run -n open-webui pip install open-webui"
        echo "    conda run -n open-webui open-webui serve --host 0.0.0.0 --port 8080"
        echo
        echo "  [방법 C] Docker (rootless Podman):"
        echo "    podman run -d --name open-webui -p 8080:8080 \\"
        echo "      -e OPENAI_API_BASE_URL=http://host-gateway:11435/v1 \\"
        echo "      -e OPENAI_API_KEY=hermes \\"
        echo "      --add-host=host-gateway:host-gateway \\"
        echo "      ghcr.io/open-webui/open-webui:main"
        return
    fi

    # ── 실행 래퍼 스크립트 생성 ─────────────────────────────────────────────
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/webui-start" <<WEOF
#!/usr/bin/env bash
# Open WebUI 시작 래퍼 (자동 생성)
# Hermes API 서버(포트 11435)에 연결

export WEBUI_AUTH=False
export OPENAI_API_BASE_URL="http://localhost:11435/v1"
export OPENAI_API_KEY="hermes"

WEBUI_BIN="${WEBUI_BIN}"

if [[ ! -x "\$WEBUI_BIN" ]]; then
    echo "[ERROR] open-webui 바이너리를 찾을 수 없습니다: \$WEBUI_BIN"
    echo "        install.sh 를 재실행해 Open WebUI를 다시 설치하세요."
    exit 1
fi

LOCAL_IP=\$(hostname -I 2>/dev/null | awk '{print \$1}' || echo "localhost")
echo "[INFO] Open WebUI 시작 중..."
echo "[INFO] 스마트폰 접속 주소: http://\${LOCAL_IP}:8080"
echo "[INFO] (Hermes API 서버가 포트 11435에서 실행 중이어야 합니다)"
echo

"\$WEBUI_BIN" serve --host 0.0.0.0 --port 8080
WEOF
    chmod +x "$HOME/.local/bin/webui-start"

    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"
    ok "Open WebUI 설치 완료 (${WEBUI_BIN})"
    info "실행 순서:"
    info "  1) ./run.sh webui        ← Hermes API 서버 + Open WebUI 한번에 시작"
    info "     또는 따로 시작:"
    info "  1) hermes api-server --port 11435  &"
    info "  2) webui-start"
    info "스마트폰 접속: http://${LOCAL_IP}:8080"
}

# ── 8. systemd 사용자 서비스 등록 ─────────────────────────────────────────
install_service() {
    step "systemd 사용자 서비스 등록"

    "$HERMES_BIN" gateway install
    ok "hermes-gateway 서비스 등록 완료"

    # loginctl linger: 로그아웃 후에도 서비스 유지 (루트 필요)
    if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
        ok "loginctl linger 활성화 → 로그아웃 후에도 서비스 유지"
    else
        warn "linger 활성화 실패 (sudo 필요)"
        warn "관리자에게 아래 명령어 실행 요청:"
        warn "  sudo loginctl enable-linger $USER"
        warn "미설정 시: SSH 세션 종료되면 서비스도 종료될 수 있음"
    fi
}

# ── 9. 완료 메시지 ─────────────────────────────────────────────────────────
print_summary() {
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        설치 완료!                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
    echo "  ─ 자주 쓰는 명령어 ───────────────────────────"
    echo "  ./run.sh start      # Discord 봇 + 게이트웨이 시작"
    echo "  ./run.sh stop       # 정지"
    echo "  ./run.sh status     # 상태 확인"
    echo "  ./run.sh logs       # 실시간 로그"
    echo "  ./run.sh chat       # 터미널에서 직접 대화"
    echo
    echo "  ─ 설정 변경 ───────────────────────────────────"
    echo "  hermes model                        # 모델 변경"
    echo "  hermes gateway setup                # 메신저 플랫폼 재설정"
    echo "  hermes config set KEY VALUE         # 개별 설정"
    echo
    echo "  ─ 새 터미널에서 바로 사용하려면 ──────────────"
    echo "  source ~/.bashrc"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   Hermes Agent 설치 스크립트              ${NC}"
    echo -e "${BOLD}   Ubuntu | 비루트 사용자 전용             ${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo

    check_prerequisites
    install_hermes
    setup_path
    configure_llm
    configure_web_search
    configure_discord
    install_open_webui
    install_service
    print_summary
}

main "$@"
