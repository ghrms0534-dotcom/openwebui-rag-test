# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

사내 문서 기반 RAG LLM QA 시스템. Open WebUI + Qdrant + PostgreSQL + Apache Tika를 Docker Compose로 구성한다. LLM 서빙은 vLLM 또는 Ollama를 외부에서 연결한다 (SSH 터널 또는 직접). 코드를 직접 작성하는 프로젝트가 아니라, Docker 기반 인프라 구성 프로젝트이다.

## Commands

```bash
# 서비스 시작 (local 모드 - SSH 터널로 GPU 서버 연결)
./scripts/start.sh local

# 서비스 시작 (airgap 모드 - 폐쇄망 DGX Spark)
./scripts/start.sh airgap

# 서비스 중지
./scripts/stop.sh

# SSH 터널 (local 모드에서 Ollama 연결, vLLM은 수동)
./scripts/local/ssh-tunnel.sh user@gpu-server          # Ollama (11434)
ssh -L 8000:localhost:8000 user@gpu-server -fN         # vLLM (8000)

# 서비스 상태 확인
./scripts/status.sh

# 백업 / 복원
./scripts/backup.sh
./scripts/restore.sh             # 최신 백업 자동 선택
./scripts/restore.sh 20260324_030000  # 특정 날짜

# 자동 백업 cron 설정
./scripts/setup-cron.sh            # 매일 03:00 등록
./scripts/setup-cron.sh --status   # 상태 확인
./scripts/setup-cron.sh --remove   # 제거

# 폐쇄망 배포 번들 생성 (인터넷 환경에서)
./scripts/local/prepare-bundle.sh

# DGX 최초 설치 (폐쇄망에서)
./scripts/dgx/install.sh

# DGX 이미지 업데이트 (데이터 보존)
./scripts/dgx/update.sh

# 클린 재설치 (컨테이너 + 볼륨 + 이미지 삭제 후 재설치)
./scripts/reinstall.sh local
./scripts/reinstall.sh airgap

# 로그 확인
docker compose -f docker/docker-compose.yml logs open-webui
docker compose -f docker/docker-compose.yml logs -f open-webui

# LLM 질의응답 실시간 로그
./scripts/query-logs.sh

# LLM 에러 로그
./scripts/error-logs.sh           # 최근 50건
./scripts/error-logs.sh -n 20     # 최근 20건
./scripts/error-logs.sh --follow  # 실시간

# 전체 초기화 (컨테이너 + 볼륨 삭제)
docker compose -f docker/docker-compose.yml down -v
```

## Architecture

- **docker/docker-compose.yml**: 전체 서비스 오케스트레이션. compose project name은 `iteyes-openwebui-rag`
- **config/env/**: local.env (로컬 개발용), airgap.env (폐쇄망 DGX 배포용)
- **scripts/start.sh**: SECRET_KEY 가드 → 서비스 시작 → open-webui ready 대기 → PostgreSQL DB에 RAG 설정 강제 동기화. ENV_FILE 환경변수로 env 파일 선택
- **scripts/backup.sh / restore.sh**: Qdrant + PostgreSQL + 에러 로그 백업/복원. 30일 자동 정리
- Open WebUI가 embedding(bge-m3)을 내장 처리. 리랭커(bge-reranker-v2-m3)는 기본 비활성화
- **LLM 백엔드**: local → vLLM(8000)/Ollama(11434) SSH 터널, airgap → vLLM/Ollama 자동 감지
- qdrant/tika 컨테이너에는 curl/wget이 없으므로 healthcheck는 `bash /dev/tcp` 사용
- PostgreSQL, Qdrant, Open WebUI 데이터는 모두 Docker named volume 사용

## DB vs ENV 설정 우선순위

Open WebUI는 DB(config 테이블) 설정이 ENV보다 우선한다. `start.sh`가 매 시작 시 다음 RAG 설정을 DB에 강제 적용하여 ENV 파일을 단일 진실 소스(single source of truth)로 유지한다:

- chunk_size, chunk_overlap, chunk_min_size_target
- top_k, top_k_reranker, reranking_model
- relevance_threshold, enable_hybrid_search
- RAG template

DB 컬럼 타입은 `json`(not jsonb)이므로 `data::jsonb`로 캐스팅 후 jsonb_set 적용, 결과를 `::json`으로 되돌린다.

## Docker Image Versions

모든 이미지는 버전 고정되어 있다:
- `ghcr.io/open-webui/open-webui:v0.8.8`
- `apache/tika:3.2.3.0-full` + tesseract-ocr-kor 커스텀 빌드 (주의: x.y.z.0 형식)
- `qdrant/qdrant:v1.17.0`
- `postgres:16-alpine`
- `nginx:1.27-alpine`

## Key Constraints

- 모든 컴포넌트는 무료 + 오픈소스 + 상업적 사용 가능 라이선스
- 외부 API 사용 금지, 모든 모델 로컬 실행
- LLM 서버 외부 노출 금지
- Open WebUI는 third-party Docker 이미지로, 내부 코드 수정 불가
- **절대 다운로드 오래 걸리는 모델 캐시 삭제 금지** (bge-m3 ~2.2GB, bge-reranker-v2-m3 ~1.1GB)

## Air-gapped Deployment (폐쇄망)

DGX Spark 폐쇄망 배포를 위한 모드: `local`, `airgap`

- **airgap 모드**: vLLM/Ollama 자동 감지 (port 8000/11434 체크), `HF_HUB_OFFLINE=1`
- **vLLM 실행**: `docker run -d --gpus all --ipc=host -v ~/.cache/huggingface:/root/.cache/huggingface -e HF_HUB_OFFLINE=1 -p 8000:8000 nvcr.io/nvidia/vllm:25.12.post1-py3 vllm serve <model> --host 0.0.0.0 --port 8000`
- **scripts/local/prepare-bundle.sh**: 인터넷 환경에서 Docker 이미지 + 임베딩 모델 캐시를 번들로 생성
- **scripts/dgx/install.sh**: DGX에서 이미지 로드 + 모델 캐시 복원 + airgap.env 자동 생성
- **scripts/dgx/update.sh**: 이미지만 업데이트 (데이터 보존, `docker compose down -v` 절대 금지)
- **scripts/reinstall.sh**: 클린 재설치 (컨테이너 + 볼륨 + 이미지 삭제 후 start.sh 호출)
- 상세 가이드: `docs/DEPLOYMENT.md`
