#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build-arm64
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86_64
app_dir="$project_dir/dist/聊析.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
lipo -create .build-arm64/arm64-apple-macosx/release/ChatArchive \
    .build-x86_64/x86_64-apple-macosx/release/ChatArchive -output "$app_dir/Contents/MacOS/ChatArchive"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n "${CHATARCHIVE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CHATARCHIVE_SIGN_IDENTITY" "$app_dir"
else
    codesign --force --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
lipo "$app_dir/Contents/MacOS/ChatArchive" -verify_arch arm64 x86_64
ditto -c -k --keepParent "$app_dir" "$project_dir/dist/ChatArchive-macOS-universal.zip"
dmg_temp="$(mktemp -d /private/tmp/chatarchive-dmg.XXXXXX)"
trap 'rm -f "$dmg_temp/Applications"; rmdir "$dmg_temp"' EXIT
ditto "$app_dir" "$dmg_temp/聊析.app"
ln -s /Applications "$dmg_temp/Applications"
hdiutil create -ov -volname '聊析' -srcfolder "$dmg_temp" -format UDZO "$project_dir/dist/ChatArchive-macOS-universal.dmg"
# A successful hdiutil detaches its image; remove only the disposable bundle we copied.
rm -rf "$dmg_temp/聊析.app"
echo "$project_dir/dist/ChatArchive-macOS-universal.dmg"
