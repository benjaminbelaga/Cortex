#!/bin/bash
# gate-xcode27.sh — canonical local build+test gate for Cortex/Cortex on Xcode 27.
#
# WHY THIS EXISTS (2026-09-20)
#   The Xcode-27 toolchain adaptations lived only in the message of gate commit
#   6675df2, so every session had to rediscover them — and when they didn't:
#     1. dependency projects generate with deployment targets below Xcode 27's
#        supported floor (12.0) → build errors on 10.13/10.15/12.0;
#     2. Xcode 27's explicit-modules resolution fails on the Tuist-generated
#        SwiftTerm/_SubprocessCShims graph ("Unable to resolve module dependency")
#        → SWIFT_ENABLE_EXPLICIT_MODULES=NO;
#     3. `tuist generate` re-introduces both on every run, so the patch below
#        runs after generate, right before xcodebuild.
#   Commit f069dc5 (D2) shipped source files that never compiled because this
#   recipe was skipped and CI is neutralised to workflow_dispatch (cost
#   decision 2026-08-22) — no other gate existed. This script IS the gate.
#
# Usage:
#   scripts/gate-xcode27.sh                 # full test suite (canonical gate)
#   scripts/gate-xcode27.sh --build         # build only (Debug)
#   scripts/gate-xcode27.sh --release       # build only (Release)
#   scripts/gate-xcode27.sh -only-testing:DomainTests/RouterAttentionTests
#                                           # extra args are forwarded to xcodebuild
# Env:
#   CLAUDEBAR_DD   override DerivedData path (optional)
#
# FILTER NAMES FOR SWIFT TESTING SUITES (2026-10-03)
#   The Cortex tests are Swift Testing suites, and xcodebuild's -only-testing
#   filter matches the test declaration's TYPE NAME — NOT the @Suite("…") display
#   string. A file that reads:
#       @Suite("RouterAttention") struct RouterAttentionTests { … }
#   is selected by  -only-testing:DomainTests/RouterAttentionTests  and NOT by the
#   display string "RouterAttention". Same for
#       @Suite("LLMRouterAttentionClient / LLMRouterMissionInspector")
#       struct LLMRouterAttentionClientTests
#   →  -only-testing:InfrastructureTests/LLMRouterAttentionClientTests.
#
#   Observed counter-example (2026-10-03, this checkout):
#       scripts/gate-xcode27.sh \
#         -only-testing:DomainTests/RouterAttention \
#         -only-testing:InfrastructureTests/LLMRouterAttentionClient
#   printed "** TEST SUCCEEDED **" and "GATE PASSED" while having executed ZERO
#   tests: a filter that matches nothing makes xcodebuild succeed with an empty
#   run. A targeted verification that verifies nothing must not go green, so a
#   run whose forwarded args contain -only-testing:/-skip-testing: is now treated
#   as "targeted": gate-xcode27.sh tees its output to
#   .build/gate-xcode27-test.log and, before printing GATE PASSED, requires
#   evidence that at least one test actually executed — a Swift Testing
#   "Test run with N tests" summary or an XCTest "Executed N tests" line with
#   N > 0. If neither is found the run fails (exit 1) with an actionable message.
#   Full (non-targeted) runs are unchanged.
set -eo pipefail
cd "$(dirname "$0")/.."

# One gate per checkout at a time (2026-09-25): parallel sessions shared this
# checkout — two `tuist install/generate` half-fetched Tuist/.build/checkouts and
# two xcodebuilds locked DerivedData's build.db (exit 65). Wait, never fail:
# mkdir is atomic; a lock whose holder pid is gone is reclaimed.
GATE_LOCK="$PWD/.build/gate-xcode27.lock"
GATE_LOCK_WAIT_S="${GATE_LOCK_WAIT_S:-3600}"
mkdir -p "$PWD/.build"
waited=0
until mkdir "$GATE_LOCK" 2>/dev/null; do
  holder="$(cat "$GATE_LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    echo "== gate lock: holder pid $holder is gone, reclaiming"
    rm -f "$GATE_LOCK/pid"; rmdir "$GATE_LOCK" 2>/dev/null || true
    continue
  fi
  if [ $((waited % 60)) -eq 0 ]; then echo "== gate lock held by pid ${holder:-?} — waiting (${waited}s)"; fi
  if [ "$waited" -ge "$GATE_LOCK_WAIT_S" ]; then echo "== gate lock: gave up after ${waited}s" >&2; exit 75; fi
  sleep 5; waited=$((waited + 5))
done
echo $$ > "$GATE_LOCK/pid"
trap 'rm -f "$GATE_LOCK/pid"; rmdir "$GATE_LOCK" 2>/dev/null || true' EXIT

MODE=test
CONFIG_ARGS=()
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --build)   MODE=build; CONFIG_ARGS=(-configuration Debug);   shift ;;
    --release) MODE=build; CONFIG_ARGS=(-configuration Release); shift ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

PROVENANCE_ARGS=(
  "CORTEX_GIT_SHA=$(git rev-parse HEAD)"
  "CORTEX_BUILD_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
)
if [ -z "$(git status --porcelain)" ]; then
  PROVENANCE_ARGS+=("CORTEX_GIT_DIRTY=false")
else
  PROVENANCE_ARGS+=("CORTEX_GIT_DIRTY=true")
fi

DD_ARGS=()
if [ -n "${CLAUDEBAR_DD:-}" ]; then DD_ARGS=(-derivedDataPath "$CLAUDEBAR_DD"); fi
# Checkout-private Clang module cache: the global DerivedData/ModuleCache.noindex
# is shared by every project and session, and keeps .pcm files built from an
# older checkout path ("module 'AwsCPlatformConfig' is defined in both …").
DD_ARGS+=("MODULE_CACHE_DIR=$PWD/.build/gate-module-cache")

echo "== Xcode: $(xcodebuild -version | head -1)"
echo "== step 1/4 tuist install"
tuist install
# Since 2026-09-25 a shared source cache (~/.cache/swifterpm/sources) may replace
# Tuist/.build/checkouts/<pkg> with symlinks. The generated dependency projects
# reference `../../tuist-derived` relative to each checkout, which then resolves
# inside the cache ("module map file … not found", 17 failures). Materialize the
# links as APFS clones (cp -c: no extra disk) so relative paths stay in-tree; the
# cache itself is never modified.
for link in Tuist/.build/checkouts/*; do
  [ -L "$link" ] || continue
  src="$(cd "$link" && pwd -P)"
  rm "$link" && cp -Rc "$src" "$link"
  echo "== materialized symlinked checkout $(basename "$link")"
done
echo "== step 2/4 tuist generate"
tuist generate --no-open
echo "== step 3/4 SwiftTerm metal fix + Xcode-27 deployment-target floor (14.0)"
./scripts/fix-swiftterm-metal.sh
for proj in Tuist/.build/tuist-derived/*/*.xcodeproj; do
  sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 1[0-3]\.[0-9]*/MACOSX_DEPLOYMENT_TARGET = 14.0/g' \
    "$proj/project.pbxproj"
done
echo "== step 4/4 xcodebuild $MODE (explicit modules off — Xcode 27)"
if [ "$MODE" = test ]; then
  # Targeted runs fail closed (2026-10-03): if EXTRA carries any -only-testing:/
  # -skip-testing: argument, xcodebuild can exit 0 having run ZERO tests when the
  # filter matches nothing (see the FILTER NAMES note in the header). So classify
  # the run, and in targeted mode tee the output to a log so we can prove
  # afterwards that at least one test executed. Full mode keeps the exact old
  # invocation, byte for byte.
  # `set -eo pipefail` is untouched: an actual xcodebuild failure still aborts the
  # pipeline (and the script) before any of the checks below, so GATE PASSED stays
  # reachable only after a real, non-empty targeted run (or a full run).
  TARGETED=false
  for extra in "${EXTRA[@]}"; do
    case "$extra" in
      -only-testing:*|-skip-testing:*) TARGETED=true ;;
    esac
  done
  if [ "$TARGETED" = true ]; then
    GATE_TEST_LOG="$PWD/.build/gate-xcode27-test.log"
    xcodebuild test -scheme Cortex -workspace Cortex.xcworkspace \
      -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
      SWIFT_ENABLE_EXPLICIT_MODULES=NO "${DD_ARGS[@]}" "${PROVENANCE_ARGS[@]}" "${EXTRA[@]}" \
      2>&1 | tee "$GATE_TEST_LOG"
    # Count executed tests from the two summary forms the toolchain emits:
    #   Swift Testing:  "✔ Test run with 12 tests passed after 0.123 seconds."
    #   XCTest:         "Executed 12 tests, with 0 failures (0 unexpected) in …"
    # sed (not grep) so a no-match is not an error under `set -e`; awk prints 0
    # for an empty stream. Requiring the sum > 0 means that a "Test run with 0
    # tests" line, and no summary line at all, both fail the gate.
    swift_tests="$(sed -nE 's/.*Test run with ([0-9]+) tests? (passed|failed).*/\1/p' "$GATE_TEST_LOG" | awk '{ n += $1 } END { print n + 0 }')"
    xctest_tests="$(sed -nE 's/.*Executed ([0-9]+) tests?,.*/\1/p' "$GATE_TEST_LOG" | awk '{ n += $1 } END { print n + 0 }')"
    executed=$(( swift_tests + xctest_tests ))
    if [ "$executed" -le 0 ]; then
      echo "" >&2
      echo "FAIL: the -only-testing filter matched no tests — a targeted run that verifies nothing must not pass" >&2
      echo "      xcodebuild exited 0 but no test executed; log: $GATE_TEST_LOG" >&2
      echo "      Pitfall: Cortex uses Swift Testing suites. Filter by the struct's" >&2
      echo "      TYPE NAME, not the @Suite(\"…\") display string — e.g." >&2
      echo "        -only-testing:DomainTests/RouterAttentionTests" >&2
      echo "      (the display name 'RouterAttention' matches nothing, silently)." >&2
      exit 1
    fi
    echo "== targeted run executed $executed test(s) (Swift Testing: $swift_tests, XCTest: $xctest_tests)"
  else
    xcodebuild test -scheme Cortex -workspace Cortex.xcworkspace \
      -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
      SWIFT_ENABLE_EXPLICIT_MODULES=NO "${DD_ARGS[@]}" "${PROVENANCE_ARGS[@]}" "${EXTRA[@]}"
  fi
else
  xcodebuild build -scheme Cortex -workspace Cortex.xcworkspace \
    -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
    "${CONFIG_ARGS[@]}" SWIFT_ENABLE_EXPLICIT_MODULES=NO "${DD_ARGS[@]}" "${PROVENANCE_ARGS[@]}" "${EXTRA[@]}"
fi
echo "GATE PASSED"
