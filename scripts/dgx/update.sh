#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 이미지 업데이트
# 서비스 중지 → 이미지 재적재 → 서비스 재시작 (데이터 보존)
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"

source "$SCRIPT_DIR/../lib/menu.sh"

UPDATE_MODELS=false
_HAS_ARGS=false
if [ $# -gt 0 ]; then
  _HAS_ARGS=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update-models) UPDATE_MODELS=true; shift ;;
      *) echo "Usage: $0 [--update-models]"; exit 1 ;;
    esac
  done
fi

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
echo " Iteyes Open WebUI RAG  ·  이미지 업데이트"
echo " ============================================="
echo ""
echo " [INFO] 서비스를 중지하고 Docker 이미지를 재적재한 후 재시작합니다."
echo ""
echo " [WARN] 데이터(DB, 벡터, 업로드 문서)는 보존됩니다."
echo ""

# 인자 없이 실행 시 대화형 메뉴
if [ "$_HAS_ARGS" = false ]; then
  echo " 업데이트 범위를 선택하세요:"
  echo ""
  select_menu _SEL \
    "Docker 이미지만 재적재" \
    "Docker 이미지 + 임베딩 모델 캐시 재적재"
  case "$_SEL" in
    1) UPDATE_MODELS=true ;;
    *) ;;
  esac
  echo ""
fi

# ============================================
# Step 1/4: 서비스 중지 (0% → 20%)
# ============================================
if docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .; then
  export ENV_FILE="airgap"
  docker compose -f "$COMPOSE_FILE" down &>/dev/null &
  _PID=$!
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress 50 "[1/4] 서비스 중지 중..." "" "$_SC"; sleep 0.1
  done
  wait "$_PID"
  step_done "[1/4] 서비스 중지" "완료"
else
  step_done "[1/4] 서비스 중지" "실행 중인 서비스 없음 (건너뜀)"
fi

# ============================================
# Step 2/4: Docker 이미지 재적재 (20% → 65%)
# ============================================
if ! ls "$PROJECT_ROOT/images/"*.tar &>/dev/null; then
  printf "\n"
  echo "[ERROR] 이미지 파일을 찾을 수 없습니다: $PROJECT_ROOT/images/"
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
    tick_spin; show_progress "$((SUB_PCT / 2))" "[2/4] Docker 이미지 재적재" "$FILENAME" "$_SC"; sleep 0.1
  done
  wait "$_PID"
  show_progress "$SUB_PCT" "[2/4] Docker 이미지 재적재" "$FILENAME (완료)" "✓"
done

# 아키텍처 검증
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64)  EXPECTED_ARCH="amd64" ;;
  aarch64) EXPECTED_ARCH="arm64" ;;
  *)       EXPECTED_ARCH="$HOST_ARCH" ;;
esac

ARCH_OK=true
for IMAGE in ghcr.io/open-webui/open-webui:v0.8.8 postgres:16-alpine qdrant/qdrant:v1.17.0 iteyes-openwebui-rag-tika:latest nginx:1.27-alpine; do
  IMG_ARCH=$(docker inspect --format='{{.Architecture}}' "$IMAGE" 2>/dev/null || echo "unknown")
  if [ "$IMG_ARCH" != "$EXPECTED_ARCH" ]; then
    ARCH_OK=false; break
  fi
done
if [ "$ARCH_OK" = false ]; then
  step_done "[2/4] Docker 이미지 재적재" "[WARN] 아키텍처 불일치 — docker compose pull 권장"
else
  step_done "[2/4] Docker 이미지 재적재" "완료 (아키텍처: $EXPECTED_ARCH)"
fi

# 모델 캐시 업데이트 (선택)
if [ "$UPDATE_MODELS" = true ]; then
  if [ ! -f "$PROJECT_ROOT/models/embedding-cache.tar.gz" ]; then
    step_done "[2/4] 모델 캐시 업데이트" "[WARN] embedding-cache.tar.gz 없음 (건너뜀)"
  else
    VOLUME_NAME="iteyes-openwebui-rag_open-webui"
    docker run --rm \
      -v "$VOLUME_NAME":/data \
      -v "$PROJECT_ROOT/models":/models:ro \
      alpine sh -c "rm -rf /data/cache/embedding && mkdir -p /data/cache && tar xzf /models/embedding-cache.tar.gz -C /data/cache/" \
      &>/dev/null &
    _PID=$!
    while kill -0 "$_PID" 2>/dev/null; do
      tick_spin; show_progress 50 "[2/4] 모델 캐시 재적재 중..." "~2.2GB" "$_SC"; sleep 0.1
    done
    wait "$_PID"
    step_done "[2/4] 모델 캐시 재적재" "완료"
  fi
fi

# ============================================
# Step 3/4: 환경 설정 동기화 (65% → 80%)
# ============================================
show_progress 0 "[3/4] 환경 설정 동기화 중..." "" " "
ENV_FILE="$PROJECT_ROOT/config/env/airgap.env"
EXAMPLE_FILE="$PROJECT_ROOT/config/env/airgap.env.example"

if [ -f "$ENV_FILE" ] && [ -f "$EXAMPLE_FILE" ]; then
  ADDED=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z_]+)= ]]; then
      KEY="${BASH_REMATCH[1]}"
      if ! grep -q "^${KEY}=" "$ENV_FILE"; then
        echo "$line" >> "$ENV_FILE"
        ADDED=$((ADDED + 1))
      fi
    fi
  done < "$EXAMPLE_FILE"
  if [ "$ADDED" -gt 0 ]; then
    step_done "[3/4] 환경 설정 동기화" "${ADDED}개 신규 설정 추가됨"
  else
    step_done "[3/4] 환경 설정 동기화" "추가할 신규 설정 없음"
  fi
else
  step_done "[3/4] 환경 설정 동기화" "파일 없음 (건너뜀)"
fi

# ============================================
# Step 4/4: 서비스 재시작 (80% → 100%)
# ============================================
step_done "[4/4] 서비스 재시작" ""
printf "\n"
"$SCRIPT_DIR/../start.sh" airgap
