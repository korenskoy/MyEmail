#!/usr/bin/env bash
# Remove localization entries from MyEmail/Resources/Localizable.xcstrings.
#
# Usage:
#   scripts/remove-loc.sh "Key text" ["Another key" ...]
#   scripts/remove-loc.sh -f keys.txt                     # batch: one key per line
#   scripts/remove-loc.sh --dry-run "Key text"            # show what would be removed
#
# Rules (per CLAUDE.md):
#   - Only manipulates Localizable.xcstrings; does not touch source code references.
#   - Missing keys are reported but do not fail the run.
#   - Preserves Xcode's on-disk style (2-space indent, sorted keys).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
XCSTRINGS="$REPO_ROOT/MyEmail/Resources/Localizable.xcstrings"

if [[ ! -f "$XCSTRINGS" ]]; then
  echo "error: $XCSTRINGS not found" >&2
  exit 1
fi

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

if [[ $# -eq 0 ]]; then usage; fi

DRY_RUN=0
KEYS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -f)
      BATCH_FILE="${2:-}"
      [[ -f "$BATCH_FILE" ]] || { echo "error: batch file not found: $BATCH_FILE" >&2; exit 1; }
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        KEYS+=("$line")
      done < "$BATCH_FILE"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do KEYS+=("$1"); shift; done
      ;;
    *)
      KEYS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#KEYS[@]} -eq 0 ]]; then
  echo "error: no keys provided" >&2
  exit 1
fi

DRY_RUN="$DRY_RUN" python3 - "$XCSTRINGS" <<'PY' "${KEYS[@]}"
import json, os, sys

path = sys.argv[1]
keys = sys.argv[2:]
dry = os.environ.get("DRY_RUN") == "1"

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

strings = data.get("strings", {})

removed, missing = [], []
for key in keys:
    if key in strings:
        removed.append(key)
        if not dry:
            del strings[key]
    else:
        missing.append(key)

if dry:
    for k in removed:
        print(f"would remove: {k!r}")
    for k in missing:
        print(f"not found:    {k!r}", file=sys.stderr)
    print(f"dry-run: {len(removed)} would be removed, {len(missing)} missing")
    sys.exit(0)

data["strings"] = dict(sorted(strings.items(), key=lambda kv: kv[0]))

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=False)
    f.write("\n")
os.replace(tmp, path)

for k in missing:
    print(f"not found: {k!r}", file=sys.stderr)
print(f"ok: -{len(removed)} removed ({len(missing)} missing) -> {path}")
PY
