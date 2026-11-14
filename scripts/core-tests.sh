#!/bin/bash
# Runs the macOS app's Foundation-only core and its tests without Xcode, with a Swift toolchain (Linux or macOS).
#
# It builds a Swift package from the sources the NookTests target lists in apps/macos/project.yml (minus the few that need
# Apple-only frameworks), copies the tests next to them, and runs `swift test`. The package lives in .build/core-tests in
# this checkout (git-ignored, like scripts/xcode.sh's build): the next run is incremental and compiles only what changed.
# Set NOOK_CORE_TESTS_DIR to put it elsewhere, or NOOK_CORE_TESTS_FRESH=1 for a throwaway build in a temporary folder.
#
#   scripts/core-tests.sh                      all portable tests
#   scripts/core-tests.sh --changed            only the tests the change since origin's default branch can affect
#   scripts/core-tests.sh --changed=HEAD~3     ... since another revision (uncommitted and untracked files included)
#   scripts/core-tests.sh --filter ComposerCoreTests
#
# --changed is for while you work; before a commit or pull request, run them all (scripts/core-tests-sync.py says how
# it picks). Extra arguments go to `swift test`.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$REPO/apps/macos"
CHANGED=""
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --changed) CHANGED=auto ;;
    --changed=*) CHANGED="${arg#--changed=}" ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [ -n "${NOOK_CORE_TESTS_DIR:-}" ]; then
  WORK="$NOOK_CORE_TESTS_DIR"
elif [ "${NOOK_CORE_TESTS_FRESH:-0}" = 1 ]; then
  # A run builds ~370 MB here; remove it afterwards, or every run leaves that behind.
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/nook-core-tests.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
else
  WORK="$REPO/.build/core-tests"
fi
mkdir -p "$WORK/Sources/Core" "$WORK/Tests/CoreTests"

# Writes stdin to $1 only when it differs: an unchanged file keeps its date, so the build does not compile it again.
write_if_changed() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")"
  cat > "$tmp"
  if cmp -s "$tmp" "$1"; then rm -f "$tmp"; else mv "$tmp" "$1"; fi
}

# Sources that need Apple-only frameworks (CryptoKit, Combine views, URLSession on Linux …): they are tested on a Mac.
EXCLUDE_SOURCES=(
  "Services/Workspace/AgentGovernor.swift"
  "Core/SystemLoad.swift"
  "Core/Log.swift"
  "Services/Connectors/MCP/MCPOAuth.swift"
  "Services/Connectors/MCP/MCPClient.swift"
  "Brain/NetworkGuard.swift"
  "Brain/AIProvider.swift"
  "Brain/ModelDownload.swift"
  "Brain/BrainSelection.swift"
  "Services/AntigravityClient.swift"
  "Services/Workspace/Antigravity.swift"
  "Services/Workspace/TextGeneration.swift"
  "Services/Workspace/TextGenerators.swift"
  "App/ChatRecovery.swift"
  "Brain/ChatImage.swift"
  "Services/Messages/ChatImageRender.swift"
  "Services/WhatsApp/WhatsAppGateway.swift"
  "Services/WhatsApp/WhatsAppExport.swift"
  "Services/WhatsApp/WhatsAppNames.swift"
  "Brain/Weather.swift"
  "Services/LocalAgentScanner.swift"
)
if [ "$(uname)" != "Darwin" ]; then
  EXCLUDE_SOURCES+=(
    "Brain/ChatChart.swift"
    "Brain/ChartRescue.swift"
    "Brain/MarkdownBlock.swift"
    "Services/Workspace/RunPullRequestLinks.swift"
    "Services/Workspace/PullRequestAsked.swift"
    "Services/Updates/Ed25519Verifier.swift"
    "Services/Autocomplete/CompletionSealing.swift"
    "../../packages/protocol/Sources/CompanionSeal.swift"
    "../../packages/protocol/Sources/RelayPushSeal.swift"
    "../../packages/protocol/Sources/GuestLinkSeal.swift"
  )
fi
# Tests that belong to those sources.
EXCLUDE_TESTS=(
  "AgentGovernorTests"
  "SessionKeeperTests"
  "MCPOAuthTests" "MCPClientTests" "NetworkGuardTests" "ModelDownloadTests" "BrainSelectionTests" "AntigravityTests"
  "TextGenerationTests" "TextGeneratorTests" "MarkdownBlockTests" "I18nCoverageTests" "ChatRecoveryTests" "AgentProcessTests" "FinishedSessionsTests"
  "ExtrasTests" "WhatsAppTests" "WhatsAppActionsTests" "WhatsAppExportTests" "LocalAgentScannerTests"
  "ChatImageRenderTests" "DayBucketsTests"
)


write_if_changed "$WORK/Sources/Core/PortabilityShims.swift" <<'SWIFT'
import Foundation

// Combine's names for the few core files that mention them (Linux has no Combine).
#if !canImport(Combine)
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

// Linux has no Objective-C runtime and so no autorelease pools: the body just runs.
#if !canImport(ObjectiveC)
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }
#endif

// APFS clones are the Mac's: on Linux `clonefile` always fails, so WorktreeCheckoutCache falls back as it does off APFS.
#if !canImport(Darwin)
public let CLONE_NOFOLLOW: Int32 = 0x0001
public func clonefile(_ source: String, _ destination: String, _ flags: UInt32) -> Int32 { -1 }
#endif

// URLRequest, URLSession and HTTPURLResponse live in FoundationNetworking on Linux.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

// Linux's Foundation has no NSDataDetector. Links and mail addresses are found with a pattern close to what Apple's
// detector finds (for ChatFormat's "Copy link"); dates are not detected here, so their tests skip or run on a Mac.
#if !canImport(Darwin)
extension NSTextCheckingResult.CheckingType {
    public static let date = NSTextCheckingResult.CheckingType(rawValue: 1 << 3)
    public static let link = NSTextCheckingResult.CheckingType(rawValue: 1 << 5)
}

public final class NSDataDetector {
    public struct Match {
        public let range: NSRange
        public let url: URL?
        public let date: Date? = nil
    }

    private let types: NSTextCheckingResult.CheckingType
    private static let links = try! NSRegularExpression(pattern:
        #"(?:mailto:)?[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}|(?:https?://|www\.)[^\s<>"'`()\[\]]*[^\s<>"'`()\[\].,;:!?]"#)

    public init(types: NSTextCheckingResult.CheckingType.RawValue) throws {
        self.types = NSTextCheckingResult.CheckingType(rawValue: types)
    }

    public func matches(in string: String, options: NSRegularExpression.MatchingOptions = [], range: NSRange) -> [Match] {
        guard types.contains(.link) else { return [] }
        let text = string as NSString
        return Self.links.matches(in: string, options: options, range: range).compactMap { match in
            let written = text.substring(with: match.range)
            let address: String
            if written.contains("@") && !written.contains("/") {
                address = written.hasPrefix("mailto:") ? written : "mailto:" + written
            } else {
                address = written.hasPrefix("www.") ? "http://" + written : written
            }
            return URL(string: address).map { Match(range: match.range, url: $0) }
        }
    }
}
#endif

// `tr` lives in Core/I18n.swift, which needs SwiftUI and is not part of this package: a text is its key here.
func tr(_ key: String, _ args: CVarArg...) -> String { key }

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case en = "en"
    case nl = "nl"
    case de = "de"
    case fr = "fr"
    case es = "es"
    public var id: String { rawValue }
}

public final class I18n: @unchecked Sendable {
    public static let shared = I18n()
    public var currentLanguage: AppLanguage = .en
    public var language: AppLanguage = .en
    static func text(_ key: String, _ args: [CVarArg], for lang: AppLanguage) -> String { ([key] + args.map { "\($0)" }).joined(separator: " ") }
}
SWIFT

write_if_changed "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "NookCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "Core", dependencies: [.target(name: "SQLite3", condition: .when(platforms: [.linux]))], path: "Sources/Core"),
    // macOS has an SQLite3 module in its SDK; on Linux the system library (libsqlite3-dev) gets one here.
    .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
    .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests/CoreTests"),
])
SWIFT

mkdir -p "$WORK/Sources/SQLite3"
write_if_changed "$WORK/Sources/SQLite3/module.modulemap" <<'MAP'
module SQLite3 [system] {
    header "shim.h"
    link "sqlite3"
    export *
}
MAP
echo '#include <sqlite3.h>' | write_if_changed "$WORK/Sources/SQLite3/shim.h"

# Links the sources and copies the tests (with `@testable import Core`, as they are part of the same target in Xcode).
sync() {
  EXCLUDE_SOURCES="$(printf '%s\n' "${EXCLUDE_SOURCES[@]}")" EXCLUDE_TESTS="$(printf '%s\n' "${EXCLUDE_TESTS[@]}")" python3 "$REPO/scripts/core-tests-sync.py" "$ROOT" "$WORK" "$@"
}
if [ -n "$CHANGED" ]; then
  REPORT="$(sync --changed "$CHANGED")"
else
  REPORT="$(sync)"
fi
MODE="$(tail -n 1 <<< "$REPORT")"
if [ "$MODE" != all ]; then
  sed -n '1p' <<< "$REPORT"
fi
if [ "$MODE" = none ]; then
  exit 0
fi

cd "$WORK"
echo "core tests in $WORK"
# Tests that read the app's sources (UIConsistencyTests) find them here: the copies in $WORK have another #filePath.
export NOOK_MACOS_ROOT="$ROOT"
# The build takes one of this machine's build slots, at a lower priority (scripts/build-slot.sh says why). The tests
# run after it, outside the slot: they need a core or two, and another agent's build should not wait for them.
SLOT="$REPO/scripts/build-slot.sh"
if [ "$MODE" = some ] && ! "$SLOT" swift build --build-tests; then
  # A picked test may use a helper the selection missed: build them all, and still run only the picked ones.
  echo "the selected tests do not build on their own; building all tests and running the selected ones"
  CLASSES="$(sed -n 's/^test classes: //p' <<< "$REPORT")"
  sync >/dev/null
  "$SLOT" swift build --build-tests
  swift test --skip-build --filter "\.($CLASSES)/" ${ARGS[@]+"${ARGS[@]}"}
  exit
fi
[ "$MODE" = some ] || "$SLOT" swift build --build-tests
swift test --skip-build ${ARGS[@]+"${ARGS[@]}"}
