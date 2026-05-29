#!/usr/bin/env bash
# =============================================================================
# AI 에이전트 프레임워크 제거 스크립트
# 대상: Hermes / LobeChat / LibreChat
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

HAS_SUDO=false
sudo -n true 2>/dev/null && HAS_SUDO=true

# ── 헬퍼: 사용자 서비스 제거 ──────────────────────────────────────────────
remove_user_service() {
    local svc="$1"
    local svc_file="$HOME/.config/systemd/user/${svc}.service"

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
# Hermes 제거
# ═══════════════════════════════════════════════════════════════════════════
uninstall_hermes() {
    step "Hermes Agent 제거"

    # 1. 실행 중인 서비스 중지
    info "실행 중인 Hermes 프로세스 확인..."

    # 대시보드 PID 파일로 프로세스 종료
    local dashboard_pid="$HOME/.hermes/dashboard.pid"
    if [[ -f "$dashboard_pid" ]]; then
        local pid
        pid=$(cat "$dashboard_pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            ok "Hermes 대시보드 프로세스 종료 (PID: $pid)"
        fi
        rm -f "$dashboard_pid"
    fi

    # hermes gateway stop (바이너리가 있으면)
    local hermes_bin=""
    for candidate in \
        "$(command -v hermes 2>/dev/null)" \
        "$HOME/.local/bin/hermes" \
        "$HOME/.hermes/hermes-agent/venv/bin/hermes"
    do
        [[ -x "$candidate" ]] && { hermes_bin="$candidate"; break; }
    done

    if [[ -n "$hermes_bin" ]]; then
        info "Hermes 게이트웨이 정지 중..."
        "$hermes_bin" gateway stop 2>/dev/null || true
        ok "게이트웨이 정지 완료"
    fi

    # hermes 관련 프로세스 강제 종료
    pkill -f "hermes" 2>/dev/null || true

    # 2. 사용자 서비스 제거
    remove_user_service "hermes-gateway"

    # 3. 시스템 서비스 제거 (루트 있으면)
    remove_system_service "hermes-gateway"

    # 4. 설치 파일 제거
    info "Hermes 파일 제거 중..."
    remove_path "$HOME/.hermes"
    remove_path "$HOME/.local/bin/hermes"
    remove_path "$HOME/.local/bin/webui-start"

    # ~/.bashrc에서 Hermes PATH 항목 제거
    if grep -q "Hermes Agent" "$HOME/.bashrc" 2>/dev/null; then
        sed -i '/# Hermes Agent/d' "$HOME/.bashrc"
        sed -i '/\.local\/bin.*PATH/d' "$HOME/.bashrc" 2>/dev/null || true
        ok "~/.bashrc에서 Hermes PATH 항목 제거됨"
    fi

    ok "Hermes Agent 제거 완료"
}

# ═══════════════════════════════════════════════════════════════════════════
# LobeChat 제거
# ═══════════════════════════════════════════════════════════════════════════
uninstall_lobechat() {
    step "LobeChat 제거"

    # 1. 실행 중인 Docker 컨테이너 중지
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        if docker ps --filter "name=lobechat" -q | grep -q .; then
            info "Docker 컨테이너 정지 중: lobechat"
            docker stop lobechat 2>/dev/null || true
            ok "컨테이너 정지됨"
        else
            skip "실행 중인 lobechat 컨테이너 없음"
        fi

        # 컨테이너 제거
        if docker ps -a --filter "name=lobechat" -q | grep -q .; then
            docker rm lobechat 2>/dev/null || true
            ok "컨테이너 제거됨"
        fi

        # Docker 이미지 제거
        read -rp "  Docker 이미지도 제거하시겠습니까? (lobehub/lobe-chat) [y/N]: " RM_IMAGE
        if [[ "${RM_IMAGE,,}" == "y" ]]; then
            docker rmi lobehub/lobe-chat:latest 2>/dev/null && ok "이미지 제거됨" || skip "이미지 없음"
        fi
    else
        skip "Docker를 사용할 수 없음 — 컨테이너 제거 건너뜀"
    fi

    # 2. 사용자 서비스 제거
    remove_user_service "lobechat"

    # 3. 시스템 서비스 제거 (루트 있으면)
    remove_system_service "lobechat"

    # 4. 설정 파일 제거
    info "LobeChat 설정 파일 제거 중..."
    remove_path "$HOME/.lobechat"

    ok "LobeChat 제거 완료"
}

# ═══════════════════════════════════════════════════════════════════════════
# LibreChat 제거
# ═══════════════════════════════════════════════════════════════════════════
uninstall_librechat() {
    step "LibreChat 제거"

    local librechat_dir="$HOME/librechat"

    # 1. Docker Compose 서비스 중지
    if [[ -d "$librechat_dir" ]] && command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        info "Docker Compose 서비스 정지 중..."
        cd "$librechat_dir"
        docker compose down 2>/dev/null && ok "서비스 정지됨" || skip "정지 실패 (이미 중지되어 있을 수 있음)"
        cd - > /dev/null
    else
        skip "LibreChat 디렉터리 또는 Docker 없음 — 서비스 중지 건너뜀"
    fi

    # 2. Docker 이미지 제거
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        read -rp "  LibreChat Docker 이미지도 제거하시겠습니까? [y/N]: " RM_IMAGE
        if [[ "${RM_IMAGE,,}" == "y" ]]; then
            info "LibreChat 관련 이미지 제거 중..."
            docker images -a | grep "librechat" | awk '{print $3}' \
                | xargs docker rmi 2>/dev/null && ok "이미지 제거됨" || skip "이미지 없음"
        fi
    fi

    # 3. 사용자 서비스 제거
    remove_user_service "librechat"

    # 4. 시스템 서비스 제거 (루트 있으면)
    remove_system_service "librechat"

    # 5. 소스 디렉터리 제거
    info "LibreChat 소스 디렉터리 제거 중..."
    read -rp "  ${librechat_dir} 를 제거하시겠습니까? (대화 데이터 포함) [y/N]: " RM_DIR
    if [[ "${RM_DIR,,}" == "y" ]]; then
        remove_path "$librechat_dir"
    else
        skip "소스 디렉터리 유지: $librechat_dir"
        warn "Docker 볼륨(대화 데이터)은 별도로 남아있을 수 있습니다:"
        warn "  docker volume ls | grep librechat"
        warn "  docker volume rm <볼륨명>"
    fi

    ok "LibreChat 제거 완료"
}

# ── 메인 ───────────────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}   AI 에이전트 제거 스크립트               ${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo
    [[ "$HAS_SUDO" == true ]] && info "sudo 권한 확인됨 — 시스템 서비스도 제거합니다" \
                               || warn "sudo 없음 — 사용자 서비스만 제거합니다"
    echo
    echo "  제거할 항목을 선택하세요:"
    echo
    echo "  1) Hermes Agent"
    echo "  2) LobeChat"
    echo "  3) LibreChat"
    echo "  4) 전체 (1+2+3)"
    echo
    read -rp "선택 [1-4]: " CHOICE

    case "$CHOICE" in
        1) targets=("hermes") ;;
        2) targets=("lobechat") ;;
        3) targets=("librechat") ;;
        4) targets=("hermes" "lobechat" "librechat") ;;
        *) error "잘못된 선택입니다." ;;
    esac

    # 제거 전 최종 확인
    echo
    warn "다음 항목을 제거합니다: ${targets[*]}"
    warn "이 작업은 되돌릴 수 없습니다."
    read -rp "계속하시겠습니까? [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "취소됨"; exit 0; }

    for target in "${targets[@]}"; do
        case "$target" in
            hermes)    uninstall_hermes    ;;
            lobechat)  uninstall_lobechat  ;;
            librechat) uninstall_librechat ;;
        esac
    done

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        제거 완료!                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo
    info "변경사항을 현재 터미널에 반영하려면: source ~/.bashrc"
    echo
}

main "$@"
