#!/bin/sh
# Builds a release binary and assembles a signed CopyHistory.app in ./build.
# Usage: scripts/make-app.sh   (output: build/CopyHistory.app)
# Env:   CH_SIGN_ID="<code-signing identity>" for a stable (non-ad-hoc) signature.
#
# Signing (M6): an ad-hoc signature ("-") embeds a cdhash-only designated
# requirement, and macOS TCC keys the Accessibility grant to it — so every
# rebuild invalidates the grant (System Settings still shows the toggle as on,
# but AXIsProcessTrusted() returns false and the app silently degrades to
# copy-only). To keep the grant across rebuilds, create a self-signed
# code-signing certificate in Keychain Access and pass its identity:
#   CH_SIGN_ID="Your Name" scripts/make-app.sh
# LIMIT: a self-signed identity keeps the designated requirement stable on
# this Mac only; other machines still see an untrusted signature and must
# re-grant Accessibility. Fully stable distribution needs a paid Apple
# Developer ID certificate.
set -eu
cd "$(dirname "$0")/.."

# --show-bin-path is cheap and does not build; resolve it first so the release
# build below runs exactly once.
BIN_DIR="$(swift build -c release --show-bin-path)"
swift build -c release
BIN="$BIN_DIR/CopyHistory"
# Fail early with a clear message if the release build did not produce the binary
# (otherwise the cp below fails with a cryptic "No such file or directory").
if [ ! -x "$BIN" ]; then
  echo "error: release build did not produce $BIN; run 'swift build -c release' to see why." >&2
  exit 1
fi

# The version lives in ./VERSION (one line, X.Y.Z); the app reads it back from Info.plist for
# the opt-in update check, which needs a plain numeric version to compare against releases.
VERSION="$(tr -d '[:space:]' < VERSION)"
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: VERSION must be X.Y.Z (got '$VERSION')." >&2
  exit 1
fi

APP="build/CopyHistory.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CopyHistory"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CopyHistory</string>
  <key>CFBundleDisplayName</key><string>CopyHistory</string>
  <key>CFBundleIdentifier</key><string>io.github.b-praveen.copyhistory</string>
  <key>CFBundleExecutable</key><string>CopyHistory</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign the bundle: a stable identity when provided, ad-hoc otherwise.
if [ -n "${CH_SIGN_ID:-}" ]; then
  codesign --force --sign "$CH_SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
  echo "note: ad-hoc signed; macOS revokes Accessibility/Keychain grants on every rebuild." >&2
  echo "  Rebuild with CH_SIGN_ID=\"<code-signing identity>\" for a stable signature," >&2
  echo "  or reset a stale grant with: tccutil reset Accessibility io.github.b-praveen.copyhistory" >&2
fi
# Verify the signature we just applied; aborts (set -e) if signing is broken.
codesign --verify "$APP"
echo "Built $APP"
