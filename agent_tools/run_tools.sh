#!/usr/bin/env bash
# =============================================================================
# agent_tools 통합 실행 스크립트
#
#   설치된 도구를 **다중 선택**해서 한꺼번에 띄우고 내린다.
#   도구 목록은 하드코딩하지 않는다 — <이름>/tool.manifest 를 발견한다.
#   실제 동작은 각 도구의 TOOL_RUN 스크립트에 위임한다.
#
#   ./run_tools.sh                      대화형 (동작 고르고 → 도구 다중 선택)
#   ./run_tools.sh start                대화형 도구 선택 후 시작
#   ./run_tools.sh start --all          설치된 도구 전부 시작
#   ./run_tools.sh start searxng ...    이름을 직접 지정
#   ./run_tools.sh stop --all           전부 정지 (의존 역순)
#   ./run_tools.sh status | logs | restart
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/_lib.sh"

ACTIONS=(start stop restart status logs)

# ── 한 도구에 동작을 위임 ──────────────────────────────────────────────────
do_one() {
    local name="$1" action="$2"
    local d; d="$(tool_dir "$name")" || { warn "그런 도구가 없다: $name"; return 1; }

    if ! is_installed "$d"; then
        warn "$name: 미설치 — 건너뜀  (./install_tools.sh install $name)"
        return 0
    fi
    local cmd; cmd="$(field "$d" TOOL_RUN)"
    if [[ -z "$cmd" ]]; then
        warn "$name: TOOL_RUN 이 없다 — 건너뜀"
        return 0
    fi

    step "$name : $action"
    ( cd "$d" && eval "$cmd" "$action" )
    local rc=$?
    [[ $rc -eq 0 ]] || warn "$name $action 실패 (exit $rc)"
    return $rc
}

# ── 선택된 도구들에 동작 적용 ──────────────────────────────────────────────
apply() {
    local action="$1"; shift
    local names=("$@")

    # start 는 의존 순서대로, stop 은 그 역순으로
    local ordered=()
    mapfile -t ordered < <(order_by_deps "${names[@]}")
    if [[ "$action" == "stop" ]]; then
        local rev=() i
        for (( i=${#ordered[@]}-1; i>=0; i-- )); do rev+=("${ordered[i]}"); done
        ordered=("${rev[@]}")
    fi

    # logs 는 여러 개를 동시에 따라갈 수 없다 (tail -f 가 블로킹)
    if [[ "$action" == "logs" && ${#ordered[@]} -gt 1 ]]; then
        warn "logs 는 한 번에 하나만 볼 수 있다 — 첫 번째만 연다: ${ordered[0]}"
        ordered=("${ordered[0]}")
    fi

    local failed=0 n
    for n in "${ordered[@]}"; do do_one "$n" "$action" || failed=1; done

    if [[ "$action" != "logs" && "$action" != "status" ]]; then
        echo
        summary
    fi
    return $failed
}

summary() {
    echo -e "${BOLD}── 현재 상태 ────────────────────────────────${NC}"
    local d
    for d in $(discover); do
        is_installed "$d" || continue
        printf "  %-16s %b  %b%s%b\n" "$(tool_name "$d")" "$(state_label "$d")" \
               "$DIM" "$(field "$d" TOOL_HEALTH)" "$NC"
    done
}

installed_names() {
    local d
    # tool_name 은 개행 없이 출력한다(printf 조합용) → 목록화할 때 줄바꿈을 붙인다
    for d in $(discover); do is_installed "$d" && echo "$(tool_name "$d")"; done
}

usage() {
    cat <<EOU
agent_tools 통합 실행

  ./run_tools.sh                        대화형 — 동작 선택 후 도구 다중 선택
  ./run_tools.sh <동작>                 대화형 도구 다중 선택
  ./run_tools.sh <동작> --all           설치된 도구 전부
  ./run_tools.sh <동작> <도구> [도구…]  이름 지정

  동작: ${ACTIONS[*]}

  · start 는 TOOL_REQUIRES 를 보고 선행 도구부터, stop 은 그 역순으로 처리한다
  · logs 는 블로킹이라 한 번에 하나만 연다
  · 각 도구의 고유 명령은 그 도구에 직접:  ./install_tools.sh run searxng test "질의"
EOU
}

# ── 인자 처리 ──────────────────────────────────────────────────────────────
main() {
    local action="" targets=() all=false

    if [[ $# -gt 0 ]]; then
        case "$1" in
            -h|--help|help) usage; exit 0 ;;
            list)           summary; exit 0 ;;
        esac
        printf '%s\n' "${ACTIONS[@]}" | grep -qx "$1" \
            || error "알 수 없는 동작: $1  (${ACTIONS[*]})"
        action="$1"; shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --all|-a) all=true; shift ;;
                *)        targets+=("$1"); shift ;;
            esac
        done
    fi

    local available=()
    mapfile -t available < <(installed_names)
    if [[ ${#available[@]} -eq 0 ]]; then
        warn "설치된 도구가 없다.  ./install_tools.sh list 로 확인하고 설치하라."
        exit 0
    fi

    # 동작이 없으면 물어본다
    if [[ -z "$action" ]]; then
        pick_one "무엇을 할까?" "start   시작" "stop    정지" "restart 재시작" \
                                "status  상태" "logs    로그" \
            || { info "취소됨"; exit 0; }
        action="$PICKED_ONE"
    fi

    # 대상이 없으면 다중 선택
    if [[ ${#targets[@]} -eq 0 ]]; then
        if [[ "$all" == true ]]; then
            targets=("${available[@]}")
        else
            pick_tools "'${action}' 할 도구를 고르세요" "${available[@]}" \
                || { info "선택 없음 — 취소됨"; exit 0; }
            targets=("${PICKED[@]}")
        fi
    fi

    apply "$action" "${targets[@]}"
}

main "$@"
