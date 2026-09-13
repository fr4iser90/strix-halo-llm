#!/usr/bin/env bash
# Minimal INI section patch (no lab_server dependency).
set -euo pipefail

patch_ini_section() {
  local ini="$1" section="$2" key="$3" val="$4"
  [[ -f "$ini" ]] || { printf '[bench capacity] missing ini: %s\n' "$ini" >&2; return 1; }
  bench_python - "$ini" "$section" "$key" "$val" <<'PY'
import sys
ini, section, key, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(ini, encoding="utf-8").read().splitlines(keepends=True)
out = []
in_section = False
replaced = False
section_found = False
i = 0
while i < len(lines):
    raw = lines[i]
    line = raw.strip()
    if line.startswith("[") and line.endswith("]"):
        if in_section and not replaced:
            out.append(f"{key} = {val}\n")
            replaced = True
        cur = line[1:-1].strip()
        in_section = cur == section
        if in_section:
            section_found = True
        out.append(raw)
        i += 1
        continue
    if in_section and "=" in line and not line.startswith(";"):
        k, _, _ = line.partition("=")
        if k.strip() == key:
            out.append(f"{key} = {val}\n")
            replaced = True
            i += 1
            continue
    out.append(raw)
    i += 1
if in_section and not replaced:
    out.append(f"{key} = {val}\n")
    replaced = True
if not section_found:
    raise SystemExit(f"section [{section}] not found in {ini}")
open(ini, "w", encoding="utf-8").writelines(out)
PY
  if [[ "${CAPACITY_PATCH_VERBOSE:-0}" == "1" ]]; then
    log "patched $(basename "$ini") [${section}] ${key}=${val}"
  fi
}

get_ini_section_key() {
  local ini="$1" section="$2" key="$3"
  [[ -f "$ini" ]] || return 0
  bench_python - "$ini" "$section" "$key" <<'PY'
import sys
ini, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
cur = None
with open(ini, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1].strip()
            continue
        if cur != section or "=" not in line or line.startswith(";"):
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            print(v.strip())
            raise SystemExit(0)
print("")
PY
}
