#!/usr/bin/env bash
# Resolve python3 on NixOS (no python in minimal PATH) and elsewhere.
set -euo pipefail

bench_find_python() {
  if [[ -n "${BENCH_PYTHON:-}" ]]; then
    printf '%s\n' "$BENCH_PYTHON"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf '%s\n' python
    return 0
  fi
  if command -v nix-shell >/dev/null 2>&1; then
    printf '%s\n' nix-shell
    return 0
  fi
  return 1
}

bench_python() {
  local mode="${BENCH_PYTHON_MODE:-}"
  [[ -n "$mode" ]] || mode="$(bench_find_python)" || {
    printf '[bench] error: no python3 (set BENCH_PYTHON or: nix-shell -p python3)\n' >&2
    return 127
  }

  # Inline script via heredoc: bench_python - arg1 arg2 <<'PY'
  if [[ "${1:-}" == "-" ]]; then
    shift
    local tmp rc
    tmp="$(mktemp "${TMPDIR:-/tmp}/bench-python.XXXXXX")"
    cat >"$tmp"
    case "$mode" in
      nix-shell)
        # shellcheck disable=SC2046
        nix-shell -p python3 --run "python3 $(printf '%q ' "$tmp" "$@")"
        rc=$?
        ;;
      *)
        "$mode" "$tmp" "$@"
        rc=$?
        ;;
    esac
    rm -f "$tmp"
    return "$rc"
  fi

  case "$mode" in
    nix-shell)
      # shellcheck disable=SC2046
      nix-shell -p python3 --run "python3 $(printf '%q ' "$@")"
      ;;
    *)
      "$mode" "$@"
      ;;
  esac
}

if [[ -z "${BENCH_PYTHON_MODE:-}" ]]; then
  BENCH_PYTHON_MODE="$(bench_find_python 2>/dev/null || true)"
  export BENCH_PYTHON_MODE
fi
