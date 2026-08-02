#!/bin/sh
# Rebuilds Gital/Resources/ShikiDiff.js from entry.mjs. The output is
# committed, so this only needs to run after editing entry.mjs or bumping the
# shiki dependencies in package.json. Requires Node.js.
set -eu
cd "$(dirname "$0")"

if [ -f package-lock.json ]; then npm ci; else npm install; fi

# The banner stamps the bundle with its source hash;
# DiffSyntaxHighlightingTests recomputes it from entry.mjs, so an edited
# entry.mjs with a stale committed bundle fails the Swift test suite.
ENTRY_HASH=$(shasum -a 256 entry.mjs | awk '{print $1}')

mkdir -p ../../Gital/Resources
npx esbuild entry.mjs \
    --bundle \
    --minify \
    --format=iife \
    --target=safari16 \
    --banner:js="/*gital-entry-sha256:${ENTRY_HASH}*/" \
    --outfile=../../Gital/Resources/ShikiDiff.js

node test.mjs

ls -lh ../../Gital/Resources/ShikiDiff.js
