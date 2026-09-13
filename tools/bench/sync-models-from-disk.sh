#!/usr/bin/env bash
# Sync models-*.ini from files under ./models/ (prune missing, add new GGUFs).
#
#   ./bench sync-models
#   ./bench sync-models --dry-run
#   ./bench sync-models --prune
#
# Sticky INIs (models.ini, models-coder.ini): only prune missing paths unless
# --touch-sticky (still does not auto-pick a new sticky model).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/python.sh
source "$SCRIPT_DIR/lib/python.sh"

DRY=0
PRUNE=1
TOUCH_STICKY=0
MODELS_DIR="$ROOT/models"

usage() {
  cat <<'EOF'
Usage: ./bench sync-models [options]

Scan ./models/**/*.gguf and update INIs automatically:
  models-lab.ini          chat weights (+ VL variants when mmproj exists)
  models-embeddings.ini   embeddings/
  models-extractor.ini    extractor/
  models.ini / models-coder.ini
                          only prune dead paths (keep chosen sticky)

Options:
  --dry-run         show plan, write nothing
  --no-prune        keep INI sections even if GGUF missing
  --touch-sticky    also prune dead sticky sections
  --models-dir DIR  default ./models
  -h|--help

After sync, refresh bench presets:
  ./bench capacity sync --from coder,chat,lab
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-prune) PRUNE=0; shift ;;
    --touch-sticky) TOUCH_STICKY=1; shift ;;
    --models-dir) shift; MODELS_DIR="${1:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -d "$MODELS_DIR" ]] || { echo "missing models dir: $MODELS_DIR" >&2; exit 1; }

bench_python - "$ROOT" "$MODELS_DIR" "$DRY" "$PRUNE" "$TOUCH_STICKY" <<'PY'
import json, os, re, sys
from pathlib import Path

root = Path(sys.argv[1])
models_dir = Path(sys.argv[2])
dry = sys.argv[3] == "1"
prune = sys.argv[4] == "1"
touch_sticky = sys.argv[5] == "1"

def container_path(host: Path) -> str:
    rel = host.relative_to(models_dir).as_posix()
    return f"/models/{rel}"

def parse_ini(path: Path):
    if not path.is_file():
        return [], {}
    order, sections, header = [], {}, []
    cur = None
    saw_section = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not saw_section and (not line or line.startswith(";")):
            header.append(raw)
            continue
        if line.startswith("[") and line.endswith("]"):
            saw_section = True
            cur = line[1:-1].strip()
            if cur not in sections:
                sections[cur] = []
                order.append(cur)
            continue
        if cur is None:
            header.append(raw)
            continue
        if not line or line.startswith(";") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        sections[cur] = [(kk, vv) for kk, vv in sections[cur] if kk != k]
        sections[cur].append((k, v))
    return order, sections, header

def write_ini(path: Path, header, order, sections, banner_lines):
    lines = list(banner_lines)
    if header and not any("AUTO-GENERATED" in h or "sync-models" in h for h in header):
        # keep human header comments once
        for h in header:
            if h.strip().startswith(";") or not h.strip():
                lines.append(h if h.endswith("\n") or True else h)
    # simplify: always use our banner + blank
    lines = banner_lines + [""]
    for name in order:
        lines.append(f"[{name}]")
        for k, v in sections[name]:
            lines.append(f"{k} = {v}")
        lines.append("")
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    if dry:
        print(f"DRY {path.name}: {len(order)} section(s)")
        return
    path.write_text(text, encoding="utf-8")
    print(f"wrote {path.name}: {len(order)} section(s)")

# Discover GGUFs
all_gguf = sorted(models_dir.rglob("*.gguf"))
# skip incomplete multipart shards except -00001-of-
primaries = []
aux = {"mmproj": [], "mtp": []}
for p in all_gguf:
    name = p.name
    if re.search(r"-0{2,}[2-9]\d*-of-\d+\.gguf$", name, re.I):
        continue  # non-first shard
    low = name.lower()
    if low.startswith("mmproj") or "-mmproj-" in low or low.startswith("mmproj-"):
        aux["mmproj"].append(p)
        continue
    if low.startswith("mtp-"):
        aux["mtp"].append(p)
        continue
    primaries.append(p)

def find_mmproj(stem: str, family_hints):
    # exact / family match in same dir or chat/large
    cands = aux["mmproj"]
    for hint in family_hints:
        for m in cands:
            if hint.lower() in m.name.lower():
                return m
    return None

def family_hints(name: str):
    hints = []
    if "Qwen3.6" in name:
        hints += ["Qwen3.6-mmproj", "Qwen3.6"]
    if "Flash-Next" in name:
        hints += ["Flash-Next-mmproj", "Flash-Next"]
    if "Qwen3.8" in name and "Flash" not in name:
        hints += ["Qwen3.8-mmproj", "mmproj-Qwen3.8", "Qwen3.8"]
    if "Tiel" in name or "Cyber-Tiel" in name:
        hints += ["Tiel-Coder-mmproj", "Tiel"]
    return hints

def defaults_for(path: Path, name: str, is_vl=False):
    pairs = [
        ("model", container_path(path)),
        ("ngl", "99"),
        ("fa", "on"),
        ("jinja", "1"),
        ("ctk", "q8_0"),
        ("ctv", "q8_0"),
        ("fit", "off"),
        ("np", "2"),
        ("c", "262144"),
        ("b", "64"),
        ("ub", "256"),
    ]
    if "small" in path.parts or "medium" in path.parts:
        pairs = [(k, "65536" if k == "c" else ("1" if k == "np" else v)) for k, v in pairs]
    if "MTP" in name:
        pairs.append(("spec-type", "draft-mtp"))
        pairs.append(("spec-draft-n-max", "3" if "Tiel" in name or "Flash" in name else "2"))
    # attach draft if obvious mtp file exists
    for mtp in aux["mtp"]:
        if "Flash-Next" in name and "Flash-Next" in mtp.name:
            pairs.append(("model-draft", container_path(mtp)))
            break
        if "Qwen3.8-27B" in name and "Qwen3.8-27B" in mtp.name:
            pairs.append(("model-draft", container_path(mtp)))
            break
    mm = find_mmproj(name, family_hints(name))
    if is_vl and mm:
        pairs.insert(1, ("mmproj", container_path(mm)))
    return pairs

def merge_preserve(old_pairs, new_pairs):
    if not old_pairs:
        return new_pairs
    old = dict(old_pairs)
    out = []
    seen = set()
    for k, v in new_pairs:
        if k in old and k in ("np", "c", "b", "ub", "ctk", "ctv", "spec-draft-n-max", "fit", "fa", "jinja", "ngl"):
            out.append((k, old[k]))
        else:
            out.append((k, v))
        seen.add(k)
    for k, v in old_pairs:
        if k not in seen and k not in ("load-on-startup",):
            # keep exotic keys
            if k not in ("model", "mmproj", "model-draft"):
                out.append((k, v))
    return out

# --- LAB (chat) ---
lab_path = root / "models-lab.ini"
lab_order, lab_sec, lab_header = parse_ini(lab_path)
lab_banner = [
    "; Lab router — AUTO-SYNCED by ./bench sync-models from ./models/",
    "; Missing GGUFs pruned; new chat weights added. Sticky INIs unchanged (except optional prune).",
    "; Edit values here; re-sync preserves np/c/ub/ctk when section still exists.",
]

existing_models = {}
for name, pairs in lab_sec.items():
    d = dict(pairs)
    if "model" in d:
        existing_models[d["model"]] = name

new_lab_order = []
new_lab = {}
added, kept, pruned = [], [], []

# Keep existing that still exist on disk
for name in lab_order:
    pairs = lab_sec[name]
    d = dict(pairs)
    mp = d.get("model", "")
    host = None
    if mp.startswith("/models/"):
        host = models_dir / mp[len("/models/"):]
    if host and host.is_file():
        # refresh path/mmproj defaults but preserve tunables
        stem = Path(mp).name.replace(".gguf", "")
        is_vl = name.endswith("-VL") or "mmproj" in d
        base = defaults_for(host, stem, is_vl=is_vl)
        new_lab[name] = merge_preserve(pairs, base)
        new_lab_order.append(name)
        kept.append(name)
    else:
        if prune:
            pruned.append(name)
        else:
            new_lab[name] = pairs
            new_lab_order.append(name)

# Add new primaries under chat/
for p in primaries:
    if "embeddings" in p.parts or "extractor" in p.parts:
        continue
    if "chat" not in p.parts:
        continue
    cp = container_path(p)
    stem = p.name.replace(".gguf", "")
    # multipart first shard → section without -00001-of-00004
    stem = re.sub(r"-00001-of-\d+$", "", stem, flags=re.I)
    if cp in existing_models or any(dict(new_lab.get(n, [])).get("model") == cp for n in new_lab_order):
        continue
    # skip if already have section with this stem
    if stem in new_lab:
        continue
    pairs = defaults_for(p, stem, is_vl=False)
    new_lab[stem] = pairs
    new_lab_order.append(stem)
    added.append(stem)
    # VL twin if mmproj available
    mm = find_mmproj(stem, family_hints(stem))
    if mm:
        vl_name = f"{stem}-VL"
        if vl_name not in new_lab:
            new_lab[vl_name] = defaults_for(p, stem, is_vl=True)
            new_lab_order.append(vl_name)
            added.append(vl_name)

write_ini(lab_path, lab_header, new_lab_order, new_lab, lab_banner)
print(f"  lab kept={len(kept)} added={len(added)} pruned={len(pruned)}")
for a in added:
    print(f"    + {a}")
for p in pruned:
    print(f"    - {p}")

# --- embeddings ---
emb_path = root / "models-embeddings.ini"
emb_order, emb_sec, emb_header = parse_ini(emb_path)
emb_banner = ["; Embeddings — AUTO-SYNCED by ./bench sync-models", ";"]
new_e_order, new_e = [], {}
for p in primaries:
    if "embeddings" not in p.parts:
        continue
    stem = p.name.replace(".gguf", "")
    old = emb_sec.get(stem, [])
    pairs = [
        ("model", container_path(p)),
        ("embeddings", "true"),
        ("ngl", "99"),
        ("c", "8192"),
        ("b", "512"),
    ]
    if stem == list(emb_sec.keys())[0] if emb_sec else False:
        pairs.append(("load-on-startup", "true"))
    # preserve load-on-startup if set
    if dict(old).get("load-on-startup"):
        pairs.append(("load-on-startup", dict(old)["load-on-startup"]))
    new_e[stem] = merge_preserve(old, pairs) if old else pairs
    new_e_order.append(stem)
# keep first as load-on-startup if none
if new_e_order and not any(dict(new_e[n]).get("load-on-startup") for n in new_e_order):
    pairs0 = list(new_e[new_e_order[0]])
    pairs0.append(("load-on-startup", "true"))
    new_e[new_e_order[0]] = pairs0
write_ini(emb_path, emb_header, new_e_order, new_e, emb_banner)

# --- extractor ---
ext_path = root / "models-extractor.ini"
ext_order, ext_sec, ext_header = parse_ini(ext_path)
ext_banner = [
    "; Schema / knowledge extractor — AUTO-SYNCED by ./bench sync-models",
    "; Section id kept stable when possible (agents-k1).",
]
new_x_order, new_x = [], {}
ext_files = [p for p in primaries if "extractor" in p.parts]
for p in ext_files:
    # prefer keeping agents-k1 name if single Agents-K1 file
    stem = p.name.replace(".gguf", "")
    name = "agents-k1" if "Agents-K1" in stem and "agents-k1" in (ext_sec or {"agents-k1": []}) else (
        "agents-k1" if "Agents-K1" in stem else stem
    )
    old = ext_sec.get(name) or ext_sec.get(stem) or []
    pairs = [
        ("model", container_path(p)),
        ("ngl", "99"),
        ("fa", "on"),
        ("jinja", "1"),
        ("ctk", "q8_0"),
        ("ctv", "q8_0"),
        ("np", "2"),
        ("c", "16384"),
        ("b", "64"),
        ("ub", "256"),
        ("load-on-startup", "true"),
    ]
    new_x[name] = merge_preserve(old, pairs) if old else pairs
    new_x_order.append(name)
write_ini(ext_path, ext_header, new_x_order, new_x, ext_banner)

# --- sticky prune only ---
def prune_sticky(path: Path, label: str):
    if not touch_sticky:
        print(f"sticky {path.name}: untouched (use --touch-sticky to prune missing)")
        return
    order, sec, header = parse_ini(path)
    new_o, new_s, removed = [], {}, []
    for name in order:
        d = dict(sec[name])
        mp = d.get("model", "")
        host = models_dir / mp[len("/models/"):] if mp.startswith("/models/") else None
        if host and host.is_file():
            new_s[name] = sec[name]
            new_o.append(name)
        else:
            removed.append(name)
    if dry:
        print(f"DRY sticky {path.name}: keep={len(new_o)} prune={removed}")
        return
    if not removed:
        print(f"sticky {path.name}: ok")
        return
    # rewrite preserving sticky style header
    banner = [
        f"; Sticky ({label}) — pruned missing GGUFs by ./bench sync-models --touch-sticky",
        ";",
    ]
    write_ini(path, header, new_o, new_s, banner)
    for r in removed:
        print(f"    sticky - {r}")

prune_sticky(root / "models.ini", "chat :11535")
prune_sticky(root / "models-coder.ini", "coder :11538")

print("done." + (" (dry-run)" if dry else ""))
print("Next: ./bench capacity sync --from coder,chat,lab")
PY
