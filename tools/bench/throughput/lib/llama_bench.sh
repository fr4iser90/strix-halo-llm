#!/usr/bin/env bash
# llama-bench: PP/TG on Vulkan, ROCm, and/or CPU (sourced from run.sh).
# Stops sticky/lab first — llama-bench and serve share the GPU.
set -euo pipefail
export LC_ALL=C LANG=C

# When sourced from run.sh, PROJECT_ROOT is already set.
THROUGHPUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$THROUGHPUT_ROOT/../../.." && pwd)}"
MODELS_DIR="${MODELS_DIR:-$PROJECT_ROOT/models}"
OUT_DIR="${BENCH_OUT:-$PROJECT_ROOT/output/bench/throughput}"
SERVICE="${BENCH_SERVICE:-llama}"

PP="${BENCH_PP:-512}"
TG="${BENCH_TG:-128}"
NGL="${BENCH_NGL:-99}"
NGL_CPU="${BENCH_NGL_CPU:-0}"

VK_BIN="${BENCH_VK_BIN:-/bin/llama-bench}"
ROCM_BIN="${BENCH_ROCM_BIN:-/app/llama-bench}"
VK_COMPOSE="${PROJECT_ROOT}/compose.yaml"
ROCM_COMPOSE="${PROJECT_ROOT}/compose.rocm.yaml"

# shellcheck source=server.sh
source "$THROUGHPUT_ROOT/lib/server.sh"

usage() {
  cat <<'EOF'
Usage: ./bench throughput [options] [filter]
       (also: tools/bench/throughput/run.sh)

Suites (default: --bench → models-bench.ini):
  --bench       models-bench.ini (synced from sticky/lab; default)
  --daily       models.ini (sticky chat)
  --lab         models-lab.ini
  --all         every chat/*.gguf except mmproj / mtp draft files

Backends (default: Vulkan + ROCm):
  --vulkan      RADV via host Nix Mesa
  --rocm        ROCm container
  --cpu         CPU only (-ngl 0)
  --both        Vulkan + ROCm
  --all-backends   Vulkan + ROCm + CPU
  --backends LIST  comma list: vulkan,rocm,cpu,gpu,all

Models:
  --list        show matched GGUFs and exit
  --models PAT  comma-separated name patterns (repeatable: -m PAT)
  filter        positional substring match (legacy)

Other:
  --compare     historical merge across all CSVs in output/bench/throughput/
  --compare-run rebuild table from newest stamped run only
  --no-compare  skip compare after a run
  --no-restore  do not restart sticky/embeddings after bench

Examples:
  ./bench throughput --vulkan
  ./bench throughput --backends vulkan,cpu --bench
  ./bench throughput --all-backends --all
  ./bench throughput -m Qwen3.8 -m Nemotron --rocm
  ./bench list bench
  ./bench                              # interactive menu

EOF
}

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

want_vk=0
want_rocm=0
want_cpu=0
backend_explicit=0
ALL=0
DAILY=0
LAB=0
BENCH=0
FILTER=""
MODEL_PATTERNS=()
LIST_ONLY=0
COMPARE_ONLY=0
COMPARE_RUN=0
NO_COMPARE=0
NO_RESTORE=0
THROUGHPUT_SYNC_SOURCES="${THROUGHPUT_SYNC_SOURCES:-coder,chat,lab}"

enable_backend() {
  case "$1" in
    vulkan|vk) want_vk=1 ;;
    rocm) want_rocm=1 ;;
    cpu) want_cpu=1 ;;
    gpu|both) want_vk=1; want_rocm=1 ;;
    all) want_vk=1; want_rocm=1; want_cpu=1 ;;
    *) die "unknown backend: $1 (use vulkan, rocm, cpu, gpu, all)" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) LIST_ONLY=1 ;;
    --compare) COMPARE_ONLY=1 ;;
    --compare-run) COMPARE_RUN=1 ;;
    --no-compare) NO_COMPARE=1 ;;
    --no-restore) NO_RESTORE=1 ;;
    --all) ALL=1 ;;
    --daily) DAILY=1 ;;
    --bench) BENCH=1 ;;
    --lab|--heavy) LAB=1 ;;
    --vulkan) enable_backend vulkan; backend_explicit=1 ;;
    --rocm) enable_backend rocm; backend_explicit=1 ;;
    --cpu) enable_backend cpu; backend_explicit=1 ;;
    --both) enable_backend both; backend_explicit=1 ;;
    --all-backends) enable_backend all; backend_explicit=1 ;;
    --backends)
      shift
      [[ $# -gt 0 ]] || die "--backends needs a comma-separated list"
      backend_explicit=1
      IFS=',' read -ra _parts <<< "$1"
      for _b in "${_parts[@]}"; do
        _b="${_b// /}"
        [[ -n "$_b" ]] || continue
        enable_backend "$_b"
      done
      ;;
    --models|-m)
      shift
      [[ $# -gt 0 ]] || die "--models needs a pattern"
      IFS=',' read -ra _parts <<< "$1"
      for _p in "${_parts[@]}"; do
        _p="${_p// /}"
        [[ -n "$_p" ]] && MODEL_PATTERNS+=("$_p")
      done
      ;;
    --) shift; while [[ $# -gt 0 ]]; do MODEL_PATTERNS+=("$1"); shift; done; break ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$FILTER" ]]; then
        FILTER="$1"
      else
        MODEL_PATTERNS+=("$1")
      fi
      ;;
  esac
  shift
done

[[ "$NO_RESTORE" -eq 1 ]] && export BENCH_NO_RESTORE=1 THROUGHPUT_NO_RESTORE=1

if [[ "$backend_explicit" -eq 0 ]]; then
  want_vk=1
  want_rocm=1
fi

if [[ "$ALL" -eq 0 && "$DAILY" -eq 0 && "$LAB" -eq 0 && "$BENCH" -eq 0 ]]; then
  BENCH=1
fi

SUITE="bench"
if [[ "$ALL" -eq 1 ]]; then
  SUITE="all"
elif [[ "$DAILY" -eq 1 && "$LAB" -eq 1 ]]; then
  SUITE="mix"
elif [[ "$BENCH" -eq 1 && ( "$DAILY" -eq 1 || "$LAB" -eq 1 ) ]]; then
  SUITE="mix"
elif [[ "$LAB" -eq 1 ]]; then
  SUITE="lab"
elif [[ "$DAILY" -eq 1 ]]; then
  SUITE="daily"
elif [[ "$BENCH" -eq 1 ]]; then
  SUITE="bench"
fi

backends_label() {
  local parts=()
  [[ "$want_vk" -eq 1 ]] && parts+=("vulkan")
  [[ "$want_rocm" -eq 1 ]] && parts+=("rocm")
  [[ "$want_cpu" -eq 1 ]] && parts+=("cpu")
  (IFS=,+; printf '%s' "${parts[*]}")
}

is_skip() {
  local base="$1"
  [[ "$base" == *mmproj* ]] && return 0
  [[ "$base" == mtp-* ]] && return 0
  return 1
}

lab_ini() {
  if [[ -f "$PROJECT_ROOT/models-lab.ini" ]]; then
    printf '%s\n' "$PROJECT_ROOT/models-lab.ini"
  elif [[ -f "$PROJECT_ROOT/models-heavy.ini" ]]; then
    printf '%s\n' "$PROJECT_ROOT/models-heavy.ini"
  else
    die "missing models-lab.ini"
  fi
}

bench_ini() {
  local ini="${THROUGHPUT_BENCH_INI:-$PROJECT_ROOT/models-bench.ini}"
  [[ -f "$ini" ]] || die "missing $ini — run: ./bench capacity sync --from coder,chat,lab"
  printf '%s\n' "$ini"
}

ensure_bench_ini() {
  [[ "$BENCH" -eq 1 ]] || return 0
  export THROUGHPUT_DO_SYNC=1
  throughput_sync_bench_ini
}

collect_ini() {
  local ini="$1" line path base found
  [[ -f "$ini" ]] || die "missing $ini"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*\; ]] && continue
    [[ "$line" =~ ^[[:space:]]*model[[:space:]]*=[[:space:]]*(.+)$ ]] || continue
    path="${BASH_REMATCH[1]}"
    path="${path// /}"
    base="$(basename "$path")"
    is_skip "$base" && continue
    found="$(find "$MODELS_DIR/chat" -type f -name "$base" 2>/dev/null | head -n1)"
    [[ -n "$found" ]] && printf '%s\n' "$found"
  done <"$ini"
}

collect_all() {
  find "$MODELS_DIR/chat" -type f -name '*.gguf' | sort
}

matches_patterns() {
  local base="$1" pat
  local patterns=()
  [[ -n "$FILTER" ]] && patterns+=("$FILTER")
  if [[ ${#MODEL_PATTERNS[@]} -gt 0 ]]; then
    patterns+=("${MODEL_PATTERNS[@]}")
  fi
  [[ ${#patterns[@]} -eq 0 ]] && return 0
  for pat in "${patterns[@]}"; do
    [[ "$base" == *"$pat"* ]] && return 0
  done
  return 1
}

resolve_wayland_lib() {
  local radeon="$1" wl=""
  [[ -n "$radeon" && -f "$radeon" ]] || return 1
  wl="$(ldd "$radeon" 2>/dev/null | awk '/libwayland-client\.so/ { print $3; exit }')"
  if [[ -z "$wl" || ! -f "$wl" ]]; then
    wl="$(ldd /nix/store/*/lib/libvulkan_radeon.so 2>/dev/null | awk '/libwayland-client/ { print $3; exit }')"
  fi
  if [[ -z "$wl" || ! -f "$wl" ]]; then
    wl="$(ls /nix/store/*/lib/libwayland-client.so.0 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$wl" && -f "$wl" ]] || return 1
  printf '%s\n' "$wl"
}

mkdir -p "$OUT_DIR/latest"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT_DIR/llama-bench-$STAMP-$SUITE.log"
VK_CSV="$OUT_DIR/llama-bench-$STAMP-$SUITE-vulkan.csv"
ROCM_CSV="$OUT_DIR/llama-bench-$STAMP-$SUITE-rocm.csv"
CPU_CSV="$OUT_DIR/llama-bench-$STAMP-$SUITE-cpu.csv"
CMP="$OUT_DIR/latest/compare.md"

mapfile -t CANDIDATES < <(
  if [[ "$ALL" -eq 1 ]]; then
    collect_all
  else
    [[ "$BENCH" -eq 1 ]] && { ensure_bench_ini; collect_ini "$(bench_ini)"; }
    [[ "$DAILY" -eq 1 ]] && collect_ini "$PROJECT_ROOT/models.ini"
    [[ "$LAB" -eq 1 ]] && collect_ini "$(lab_ini)"
  fi
)

FILES=()
declare -A SEEN=()
for p in "${CANDIDATES[@]}"; do
  [[ -f "$p" ]] || continue
  base="$(basename "$p")"
  is_skip "$base" && continue
  matches_patterns "$base" || continue
  [[ -n "${SEEN[$p]:-}" ]] && continue
  SEEN["$p"]=1
  FILES+=("$p")
done

if [[ "$LIST_ONLY" -eq 1 ]]; then
  printf 'suite=%s backends=%s models=%s\n' "$SUITE" "$(backends_label)" "${#FILES[@]}"
  if [[ ${#FILES[@]} -eq 0 ]]; then
    die "no GGUFs matched"
  fi
  local_i=0
  for p in "${FILES[@]}"; do
    local_i=$((local_i + 1))
    printf '%3d  %s\n' "$local_i" "$(basename "$p")"
  done
  exit 0
fi

if [[ "$COMPARE_ONLY" -eq 0 && "$COMPARE_RUN" -eq 0 ]]; then
  [[ ${#FILES[@]} -gt 0 ]] || die "no GGUFs matched (copy models.ini / download first)"
  log "${#FILES[@]} model(s) suite=$SUITE backends=$(backends_label) → $OUT_DIR"
  if [[ "$want_vk" -eq 1 || "$want_rocm" -eq 1 ]]; then
    throughput_bench_prepare
    trap throughput_bench_cleanup EXIT
  fi
fi

VK_DOCKER_OPTS=()
VK_ICD=""

setup_vk_docker_opts() {
  [[ -e /dev/dri/renderD128 || -e /dev/dri/renderD129 ]] || die "missing /dev/dri/renderD*"
  # llama-cpp-vulkan-nix ships Mesa/RADV. Do not inject host /run/opengl-driver or LD_PRELOAD.
  log "vulkan docker opts: /dev/dri only (nix-native image)"
  VK_DOCKER_OPTS=(
    -v /dev/dri:/dev/dri
  )
}

preflight_vulkan() {
  setup_vk_docker_opts
  log "vulkan preflight llama-bench=$VK_BIN (nix image has no vulkaninfo)"
  local summary rc=0
  summary="$(cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" run --rm --no-deps --quiet-pull \
    "${VK_DOCKER_OPTS[@]}" \
    --entrypoint "$VK_BIN" "$SERVICE" --help 2>&1)" || rc=$?
  printf '%s\n' "$summary" | tee -a "$LOG"
  if printf '%s\n' "$summary" | grep -qi 'Unable to find group'; then
    die "compose group_add failed. Remove group_add from compose.yaml and retry --vulkan."
  fi
  if [[ "$rc" -ne 0 ]]; then
    die "llama-bench --help failed in vulkan container (rc=$rc). Check image llama-cpp-vulkan-nix and --entrypoint $VK_BIN."
  fi
}

compose_run() {
  local compose="$1" bin="$2" ctn_gguf="$3" ngl="${4:-$NGL}"
  shift 4 || true
  local extra=()
  if [[ "$compose" == "$VK_COMPOSE" ]]; then
    extra=("${VK_DOCKER_OPTS[@]}")
  fi
  (cd "$PROJECT_ROOT" && docker compose -f "$compose" run --rm --no-deps --quiet-pull \
    "${extra[@]}" \
    --entrypoint "$bin" "$SERVICE" \
    -m "$ctn_gguf" -ngl "$ngl" -fa 1 -p "$PP" -n "$TG" -o csv "$@")
}

run_one() {
  local backend="$1" host_gguf="$2"
  local rel="${host_gguf#"$MODELS_DIR"/}"
  local ctn_gguf="/models/$rel"
  case "$backend" in
    vulkan)
      [[ -f "$VK_COMPOSE" ]] || die "missing $VK_COMPOSE"
      compose_run "$VK_COMPOSE" "$VK_BIN" "$ctn_gguf" "$NGL"
      ;;
    rocm)
      [[ -f "$ROCM_COMPOSE" ]] || die "missing $ROCM_COMPOSE"
      compose_run "$ROCM_COMPOSE" "$ROCM_BIN" "$ctn_gguf" "$NGL"
      ;;
    cpu)
      [[ -f "$VK_COMPOSE" ]] || die "missing $VK_COMPOSE"
      compose_run "$VK_COMPOSE" "$VK_BIN" "$ctn_gguf" "$NGL_CPU"
      ;;
    *) die "backend $backend" ;;
  esac
}

run_pass() {
  local backend="$1" csv="$2"
  local i=0 f base
  : >"$csv"
  log "=== $backend ==="
  for f in "${FILES[@]}"; do
    i=$((i + 1))
    base="$(basename "$f")"
    log "[$backend $i/${#FILES[@]}] $base"
    {
      echo "======== $backend $base ========"
      if ! run_one "$backend" "$f" | tee -a "$csv"; then
        echo "FAILED $backend $base"
      fi
      echo
    } | tee -a "$LOG"
    if [[ "$backend" == vulkan && "$i" -eq 1 ]]; then
      grep -q '"Vulkan"' "$csv" \
        || die "first Vulkan row is not GPU (CSV backends=CPU). Host Mesa not visible in the container — see compose.yaml /run/opengl-driver."
    fi
  done
}

if [[ "$COMPARE_ONLY" -eq 0 && "$COMPARE_RUN" -eq 0 ]]; then
  [[ "$want_vk" -eq 1 ]] && preflight_vulkan && run_pass vulkan "$VK_CSV"
  [[ "$want_rocm" -eq 1 ]] && run_pass rocm "$ROCM_CSV"
  [[ "$want_cpu" -eq 1 ]] && run_pass cpu "$CPU_CSV"
fi

extract_ts() {
  local csv="$1"
  [[ -f "$csv" && -s "$csv" ]] || return 0
  awk '
    function unq(s) { gsub(/^"/, "", s); gsub(/"$/, "", s); return s }
    function parse(line, out,    n, i, c, field, inq) {
      n = 0; field = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { inq = 1 - inq; continue }
        if (c == "," && inq == 0) { out[++n] = field; field = ""; continue }
        field = field c
      }
      out[++n] = field
      return n
    }
    function base(p,    a, n) { n = split(p, a, "/"); return a[n] }
    {
      if ($0 ~ /^========/ || $0 ~ /^FAILED/ || $0 ~ /^ggml_/ || $0 ~ /^main:/ || $0 == "") next
      n = parse($0, f)
      if ($0 ~ /avg_ts/ && $0 ~ /model_filename/) {
        for (i = 1; i <= n; i++) {
          h = unq(f[i])
          if (h == "model_filename") mf = i
          if (h == "n_prompt") np = i
          if (h == "n_gen") ng = i
          if (h == "avg_ts") ts = i
        }
        next
      }
      if (!mf || !ts) next
      path = unq(f[mf])
      if (path !~ /[.]gguf/) next
      name = base(path)
      names[name] = 1
      n_prompt = unq(f[np]) + 0
      n_gen = unq(f[ng]) + 0
      val = unq(f[ts]) + 0
      if (n_prompt > 0 && n_gen == 0) pp[name] = val
      else if (n_gen > 0) tg[name] = val
    }
    END {
      for (name in names) printf "%s\t%s\t%s\n", name, (name in pp ? pp[name] : ""), (name in tg ? tg[name] : "")
    }
  ' "$csv"
}

merge_extract() {
  local kind="$1" needle="$2" f name pp tg
  shift 2
  local -a only=()
  [[ $# -gt 0 ]] && only=("$@")
  declare -A have=()
  for f in $(ls -1t "$OUT_DIR"/llama-bench-*-"$kind".csv 2>/dev/null); do
    if [[ ${#only[@]} -gt 0 ]]; then
      local ok=0 of
      for of in "${only[@]}"; do
        [[ "$f" == "$of" ]] && ok=1 && break
      done
      [[ "$ok" -eq 1 ]] || continue
    fi
    grep -q "\"$needle\"" "$f" || continue
    while IFS=$'\t' read -r name pp tg; do
      [[ -n "$name" ]] || continue
      [[ -n "${have[$name]:-}" ]] && continue
      have["$name"]=1
      printf '%s\t%s\t%s\n' "$name" "$pp" "$tg"
    done < <(extract_ts "$f")
  done
}

backend_csv_count() {
  local kind="$1" needle="$2" f n=0
  shift 2
  local -a only=()
  [[ $# -gt 0 ]] && only=("$@")
  for f in "$OUT_DIR"/llama-bench-*-"$kind".csv; do
    [[ -f "$f" ]] || continue
    if [[ ${#only[@]} -gt 0 ]]; then
      local ok=0 of
      for of in "${only[@]}"; do
        [[ "$f" == "$of" ]] && ok=1 && break
      done
      [[ "$ok" -eq 1 ]] || continue
    fi
    grep -q "\"$needle\"" "$f" && n=$((n + 1))
  done
  printf '%s' "$n"
}

md_table_sep() {
  local n="$1" i sep="|"
  for ((i = 0; i < n; i++)); do sep="${sep}---|"; done
  printf '%s\n' "$sep"
}

short_name() {
  local n="${1%.gguf}"
  n="${n#NVIDIA-}"
  n="${n/-Instruct-2507/}"
  n="${n/-Instruct/}"
  n="${n/-UD-/-}"
  n="${n/-RotorQuant-/-Rotor-}"
  n="${n/-TurboQuant-/-Turbo-}"
  printf '%s' "$n"
}

fmt_ts() {
  [[ -n "${1:-}" ]] || { printf '—'; return; }
  awk -v x="$1" 'BEGIN { printf "%.1f", x + 0 }'
}

delta_ts() {
  local a="${1:-}" b="${2:-}"
  if [[ -z "$a" || -z "$b" ]]; then
    printf '—'
    return
  fi
  awk -v a="$a" -v b="$b" 'BEGIN {
    if (a + 0 == 0) { print "—"; exit }
    pct = (b - a) / a * 100
    printf "%s%.0f%%", (pct >= 0 ? "+" : ""), pct
  }'
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

load_compare_run() {
  local f base name found
  f=""
  for f in $(ls -1t "$OUT_DIR"/llama-bench-*-*-*.csv 2>/dev/null); do
    grep -qE '"(Vulkan|ROCm|CPU)"' "$f" || continue
    break
  done
  [[ -n "$f" && -f "$f" ]] || die "no bench CSV with GPU/CPU rows in $OUT_DIR"
  base="$(basename "$f" .csv)"
  if [[ "$base" =~ ^llama-bench-(.+)-(daily|mix|lab|all|bench)-(vulkan|rocm|cpu)$ ]]; then
    STAMP="${BASH_REMATCH[1]}"
    SUITE="${BASH_REMATCH[2]}"
  else
    die "cannot parse bench CSV name: $base"
  fi
  VK_CSV="$OUT_DIR/llama-bench-${STAMP}-${SUITE}-vulkan.csv"
  ROCM_CSV="$OUT_DIR/llama-bench-${STAMP}-${SUITE}-rocm.csv"
  CPU_CSV="$OUT_DIR/llama-bench-${STAMP}-${SUITE}-cpu.csv"
  LOG="$OUT_DIR/llama-bench-$STAMP-$SUITE.log"
  want_vk=0
  want_rocm=0
  want_cpu=0
  [[ -f "$VK_CSV" ]] && grep -q '"Vulkan"' "$VK_CSV" && want_vk=1
  [[ -f "$ROCM_CSV" ]] && grep -q '"ROCm"' "$ROCM_CSV" && want_rocm=1
  [[ -f "$CPU_CSV" ]] && grep -q '"CPU"' "$CPU_CSV" && want_cpu=1
  [[ $((want_vk + want_rocm + want_cpu)) -gt 0 ]] || die "no GPU/CPU rows in latest run $STAMP/$SUITE"
  FILES=()
  declare -A seen=()
  for f in "$VK_CSV" "$ROCM_CSV" "$CPU_CSV"; do
    [[ -f "$f" ]] || continue
    while IFS=$'\t' read -r name _pp _tg; do
      [[ -n "$name" ]] || continue
      [[ -n "${seen[$name]:-}" ]] && continue
      found="$(find "$MODELS_DIR/chat" -type f -name "$name" 2>/dev/null | head -n1)"
      [[ -n "$found" ]] || continue
      seen["$name"]=1
      FILES+=("$found")
    done < <(extract_ts "$f")
  done
  [[ ${#FILES[@]} -gt 0 ]] || die "no models in latest run $STAMP/$SUITE"
  log "compare-run stamp=$STAMP suite=$SUITE backends=$(backends_label)"
}

write_compare() {
  local scope="${1:-run}"
  declare -A vk_pp vk_tg rocm_pp rocm_tg cpu_pp cpu_tg
  local name html vk_n rocm_n cpu_n cols ncol show_vk show_rocm show_cpu
  local -a model_names run_csvs=() scope_note

  mkdir -p "$OUT_DIR/latest"
  html="$OUT_DIR/latest/compare.html"
  CMP="$OUT_DIR/latest/compare.md"

  if [[ "$scope" == run ]]; then
    show_vk=$want_vk
    show_rocm=$want_rocm
    show_cpu=$want_cpu
    [[ "$show_vk" -eq 1 && -f "$VK_CSV" ]] && run_csvs+=("$VK_CSV")
    [[ "$show_rocm" -eq 1 && -f "$ROCM_CSV" ]] && run_csvs+=("$ROCM_CSV")
    [[ "$show_cpu" -eq 1 && -f "$CPU_CSV" ]] && run_csvs+=("$CPU_CSV")
    scope_note="This run only ($STAMP, suite=$SUITE, backends=$(backends_label))."
    for f in "${FILES[@]}"; do
      model_names+=("$(basename "$f")")
    done
    vk_n=$([[ "$show_vk" -eq 1 && -f "$VK_CSV" ]] && grep -q '"Vulkan"' "$VK_CSV" && echo 1 || echo 0)
    rocm_n=$([[ "$show_rocm" -eq 1 && -f "$ROCM_CSV" ]] && grep -q '"ROCm"' "$ROCM_CSV" && echo 1 || echo 0)
    cpu_n=$([[ "$show_cpu" -eq 1 && -f "$CPU_CSV" ]] && grep -q '"CPU"' "$CPU_CSV" && echo 1 || echo 0)
    while IFS=$'\t' read -r name pp tg; do
      [[ -n "$name" ]] || continue
      vk_pp["$name"]="$pp"
      vk_tg["$name"]="$tg"
    done < <(merge_extract vulkan Vulkan "$VK_CSV")
    while IFS=$'\t' read -r name pp tg; do
      [[ -n "$name" ]] || continue
      rocm_pp["$name"]="$pp"
      rocm_tg["$name"]="$tg"
    done < <(merge_extract rocm ROCm "$ROCM_CSV")
    while IFS=$'\t' read -r name pp tg; do
      [[ -n "$name" ]] || continue
      cpu_pp["$name"]="$pp"
      cpu_tg["$name"]="$tg"
    done < <(merge_extract cpu CPU "$CPU_CSV")
  else
    show_vk=1
    show_rocm=1
    show_cpu=1
    scope_note="Historical merge: latest result per model across all CSVs in \`$OUT_DIR\`."
    vk_n="$(backend_csv_count vulkan Vulkan)"
    rocm_n="$(backend_csv_count rocm ROCm)"
    cpu_n="$(backend_csv_count cpu CPU)"
    [[ "$vk_n" -gt 0 || "$rocm_n" -gt 0 || "$cpu_n" -gt 0 ]] || die "no bench CSV in $OUT_DIR"
    while IFS=$'\t' read -r name pp tg; do
      [[ -n "$name" ]] || continue
      vk_pp["$name"]="$pp"
      vk_tg["$name"]="$tg"
      model_names+=("$name")
    done < <(merge_extract vulkan Vulkan)
    while IFS=$'\t' read -r name pp tg; do
      [[ -n "$name" ]] || continue
      rocm_pp["$name"]="$pp"
      rocm_tg["$name"]="$tg"
      model_names+=("$name")
    done < <(merge_extract rocm ROCm)
    while IFS=$'\t' read -r name pp tg; do
      [[ -n "$name" ]] || continue
      cpu_pp["$name"]="$pp"
      cpu_tg["$name"]="$tg"
      model_names+=("$name")
    done < <(merge_extract cpu CPU)
    show_rocm=$([[ "$rocm_n" -gt 0 ]] && echo 1 || echo 0)
    show_vk=$([[ "$vk_n" -gt 0 ]] && echo 1 || echo 0)
    show_cpu=$([[ "$cpu_n" -gt 0 ]] && echo 1 || echo 0)
  fi

  [[ ${#model_names[@]} -gt 0 ]] || die "no models for compare table"

  {
    echo "# llama-bench compare"
    echo
    echo "$scope_note"
    echo
    if [[ "$scope" == history ]]; then
      echo "- Vulkan sources: $vk_n file(s) · ROCm: $rocm_n · CPU: $cpu_n"
    fi
    echo "- pp = prompt tok/s ($PP), tg = generation tok/s ($TG). Higher is better."
    cols="model"
    [[ "$show_vk" -eq 1 ]] && cols="$cols | Vulkan pp | Vulkan tg"
    [[ "$show_rocm" -eq 1 ]] && cols="$cols | ROCm pp | ROCm tg"
    [[ "$show_cpu" -eq 1 ]] && cols="$cols | CPU pp | CPU tg"
    if [[ "$show_vk" -eq 1 && "$show_rocm" -eq 1 ]]; then
      cols="$cols | pp Δ vk→rocm | tg Δ vk→rocm"
    fi
    ncol=$(awk -F'|' '{print NF}' <<< "$cols")
    echo
    echo "| $cols |"
    md_table_sep "$ncol"
    printf '%s\n' "${model_names[@]}" | sort -u | while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      local_row="| $(short_name "$name")"
      [[ "$show_vk" -eq 1 ]] && local_row="$local_row | $(fmt_ts "${vk_pp[$name]:-}") | $(fmt_ts "${vk_tg[$name]:-}")"
      [[ "$show_rocm" -eq 1 ]] && local_row="$local_row | $(fmt_ts "${rocm_pp[$name]:-}") | $(fmt_ts "${rocm_tg[$name]:-}")"
      [[ "$show_cpu" -eq 1 ]] && local_row="$local_row | $(fmt_ts "${cpu_pp[$name]:-}") | $(fmt_ts "${cpu_tg[$name]:-}")"
      if [[ "$show_vk" -eq 1 && "$show_rocm" -eq 1 ]]; then
        local_row="$local_row | $(delta_ts "${vk_pp[$name]:-}" "${rocm_pp[$name]:-}") | $(delta_ts "${vk_tg[$name]:-}" "${rocm_tg[$name]:-}")"
      fi
      printf '%s |\n' "$local_row"
    done
  } >"$CMP"

  {
    cat <<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>llama-bench compare</title>
<style>
:root { color-scheme: dark; }
body { font: 15px/1.45 system-ui, sans-serif; margin: 2rem; background: #12141a; color: #e8eaed; }
h1 { font-size: 1.25rem; }
.meta, .foot { color: #9aa0a6; }
table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
th, td { padding: 0.5rem 0.7rem; border-bottom: 1px solid #2a2e37; }
th { text-align: left; color: #9aa0a6; font-weight: 600; }
td.n { text-align: right; font-variant-numeric: tabular-nums; font-family: ui-monospace, monospace; }
.pos { color: #7ddea5; } .neg { color: #f0a0a0; }
</style></head><body>
<h1>llama-bench compare</h1>
<p class="meta">$(html_escape "$scope_note")<br>
pp${PP} prompt tok/s · tg${TG} generation tok/s · higher is better</p>
<table><thead><tr>
EOF
    echo -n '<th>model</th>'
    [[ "$show_vk" -eq 1 ]] && echo -n '<th class="n">Vulkan pp</th><th class="n">Vulkan tg</th>'
    [[ "$show_rocm" -eq 1 ]] && echo -n '<th class="n">ROCm pp</th><th class="n">ROCm tg</th>'
    [[ "$show_cpu" -eq 1 ]] && echo -n '<th class="n">CPU pp</th><th class="n">CPU tg</th>'
    if [[ "$show_vk" -eq 1 && "$show_rocm" -eq 1 ]]; then
      echo -n '<th class="n">pp Δ</th><th class="n">tg Δ</th>'
    fi
    echo '</tr></thead><tbody>'
    printf '%s\n' "${model_names[@]}" | sort -u | while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      dpp="—"; dtg="—"; cpp="n"; ctg="n"
      if [[ "$show_vk" -eq 1 && "$show_rocm" -eq 1 ]]; then
        dpp="$(delta_ts "${vk_pp[$name]:-}" "${rocm_pp[$name]:-}")"
        dtg="$(delta_ts "${vk_tg[$name]:-}" "${rocm_tg[$name]:-}")"
        [[ "$dpp" == +* ]] && cpp="n pos"; [[ "$dpp" == -* ]] && cpp="n neg"
        [[ "$dtg" == +* ]] && ctg="n pos"; [[ "$dtg" == -* ]] && ctg="n neg"
      fi
      printf '<tr><td>%s</td>' "$(short_name "$name")"
      [[ "$show_vk" -eq 1 ]] && printf '<td class="n">%s</td><td class="n">%s</td>' "$(fmt_ts "${vk_pp[$name]:-}")" "$(fmt_ts "${vk_tg[$name]:-}")"
      [[ "$show_rocm" -eq 1 ]] && printf '<td class="n">%s</td><td class="n">%s</td>' "$(fmt_ts "${rocm_pp[$name]:-}")" "$(fmt_ts "${rocm_tg[$name]:-}")"
      [[ "$show_cpu" -eq 1 ]] && printf '<td class="n">%s</td><td class="n">%s</td>' "$(fmt_ts "${cpu_pp[$name]:-}")" "$(fmt_ts "${cpu_tg[$name]:-}")"
      if [[ "$show_vk" -eq 1 && "$show_rocm" -eq 1 ]]; then
        printf '<td class="%s">%s</td><td class="%s">%s</td>' "$cpp" "$dpp" "$ctg" "$dtg"
      fi
      echo '</tr>'
    done
    echo '</tbody></table><p class="foot">Markdown: output/bench/throughput/latest/compare.md</p></body></html>'
  } >"$html"

  cp -f "$CMP" "$OUT_DIR/llama-bench-$STAMP-compare.md"
  log "latest → $CMP"
  log "html    → $html"
  cat "$CMP"
}

if [[ "$COMPARE_RUN" -eq 1 ]]; then
  load_compare_run
  write_compare run
  [[ -f "$PROJECT_ROOT/tools/bench/build-index.sh" ]] && bash "$PROJECT_ROOT/tools/bench/build-index.sh" || true
  exit 0
fi

if [[ "$COMPARE_ONLY" -eq 1 ]]; then
  write_compare history
  [[ -f "$PROJECT_ROOT/tools/bench/build-index.sh" ]] && bash "$PROJECT_ROOT/tools/bench/build-index.sh" || true
  exit 0
fi

if [[ "$NO_COMPARE" -eq 0 ]]; then
  write_compare run | tee -a "$LOG"
fi

INDEX="$PROJECT_ROOT/tools/bench/build-index.sh"
if [[ -f "$INDEX" ]]; then
  bash "$INDEX" 2>/dev/null || true
fi

log "done. log: $LOG"
