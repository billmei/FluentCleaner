#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo 'Building FluentCleaner.app requires macOS.' >&2
    exit 1
fi

cd "$(dirname "$0")/.."
swift build --configuration release --product FluentCleaner
binary_directory=$(swift build --configuration release --show-bin-path)

bundle=build/FluentCleaner.app
mkdir -p "$bundle/Contents/MacOS"
cp macOS/Info.plist "$bundle/Contents/Info.plist"
install -m 755 "$binary_directory/FluentCleaner" "$bundle/Contents/MacOS/FluentCleaner"
codesign --force --sign - "$bundle"
printf 'Built %s\n' "$bundle"
