#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - LLM 에러 로그
# data/logs/errors.jsonl 파일을 조회한다.
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/menu.sh"

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$PROJECT_ROOT/data/logs/errors.jsonl"
COUNT=50
FOLLOW=false

if [ $# -gt 0 ]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n)       COUNT="$2"; shift 2 ;;
      --follow) FOLLOW=true; shift ;;
      -h|--help) head -10 "$0" | tail -7; exit 0 ;;
      *) echo "[ERROR] 알 수 없는 인자: $1"; exit 1 ;;
    esac
  done
fi

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  LLM 에러 로그"
echo " ============================================="
echo ""
echo " [INFO] data/logs/errors.jsonl 파일을 조회합니다."
echo ""

if [ ! -f "$LOG_FILE" ]; then
  echo " [INFO] 에러 로그 없음. 에러 발생 시 자동으로 생성됩니다."
  echo ""
  if $FOLLOW; then
    echo " (대기 중...)"
    while [ ! -f "$LOG_FILE" ]; do sleep 2; done
  else
    exit 0
  fi
fi

format_entry() {
  python3 -c "
import sys, json
try:
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            ts = e.get('timestamp', '')
            user = e.get('user', '')
            question = e.get('question', '')
            error = e.get('error', '')
            lat = e.get('latency_sec')
            print(f' [Requested at: {ts}]')
            print(f'   User: {user}')
            if question: print(f'   Question: {question[:120]}')
            print(f'   Error: {error}')
            if lat is not None: print(f'   Latency: {lat}s')
            print()
        except:
            pass
except (KeyboardInterrupt, BrokenPipeError):
    pass
"
}

# 인자 없이 실행 시 대화형 메뉴
if [ "$COUNT" -eq 50 ] && [ "$FOLLOW" = false ] && [ -f "$LOG_FILE" ]; then
  echo " 조회 방식을 선택하세요:"
  echo ""
  select_menu _SEL \
    "최근 50건 조회" \
    "건수 지정 조회" \
    "실시간 모니터링"
  case "$_SEL" in
    1)
      printf "\n 조회 건수: "
      read -r _COUNT
      COUNT="${_COUNT:-50}"
      ;;
    2) FOLLOW=true ;;
    *) ;;
  esac
  echo ""
fi

if $FOLLOW; then
  tail -f "$LOG_FILE" | format_entry
else
  tail -n "$COUNT" "$LOG_FILE" | format_entry
fi
