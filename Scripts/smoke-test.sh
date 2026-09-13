#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export LIBTORRENTKIT_USE_LOCAL_NATIVE=1
"$ROOT/Scripts/test-native-events.sh"
swift test
xcodebuild -project Harness/LibtorrentHarness.xcodeproj -scheme LibtorrentHarness \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES build
git diff --check
