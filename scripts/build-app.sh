#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/dist"
app_dir="$output_dir/聊析.app"

cd "$project_dir"
swift build -c release

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/release/ChatArchive" "$app_dir/Contents/MacOS/ChatArchive"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
