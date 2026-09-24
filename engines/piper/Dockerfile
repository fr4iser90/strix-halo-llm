FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    curl wget ca-certificates python3 python3-pip \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN wget -q https://github.com/rhasspy/piper/releases/latest/download/piper_linux_x86_64.tar.gz \
    && tar -xzf piper_linux_x86_64.tar.gz \
    && rm piper_linux_x86_64.tar.gz \
    && chmod +x /app/piper/piper

RUN apt-get update && apt-get install -y python3-venv \
    && python3 -m venv /venv
ENV PATH="/venv/bin:$PATH"
RUN pip install --no-cache-dir fastapi uvicorn

COPY server.py /app/server.py

ENV PIPER_BIN=/app/piper/piper
ENV PIPER_VOICES_DIR=/voices
ENV PIPER_DEFAULT_VOICE=

EXPOSE 8080

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080"]
