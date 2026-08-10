#!/usr/bin/env bash
# =============================================================================
# AnythingLLM에 "초경량 bash 실행 MCP"를 추가하는 스크립트
# - @mkusaka/mcp-shell-server : 도구 1개(shell_exec)만 노출 → 컨텍스트 부하 최소
#   (desktop-commander는 도구 25개+로 작은 모델의 프롬프트를 꽉 채워버림)
# - 무거운 desktop-commander 항목이 있으면 함께 제거할지 물어봅니다.
# - npx가 아니라 전역 설치본 절대경로를 직접 실행 → 시작 시 다운로드 없음(타임아웃 방지).
# 사용법: ./add_shell_mcp.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

command -v python3 &>/dev/null || error "python3가 필요합니다."
command -v node    &>/dev/null || error "node가 필요합니다."
command -v npm     &>/dev/null || error "npm이 필요합니다."

HAS_SUDO=false
if [[ $EUID -eq 0 ]]; then HAS_SUDO=true
elif command -v sudo &>/dev/null; then
  if sudo -n true 2>/dev/null; then HAS_SUDO=true
  elif sudo -v 2>/dev/null;  then HAS_SUDO=true
  fi
fi

PKG="@mkusaka/mcp-shell-server"
BIN_NAME="mcp-shell"

# ── 1. 전역 설치 ───────────────────────────────────────────────────────────
info "경량 shell MCP 전역 설치 중... ($PKG)"
if ! npm install -g "$PKG" 2>/tmp/_shellmcp_install.log; then
  if [[ "$HAS_SUDO" == true ]]; then
    warn "일반 권한 설치 실패 — sudo로 재시도합니다"
    sudo npm install -g "$PKG" || error "설치 실패. 로그: /tmp/_shellmcp_install.log"
  else
    cat /tmp/_shellmcp_install.log | tail -5
    error "설치 실패 (sudo 없음). 전역 npm 경로 권한을 확인하세요."
  fi
fi

SHELL_BIN="$(command -v "$BIN_NAME" 2>/dev/null || true)"
[[ -z "$SHELL_BIN" ]] && SHELL_BIN="$(npm prefix -g)/bin/${BIN_NAME}"
[[ -x "$SHELL_BIN" ]] || error "설치는 됐지만 바이너리($BIN_NAME)를 못 찾았습니다: $SHELL_BIN"
ok "설치 완료: $SHELL_BIN"

# ── 2. MCP 설정 파일 위치 자동 탐색 ────────────────────────────────────────
CANDIDATES=(
    "$HOME/anythingllm/server/storage/plugins/anythingllm_mcp_servers.json"
    "$HOME/.anythingllm/storage/plugins/anythingllm_mcp_servers.json"
)
MCP_CONFIG=""
for c in "${CANDIDATES[@]}"; do [[ -f "$c" ]] && { MCP_CONFIG="$c"; break; }; done
if [[ -z "$MCP_CONFIG" ]]; then
    for c in "${CANDIDATES[@]}"; do [[ -d "$(dirname "$c")" ]] && { MCP_CONFIG="$c"; break; }; done
fi
if [[ -z "$MCP_CONFIG" ]]; then
    warn "MCP 설정 파일을 자동으로 찾지 못했습니다."
    read -rp "anythingllm_mcp_servers.json 의 전체 경로를 입력하세요: " MCP_CONFIG
    [[ -n "$MCP_CONFIG" ]] || error "경로를 입력해야 합니다."
fi
info "대상 MCP 설정 파일: $MCP_CONFIG"
mkdir -p "$(dirname "$MCP_CONFIG")"

# ── 3. desktop-commander 제거 여부 ─────────────────────────────────────────
REMOVE_DC="n"
if [[ -f "$MCP_CONFIG" ]] && grep -q '"desktop-commander"' "$MCP_CONFIG" 2>/dev/null; then
    echo
    warn "무거운 desktop-commander 항목이 설정에 있습니다 (도구 25개+, 컨텍스트 부하 큼)."
    read -rp "desktop-commander를 제거하고 경량 shell로 대체할까요? [Y/n]: " ans
    [[ "${ans,,}" != "n" ]] && REMOVE_DC="y"
fi

# ── 4. 설정 병합 ───────────────────────────────────────────────────────────
python3 - "$MCP_CONFIG" "$SHELL_BIN" "$REMOVE_DC" <<'PYEOF'
import json, os, sys
path, shell_bin, remove_dc = sys.argv[1], sys.argv[2], sys.argv[3]

if os.path.exists(path):
    try:
        with open(path) as f: config = json.load(f)
    except Exception:
        config = {}
else:
    config = {}
config.setdefault("mcpServers", {})

if remove_dc == "y" and "desktop-commander" in config["mcpServers"]:
    del config["mcpServers"]["desktop-commander"]
    print("\033[1;33m[WARN]  desktop-commander 제거됨\033[0m")

config["mcpServers"]["shell"] = {
    "command": shell_bin,
    "args": [],
    "description": "bash 명령 실행"
}

with open(path, "w") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print("\033[0;32m[OK]    shell MCP 추가 완료 (현재 MCP 서버 %d개)\033[0m" % len(config["mcpServers"]))
for name, cfg in config["mcpServers"].items():
    print("         - %s: %s" % (name, cfg.get("description","")))
PYEOF

echo
ok "완료. 다음 두 단계를 마저 진행하세요:"
echo "  1) AnythingLLM 재시작:"
echo "       ./run_AnythingLLM_baremetal.sh restart"
echo "  2) 웹 UI에서 활성화(토글 ON):"
echo "       Settings → Agent Skills → MCP Servers → shell"
echo
info "사용 예: @agent 로 'date 명령 실행해줘' → shell_exec 로 bash 실행"
warn "참고: 이 서버는 명령 자체는 자유롭게 실행하지만, workingDir 지정은 \$HOME 하위만 허용됩니다."
warn "LLM에게 셸 접근을 주는 것이므로 신뢰할 수 있는 로컬 환경에서만 켜세요."
