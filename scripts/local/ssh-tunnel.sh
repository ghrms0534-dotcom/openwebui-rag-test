#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - SSH 터널 (local 모드 전용)
# GPU 서버의 LLM 백엔드를 로컬 포트로 포워딩한다.
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/menu.sh"

echo " ============================================="
echo " Iteyes Open WebUI RAG  ·  SSH 터널"
echo " ============================================="
echo ""
echo " [INFO] local 모드 전용. GPU 서버 LLM 백엔드를 로컬 포트로 포워딩합니다."
echo ""

if [ -n "${1:-}" ]; then
  GPU_SERVER="$1"
  BACKEND="${2:-vllm}"
  SSH_PORT="${3:-22}"
else
  printf " GPU 서버 호스트 (user@host): "
  read -r GPU_SERVER
  if [ -z "$GPU_SERVER" ]; then
    echo "[ERROR] GPU 서버 호스트를 입력하세요."
    exit 1
  fi
  echo ""
  echo " LLM 백엔드를 선택하세요:"
  echo ""
  select_menu _SEL \
    "vllm     vLLM (포트 8000)" \
    "ollama   Ollama (포트 11434)"
  case "$_SEL" in
    1) BACKEND="ollama" ;;
    *) BACKEND="vllm" ;;
  esac
  echo ""
  printf " SSH 포트 [22] (변경하지 않았다면 엔터): "
  read -r _PORT
  SSH_PORT="${_PORT:-22}"
  echo ""
fi

case "$BACKEND" in
  ollama) LOCAL_PORT=11434; REMOTE_PORT=11434 ;;
  vllm)   LOCAL_PORT=8000;  REMOTE_PORT=8000  ;;
  *)
    echo "[ERROR] 알 수 없는 백엔드: $BACKEND (ollama / vllm)"
    exit 1
    ;;
esac

echo " localhost:${LOCAL_PORT}  →  ${GPU_SERVER}:${REMOTE_PORT}"
echo ""
echo " [INFO] 연결 중... (최대 10초)"
echo ""
if ! ssh -fN -o ConnectTimeout=10 \
  -L "${LOCAL_PORT}:localhost:${REMOTE_PORT}" \
  -p "${SSH_PORT}" "${GPU_SERVER}"; then
  echo ""
  echo " [ERROR] SSH 연결 실패."
  echo "         호스트: ${GPU_SERVER}  포트: ${SSH_PORT}"
  echo ""
  exit 1
fi
echo ""
echo " [INFO] SSH 터널 연결 완료 (백그라운드 실행 중)"
echo ""
