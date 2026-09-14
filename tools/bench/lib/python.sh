#!/usr/bin/env bash
# Resolve python3 on NixOS (no python in minimal PATH) and elsewhere.
#
# Never uses TMPDIR/mktemp under /tmp/nix-shell-* (vanishes → overnight crash).
# Heredoc scripts go to output/bench/.scratch/ or python3 stdin.
#
# Prefer output/bench/.venv-quality when present (HumanEval / pip packages).
set -euo pipefail

bench_repo_root() {
  local root="${PROJECT_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  fi
  printf '%s\n' "$root"
}

bench_quality_venv_python() {
  local py
  py="$(bench_repo_root)/output/bench/.venv-quality/bin/python3"
  if [[ -x "$py" ]]; then
    printf '%s\n' "$py"
    return 0
  fi
  return 1
}

# NixOS: pip numpy in a venv needs libstdc++ from nixpkgs (not on default PATH/lib).
bench_ensure_libstdcxx() {
  if [[ -n "${BENCH_LIBSTDCXX_DONE:-}" ]]; then
    return 0
  fi
  export BENCH_LIBSTDCXX_DONE=1
  # Already resolvable?
  if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q 'libstdc++\.so\.6'; then
    return 0
  fi
  if [[ -n "${NIX_CC:-}" && -d "${NIX_CC}/lib" ]]; then
    export LD_LIBRARY_PATH="${NIX_CC}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    return 0
  fi
  if command -v nix-build >/dev/null 2>&1; then
    local lib
    lib="$(env -u TMPDIR nix-build --no-out-link -E 'with import <nixpkgs> {}; stdenv.cc.cc.lib' 2>/dev/null || true)"
    if [[ -n "$lib" && -d "$lib/lib" ]]; then
      export LD_LIBRARY_PATH="${lib}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      return 0
    fi
  fi
  return 0
}

bench_find_python() {
  if [[ -n "${BENCH_PYTHON:-}" ]]; then
    printf '%s\n' "$BENCH_PYTHON"
    return 0
  fi
  if py="$(bench_quality_venv_python 2>/dev/null)"; then
    printf '%s\n' "$py"
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
  local d
  d="$(bench_repo_root)/output/bench/.scratch"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

bench_python() {
  local mode="${BENCH_PYTHON_MODE:-}"
  [[ -n "$mode" ]] || mode="$(bench_find_python)" || {
    printf '[bench] error: no python3 (set BENCH_PYTHON or: nix-shell -p python3)\n' >&2
    return 127
  }
  # venv + numpy on NixOS
  case "$mode" in
    */.venv-quality/*|*/output/bench/.venv-quality/*)
      bench_ensure_libstdcxx || true
      ;;
  esac

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
