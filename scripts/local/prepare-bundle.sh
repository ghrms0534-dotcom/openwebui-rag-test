#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 폐쇄망 배포 번들 생성
# 인터넷이 연결된 환경에서 실행하여 배포 번들을 만든다.
#
# 번들에 포함되는 것:
#   - Docker 이미지 (.tar)
#   - 임베딩 모델 캐시 (bge-m3, ~2.2GB)
#   - docker-compose.yml, nginx.conf
#   - 환경설정 템플릿 (airgap.env.example)
#   - 운영 스크립트 (install, start, stop, update, reinstall, backup, restore)
#   - 배포 문서
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"

IMAGES=(
  "ghcr.io/open-webui/open-webui:v0.8.8"
  "postgres:16-alpine"
  "qdrant/qdrant:v1.17.0"
  # tika는 커스텀 빌드 이미지 — 아래에서 별도 처리
  "nginx:1.27-alpine"
)

source "$SCRIPT_DIR/../lib/menu.sh"

OUTPUT_DIR="$PROJECT_ROOT/bundle"
TARGET_PLATFORM="linux/arm64"
FORCE=false
_HAS_ARGS=false

if [ $# -gt 0 ]; then
  _HAS_ARGS=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)   TARGET_PLATFORM="$2"; shift 2 ;;
      --force)      FORCE=true; shift ;;
      -h|--help)
        echo "Usage: $0 [--platform PLATFORM] [--force]"
        echo "  --platform     대상 플랫폼 (기본: linux/arm64)"
        echo "  --force        기존 이미지 tar 무시하고 재생성"
        exit 0 ;;
      *) echo "[ERROR] 알 수 없는 인자: $1"; exit 1 ;;
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
echo " Iteyes Open WebUI RAG  ·  배포 번들 생성"
echo " ============================================="
echo ""
echo " [INFO] 폐쇄망 배포를 위한 Docker 이미지와 모델 캐시를 번들로 생성합니다."
echo ""

# 인자 없이 실행 시 대화형 설정
if [ "$_HAS_ARGS" = false ]; then
  echo " 기존 이미지 캐시 처리:"
  echo ""
  select_menu _SEL \
    "캐시된 이미지 재사용 (빠름)" \
    "기존 이미지 무시하고 강제 재생성"
  case "$_SEL" in
    1) FORCE=true ;;
    *) ;;
  esac
  echo ""
fi

echo " 경로: $OUTPUT_DIR  |  플랫폼: $TARGET_PLATFORM"
echo ""

# ============================================
# 전제조건 확인
# ============================================
show_progress 0 "[1/6] 전제조건 확인 중..." "" " "

! command -v docker &>/dev/null && printf "\n" && echo "[ERROR] Docker가 설치되어 있지 않습니다." && exit 1
! docker compose version &>/dev/null && printf "\n" && echo "[ERROR] Docker Compose v2가 필요합니다." && exit 1
! docker buildx version &>/dev/null && printf "\n" && echo "[ERROR] Docker Buildx가 필요합니다." && exit 1

SUPPORTED_PLATFORMS=$(docker buildx inspect --bootstrap 2>/dev/null | grep -i "platforms:" | head -1 || echo "")
if [ -n "$SUPPORTED_PLATFORMS" ] && ! echo "$SUPPORTED_PLATFORMS" | grep -q "$TARGET_PLATFORM"; then
  printf "\n"
  echo "[ERROR] 현재 buildx 빌더가 $TARGET_PLATFORM 을 지원하지 않습니다."
  echo "        해결: docker buildx create --name multiarch --platform linux/amd64,linux/arm64 --use"
  exit 1
fi

step_done "[1/6] 전제조건 확인" "완료"

# WSL2 + Docker Desktop: docker-credential-desktop.exe 우회
TEMP_DOCKER_CONFIG=""
if [ -f "$HOME/.docker/config.json" ] && grep -q '"credsStore"' "$HOME/.docker/config.json" 2>/dev/null; then
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

mkdir -p "$OUTPUT_DIR"/{images,models,docker,config/env,config/functions,data/documents,data/logs,scripts,docs}

# ============================================
# Step 1/5: Docker 이미지 Pull+Save (2% → 40%)
# ============================================
IMG_TOTAL=$(( ${#IMAGES[@]} + 1 ))  # +1 for tika
IMG_IDX=0

for IMAGE in "${IMAGES[@]}"; do
  IMG_IDX=$((IMG_IDX + 1))
  SUB_PCT=$((IMG_IDX * 100 / IMG_TOTAL))
  TAR_NAME=$(echo "$IMAGE" | sed 's|[/:]|_|g').tar   # ghcr.io/open-webui:v0.8.8 → ghcr.io_open-webui_v0.8.8.tar
  IMG_SHORT=$(echo "$IMAGE" | sed 's|.*/||')          # 마지막 / 이후만 추출 (표시용)

  if [ -f "$OUTPUT_DIR/images/$TAR_NAME" ] && [ "$FORCE" != true ]; then
    show_progress "$SUB_PCT" "[2/6] Docker 이미지" "$IMG_SHORT (캐시됨)" "✓"
    continue
  fi

  docker buildx build --platform "$TARGET_PLATFORM" \
    --output "type=docker,name=$IMAGE,dest=$OUTPUT_DIR/images/$TAR_NAME" \
    - <<< "FROM $IMAGE" &>/dev/null &
  _PID=$!
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress "$((SUB_PCT / 2))" "[2/6] Docker 이미지 Pull+Save" "$IMG_SHORT" "$_SC"; sleep 0.1
  done
  if ! wait "$_PID"; then
    printf "\n"
    echo "[ERROR] 이미지 pull/save 실패: $IMAGE — 인터넷 연결을 확인하세요."
    exit 1
  fi
  SIZE=$(du -sh "$OUTPUT_DIR/images/$TAR_NAME" 2>/dev/null | awk '{print $1}')
  show_progress "$SUB_PCT" "[2/6] Docker 이미지 Pull+Save" "$IMG_SHORT ($SIZE)" "✓"
done

# Tika 커스텀 이미지 빌드 (한국어 OCR 포함)
TIKA_IMAGE="iteyes-openwebui-rag-tika:latest"
TIKA_TAR="iteyes-openwebui-rag-tika_latest.tar"
IMG_IDX=$((IMG_IDX + 1))
SUB_PCT=$((2 + (IMG_IDX * 35 / IMG_TOTAL)))

if [ -f "$OUTPUT_DIR/images/$TIKA_TAR" ] && [ "$FORCE" != true ]; then
  show_progress "$SUB_PCT" "[2/6] Docker 이미지" "tika (캐시됨)" "✓"
else
  docker buildx build --platform "$TARGET_PLATFORM" \
    --output "type=docker,name=$TIKA_IMAGE,dest=$OUTPUT_DIR/images/$TIKA_TAR" \
    "$PROJECT_ROOT/docker/tika" &>/dev/null &
  _PID=$!
  while kill -0 "$_PID" 2>/dev/null; do
    tick_spin; show_progress "$((SUB_PCT / 2))" "[2/6] Tika 빌드 중..." "tesseract-ocr-kor" "$_SC"; sleep 0.1
  done
  if ! wait "$_PID"; then
    printf "\n"; echo "[ERROR] Tika 이미지 빌드 실패"; exit 1
  fi
  SIZE=$(du -sh "$OUTPUT_DIR/images/$TIKA_TAR" 2>/dev/null | awk '{print $1}')
  show_progress "$SUB_PCT" "[2/6] Docker 이미지 Pull+Save" "tika ($SIZE)" "✓"
fi

step_done "[2/6] Docker 이미지 Pull+Save" "완료 (${IMG_IDX}개)"

# ============================================
# Step 2/5: 임베딩 모델 캐시 추출 (40% → 65%)
# ============================================
show_progress 0 "[3/6] 임베딩 모델 캐시 확인 중..." "" " "

if [ -f "$OUTPUT_DIR/models/embedding-cache.tar.gz" ]; then
  SIZE=$(du -sh "$OUTPUT_DIR/models/embedding-cache.tar.gz" | awk '{print $1}')
  step_done "[3/6] 임베딩 모델 캐시" "이미 존재 ($SIZE, 건너뜀)"
else
  EXTRACTED=false
  CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps -q open-webui 2>/dev/null || echo "")

  if [ -n "$CONTAINER" ] && [ "$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null)" = "running" ]; then
    TEMP_DIR=$(mktemp -d)
    docker cp "$CONTAINER:/app/backend/data/cache/embedding" "$TEMP_DIR/embedding" 2>/dev/null || true
    if find "$TEMP_DIR/embedding" -name "*.safetensors" -o -name "*.bin" 2>/dev/null | grep -q .; then
      tar czf "$OUTPUT_DIR/models/embedding-cache.tar.gz" -C "$TEMP_DIR" embedding &>/dev/null &
      _PID=$!
      while kill -0 "$_PID" 2>/dev/null; do
        tick_spin; show_progress 50 "[3/6] 임베딩 모델 캐시 추출 중..." "" "$_SC"; sleep 0.1
      done
      wait "$_PID"
      EXTRACTED=true
    fi
    rm -rf "$TEMP_DIR"
  fi

  if [ "$EXTRACTED" = false ]; then
    VOLUME_NAME="iteyes-openwebui-rag_open-webui"
    if docker volume inspect "$VOLUME_NAME" &>/dev/null; then
      TEMP_DIR=$(mktemp -d)
      docker run --rm -v "$VOLUME_NAME":/data:ro -v "$TEMP_DIR":/out \
        alpine sh -c "[ -d /data/cache/embedding ] && cp -r /data/cache/embedding /out/embedding" \
        &>/dev/null || true
      if find "$TEMP_DIR/embedding" -name "*.safetensors" -o -name "*.bin" 2>/dev/null | grep -q .; then
        tar czf "$OUTPUT_DIR/models/embedding-cache.tar.gz" -C "$TEMP_DIR" embedding &>/dev/null &
        _PID=$!
        while kill -0 "$_PID" 2>/dev/null; do
          tick_spin; show_progress 50 "[3/6] 임베딩 모델 캐시 추출 중..." "" "$_SC"; sleep 0.1
        done
        wait "$_PID"
        EXTRACTED=true
      fi
      rm -rf "$TEMP_DIR"
    fi
  fi

  if [ "$EXTRACTED" = false ]; then
    printf "\n\n"
    echo "[ERROR] 임베딩 모델 캐시를 추출할 수 없습니다."
    echo "        먼저 ./scripts/start.sh local 로 서비스를 시작하여 모델을 다운로드하세요."
    exit 1
  fi

  SIZE=$(du -sh "$OUTPUT_DIR/models/embedding-cache.tar.gz" | awk '{print $1}')
  step_done "[3/6] 임베딩 모델 캐시 추출" "완료 ($SIZE)"
fi

# ============================================
# Step 3/5: 프로젝트 파일 복사 (65% → 80%)
# ============================================
show_progress 0 "[4/6] 프로젝트 파일 복사 중..." "" " "

cp "$PROJECT_ROOT/docker/docker-compose.yml" "$OUTPUT_DIR/docker/"
cp "$PROJECT_ROOT/docker/nginx.conf" "$OUTPUT_DIR/docker/"
cp -r "$PROJECT_ROOT/docker/tika" "$OUTPUT_DIR/docker/tika"
cp "$PROJECT_ROOT/config/env/airgap.env.example" "$OUTPUT_DIR/config/env/"
cp -r "$PROJECT_ROOT/config/functions/"* "$OUTPUT_DIR/config/functions/" 2>/dev/null || true
touch "$OUTPUT_DIR/data/documents/.gitkeep"

for SCRIPT in start.sh stop.sh backup.sh restore.sh query-logs.sh error-logs.sh status.sh setup-cron.sh reinstall.sh; do
  cp "$PROJECT_ROOT/scripts/$SCRIPT" "$OUTPUT_DIR/scripts/" 2>/dev/null || true
done
mkdir -p "$OUTPUT_DIR/scripts/dgx"
cp "$PROJECT_ROOT/scripts/dgx/install.sh" "$OUTPUT_DIR/scripts/dgx/" 2>/dev/null || true
cp "$PROJECT_ROOT/scripts/dgx/update.sh" "$OUTPUT_DIR/scripts/dgx/" 2>/dev/null || true
mkdir -p "$OUTPUT_DIR/scripts/lib"
cp "$PROJECT_ROOT/scripts/lib/menu.sh" "$OUTPUT_DIR/scripts/lib/" 2>/dev/null || true
chmod +x "$OUTPUT_DIR/scripts/"*.sh "$OUTPUT_DIR/scripts/dgx/"*.sh

[ -d "$PROJECT_ROOT/docs" ] && cp -r "$PROJECT_ROOT/docs/"* "$OUTPUT_DIR/docs/" 2>/dev/null || true

step_done "[4/6] 프로젝트 파일 복사" "완료"

# ============================================
# Step 4/5: VERSION 파일 생성 (80% → 90%)
# ============================================
show_progress 0 "[5/6] VERSION 파일 생성 중..." "" " "
cat > "$OUTPUT_DIR/VERSION" << EOF
# Iteyes Open WebUI RAG - 폐쇄망 배포 번들
# 생성일: $(date '+%Y-%m-%d %H:%M:%S')
# 빌드 호스트: $(uname -m)
# 대상 플랫폼: $TARGET_PLATFORM

[Images]
$(for IMAGE in "${IMAGES[@]}"; do [[ "$IMAGE" =~ ^# ]] || echo "$IMAGE"; done)
iteyes-openwebui-rag-tika:latest (커스텀 빌드, tesseract-ocr-kor)

[Models]
BAAI/bge-m3 (embedding)
EOF
step_done "[5/6] VERSION 파일 생성" "완료"

# ============================================
# Step 5/5: 완료 (90% → 100%)
# ============================================
step_done "[6/6] 번들 생성 완료" ""

TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | awk '{print $1}')

printf "\n"
echo " ▶▶ 번들 생성 완료! (총 크기: ${TOTAL_SIZE})"
echo ""
echo " 다음 단계:"
echo "   1. DGX 서버에 전송:  rsync -avP bundle/ dgx:~/iteyes-openwebui-rag/"
echo "   2. DGX에서 설치:     ./scripts/dgx/install.sh"
echo "   3. DGX에서 시작:     ./scripts/start.sh airgap"
echo ""
echo " 이미지: $OUTPUT_DIR/images/"
ls -lh "$OUTPUT_DIR/images/"*.tar 2>/dev/null | awk '{n=split($NF,a,"/"); print "   " a[n] "  (" $5 ")"}'
echo ""
echo " 모델: $OUTPUT_DIR/models/"
ls -lh "$OUTPUT_DIR/models/"*.tar.gz 2>/dev/null | awk '{n=split($NF,a,"/"); print "   " a[n] "  (" $5 ")"}'
echo ""
