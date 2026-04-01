#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 자동 백업 cron 설정
# 매일 03:00에 자동 백업을 실행하는 cron 작업을 관리한다.
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/menu.sh"

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"
CRON_LOG="$PROJECT_ROOT/backups/cron.log"
CRON_TAG="# iteyes-openwebui-rag-backup"
CRON_SCHEDULE="0 3 * * *"

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  자동 백업 설정"
echo " ============================================="
echo ""
echo " [INFO] 매일 03:00에 자동 백업을 실행하는 cron 작업을 관리합니다."
echo ""

show_current() {
  echo ""
  echo " [INFO] 현재 등록된 백업 cron:"
  echo ""
  if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
    crontab -l 2>/dev/null | grep "$CRON_TAG" -B0
    echo ""

    # 마지막 백업 확인
    if [ -d "$PROJECT_ROOT/backups" ]; then
      LATEST=$(ls -t "$PROJECT_ROOT/backups"/postgres-*.sql 2>/dev/null | head -1 || true)
      if [ -n "$LATEST" ]; then
        echo ""
        echo " [INFO] 마지막 백업: $(basename "$LATEST")"
        echo ""
      fi
    fi
  else
    echo "  (등록된 백업 cron 없음)"
  fi
}

run_action() {
  local action="$1"
  case "$action" in
    --status|-s)
      show_current
      ;;

    --remove|-r)
      if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        (crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true) | crontab -
        echo " ▶▶ 자동 백업 cron 제거 완료"
      else
        echo ""
        echo " [INFO] 등록된 백업 cron이 없습니다."
        echo ""
      fi
      ;;

    install|--install|-i|"")
      if ! command -v crontab &>/dev/null; then
        echo "[ERROR] crontab이 설치되어 있지 않습니다."
        return 1
      fi

      if [ ! -x "$BACKUP_SCRIPT" ]; then
        echo "[ERROR] backup.sh를 찾을 수 없거나 실행 권한이 없습니다: $BACKUP_SCRIPT"
        return 1
      fi

      if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        echo ""
        echo " [INFO] 이미 등록된 백업 cron이 있습니다."
        echo ""
        show_current
        echo ""
        echo " 제거 후 재등록하려면: $0 --remove && $0"
        return 0
      fi

      mkdir -p "$PROJECT_ROOT/backups"

      CRON_ENTRY="$CRON_SCHEDULE cd $PROJECT_ROOT && ./scripts/backup.sh >> $CRON_LOG 2>&1 $CRON_TAG"
      (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -

      echo " ▶▶ 자동 백업 cron 등록 완료"
      echo ""
      echo " 스케줄:    매일 03:00"
      echo " 스크립트:  $BACKUP_SCRIPT"
      echo " 로그:      $CRON_LOG"
      echo ""
      echo " 상태 확인: ./scripts/setup-cron.sh --status"
      echo " 제거:      ./scripts/setup-cron.sh --remove"
      ;;

    -h|--help)
      head -9 "$0" | tail -6
      ;;

    *)
      echo "Usage: $0 [--status|--remove|--help]"
      return 1
      ;;
  esac
}

# 인수 있으면 바로 실행 후 종료 (start.sh 등 스크립트 호출용)
if [ -n "${1:-}" ]; then
  run_action "$1"
  exit $?
fi

# 인수 없으면 대화형 루프
while true; do
  echo " 작업을 선택하세요:"
  echo ""
  select_menu _SEL \
    "매일 03:00 자동 백업 cron 등록" \
    "현재 cron 등록 상태 확인" \
    "자동 백업 cron 제거" \
    "종료"
  echo ""

  case "$_SEL" in
    0) run_action "install" ;;
    1) run_action "--status" ;;
    2) run_action "--remove" ;;
    3) break ;;
  esac

  echo ""
done
