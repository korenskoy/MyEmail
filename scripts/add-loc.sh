#!/usr/bin/env bash
# Add or update a localization entry in MyEmail/Resources/Localizable.xcstrings.
#
# Usage:
#   scripts/add-loc.sh "Key text" "English value" "Русский перевод"
#   scripts/add-loc.sh "Key text" "Русский перевод"           # key is used as EN
#   scripts/add-loc.sh -f entries.tsv                          # batch: key<TAB>en<TAB>ru per line
#
# Rules (per CLAUDE.md):
#   - sourceLanguage is "en"; if EN equals the key, no explicit "en" unit is written.
#   - RU is always written with state "translated".
#   - Existing entries are updated, not duplicated.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
XCSTRINGS="$REPO_ROOT/MyEmail/Resources/Localizable.xcstrings"

if [[ ! -f "$XCSTRINGS" ]]; then
  echo "error: $XCSTRINGS not found" >&2
  exit 1
fi

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

if [[ $# -eq 0 ]]; then usage; fi

BATCH_FILE=""
ENTRIES=()  # each item: "KEY\tEN\tRU"

if [[ "${1:-}" == "-f" ]]; then
  BATCH_FILE="${2:-}"
  [[ -f "$BATCH_FILE" ]] || { echo "error: batch file not found: $BATCH_FILE" >&2; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    ENTRIES+=("$line")
  done < "$BATCH_FILE"
elif [[ $# -eq 2 ]]; then
  ENTRIES+=("$1"$'\t'"$1"$'\t'"$2")
elif [[ $# -eq 3 ]]; then
  ENTRIES+=("$1"$'\t'"$2"$'\t'"$3")
else
  usage
fi

python3 - "$XCSTRINGS" <<'PY' "${ENTRIES[@]}"
import json, sys, os

path = sys.argv[1]
raw_entries = sys.argv[2:]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

data.setdefault("sourceLanguage", "en")
strings = data.setdefault("strings", {})

added, updated = 0, 0
for raw in raw_entries:
    parts = raw.split("\t")
    if len(parts) != 3:
        print(f"skip (bad line): {raw!r}", file=sys.stderr)
        continue
    key, en, ru = parts
    if not key:
        print("skip: empty key", file=sys.stderr)
        continue

    entry = strings.get(key)
    is_new = entry is None
    if is_new:
        entry = {}
    locs = entry.setdefault("localizations", {})

    # Only store explicit "en" unit if it differs from the key.
    if en and en != key:
        locs["en"] = {"stringUnit": {"state": "translated", "value": en}}
    else:
        locs.pop("en", None)

    if ru:
        locs["ru"] = {"stringUnit": {"state": "translated", "value": ru}}

    if not locs:
        entry.pop("localizations", None)

    strings[key] = entry
    if is_new:
        added += 1
    else:
        updated += 1

# Stable sorted keys, same style Xcode emits (2-space indent, sorted).
data["strings"] = dict(sorted(strings.items(), key=lambda kv: kv[0]))

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=False)
    f.write("\n")
os.replace(tmp, path)

print(f"ok: +{added} added, ~{updated} updated -> {path}")
PY
