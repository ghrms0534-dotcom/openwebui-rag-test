#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 시스템 상태
# 컨테이너, LLM 백엔드, DB, 디스크, 웹 접근 상태를 확인한다.
# ============================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"
BACKUP_DIR="$PROJECT_ROOT/backups"
WATCH_INTERVAL=5

# --watch 옵션 처리
ONCE=false
for arg in "$@"; do
  case "$arg" in
    --once) ONCE=true ;;
  esac
done

if ! $ONCE; then
  while true; do
    OUTPUT=$(bash "${BASH_SOURCE[0]}" --once 2>/dev/null)
    clear
    echo "$OUTPUT"
    echo ""
    echo " 갱신 주기: ${WATCH_INTERVAL}초"
    sleep "$WATCH_INTERVAL"
  done
  exit 0
fi

# ENV_FILE 감지 (docker compose exec에 필요, airgap 우선)
if [ -f "$PROJECT_ROOT/config/env/airgap.env" ]; then
  export ENV_FILE="airgap"
elif [ -f "$PROJECT_ROOT/config/env/local.env" ]; then
  export ENV_FILE="local"
fi

# PostgreSQL 비밀번호 로드
for ENV_CANDIDATE in "$PROJECT_ROOT/config/env/local.env" "$PROJECT_ROOT/config/env/airgap.env"; do
  if [ -f "$ENV_CANDIDATE" ]; then
    POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' "$ENV_CANDIDATE" 2>/dev/null | cut -d= -f2 || echo "openwebui")
    break
  fi
done
export PGPASSWORD="${POSTGRES_PASSWORD:-openwebui}"

# 색상 (터미널 지원 시만 적용)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  DIM='\033[0;90m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' DIM='' NC=''
fi

OK="${GREEN}●${NC}"
FAIL="${RED}○${NC}"
WARN="${YELLOW}●${NC}"

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  System Status"
echo " ============================================="
echo ""
echo " [INFO] 컨테이너, LLM 백엔드, DB, 디스크, 웹 접근 상태를 확인합니다."
echo ""

# ============================================
# 1. 컨테이너 상태
# ============================================
echo " [Services]"
SERVICES=(open-webui postgres qdrant tika nginx)
ALL_RUNNING=true

for SVC in "${SERVICES[@]}"; do
  CID=$(docker compose -f "$COMPOSE_FILE" ps -q "$SVC" 2>/dev/null || echo "")
  if [ -z "$CID" ]; then
    printf "  ${FAIL} %-14s Stopped\n" "$SVC"
    ALL_RUNNING=false
    continue
  fi

  STATUS=$(docker inspect "$CID" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
  HEALTH=$(docker inspect "$CID" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' 2>/dev/null || echo "")
  MEM=$(docker stats "$CID" --no-stream --format='{{.MemUsage}}' 2>/dev/null | awk '{print $1}' || echo "?")

  if [ "$STATUS" = "running" ]; then
    if [ "$HEALTH" = "healthy" ]; then
      printf "  ${OK} %-14s Running (healthy)     mem: %s\n" "$SVC" "$MEM"
    elif [ "$HEALTH" = "starting" ]; then
      printf "  ${WARN} %-14s Running (starting)    mem: %s\n" "$SVC" "$MEM"
    elif [ "$HEALTH" = "unhealthy" ]; then
      printf "  ${FAIL} %-14s Running (unhealthy)   mem: %s\n" "$SVC" "$MEM"
    else
      printf "  ${OK} %-14s Running               mem: %s\n" "$SVC" "$MEM"
    fi
  else
    printf "  ${FAIL} %-14s %s\n" "$SVC" "$STATUS"
    ALL_RUNNING=false
  fi
done
echo ""

# ============================================
# 2. LLM 백엔드
# ============================================
echo " [LLM Backend]"

if bash -c ':>/dev/tcp/localhost/8000' 2>/dev/null; then
  printf "  ${OK} vLLM (8000)      Connected\n"
else
  printf "  ${FAIL} vLLM (8000)      Not detected\n"
fi

if bash -c ':>/dev/tcp/localhost/11434' 2>/dev/null; then
  printf "  ${OK} Ollama (11434)   Connected\n"
else
  printf "  ${FAIL} Ollama (11434)   Not detected\n"
fi
echo ""

# ============================================
# 3. Database
# ============================================
echo " [Database]"
if [ "$ALL_RUNNING" = true ] || docker compose -f "$COMPOSE_FILE" ps -q postgres &>/dev/null; then
  DB_SIZE=$(docker compose -f "$COMPOSE_FILE" exec -T postgres \
    psql -U openwebui -d openwebui -tAc "SELECT pg_size_pretty(pg_database_size('openwebui'))" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [ -n "$DB_SIZE" ]; then
    printf "  ${OK} PostgreSQL       Connected    size: %s\n" "$DB_SIZE"
  else
    printf "  ${FAIL} PostgreSQL       Connection failed\n"
  fi
else
  printf "  ${FAIL} PostgreSQL       Not running\n"
fi
echo ""

# ============================================
# 4. 디스크 사용량
# ============================================
echo " [Disk Usage]"
# docker system df -v 출력에서 VOLUME NAME 헤더 이후 행만 추출, 프로젝트 볼륨 필터링
declare -A VOL_SIZES
while IFS= read -r line; do
  VOL_NAME=$(echo "$line" | awk '{print $1}')
  VOL_SIZE=$(echo "$line" | awk '{print $3}')
  VOL_SIZES["$VOL_NAME"]="$VOL_SIZE"
done < <(docker system df -v 2>/dev/null | awk '/^VOLUME NAME/,0 { if (NR>1 && NF>=3) print }' | grep "iteyes-openwebui-rag_")

for VOL in open-webui postgres qdrant; do
  FULL="iteyes-openwebui-rag_${VOL}"
  SIZE="${VOL_SIZES[$FULL]:-?}"
  printf "  %-20s %s\n" "$VOL volume" "$SIZE"
done

if [ -d "$BACKUP_DIR" ]; then
  BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}' || echo "0")
  BACKUP_COUNT=$(find "$BACKUP_DIR" -name "postgres-*.sql" 2>/dev/null | wc -l || echo "0")
  printf "  %-20s %s (%s backups)\n" "backups/" "$BACKUP_SIZE" "$BACKUP_COUNT"
else
  printf "  %-20s (없음)\n" "backups/"
fi
echo ""

# ============================================
# 5. 웹 접근
# ============================================
echo " [Web Access]"
for URL in "http://localhost:3000" "http://localhost"; do
  HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 3 "$URL" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    printf "  ${OK} %-28s OK (%s)\n" "$URL" "$HTTP_CODE"
  else
    printf "  ${FAIL} %-28s Failed (%s)\n" "$URL" "$HTTP_CODE"
  fi
done
echo ""

# ============================================
# 6. 마지막 백업
# ============================================
echo " [Last Backup]"
if [ -d "$BACKUP_DIR" ]; then
  LATEST=$(ls -t "$BACKUP_DIR"/postgres-*.sql 2>/dev/null | head -1 || true)
  if [ -n "$LATEST" ]; then
    BACKUP_DATE=$(basename "$LATEST" | sed 's/postgres-//;s/\.sql//')
    # YYYYMMDD_HHMMSS → YYYY-MM-DD HH:MM:SS 변환
    FORMATTED=$(echo "$BACKUP_DATE" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
    BACKUP_TS=$(date -d "${FORMATTED}" +%s 2>/dev/null || echo "0")
    NOW_TS=$(date +%s)
    if [ "$BACKUP_TS" -gt 0 ]; then
      SECS_AGO=$(( NOW_TS - BACKUP_TS ))
      if [ "$SECS_AGO" -lt 3600 ]; then
        printf "  ${OK} %s (%s분 전)\n" "$FORMATTED" "$(( SECS_AGO / 60 ))"
      elif [ "$SECS_AGO" -lt 86400 ]; then
        printf "  ${OK} %s (%s시간 전)\n" "$FORMATTED" "$(( SECS_AGO / 3600 ))"
      else
        printf "  ${OK} %s (%s일 전)\n" "$FORMATTED" "$(( SECS_AGO / 86400 ))"
      fi
    else
      printf "  ${OK} %s\n" "$FORMATTED"
    fi
  else
    printf "  ${FAIL} 백업 없음\n"
  fi
else
  printf "  ${FAIL} backups/ 디렉토리 없음\n"
fi
echo ""
