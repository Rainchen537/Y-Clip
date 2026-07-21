#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/y-clip-asset-tests.XXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT

xcrun swiftc \
  -swift-version 5 \
  "$ROOT_DIR/Sources/SoftwareUpdateAssetSelector.swift" \
  "$ROOT_DIR/Tests/SoftwareUpdateAssetSelectorTests.swift" \
  -o "$TEST_WORK/SoftwareUpdateAssetSelectorTests"

"$TEST_WORK/SoftwareUpdateAssetSelectorTests"
