#!/usr/bin/env bash
# Generate a deterministic newline-delimited seed pool for parlor-sim (R-QA-2.1, R-QA-2.2).
#
# The simulation PRNG expands each hand seed before shuffling. A sequential, recorded pool is therefore
# sufficient for reproducible volume sampling and makes a failed seed easy to report and rerun.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/generate-seed-pool.sh --count N --output PATH [--base N]

Generate N deterministic UInt64-compatible decimal seeds, starting at N's base value.
  --count N    Number of seeds to write (required; positive integer)
  --output P   Output file path (required; replaced atomically)
  --base N     First seed (default: 20240601)
EOF
}

count=""
base="20240601"
output=""

while (($# > 0)); do
  case "$1" in
    --count)
      (($# >= 2)) || { echo "error: --count needs a value" >&2; exit 2; }
      count="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || { echo "error: --output needs a value" >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    --base)
      (($# >= 2)) || { echo "error: --base needs a value" >&2; exit 2; }
      base="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --count must be a positive integer" >&2
  exit 2
fi
if [[ ! "$base" =~ ^[0-9]+$ ]]; then
  echo "error: --base must be an unsigned decimal integer" >&2
  exit 2
fi
if [[ -z "$output" ]]; then
  echo "error: --output is required" >&2
  exit 2
fi

# Keep shell arithmetic in the signed range on macOS while still leaving ample UInt64 seed space.
if ((base > 9000000000000000000)); then
  echo "error: --base is too large for portable shell arithmetic" >&2
  exit 2
fi
if ((count > 9000000000000000000)); then
  echo "error: --count is too large for portable shell arithmetic" >&2
  exit 2
fi
if ((count - 1 > 9000000000000000000 - base)); then
  echo "error: --base plus --count exceeds the portable seed range" >&2
  exit 2
fi

parent="$(dirname "$output")"
mkdir -p "$parent"
temporary="$(mktemp "$output.tmp.XXXXXX")"
cleanup() { rm -f "$temporary"; }
trap cleanup EXIT

for ((offset = 0; offset < count; offset += 1)); do
  printf '%d\n' "$((base + offset))"
done > "$temporary"
mv -f "$temporary" "$output"
trap - EXIT

printf 'generated %s seeds in %s (base %s)\n' "$count" "$output" "$base"
