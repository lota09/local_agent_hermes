#!/usr/bin/env bash
# =============================================================================
# AnythingLLM 제거 스크립트 (베어메탈 / pm2 기반)
# 비루트 사용자도 실행 가능 (루트 권한 있으면 pm2 startup 등록도 해제)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }
skip()  { echo -e "  ${YELLOW}건너뜀:${NC} $*"; }

# sudo로 감싸서 실행하면 $HOME이 바뀌어 엉뚱한(/root) 디렉터리를 대상으로
# rm -rf를 계산하게 되므로, 애초에 sudo로는 실행하지 못하게 막는다.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo -e "${RED}[ERROR]${NC} 이 스크립트는 sudo로 실행하지 마세요."
    echo "  sudo로 실행하면 \$HOME이 /root로 바뀌어서 제거 대상 경로가 달라집니다."
    echo "  일반 사용자로 다시 실행하세요: ./uninstall_AnythingLLM_baremetal.sh"
    exit 1
fi

# -n(비대화형)만 쓰면 비밀번호가 필요한 일반 sudo 계정을 전부 "sudo 없음"으로
# 오판하므로, 실패하면 대화형 sudo -v로 한 번 더 확인한다.
HAS_SUDO=false
if [[ $EUID -eq 0 ]]; then
    HAS_SUDO=true
elif command -v sudo &>/dev/null; then
    if sudo -n true 2>/dev/null; then
        HAS_SUDO=true
    elif sudo -v 2>/dev/null; then
        HAS_SUDO=true
    fi
fi

HAS_SYSTEMD=false
[[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null && HAS_SYSTEMD=true

ANYTHINGLLM_DIR="$HOME/anythingllm"
PM2_SERVER="anythingllm-server"
PM2_COLLECTOR="anythingllm-collector"

# ── 헬퍼: 디렉터리/파일 제거 ──────────────────────────────────────────────
remove_path() {
    local target="$1"
    if [[ -e "$target" ]]; then
        rm -rf "$target"
        ok "제거됨: $target"
    else
        skip "없음: $target"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# AnythingLLM 제거
# ═══════════════════════════════════════════════════════════════════════════
uninstall_anythingllm() {
    step "AnythingLLM 제거 (베어메탈)"

    # 1. pm2 프로세스 정지/제거
    if command -v pm2 &>/dev/null; then
        info "pm2 프로세스 정지 중..."
        pm2 delete "$PM2_SERVER" 2>/dev/null && ok "${PM2_SERVER} 제거됨" || skip "${PM2_SERVER} 없음"
        pm2 delete "$PM2_COLLECTOR" 2>/dev/null && ok "${PM2_COLLECTOR} 제거됨" || skip "${PM2_COLLECTOR} 없음"
        pm2 save &>/dev/null || true

        # 2. pm2 startup(systemd 등록) 해제
        if [[ "$HAS_SYSTEMD" == true && "$HAS_SUDO" == true ]]; then
            info "pm2 startup 등록 해제 시도 중..."
            local unstartup_cmd
            unstartup_cmd="$(pm2 unstartup systemd 2>/dev/null | grep -E '^sudo ' | tail -1 || true)"
            if [[ -n "$unstartup_cmd" ]]; then
                eval "$unstartup_cmd" &>/dev/null && ok "pm2 startup 해제 완료" || warn "pm2 startup 해제 실패 (수동: $unstartup_cmd)"
            else
                skip "pm2 startup 등록 흔적 없음"
            fi
        else
            skip "systemd/sudo 없음 — pm2 startup 해제 단계 생략"
        fi
    else
        skip "pm2 없음 — 프로세스 제거 단계 생략"
    fi

    # 3. 전역 npm 패키지(yarn, pm2)는 다른 프로젝트가 쓸 수도 있어 유지
    info "yarn / pm2 / Node.js는 다른 프로젝트에서도 쓸 수 있어 제거하지 않습니다."
    info "직접 정리하려면: npm uninstall -g pm2 yarn"

    # 4. 소스/데이터 제거
    info "AnythingLLM 소스 디렉터리 제거 여부 확인..."
    read -rp "  ${ANYTHINGLLM_DIR} 를 제거하시겠습니까? (대화 기록·문서·MCP 설정 포함) [y/N]: " RM_DIR
    if [[ "${RM_DIR,,}" == "y" ]]; then
        remove_path "$ANYTHINGLLM_DIR"
    else
        skip "디렉터리 유지: $ANYTHINGLLM_DIR"
        info "나중에 직접 삭제: rm -rf $ANYTHINGLLM_DIR"
    fi

    ok "AnythingLLM 제거 완료"
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}==================================================${NC}"
    echo -e "${BOLD}   AnythingLLM 제거 스크립트 (베어메탈)          ${NC}"
    echo -e "${BOLD}==================================================${NC}"
    echo
    [[ "$HAS_SYSTEMD" == true ]] || info "systemd 없음 (chroot/proot 등) — pm2 프로세스만 정리합니다"
    echo

    warn "AnythingLLM을 제거합니다."
    warn "이 작업은 되돌릴 수 없습니다."
    read -rp "계속하시겠습니까? [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "취소됨"; exit 0; }

    uninstall_anythingllm

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        제거 완료!                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
}

main "$@"
