#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo 'Building FluentCleaner.app requires macOS.' >&2
    exit 1
fi

cd "$(dirname "$0")/.."

# Build and sign on a local temporary filesystem so cloud-synced working trees
# (such as Google Drive or iCloud Drive) do not fail with SQLite build.db I/O
# errors or extended-attribute codesign errors.
if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
    temp_root=$(cd "$TMPDIR" && pwd -P)
else
    temp_root=$(cd /tmp && pwd -P)
fi
work_dir=$(mktemp -d "${temp_root%/}/fluentcleaner-build.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

scratch_path=$work_dir/swift-build
swift build --scratch-path "$scratch_path" --configuration release --product FluentCleaner
binary_directory=$(swift build --scratch-path "$scratch_path" --configuration release --show-bin-path)

staged_bundle=$work_dir/FluentCleaner.app
mkdir -p "$staged_bundle/Contents/MacOS"
install -m 644 macOS/Info.plist "$staged_bundle/Contents/Info.plist"
install -m 755 "$binary_directory/FluentCleaner" "$staged_bundle/Contents/MacOS/FluentCleaner"
xattr -cr "$staged_bundle" 2>/dev/null || true
codesign --force --sign - "$staged_bundle"

bundle=build/FluentCleaner.app
mkdir -p build
rm -rf "$bundle"
ditto --norsrc --noextattr "$staged_bundle" "$bundle"
printf 'Built %s\n' "$bundle"
