#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 클린 재설치
# 프로젝트 컨테이너 + 볼륨 + 이미지를 삭제하고 처음부터 재설치한다.
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"

IMAGES=(
  "ghcr.io/open-webui/open-webui:v0.8.8"
  "postgres:16-alpine"
  "qdrant/qdrant:v1.17.0"
  "nginx:1.27-alpine"
  "iteyes-openwebui-rag-tika:latest"
)

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

source "$SCRIPT_DIR/lib/menu.sh"

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  클린 재설치"
echo " ============================================="
echo ""
echo " [INFO] 프로젝트 컨테이너, 볼륨, 이미지를 삭제하고 처음부터 재설치합니다."
echo ""

if [ -n "${1:-}" ]; then
  MODE="$1"
else
  echo " 실행 환경을 선택하세요:"
  echo ""
  select_menu _SEL \
    "local    로컬 환경 재설치" \
    "airgap   폐쇄망 DGX 환경 재설치"
  case "$_SEL" in
    1) MODE="airgap" ;;
    *) MODE="local" ;;
  esac
  echo ""
fi

echo " [WARN] 모든 데이터(DB, 벡터, 업로드 문서, 임베딩 모델 캐시)가 삭제됩니다!"
printf " 계속하시겠습니까? (y/N) "
read -r CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo " [INFO] 재설치 취소됨"
  exit 0
fi
echo ""

# ============================================
# Step 1/3: 컨테이너 + 볼륨 삭제 (0% → 30%)
# ============================================
if docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .; then
  export ENV_FILE="$MODE"
  docker compose -f "$COMPOSE_FILE" down -v &>/dev/null &
  _PID=$!
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress 50 "[1/4] 컨테이너 + 볼륨 삭제 중..." "docker compose down -v" "$_SC"; sleep 0.1
  done
  wait "$_PID"
  step_done "[1/4] 컨테이너 + 볼륨 삭제" "완료"
else
  # 실행 중이 아니어도 볼륨은 남아있을 수 있음
  docker compose -f "$COMPOSE_FILE" down -v &>/dev/null || true
  step_done "[1/4] 컨테이너 + 볼륨 삭제" "완료"
fi

# ============================================
# Step 2/3: Docker 이미지 처리 (30% → 60%)
# - local:  이미지 삭제 (start.sh에서 새로 pull)
# - airgap: tar에서 재로드 (폐쇄망이라 pull 불가)
# ============================================
if [ "$MODE" = "airgap" ]; then
  if ! ls "$PROJECT_ROOT/images/"*.tar &>/dev/null; then
    echo " [ERROR] 이미지 tar 파일을 찾을 수 없습니다: $PROJECT_ROOT/images/"
    exit 1
  fi
  TAR_FILES=("$PROJECT_ROOT/images/"*.tar)
  TAR_COUNT=${#TAR_FILES[@]}
  TAR_IDX=0
  for TAR in "${TAR_FILES[@]}"; do
    TAR_IDX=$((TAR_IDX + 1))
    SUB_PCT=$((TAR_IDX * 100 / TAR_COUNT))
    FILENAME=$(basename "$TAR")
    docker load -i "$TAR" &>/dev/null &
    _PID=$!
    while kill -0 "$_PID" 2>/dev/null; do
      tick_spin; show_progress "$((SUB_PCT / 2))" "[2/4] Docker 이미지 재로드" "$FILENAME" "$_SC"; sleep 0.1
    done
    wait "$_PID"
    show_progress "$SUB_PCT" "[2/4] Docker 이미지 재로드" "$FILENAME (완료)" "✓"
  done
  step_done "[2/4] Docker 이미지 재로드" "완료 (${TAR_IDX}개)"
else
  REMOVED=0
  for IMG in "${IMAGES[@]}"; do
    if docker image inspect "$IMG" &>/dev/null; then
      docker rmi "$IMG" &>/dev/null || true
      REMOVED=$((REMOVED + 1))
    fi
  done
  step_done "[2/4] Docker 이미지 삭제" "${REMOVED}개 삭제"
fi

# ============================================
# Step 3/4: 임베딩 모델 캐시 복원 (airgap 전용)
# ============================================
if [ "$MODE" = "airgap" ]; then
  CACHE_TAR="$PROJECT_ROOT/models/embedding-cache.tar.gz"
  VOLUME_NAME="iteyes-openwebui-rag_open-webui"
  if [ ! -f "$CACHE_TAR" ]; then
    echo " [ERROR] 임베딩 모델 캐시를 찾을 수 없습니다: $CACHE_TAR"
    exit 1
  fi
  docker volume create "$VOLUME_NAME" &>/dev/null || true
  docker run --rm \
    -v "$VOLUME_NAME":/data \
    -v "$PROJECT_ROOT/models":/models:ro \
    alpine sh -c "mkdir -p /data/cache && tar xzf /models/embedding-cache.tar.gz -C /data/cache/" \
    &>/dev/null &
  _PID=$!
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress 50 "[3/4] 임베딩 모델 캐시 복원 중..." "~2.2GB" "$_SC"; sleep 0.1
  done
  wait "$_PID"
  step_done "[3/4] 임베딩 모델 캐시 복원" "완료"
else
  step_done "[3/4] 임베딩 모델 캐시 복원" "local에선 건너뜀"
fi

# ============================================
# Step 4/4: 서비스 시작
# ============================================
step_done "[4/4] 서비스 시작" ""
printf "\n"
"$SCRIPT_DIR/start.sh" "$MODE"
