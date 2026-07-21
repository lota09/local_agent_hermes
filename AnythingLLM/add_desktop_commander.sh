#!/usr/bin/env bash
# =============================================================================
# 이미 설치된 AnythingLLM에 Desktop Commander(터미널 MCP)를 추가하는 스크립트
# - 재설치 없이 기존 anythingllm_mcp_servers.json 에 항목만 병합합니다.
# - 베어메탈/도커 설치 위치를 자동으로 찾습니다.
# 사용법: ./add_desktop_commander.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── MCP 설정 파일 위치 자동 탐색 ───────────────────────────────────────────
# 베어메탈: ~/anythingllm/server/storage/plugins/...
# 도커:     ~/.anythingllm/storage/plugins/...
CANDIDATES=(
    "$HOME/anythingllm/server/storage/plugins/anythingllm_mcp_servers.json"
    "$HOME/.anythingllm/storage/plugins/anythingllm_mcp_servers.json"
)

MCP_CONFIG=""
for c in "${CANDIDATES[@]}"; do
    if [[ -f "$c" ]]; then MCP_CONFIG="$c"; break; fi
done

# 파일이 아직 없으면 디렉터리라도 있는 위치에 새로 만든다
if [[ -z "$MCP_CONFIG" ]]; then
    for c in "${CANDIDATES[@]}"; do
        if [[ -d "$(dirname "$c")" ]]; then MCP_CONFIG="$c"; break; fi
    done
fi

# 그래도 못 찾으면 사용자에게 경로를 직접 받는다
if [[ -z "$MCP_CONFIG" ]]; then
    warn "MCP 설정 파일을 자동으로 찾지 못했습니다."
    read -rp "anythingllm_mcp_servers.json 의 전체 경로를 입력하세요: " MCP_CONFIG
    [[ -n "$MCP_CONFIG" ]] || error "경로를 입력해야 합니다."
fi

info "대상 MCP 설정 파일: $MCP_CONFIG"
mkdir -p "$(dirname "$MCP_CONFIG")"

command -v python3 &>/dev/null || error "python3가 필요합니다."

# ── desktop-commander 항목 병합 ───────────────────────────────────────────
python3 - "$MCP_CONFIG" <<'PYEOF'
import json, os, sys

path = sys.argv[1]

if os.path.exists(path):
    try:
        with open(path) as f:
            config = json.load(f)
    except Exception:
        config = {}
else:
    config = {}

config.setdefault("mcpServers", {})

if "desktop-commander" in config["mcpServers"]:
    print("\033[1;33m[WARN]  desktop-commander 항목이 이미 존재합니다 — 덮어씁니다\033[0m")

config["mcpServers"]["desktop-commander"] = {
    "command": "npx",
    "args": ["-y", "@wonderwhy-er/desktop-commander@latest"],
    "description": "터미널 명령 실행 + 파일 편집"
}

with open(path, "w") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print(f"\033[0;32m[OK]    desktop-commander 추가 완료 (현재 MCP 서버 {len(config['mcpServers'])}개)\033[0m")
for name, cfg in config["mcpServers"].items():
    print(f"         • {name}: {cfg.get('description', '')}")
PYEOF

echo
ok "완료되었습니다. 다음 두 단계를 마저 진행하세요:"
echo "  1) AnythingLLM 재시작:"
echo "       ./run_AnythingLLM_baremetal.sh restart   (베어메탈)"
echo "       ./run_AnythingLLM.sh restart             (도커)"
echo "  2) 웹 UI에서 활성화(토글 ON):"
echo "       Settings → Agent Skills → MCP Servers → desktop-commander"
echo
warn "이 도구는 LLM에게 사실상 셸 전체 접근을 허용합니다. 신뢰할 수 있는 로컬 환경에서만 켜세요."
