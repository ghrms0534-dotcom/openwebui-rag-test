#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 데이터 백업
# Qdrant 벡터 DB + PostgreSQL 메타데이터 + LLM 쿼리 로그를 백업한다.
# ============================================

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"
DATE=$(date +%Y%m%d_%H%M%S)
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"

mkdir -p "$BACKUP_DIR"

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

shopt -s checkwinsize
_COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}
_SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
_SIDX=0
_SC=" "

tick_spin() { _SC="${_SPIN:$((_SIDX % ${#_SPIN})):1}"; _SIDX=$((_SIDX + 1)); }

show_progress() {
  local pct=$1 step_label="$2" detail="${3:-}" icon="${4:-$_SC}"
  _COLS=${COLUMNS:-120}
  local bar_len=20 filled=$((pct * 20 / 100)) empty=$((20 - pct * 20 / 100))
  local bar=""
  [ "$filled" -gt 0 ] && bar=$(printf '%0.s█' $(seq 1 $filled))
  [ "$empty"  -gt 0 ] && bar="${bar}$(printf '%0.s░' $(seq 1 $empty))"
  local text; [ -n "$detail" ] && text="$step_label — $detail" || text="$step_label"
  local max_text=$(( _COLS - 32 )); [ "$max_text" -lt 5 ] && max_text=5
  text="${text:0:$max_text}"
  printf "\r\033[2K  %s [%3d%%] %s %s" "$icon" "$pct" "$bar" "$text"
}

step_done() { show_progress 100 "$1" "${2:-}" "✓"; printf "\n"; }

# ============================================
echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  데이터 백업"
echo " ============================================="
echo ""
echo " [INFO] Qdrant(문서 임베딩), PostgreSQL(채팅·사용자·설정), 에러 로그를 백업합니다."
echo ""

# ============================================
# 서비스 상태 사전 확인
# ============================================
_QDRANT_UP=false
_POSTGRES_UP=false

_CID=$(docker compose -f "$COMPOSE_FILE" ps -q qdrant 2>/dev/null | head -1 || echo "")
[ -n "$_CID" ] && [ "$(docker inspect "$_CID" --format='{{.State.Status}}' 2>/dev/null)" = "running" ] && _QDRANT_UP=true

_CID=$(docker compose -f "$COMPOSE_FILE" ps -q postgres 2>/dev/null | head -1 || echo "")
[ -n "$_CID" ] && [ "$(docker inspect "$_CID" --format='{{.State.Status}}' 2>/dev/null)" = "running" ] && _POSTGRES_UP=true

if ! $_QDRANT_UP || ! $_POSTGRES_UP; then
  ! $_QDRANT_UP  && echo " [ERROR] Qdrant(문서 임베딩) 컨테이너가 실행 중이지 않습니다."
  ! $_POSTGRES_UP && echo " [ERROR] PostgreSQL(채팅·사용자·설정) 컨테이너가 실행 중이지 않습니다."
  echo ""
  echo " 백업을 중단합니다. 먼저 서비스를 시작하세요: ./scripts/start.sh"
  exit 1
fi

# ============================================
# Step 1/3: Qdrant 백업 (0% → 33%)
# ============================================
QDRANT_CID=$(docker compose -f "$COMPOSE_FILE" ps -q qdrant 2>/dev/null | head -1 || echo "")
if [ -n "$QDRANT_CID" ]; then
  docker run --rm \
    --volumes-from "$QDRANT_CID" \
    -v "$BACKUP_DIR":/backup \
    alpine \
    tar czf "/backup/qdrant-${DATE}.tar.gz" /qdrant/storage &>/dev/null &
  _PID=$!
  _ok=true
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress 50 "[1/3] Qdrant(문서 임베딩) 백업 중..." "" "$_SC"; sleep 0.1
  done
  wait "$_PID" || _ok=false
  if $_ok; then
    step_done "[1/3] Qdrant(문서 임베딩) 백업" "qdrant-${DATE}.tar.gz"
  else
    step_done "[1/3] Qdrant(문서 임베딩) 백업" "[WARN] 실패"
  fi
else
  step_done "[1/3] Qdrant(문서 임베딩) 백업" "[WARN] 컨테이너 없음 (건너뜀)"
fi

# ============================================
# Step 2/3: PostgreSQL 백업 (33% → 66%)
# ============================================
_PG_FILE="$BACKUP_DIR/postgres-${DATE}.sql"
docker compose -f "$COMPOSE_FILE" exec -T postgres \
  pg_dump -U openwebui openwebui \
  > "$_PG_FILE" &
_PID=$!
_ok=true
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin; show_progress 50 "[2/3] PostgreSQL(채팅·사용자·설정) 백업 중..." "pg_dump" "$_SC"; sleep 0.1
done
wait "$_PID" || _ok=false
if $_ok && [ -s "$_PG_FILE" ]; then
  step_done "[2/3] PostgreSQL(채팅·사용자·설정) 백업" "postgres-${DATE}.sql"
else
  # 실패 시 0바이트 파일 정리
  rm -f "$_PG_FILE"
  step_done "[2/3] PostgreSQL(채팅·사용자·설정) 백업" "[WARN] 실패 (서비스 실행 중인지 확인)"
fi

# ============================================
# Step 3/3: 에러 로그 백업 (66% → 100%)
# - LLM 질의응답 데이터는 PostgreSQL에 포함 (Step 2에서 백업됨)
# ============================================
LOG_DIR="$PROJECT_ROOT/data/logs"
if [ -d "$LOG_DIR" ] && ls "$LOG_DIR"/*.jsonl &>/dev/null; then
  tar czf "$BACKUP_DIR/error-logs-${DATE}.tar.gz" -C "$(dirname "$LOG_DIR")" logs &>/dev/null &
  _PID=$!
  _ok=true
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress 50 "[3/3] 에러 로그 백업 중..." "" "$_SC"; sleep 0.1
  done
  wait "$_PID" || _ok=false
  if $_ok; then
    step_done "[3/3] 에러 로그 백업" "error-logs-${DATE}.tar.gz"
  else
    step_done "[3/3] 에러 로그 백업" "[WARN] 실패"
  fi
else
  step_done "[3/3] 에러 로그 백업" "에러 없음 (정상)"
fi

printf "\n"
echo " ▶▶ 백업 완료"
echo " 경로: $BACKUP_DIR"
echo ""

# 오래된 백업 정리 (30일 이상)
find "$BACKUP_DIR" -name "qdrant-*.tar.gz" -mtime +30 -delete 2>/dev/null && true
find "$BACKUP_DIR" -name "postgres-*.sql" -mtime +30 -delete 2>/dev/null && true
find "$BACKUP_DIR" -name "error-logs-*.tar.gz" -mtime +30 -delete 2>/dev/null && true
