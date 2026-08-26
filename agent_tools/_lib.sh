#!/usr/bin/env bash
# =============================================================================
# agent_tools 공용 라이브러리 — install.sh 와 run.sh 가 함께 쓴다.
#
#   · 매니페스트 발견/파싱   (도구 목록은 어디에도 하드코딩하지 않는다)
#   · 설치·실행 상태 판정
#   · 의존 순서 정렬
#   · 다중 선택 UI (방향키 TUI + 숫자 입력 폴백)
#
# 새 도구 추가는 여전히 <이름>/tool.manifest 한 장이면 된다.
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo; echo -e "${BOLD}▶ $*${NC}"; echo "──────────────────────────────────"; }

# ── 매니페스트 ─────────────────────────────────────────────────────────────
discover() {
    local d
    for d in "$ROOT"/*/; do
        [[ -f "${d}tool.manifest" ]] && echo "${d%/}"
    done
}

# 매니페스트를 서브셸에서 읽어 필드 하나만 출력 (현재 셸을 오염시키지 않는다)
field() {
    local dir="$1" key="$2"
    (
        set +u
        # shellcheck disable=SC1090
        . "$dir/tool.manifest" 2>/dev/null || exit 0
        printf '%s' "${!key:-}"
    )
}

tool_name() {
    local n; n="$(field "$1" TOOL_NAME)"
    [[ -n "$n" ]] || n="$(basename "$1")"
    printf '%s' "$n"
}

tool_dir() {
    local name="$1" d
    for d in $(discover); do
        [[ "$(tool_name "$d")" == "$name" ]] && { echo "$d"; return 0; }
    done
    return 1
}

is_installed() {
    local d="$1"
    [[ -d "$d/.venv" || -d "$d/node_modules" || -f "$d/.installed" ]]
}

is_up() {
    local url; url="$(field "$1" TOOL_HEALTH)"
    [[ -n "$url" ]] || return 1
    curl -sf --max-time 2 -o /dev/null "$url" 2>/dev/null
}

# 사람이 읽는 상태 문자열
state_label() {
    local d="$1"
    if ! is_installed "$d"; then printf '%b' "${DIM}미설치${NC}"
    elif is_up "$d";       then printf '%b' "${GREEN}실행중${NC}"
    else                        printf '%b' "${YELLOW}정지됨${NC}"
    fi
}

# ── 의존 순서 ──────────────────────────────────────────────────────────────
# TOOL_REQUIRES 를 보고 선행 도구가 앞에 오도록 정렬한다.
# 순환이 있으면 남은 것을 원래 순서대로 뒤에 붙인다(멈추지 않는다).
order_by_deps() {
    local pending=("$@") done_list=() out=() progressed=1
    while [[ ${#pending[@]} -gt 0 && $progressed -eq 1 ]]; do
        progressed=0
        local rest=() n d req satisfied
        for n in "${pending[@]}"; do
            d="$(tool_dir "$n")" || { out+=("$n"); progressed=1; continue; }
            satisfied=1
            for req in $(field "$d" TOOL_REQUIRES); do
                # 선택 목록 안에 있는 선행 도구만 따진다
                if printf '%s\n' "${pending[@]}" | grep -qx "$req" \
                   && ! printf '%s\n' "${done_list[@]+"${done_list[@]}"}" | grep -qx "$req"; then
                    satisfied=0; break
                fi
            done
            if [[ $satisfied -eq 1 ]]; then
                out+=("$n"); done_list+=("$n"); progressed=1
            else
                rest+=("$n")
            fi
        done
        pending=("${rest[@]+"${rest[@]}"}")
    done
    out+=("${pending[@]+"${pending[@]}"}")
    printf '%s\n' "${out[@]+"${out[@]}"}"
}

# ── 다중 선택 UI ───────────────────────────────────────────────────────────
# 사용법:  pick_tools "제목" <후보 이름들...>
#          선택 결과는 전역 배열 PICKED 에 담긴다.
#
# 진짜 터미널이면 방향키 TUI, 아니면 숫자 입력 폴백.
# 폴백이 있어야 파이프·CI·TERM=dumb 에서도 쓸 수 있다.
PICKED=()

_pick_tty_capable() {
    [[ -t 0 && -t 1 ]] || return 1
    [[ -n "${TERM:-}" && "$TERM" != "dumb" ]] || return 1
    return 0
}

pick_tools() {
    local title="$1"; shift
    local names=("$@")
    PICKED=()
    [[ ${#names[@]} -gt 0 ]] || return 1

    if _pick_tty_capable; then _pick_interactive "$title" "${names[@]}"
    else _pick_numeric "$title" "${names[@]}"; fi
}

# 방향키 TUI — ↑↓ 이동, Space 토글, a 전체, n 해제, Enter 확정, q 취소
_pick_interactive() {
    local title="$1"; shift
    local names=("$@") n=${#} cur=0 i key
    local -a sel; for ((i=0;i<n;i++)); do sel[i]=1; done   # 기본 전체 선택

    printf '\n  %b%s%b\n' "$BOLD" "$title" "$NC"
    printf '  %b↑↓ 이동 · Space 토글 · a 전체 · n 해제 · Enter 확정 · q 취소%b\n\n' "$DIM" "$NC"
    tput civis 2>/dev/null || true

    _draw() {
        local j d mark line
        for ((j=0;j<n;j++)); do
            d="$(tool_dir "${names[j]}")"
            [[ ${sel[j]} -eq 1 ]] && mark="${GREEN}◉${NC}" || mark="${DIM}◯${NC}"
            line=$(printf "  %b %b %-16s %b  %b%s%b" \
                   "$([[ $j -eq $cur ]] && printf '%b▸%b' "$BOLD" "$NC" || printf ' ')" \
                   "$mark" "${names[j]}" "$(state_label "$d")" \
                   "$DIM" "$(field "$d" TOOL_DESC)" "$NC")
            printf '\033[2K%b\n' "$line"
        done
    }
    _draw
    while true; do
        IFS= read -rsn1 key || break
        if [[ $key == $'\e' ]]; then
            read -rsn2 -t 0.05 key || key=""
            case "$key" in
                '[A') ((cur = (cur - 1 + n) % n)) ;;
                '[B') ((cur = (cur + 1) % n)) ;;
            esac
        else
            case "$key" in
                ' ') sel[cur]=$(( 1 - sel[cur] )) ;;
                k|K) ((cur = (cur - 1 + n) % n)) ;;
                j|J) ((cur = (cur + 1) % n)) ;;
                a|A) for ((i=0;i<n;i++)); do sel[i]=1; done ;;
                n|N) for ((i=0;i<n;i++)); do sel[i]=0; done ;;
                q|Q) tput cnorm 2>/dev/null || true; echo; return 1 ;;
                '')  break ;;
            esac
        fi
        printf '\033[%dA' "$n"
        _draw
    done
    tput cnorm 2>/dev/null || true
    for ((i=0;i<n;i++)); do [[ ${sel[i]} -eq 1 ]] && PICKED+=("${names[i]}"); done
    echo
    [[ ${#PICKED[@]} -gt 0 ]]
}

# 숫자 입력 폴백 — "1 3" / "1,3" / "a"(전체) / 빈 입력(전체) / "q"(취소)
_pick_numeric() {
    local title="$1"; shift
    local names=("$@") n=${#} i d
    printf '\n  %b%s%b\n\n' "$BOLD" "$title" "$NC"
    for ((i=0;i<n;i++)); do
        d="$(tool_dir "${names[i]}")"
        printf "  %2d) %-16s %b  %b%s%b\n" "$((i+1))" "${names[i]}" \
               "$(state_label "$d")" "$DIM" "$(field "$d" TOOL_DESC)" "$NC"
    done
    echo
    local ans
    read -rp "  번호 선택 (공백/쉼표 구분, a=전체, Enter=전체, q=취소): " ans || ans="a"
    ans="${ans//,/ }"
    case "${ans,,}" in
        q) return 1 ;;
        ''|a|all) PICKED=("${names[@]}"); return 0 ;;
    esac
    local t
    for t in $ans; do
        [[ "$t" =~ ^[0-9]+$ ]] || { warn "숫자가 아닌 입력 무시: $t"; continue; }
        (( t >= 1 && t <= n )) || { warn "범위 밖 무시: $t"; continue; }
        PICKED+=("${names[t-1]}")
    done
    [[ ${#PICKED[@]} -gt 0 ]]
}

# 단일 선택 (동작 고르기용)
PICKED_ONE=""
pick_one() {
    local title="$1"; shift
    local opts=("$@") i
    PICKED_ONE=""
    printf '\n  %b%s%b\n\n' "$BOLD" "$title" "$NC"
    for ((i=0;i<${#opts[@]};i++)); do printf "  %2d) %s\n" "$((i+1))" "${opts[i]}"; done
    echo
    local ans; read -rp "  번호 [1]: " ans || ans=1
    [[ -n "$ans" ]] || ans=1
    [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )) || return 1
    PICKED_ONE="${opts[ans-1]%% *}"   # "start  시작" → "start"
    return 0
}
