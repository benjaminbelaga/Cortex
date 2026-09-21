#!/bin/bash
# Workaround for tuist/tuist#9111: Tuist adds .metal files as both Sources and Resources,
# causing "Unexpected duplicate tasks" build errors.
# This removes the duplicate "Shaders.metal in Sources" entry, keeping only Resources.
#
# ALSO (2026-09-20): pin SwiftTerm to its forkpty path. Upstream's Package.swift
# deliberately comments out the swift-subprocess dependency ("no way of
# configuring the child process to be a controlling terminal"), but the source
# still carries `#if canImport(Subprocess)` blocks. In the Tuist workspace the
# module becomes visible as soon as Subprocess.framework lands in the products
# dir — i.e. depending on parallel build order — and then the compile fails with
# "missing required module '_SubprocessCShims'" (race reproduced 2026-09-20;
# broke D2's never-compiled commit). Flipping every `canImport(Subprocess)` to
# false reproduces exactly the upstream-supported SwiftPM state (no dep).

# Search known locations. Tuist may place the generated project under
# Tuist/.build/tuist-derived (classic) or .build/tuist-derived (cache build),
# and the cached binaries path varies across Tuist versions. Also discover any
# SwiftTerm project nested under the current tree.
CANDIDATES=$({
  find . -path "*/SwiftTerm/*.xcodeproj/project.pbxproj" 2>/dev/null
  find ~/.tuist ~/Library/Caches/tuist 2>/dev/null \
    -type f -name 'project.pbxproj' -path '*/SwiftTerm.xcodeproj/*' 2>/dev/null
} | awk 'NF && !seen[$0]++')

# Pin the forkpty path deterministically (see header). The checkout is shared
# across projects, so this is idempotent: only the original conditional is
# rewritten, a second run finds nothing to change.
SUBPROCESS_CHECKOUT="Tuist/.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift"
if [ -f "$SUBPROCESS_CHECKOUT" ] && grep -q 'canImport(Subprocess)' "$SUBPROCESS_CHECKOUT"; then
  sed -i.bak 's/#if canImport(Subprocess)/#if false \/* Subprocess pinned off — see fix-swiftterm-metal.sh *\//g' "$SUBPROCESS_CHECKOUT"
  rm -f "${SUBPROCESS_CHECKOUT}.bak"
  echo "Fixed: pinned SwiftTerm forkpty path (disabled canImport(Subprocess) blocks)"
fi

if [ -z "$CANDIDATES" ]; then
  echo "SwiftTerm project not found in any known location, skipping"
  exit 0
fi

fixed=0
while IFS= read -r PBXPROJ; do
  if grep -q "Shaders.metal in Sources" "$PBXPROJ"; then
    sed -i.bak '/Shaders\.metal in Sources/d' "$PBXPROJ"
    rm -f "${PBXPROJ}.bak"
    echo "Fixed: removed duplicate Shaders.metal from Sources in $PBXPROJ"
    fixed=$((fixed + 1))
  fi
done <<< "$CANDIDATES"

if [ "$fixed" -eq 0 ]; then
  echo "No duplicate Metal entry found in any SwiftTerm project, skipping"
fi
