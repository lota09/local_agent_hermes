#!/usr/bin/env bash
# =============================================================================
# OpenClaw 설치 스크립트
# 대상: Ubuntu (비루트 사용자 가능, 일부 단계는 sudo 필요)
# LLM 백엔드: OpenAI API 호환 엔드포인트 지원
# 공식 문서: https://docs.openclaw.ai/start/getting-started
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"

# ── 1. Node.js 확인 및 설치 ────────────────────────────────────────────────
check_node() {
    step "Node.js 확인"

    # OpenClaw 공식 요구사항: Node 24 권장, 22.19+ 지원
    _node_ok() {
        command -v node &>/dev/null || return 1
        local major
        major=$(node --version | sed 's/v//' | cut -d. -f1)
        local minor
        minor=$(node --version | sed 's/v//' | cut -d. -f2)
        [[ "$major" -ge 24 ]] && return 0
        [[ "$major" -eq 22 ]] && [[ "$minor" -ge 19 ]] && return 0
        return 1
    }

    if _node_ok; then
        ok "Node.js $(node --version) — 요구사항 충족"
        return
    fi

    # 현재 버전이 낮거나 없음 → 설치/업그레이드
    if command -v node &>/dev/null; then
        warn "Node.js $(node --version) — Node 24 이상 필요"
    else
        warn "Node.js 없음"
    fi

    # nvm이 있으면 루트 없이 설치 (가장 깔끔한 방법)
    if command -v nvm &>/dev/null || [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        info "nvm으로 Node.js 24 설치 중..."
        # shellcheck disable=SC1090
        [[ -s "$HOME/.nvm/nvm.sh" ]] && source "$HOME/.nvm/nvm.sh"
        nvm install 24
        nvm use 24
        nvm alias default 24
        ok "Node.js $(node --version) 설치 완료 (nvm)"
        return
    fi

    # NodeSource 공식 저장소로 설치 (sudo 필요)
    if sudo -n true 2>/dev/null; then
        info "NodeSource로 Node.js 24 설치 중 (sudo)..."
        curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
        sudo apt-get install -y -qq nodejs
        ok "Node.js $(node --version) 설치 완료"
        return
    fi

    # fnm (루트 불필요, nvm보다 빠름)
    if command -v fnm &>/dev/null; then
        info "fnm으로 Node.js 24 설치 중..."
        fnm install 24
        fnm use 24
        fnm default 24
        ok "Node.js $(node --version) 설치 완료 (fnm)"
        return
    fi

    # fnm 자동 설치 후 Node.js 설치
    info "fnm 설치 중 (루트 불필요)..."
    curl -fsSL https://fnm.vercel.app/install | bash
    export PATH="$HOME/.local/share/fnm:$PATH"
    eval "$(fnm env)"
    fnm install 24
    fnm use 24
    fnm default 24

    # ~/.bashrc에 fnm 초기화 추가
    if ! grep -q 'fnm env' "$HOME/.bashrc" 2>/dev/null; then
        {
            echo ''
            echo '# fnm (Node.js version manager)'
            echo 'export PATH="$HOME/.local/share/fnm:$PATH"'
            echo 'eval "$(fnm env)"'
        } >> "$HOME/.bashrc"
    fi

    _node_ok || error "Node.js 설치 실패. 위 오류를 확인하세요."
    ok "Node.js $(node --version) 설치 완료 (fnm)"
}

# ── 2. OpenClaw 설치 ───────────────────────────────────────────────────────
install_openclaw() {
    step "OpenClaw 설치"

    if command -v openclaw &>/dev/null; then
        local current_ver
        current_ver=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")
        warn "이미 설치된 OpenClaw 발견 (${current_ver})"
        read -rp "최신 버전으로 업데이트하시겠습니까? [y/N]: " UPDATE
        if [[ "${UPDATE,,}" == "y" ]]; then
            info "OpenClaw 업데이트 중..."
            npm install -g openclaw@latest
            ok "OpenClaw $(openclaw --version 2>/dev/null | head -1) 업데이트 완료"
        else
            ok "기존 버전 유지"
        fi
        return
    fi

    info "OpenClaw 공식 설치 스크립트 실행 중..."
    info "  → npm global 설치, ~/.openclaw 디렉터리 생성"
    curl -fsSL https://openclaw.ai/install.sh | bash \
        || {
            warn "공식 설치 스크립트 실패 — npm global install 시도"
            npm install -g openclaw@latest
        }

    # PATH 갱신 (설치 스크립트가 추가했을 수 있음)
    export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

    command -v openclaw &>/dev/null \
        || error "openclaw 바이너리를 찾을 수 없습니다. 위 오류를 확인하세요."

    ok "OpenClaw $(openclaw --version 2>/dev/null | head -1) 설치 완료"
}

# ── 3. LLM 백엔드 사전 설정 안내 ──────────────────────────────────────────
configure_llm_hint() {
    step "LLM 백엔드 설정 안내"

    echo
    echo "  OpenClaw onboard 마법사가 LLM 설정을 안내합니다."
    echo "  로컬 LLM(llama.cpp 등 OpenAI 호환 서버)을 사용하려면"
    echo "  마법사에서 'Custom / OpenAI-compatible' 옵션을 선택하세요."
    echo
    echo "  ─ 현재 LLM 서버 상태 확인 ─────────────────────────────"

    # 알려진 로컬 LLM 포트 자동 감지
    local detected_url=""
    for port in 11436 8080 11434 1234 8000; do
        if curl -sf --max-time 2 "http://localhost:${port}/v1/models" &>/dev/null; then
            detected_url="http://localhost:${port}/v1"
            ok "로컬 LLM 서버 감지됨: ${detected_url}"
            # 모델 목록 출력
            curl -sf "http://localhost:${port}/v1/models" \
                | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for m in d.get('data',[])[:5]: print(f'    - {m.get(\"id\",\"?\")}')
except: pass
" 2>/dev/null || true
            break
        fi
    done

    if [[ -z "$detected_url" ]]; then
        warn "실행 중인 로컬 LLM 서버를 찾지 못했습니다."
        warn "onboard 전에 llama.cpp 등을 먼저 시작하거나"
        warn "클라우드 API 키(Anthropic/OpenAI/Google)를 준비하세요."
    fi

    echo
    info "마법사에서 묻는 항목:"
    info "  1) 모델 프로바이더 → 'Custom' 또는 'OpenAI-compatible'"
    info "  2) Base URL       → ${detected_url:-http://localhost:11436/v1}"
    info "  3) API Key        → 로컬 서버는 아무 값이나 (예: local)"
    info "  4) 채널 설정      → Discord/Telegram 등 (선택사항)"
    echo
    read -rp "계속해서 onboard 마법사를 실행하시겠습니까? [Y/n]: " CONT
    [[ "${CONT,,}" != "n" ]] || { info "취소됨. 나중에: openclaw onboard --install-daemon"; exit 0; }
}

# ── 4. onboard 마법사 실행 ─────────────────────────────────────────────────
run_onboard() {
    step "OpenClaw onboard 마법사"

    info "마법사가 다음을 안내합니다:"
    info "  - LLM 프로바이더 및 API 키 설정"
    info "  - Gateway 데몬 설치 (systemd user service)"
    info "  - 채널 연결 (Discord, Telegram 등 — 선택사항)"
    echo
    info "완료 후 'openclaw gateway status'로 확인하세요."
    echo

    # --install-daemon: systemd user service 자동 등록
    openclaw onboard --install-daemon \
        || error "onboard 마법사 실패. 수동 실행: openclaw onboard --install-daemon"
}

# ── 5. PATH 영구 설정 및 바이너리 등록 ────────────────────────────────────
setup_path() {
    step "PATH 설정 및 바이너리 등록"

    # onboard 후 PATH가 갱신되지 않은 경우를 위해 가능한 경로를 모두 탐색
    local openclaw_bin=""
    for candidate in \
        "$(command -v openclaw 2>/dev/null)" \
        "$HOME/.local/bin/openclaw" \
        "$HOME/.npm-global/bin/openclaw" \
        "$HOME/.local/share/openclaw/bin/openclaw" \
        "$(npm config get prefix 2>/dev/null)/bin/openclaw" \
        "$(find "$HOME" -maxdepth 6 -name openclaw -type f -executable 2>/dev/null | grep -v node_modules | head -1)"
    do
        [[ -n "$candidate" ]] && [[ -x "$candidate" ]] && { openclaw_bin="$candidate"; break; }
    done

    if [[ -z "$openclaw_bin" ]]; then
        warn "openclaw 바이너리를 찾을 수 없습니다."
        warn "npm 글로벌 경로에서 재시도..."
        # npm link로 강제 등록 시도
        npm install -g openclaw@latest 2>/dev/null || true
        openclaw_bin="$(npm config get prefix 2>/dev/null)/bin/openclaw"
    fi

    if [[ -x "$openclaw_bin" ]]; then
        ok "openclaw 위치 확인: $openclaw_bin"

        # ~/.local/bin에 심볼릭 링크 생성 (가장 안정적인 PATH 등록 방법)
        mkdir -p "$HOME/.local/bin"
        if [[ "$openclaw_bin" != "$HOME/.local/bin/openclaw" ]]; then
            ln -sf "$openclaw_bin" "$HOME/.local/bin/openclaw"
            ok "심볼릭 링크 생성: ~/.local/bin/openclaw → $openclaw_bin"
        fi

        # ~/.local/bin이 PATH에 없으면 ~/.bashrc에 추가
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
            export PATH="$HOME/.local/bin:$PATH"
            ok "PATH 추가됨: ~/.local/bin"
        else
            ok "PATH 이미 설정됨"
        fi
    else
        warn "openclaw 바이너리 등록 실패. 다음 명령으로 수동 확인:"
        warn "  npm list -g openclaw"
        warn "  npm config get prefix"
    fi
}

# ── 6. 완료 요약 ───────────────────────────────────────────────────────────
print_summary() {
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        OpenClaw 설치 완료!               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
    echo "  ─ 서비스 관리 ──────────────────────────────────────"
    echo "  ./openclaw-run.sh start    # Gateway 시작"
    echo "  ./openclaw-run.sh stop     # Gateway 정지"
    echo "  ./openclaw-run.sh status   # 상태 확인"
    echo "  ./openclaw-run.sh logs     # 실시간 로그"
    echo "  ./openclaw-run.sh ui       # 웹 대시보드 열기"
    echo "  ./openclaw-run.sh update   # 최신 버전 업데이트"
    echo
    echo "  ─ 직접 명령어 ───────────────────────────────────────"
    echo "  openclaw gateway status    # Gateway 상태"
    echo "  openclaw dashboard         # 웹 UI 열기 (포트 18789)"
    echo "  openclaw doctor            # 환경 진단"
    echo "  openclaw agent -m '안녕'   # 터미널에서 직접 대화"
    echo
    echo "  ─ 채널 추가 (나중에) ─────────────────────────────────"
    echo "  openclaw onboard           # 마법사 재실행"
    echo "  https://docs.openclaw.ai/channels"
    echo
    echo "  ─ 새 터미널에서 바로 사용하려면 ────────────────────"
    echo "  source ~/.bashrc"
    echo
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   OpenClaw 설치 스크립트                  ${NC}"
    echo -e "${BOLD}   Ubuntu | OpenAI 호환 LLM 지원           ${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo

    check_node
    install_openclaw
    configure_llm_hint
    run_onboard
    setup_path
    print_summary
}

main "$@"
