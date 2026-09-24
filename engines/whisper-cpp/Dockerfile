FROM ubuntu:24.04

RUN apt update && apt install -y \
    git cmake build-essential \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN git clone https://github.com/ggml-org/whisper.cpp.git . \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j$(nproc)

RUN mkdir /models

EXPOSE 8080

CMD ["sleep", "infinity"]
