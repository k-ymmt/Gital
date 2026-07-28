#!/bin/zsh
# Runs the GItalTests unit-test bundle (Swift Testing, hosted in Gital.app).
# Extra arguments are passed through to xcodebuild, e.g.:
#   Scripts/run-tests.sh -only-testing:GItalTests/DiffParserTests
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild test \
  -project Gital.xcodeproj \
  -scheme Gital \
  -destination 'platform=macOS' \
  -quiet \
  "$@"
