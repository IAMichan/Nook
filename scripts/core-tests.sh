#!/bin/bash
# Runs Nook's Foundation-only core and its tests without Xcode, with a Swift toolchain (Linux or macOS).
#
# It builds a throwaway Swift package from the sources the NookTests target lists in project.yml (minus the few that need
# Apple-only frameworks), copies the tests next to them, and runs `swift test`. Everything it needs is generated under a
# temporary folder; nothing in the repository changes.
#
#   scripts/core-tests.sh                      all portable tests
#   scripts/core-tests.sh --filter ComposerCoreTests
#
# Extra arguments go to `swift test`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${NOOK_CORE_TESTS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/nook-core-tests.XXXXXX")}"
mkdir -p "$WORK/Sources/Core" "$WORK/Tests/CoreTests"

# Sources that need Apple-only frameworks (CryptoKit, Combine views, URLSession on Linux …): they are tested on a Mac.
EXCLUDE_SOURCES=(
  "Services/Connectors/MCP/MCPOAuth.swift"
  "Services/Connectors/MCP/MCPClient.swift"
  "Brain/NetworkGuard.swift"
  "Brain/AIProvider.swift"
  "Brain/ModelDownload.swift"
  "Brain/BrainSelection.swift"
  "Brain/ChatChart.swift"
  "Brain/ChartRescue.swift"
  "Brain/MarkdownBlock.swift"
  "Services/AntigravityClient.swift"
  "Services/Workspace/Antigravity.swift"
  "Services/Workspace/TextGeneration.swift"
  "App/ChatRecovery.swift"
)
# Tests that belong to those sources.
EXCLUDE_TESTS=(
  "MCPOAuthTests" "MCPClientTests" "NetworkGuardTests" "ModelDownloadTests" "BrainSelectionTests" "AntigravityTests"
  "TextGenerationTests" "MarkdownBlockTests" "I18nCoverageTests" "ChatRecoveryTests" "AgentProcessTests" "FinishedSessionsTests"
)

python3 - "$ROOT" "$WORK" "${EXCLUDE_SOURCES[@]}" <<'PY'
import os, re, sys
root, work, *excluded = sys.argv[1:]
text = open(os.path.join(root, "project.yml")).read()
block = text[text.index("  NookTests:"):]
sources = [p for p in re.findall(r"- path: (\S+)", block) if p.endswith(".swift") and p not in excluded]
sdir = os.path.join(work, "Sources", "Core")
for folder in (sdir, os.path.join(work, "Tests", "CoreTests")):
    for name in os.listdir(folder):
        os.remove(os.path.join(folder, name))
for path in sources:
    os.symlink(os.path.join(root, path), os.path.join(sdir, path.replace("/", "__")))
PY

cat > "$WORK/Sources/Core/PortabilityShims.swift" <<'SWIFT'
// Combine's names for the few core files that mention them (Linux has no Combine).
#if !canImport(Combine)
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif
SWIFT

cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "NookCore", targets: [
    .target(name: "Core", path: "Sources/Core"),
    .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests/CoreTests"),
])
SWIFT

# The tests see the sources as a module here, but are part of the same target in Xcode: add the import.
for file in "$ROOT"/Tests/NookTests/*.swift; do
  name="$(basename "$file" .swift)"
  skip=0
  for excluded in "${EXCLUDE_TESTS[@]}"; do [ "$name" = "$excluded" ] && skip=1; done
  [ "$skip" = 1 ] && continue
  { echo "@testable import Core"; cat "$file"; } > "$WORK/Tests/CoreTests/$name.swift"
done

cd "$WORK"
echo "core tests in $WORK"
exec swift test "$@"
