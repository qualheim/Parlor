#!/usr/bin/env bash
#
# Scripts/lint.sh — architecture, privacy, and entitlement lint for Parlor (task 1.4).
#
# Invoked by `make lint` after the swift-format check. Enforces the rules that a formatter cannot:
#
#   R-BUILD-4.2  Forbidden imports / APIs anywhere in Swift sources
#                (URLSession, Network, WebKit, CFNetwork, MultipeerConnectivity, GameKit, CloudKit,
#                 and analytics/crash-reporting SDKs). Parlor is fully offline (tech.md).
#   R-BUILD-4.3  UI-framework imports (SwiftUI, AppKit, SpriteKit, Combine, UIKit, …) inside the pure
#                layer (EngineCore, AIKit, GamesRules) — these stay stdlib + Foundation only so they
#                remain Linux-portable for a future server (tech.md rule 1).
#   R-BUILD-4.1  Dependency-direction violations: a package importing an internal Parlor module that is
#                not in its allowed set (structure.md / design.md §1).
#   R-BUILD-4.4  Unexpected entitlements in App/Parlor.entitlements (only com.apple.security.app-sandbox
#                is allowed) — implements R-BUILD-3.4.
#
# No dependencies beyond what macOS ships: bash, grep, sed, plutil. POSIX-friendly; runs headless.
#
# Exit status: 0 when clean, 1 when any rule is violated (fails `make lint`).

set -u

# ---------------------------------------------------------------------------------------------------
# Locate the repo root (this script lives in <root>/Scripts) and move there so paths are stable.
# ---------------------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || { echo "lint: cannot cd to repo root '$ROOT'"; exit 1; }

FAILURES=0
CHECKS_RUN=0

note()  { printf '  %s\n' "$*"; }
fail()  { printf '  [FAIL] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
okay()  { printf '  [ok] %s\n' "$*"; }

# ---------------------------------------------------------------------------------------------------
# Source enumeration.
#
# All Swift sources under App/ and Packages/ (build products under .build are never scanned).
# ---------------------------------------------------------------------------------------------------
swift_sources() {
  find App Packages -type f -name '*.swift' 2>/dev/null | LC_ALL=C sort
}

# Emit "path:lineno:code" for every source line with // line-comments and /* */ block-comments removed
# and string literals blanked, so matches below reflect real code, not documentation or prose. The
# many explanatory comments in this repo mention forbidden frameworks by name; stripping comments keeps
# those from tripping the checks while still catching genuine code usage.
#
# The awk program:
#   - tracks block-comment state across lines (in_block),
#   - removes /* ... */ regions (single- and multi-line),
#   - truncates at the first // outside a string,
#   - blanks the contents of "..." string literals,
#   - prints FILENAME:FNR:<sanitized code> for non-empty remaining code.
strip_comments() {
  # $1 = file
  awk '
    BEGIN { in_block = 0 }
    {
      line = $0
      out = ""
      i = 1
      n = length(line)
      in_string = 0
      while (i <= n) {
        c = substr(line, i, 1)
        two = substr(line, i, 2)
        if (in_block) {
          if (two == "*/") { in_block = 0; i += 2; continue }
          i += 1; continue
        }
        if (in_string) {
          if (c == "\\") { out = out " "; i += 2; continue }   # skip escaped char
          if (c == "\"") { in_string = 0; out = out " "; i += 1; continue }
          out = out " "; i += 1; continue                       # blank string contents
        }
        if (two == "/*") { in_block = 1; i += 2; continue }
        if (two == "//") { break }                              # rest of line is a comment
        if (c == "\"") { in_string = 1; out = out " "; i += 1; continue }
        out = out c; i += 1
      }
      # Trim trailing whitespace; print only if code remains.
      gsub(/[ \t]+$/, "", out)
      if (out !~ /^[ \t]*$/) {
        printf "%s:%d:%s\n", FILENAME, FNR, out
      }
    }
  ' "$1"
}

# Return the sanitized (comment-free) code for every Swift source, as path:lineno:code lines.
sanitized_all() {
  local f
  swift_sources | while IFS= read -r f; do
    strip_comments "$f"
  done
}

# ---------------------------------------------------------------------------------------------------
# Check 1 — Forbidden imports / APIs anywhere (R-BUILD-4.2).
# ---------------------------------------------------------------------------------------------------
# Forbidden *module* imports: any `import Network`, `import WebKit`, etc.
FORBIDDEN_IMPORT_MODULES="Network WebKit CFNetwork MultipeerConnectivity GameKit CloudKit"

# Forbidden *symbols/APIs* that may appear without an import (e.g. URLSession via Foundation), and
# analytics / crash-reporting SDK module names. Matched as whole words against sanitized code.
FORBIDDEN_API_SYMBOLS="URLSession URLSessionConfiguration URLSessionTask URLSessionDataTask URLSessionDownloadTask URLSessionWebSocketTask URLConnection NSURLConnection NSURLSession CFNetwork"

# Analytics / crash-reporting SDKs (module names). Any import of these fails the offline posture.
FORBIDDEN_ANALYTICS_MODULES="Firebase FirebaseAnalytics FirebaseCrashlytics Crashlytics Fabric Sentry SentrySwift Bugsnag Amplitude Mixpanel Segment Analytics AppCenter AppCenterAnalytics AppCenterCrashes Datadog DatadogCore Instabug Countly Flurry GoogleAnalytics Adjust Branch Kochava Heap Smartlook"

check_forbidden() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "==> [1/4] Forbidden imports / APIs (R-BUILD-4.2)"
  local sanitized hits found=0 m
  sanitized="$(sanitized_all)"

  # Forbidden module imports (networking / OS UI-adjacent frameworks).
  for m in $FORBIDDEN_IMPORT_MODULES $FORBIDDEN_ANALYTICS_MODULES; do
    hits="$(printf '%s\n' "$sanitized" | grep -nE "^[^:]+:[0-9]+:[[:space:]]*(@[A-Za-z]+[[:space:]]+)?import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|enum[[:space:]]+|func[[:space:]]+|var[[:space:]]+|let[[:space:]]+|typealias[[:space:]]+|protocol[[:space:]]+)?${m}([[:space:]]|\.|$)" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      found=1
      while IFS= read -r line; do
        [ -n "$line" ] && fail "forbidden import of '$m' → ${line#*:}  (${line%%:*})"
      done <<EOF
$hits
EOF
    fi
  done

  # Forbidden API symbols (may be reachable without an explicit import).
  for m in $FORBIDDEN_API_SYMBOLS; do
    hits="$(printf '%s\n' "$sanitized" | grep -nE "(^|[^A-Za-z0-9_.])${m}([^A-Za-z0-9_]|$)" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      found=1
      while IFS= read -r line; do
        [ -n "$line" ] && fail "forbidden API '$m' → ${line#*:}  (${line%%:*})"
      done <<EOF
$hits
EOF
    fi
  done

  [ "$found" -eq 0 ] && okay "no forbidden imports or APIs"
}

# ---------------------------------------------------------------------------------------------------
# Check 2 — UI-framework imports inside the pure layer (R-BUILD-4.3).
# ---------------------------------------------------------------------------------------------------
# Pure-layer source roots: EngineCore, AIKit, and the rules target GamesRules. These must import only
# the Swift standard library + Foundation (tech.md rule 1; design.md §1).
PURE_LAYER_DIRS="Packages/EngineCore/Sources Packages/AIKit/Sources Packages/Games/Sources/GamesRules"

# Apple-only UI / reactive frameworks disallowed in the pure layer.
UI_FRAMEWORKS="SwiftUI AppKit UIKit SpriteKit SceneKit Combine CoreGraphics CoreAnimation QuartzCore Metal MetalKit CoreImage ImageIO Charts Cocoa Carbon WatchKit"

check_ui_in_pure() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "==> [2/4] UI-framework imports in pure layer (R-BUILD-4.3)"
  local found=0 dir f sanitized hits m
  for dir in $PURE_LAYER_DIRS; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sanitized="$(strip_comments "$f")"
      for m in $UI_FRAMEWORKS; do
        hits="$(printf '%s\n' "$sanitized" | grep -nE "^[^:]+:[0-9]+:[[:space:]]*(@[A-Za-z]+[[:space:]]+)?import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|enum[[:space:]]+|func[[:space:]]+|var[[:space:]]+|let[[:space:]]+|typealias[[:space:]]+|protocol[[:space:]]+)?${m}([[:space:]]|\.|$)" 2>/dev/null || true)"
        if [ -n "$hits" ]; then
          found=1
          while IFS= read -r line; do
            [ -n "$line" ] && fail "UI framework '$m' imported in pure layer → ${line#*:}  (${line%%:*})"
          done <<EOF
$hits
EOF
        fi
      done
    done <<EOF
$(find "$dir" -type f -name '*.swift' 2>/dev/null | LC_ALL=C sort)
EOF
  done
  [ "$found" -eq 0 ] && okay "pure layer imports only stdlib + Foundation"
}

# ---------------------------------------------------------------------------------------------------
# Check 3 — Dependency direction (R-BUILD-4.1).
# ---------------------------------------------------------------------------------------------------
# The set of internal Parlor modules. Any import of one of these from a target not allowed to depend on
# it is a violation. Allowed sets mirror structure.md / design.md §1:
#
#   EngineCore     -> (nothing internal)
#   DesignSystem   -> (nothing internal)
#   AIKit          -> EngineCore
#   GamesRules     -> AIKit, EngineCore
#   Persistence    -> EngineCore
#   TableKit       -> DesignSystem, EngineCore
#   GamesUI        -> GamesRules, TableKit
#   SimulationCLI  -> GamesRules, AIKit, EngineCore
#
# A module may always "import" itself (it can't, but self-name is filtered out harmlessly).
INTERNAL_MODULES="EngineCore AIKit GamesRules GamesUI TableKit DesignSystem Persistence SimulationCLI"

# Source root for each target.
target_dir() {
  case "$1" in
    EngineCore)    echo "Packages/EngineCore/Sources/EngineCore" ;;
    AIKit)         echo "Packages/AIKit/Sources/AIKit" ;;
    GamesRules)    echo "Packages/Games/Sources/GamesRules" ;;
    GamesUI)       echo "Packages/Games/Sources/GamesUI" ;;
    TableKit)      echo "Packages/TableKit/Sources/TableKit" ;;
    DesignSystem)  echo "Packages/DesignSystem/Sources/DesignSystem" ;;
    Persistence)   echo "Packages/Persistence/Sources/Persistence" ;;
    SimulationCLI) echo "Packages/SimulationCLI/Sources/SimulationCLI" ;;
    *)             echo "" ;;
  esac
}

# Allowed internal imports for each target (space-separated).
allowed_deps() {
  case "$1" in
    EngineCore)    echo "" ;;
    DesignSystem)  echo "" ;;
    AIKit)         echo "EngineCore" ;;
    GamesRules)    echo "AIKit EngineCore" ;;
    Persistence)   echo "EngineCore" ;;
    TableKit)      echo "DesignSystem EngineCore" ;;
    GamesUI)       echo "GamesRules TableKit" ;;
    SimulationCLI) echo "GamesRules AIKit EngineCore" ;;
    *)             echo "" ;;
  esac
}

check_dependency_direction() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "==> [3/4] Dependency direction (R-BUILD-4.1)"
  local found=0 target dir allowed f sanitized hits mod is_allowed a
  for target in $INTERNAL_MODULES; do
    dir="$(target_dir "$target")"
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    allowed="$(allowed_deps "$target")"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sanitized="$(strip_comments "$f")"
      # Find every internal module imported by this file.
      for mod in $INTERNAL_MODULES; do
        [ "$mod" = "$target" ] && continue
        hits="$(printf '%s\n' "$sanitized" | grep -nE "^[^:]+:[0-9]+:[[:space:]]*(@[A-Za-z]+[[:space:]]+)?import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|enum[[:space:]]+|func[[:space:]]+|var[[:space:]]+|let[[:space:]]+|typealias[[:space:]]+|protocol[[:space:]]+)?${mod}([[:space:]]|\.|$)" 2>/dev/null || true)"
        [ -n "$hits" ] || continue
        # Is `mod` in the allowed set for `target`?
        is_allowed=0
        for a in $allowed; do
          [ "$a" = "$mod" ] && is_allowed=1 && break
        done
        if [ "$is_allowed" -eq 0 ]; then
          found=1
          while IFS= read -r line; do
            [ -n "$line" ] && fail "$target imports '$mod' outside allowed direction (allowed: ${allowed:-none}) → ${line%%:*}"
          done <<EOF
$hits
EOF
        fi
      done
    done <<EOF
$(find "$dir" -type f -name '*.swift' 2>/dev/null | LC_ALL=C sort)
EOF
  done
  [ "$found" -eq 0 ] && okay "all internal imports respect the allowed direction"
}

# ---------------------------------------------------------------------------------------------------
# Check 4 — Unexpected entitlements (R-BUILD-4.4 / R-BUILD-3.4).
# ---------------------------------------------------------------------------------------------------
# Only com.apple.security.app-sandbox is expected. Any other entitlement key fails the check. Network
# entitlements (client/server) are specifically forbidden (R-BUILD-3.2). Parsed with plutil.
ENTITLEMENTS_FILE="App/Parlor.entitlements"
EXPECTED_ENTITLEMENTS="com.apple.security.app-sandbox"

check_entitlements() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "==> [4/4] Entitlements (R-BUILD-4.4 / R-BUILD-3.4)"
  if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    fail "entitlements file '$ENTITLEMENTS_FILE' not found"
    return
  fi
  # Validate the plist parses at all.
  if ! plutil -lint "$ENTITLEMENTS_FILE" >/dev/null 2>&1; then
    fail "entitlements file '$ENTITLEMENTS_FILE' is not a valid property list"
    return
  fi
  # Extract the top-level keys as JSON, then read the key names with plutil expressions.
  # `plutil -convert json -o - -` gives us a single JSON object; we pull keys without needing jq by
  # asking plutil for the raw keys via a small conversion + grep on the pretty JSON.
  local json keys key found=0 expected is_expected
  json="$(plutil -convert json -o - "$ENTITLEMENTS_FILE" 2>/dev/null)"
  if [ -z "$json" ]; then
    fail "could not read entitlements from '$ENTITLEMENTS_FILE'"
    return
  fi
  # Top-level keys look like  "com.apple.security.app-sandbox":  in the JSON. Extract them.
  keys="$(printf '%s\n' "$json" \
    | grep -oE '"[^"]+"[[:space:]]*:' \
    | sed -E 's/^"([^"]+)"[[:space:]]*:$/\1/' \
    | LC_ALL=C sort -u)"

  if [ -z "$keys" ]; then
    okay "no entitlement keys declared"
    return
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    is_expected=0
    for expected in $EXPECTED_ENTITLEMENTS; do
      [ "$key" = "$expected" ] && is_expected=1 && break
    done
    if [ "$is_expected" -eq 0 ]; then
      found=1
      fail "unexpected entitlement '$key' (expected only: $EXPECTED_ENTITLEMENTS)"
    fi
  done <<EOF
$keys
EOF
  [ "$found" -eq 0 ] && okay "entitlements limited to the expected set ($EXPECTED_ENTITLEMENTS)"
}

# ---------------------------------------------------------------------------------------------------
# Run all checks.
# ---------------------------------------------------------------------------------------------------
echo "==> Architecture / privacy / entitlement lint (Scripts/lint.sh)"
check_forbidden
check_ui_in_pure
check_dependency_direction
check_entitlements

echo
if [ "$FAILURES" -gt 0 ]; then
  printf 'lint: FAILED — %d violation(s) across %d checks.\n' "$FAILURES" "$CHECKS_RUN"
  exit 1
fi
printf 'lint: OK — all %d architecture/privacy/entitlement checks passed.\n' "$CHECKS_RUN"
exit 0
