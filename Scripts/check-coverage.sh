#!/usr/bin/env bash
#
# Scripts/check-coverage.sh — line-coverage gate for EngineCore and the rules targets (task 8.4).
#
#   R-QA-7.1  Line coverage SHALL be at least 90% for EngineCore and every rules target (tech.md
#             testing).
#
# Invoked by `make test` / `make test-long` right after `swift test --enable-code-coverage`. It merges the
# raw profiles that run wrote, asks llvm-cov for each scope's line coverage, prints a table, and exits
# non-zero when any scope is under the minimum, so a coverage regression fails the build.
#
# WHAT IS MEASURED. llvm-cov line coverage (executable lines run at least once / executable lines), over
# the UNION of every test bundle in the package. With SwiftPM's Swift Build backend each test target is
# its own .xctest bundle that statically links the library code it exercises; handing llvm-cov all of
# them merges their coverage, which matches what a single SwiftPM test bundle reports. A scope is a
# source directory, so test sources and other targets never count toward it.
#
# SCOPES. Each one is enforced on its own (edit COVERAGE_SCOPES below to add one):
#   EngineCore                     the engine target.
#   GamesRules (rules target)      the rules target as a whole: both games plus the catalog and setup
#                                  models it compiles, so no file in a rules target escapes the gate.
#   Klondike rules                 Klondike's sources inside GamesRules.
#   Crazy Eights rules (incl. AI)  Crazy Eights' sources inside GamesRules, INCLUDING the AI/ tiers. They
#                                  compile into the rules target, so R-QA-7.1 already covers them; keeping
#                                  them in the game's scope stops thin AI tests hiding behind the rules
#                                  tests (or the other way round).
# Both games share the single GamesRules target today. When a family gets its own rules target
# (design.md §11), add a line for it here.
#
# NO EXCLUSIONS. Every source file in a scope counts; nothing is filtered out to reach the number.
#
# The merged profile and an llvm-cov response file listing the test bundles stay in .build/coverage/ so
# uncovered lines can be inspected afterwards (a failing run prints the exact command).
#
# Needs: bash, plutil (ships with macOS), and llvm-cov + llvm-profdata (Xcode or the command line tools,
# found through xcrun). Run after `swift test --enable-code-coverage`.
#
# Exit status: 0 when every scope meets the minimum, 1 when any scope falls short, 2 on a usage or
# environment error (missing tool, no coverage data).

set -euo pipefail

# ---------------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------------

# Minimum line coverage per scope, in percent (R-QA-7.1). Override with --min or COVERAGE_MIN (the
# Makefile forwards its COVERAGE_MIN variable as --min).
min_coverage="${COVERAGE_MIN:-90}"

# Scopes as "label|source directory relative to the repo root".
COVERAGE_SCOPES=(
  "EngineCore|Packages/EngineCore/Sources/EngineCore"
  "GamesRules (rules target)|Packages/Games/Sources/GamesRules"
  "Klondike rules|Packages/Games/Sources/GamesRules/Klondike"
  "Crazy Eights rules (incl. AI)|Packages/Games/Sources/GamesRules/CrazyEights"
)

# Where the merged profile and the response file go (inside the git-ignored build directory).
output_dir=".build/coverage"

usage() {
  cat <<'EOF'
Usage: Scripts/check-coverage.sh [--min PERCENT] [--verbose]

Fail unless every coverage scope (EngineCore, GamesRules, Klondike, Crazy Eights) has at least
PERCENT line coverage. Run after `swift test --enable-code-coverage` (`make test` does both).
  --min P     Minimum line coverage per scope, 0-100 (default: $COVERAGE_MIN, else 90)
  --verbose   Print the per-file breakdown for every scope, not only for failing ones
EOF
}

verbose=0
while (($# > 0)); do
  case "$1" in
    --min)
      (($# >= 2)) || { echo "error: --min needs a value" >&2; exit 2; }
      min_coverage="$2"
      shift 2
      ;;
    --verbose)
      verbose=1
      shift
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

if [[ ! "$min_coverage" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || ! awk -v m="$min_coverage" 'BEGIN { exit !(m <= 100) }'; then
  echo "error: --min must be a percentage between 0 and 100 (got '$min_coverage')" >&2
  exit 2
fi

# Work from the repo root (this script lives in <root>/Scripts) so scope paths resolve.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------------------------------

# Resolve an LLVM tool from the active Xcode / command line tools toolchain, else from PATH.
find_llvm_tool() {
  local path=""
  if command -v xcrun >/dev/null 2>&1; then
    path="$(xcrun --find "$1" 2>/dev/null || true)"
  fi
  if [[ -z "$path" ]]; then
    path="$(command -v "$1" 2>/dev/null || true)"
  fi
  printf '%s' "$path"
}

LLVM_COV="$(find_llvm_tool llvm-cov)"
LLVM_PROFDATA="$(find_llvm_tool llvm-profdata)"
if [[ -z "$LLVM_COV" || -z "$LLVM_PROFDATA" ]]; then
  echo "error: llvm-cov and llvm-profdata are required for the coverage gate but were not found." >&2
  echo "       They ship with Xcode and the Swift command line tools: run 'xcode-select --install'" >&2
  echo "       (or 'make bootstrap'), or put a Swift toolchain's bin directory on PATH." >&2
  exit 2
fi
if ! command -v plutil >/dev/null 2>&1; then
  echo "error: plutil (part of macOS) is required to read llvm-cov's JSON summary but was not found." >&2
  exit 2
fi

# ---------------------------------------------------------------------------------------------------
# Coverage data: the raw profiles from the last `swift test --enable-code-coverage`, plus the test
# bundles whose coverage mappings tell llvm-cov which source lines are executable.
# ---------------------------------------------------------------------------------------------------

no_coverage_data() {
  echo "error: $1" >&2
  echo "       Run 'swift test --enable-code-coverage' first ('make test' runs it before this gate)." >&2
  exit 2
}

if ! bin_path="$(swift build --show-bin-path | tail -n 1)" || [[ -z "$bin_path" ]]; then
  echo "error: 'swift build --show-bin-path' failed; cannot locate the test bundles." >&2
  exit 2
fi
if ! codecov_json="$(swift test --show-codecov-path | tail -n 1)" || [[ -z "$codecov_json" ]]; then
  echo "error: 'swift test --show-codecov-path' failed; cannot locate the coverage profiles." >&2
  exit 2
fi
codecov_dir="$(dirname "$codecov_json")"

shopt -s nullglob
raw_profiles=("$codecov_dir"/*.profraw)
bundles=("$bin_path"/*.xctest)
shopt -u nullglob

((${#raw_profiles[@]} > 0)) || no_coverage_data "no raw coverage profiles in $codecov_dir."

# llvm-cov takes the first binary positionally and every other one through -object.
object_args=()
bundle_count=0
for bundle in ${bundles[@]+"${bundles[@]}"}; do
  name="$(basename "$bundle" .xctest)"
  if [[ -f "$bundle" ]]; then
    binary="$bundle"  # Linux layout: the .xctest is the executable itself
  elif [[ -f "$bundle/Contents/MacOS/$name" ]]; then
    binary="$bundle/Contents/MacOS/$name"  # macOS bundle layout
  else
    continue
  fi
  if ((bundle_count == 0)); then
    object_args=("$binary")
  else
    object_args+=(-object "$binary")
  fi
  bundle_count=$((bundle_count + 1))
done
((bundle_count > 0)) || no_coverage_data "no test bundles found in $bin_path."

mkdir -p "$output_dir"
profile="$output_dir/parlor.profdata"
"$LLVM_PROFDATA" merge -sparse -o "$profile" "${raw_profiles[@]}"

# Response file so `llvm-cov show ... @<file>` can reuse the bundle list. One quoted argument per line,
# with backslashes and double quotes escaped (llvm's GNU-style response-file syntax).
response_file="$output_dir/test-bundles.rsp"
for arg in "${object_args[@]}"; do
  printf '"%s"\n' "$(printf '%s' "$arg" | sed -e 's/[\\"]/\\&/g')"
done >"$response_file"

# ---------------------------------------------------------------------------------------------------
# Gate
# ---------------------------------------------------------------------------------------------------

# Print "<executable lines> <covered lines>" for the sources under directory $1; non-zero on failure.
scope_line_totals() {
  local json count covered
  json="$("$LLVM_COV" export -summary-only -instr-profile "$profile" "${object_args[@]}" "$1")" \
    || return 1
  count="$(printf '%s' "$json" | plutil -extract data.0.totals.lines.count raw -o - -)" || return 1
  covered="$(printf '%s' "$json" | plutil -extract data.0.totals.lines.covered raw -o - -)" || return 1
  printf '%s %s\n' "$count" "$covered"
}

# Per-file line coverage for the sources under directory $1, indented under the table. Display only,
# so a reporting hiccup never masks the gate's verdict.
print_file_breakdown() {
  "$LLVM_COV" report -instr-profile "$profile" "${object_args[@]}" \
    -show-region-summary=false -show-branch-summary=false -show-instantiation-summary=false "$1" \
    | sed 's/^/      /' || echo "      (per-file breakdown unavailable)"
}

echo "==> Line coverage gate (R-QA-7.1): each scope needs >= ${min_coverage}% of executable lines"
printf '  %d raw profile(s) from %s; %d test bundle(s) from %s\n' \
  "${#raw_profiles[@]}" "$codecov_dir" "$bundle_count" "$bin_path"
printf '  %-30s %8s %8s %9s  %s\n' "Scope" "Lines" "Covered" "Coverage" "Result"

failures=0
failed_dirs=()
for entry in "${COVERAGE_SCOPES[@]}"; do
  label="${entry%%|*}"
  dir="${entry#*|}"
  if [[ ! -d "$dir" ]]; then
    echo "error: coverage scope '$label' points at '$dir', which does not exist; update COVERAGE_SCOPES." >&2
    exit 2
  fi
  if ! totals="$(scope_line_totals "$dir")"; then
    no_coverage_data "llvm-cov could not report on '$label' ($dir); were the test bundles rebuilt without coverage?"
  fi
  read -r count covered <<<"$totals"
  if [[ ! "$count" =~ ^[0-9]+$ || ! "$covered" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
    no_coverage_data "llvm-cov reported no executable lines for '$label' ($dir)."
  fi
  percent="$(awk -v c="$covered" -v n="$count" 'BEGIN { printf "%.2f%%", 100 * c / n }')"
  if awk -v c="$covered" -v n="$count" -v m="$min_coverage" 'BEGIN { exit !(100 * c >= m * n) }'; then
    result="[ok]"
  else
    result="[FAIL] below ${min_coverage}%"
    failures=$((failures + 1))
    failed_dirs+=("$dir")
  fi
  printf '  %-30s %8s %8s %9s  %s\n' "$label" "$count" "$covered" "$percent" "$result"
  if ((verbose)); then
    print_file_breakdown "$dir"
  fi
done

echo
if ((failures > 0)); then
  if ((!verbose)); then
    for dir in "${failed_dirs[@]}"; do
      echo "  Per-file line coverage under $dir:"
      print_file_breakdown "$dir"
    done
  fi
  echo "  Uncovered lines for one file (run from the repo root):"
  echo "    xcrun llvm-cov show -instr-profile $profile @$response_file -show-line-counts <source file>"
  echo
  printf 'coverage: FAILED, %d of %d scope(s) below %s%% line coverage (R-QA-7.1).\n' \
    "$failures" "${#COVERAGE_SCOPES[@]}" "$min_coverage"
  echo "          Cover the missing behavior with tests; do not lower the minimum or exclude files."
  exit 1
fi
printf 'coverage: OK, all %d scopes at or above %s%% line coverage (R-QA-7.1).\n' \
  "${#COVERAGE_SCOPES[@]}" "$min_coverage"
exit 0
