#!/usr/bin/env bash
# Engine adapter: llama.cpp
# Matrix-level lifecycle is a no-op — capacity/sched/quality/throughput each own
# llama-bench-a via their lib/server.sh. This file exists so
# `bench_engine_prepare llama.cpp` is a valid, documented hook for future shared use.
#
# shellcheck shell=bash

engine_llama_cpp_base_url() {
  printf '%s\n' "${CAPACITY_URL_A:-${QUALITY_BASE_URL:-http://127.0.0.1:11601}}"
}

engine_llama_cpp_prepare() {
  if declare -F bench_lifecycle_log >/dev/null 2>&1; then
    bench_lifecycle_log "llama.cpp — suites own llama-bench-a lifecycle (no matrix-level start)"
  fi
  return 0
}

engine_llama_cpp_cleanup() {
  return 0
}
