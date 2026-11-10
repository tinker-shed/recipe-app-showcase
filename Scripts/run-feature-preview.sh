#!/bin/bash
# Always uses an isolated development library; never opens the normal app library.
set -euo pipefail
cd "$(dirname "$0")/.."
export TMPDIR="$PWD/working/app-features/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/working/app-features/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export RECIPEAPP_LIBRARY_PATH="$PWD/working/app-features/manual-preview-library"
mkdir -p "$TMPDIR"
swift build --disable-sandbox --product RecipeApp --cache-path "$PWD/working/app-features/swift-cache" --scratch-path "$PWD/working/app-features/build"
exec working/app-features/build/debug/RecipeApp
