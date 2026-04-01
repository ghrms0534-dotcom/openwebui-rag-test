#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 데이터 복원
# Qdrant 벡터 DB + PostgreSQL 메타데이터를 복원한다.
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/menu.sh"

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_ROOT/backups"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"

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
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-openwebui}"
export PGPASSWORD="$POSTGRES_PASSWORD"

# WSL2 + Docker Desktop: docker-credential-desktop.exe 우회
TEMP_DOCKER_CONFIG=""
if grep -qi microsoft /proc/version 2>/dev/null && \
   [ -f "$HOME/.docker/config.json" ] && grep -q '"credsStore"' "$HOME/.docker/config.json" 2>/dev/null; then
  TEMP_DOCKER_CONFIG=$(mktemp -d)
  python3 -c "
import json
with open('$HOME/.docker/config.json') as f: cfg = json.load(f)
cfg.pop('credsStore', None)
with open('$TEMP_DOCKER_CONFIG/config.json', 'w') as f: json.dump(cfg, f, indent=2)
"
  export DOCKER_CONFIG="$TEMP_DOCKER_CONFIG"
fi
cleanup() { [ -n "$TEMP_DOCKER_CONFIG" ] && [ -d "$TEMP_DOCKER_CONFIG" ] && rm -rf "$TEMP_DOCKER_CONFIG"; }
trap cleanup EXIT

RESTORE_DATE="${1:-}"

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

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  데이터 복원"
echo " ============================================="
echo ""
echo " [INFO] 백업 파일에서 Qdrant(문서 임베딩)와 PostgreSQL(채팅·사용자·설정) 데이터를 복원합니다."
echo ""

# ============================================
# 백업 날짜 결정
# ============================================
if [ -z "$RESTORE_DATE" ]; then
  # postgres + qdrant 둘 다 있는 날짜만 수집 (최신순)
  DATES=()
  while IFS= read -r f; do
    _D="$(basename "$f" | sed 's/postgres-//;s/\.sql//')"
    [ -f "$BACKUP_DIR/qdrant-${_D}.tar.gz" ] && DATES+=("$_D")
  done < <(ls -t "$BACKUP_DIR"/postgres-*.sql 2>/dev/null)

  if [ ${#DATES[@]} -eq 0 ]; then
    echo " [ERROR] 유효한 백업 없음 (Qdrant(문서 임베딩) + PostgreSQL(채팅·사용자·설정) 세트가 필요합니다)"
    echo "         백업 위치: $BACKUP_DIR"
    exit 1
  fi

  # YYYYMMDD_HHMMSS → YYYY-MM-DD HH:MM:SS 형식으로 표시용 변환
  DISPLAY_DATES=()
  for _D in "${DATES[@]}"; do
    DISPLAY_DATES+=("$(echo "$_D" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')")
  done

  if [ ${#DATES[@]} -eq 1 ]; then
    RESTORE_DATE="${DATES[0]}"
    echo " 백업 1개 발견: ${DISPLAY_DATES[0]}"
  else
    echo " 복원할 백업을 선택하세요:"
    echo ""
    select_menu _SEL "${DISPLAY_DATES[@]}"
    RESTORE_DATE="${DATES[$_SEL]}"
  fi
  echo ""
fi

QDRANT_FILE="$BACKUP_DIR/qdrant-${RESTORE_DATE}.tar.gz"
POSTGRES_FILE="$BACKUP_DIR/postgres-${RESTORE_DATE}.sql"

MISSING=0
[ ! -f "$QDRANT_FILE" ]   && echo "[ERROR] Qdrant(문서 임베딩) 백업 없음: $QDRANT_FILE"   && MISSING=1
[ ! -f "$POSTGRES_FILE" ] && echo "[ERROR] PostgreSQL(채팅·사용자·설정) 백업 없음: $POSTGRES_FILE" && MISSING=1
if [ "$MISSING" -eq 1 ]; then
  echo ""
  echo "사용 가능한 백업:"
  ls -lh "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.sql 2>/dev/null | tail -10
  exit 1
fi

echo " 복원 대상: $RESTORE_DATE"
echo ""
echo " [WARN] 복원 시 현재 데이터가 덮어쓰기됩니다!"
printf " 계속하시겠습니까? (y/N) "
read -r CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo " [INFO] 복원 취소됨"
  exit 0
fi
echo ""

# ============================================
# Step 1/4: 서비스 중지 (0% → 25%)
# ============================================
docker compose -f "$COMPOSE_FILE" down &>/dev/null &
_PID=$!
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin; show_progress 50 "[1/4] 서비스 중지 중..." "docker compose down" "$_SC"; sleep 0.1
done
wait "$_PID"
step_done "[1/4] 서비스 중지" "완료"

# ============================================
# Step 2/4: PostgreSQL 복원 (25% → 60%)
# ============================================
# PostgreSQL 단독 시작
docker compose -f "$COMPOSE_FILE" up -d postgres &>/dev/null &
_PID=$!
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin; show_progress 10 "[2/4] PostgreSQL(채팅·사용자·설정) 시작 중..." "" "$_SC"; sleep 0.1
done
wait "$_PID"

# PostgreSQL 준비 대기
show_progress 20 "[2/4] PostgreSQL(채팅·사용자·설정) 준비 대기 중..." "" " "
for i in $(seq 1 30); do
  if docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U openwebui -d openwebui &>/dev/null; then
    break
  fi
  tick_spin; show_progress 20 "[2/4] PostgreSQL(채팅·사용자·설정) 준비 대기 중..." "${i}s" "$_SC"; sleep 1
done

# 스키마 초기화 + 복원
docker compose -f "$COMPOSE_FILE" exec -T postgres \
  psql -U openwebui -d openwebui -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" &>/dev/null &
_PID=$!
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin; show_progress 40 "[2/4] PostgreSQL(채팅·사용자·설정) 스키마 초기화 중..." "" "$_SC"; sleep 0.1
done
wait "$_PID"

docker compose -f "$COMPOSE_FILE" exec -T postgres \
  psql -U openwebui -d openwebui < "$POSTGRES_FILE" &>/dev/null &
_PID=$!
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin; show_progress 70 "[2/4] PostgreSQL(채팅·사용자·설정) 복원 중..." "psql restore" "$_SC"; sleep 0.1
done
wait "$_PID"

docker compose -f "$COMPOSE_FILE" down &>/dev/null &
_PID=$!
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin; show_progress 90 "[2/4] PostgreSQL(채팅·사용자·설정) 중지 중..." "" "$_SC"; sleep 0.1
done
wait "$_PID"
step_done "[2/4] PostgreSQL(채팅·사용자·설정) 복원" "완료"

# ============================================
# Step 3/4: Qdrant 복원 (60% → 90%)
# ============================================
QDRANT_VOLUME="iteyes-openwebui-rag_qdrant"
docker run --rm \
  -v "$QDRANT_VOLUME":/qdrant/storage \
  -v "$BACKUP_DIR":/backup \
  alpine \
  sh -c "rm -rf /qdrant/storage/* && tar xzf /backup/qdrant-${RESTORE_DATE}.tar.gz -C / --strip-components=0" \
  &>/dev/null &
_PID=$!
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin; show_progress 50 "[3/4] Qdrant(문서 임베딩) 복원 중..." "" "$_SC"; sleep 0.1
done
wait "$_PID"
step_done "[3/4] Qdrant(문서 임베딩) 복원" "완료"

# ============================================
# Step 4/4: 완료
# ============================================
step_done "[4/4] 복원 완료" "$RESTORE_DATE"

printf "\n"
echo " ▶▶ 복원 완료 ($RESTORE_DATE)"
echo "   서비스 시작: ./scripts/start.sh [local|airgap]"
echo ""
