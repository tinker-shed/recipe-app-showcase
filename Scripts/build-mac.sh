#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$PWD/working/tmp"
export TMPDIR="$PWD/working/tmp"
output_dir="${1:-$PWD/working/builds/RecipeApp-1.0.0}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
export CLANG_MODULE_CACHE_PATH="$PWD/working/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build_dir="$PWD/working/release-build"
# No external packages or plugins; outer execution permissions still apply.
swift build --disable-sandbox --cache-path "$PWD/working/swift-cache" --configuration release --scratch-path "$build_dir"
bin_dir="$(swift build --disable-sandbox --cache-path "$PWD/working/swift-cache" --configuration release --scratch-path "$build_dir" --show-bin-path)"
app="$output_dir/RecipeApp.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin_dir/RecipeApp" "$app/Contents/MacOS/RecipeApp"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>RecipeApp</string>
<key>CFBundleDisplayName</key><string>RecipeApp</string>
<key>CFBundleIdentifier</key><string>com.tinkershed.recipeshowcase.mac</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>RecipeApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>16</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>RecipeApp shares your recipes with your iPhone over the local network during a sync.</string>
<key>NSBonjourServices</key><array><string>_recipesync._tcp</string></array>
</dict></plist>
PLIST
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
