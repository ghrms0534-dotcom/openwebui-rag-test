# Iteyes Open WebUI RAG - Tika (한국어 OCR 추가)
FROM apache/tika:3.2.3.0-full
USER root
RUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr-kor \
    && rm -rf /var/lib/apt/lists/*
COPY tika-config.xml /tika-config.xml
USER 35002
