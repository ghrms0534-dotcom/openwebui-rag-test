#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 대화형 메뉴 유틸리티
# 화살표 키로 선택하는 메뉴와 입력 프롬프트를 제공한다.
# ============================================

# Ctrl+C 시 커서 복원
_menu_cleanup() { printf "\033[?25h"; exit 130; }

# 화살표 키 선택 메뉴
# 사용법: select_menu RESULT_VAR "옵션1" "옵션2" ...
# 결과: 0부터 시작하는 선택 인덱스가 RESULT_VAR에 저장됨
select_menu() {
  local _var="$1"; shift
  local _default=0
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then _default="$1"; shift; fi
  local _opts=("$@")
  local _cnt=${#_opts[@]}
  local _sel=$_default _key

  trap '_menu_cleanup' INT

  # 커서 숨김
  printf "\033[?25l"

  # 메뉴 그리기
  _draw() {
    for _i in "${!_opts[@]}"; do
      printf "\033[2K"
      if [ "$_i" -eq "$_sel" ]; then
        printf "   \033[36m▶ %s\033[0m\n" "${_opts[$_i]}"
      else
        printf "     %s\n" "${_opts[$_i]}"
      fi
    done
  }

  _draw

  while true; do
    IFS= read -rsn1 _key
    case "$_key" in
      $'\x1b')
        read -rsn2 _key
        case "$_key" in
          '[A') if (( _sel > 0 )); then _sel=$(( _sel - 1 )); fi ;;
          '[B') if (( _sel < _cnt - 1 )); then _sel=$(( _sel + 1 )); fi ;;
        esac
        ;;
      '') break ;;   # Enter
    esac
    # 커서를 메뉴 시작 위치로 되돌린 뒤 다시 그림
    printf "\033[%dA" "$_cnt"
    _draw
  done

  # 커서 복원
  printf "\033[?25h"
  trap - INT

  eval "$_var=$_sel"
}
