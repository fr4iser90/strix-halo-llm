#!/bin/sh
# Docker entrypoint: optional Web UI via LLAMA_WEBUI (default: true).
# false|0|off|no → pass --no-webui to llama-server. API endpoints unchanged.
set -e

BIN="/bin/llama-server"
if [ -x /app/llama-server ]; then
  BIN="/app/llama-server"
fi
# ROCm compose historically put the binary path in command[0]
case "${1:-}" in
  */llama-server|/bin/llama-server|/app/llama-server)
    BIN="$1"
    shift
    ;;
esac

case "${LLAMA_WEBUI:-true}" in
  0|false|FALSE|False|off|OFF|no|NO)
    set -- --no-webui "$@"
    ;;
esac

exec "$BIN" "$@"
