#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/ltkit-event-tests.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$ROOT/Native/tests/EventMailboxTests.cpp" -o "$OUTPUT/events"
"$OUTPUT/events"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$ROOT/Native/tests/DiskCheckpointTests.cpp" -o "$OUTPUT/checkpoints"
"$OUTPUT/checkpoints"
