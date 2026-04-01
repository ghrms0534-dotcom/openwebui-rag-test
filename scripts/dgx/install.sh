#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 폐쇄망 DGX 최초 설치
# 배포 번들의 루트 디렉토리에서 실행
#
# 수행 작업:
#   1. Docker 이미지 로드 (images/*.tar)
#   2. airgap.env 생성 (없을 때만)
#   3. 임베딩 모델 캐시 복원 (models/)
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

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
echo " Iteyes Open WebUI RAG  ·  폐쇄망 설치"
echo " ============================================="
echo ""
echo " [INFO] Docker 이미지 로드, 환경설정 생성, 모델 캐시 복원을 수행합니다."
echo ""

# ============================================
# Step 1/5: 전제조건 확인 (0% → 10%)
# ============================================
show_progress 0 "[1/5] 전제조건 확인 중..." "" " "

if ! command -v docker &>/dev/null; then
  printf "\n"
  echo "[ERROR] Docker가 설치되어 있지 않습니다."
  exit 1
fi
if ! docker compose version &>/dev/null; then
  printf "\n"
  echo "[ERROR] Docker Compose v2가 설치되어 있지 않습니다."
  exit 1
fi
if ! ls "$PROJECT_ROOT/images/"*.tar &>/dev/null; then
  printf "\n"
  echo "[ERROR] Docker 이미지 파일을 찾을 수 없습니다: $PROJECT_ROOT/images/"
  echo "        scripts/local/prepare-bundle.sh로 생성된 번들인지 확인하세요."
  exit 1
fi
if [ ! -f "$PROJECT_ROOT/models/embedding-cache.tar.gz" ]; then
  printf "\n"
  echo "[ERROR] 임베딩 모델 캐시를 찾을 수 없습니다: $PROJECT_ROOT/models/embedding-cache.tar.gz"
  exit 1
fi

step_done "[1/5] 전제조건 확인" \
  "Docker $(docker --version | awk '{print $3}' | tr -d ',')  Compose $(docker compose version --short)"

# ============================================
# Step 2/5: Docker 이미지 로드 (10% → 45%)
# ============================================
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
    tick_spin; show_progress "$((SUB_PCT / 2))" "[2/5] Docker 이미지 로드" "$FILENAME" "$_SC"; sleep 0.1
  done
  wait "$_PID"
  show_progress "$SUB_PCT" "[2/5] Docker 이미지 로드" "$FILENAME (완료)" "✓"
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
    ARCH_OK=false
    break
  fi
done

if [ "$ARCH_OK" = false ]; then
  printf "\n\n"
  echo "[WARN] 일부 이미지의 아키텍처가 호스트와 일치하지 않습니다!"
  echo "       exec format error가 발생할 수 있습니다."
  echo "       해결 1 (인터넷 가능): docker compose pull"
  echo "       해결 2: ./scripts/local/prepare-bundle.sh --force (인터넷 환경)"
  echo ""
  step_done "[2/5] Docker 이미지 로드" "[WARN] 아키텍처 불일치 ($EXPECTED_ARCH)"
else
  step_done "[2/5] Docker 이미지 로드" "완료 (아키텍처: $EXPECTED_ARCH)"
fi

# ============================================
# Step 3/5: 환경 설정 확인 (45% → 60%)
# ============================================
show_progress 0 "[3/5] 환경 설정 확인 중..." "" " "
ENV_FILE="$PROJECT_ROOT/config/env/airgap.env"

if [ -f "$ENV_FILE" ]; then
  step_done "[3/5] 환경 설정 확인" "airgap.env 이미 존재 (기존 설정 유지)"
else
  cp "$PROJECT_ROOT/config/env/airgap.env.example" "$ENV_FILE"
  SECRET_KEY=$(openssl rand -hex 32)
  sed -i "s|WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$SECRET_KEY|" "$ENV_FILE"
  PG_PASS=$(openssl rand -hex 16)
  sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PG_PASS|" "$ENV_FILE"
  sed -i "s|DATABASE_URL=.*|DATABASE_URL=postgresql://openwebui:${PG_PASS}@postgres:5432/openwebui|" "$ENV_FILE"

  step_done "[3/5] 환경 설정 확인" "airgap.env 생성 완료 (SECRET_KEY + POSTGRES_PASSWORD 자동 생성)"
  printf "\n"
  echo " ▶▶ airgap.env가 생성되었습니다."
  echo ""
  echo " LLM 수동 설정: vi $ENV_FILE"
  echo ""
fi

# ============================================
# Step 4/5: 임베딩 모델 캐시 복원 (60% → 90%)
# ============================================
show_progress 0 "[4/5] 임베딩 모델 캐시 확인 중..." "" " "
VOLUME_NAME="iteyes-openwebui-rag_open-webui"

if ! docker volume inspect "$VOLUME_NAME" &>/dev/null; then
  docker volume create "$VOLUME_NAME" &>/dev/null
fi

MODEL_EXISTS=$(docker run --rm \
  -v "$VOLUME_NAME":/data:ro \
  alpine sh -c "find /data/cache/embedding -name '*.safetensors' -o -name '*.bin' 2>/dev/null | head -1" \
  2>/dev/null || echo "")

if [ -n "$MODEL_EXISTS" ]; then
  step_done "[4/5] 임베딩 모델 캐시" "이미 존재 (건너뜀)"
else
  docker run --rm \
    -v "$VOLUME_NAME":/data \
    -v "$PROJECT_ROOT/models":/models:ro \
    alpine sh -c "mkdir -p /data/cache && tar xzf /models/embedding-cache.tar.gz -C /data/cache/" \
    &>/dev/null &
  _PID=$!
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress 50 "[4/5] 임베딩 모델 캐시 복원 중..." "~2.2GB" "$_SC"; sleep 0.1
  done
  wait "$_PID"

  VERIFY=$(docker run --rm -v "$VOLUME_NAME":/data:ro \
    alpine sh -c "find /data/cache/embedding -name '*.safetensors' -o -name '*.bin' 2>/dev/null | head -1" \
    2>/dev/null || echo "")
  if [ -z "$VERIFY" ]; then
    printf "\n"
    echo "[ERROR] 모델 캐시 복원 실패. embedding-cache.tar.gz 파일을 확인하세요."
    exit 1
  fi
  step_done "[4/5] 임베딩 모델 캐시" "복원 완료"
fi

# ============================================
# Step 5/5: 디렉토리 준비 (90% → 100%)
# ============================================
mkdir -p "$PROJECT_ROOT/data/documents"
mkdir -p "$PROJECT_ROOT/backups"
step_done "[5/5] 디렉토리 준비" "완료"

printf "\n"
echo " ▶▶ 설치 완료!"
echo ""
echo " 다음 단계:"
echo "   1. LLM 서비스 확인:"
echo "      curl http://localhost:8000/v1/models  (vLLM)"
echo "      curl http://localhost:11434/api/tags  (Ollama)"
echo "   2. 서비스 시작: ./scripts/start.sh airgap"
echo ""
