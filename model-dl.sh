#!/usr/bin/env bash
# Download models from Hugging Face into MODELS_ROOT layout:
#   gguf/chat|embeddings|extractor  ·  tts/  ·  stt/  ·  hgn/<pack>/
# Works on NixOS, Debian/Ubuntu, Fedora, Arch, etc. (installs hf CLI if missing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load .env if present (optional — defaults work without it)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi
# Parent of gguf/hgn/stt/tts. Default: ~/data/models if present, else ./models
if [[ -z "${MODELS_ROOT:-}" ]]; then
  if [[ -d "${HOME}/data/models" ]]; then
    MODELS_ROOT="${HOME}/data/models"
  else
    MODELS_ROOT="$SCRIPT_DIR/models"
  fi
fi
MODELS_DIR="${MODELS_DIR:-$MODELS_ROOT/gguf}"
CATALOG="${CATALOG:-$SCRIPT_DIR/models.catalog.tsv}"
INI_DIR="${LLAMA_INI_DIR:-$SCRIPT_DIR/engines/llama-cpp}"
INI_FILES=("$INI_DIR/models.ini" "$INI_DIR/models-embeddings.ini" "$INI_DIR/models-extractor.ini")

HF_CMD=""
USE_NIX_HF=0

usage() {
  cat <<'EOF'
Usage: ./model-dl.sh <command> [options]

Commands:
  list              Show local status for all catalog + ini models
  download          Missing models referenced by models.ini (+ embeddings/extractor)
  download <name>   Download by partial filename (also heavy catalog / TTS / STT)
  install-cli       Install huggingface-cli only
  init-dirs         Create MODELS_ROOT/{gguf,hgn,stt,tts}/…

Environment:
  MODELS_ROOT       Parent tree — default ~/data/models if that dir exists, else ./models
  MODELS_DIR        GGUF root (default: \$MODELS_ROOT/gguf)
  LLAMA_INI_DIR     Live models*.ini dir (default: ./engines/llama-cpp)
  CATALOG           Catalog TSV path (default: ./models.catalog.tsv)
  HF_TOKEN          Hugging Face token (gated models)
  HF_HUB_ENABLE_HF_TRANSFER=1   Faster downloads (needs hf_transfer)

No .env required. Optional .env overrides the defaults above.

Catalog format (models.catalog.tsv):
  local_filename<TAB>subdir<TAB>hf_repo<TAB>remote_filename
  subdir relative to MODELS_ROOT (e.g. gguf/chat/large, tts, stt)
EOF
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

prepend_path() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
}

# --- huggingface CLI (cross-distro) ---

run_hf() {
  if [[ "$USE_NIX_HF" -eq 1 ]]; then
    # Attribute is python3Packages.huggingface-hub (mainProgram=hf), not huggingface-cli
    nix shell "nixpkgs#python3Packages.huggingface-hub" -c hf "$@"
  else
    "$HF_CMD" "$@"
  fi
}

detect_hf_cli() {
  if have_cmd hf; then
    HF_CMD=hf
    return 0
  fi
  if have_cmd huggingface-cli; then
    HF_CMD=huggingface-cli
    return 0
  fi
  prepend_path "$HOME/.local/bin"
  prepend_path "$HOME/.cargo/bin"
  if have_cmd hf; then
    HF_CMD=hf
    return 0
  fi
  if have_cmd huggingface-cli; then
    HF_CMD=huggingface-cli
    return 0
  fi
  if have_cmd nix; then
    USE_NIX_HF=1
    return 0
  fi
  return 1
}

install_hf_cli() {
  detect_hf_cli && {
    if [[ "$USE_NIX_HF" -eq 1 ]]; then
      log "huggingface CLI via: nix shell nixpkgs#python3Packages.huggingface-hub"
    else
      log "huggingface CLI already available ($HF_CMD)"
    fi
    return 0
  }

  log "huggingface CLI not found — installing..."

  if have_cmd pipx; then
    pipx install 'huggingface_hub[cli]' || pipx upgrade huggingface_hub
    prepend_path "$HOME/.local/bin"
    detect_hf_cli && return 0
  fi

  if have_cmd uv; then
    uv tool install 'huggingface_hub[cli]'
    prepend_path "$HOME/.local/bin"
    detect_hf_cli && return 0
  fi

  if have_cmd pip3; then
    pip3 install --user 'huggingface_hub[cli]'
    prepend_path "$HOME/.local/bin"
    detect_hf_cli && return 0
  fi

  if have_cmd pip; then
    pip install --user 'huggingface_hub[cli]'
    prepend_path "$HOME/.local/bin"
    detect_hf_cli && return 0
  fi

  if have_cmd apt-get; then
    if ! have_cmd pip3; then
      log "Installing python3-pip (requires sudo)..."
      sudo apt-get update -qq
      sudo apt-get install -y python3-pip
    fi
    pip3 install --user 'huggingface_hub[cli]'
    prepend_path "$HOME/.local/bin"
    detect_hf_cli && return 0
  fi

  if have_cmd dnf; then
    if ! have_cmd pip3; then
      log "Installing python3-pip (requires sudo)..."
      sudo dnf install -y python3-pip
    fi
    pip3 install --user 'huggingface_hub[cli]'
    prepend_path "$HOME/.local/bin"
    detect_hf_cli && return 0
  fi

  if have_cmd pacman; then
    if ! have_cmd pip; then
      log "Installing python-pip (requires sudo)..."
      sudo pacman -S --needed --noconfirm python-pip
    fi
    pip install --user 'huggingface_hub[cli]'
    prepend_path "$HOME/.local/bin"
    detect_hf_cli && return 0
  fi

  if have_cmd nix; then
    USE_NIX_HF=1
    log "Using nix shell nixpkgs#python3Packages.huggingface-hub (hf)"
    return 0
  fi

  die "Could not install huggingface CLI. On NixOS: nix shell nixpkgs#python3Packages.huggingface-hub -c hf --help"
}

ensure_hf_cli() {
  detect_hf_cli || install_hf_cli
  detect_hf_cli || die "huggingface CLI still not available after install"
}

# --- directories ---

init_dirs() {
  mkdir -p \
    "$MODELS_ROOT/gguf/chat/large" \
    "$MODELS_ROOT/gguf/chat/medium" \
    "$MODELS_ROOT/gguf/chat/small" \
    "$MODELS_ROOT/gguf/embeddings" \
    "$MODELS_ROOT/gguf/extractor" \
    "$MODELS_ROOT/gguf/multimodal" \
    "$MODELS_ROOT/hgn" \
    "$MODELS_ROOT/stt" \
    "$MODELS_ROOT/tts" \
    "$MODELS_ROOT/.cache/hf-dl"
  # Keep MODELS_DIR pointing at gguf tree for callers
  MODELS_DIR="${MODELS_DIR:-$MODELS_ROOT/gguf}"
  log "Directories ready under $MODELS_ROOT (gguf → $MODELS_DIR)"
}

# Normalize catalog subdir to MODELS_ROOT-relative path.
normalize_subdir() {
  local sub="$1"
  case "$sub" in
    gguf/*|hgn/*|stt/*|tts/*|hgn|stt|tts) printf '%s' "$sub" ;;
    *) printf 'gguf/%s' "$sub" ;;
  esac
}

# --- catalog parsing ---

declare -A CAT_SUBDIR CAT_REPO CAT_REMOTE

load_catalog() {
  [[ -f "$CATALOG" ]] || die "Catalog not found: $CATALOG"
  local line local_name subdir repo remote
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//$'\r'/}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    IFS=$'\t' read -r local_name subdir repo remote <<<"$line"
    # strip whitespace / accidental newlines from fields
    local_name="${local_name//$'\n'/}"
    subdir="${subdir//$'\n'/}"
    repo="${repo//$'\n'/}"
    remote="${remote//$'\n'/}"
    local_name="${local_name#"${local_name%%[![:space:]]*}"}"
    local_name="${local_name%"${local_name##*[![:space:]]}"}"
    subdir="${subdir#"${subdir%%[![:space:]]*}"}"
    subdir="${subdir%"${subdir##*[![:space:]]}"}"
    repo="${repo#"${repo%%[![:space:]]*}"}"
    repo="${repo%"${repo##*[![:space:]]}"}"
    remote="${remote#"${remote%%[![:space:]]*}"}"
    remote="${remote%"${remote##*[![:space:]]}"}"
    [[ -n "$local_name" && -n "$subdir" ]] || continue
    subdir="$(normalize_subdir "$subdir")"
    CAT_SUBDIR["$local_name"]="$subdir"
    CAT_REPO["$local_name"]="${repo:-}"
    CAT_REMOTE["$local_name"]="${remote:-$local_name}"
  done <"$CATALOG"
}

# Collect model paths referenced in *.ini (basename -> subdir from catalog or path)
declare -A INI_WANTED

load_ini_targets() {
  local ini line path base sub
  for ini in "${INI_FILES[@]}"; do
    [[ -f "$ini" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*\; ]] && continue
      # model / mmproj / model-draft (-md) — anything that must exist on disk
      [[ "$line" =~ ^[[:space:]]*(model|mmproj|model-draft|spec-draft-model|md)[[:space:]]*=[[:space:]]*(.+)$ ]] || continue
      path="${BASH_REMATCH[2]}"
      path="${path// /}"
      base="$(basename "$path")"
      INI_WANTED["$base"]=1
    done <"$ini"
  done
}

model_dest() {
  local name="$1"
  local sub="${CAT_SUBDIR[$name]:-}"
  [[ -n "$sub" ]] || die "No subdir in catalog for: $name"
  sub="$(normalize_subdir "$sub")"
  printf '%s/%s/%s' "$MODELS_ROOT" "$sub" "$name"
}

is_present() {
  local dest="$1"
  [[ -f "$dest" ]] && [[ -s "$dest" ]]
}

download_one() {
  local name="$1"
  local repo="${CAT_REPO[$name]:-}"
  local remote="${CAT_REMOTE[$name]:-$name}"
  local dest subdir tmp

  [[ -n "${CAT_SUBDIR[$name]:-}" ]] || die "Unknown model (not in catalog): $name"
  [[ -n "$repo" ]] || die "No Hugging Face repo for $name — add it to $CATALOG or download manually"

  dest="$(model_dest "$name")"
  if is_present "$dest"; then
    log "skip (exists): $name"
    return 0
  fi

  init_dirs
  ensure_hf_cli
  subdir="$(dirname "$dest")"
  mkdir -p "$subdir"
  # Persistent staging dir so interrupted downloads can resume (not mktemp).
  tmp="$MODELS_ROOT/.cache/hf-dl/${name}"
  mkdir -p "$tmp"

  log "download: $repo :: $remote -> $dest (staging $tmp)"
  if [[ -n "${HF_TOKEN:-}" ]]; then
    run_hf download "$repo" "$remote" --local-dir "$tmp" --token "$HF_TOKEN"
  else
    run_hf download "$repo" "$remote" --local-dir "$tmp"
  fi

  local fetched="$tmp/$remote"
  [[ -f "$fetched" ]] || die "Download failed: $remote not in $tmp"
  mv "$fetched" "$dest"
  log "done: $dest ($(du -h "$dest" | cut -f1))"
  # Keep hub metadata under staging; drop large blobs if any leftover
  find "$tmp" -name '*.incomplete' -delete 2>/dev/null || true
}

cmd_list() {
  load_catalog
  load_ini_targets
  init_dirs

  printf '%-45s %-18s %-10s %s\n' "MODEL" "SUBDIR" "STATUS" "HF_REPO"
  printf '%s\n' "$(printf '%.0s-' {1..100})"

  local name
  for name in $(printf '%s\n' "${!CAT_SUBDIR[@]}" | sort); do
    local dest status repo ini_mark=""
    dest="$(model_dest "$name")"
    repo="${CAT_REPO[$name]:-}"
    if is_present "$dest"; then
      status="present"
    else
      status="missing"
    fi
    [[ -n "${INI_WANTED[$name]:-}" ]] && ini_mark=" [ini]"
    if [[ -z "$repo" ]]; then
      repo="(manual)"
    fi
    printf '%-45s %-18s %-10s %s%s\n' "$name" "${CAT_SUBDIR[$name]}" "$status" "$repo" "$ini_mark"
  done

  # ini models without catalog entry
  local base
  for base in "${!INI_WANTED[@]}"; do
    [[ -n "${CAT_SUBDIR[$base]:-}" ]] && continue
    warn "in models.ini but not in catalog: $base"
  done
}

cmd_download() {
  local filter="${1:-}"
  load_catalog
  load_ini_targets

  local names=()
  local name
  for name in $(printf '%s\n' "${!CAT_SUBDIR[@]}" | sort); do
    [[ -n "${CAT_REPO[$name]:-}" ]] || continue
    if [[ -n "$filter" && "$name" != *"$filter"* ]]; then
      continue
    fi
    if [[ -z "$filter" && -z "${INI_WANTED[$name]:-}" ]]; then
      continue
    fi
    names+=("$name")
  done

  if [[ ${#names[@]} -eq 0 ]]; then
    if [[ -n "$filter" ]]; then
      die "No catalog match for: $filter"
    fi
    warn "Nothing to download (all ini models present or no HF repo in catalog)"
    return 0
  fi

  for name in "${names[@]}"; do
    download_one "$name"
  done
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    list)       cmd_list ;;
    download)   cmd_download "${1:-}" ;;
    install-cli) install_hf_cli ;;
    init-dirs)  init_dirs ;;
    -h|--help|help|"") usage ;;
    *) die "Unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
