#!/bin/bash
# Builds the Release app for this Mac and installs it as "/Applications/IINA WebDAV.app".
# Re-run it after changing the code. Set NO_OPEN=1 to skip launching the app, DERIVED=<dir> to reuse a build folder.
set -euo pipefail
cd "$(dirname "$0")"

DERIVED="${DERIVED:-$PWD/build}"
DEST="/Applications/IINA WebDAV.app"
SRC="$DERIVED/Build/Products/Release/IINA.app"

[ -d deps/lib ] || ./other/download_libs.sh --arch arm64

xcodebuild -project iina.xcodeproj -scheme iina -configuration Release -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

# Quit the running copy first so its settings are saved.
osascript -e 'tell application id "com.luis.iina-webdav" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8; do pgrep -f "IINA WebDAV.app/Contents/MacOS" >/dev/null || break; sleep 1; done

rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --force --deep --sign - "$DEST"
codesign --verify --deep --strict "$DEST"
echo "Installed: $DEST"
[ "${NO_OPEN:-}" = "1" ] || open "$DEST"
