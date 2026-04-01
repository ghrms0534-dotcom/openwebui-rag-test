"""
Iteyes Open WebUI RAG - LLM 에러 로거 (Filter Function)
에러 발생 시(모델 로드 실패, 서버 연결 끊김 등) errors.jsonl 파일에 기록한다.
정상 대화는 PostgreSQL에 저장되므로 별도 로깅 불필요.
start.sh가 매 시작 시 이 코드를 PostgreSQL function 테이블에 자동 주입한다.
"""

import json
import os
import re
import time
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        pipelines: list = ["*"]
        priority: int = 0
        log_dir: str = Field(
            default="/app/backend/data/logs",
            description="Error log directory path",
        )

    def __init__(self):
        self.valves = self.Valves()
        self._start_times: dict = {}

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        try:
            chat_id = body.get("metadata", {}).get("chat_id", "") or body.get("chat_id", "")
            self._start_times[chat_id] = time.time()
        except Exception:
            pass
        return body

    def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        try:
            chat_id = body.get("metadata", {}).get("chat_id", "") or body.get("chat_id", "")
            start = self._start_times.pop(chat_id, None)
            latency = round(time.time() - start, 2) if start else None

            # 마지막 assistant 메시지 추출
            messages = body.get("messages", [])
            assistant_msg = ""
            user_msg = ""
            for msg in reversed(messages):
                role = msg.get("role")
                if role == "assistant" and not assistant_msg:
                    # RAG 출처 태그(<details>...</details>) 제거
                    assistant_msg = re.sub(
                        r"<details[^>]*>.*?</details>", "", msg.get("content", ""), flags=re.DOTALL
                    ).strip()
                elif role == "user" and not user_msg:
                    content = msg.get("content", "")
                    # RAG 템플릿에서 [Question]...[Answer] 사이의 실제 질문만 추출
                    match = re.search(r"\[Question\]\s*(.+?)\s*\[Answer\]", content, re.DOTALL)
                    user_msg = match.group(1).strip() if match else content
                if assistant_msg and user_msg:
                    break

            # 에러 감지
            error_reason = None
            error_patterns = [
                (r"model failed to load|resource limitations", "모델 로드 실패 (GPU 메모리 부족)"),
                (r"server disconnected|disconnected",          "서버 연결 끊김"),
                (r"connection refused",                        "LLM 서버 연결 거부"),
                (r"timed out|timeout",                        "응답 시간 초과"),
                (r"^\d{3}:.*",                                assistant_msg),  # "500: Internal Server Error" 등 HTTP 에러 코드
            ]
            for pattern, reason in error_patterns:
                if re.search(pattern, assistant_msg, re.IGNORECASE):
                    error_reason = reason if reason != assistant_msg else assistant_msg
                    break

            if not error_reason and body.get("error"):
                error_reason = str(body["error"])

            # 에러인 경우에만 파일에 기록
            if error_reason:
                user_info = ""
                if __user__:
                    user_info = __user__.get("email", "") or __user__.get("name", "")

                entry = {
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                    "user": user_info,
                    "model": body.get("model", ""),
                    "question": user_msg[:200],
                    "error": error_reason[:300],
                    "latency_sec": latency,
                }

                log_dir = self.valves.log_dir
                os.makedirs(log_dir, exist_ok=True)
                log_path = os.path.join(log_dir, "errors.jsonl")
                with open(log_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(entry, ensure_ascii=False) + "\n")

        except Exception:
            pass

        return body
