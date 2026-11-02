#!/usr/bin/env bash
# Run the core unit tests on Linux (e.g. a Claude Code cloud session).
# The SwiftUI/AppKit app target can't build on Linux, so this builds a temporary
# package with only InboxCore + NexusCore + tests, and links stubs for the SQLite
# snapshot API that GRDB references but Linux's system SQLite doesn't export.
# The app itself is only syntax-checked here; real builds happen on the Mac (scripts/build-app.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_VERSION="${SWIFT_VERSION:-6.0.3}"

if ! command -v swift >/dev/null; then
  echo "Installing Swift $SWIFT_VERSION…"
  sudo apt-get update -qq && sudo apt-get install -y -qq libsqlite3-dev libncurses-dev clang curl >/dev/null
  . /etc/os-release
  DIST="ubuntu${VERSION_ID}"; DIRDIST="ubuntu${VERSION_ID//./}"
  curl -sSfL -o /tmp/swift.tgz "https://download.swift.org/swift-${SWIFT_VERSION}-release/${DIRDIST}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-${DIST}.tar.gz"
  mkdir -p /tmp/swiftroot && tar xzf /tmp/swift.tgz -C /tmp/swiftroot --strip-components=1 && rm /tmp/swift.tgz
  export PATH=/tmp/swiftroot/usr/bin:$PATH
fi

# 1. Syntax-check every source file (including the macOS-only app target).
swiftc -parse $(find "$ROOT/Sources" -name '*.swift') && echo "Syntax OK"

# 2. Core tests in a temporary Linux-only package.
WORK="${TMPDIR:-/tmp}/unifiedinbox-linux"
rm -rf "$WORK/Sources" "$WORK/Tests"; mkdir -p "$WORK/Sources"
cp -r "$ROOT/Sources/InboxCore" "$ROOT/Sources/NexusCore" "$WORK/Sources/"
cp -r "$ROOT/Tests" "$WORK/"
cat > "$WORK/Package.swift" <<'PKG'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "UnifiedInboxLinux",
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")],
    targets: [
        .target(name: "InboxCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "NexusCore"),
        .testTarget(name: "InboxCoreTests", dependencies: ["InboxCore"]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
    ]
)
PKG
clang -c -fPIC "$ROOT/scripts/sqlite_snapshot_stubs.c" -o "$WORK/stubs.o"
cd "$WORK" && swift test -Xlinker "$WORK/stubs.o"
