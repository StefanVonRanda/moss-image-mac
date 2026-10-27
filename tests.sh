#!/bin/zsh
# Headless checks of the app's logic (layout compile, render JSON, triggers, presets, mask from boxes…).
# Compiles the app sources minus the @main file together with Tests/checks/main.swift. Run: ./tests.sh
set -e
cd "$(dirname "$0")"
. scripts/toolchain.sh
mkdir -p .build/checks
swiftc -O -target arm64-apple-macosx14.0 -o .build/checks/checks Tests/checks/main.swift $(ls Sources/MossImage/*.swift | grep -v MossImageApp.swift) 2>&1 | grep -E "error" && exit 1
.build/checks/checks
