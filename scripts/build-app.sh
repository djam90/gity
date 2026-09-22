#!/usr/bin/env bash
# Builds build/Gity.app with swiftc directly, so it works with just the Command Line Tools.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
OBJ="$BUILD/$CONFIG"
APP="$BUILD/Gity.app"
TARGET="$(uname -m)-apple-macos15.0"

if [[ "$CONFIG" == "release" ]]; then
  OPT=(-O -whole-module-optimization)
else
  OPT=(-Onone -g -DDEBUG)
fi

# Prefer a full Xcode install over the Command Line Tools when one is available.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]] && \
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -license check >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# SwiftUI in the macOS 27 SDK implements @State as a macro whose plugin only ships with Xcode.
# If the active toolchain lacks it (Command Line Tools only), fall back to the newest older SDK.
if [[ -z "${SDK:-}" ]]; then
  PLUGINS="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins"
  if [[ ! -e "$PLUGINS/libSwiftUIMacros.dylib" ]]; then
    SDK="$(ls -d "$(xcode-select -p)"/SDKs/MacOSX2[0-6].*.sdk 2>/dev/null | sort -V | tail -1 || true)"
  fi
fi
SDK_FLAGS=(${SDK:+-sdk "$SDK"})
export SDK

mkdir -p "$OBJ"

echo "▸ Compiling GitKit"
swiftc ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} "${OPT[@]}" -target "$TARGET" -swift-version 6 -parse-as-library \
  -module-name GitKit -emit-library -static \
  -emit-module -emit-module-path "$OBJ/GitKit.swiftmodule" \
  -o "$OBJ/libGitKit.a" \
  $(find "$ROOT/Sources/GitKit" -name '*.swift')

echo "▸ Compiling Gity"
swiftc ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} "${OPT[@]}" -target "$TARGET" -swift-version 6 -parse-as-library \
  -default-isolation MainActor \
  -module-name Gity -I "$OBJ" -L "$OBJ" -lGitKit \
  -o "$OBJ/Gity" \
  $(find "$ROOT/Sources/Gity" -name '*.swift')

echo "▸ Bundling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OBJ/Gity" "$APP/Contents/MacOS/Gity"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Gatekeeper and TCC treat the bundle as a stable identity.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

echo "✓ $APP"
