#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BUILD_DIR="$ROOT_DIR/build/Tests"
if (( $# > 0 )); then
  TEST_BUILD_DIR="$1"
fi
mkdir -p "$TEST_BUILD_DIR"

xcrun swiftc \
  -swift-version 5 \
  "$ROOT_DIR/Sources/Models.swift" \
  "$ROOT_DIR/Sources/CuratedTextSelection.swift" \
  "$ROOT_DIR/Sources/CuratedClipboardStore.swift" \
  "$ROOT_DIR/Tests/CuratedClipboardStoreTests.swift" \
  -o "$TEST_BUILD_DIR/CuratedClipboardStoreTests"

"$TEST_BUILD_DIR/CuratedClipboardStoreTests"
