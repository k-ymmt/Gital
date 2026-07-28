#!/bin/zsh
# Compiles the git parsing layer together with Tests/main.swift and runs the assertions.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="${TMPDIR:-/tmp}/gital-tests"
mkdir -p "$BUILD_DIR"

swiftc \
  Gital/Git/GitModels.swift \
  Gital/Git/GitExecutor.swift \
  Gital/Git/DiffParser.swift \
  Gital/Git/PatchBuilder.swift \
  Gital/Git/GitRepository.swift \
  Gital/Git/CommitGraph.swift \
  Gital/Git/RepoWatcher.swift \
  Gital/GitHub/GitHubAvatars.swift \
  Tests/main.swift \
  -o "$BUILD_DIR/gital-tests"

"$BUILD_DIR/gital-tests"
