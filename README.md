# Iteyes Open WebUI 기반 RAG 시스템 구축 및 운영 방안

Open WebUI를 통해 PDF, DOCX, PPTX, XLSX, HWP 등의 문서를 업로드하면, 문서 내용을 자동으로 분석하여 벡터 DB에 저장한다. 이후 사용자가 자연어로 질문하면 관련 문서를 검색하여 LLM이 답변과 출처(citation)를 함께 제공한다.

## 시스템 구성도

```
사용자
  │
  ▼
Nginx (리버스 프록시, port 80)
  │
  ▼
Open WebUI (Chat UI + RAG 오케스트레이션, port 3000)
  │
  ├── vLLM / Ollama (LLM 추론 서버 - 외부 실행)
  ├── Qdrant (벡터 DB - 문서 임베딩 저장/검색)
  ├── PostgreSQL (메타데이터 - 사용자/채팅/설정)
  └── Apache Tika (문서 파싱 - PDF/DOCX/XLSX 등 텍스트 추출)
```

## 구성 요소 상세

이 프로젝트를 구성하는 모든 요소는 **무료 + 오픈소스 + 상업적 사용 가능** 라이선스이다.

| 구성 요소         | 기술                    | 버전         | 라이선스       | 역할 및 선택 이유                                                                                                                                                                                  |
| ----------------- | ----------------------- | ------------ | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Chat UI**       | Open WebUI              | v0.8.8       | BSD            | RAG 파이프라인 전체를 관리하는 웹 UI. Knowledge Base 업로드, 벡터 검색, LLM 연결, 사용자 관리를 한 곳에서 처리한다. 별도 코드 없이 설정만으로 RAG 시스템을 완성할 수 있어 선택                     |
| **리버스 프록시** | Nginx                   | 1.27-alpine  | BSD            | 포트 80으로 Open WebUI(3000)를 노출하여 사용자가 URL만으로 접속할 수 있게 한다. LLM API 경로(`/ollama/`)를 차단하여 내부 모델에 대한 외부 직접 접근을 방지하고, 향후 SSL(HTTPS) 적용에도 대비      |
| **LLM 추론**      | vLLM / Ollama           | 외부 실행    | Apache 2 / MIT | LLM 추론 서버. vLLM은 대형 모델(120b급) + GPU 고속 배치 처리에 적합하고, Ollama는 소형 모델을 간편하게 실행할 때 유용하다. Docker Compose 외부에서 별도로 실행하며, SSH 터널 또는 직접 연결로 사용 |
| **벡터 DB**       | Qdrant                  | v1.17.0      | Apache 2       | 문서 청크의 임베딩 벡터를 저장하고 유사도 검색을 수행한다. 하이브리드 검색(벡터 + 키워드)을 지원하여 검색 정확도를 높인다. REST API 기반으로 Open WebUI와 바로 연동 가능                           |
| **데이터베이스**  | PostgreSQL              | 16-alpine    | PostgreSQL     | 사용자 계정, 채팅 이력, RAG 설정(config 테이블), Knowledge Base 메타데이터를 저장한다. Open WebUI의 기본 DB 엔진으로 SQLite 대비 동시 접속과 백업/복원이 안정적                                    |
| **문서 파싱**     | Apache Tika             | 3.2.3.0-full | Apache 2       | PDF, DOCX, PPTX, XLSX, HWP 등 다양한 포맷에서 텍스트를 추출한다. `-full` 이미지 기반에 Tesseract OCR 한국어 패키지를 추가하여 스캔 문서에서도 텍스트를 인식할 수 있다                              |
| **임베딩 모델**   | BAAI/bge-m3             | -            | MIT            | 한국어에 최적화된 다국어 임베딩 모델(~2.2GB). 문서 청크를 벡터로 변환하여 Qdrant에 저장한다. Open WebUI가 내장 처리하므로 별도 서버 불필요                                                         |
| **리랭커**        | BAAI/bge-reranker-v2-m3 | -            | MIT            | 벡터 검색 결과를 재순위 매기는 모델(~1.1GB). 정확도를 높이지만 쿼리당 1~3초 추가 소요. 현재 비활성화 상태 (속도 우선)                                                                              |

## 프로젝트 구조

```
iteyes-openwebui-rag/
├── docker/
│   ├── docker-compose.yml          # 전체 서비스 오케스트레이션
│   ├── nginx.conf                  # Nginx 설정 (리버스 프록시 + LLM API 차단)
│   └── tika/
│       ├── Dockerfile              # apache/tika:3.2.3.0-full + tesseract-ocr-kor
│       └── tika-config.xml
├── config/
│   ├── env/
│   │   ├── local.env.example       # 로컬 개발용 환경변수 템플릿
│   │   ├── airgap.env.example      # 폐쇄망 DGX 배포용 환경변수 템플릿
│   │   ├── local.env               (gitignored, 사용자 생성)
│   │   └── airgap.env              (gitignored, dgx/install.sh가 자동 생성)
│   └── functions/
│       └── logging_filter.py       # LLM 에러 로깅 Filter Function
├── data/
│   └── documents/                  # 업로드 문서 저장
├── backups/                        (gitignored, 백업 파일 저장)
├── bundle/                         (gitignored, 폐쇄망 배포 번들 출력)
├── scripts/
│   ├── start.sh                    # 서비스 시작 + DB 설정 동기화
│   ├── stop.sh                     # 서비스 중지
│   ├── status.sh                   # 서비스 상태 대시보드
│   ├── backup.sh                   # 데이터 백업
│   ├── restore.sh                  # 데이터 복원
│   ├── reinstall.sh                # 클린 재설치
│   ├── setup-cron.sh               # 자동 백업 cron 관리
│   ├── query-logs.sh               # LLM 질의응답 실시간 로그
│   ├── error-logs.sh               # LLM 에러 로그 조회
│   ├── local/
│   │   ├── ssh-tunnel.sh           # SSH 터널 (로컬 모드 전용)
│   │   └── prepare-bundle.sh       # 폐쇄망 배포 번들 생성
│   ├── dgx/
│   │   ├── install.sh              # DGX 최초 설치
│   │   └── update.sh               # DGX 이미지 업데이트 (데이터 보존)
│   └── lib/
│       └── menu.sh                 # 화살표 키 메뉴 유틸리티
└── README.md
```

## 사전 요구사항

- Docker 및 Docker Compose v2
- LLM 추론 서버 (vLLM 또는 Ollama)가 실행 중이어야 한다

---

## DGX 폐쇄망 배포

> DGX Spark는 **ARM64(aarch64)** 아키텍처이다. 번들 생성 시 자동으로 `linux/arm64`로 빌드된다.

### 배포 흐름 요약

```
인터넷 환경(PC)                        폐쇄망(DGX)
─────────────────                    ─────────────────
1. prepare-bundle.sh
   (이미지 + 모델 캐시 + 설정 번들링)
              │
              ├── rsync / USB ──────► 2. dgx/install.sh
                                        (이미지 로드 + 모델 복원 + 환경설정)

                                      3. start.sh airgap
                                        (서비스 시작)
```

### 1단계: 번들 생성 (인터넷 환경)

인터넷이 연결된 PC에서 배포에 필요한 모든 파일을 묶어 번들로 만든다.

```bash
./scripts/local/prepare-bundle.sh
```

번들에 포함되는 것:

- Docker 이미지 5개를 ARM64용으로 pull/build 후 `.tar`로 저장 (~6GB)
- 임베딩 모델(bge-m3) 캐시 추출 (~2.2GB)
- 설정 파일, 스크립트, 문서

> 번들 생성 전 Open WebUI를 최소 1회 실행(`./scripts/start.sh local`)하여 임베딩 모델이 다운로드되어야 한다.

### 2단계: DGX로 전송

```bash
# rsync 권장 (대용량에 적합, 중단 시 재개 가능)
rsync -avP bundle/ iteyes@<dgx-ip>:~/iteyes-openwebui-rag/
```

예상 크기: **약 8GB**

### 3단계: DGX 최초 설치

```bash
cd ~/iteyes-openwebui-rag
./scripts/dgx/install.sh
```

install.sh가 수행하는 작업:

1. Docker 이미지 로드 (`docker load`) + 아키텍처(ARM64) 검증
2. `airgap.env` 생성 + WEBUI_SECRET_KEY, POSTGRES_PASSWORD 자동 생성
3. 임베딩 모델 캐시를 Docker 볼륨에 복원

### 4단계: LLM 확인 및 서비스 시작

`start.sh airgap`은 시작 시 포트를 자동 감지하여 LLM 백엔드를 활성화한다:

- **포트 8000** 응답 → vLLM(OpenAI 호환 API) 활성화
- **포트 11434** 응답 → Ollama 활성화

```bash
# LLM 서비스가 실행 중인지 먼저 확인
curl http://localhost:8000/v1/models    # vLLM
curl http://localhost:11434/api/tags    # Ollama

# 서비스 시작
./scripts/start.sh airgap
```

### 5단계: 접속

- http://localhost:3000 (직접 접속)
- http://localhost (Nginx 경유)
- **최초 접속 시 관리자 계정을 생성**해야 한다

### DGX 업데이트

새 버전으로 업데이트할 때는 인터넷 환경에서 번들을 재생성하여 DGX에 전송한 뒤 실행한다. 기존 데이터(문서, 채팅, 벡터)는 보존된다.

```bash
./scripts/dgx/update.sh
```

---

## 스크립트 안내

모든 스크립트는 실행 시 안내 메시지와 선택 메뉴를 제공하므로, 옵션을 외울 필요 없이 그대로 실행하면 된다.

### 서비스 관리

| 스크립트       | 기능                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `start.sh`     | 서비스 시작. 컨테이너 기동 → Open WebUI 준비 대기 → RAG 설정을 DB에 동기화까지 한 번에 처리한다. `local` 또는 `airgap` 모드를 선택하여 실행 |
| `stop.sh`      | 프로젝트의 모든 컨테이너를 중지한다. Docker 볼륨(데이터)은 삭제하지 않는다                                                                  |
| `status.sh`    | 컨테이너 상태, LLM 백엔드 연결, DB 크기, 디스크 사용량, 웹 접근, 마지막 백업 시각을 한 화면에 표시한다. 5초마다 자동 갱신                   |
| `reinstall.sh` | 컨테이너 + 볼륨 + 이미지를 모두 삭제하고 처음부터 재설치한다. **모든 데이터가 삭제**되므로 주의                                             |

### 데이터 백업/복원

| 스크립트        | 기능                                                                                                                 |
| --------------- | -------------------------------------------------------------------------------------------------------------------- |
| `backup.sh`     | Qdrant(문서 임베딩 벡터) + PostgreSQL(사용자, 채팅 이력, 설정) + 에러 로그를 백업한다. 30일 이상 된 백업은 자동 삭제 |
| `restore.sh`    | 백업 파일에서 Qdrant와 PostgreSQL 데이터를 복원한다. 복원할 백업을 선택할 수 있다                                    |
| `setup-cron.sh` | 매일 03:00에 자동 백업을 실행하는 cron 작업을 등록/확인/제거한다. 대화형 메뉴 제공                                   |

### 로그 모니터링

| 스크립트        | 기능                                                                                                                   |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `query-logs.sh` | 실행 이후 발생하는 LLM 질의응답을 실시간으로 표시한다. 사용자, 질문, 답변, 모델, 백엔드(vLLM/Ollama), 응답 시간을 출력 |
| `error-logs.sh` | LLM 에러 로그를 조회한다. 모델 로드 실패, 타임아웃 등 에러 발생 시 자동 기록된 내용을 확인할 수 있다                   |

### 폐쇄망 배포 전용

| 스크립트                  | 기능                                                                                      |
| ------------------------- | ----------------------------------------------------------------------------------------- |
| `local/prepare-bundle.sh` | 인터넷 환경에서 Docker 이미지 + 임베딩 모델 캐시 + 설정 파일을 하나의 번들로 묶는다       |
| `dgx/install.sh`          | DGX 최초 설치. 번들의 이미지를 로드하고, 환경설정을 생성하고, 임베딩 모델 캐시를 복원한다 |
| `dgx/update.sh`           | DGX 이미지 업데이트. 기존 데이터를 보존하면서 컨테이너 이미지만 교체한다                  |

---

## 주요 환경변수

환경변수는 `config/env/` 디렉토리의 `.env` 파일에서 관리한다. `start.sh`가 매 시작 시 DB에 설정을 동기화하므로 `.env` 파일이 단일 진실 소스(single source of truth)가 된다.

| 변수                        | 설명                                                        |
| --------------------------- | ----------------------------------------------------------- |
| `WEBUI_SECRET_KEY`          | JWT 인증 시크릿 키 (필수). 미설정 시 서비스 시작이 차단된다 |
| `ENABLE_OLLAMA_API`         | Ollama 활성화 여부 (`true` / `false`)                       |
| `OLLAMA_BASE_URL`           | Ollama 접속 주소                                            |
| `ENABLE_OPENAI_API`         | vLLM(OpenAI 호환 API) 활성화 여부 (`true` / `false`)        |
| `OPENAI_API_BASE_URL`       | vLLM 접속 주소                                              |
| `DATABASE_URL`              | PostgreSQL 연결 문자열                                      |
| `RAG_EMBEDDING_MODEL`       | 임베딩 모델 (`BAAI/bge-m3`)                                 |
| `RAG_TOP_K`                 | LLM에 전달할 검색 청크 수                                   |
| `CONTENT_EXTRACTION_ENGINE` | 문서 파싱 엔진 (`tika`)                                     |

### RAG 설정 자동 동기화

Open WebUI는 DB(config 테이블) 설정이 환경변수보다 우선한다. 이로 인해 Admin UI에서 수동으로 변경한 값이 `.env` 파일과 달라질 수 있다.

이를 방지하기 위해 `start.sh`가 매 시작 시 다음 RAG 설정을 DB에 강제 적용한다:

- chunk_size=400, chunk_overlap=80, chunk_min_size_target=150
- top_k=8, 리랭커 비활성화, 하이브리드 검색 활성화, relevance_threshold=0.1
- 영문 RAG 프롬프트 템플릿 (instruction following 최적화)

> Admin UI에서 수동 변경해도 다음 재시작 시 `.env` 파일의 값으로 복원된다.

---

## 사용 방법

### 문서 업로드

1. Workspace → Knowledge → Create Knowledge Base
2. 문서 업로드 (PDF, DOCX, PPTX, XLSX, TXT, HTML, Markdown 지원)

### RAG 질의

1. Chat에서 Knowledge Base를 선택
2. 자연어로 질문 입력
3. LLM이 문서 내용 기반 답변과 출처(citation)를 제공

---

## 문제 해결

| 증상                      | 해결 방법                                                                                                               |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| LLM 연결 실패             | LLM 서비스 실행 여부 확인. vLLM: `curl http://localhost:8000/v1/models`, Ollama: `curl http://localhost:11434/api/tags` |
| SECRET_KEY 미설정 오류    | `openssl rand -hex 32` 실행 후 `.env` 파일의 `WEBUI_SECRET_KEY`에 입력                                                  |
| 로그인 세션 만료          | SECRET_KEY 변경 시 기존 세션이 무효화된다. 재로그인 필요                                                                |
| exec format error (DGX)   | 번들 이미지 아키텍처 불일치. `./scripts/local/prepare-bundle.sh --force`로 재생성                                       |
| 임베딩 모델 오류 (폐쇄망) | 모델 캐시 누락. `./scripts/dgx/update.sh --update-models` 실행                                                          |
| 문서 파싱 실패            | Tika 컨테이너 로그 확인: `docker compose -f docker/docker-compose.yml logs tika`                                        |

### 컨테이너 로그 확인

```bash
docker compose -f docker/docker-compose.yml logs open-webui     # Open WebUI
docker compose -f docker/docker-compose.yml logs -f open-webui  # 실시간
docker compose -f docker/docker-compose.yml logs postgres       # PostgreSQL
docker compose -f docker/docker-compose.yml logs qdrant         # Qdrant
docker compose -f docker/docker-compose.yml logs tika           # Tika
```

---

## 보안

- LLM 서버는 외부에 노출하지 않는다
- 내부 네트워크 또는 SSH 터널을 통해서만 접근
- Nginx에서 `/ollama/` 경로를 차단하여 LLM API 외부 직접 접근 방지
- 모든 모델은 로컬에서 실행 (외부 API 사용 없음)
- WEBUI_SECRET_KEY는 반드시 랜덤 값으로 설정 (미설정 시 시작 차단)

---

## Docker 볼륨

| 볼륨                              | 내용                                 |
| --------------------------------- | ------------------------------------ |
| `iteyes-openwebui-rag_open-webui` | Open WebUI 데이터 + 임베딩 모델 캐시 |
| `iteyes-openwebui-rag_postgres`   | PostgreSQL 데이터베이스              |
| `iteyes-openwebui-rag_qdrant`     | 벡터 임베딩 데이터                   |

---

## 로컬 개발 환경 (SSH 터널 모드)

로컬 PC에서 개발/테스트할 때 사용한다. GPU 서버의 LLM에 SSH 터널로 연결한다.

### 환경 설정

```bash
cp config/env/local.env.example config/env/local.env

# WEBUI_SECRET_KEY 생성 후 local.env에 입력
openssl rand -hex 32
```

### SSH 터널 연결

```bash
# Ollama (포트 11434)
./scripts/local/ssh-tunnel.sh user@gpu-server

# vLLM (포트 8000)
ssh -L 8000:localhost:8000 user@gpu-server -fN
```

### 서비스 시작

```bash
./scripts/start.sh local
```

### 접속

- http://localhost:3000 (직접)
- http://localhost (Nginx 경유)
- 최초 접속 시 관리자 계정 생성
