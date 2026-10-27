#!/bin/bash
# Usage: scripts/build-xcframework.sh <version> <output-dir>
# Writes <output-dir>/HotCodePushCore.xcframework.zip, a dynamic framework for the iOS device and simulator with their dSYMs.
set -euo pipefail

version=$1
output_dir=$(mkdir -p "$2" && cd "$2" && pwd)
build_dir=$output_dir/build
rm -rf "$build_dir" "$output_dir/HotCodePushCore.xcframework" "$output_dir/HotCodePushCore.xcframework.zip"

create_arguments=()
for platform in "iOS" "iOS Simulator"; do
  archive=$build_dir/$platform.xcarchive
  xcodebuild archive \
    -project Distribution/HotCodePushCore.xcodeproj \
    -scheme HotCodePushCore \
    -configuration Release \
    -destination "generic/platform=$platform" \
    -archivePath "$archive" \
    -derivedDataPath "$build_dir/DerivedData" \
    -quiet \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$version"
  create_arguments+=(
    -framework "$archive/Products/Library/Frameworks/HotCodePushCore.framework"
    -debug-symbols "$archive/dSYMs/HotCodePushCore.framework.dSYM")
done
xcodebuild -create-xcframework "${create_arguments[@]}" -output "$output_dir/HotCodePushCore.xcframework"

# Archiving the Swift package's product recorded the deployment target as the SDK; the framework target must record the real one.
for binary in "$output_dir"/HotCodePushCore.xcframework/*/HotCodePushCore.framework/HotCodePushCore; do
  sdk=$(xcrun vtool -show-build "$binary" | awk '$1 == "sdk" { print $2; exit }')
  if [ "${sdk%%.*}" -lt 26 ]; then
    echo "error: $binary was linked against SDK $sdk, expected 26 or later" >&2
    exit 1
  fi
done

(cd "$output_dir" && ditto -c -k --keepParent HotCodePushCore.xcframework HotCodePushCore.xcframework.zip)
rm -rf "$build_dir"
