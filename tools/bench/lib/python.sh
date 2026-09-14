#!/usr/bin/env bash
# Resolve python3 on NixOS (no python in minimal PATH) and elsewhere.
#
# Never uses TMPDIR/mktemp under /tmp/nix-shell-* (vanishes → overnight crash).
# Heredoc scripts go to output/bench/.scratch/ or python3 stdin.
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

# Stable scratch under the repo (survives SSH / nix-shell exit).
bench_scratch_dir() {
  local root="${PROJECT_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  fi
  local d="$root/output/bench/.scratch"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

bench_python() {
  local mode="${BENCH_PYTHON_MODE:-}"
  [[ -n "$mode" ]] || mode="$(bench_find_python)" || {
    printf '[bench] error: no python3 (set BENCH_PYTHON or: nix-shell -p python3)\n' >&2
    return 127
  }

  # Inline script: bench_python - arg1 arg2 <<'PY'
  if [[ "${1:-}" == "-" ]]; then
    shift
    local rc=0
    case "$mode" in
      nix-shell)
        local scratch script
        scratch="$(bench_scratch_dir)"
        script="$scratch/py-$$-$RANDOM.py"
        cat >"$script"
        # Drop broken nix TMPDIR so nested nix-shell does not recreate the failure mode
        # shellcheck disable=SC2046
        env -u TMPDIR nix-shell -p python3 --run "python3 $(printf '%q ' "$script" "$@")"
        rc=$?
        rm -f "$script"
        return "$rc"
        ;;
      *)
        # Host python: script on stdin, no file
        "$mode" - "$@"
        return $?
        ;;
    esac
  fi

  case "$mode" in
    nix-shell)
      # shellcheck disable=SC2046
      env -u TMPDIR nix-shell -p python3 --run "python3 $(printf '%q ' "$@")"
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
