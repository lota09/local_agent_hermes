#!/usr/bin/env bash
# =============================================================================
# Open WebUI 설치 스크립트
# 대상: Ubuntu (비루트 사용자 가능, 시스템 패키지 단계만 sudo 사용)
#
# 철학: **설치 과정에 있어서** 사용자는 스크립트 밖에서 아무것도 하지 않는다.
#       설치가 끝난 뒤의 설정은 Open WebUI 자신이 관리자 UI 로 해 준다 —
#       이 스크립트는 거기에 손대지 않는다.
#
#       그래서 이 스크립트가 쓰는 값은 딱 두 종류뿐이다:
#         (1) 배치   : 데이터를 어디에 둘 것인가 (DATA_DIR — UI 에 없는 값)
#         (2) 기동   : 어느 주소·포트로 띄울 것인가 (CLI 인자)
#       LLM 백엔드 주소, 모델 이름, 임베딩·음성·이미지 엔진은 **건드리지 않는다.**
#       전부 관리자 UI 에 있고, 환경마다 다르며, 앱이 DB 에 저장한다.
#
# 근거 (2026-08 확인):
#   - 공식 설치 문서 : https://docs.openwebui.com/getting-started/quick-start/
#   - 시스템 패키지 목록은 공식 Dockerfile 의 apt-get install 줄을 그대로 옮겼다:
#     https://github.com/open-webui/open-webui/blob/main/Dockerfile
#   - PyPI open-webui requires_python = ">=3.11,<3.13"  → 3.12 고정 (3.13+ 불가)
#   - backend/open_webui/__init__.py:13
#         KEY_FILE = Path.cwd() / '.webui_secret_key'
#     → 시크릿 키는 앱이 스스로 만든다. 단 **cwd 기준**이라 기동 디렉터리가
#       흔들리면 매번 새 키가 생겨 로그인 세션이 끊긴다. 그래서 cwd 를 고정한다.
#   - backend/open_webui/config.py:176
#         CACHE_DIR = DATA_DIR / 'cache'
#     → DATA_DIR 하나만 정하면 모델 캐시 위치는 앱이 알아서 따라온다.
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

# ── 설치 파라미터 ──────────────────────────────────────────────────────────
PY_VERSION="3.12"                                  # open-webui 는 3.13 미지원
VENV="${OPENWEBUI_VENV:-$SCRIPT_DIR/.venv}"        # ⛔ vLLM venv 와 반드시 분리
OW_HOME="${OPENWEBUI_HOME:-$HOME/.open-webui}"     # 기동 cwd + 데이터·로그 루트
OW_DATA="$OW_HOME/data"
ENV_FILE="$OW_HOME/openwebui.env"                  # 기동 파라미터만 들어간다
LOG_DIR="$OW_HOME/logs"

OW_HOST="${OPENWEBUI_HOST:-127.0.0.1}"             # 로컬 전용이 기본
OW_PORT="${OPENWEBUI_PORT:-8080}"

# status 표시용 LLM 주소. 기본값 없음 — 추측하지 않는다.
# 지정하지 않으면 탐지만 시도하고, 못 찾으면 빈 값으로 둔다.
LLM_URL="${OPENWEBUI_STATUS_LLM_URL:-}"
LLM_KEY="${OPENWEBUI_STATUS_LLM_KEY:-}"
LLM_PROBE=true                                     # --llm-url 을 주면 탐지 안 함

# 재실행 시 기존 값을 승계하려면 '명령줄로 명시했는가'를 구분해야 한다
OPT_HOST_SET=false; OPT_PORT_SET=false; OPT_DATA_SET=false

GPU_TORCH=false        # 기본은 CPU torch (공식 Docker 기본값과 동일)
TORCH_CUDA=""          # --gpu-torch cu128 처럼 명시할 때만 채워진다
DO_APT=true
DO_PREFETCH=false      # 기본 꺼짐 — 설치가 아니라 런타임 리소스다
DO_SMOKE=true
DO_SERVICE=false

usage() {
    cat <<EOU
사용법: $(basename "$0") [옵션]

  --port N            기동 포트 (기본 ${OW_PORT})
  --host H            기동 바인딩 주소 (기본 ${OW_HOST}, 외부 공개는 0.0.0.0)
  --home PATH         기동 cwd·로그·기동파라미터 위치 (기본 ${OW_HOME})
  --data-dir PATH     데이터 위치 (기본 <home>/data)
  --llm-url URL       run.sh status 에 표시할 LLM 주소 (미지정 시 탐지만 시도)
  --llm-key KEY       위 주소가 인증을 요구할 때의 키 (표시용일 뿐)
  --gpu-torch [cuXXX] CUDA torch 설치 (기본은 CPU — GPU 는 vLLM/ComfyUI 몫)
                      cuXXX 를 생략하면 PyPI 기본 채널을 쓴다 (버전 추측 안 함)
  --prefetch          임베딩·Whisper 모델 미리 받기 (기본 꺼짐, 아래 설명 참고)
  --no-apt            시스템 패키지 설치 건너뜀 (sudo 없는 환경)
  --no-smoke          설치 후 기동 검증 건너뜀
  --service           systemd 사용자 서비스로 등록
  -h, --help          이 도움말

  --prefetch 는 왜 기본이 꺼져 있나:
    Open WebUI 는 임베딩·Whisper 모델을 처음 쓸 때 알아서 받는다. 미리 받아두면
    첫 사용이 매끄럽지만, 받아두는 경로는 DATA_DIR 에 묶인다. 나중에 DATA_DIR 을
    옮기면 그 캐시는 버려진다. 설치의 성공/실패와는 무관하므로 선택으로 뒀다.
EOU
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)        OW_PORT="$2"; OPT_PORT_SET=true; shift 2 ;;
        --home)        OW_HOME="$2"; OW_DATA="$OW_HOME/data"
                       ENV_FILE="$OW_HOME/openwebui.env"; LOG_DIR="$OW_HOME/logs"; shift 2 ;;
        --llm-url)     LLM_URL="$2"; LLM_PROBE=false; shift 2 ;;
        --llm-key)     LLM_KEY="$2"; shift 2 ;;
        --host)        OW_HOST="$2"; OPT_HOST_SET=true; shift 2 ;;
        --data-dir)    OW_DATA="$2"; OPT_DATA_SET=true; shift 2 ;;
        --gpu-torch)   GPU_TORCH=true
                       # CUDA 버전을 안 주면 추측하지 않고 pytorch.org 기본 채널을 쓴다
                       if [[ "${2:-}" =~ ^cu[0-9]+$ ]]; then TORCH_CUDA="$2"; shift; fi
                       shift ;;
        --prefetch)    DO_PREFETCH=true; shift ;;
        --no-apt)      DO_APT=false; shift ;;
        --no-smoke)    DO_SMOKE=false; shift ;;
        --service)     DO_SERVICE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             error "알 수 없는 옵션: $1  (--help 참고)" ;;
    esac
done

# ── 1. 사전 점검 ───────────────────────────────────────────────────────────
check_prerequisites() {
    step "사전 점검"

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        info "OS: ${PRETTY_NAME:-unknown}"
        [[ "${ID:-}" =~ ^(ubuntu|debian)$ ]] || warn "Ubuntu/Debian 이 아니다 — 시스템 패키지 단계는 건너뛴다"
    fi

    command -v curl &>/dev/null || error "curl 이 필요하다: sudo apt install curl"

    # 쓰기 권한 — venv 와 데이터가 서로 다른 곳에 간다. 둘 다 확인한다.
    local venv_parent="$(dirname "$VENV")"
    mkdir -p "$venv_parent" 2>/dev/null || true
    [[ -w "$venv_parent" ]] || error "쓰기 불가: $venv_parent (venv 를 만들 수 없다)"
    mkdir -p "$OW_HOME" 2>/dev/null || error "생성 불가: $OW_HOME"
    [[ -w "$OW_HOME" ]] || error "쓰기 불가: $OW_HOME"

    # 디스크 — venv(약 3GB)와 데이터·캐시가 다른 파일시스템일 수 있다.
    _avail_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
    local venv_fs data_fs venv_gb data_gb
    venv_fs=$(df --output=target "$venv_parent" 2>/dev/null | tail -1)
    data_fs=$(df --output=target "$OW_HOME" 2>/dev/null | tail -1)
    venv_gb=$(_avail_gb "$venv_parent"); data_gb=$(_avail_gb "$OW_HOME")
    if [[ -z "$venv_gb" ]]; then
        warn "디스크 여유를 확인할 수 없다 (GNU df 아님) — 건너뛴다"
    elif [[ "$venv_fs" == "$data_fs" ]]; then
        [[ "$venv_gb" -lt 12 ]] && warn "여유 디스크 ${venv_gb}GB (${venv_fs}) — 12GB 이상 권장" \
                                || ok "여유 디스크 ${venv_gb}GB (${venv_fs})"
    else
        info "venv 와 데이터가 다른 파일시스템이다"
        [[ "$venv_gb" -lt 6 ]] && warn "  venv  ${venv_gb}GB (${venv_fs}) — 6GB 이상 권장" \
                               || ok "  venv  ${venv_gb}GB (${venv_fs})"
        [[ "$data_gb" -lt 6 ]] && warn "  데이터 ${data_gb}GB (${data_fs}) — 6GB 이상 권장" \
                               || ok "  데이터 ${data_gb}GB (${data_fs})"
    fi

    # 이미 떠 있는 것이 '우리 인스턴스'인지 먼저 가린다.
    # 남의 것이면 막아야 하지만, 우리 것이면 설치를 계속할 수 있어야 한다.
    OUR_INSTANCE=false
    if curl -sf --max-time 3 "http://127.0.0.1:${OW_PORT}/health" 2>/dev/null | grep -q 'true'; then
        if [[ -f "$OW_HOME/openwebui.pid" ]] && kill -0 "$(cat "$OW_HOME/openwebui.pid")" 2>/dev/null; then
            OUR_INSTANCE=true
        elif systemctl --user is-active --quiet openwebui.service 2>/dev/null; then
            OUR_INSTANCE=true
        fi
    fi
    if [[ "$OUR_INSTANCE" == true ]]; then
        warn "이미 이 스크립트가 띄운 Open WebUI 가 포트 ${OW_PORT} 에서 돌고 있다"
        warn "  설치는 계속한다. 기동 검증은 건너뛴다 (내리지 않는다)"
        DO_SMOKE=false
        return
    fi

    # 포트 — 우리가 실제로 바인딩할 주소를 기준으로 본다.
    local probe_host="$OW_HOST"
    [[ "$probe_host" == "0.0.0.0" || "$probe_host" == "::" ]] && probe_host="127.0.0.1"
    if command -v ss &>/dev/null; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "^(\[::\]|0\.0\.0\.0|\*|${probe_host//./\\.})[:.]${OW_PORT}$"; then
            error "포트 ${OW_PORT} 가 이미 사용 중이다 (ss 확인). --port 로 다른 포트를 지정하라."
        fi
        ok "포트 ${OW_PORT} 사용 가능 (ss 확인)"
    elif (exec 3<>"/dev/tcp/${probe_host}/${OW_PORT}") 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        error "포트 ${OW_PORT} 에 이미 응답하는 것이 있다. --port 로 다른 포트를 지정하라."
    else
        ok "포트 ${OW_PORT} 사용 가능 (ss 없음 — ${probe_host} 접속 시도로 확인)"
    fi
}

# ── 2. uv ──────────────────────────────────────────────────────────────────
install_uv() {
    step "uv 확인"

    if command -v uv &>/dev/null; then
        ok "uv $(uv --version | awk '{print $2}') — 이미 설치됨"
        return
    fi

    info "uv 설치 중 (astral.sh 공식 설치 스크립트)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv &>/dev/null || error "uv 설치 실패"
    ok "uv $(uv --version | awk '{print $2}') 설치 완료"
}

# ── 3. 시스템 패키지 ───────────────────────────────────────────────────────
# 목록 근거: 공식 Dockerfile 의 apt-get install 줄. 컨테이너를 안 쓰기로 했으니
# 컨테이너가 대신 깔아주던 것을 여기서 깐다.
#   ffmpeg          → 음성 입출력 오디오 디코딩 (계획서 Step 5)
#   libsm6/libxext6 → opencv-python-headless 런타임
#   pandoc          → 문서 RAG 변환
#   build-essential/python3-dev → 휠이 없을 때 소스 빌드 폴백
install_system_deps() {
    step "시스템 패키지"

    if [[ "$DO_APT" == false ]]; then
        warn "--no-apt 지정 — 건너뜀"
        return
    fi
    if ! command -v apt-get &>/dev/null; then
        warn "apt-get 없음 — 건너뜀"
        return
    fi

    local pkgs=(ffmpeg libsm6 libxext6 pandoc build-essential python3-dev
                netcat-openbsd jq zstd git ca-certificates)
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" &>/dev/null || missing+=("$p")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "필요한 시스템 패키지가 모두 설치되어 있다"
        return
    fi

    info "설치 필요: ${missing[*]}"

    if sudo -n true 2>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"
        ok "시스템 패키지 설치 완료"
    elif [[ -t 0 ]]; then
        info "sudo 비밀번호가 필요하다..."
        if sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"; then
            ok "시스템 패키지 설치 완료"
        else
            warn "설치 실패 — 계속 진행한다"
            warn "  ffmpeg 없으면 음성 입출력(계획서 Step 5)이 동작하지 않는다"
        fi
    else
        warn "sudo 불가(비대화 세션) — 건너뜀. 직접 실행하라:"
        warn "  sudo apt install ${missing[*]}"
        warn "  ffmpeg 없으면 음성 입출력(계획서 Step 5)이 동작하지 않는다"
    fi
}

# ── 4. 가상환경 ────────────────────────────────────────────────────────────
create_venv() {
    step "가상환경 생성 (Python ${PY_VERSION})"

    if [[ -d "$VENV" ]]; then
        if [[ -x "$VENV/bin/python" ]]; then
            local cur
            cur=$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            if [[ "$cur" == "$PY_VERSION" ]]; then
                ok "기존 venv 재사용 (Python ${cur})"
                return
            fi
            warn "Python ${cur} → ${PY_VERSION} 로 재생성한다"
        fi
        rm -rf "$VENV"
    fi

    # 시스템 python 이 3.13+ 여도 상관없다 — uv 가 3.12 를 따로 내려받는다.
    uv venv --python "$PY_VERSION" "$VENV"
    ok "venv 생성: $VENV ($("$VENV/bin/python" --version))"

    local gi="$SCRIPT_DIR/.gitignore"
    for e in '.venv/' '.open-webui'; do
        grep -qxF "$e" "$gi" 2>/dev/null || echo "$e" >> "$gi"
    done
}

# ── 5. torch ───────────────────────────────────────────────────────────────
# sentence-transformers 가 torch 를 끌고 온다. 그냥 두면 PyPI 기본값인 CUDA 번들
# (~2.5GB)이 들어온다. GPU 는 vLLM/ComfyUI 몫이므로 CPU 휠로 자리를 먼저 잡는다.
# 공식 Docker 이미지의 기본 동작(USE_CUDA=false)과 동일하다.
install_torch() {
    step "torch 설치"

    if [[ "$GPU_TORCH" == true ]]; then
        if [[ -n "$TORCH_CUDA" ]]; then
            info "CUDA torch 설치 중 (${TORCH_CUDA} 채널)..."
            uv pip install --python "$VENV/bin/python" torch torchvision torchaudio \
                --index-url "https://download.pytorch.org/whl/${TORCH_CUDA}"
        else
            # CUDA 버전을 추측하지 않는다. PyPI 기본 휠(자체 CUDA 런타임 번들)을 쓴다.
            info "CUDA torch 설치 중 (PyPI 기본 채널 — 버전 추측 안 함)..."
            info "  특정 CUDA 를 원하면: --gpu-torch cu128 처럼 지정하라"
            uv pip install --python "$VENV/bin/python" torch torchvision torchaudio
        fi
        warn "GPU 임베딩은 VRAM 을 추가로 먹는다 — 계획서 §2.2 예산 재확인 필요"
    else
        info "CPU torch 설치 중 (GPU 는 vLLM/ComfyUI 몫)..."
        uv pip install --python "$VENV/bin/python" torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/cpu
    fi

    ok "torch $("$VENV/bin/python" -c 'import torch; print(torch.__version__)')"
}

# ── 6. Open WebUI ──────────────────────────────────────────────────────────
ow_version() {
    "$VENV/bin/python" -c \
        "from importlib.metadata import version; print(version('open-webui'))" 2>/dev/null || echo "unknown"
}

install_openwebui() {
    step "Open WebUI 설치"

    info "uv pip install open-webui ... (의존성 119개, 몇 분 걸린다)"
    uv pip install --python "$VENV/bin/python" open-webui

    [[ -x "$VENV/bin/open-webui" ]] || error "open-webui 실행파일이 생기지 않았다"
    ok "Open WebUI $(ow_version) 설치 완료"
}

# ── 7. 기동 파라미터 ───────────────────────────────────────────────────────
# ⚠ 여기 들어가는 것은 '설정'이 아니라 '기동 방법'이다.
#    LLM 백엔드 주소·모델·엔진 종류는 관리자 UI 에 있고 앱이 DB 에 저장한다.
#    환경마다 다른 값이라 스크립트가 미리 박으면 오히려 틀린다.
# status 표시용 LLM 주소를 '추측'하지 않고 '탐지'한다.
# --llm-url 을 주면 탐지 자체를 건너뛴다. 못 찾으면 빈 값으로 둔다.
probe_llm_url() {
    [[ "$LLM_PROBE" == true ]] || { info "LLM 주소: 지정값 사용 — ${LLM_URL}"; return 0; }
    [[ -z "$LLM_URL" ]] || return 0

    local candidates=(
        "http://127.0.0.1:8000/v1"    # vLLM 기본
        "http://127.0.0.1:11434/v1"   # Ollama
        "http://127.0.0.1:1234/v1"    # LM Studio
        "http://127.0.0.1:8080/v1"    # llama.cpp server
    )
    local c
    for c in "${candidates[@]}"; do
        [[ "$c" == "http://127.0.0.1:${OW_PORT}/v1" ]] && continue   # 우리 포트는 제외
        if curl -sf --max-time 2 "${c}/models" &>/dev/null; then
            LLM_URL="$c"
            ok "LLM 백엔드 탐지: ${LLM_URL} (status 표시용으로만 기록한다)"
            return 0
        fi
    done
    warn "로컬에서 OpenAI 호환 백엔드를 찾지 못했다 — status 의 LLM 항목은 비워둔다"
    warn "  나중에 지정하려면: --llm-url http://<host>:<port>/v1"
}

write_launch_params() {
    step "기동 파라미터 기록"

    mkdir -p "$OW_HOME" "$OW_DATA" "$LOG_DIR"

    # 기존 파일이 있으면 그 값을 기본값으로 승계한다.
    # 명령줄로 명시한 것만 덮어쓴다 — 손으로 고친 값이 재실행에 날아가지 않도록.
    if [[ -f "$ENV_FILE" ]]; then
        local prev_host prev_port prev_llm prev_key prev_data
        # shellcheck disable=SC1090
        prev_host=$( ( . "$ENV_FILE" >/dev/null 2>&1; echo "${OPENWEBUI_HOST:-}" ) )
        prev_port=$( ( . "$ENV_FILE" >/dev/null 2>&1; echo "${OPENWEBUI_PORT:-}" ) )
        prev_data=$( ( . "$ENV_FILE" >/dev/null 2>&1; echo "${OPENWEBUI_DATA_DIR:-}" ) )
        prev_llm=$(  ( . "$ENV_FILE" >/dev/null 2>&1; echo "${STATUS_LLM_URL:-}" ) )
        prev_key=$(  ( . "$ENV_FILE" >/dev/null 2>&1; echo "${STATUS_LLM_KEY:-}" ) )

        [[ -n "$prev_host" && "$OPT_HOST_SET" == false ]] && OW_HOST="$prev_host"
        [[ -n "$prev_port" && "$OPT_PORT_SET" == false ]] && OW_PORT="$prev_port"
        [[ -n "$prev_data" && "$OPT_DATA_SET" == false ]] && OW_DATA="$prev_data"
        [[ -n "$prev_key"  && -z "$LLM_KEY" ]] && LLM_KEY="$prev_key"
        if [[ -n "$prev_llm" && "$LLM_PROBE" == true ]]; then
            LLM_URL="$prev_llm"
            info "기존 STATUS_LLM_URL 유지: $LLM_URL (--llm-url 로 바꿀 수 있다)"
        fi
        info "기존 기동 파라미터를 승계했다 (명시한 옵션만 덮어쓴다)"
    fi

    probe_llm_url

    # 이전 버전 스크립트가 만든 시크릿 키를 앱 형식으로 이관한다.
    # (앱은 cwd 의 .webui_secret_key 를 스스로 만들고 관리한다)
    if [[ -f "$ENV_FILE" ]] && grep -q '^WEBUI_SECRET_KEY=' "$ENV_FILE" \
       && [[ ! -f "$OW_HOME/.webui_secret_key" ]]; then
        grep '^WEBUI_SECRET_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' \
            > "$OW_HOME/.webui_secret_key"
        chmod 600 "$OW_HOME/.webui_secret_key"
        info "기존 시크릿 키를 앱 형식으로 이관했다 (로그인 세션 유지)"
    fi

    cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# Open WebUI 기동 파라미터  —  openwebui-install.sh 가 생성
#
# 여기에는 '어떻게 띄울 것인가'만 들어간다.
# LLM 백엔드 주소, 모델 이름, 임베딩/음성/이미지 엔진 같은 '설정'은
# 이 파일에 없다. 전부 Open WebUI 관리자 UI(설정 > 관리자 패널)에서 하고,
# 앱이 자기 DB(webui.db)에 저장한다. 그게 유일한 정답 위치다.
#
# (bash 로 source 된다 — 공백이 든 값은 따옴표로 감쌀 것)
# =============================================================================

# venv 위치
OPENWEBUI_VENV="${VENV}"

# 기동 cwd. 앱이 .webui_secret_key 를 cwd 에 만들기 때문에(__init__.py:13)
# 이 값이 흔들리면 매 기동마다 새 키가 생겨 로그인 세션이 전부 끊긴다.
OPENWEBUI_HOME="${OW_HOME}"

# 데이터 위치. 관리자 UI 에 없는 값이라 여기서 정할 수밖에 없다.
# 모델 캐시(CACHE_DIR)는 config.py:176 에 따라 이 아래로 자동으로 따라온다.
OPENWEBUI_DATA_DIR="${OW_DATA}"

# 기동 주소·포트 (open-webui serve 의 CLI 인자로 전달된다)
OPENWEBUI_HOST="${OW_HOST}"
OPENWEBUI_PORT="${OW_PORT}"

# 아래는 openwebui-run.sh 의 status 표시에만 쓰인다.
# Open WebUI 의 설정이 아니다 — 백엔드 연결은 관리자 UI > Connections 에서 한다.
# 비어 있으면 status 가 LLM 항목을 그냥 건너뛴다.
STATUS_LLM_URL="${LLM_URL}"
STATUS_LLM_KEY="${LLM_KEY}"
ENVEOF

    chmod 600 "$ENV_FILE"

    if ! ( set -a; . "$ENV_FILE"; set +a ) 2>/dev/null; then
        error "기동 파라미터 파일 파싱 실패: $ENV_FILE"
    fi
    ok "기동 파라미터: $ENV_FILE"

    [[ -e "$SCRIPT_DIR/.open-webui" ]] || ln -s "$OW_HOME" "$SCRIPT_DIR/.open-webui"
}

# ── 8. 모델 사전 다운로드 (선택) ───────────────────────────────────────────
# 기본 꺼짐. 안 해도 앱이 첫 사용 때 알아서 받는다.
# 받는 위치는 앱 기본값(DATA_DIR/cache, config.py:176)을 그대로 따른다 —
# 스크립트가 별도 경로를 만들지 않으므로 앱이 못 찾는 일은 없다.
prefetch_models() {
    [[ "$DO_PREFETCH" == true ]] || return 0
    step "모델 사전 다운로드 (--prefetch)"

    export DATA_DIR="$OW_DATA"

    _try() {
        local label="$1"; shift
        info "${label} ..."
        if "$VENV/bin/python" -c "$1" 2>/dev/null; then
            ok "${label}"
        else
            warn "${label} 실패 — 첫 사용 시 앱이 다시 받는다"
        fi
    }

    _try "임베딩 모델 (all-MiniLM-L6-v2)" \
        "from sentence_transformers import SentenceTransformer
SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2', device='cpu')"

    _try "Whisper STT 모델 (base)" \
        "import os
from faster_whisper import WhisperModel
WhisperModel('base', device='cpu', compute_type='int8',
             download_root=os.environ['DATA_DIR'] + '/cache/whisper/models')"

    _try "tiktoken 인코딩 (cl100k_base)" \
        "import tiktoken; tiktoken.get_encoding('cl100k_base')"

    _try "NLTK punkt_tab" \
        "import nltk; nltk.download('punkt_tab', quiet=True)"
}

# ── 9. 기동 검증 ───────────────────────────────────────────────────────────
# 설정이 맞는지가 아니라 '설치가 됐는지'만 본다.
smoke_test() {
    [[ "$DO_SMOKE" == true ]] || { warn "--no-smoke 지정 — 건너뜀"; return 0; }
    step "기동 검증"

    local log="$LOG_DIR/install-smoke.log"
    info "open-webui serve 기동 중... (최초 기동은 DB 마이그레이션 때문에 느리다)"

    # cwd 를 OW_HOME 으로 고정 — 앱이 여기에 .webui_secret_key 를 만든다.
    # 서브셸로 감싸면 $! 가 데몬이 아니라 서브셸을 가리키므로 감싸지 않는다.
    local prev_pwd="$PWD"
    cd "$OW_HOME"
    DATA_DIR="$OW_DATA" "$VENV/bin/open-webui" serve \
        --host 127.0.0.1 --port "$OW_PORT" < /dev/null > "$log" 2>&1 &
    local pid=$!
    cd "$prev_pwd"

    local i
    for i in $(seq 1 120); do
        if ! kill -0 "$pid" 2>/dev/null; then
            warn "프로세스가 죽었다. 로그 마지막 20줄:"
            tail -20 "$log"
            error "기동 검증 실패"
        fi
        if curl -sf --max-time 3 "http://127.0.0.1:${OW_PORT}/health" | grep -q 'true'; then
            ok "/health 응답 확인 (${i}초)"
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            ok "기동 검증 통과 — 계획서 Step 1 완료 판정 충족"
            return
        fi
        sleep 1
    done

    kill "$pid" 2>/dev/null || true
    warn "120초 안에 /health 가 응답하지 않았다. 로그: $log"
    tail -20 "$log"
}

# ── 10. systemd 사용자 서비스 (선택) ───────────────────────────────────────
install_service() {
    [[ "$DO_SERVICE" == true ]] || return 0
    step "systemd 사용자 서비스 등록"

    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"

    # WorkingDirectory 가 곧 시크릿 키 위치다 (__init__.py:13) — 반드시 고정
    cat > "$unit_dir/openwebui.service" <<SVCEOF
[Unit]
Description=Open WebUI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${OW_HOME}
Environment=DATA_DIR=${OW_DATA}
ExecStart=${VENV}/bin/open-webui serve --host ${OW_HOST} --port ${OW_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

    if ! systemctl --user daemon-reload 2>/dev/null; then
        warn "systemd 사용자 세션이 없다 (컨테이너·WSL 등) — 유닛 파일만 남긴다:"
        warn "  $unit_dir/openwebui.service"
        return 0
    fi
    systemctl --user enable openwebui.service
    ok "서비스 등록 완료: systemctl --user start openwebui"

    if loginctl enable-linger "$USER" 2>/dev/null; then
        ok "linger 활성화 — 로그아웃 후에도 실행 유지"
    else
        warn "linger 활성화 실패 (sudo 필요): sudo loginctl enable-linger $USER"
    fi
}

# ── 11. 요약 ───────────────────────────────────────────────────────────────
print_summary() {
    step "설치 완료"

    echo
    echo -e "  ${BOLD}설치 위치${NC}"
    echo "  venv       : $VENV"
    echo "  데이터     : $OW_DATA"
    echo "  기동 파라미터 : $ENV_FILE"
    echo "  로그       : $LOG_DIR"
    echo
    echo -e "  ${BOLD}실행${NC}"
    echo "  ./openwebui-run.sh start     # 시작"
    echo "  ./openwebui-run.sh status    # 상태"
    echo "  ./openwebui-run.sh logs      # 실시간 로그"
    echo "  ./openwebui-run.sh stop      # 정지"
    echo
    echo -e "  ${BOLD}접속${NC}   http://${OW_HOST}:${OW_PORT}"
    echo "  첫 접속 시 만드는 계정이 관리자다."
    echo
    echo -e "  ${BOLD}설정은 전부 앱 안에서 한다${NC} (이 스크립트는 손대지 않았다)"
    echo "  Step 2  vLLM 연결  — 관리자 패널 > Connections > OpenAI"
    echo "                       Base URL 에 vLLM 주소, API Key 는 아무 값"
    echo "  Step 3  MCP        — uvx mcpo --port 8001 -- <MCP 서버 명령>"
    echo "                       → 설정 > Tools 에 OpenAPI 로 등록"
    echo "  Step 4  이미지     — 관리자 패널 > Images > ComfyUI"
    echo "  Step 5  음성      — 관리자 패널 > Audio (STT/TTS)"
    if ! command -v ffmpeg &>/dev/null; then
        echo "                       ⚠ ffmpeg 없음 — sudo apt install ffmpeg"
    fi
    echo "  Step 6  영상      — Functions(Pipe) 로 vLLM 정지/재기동 큐 구현"
    echo "                       ⚠ 공식 문서상 Pipelines 는 legacy 다"
    echo
    if [[ "$DO_SERVICE" == false ]]; then
        echo "  부팅 시 자동 시작: $(basename "$0") --service"
        echo
    fi
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   Open WebUI 설치 스크립트                 ${NC}"
    echo -e "${BOLD}   Ubuntu | uv venv | 설정은 앱에 맡긴다     ${NC}"
    echo -e "${BOLD}============================================${NC}"

    check_prerequisites
    install_uv
    install_system_deps
    create_venv
    install_torch
    install_openwebui
    write_launch_params
    prefetch_models
    smoke_test
    install_service
    print_summary
}

main "$@"
