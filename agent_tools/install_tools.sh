#!/usr/bin/env bash
# =============================================================================
# agent_tools 통합 설치 스크립트
#
# 설계 원칙:
#   1. **이 파일은 도구가 늘어나도 수정하지 않는다.**
#      `agent_tools/<도구>/tool.manifest` 를 발견해서 목록을 만든다.
#      새 도구는 디렉터리 하나 + 매니페스트 한 장이면 자동으로 등장한다.
#   2. **설치는 각 도구가 한다.**
#      이 스크립트는 매니페스트의 TOOL_INSTALL 을 그 도구의 디렉터리에서
#      실행할 뿐이다. 도구별 사정(uv/git/npm/docker)은 도구가 안다.
#   3. **옵션은 그대로 흘려보낸다.**
#      `install.sh install <도구> -- <도구 옵션들>` 로 전달된다.
#
# 매니페스트 필드 (TOOL_NAME / TOOL_INSTALL 만 필수):
#   TOOL_NAME    고유 이름(디렉터리명과 같게)      [필수]
#   TOOL_INSTALL 설치 명령 — 도구 디렉터리 기준     [필수]
#   TOOL_TITLE   사람이 읽는 이름
#   TOOL_DESC    한 줄 설명
#   TOOL_TAGS    공백 구분 분류
#   TOOL_RUN     서비스 관리 스크립트
#   TOOL_STATUS  상태 확인 명령
#   TOOL_PORT    사용 포트 (충돌 사전 경고용)
#   TOOL_HEALTH  살아있는지 확인할 URL
#   TOOL_DOCS    참고 문서
#   TOOL_REQUIRES 선행 도구 이름들 (공백 구분)
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 파일명이 바뀌어도 도움말이 낡지 않게 $0 에서 유도한다
# 발견·파싱·상태판정·선택 UI 는 run.sh 와 공유한다.
# shellcheck disable=SC1091
. "$ROOT/_lib.sh"

# ── list ───────────────────────────────────────────────────────────────────
cmd_list() {
    local dirs; dirs=$(discover)
    [[ -n "$dirs" ]] || { warn "도구가 없다. <이름>/tool.manifest 를 만들면 여기 나타난다."; return; }

    echo
    printf "  ${BOLD}%-16s %-9s %-7s %s${NC}\n" "도구" "상태" "포트" "설명"
    echo "  ────────────────────────────────────────────────────────────────────"
    local d
    for d in $dirs; do
        printf "  %-16s %-18b %-7s ${DIM}%s${NC}\n" \
            "$(tool_name "$d")" "$(state_label "$d")" \
            "$(field "$d" TOOL_PORT)" "$(field "$d" TOOL_DESC)"
    done
    echo
    echo -e "  ${DIM}설치: ./install_tools.sh install [도구…]  (인자 없으면 골라서 설치)${NC}"
    echo -e "  ${DIM}실행: ./run_tools.sh start                (설치된 도구 다중 선택)${NC}"
    echo
}

# ── install ────────────────────────────────────────────────────────────────
install_one() {
    local d="$1"; shift
    local name title cmd
    name="$(field "$d" TOOL_NAME)"; [[ -n "$name" ]] || name="$(basename "$d")"
    title="$(field "$d" TOOL_TITLE)"; [[ -n "$title" ]] || title="$name"
    cmd="$(field "$d" TOOL_INSTALL)"

    [[ -n "$cmd" ]] || { warn "$name: TOOL_INSTALL 이 없다 — 건너뜀"; return 0; }

    # 선행 도구
    local req
    for req in $(field "$d" TOOL_REQUIRES); do
        local rd
        if rd=$(tool_dir "$req"); then
            is_installed "$rd" || warn "$name 은 $req 를 필요로 한다 (아직 미설치)"
        else
            warn "$name 이 요구하는 $req 를 agent_tools 에서 찾을 수 없다"
        fi
    done

    # 포트 충돌 사전 경고 (막지는 않는다 — 도구 스크립트가 최종 판단한다)
    local port; port="$(field "$d" TOOL_PORT)"
    if [[ -n "$port" ]] && command -v ss &>/dev/null; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
            if is_up "$d"; then
                info "포트 ${port} — 이미 이 도구가 응답 중이다"
            else
                warn "포트 ${port} 를 다른 무언가가 쓰고 있다"
            fi
        fi
    fi

    step "$title 설치"
    info "위임: ${cmd} $*"
    echo

    # 각 도구의 설치 스크립트에 완전히 맡긴다. 옵션은 그대로 전달.
    # 주의: 인자가 0개일 때 printf '%q ' 는 빈 문자열 인자를 하나 만들어낸다.
    #       그러면 도구가 '' 를 알 수 없는 옵션으로 받는다. 개수를 먼저 본다.
    local rc=0
    if [[ $# -gt 0 ]]; then
        ( cd "$d" && eval "$cmd" "$(printf '%q ' "$@")" ) || rc=$?
    else
        ( cd "$d" && eval "$cmd" ) || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        ok "$title 설치 완료"
    else
        error "$title 설치 실패 (exit $rc)"
    fi
}

cmd_install() {
    local all=false targets=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) all=true; shift ;;
            --)    shift; break ;;
            -*)    error "알 수 없는 옵션: $1" ;;
            *)     targets+=("$1"); shift ;;
        esac
    done
    local passthru=("$@")   # -- 뒤는 도구에게 그대로 넘긴다

    if [[ "$all" == true ]]; then
        local d
        for d in $(discover); do install_one "$d" "${passthru[@]+"${passthru[@]}"}"; done
        return
    fi

    # 인자가 없으면 다중 선택 UI 로 고르게 한다 (run.sh 와 같은 UI)
    if [[ ${#targets[@]} -eq 0 ]]; then
        local avail=() d
        for d in $(discover); do avail+=("$(tool_name "$d")"); done
        [[ ${#avail[@]} -gt 0 ]] || error "도구가 없다"
        pick_tools "설치할 도구를 고르세요 (이미 설치된 것은 갱신된다)" "${avail[@]}" \
            || { info "취소됨"; exit 0; }
        targets=("${PICKED[@]}")
    fi

    local t d
    for t in "${targets[@]}"; do
        d=$(tool_dir "$t") || error "그런 도구가 없다: $t   (./install_tools.sh list)"
        install_one "$d" "${passthru[@]+"${passthru[@]}"}"
    done
}

# ── status / run ───────────────────────────────────────────────────────────
cmd_status() {
    local d cmd name
    for d in $(discover); do
        name="$(field "$d" TOOL_NAME)"; [[ -n "$name" ]] || name="$(basename "$d")"
        is_installed "$d" || continue
        cmd="$(field "$d" TOOL_STATUS)"
        [[ -n "$cmd" ]] || continue
        step "$name"
        ( cd "$d" && eval "$cmd" ) || warn "$name 상태 확인 실패"
    done
}

cmd_run() {
    local t="${1:-}"; shift || true
    [[ -n "$t" ]] || error "사용법: ./install_tools.sh run <도구> <명령...>"
    local d; d=$(tool_dir "$t") || error "그런 도구가 없다: $t"
    local cmd; cmd="$(field "$d" TOOL_RUN)"
    [[ -n "$cmd" ]] || error "$t 에는 TOOL_RUN 이 없다"
    if [[ $# -gt 0 ]]; then
        ( cd "$d" && eval "$cmd" "$(printf '%q ' "$@")" )
    else
        ( cd "$d" && eval "$cmd" )
    fi
}

cmd_help() {
    cat <<EOU
agent_tools 통합 설치

  ./install_tools.sh list                     도구 목록과 설치·실행 상태
  ./install_tools.sh install                  다중 선택해서 설치
  ./install_tools.sh install <도구> [-- 옵션] 설치 (옵션은 도구에 그대로 전달)
  ./install_tools.sh install --all            전부 설치
  ./install_tools.sh status                   설치된 도구 전체 상태
  ./install_tools.sh run <도구> <명령...>      해당 도구의 run 스크립트 호출
  ./install_tools.sh help                     이 도움말

  실행/정지는 통합 실행 스크립트로:
  ./run_tools.sh start                        설치된 도구 다중 선택 후 시작
  ./run_tools.sh stop --all                   전부 정지

예)
  ./install_tools.sh install searxng -- --port 8899
  ./install_tools.sh run searxng test "vllm fp8"

새 도구 추가 — 이 파일은 건드리지 않는다:
  agent_tools/<이름>/tool.manifest 에 최소 두 줄
      TOOL_NAME="<이름>"
      TOOL_INSTALL="./<이름>-install.sh"
EOU
}

case "${1:-list}" in
    list)    shift; cmd_list ;;
    install) shift; cmd_install "$@" ;;
    status)  shift; cmd_status ;;
    run)     shift; cmd_run "$@" ;;
    help|-h|--help) cmd_help ;;
    *)       error "알 수 없는 명령: $1  (./install_tools.sh help)" ;;
esac
