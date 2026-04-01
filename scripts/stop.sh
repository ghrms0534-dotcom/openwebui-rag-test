#!/usr/bin/env bash
# ============================================
# Iteyes Open WebUI RAG - 서비스 중지
# 프로젝트 컨테이너를 중지한다 (볼륨은 유지).
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.yml"

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
echo " Iteyes Open WebUI RAG  ·  서비스 중지"
echo " ============================================="
echo ""
echo " [INFO] 프로젝트 컨테이너를 중지합니다."
echo ""

docker compose -f "$COMPOSE_FILE" down &>/dev/null &
_PID=$!
while kill -0 "$_PID" 2>/dev/null; do
  tick_spin
  show_progress 50 "[1/1] 컨테이너 중지 중..." "docker compose down" "$_SC"
  sleep 0.1
done
wait "$_PID"

step_done "[1/1] 컨테이너 중지" "완료"
printf "\n"
echo " ▶▶ 서비스 중지 완료"
echo ""
