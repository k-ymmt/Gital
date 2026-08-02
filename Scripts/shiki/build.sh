#!/bin/sh
# Rebuilds Gital/Resources/ShikiDiff.js from entry.mjs. The output is
# committed, so this only needs to run after editing entry.mjs or bumping the
# shiki dependencies in package.json. Requires Node.js.
set -eu
cd "$(dirname "$0")"

if [ -f package-lock.json ]; then npm ci; else npm install; fi

mkdir -p ../../Gital/Resources
npx esbuild entry.mjs \
    --bundle \
    --minify \
    --format=iife \
    --target=safari16 \
    --outfile=../../Gital/Resources/ShikiDiff.js

ls -lh ../../Gital/Resources/ShikiDiff.js
