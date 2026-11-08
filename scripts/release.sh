#!/usr/bin/env bash
# Packages Shothook for download: a drag-to-Applications DMG, a zip, and a Homebrew cask.
#
#   scripts/release.sh 0.1.0             build + package into dist/
#   scripts/release.sh 0.1.0 --publish   …and create the GitHub release v0.1.0, then bump the
#                                        Homebrew tap (../homebrew-tap, or $SHOTHOOK_TAP_DIR) if present
#
# Gatekeeper-clean downloads need a "Developer ID Application" signing identity and a notarytool
# keychain profile (one-time: xcrun notarytool store-credentials shothook --apple-id … --team-id …),
# selected with SHOTHOOK_NOTARY_PROFILE=shothook. Without them the app is still signed, but macOS
# asks people to approve it once (System Settings → Privacy & Security → Open Anyway); the
# Homebrew cask then clears the quarantine flag itself so `brew install` just works.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
NOTARY="${SHOTHOOK_NOTARY_PROFILE:-}"
APP=build/Shothook.app
DIST=dist
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

SHOTHOOK_VERSION="$VERSION" scripts/build-app.sh
# (no `exit` in awk: closing the pipe early would SIGPIPE codesign and trip pipefail)
IDENTITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !done {print $2; done=1}')"
NOTARIZED=false

notarize() { xcrun notarytool submit "$1" --keychain-profile "$NOTARY" --wait; }

if [[ -n "$NOTARY" ]]; then
  [[ "$IDENTITY" == "Developer ID Application"* ]] || { echo "notarizing needs a Developer ID Application identity, not: $IDENTITY" >&2; exit 1; }
  ditto -c -k --keepParent "$APP" build/notarize.zip
  notarize build/notarize.zip
  xcrun stapler staple "$APP"
  NOTARIZED=true
fi

rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/Shothook.zip"

# DMG: the app beside an Applications shortcut, with the app icon as the volume icon.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Support/AppIcon.icns "$STAGE/.VolumeIcon.icns"
hdiutil create -quiet -volname Shothook -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$STAGE.dmg"
MOUNT="$(hdiutil attach -nobrowse -noautoopen -readwrite "$STAGE.dmg" | awk -F'\t' '/\/Volumes\// {print $NF}')"
xcrun SetFile -a C "$MOUNT"
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$STAGE.dmg" -format UDZO -imagekey zlib-level=9 -o "$DIST/Shothook.dmg"
rm -f "$STAGE.dmg"
if $NOTARIZED; then TIMESTAMP=--timestamp; else TIMESTAMP=--timestamp=none; fi
codesign --sign "$IDENTITY" "$TIMESTAMP" "$DIST/Shothook.dmg"
if $NOTARIZED; then
  notarize "$DIST/Shothook.dmg"
  xcrun stapler staple "$DIST/Shothook.dmg"
fi

# Homebrew cask, pinned to this release's DMG.
SHA="$(shasum -a 256 "$DIST/Shothook.dmg" | cut -d' ' -f1)"
{
  cat <<EOF
cask "shothook" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Shothook.dmg"
  name "Shothook"
  desc "Hotkey screenshots thrown straight into your AI coding agent"
  homepage "https://github.com/$REPO"

  depends_on macos: ">= :sonoma"

  app "Shothook.app"
EOF
  if ! $NOTARIZED; then
    cat <<'EOF'

  # Not notarized yet: clear the download quarantine so Gatekeeper doesn't block first launch.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Shothook.app"]
  end
EOF
  fi
  cat <<'EOF'

  uninstall quit: "dev.shothook.Shothook"

  zap trash: [
    "~/.config/shothook",
    "~/Library/Preferences/dev.shothook.Shothook.plist",
  ]
end
EOF
} > "$DIST/shothook.rb"

echo "dist/: Shothook.dmg ($(du -h "$DIST/Shothook.dmg" | cut -f1)), Shothook.zip, shothook.rb — signed by $IDENTITY, notarized: $NOTARIZED"

[[ "$PUBLISH" == "--publish" ]] || exit 0

TAP_NAME="$(dirname "$REPO")/tap"
NOTES="**Install:** \`brew install --cask $TAP_NAME/shothook\`, or download **Shothook.dmg** below and drag it into Applications."
$NOTARIZED || NOTES+=$'\n\n'"Not notarized yet: the first time you open a downloaded copy, go to **System Settings → Privacy & Security → Open Anyway** (Homebrew installs skip this)."
gh release create "v$VERSION" "$DIST/Shothook.dmg" "$DIST/Shothook.zip" --repo "$REPO" \
  --title "Shothook $VERSION" --notes "$NOTES" --generate-notes
TAP="${SHOTHOOK_TAP_DIR:-../homebrew-tap}"
if [[ -d "$TAP/.git" ]]; then
  mkdir -p "$TAP/Casks"
  cp "$DIST/shothook.rb" "$TAP/Casks/shothook.rb"
  git -C "$TAP" add Casks/shothook.rb
  git -C "$TAP" commit -q -m "shothook $VERSION"
  git -C "$TAP" push -q
  echo "tap updated: $TAP"
fi
