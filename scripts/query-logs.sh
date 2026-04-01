#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - LLM 질의응답 로그
# chat_message 테이블의 완료된 응답을 2초마다 폴링하여 출력한다.
# ============================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
export PGPASSWORD="${POSTGRES_PASSWORD:-openwebui}"

# psql 결과를 SOH(\x01) 구분자로 반환 (필드 내 탭/쉼표와 충돌 방지)
psql_query() {
  echo "$1" | docker compose -f "$COMPOSE_FILE" exec -T postgres \
    psql -U openwebui -d openwebui -t -A -F $'\x01'
}

print_entry() {
  local ts="$1" user="$2" question="$3" answer="$4" latency="$5" model="$6" backend="$7"
  [ -z "$answer" ] && answer="(응답 없음)"
  echo " [Requested at: $ts]"
  echo "   User: $user"
  echo "   Question: $question"
  echo "   Answer: $answer"
  echo "   Backend: ${backend}"
  echo "   Model: ${model}"
  echo "   Latency: ${latency}s"
  echo ""
}

# chat_message 테이블 기반으로 완료된 assistant 응답을 추출
# - cm.id: 메시지 고유 ID (SEEN 중복 방지용)
# - updated_at 기반 폴링 + SEEN으로 중복 방지: 동시 다발 질문에서 누락 없이 캡처
# - updated_at < now() - 3: 스트리밍 완료 후 3초 대기하여 최종 상태만 표시
# - parent_id → chat.messages 배열에서 user 질문 매칭
# - regexp_replace: reasoning 블록(<details>) 제거 후 200자 추출
# - 모델명에 ':'가 있으면 Ollama, 없으면 vLLM으로 백엔드 판별
make_sql() {
  local ts_filter="$1" limit="$2"
  cat << SQL
SELECT
  cm.id,
  to_char(to_timestamp(cm.created_at), 'YYYY-MM-DD HH24:MI:SS'),
  u.email,
  trim(replace(substring(
    (SELECT m->>'content' FROM jsonb_array_elements(c.chat::jsonb -> 'messages') m WHERE m->>'id' = cm.parent_id LIMIT 1)
  for 120), E'\n', ' ')),
  trim(replace(substring(
    regexp_replace(cm.content #>> '{}', '<details[^>]*>.*?</details>', '', 'gs')
  for 200), E'\n', ' ')),
  cm.updated_at - cm.created_at,
  cm.updated_at,
  COALESCE(cm.model_id, ''),
  CASE WHEN COALESCE(cm.model_id, '') LIKE '%:%' THEN 'Ollama' ELSE 'vLLM' END
FROM chat_message cm
JOIN chat c ON cm.chat_id = c.id
JOIN "user" u ON cm.user_id = u.id
WHERE cm.role = 'assistant'
  AND cm.done = true
  AND length(trim(regexp_replace(cm.content #>> '{}', '<details[^>]*>.*?</details>', '', 'gs'))) > 0
  AND cm.updated_at > $ts_filter
  AND cm.updated_at < extract(epoch from now())::bigint - 3
ORDER BY cm.updated_at ASC
LIMIT $limit;
SQL
}

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  LLM 질의응답 로그"
echo " ============================================="
echo ""
echo " [INFO] 실행 이후 발생하는 질의응답만 표시됩니다."
echo ""

LAST_TS=$(date +%s)
declare -A SEEN  # 메시지 ID 기반 중복 방지

while true; do
  sleep 2
  if ! rows=$(psql_query "$(make_sql "$LAST_TS" "50")" 2>&1); then
    echo " [ERROR] DB 조회 실패 — 서비스가 실행 중인지 확인하세요." >&2
    exit 1
  fi
  if [ -n "$rows" ]; then
    while IFS=$'\x01' read -r msg_id ts user question answer latency updated_at model backend; do  # SOH 구분자로 파싱
      [ -z "$ts" ] && continue
      [ -n "${SEEN[$msg_id]+x}" ] && continue  # 이미 표시한 메시지 스킵
      SEEN[$msg_id]=1
      print_entry "$ts" "$user" "$question" "$answer" "$latency" "$model" "$backend"
      # LAST_TS는 최신 updated_at으로 갱신 (SEEN이 중복 방지)
      if [ "$updated_at" -gt "$LAST_TS" ]; then
        LAST_TS="$updated_at"
      fi
    done <<< "$rows"
  fi
done
