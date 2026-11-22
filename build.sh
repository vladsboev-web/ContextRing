#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/build/ContextRing.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SIGN_IDENTITY="${SIGN_IDENTITY:-ContextRing Local Signing}"

UNIVERSAL=true

usage() {
  cat <<'EOF'
Usage: ./build.sh [--universal | --native] [-h|--help]

Options:
  --universal   Build a Universal Binary (x86_64 + arm64) (default)
  --native      Build only for the current host architecture
  -h, --help    Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --universal)
      UNIVERSAL=true
      shift
      ;;
    --native)
      UNIVERSAL=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

compile_arch() {
  local arch="$1"
  local out="$2"
  swiftc \
    -target "${arch}-apple-macosx13.0" \
    -O \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -lsqlite3 \
    "$ROOT_DIR"/Sources/*.swift \
    -o "$out"
}

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [ "$UNIVERSAL" = true ]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  compile_arch "x86_64" "$TMP_DIR/ContextRing-x86_64"
  compile_arch "arm64" "$TMP_DIR/ContextRing-arm64"
  lipo -create -output "$MACOS_DIR/ContextRing" \
    "$TMP_DIR/ContextRing-x86_64" \
    "$TMP_DIR/ContextRing-arm64"
else
  ARCH="$(uname -m)"
  compile_arch "$ARCH" "$MACOS_DIR/ContextRing"
fi

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""; then
  codesign --force --deep \
    -r="designated => identifier \"com.vladsboev.contextring\" and certificate leaf[subject.CN] = \"$SIGN_IDENTITY\"" \
    --sign "$SIGN_IDENTITY" "$APP_DIR"
  echo "Signed with local certificate: $SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP_DIR"
  echo "Signed ad-hoc (run ./setup_signing_cert.sh once to keep Accessibility permission across rebuilds)."
fi

ARCHS="$(lipo -archs "$MACOS_DIR/ContextRing" 2>/dev/null || uname -m)"
echo "Built: $APP_DIR ($ARCHS)"
