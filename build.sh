#!/bin/zsh

set -euo pipefail

readonly ROOT="${0:A:h}"
readonly PRODUCT="DDCVolumeKeys"
readonly APP="$ROOT/dist/$PRODUCT.app"
readonly ICON_SOURCE="$ROOT/Resources/AppIcon.png"
readonly ICON_FILE="$ROOT/Resources/AppIcon.icns"

cd "$ROOT"

mkdir -p "$ROOT/.build/cache/clang"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/cache/clang"

swift_args=(--disable-sandbox)

# A Command Line Tools update can temporarily pair a newer compiler with an
# incompatible default SDK. Prefer the known-compatible SDK when available.
readonly fallback_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -z "${SDKROOT:-}" && -d "$fallback_sdk" ]]; then
  export SDKROOT="$fallback_sdk"
fi
if [[ -n "${SDKROOT:-}" ]]; then
  swift_args+=(--sdk "$SDKROOT")
fi

echo "==> Running checks"
swift run "${swift_args[@]}" "$PRODUCT"Verification

echo "==> Building release binary"
swift build "${swift_args[@]}" -c release --product "$PRODUCT"
bin_dir="$(swift build "${swift_args[@]}" -c release --show-bin-path)"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin_dir/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON_FILE" "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.png"
for localization in "$ROOT"/Resources/*.lproj(/); do
  cp -R "$localization" "$APP/Contents/Resources/"
done

signing_identity="${DDC_VOLUME_KEYS_SIGN_IDENTITY:-}"
if [[ -n "$signing_identity" ]]; then
  echo "==> Signing with: $signing_identity"
  /usr/bin/codesign --force --timestamp=none --sign "$signing_identity" "$APP"
else
  echo "==> Ad-hoc signing (set DDC_VOLUME_KEYS_SIGN_IDENTITY for a stable identity)"
  /usr/bin/codesign --force --sign - "$APP"
fi

/usr/bin/codesign --verify --strict "$APP"
echo "==> Built $APP"
