#!/usr/bin/env bash
# =============================================================================
# AnythingLLM 제거 스크립트
# 비루트 사용자도 실행 가능 (루트 권한 있으면 시스템 서비스도 제거)
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
# 계산하게 되므로, 애초에 sudo로는 실행하지 못하게 막는다.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo -e "${RED}[ERROR]${NC} 이 스크립트는 sudo로 실행하지 마세요."
    echo "  sudo로 실행하면 \$HOME이 /root로 바뀌어서 제거 대상 경로가 달라집니다."
    echo "  일반 사용자로 다시 실행하세요: ./uninstall_AnythingLLM.sh"
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

# systemd가 실제 init(PID 1)으로 동작 중인지 확인 (chroot 등 최소 환경 대비)
HAS_SYSTEMD=false
[[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null && HAS_SYSTEMD=true

HAS_SYSTEMD_USER=false
if [[ "$HAS_SYSTEMD" == true ]] && systemctl --user daemon-reload &>/dev/null 2>&1; then
    HAS_SYSTEMD_USER=true
fi

ANYTHINGLLM_HOME="$HOME/.anythingllm"
CONTAINER_NAME="anythingllm"
IMAGE="mintplexlabs/anythingllm:latest"

# ── 헬퍼: 사용자 서비스 제거 ──────────────────────────────────────────────
remove_user_service() {
    local svc="$1"
    local svc_file="$HOME/.config/systemd/user/${svc}.service"

    if [[ "$HAS_SYSTEMD_USER" != true ]]; then
        skip "systemd 사용자 세션 없음 — 서비스 제거 건너뜀: $svc"
        [[ -f "$svc_file" ]] && remove_path "$svc_file"
        return
    fi

    if systemctl --user is-active "$svc" &>/dev/null 2>&1; then
        info "사용자 서비스 정지 중: $svc"
        systemctl --user stop "$svc" 2>/dev/null || true
        ok "서비스 정지됨"
    fi

    if systemctl --user is-enabled "$svc" &>/dev/null 2>&1; then
        info "사용자 서비스 비활성화 중: $svc"
        systemctl --user disable "$svc" 2>/dev/null || true
        ok "서비스 비활성화됨"
    fi

    if [[ -f "$svc_file" ]]; then
        rm -f "$svc_file"
        systemctl --user daemon-reload 2>/dev/null || true
        ok "서비스 파일 제거됨: $svc_file"
    else
        skip "서비스 파일 없음: $svc_file"
    fi
}

# ── 헬퍼: 시스템 서비스 제거 (루트 필요) ─────────────────────────────────
remove_system_service() {
    local svc="$1"
    local svc_file="/etc/systemd/system/${svc}.service"

    if [[ "$HAS_SYSTEMD" == false ]]; then
        skip "systemd 없음 — 시스템 서비스 제거 건너뜀: $svc"
        return
    fi

    if [[ "$HAS_SUDO" == false ]]; then
        skip "시스템 서비스 제거 건너뜀 (sudo 없음): $svc"
        return
    fi

    if sudo systemctl is-active "$svc" &>/dev/null 2>&1; then
        info "시스템 서비스 정지 중: $svc"
        sudo systemctl stop "$svc" 2>/dev/null || true
        ok "시스템 서비스 정지됨"
    fi

    if sudo systemctl is-enabled "$svc" &>/dev/null 2>&1; then
        sudo systemctl disable "$svc" 2>/dev/null || true
        ok "시스템 서비스 비활성화됨"
    fi

    if [[ -f "$svc_file" ]]; then
        sudo rm -f "$svc_file"
        sudo systemctl daemon-reload 2>/dev/null || true
        ok "시스템 서비스 파일 제거됨: $svc_file"
    else
        skip "시스템 서비스 파일 없음: $svc_file"
    fi
}

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
    step "AnythingLLM 제거"

    # 1. 실행 중인 Docker 컨테이너 중지/제거
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        if docker ps --filter "name=${CONTAINER_NAME}" -q | grep -q .; then
            info "Docker 컨테이너 정지 중: ${CONTAINER_NAME}"
            docker stop "$CONTAINER_NAME" 2>/dev/null || true
            ok "컨테이너 정지됨"
        else
            skip "실행 중인 ${CONTAINER_NAME} 컨테이너 없음"
        fi

        if docker ps -a --filter "name=${CONTAINER_NAME}" -q | grep -q .; then
            docker rm "$CONTAINER_NAME" 2>/dev/null || true
            ok "컨테이너 제거됨"
        fi

        read -rp "  Docker 이미지도 제거하시겠습니까? (${IMAGE}) [y/N]: " RM_IMAGE
        if [[ "${RM_IMAGE,,}" == "y" ]]; then
            docker rmi "$IMAGE" 2>/dev/null && ok "이미지 제거됨" || skip "이미지 없음"
        fi
    else
        skip "Docker를 사용할 수 없음 — 컨테이너 제거 건너뜀"
    fi

    # 2. 사용자 서비스 제거
    remove_user_service "anythingllm"

    # 3. 시스템 서비스 제거 (루트 있으면)
    remove_system_service "anythingllm"

    # 4. 저장소/설정 제거
    info "AnythingLLM 저장소 제거 여부 확인..."
    read -rp "  ${ANYTHINGLLM_HOME} 를 제거하시겠습니까? (대화 기록·문서·MCP 설정 포함) [y/N]: " RM_DIR
    if [[ "${RM_DIR,,}" == "y" ]]; then
        remove_path "$ANYTHINGLLM_HOME"
    else
        skip "저장소 유지: $ANYTHINGLLM_HOME"
        info "나중에 직접 삭제: rm -rf $ANYTHINGLLM_HOME"
    fi

    ok "AnythingLLM 제거 완료"
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   AnythingLLM 제거 스크립트                ${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo
    [[ "$HAS_SUDO" == true ]] && info "sudo 권한 확인됨 — 시스템 서비스도 제거합니다" \
                               || warn "sudo 없음 — 사용자 서비스만 제거합니다"
    [[ "$HAS_SYSTEMD" == true ]] || warn "systemd 없음 (chroot 등 최소 환경) — 서비스 제거 단계는 건너뜁니다"
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
