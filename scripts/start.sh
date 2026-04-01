#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 서비스 시작
# 서비스 시작, Ready 대기, DB 설정 동기화를 순차적으로 수행한다.
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"

PROFILE_ARGS=""
COMPOSE_ARGS="-f $COMPOSE_FILE"

# WSL2 + Docker Desktop: docker-credential-desktop.exe 우회
# buildx/compose build 시 credsStore가 WSL2에서 실행 불가 → 임시 config 사용
_TEMP_DOCKER_CONFIG=""
if [ -f "$HOME/.docker/config.json" ] && grep -q '"credsStore"' "$HOME/.docker/config.json" 2>/dev/null; then
  _TEMP_DOCKER_CONFIG=$(mktemp -d)
  python3 -c "
import json
with open('$HOME/.docker/config.json') as f: cfg = json.load(f)
cfg.pop('credsStore', None)
with open('$_TEMP_DOCKER_CONFIG/config.json', 'w') as f: json.dump(cfg, f, indent=2)
"
  export DOCKER_CONFIG="$_TEMP_DOCKER_CONFIG"
fi
trap '[ -n "$_TEMP_DOCKER_CONFIG" ] && rm -rf "$_TEMP_DOCKER_CONFIG"' EXIT

_SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
_SIDX=0
_SC=" "
shopt -s checkwinsize
_COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}

tick_spin() {
  _SC="${_SPIN:$((_SIDX % ${#_SPIN})):1}"
  _SIDX=$((_SIDX + 1))
}

show_progress() {
  local pct=$1 step_label="$2" detail="${3:-}" icon="${4:-$_SC}"
  _COLS=${COLUMNS:-120}

  local bar_len=20 filled=$((pct * 20 / 100)) empty=$((20 - pct * 20 / 100))
  local bar=""
  [ "$filled" -gt 0 ] && bar=$(printf '%0.s█' $(seq 1 $filled))
  [ "$empty"  -gt 0 ] && bar="${bar}$(printf '%0.s░' $(seq 1 $empty))"

  local text
  if [ -n "$detail" ]; then
    text="$step_label — $detail"
  else
    text="$step_label"
  fi
  local max_text=$(( _COLS - 32 ))
  [ "$max_text" -lt 5 ] && max_text=5
  text="${text:0:$max_text}"

  printf "\r\033[2K  %s [%3d%%] %s %s" "$icon" "$pct" "$bar" "$text"
}

step_done() {
  show_progress 100 "$1" "${2:-}" "✓"
  printf "\n"
}

# 백그라운드 명령 실행 + 스피너 표시
spin_run() {
  local label=$1 detail=$2
  shift 2; [ "${1:-}" = "--" ] && shift
  local _log; _log=$(mktemp)
  "$@" > "$_log" 2>&1 &
  local _pid=$!
  while kill -0 "$_pid" 2>/dev/null; do
    tick_spin
    show_progress 50 "$label" "$detail" "$_SC"
    sleep 0.1
  done
  if ! wait "$_pid"; then
    printf "\n\n"
    echo "[ERROR] 명령 실패: $*"
    echo "---"
    cat "$_log"
    echo "---"
    rm -f "$_log"
    exit 1
  fi
  rm -f "$_log"
}

source "$SCRIPT_DIR/lib/menu.sh"

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  서비스 시작"
echo " ============================================="
echo ""
echo " [INFO] 서비스 시작, 서비스 준비 확인, DB 설정 동기화를 순차적으로 수행합니다."
echo ""

if [ -n "${1:-}" ]; then
  MODE="$1"
else
  echo " 실행 환경을 선택하세요:"
  echo ""
  select_menu _SEL \
    "local    로컬 환경 (local.env, GPU 서버는 SSH 터널로 사전 연결 필요)" \
    "airgap   폐쇄망 DGX 환경 (airgap.env, vLLM/Ollama 포트 자동 감지)"
  case "$_SEL" in
    1) MODE="airgap" ;;
    *) MODE="local" ;;
  esac
  echo ""
fi

# ============================================
# Step 1/8: 환경 설정 확인 (0% → 5%)
# ============================================
show_progress 0 "[1/9] 환경 설정 확인 중..." "" " "

case "$MODE" in
  local)
    export ENV_FILE="local"
    ;;
  airgap)
    export ENV_FILE="airgap"
    COMPOSE_ARGS="-f $COMPOSE_FILE"

    # LLM 백엔드 자동 감지 (포트 체크)
    _VLLM_UP=false
    _OLLAMA_UP=false
    bash -c ':>/dev/tcp/localhost/8000' 2>/dev/null && _VLLM_UP=true
    bash -c ':>/dev/tcp/localhost/11434' 2>/dev/null && _OLLAMA_UP=true

    _ENV_PATH="$PROJECT_ROOT/config/env/airgap.env"
    if $_VLLM_UP && $_OLLAMA_UP; then
      show_progress 50 "[1/9] 환경 설정 확인 중..." "LLM 감지: vLLM+Ollama" " "
      sed -i 's/^ENABLE_OPENAI_API=.*/ENABLE_OPENAI_API=true/' "$_ENV_PATH"
      sed -i 's/^ENABLE_OLLAMA_API=.*/ENABLE_OLLAMA_API=true/' "$_ENV_PATH"
    elif $_VLLM_UP; then
      show_progress 50 "[1/9] 환경 설정 확인 중..." "LLM 감지: vLLM(8000)" " "
      sed -i 's/^ENABLE_OPENAI_API=.*/ENABLE_OPENAI_API=true/' "$_ENV_PATH"
      sed -i 's/^ENABLE_OLLAMA_API=.*/ENABLE_OLLAMA_API=false/' "$_ENV_PATH"
    elif $_OLLAMA_UP; then
      show_progress 50 "[1/9] 환경 설정 확인 중..." "LLM 감지: Ollama(11434)" " "
      sed -i 's/^ENABLE_OPENAI_API=.*/ENABLE_OPENAI_API=false/' "$_ENV_PATH"
      sed -i 's/^ENABLE_OLLAMA_API=.*/ENABLE_OLLAMA_API=true/' "$_ENV_PATH"
    else
      show_progress 50 "[1/9] 환경 설정 확인 중..." "[WARN] LLM 미감지 (8000, 11434 응답 없음)" " "
    fi
    ;;
  *)
    printf "\n"
    echo "Usage: $0 [local|airgap]"
    exit 1
    ;;
esac

# SECRET_KEY 미설정 시 차단
ENV_PATH="$PROJECT_ROOT/config/env/${ENV_FILE}.env"
if grep -q '<generate' "$ENV_PATH" 2>/dev/null; then
  printf "\n"
  echo "[ERROR] WEBUI_SECRET_KEY가 설정되지 않았습니다."
  echo "        다음 명령으로 키를 생성하세요: openssl rand -hex 32"
  echo "        생성된 값을 $ENV_PATH 의 WEBUI_SECRET_KEY에 입력하세요."
  exit 1
fi

# PostgreSQL 비밀번호 로드 (compose + psql 인증 공용)
POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' "$ENV_PATH" 2>/dev/null | cut -d= -f2 || echo "openwebui")
export POSTGRES_PASSWORD
export PGPASSWORD="$POSTGRES_PASSWORD"

mkdir -p "$PROJECT_ROOT/data/documents"
mkdir -p "$PROJECT_ROOT/data/logs"

step_done "[1/9] 환경 설정 확인" "완료 ($MODE mode)"

# ============================================
# Step 2/8: Docker 이미지 확인/Pull (5% → 35%)
# ============================================
IMAGES=(
  "ghcr.io/open-webui/open-webui:v0.8.8"
  "postgres:16-alpine"
  "qdrant/qdrant:v1.17.0"
  "nginx:1.27-alpine"
)
IMG_COUNT=${#IMAGES[@]}
IMG_IDX=0

for IMG in "${IMAGES[@]}"; do
  IMG_IDX=$((IMG_IDX + 1))
  SUB_PCT=$((IMG_IDX * 100 / IMG_COUNT))
  IMG_SHORT=$(echo "$IMG" | sed 's|.*/||')

  if docker image inspect "$IMG" &>/dev/null; then
    show_progress "$SUB_PCT" "[2/9] Docker 이미지" "$IMG_SHORT (캐시됨)" "✓"
  else
    spin_run "[2/9] Docker 이미지 Pull" "$IMG_SHORT" -- docker pull "$IMG"
    show_progress "$SUB_PCT" "[2/9] Docker 이미지 Pull" "$IMG_SHORT (완료)" "✓"
  fi
done
step_done "[2/9] Docker 이미지 확인" "${IMG_COUNT}개 완료 (tika는 step 3 빌드)"

# ============================================
# Step 3/8: 컨테이너 시작 (35% → 50%)
# ============================================
# shellcheck disable=SC2086
spin_run "[3/9] 컨테이너 시작 중..." "docker compose up" -- \
  docker compose $COMPOSE_ARGS $PROFILE_ARGS up -d --build

# WSL2 Docker Desktop: bind mount stale → nginx exit 127 대응
NGINX_STATUS=$(docker compose $COMPOSE_ARGS ps -q nginx 2>/dev/null | xargs -I{} docker inspect {} --format='{{.State.Status}}' 2>/dev/null || echo "")
if [ "$NGINX_STATUS" = "exited" ]; then
  # shellcheck disable=SC2086
  spin_run "[3/9] nginx 재생성 중..." "WSL2 bind mount fix" -- \
    docker compose $COMPOSE_ARGS up -d nginx --force-recreate
fi

# open-webui 컨테이너 확인
CONTAINER=$(docker compose $COMPOSE_ARGS ps -q open-webui)

if [ -z "$CONTAINER" ]; then
  printf "\n"
  echo "[ERROR] open-webui container not found"
  exit 1
fi

step_done "[3/9] 컨테이너 시작" "완료"

# ============================================
# Step 4/8: 임베딩 모델 다운로드 (50% → 62%)
# Step 5/8: Open WebUI 준비 대기 (62% → 70%)
# ============================================
SECONDS=0
MODEL_TOTAL_MB=2200
_MODEL_DONE=false

while true; do
  # open-webui 포트 응답 확인 → 준비 완료
  if docker exec "$CONTAINER" bash -c ':> /dev/tcp/localhost/8080' 2>/dev/null; then
    if [ "$_MODEL_DONE" = false ]; then
      step_done "[4/9] 임베딩 모델 다운로드" "완료"
    fi
    step_done "[5/9] Open WebUI 준비" "완료 (${SECONDS}s)"
    if [ "$MODE" = "airgap" ]; then
      _ACCESS_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")"
    else
      _ACCESS_URL="http://localhost:3000"
    fi
    echo ""
    echo " ▶▶ 서비스 준비 완료 — $_ACCESS_URL"
    echo ""

    # ============================================
    # Step 6/8: 관리자 계정 확인
    # ============================================
    show_progress 0 "[6/9] 관리자 계정 확인 중..." "" " "
    ADMIN_EXISTS=$(docker compose $COMPOSE_ARGS exec -T postgres psql -U openwebui -d openwebui -tAc \
      "SELECT COUNT(*) FROM \"user\" WHERE role = 'admin'" 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ "${ADMIN_EXISTS:-0}" = "0" ]; then
      while true; do
        for (( _w=0; _w<50; _w++ )); do
          tick_spin
          show_progress 50 "[6/9] 관리자 계정 생성 대기 중..." "$_ACCESS_URL" "$_SC"
          sleep 0.1
        done
        ADMIN_EXISTS=$(docker compose $COMPOSE_ARGS exec -T postgres psql -U openwebui -d openwebui -tAc \
          "SELECT COUNT(*) FROM \"user\" WHERE role = 'admin'" 2>/dev/null | tr -d '[:space:]' || echo "0")
        if [ "${ADMIN_EXISTS:-0}" != "0" ]; then
          break
        fi
      done
    fi
    step_done "[6/9] 관리자 계정 확인" "완료"

    # ============================================
    # Step 7/8: RAG 설정 적용
    # ============================================
    show_progress 0 "[7/9] RAG 설정 DB 적용 중..." "" " "
    if docker compose $COMPOSE_ARGS exec -T postgres psql -U openwebui -d openwebui &>/dev/null << 'PSQL'
UPDATE config SET data = (
  jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(data::jsonb,
    '{rag,chunk_size}', '400'),
    '{rag,chunk_overlap}', '80'),
    '{rag,chunk_min_size_target}', '150'),
    '{rag,top_k}', '8'),
    '{rag,top_k_reranker}', '8'),
    '{rag,reranking_model}', '""'),
    '{rag,relevance_threshold}', '0.1'),
    '{rag,enable_hybrid_search}', 'true'),
    '{rag,template}', to_jsonb('You are an expert analyst answering questions based on internal company documents. Always respond in Korean.

[Instructions]
1. Use ALL relevant information from every document included in the context below.
2. If related information is found across multiple documents, organize it by document.
3. Always cite the source of each piece of information using the format [document name].
4. Use structured formats such as tables or lists when appropriate.
5. Only say "제공된 문서에서 해당 정보를 찾을 수 없습니다" if the context contains NO relevant information.
6. Never guess or fabricate information not present in the context.

[Excel Data Guidelines]
- Data separated by tabs or spaces represents rows and columns of an Excel spreadsheet.
- Headers may be cut off at chunk boundaries; infer structure from data patterns (numeric columns, date formats, code values, etc.).
- Always quote numeric, date, and code values exactly as they appear in the source.
- If related data is spread across multiple chunks, consolidate it into a single table.

[Context]
{{CONTEXT}}

[Question]
{{QUERY}}

[Answer]'::text)
  )
)::json;
PSQL
    then
      step_done "[7/9] RAG 설정 적용" "chunk=400/80/150, top_k=8, reranker=off"
    else
      step_done "[7/9] RAG 설정 적용" "[WARN] 실패 — Admin UI에서 수동 확인 필요"
    fi

    # ============================================
    # Step 8/8: 로깅 필터 등록
    # ============================================
    show_progress 0 "[8/9] 로깅 필터 등록 중..." "" " "
    FILTER_FILE="$PROJECT_ROOT/config/functions/logging_filter.py"
    if [ -f "$FILTER_FILE" ]; then
      TMPFILE=$(mktemp)
      cat > "$TMPFILE" << 'SQL_HEADER'
INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, created_at, updated_at)
VALUES (
  'llm_query_logger',
  (SELECT id FROM "user" WHERE role = 'admin' LIMIT 1),
  'LLM Query Logger',
  'filter',
  $fn$
SQL_HEADER
      cat "$FILTER_FILE" >> "$TMPFILE"
      cat >> "$TMPFILE" << 'SQL_FOOTER'
$fn$,
  '{"description": "LLM 질의/응답/소요시간을 JSONL 파일로 기록"}',
  '{}',
  true,
  true,
  EXTRACT(EPOCH FROM NOW())::bigint * 1000000000,
  EXTRACT(EPOCH FROM NOW())::bigint * 1000000000
)
ON CONFLICT (id) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  is_global = true,
  updated_at = EXTRACT(EPOCH FROM NOW())::bigint * 1000000000;
SQL_FOOTER
      if docker compose $COMPOSE_ARGS exec -T postgres psql -U openwebui -d openwebui &>/dev/null < "$TMPFILE"
      then
        step_done "[8/9] 로깅 필터 등록" "완료"
      else
        step_done "[8/9] 로깅 필터 등록" "[WARN] 실패 — Admin UI > Functions에서 수동 등록 필요"
      fi
      rm -f "$TMPFILE"
    else
      step_done "[8/9] 로깅 필터 등록" "필터 파일 없음 (건너뜀)"
    fi

    # ============================================
    # 자동 백업 cron 설정
    # ============================================
    if crontab -l 2>/dev/null | grep -q "iteyes-openwebui-rag"; then
      # 이미 등록된 경우 cron 서비스만 조용히 시작
      sudo service cron start &>/dev/null || true
      step_done "[9/9] 자동 백업 cron 설정" "이미 등록됨 (건너뜀)"
    else
      echo ""
      echo " [INFO] 자동 백업 cron을 등록하시겠습니까? (매일 03:00 자동 백업, 등록 시 sudo 비밀번호 필요)"
      echo ""
      printf " 등록하시겠습니까? (y/N): "
      read -r _CRON
      echo ""
      if [ "${_CRON:-N}" = "y" ] || [ "${_CRON:-N}" = "Y" ]; then
        sudo service cron start &>/dev/null || true
        "$SCRIPT_DIR/setup-cron.sh" install &>/dev/null || true
        step_done "[9/9] 자동 백업 cron 설정" "완료 (매일 03:00)"
      else
        step_done "[9/9] 자동 백업 cron 설정" "건너뜀"
      fi
    fi

    # ============================================
    # 완료
    # ============================================
    printf "\n"
    echo " ▶▶ 시작 완료! (${SECONDS}s) — $_ACCESS_URL"
    echo ""

    break
  fi

  # 컨테이너 비정상 종료 감지
  STATUS=$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "not found")
  if [ "$STATUS" != "running" ]; then
    printf "\n"
    echo "[ERROR] open-webui container stopped (status: $STATUS)"
    exit 1
  fi

  # 임베딩 모델 다운로드 진행률 표시
  CACHE_DIR="/app/backend/data/cache/embedding/models"
  CACHE_MB=$(docker exec "$CONTAINER" du -sm "$CACHE_DIR" 2>/dev/null | awk '{print $1}' || echo "0")

  if [ "$CACHE_MB" -gt 0 ] 2>/dev/null && [ "$CACHE_MB" -lt "$MODEL_TOTAL_MB" ]; then
    _MODEL_DONE=false
    DL_PCT=$((CACHE_MB * 100 / MODEL_TOTAL_MB))
    _DETAIL="${CACHE_MB}MB / ${MODEL_TOTAL_MB}MB (${DL_PCT}%)"
    for (( _w=0; _w<30; _w++ )); do
      tick_spin
      show_progress "$DL_PCT" "[4/9] 임베딩 모델 다운로드" "$_DETAIL [${SECONDS}s]" "$_SC"
      sleep 0.1
    done
  else
    if [ "$_MODEL_DONE" = false ] && [ "$CACHE_MB" -ge "$MODEL_TOTAL_MB" ] 2>/dev/null; then
      step_done "[4/9] 임베딩 모델 다운로드" "완료"
      _MODEL_DONE=true
    fi
    # Open WebUI 준비 대기
    # 마지막 로그 1줄: 개행 제거 → ANSI escape 코드 제거 → 60자 잘라냄
    LAST_LOG=$(docker logs "$CONTAINER" --tail 1 2>&1 | tr -d '\r\n' | sed 's/\x1b\[[0-9;]*[mK]//g' | cut -c1-60)
    for (( _w=0; _w<30; _w++ )); do
      tick_spin
      show_progress 50 "[5/9] Open WebUI 준비 대기" "[${SECONDS}s]" "$_SC"
      sleep 0.1
    done
  fi
done
