#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
mkdir -p dist
package_temp="$(mktemp -d /private/tmp/chatarchive-package.XXXXXX)"
trap 'rmdir "$package_temp"' EXIT
zip -qr "$package_temp/windows.zip" windows \
    -x '*/__pycache__/*' '*.pyc' '*/.venv/*' '*/build/*' '*/dist/*' '*.spec'
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
mv "$package_temp/windows.zip" "$project_dir/dist/聊析-Windows-$version-启动包.zip"
echo "$project_dir/dist/聊析-Windows-$version-启动包.zip"
