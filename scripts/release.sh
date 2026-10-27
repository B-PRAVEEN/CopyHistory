#!/bin/sh
# Builds a universal (arm64 + x86_64), ad-hoc signed release zip for the version in ./VERSION.
# Usage: scripts/release.sh [--dry-run | --ci]
#   (default)  local release: tree must be clean, on main, and tag vX.Y.Z must not exist yet.
#   --dry-run  local trial: skips the clean-tree check (branch and tag checks still apply).
#   --ci       GitHub Actions on a tag push: tree must be clean, tag vX.Y.Z must exist and point
#              at HEAD, and HEAD must be on origin/main (a tag checkout is a detached HEAD).
# Output: build/CopyHistory-X.Y.Z.zip and build/CopyHistory-X.Y.Z.zip.sha256.
# It never tags, pushes or publishes; it prints the manual commands for that instead.
# The app is ad-hoc signed and not notarised (no Apple Developer ID), so Gatekeeper asks the
# user to approve it on first launch; see README "Install".
set -eu
cd "$(dirname "$0")/.."

MODE=release
case "${1:-}" in
  "") ;;
  --dry-run) MODE=dry-run ;;
  --ci) MODE=ci ;;
  *) echo "usage: scripts/release.sh [--dry-run | --ci]" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < VERSION)"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "VERSION must be X.Y.Z (got '$VERSION')."
TAG="v$VERSION"

# --- Preconditions ---------------------------------------------------------------------------
if [ "$MODE" = dry-run ]; then
  echo "note: --dry-run: skipping the clean-tree check." >&2
elif [ -n "$(git status --porcelain)" ]; then
  die "working tree is not clean; commit or stash first (or use --dry-run for a local trial)."
fi

if [ "$MODE" = ci ]; then
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG does not exist (VERSION is $VERSION)."
  [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "tag $TAG does not point at HEAD."
  git merge-base --is-ancestor HEAD origin/main || die "HEAD is not on origin/main."
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [ "$BRANCH" = main ] || die "not on main (on '$BRANCH')."
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists; bump VERSION first."
  fi
fi

# --- Build each architecture separately, then merge ------------------------------------------
UNIVERSAL_DIR=".build/universal-release"
mkdir -p "$UNIVERSAL_DIR"
SLICES=""
for ARCH in arm64 x86_64; do
  echo "==> swift build -c release --arch $ARCH"
  BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
  swift build -c release --arch "$ARCH"
  [ -x "$BIN_DIR/CopyHistory" ] || die "$ARCH build did not produce $BIN_DIR/CopyHistory."
  SLICES="$SLICES $BIN_DIR/CopyHistory"
done
UNIVERSAL="$UNIVERSAL_DIR/CopyHistory"
# shellcheck disable=SC2086  # SLICES is a space-separated list of paths without spaces
lipo -create $SLICES -output "$UNIVERSAL"

# --- Assemble and sign the app (always ad-hoc for releases) ----------------------------------
CH_BIN="$UNIVERSAL" CH_SIGN_ID="" scripts/make-app.sh

# --- Verify ----------------------------------------------------------------------------------
APP="build/CopyHistory.app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/CopyHistory")"
echo "==> lipo -archs: $ARCHS"
for ARCH in arm64 x86_64; do
  case " $ARCHS " in *" $ARCH "*) ;; *) die "app binary is missing the $ARCH slice." ;; esac
done
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[ "$PLIST_VERSION" = "$VERSION" ] || die "Info.plist version $PLIST_VERSION != VERSION $VERSION."

# --- Zip and checksum ------------------------------------------------------------------------
ZIP_NAME="CopyHistory-$VERSION.zip"
rm -f "build/$ZIP_NAME" "build/$ZIP_NAME.sha256"
# --norsrc/--noextattr/--noacl: keep local xattrs (e.g. com.apple.provenance) out of the archive;
# otherwise they are stored as ._* AppleDouble entries that a non-Apple unzip extracts as real
# files inside the signed bundle, breaking `codesign --verify --strict`.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "build/$ZIP_NAME"
# Hash from inside build/ so the .sha256 names the bare file and `shasum -c` works wherever
# the user downloads both files.
(cd build && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
SHA="$(cut -d ' ' -f 1 "build/$ZIP_NAME.sha256")"

echo
echo "Built build/$ZIP_NAME ($(du -h "build/$ZIP_NAME" | cut -f 1 | tr -d ' '))"
echo "sha256: $SHA"
if [ "$MODE" != ci ]; then
  cat <<NEXT

Nothing was tagged, pushed or published. To release $TAG:
  git push origin main        # the release workflow requires the tagged commit to be on origin/main
  git tag -a $TAG -m "CopyHistory $VERSION"
  git push origin $TAG        # the release workflow then builds and publishes the GitHub Release
Or publish this local build by hand instead of via the workflow:
  gh release create $TAG build/$ZIP_NAME build/$ZIP_NAME.sha256 --verify-tag --title "CopyHistory $VERSION"
Then update the Homebrew cask (packaging/README.md): version "$VERSION", sha256 "$SHA".
NEXT
fi
