#!/bin/zsh
# Build the executable and wrap it in a .app bundle (audio-capture permission is tied
# to the bundle identity, not to the terminal). Signed with the first "Apple Development"
# identity if there is one: its signature stays the same across rebuilds, so the permission
# survives. Ad-hoc otherwise, and macOS asks for the permission again after every rebuild.
set -euo pipefail
cd "${0:A:h}/.."
config=${1:-release}
swift build -c "$config"
app=build/S12AdaptiveEQ.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c "$config" --show-bin-path)/S12AdaptiveEQ" "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/"
cp profiles/s12-ultra.json "$app/Contents/Resources/"
identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}
codesign --force --sign "${identity:--}" "$app"
echo "signed with: ${identity:-ad-hoc}"
echo "$app"
