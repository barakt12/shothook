#!/usr/bin/env bash
# Builds build/Shothook.app (release, universal) and signs it.
# Signing with a stable identity matters: macOS ties Accessibility / Screen Recording
# grants to the signature, so ad-hoc builds would lose them on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Shothook"

APP=build/Shothook.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shothook"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Support/Sounds/*.wav "$APP/Contents/Resources/"

# Reuse the identity already on the installed app so a rebuild doesn't rotate certs
# and drop the Screen Recording / Accessibility grants.
pick_identity() {
  if [[ -n "${SHOTHOOK_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$SHOTHOOK_SIGN_IDENTITY"
    return
  fi
  local installed="${SHOTHOOK_INSTALL_DIR:-/Applications}/Shothook.app"
  if [[ -d "$installed" ]]; then
    local existing
    existing="$(codesign -dvv "$installed" 2>&1 | awk -F= '/^Authority=/ && $0 !~ /Apple (Root|Worldwide|Timestamp)/ {print $2; exit}')"
    if [[ -n "$existing" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -F -q "$existing"; then
      printf '%s' "$existing"
      return
    fi
  fi
  security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}'
}
IDENTITY="$(pick_identity)"
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no signing identity found; ad-hoc signing (permissions reset on each rebuild)" >&2
  IDENTITY="-"
fi
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "built $APP ($(du -sh "$APP" | cut -f1), signed: $IDENTITY)"
