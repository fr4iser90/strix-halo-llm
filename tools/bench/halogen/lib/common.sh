#!/usr/bin/env bash
# Compat: shared helpers live in tools/bench/lib/http_openai.sh
# shellcheck shell=bash
_HALOGEN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_HALOGEN_LIB/../../../.." && pwd)"
# shellcheck source=../../lib/http_openai.sh
source "$PROJECT_ROOT/tools/bench/lib/http_openai.sh"
export BENCH_ENGINE="${BENCH_ENGINE:-halogen-flash}"
BENCH_ENGINE="$(bench_engine_normalize "$BENCH_ENGINE")"
export BENCH_ENGINE
HALOGEN_BASE_URL="$(bench_http_base_url)"
export HALOGEN_BASE_URL
