#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BUILD_DIR="${1:-$ROOT_DIR/build/Tests}"
mkdir -p "$TEST_BUILD_DIR"

xcrun swiftc -swift-version 5 \
  -framework AppKit -framework Carbon \
  "$ROOT_DIR/Sources/Models.swift" \
  "$ROOT_DIR/Sources/HotKey.swift" \
  "$ROOT_DIR/Sources/ClipboardPanelController.swift" \
  "$ROOT_DIR/Sources/CuratedTextSegments.swift" \
  "$ROOT_DIR/Sources/CuratedClipboardStore.swift" \
  "$ROOT_DIR/Sources/CuratedClipboardPanelController.swift" \
  "$ROOT_DIR/Sources/StandaloneSnippetController.swift" \
  "$ROOT_DIR/Tests/FeatureInteractionTests.swift" \
  -o "$TEST_BUILD_DIR/FeatureInteractionTests"

"$TEST_BUILD_DIR/FeatureInteractionTests"
