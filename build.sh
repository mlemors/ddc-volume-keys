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

xcode_developer_dir="${DEVELOPER_DIR:-}"
if [[ -z "$xcode_developer_dir" ]]; then
  xcode_developer_dir="$(xcode-select -p 2>/dev/null || true)"
fi

# A Command Line Tools update can temporarily pair a newer compiler with an
# incompatible default SDK. Use Xcode's SDK when Xcode is active; otherwise
# prefer the known-compatible Command Line Tools SDK when available.
readonly fallback_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -z "${SDKROOT:-}" ]]; then
  if [[ "$xcode_developer_dir" == */Xcode*.app/Contents/Developer ]]; then
    xcode_sdk="$(DEVELOPER_DIR="$xcode_developer_dir" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [[ -n "$xcode_sdk" && -d "$xcode_sdk" ]]; then
      export SDKROOT="$xcode_sdk"
    fi
  elif [[ -d "$fallback_sdk" ]]; then
    export SDKROOT="$fallback_sdk"
  fi
fi
if [[ -n "${SDKROOT:-}" ]]; then
  swift_args+=(--sdk "$SDKROOT")
fi

echo "==> Running checks"
echo "==> Running portable unit and fail-safe checks"
swift run "${swift_args[@]}" "$PRODUCT"Verification

if [[ -f "$xcode_developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework/Headers/XCTest.h" ]]; then
  echo "==> Running XCTest"
  swift test "${swift_args[@]}"
elif [[ "${CI:-}" == "true" ]]; then
  echo "XCTest is required in CI but no full Xcode installation was found." >&2
  exit 1
else
  echo "==> XCTest not available without full Xcode; portable checks above are the local test run"
fi

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
