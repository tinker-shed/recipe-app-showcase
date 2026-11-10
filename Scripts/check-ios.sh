#!/bin/bash
# Unsigned compile/link validation; does not launch an app or open a library.
set -euo pipefail
cd "$(dirname "$0")/.."
export TMPDIR="$PWD/working/app-features/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/working/app-features/ios-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$TMPDIR"
mobile_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --disable-sandbox --target RecipeCore --triple arm64-apple-ios15.0-simulator --sdk "$mobile_sdk" --cache-path "$PWD/working/app-features/swift-cache" --scratch-path "$PWD/working/app-features/ios-direct"
swiftc -parse-as-library -sdk "$mobile_sdk" -target arm64-apple-ios15.0-simulator -Xcc -isysroot -Xcc "$mobile_sdk" -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I working/app-features/ios-direct/arm64-apple-ios-simulator/debug/Modules iOS-App/RecipeMobileApp.swift working/app-features/ios-direct/arm64-apple-ios-simulator/debug/RecipeCore.build/*.o -o working/app-features/RecipeMobile
xcrun vtool -show-build working/app-features/RecipeMobile
