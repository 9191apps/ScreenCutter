#!/bin/bash
# Build the tiny E2E driver used by smoke.sh. Needs Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p bin

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

# If the selected Xcode has a mismatched SDK/compiler (usually with a beta),
# run this script with a stable developer directory, for example:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/e2e/build.sh
xcrun swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos14.0" \
  -module-cache-path bin/ModuleCache \
  -o bin/e2e-tools \
  Tools.swift

echo "built $(pwd)/bin/e2e-tools"
