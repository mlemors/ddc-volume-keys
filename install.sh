#!/bin/zsh

set -euo pipefail

readonly ROOT="${0:A:h}"
readonly PRODUCT="DDCVolumeKeys"
readonly BUNDLE_ID="de.mlemors.DDCVolumeKeys"
readonly SOURCE_APP="$ROOT/dist/$PRODUCT.app"
readonly TARGET_APP="/Applications/$PRODUCT.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing build: $SOURCE_APP" >&2
  echo "Run ./build.sh first." >&2
  exit 1
fi

# Validate before stopping the working app or changing its authorization.
/usr/bin/codesign --verify --strict "$SOURCE_APP"
source_signature="$(/usr/bin/codesign -dvvv "$SOURCE_APP" 2>&1)"
if [[ "$source_signature" == *"Signature=adhoc"* ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" != "$BUNDLE_ID" ]]; then
  echo "Refusing an ad-hoc build or unexpected app identity." >&2
  exit 1
fi
existing_signature="$(/usr/bin/codesign -dvvv "$TARGET_APP" 2>&1 || true)"
if [[ -d "$TARGET_APP" && "$existing_signature" != *"Signature=adhoc"* ]]; then
  requirement="$(/usr/bin/codesign -d -r- "$TARGET_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
  [[ -n "$requirement" ]] || exit 1
  /usr/bin/codesign --verify --strict -R "=$requirement" "$SOURCE_APP"
fi

# Stage on the destination filesystem; retain the previous version for recovery.
privilege=()
if [[ ! -w /Applications ]]; then
  /usr/bin/sudo -v
  privilege=(/usr/bin/sudo)
fi
staging_dir="$("${privilege[@]}" /usr/bin/mktemp -d /Applications/.DDCVolumeKeys-update.XXXXXX)"
"${privilege[@]}" /bin/chmod 755 "$staging_dir"
"${privilege[@]}" /usr/bin/ditto "$SOURCE_APP" "$staging_dir/$PRODUCT.app"
/usr/bin/codesign --verify --strict "$staging_dir/$PRODUCT.app"

if /usr/bin/pgrep -x "$PRODUCT" >/dev/null 2>&1; then
  /usr/bin/pkill -x "$PRODUCT" || true
  for attempt in {1..50}; do
    /usr/bin/pgrep -x "$PRODUCT" >/dev/null 2>&1 || break
    /bin/sleep 0.1
  done
  if /usr/bin/pgrep -x "$PRODUCT" >/dev/null 2>&1; then
    echo "App did not exit; installation cancelled." >&2
    exit 1
  fi
fi

# Finder does not run an uninstall hook when an app bundle is replaced. Reset
# the permission only during the one-time migration away from an old ad-hoc
# build. Stable signed updates keep the existing Accessibility authorization.
if [[ "$existing_signature" == *"Signature=adhoc"* ]]; then
  /usr/bin/tccutil reset Accessibility "$BUNDLE_ID"
fi

if [[ -d "$TARGET_APP" ]]; then
  "${privilege[@]}" /bin/mv "$TARGET_APP" "$staging_dir/Previous.app"
fi
if ! "${privilege[@]}" /bin/mv "$staging_dir/$PRODUCT.app" "$TARGET_APP"; then
  [[ ! -d "$staging_dir/Previous.app" ]] || "${privilege[@]}" /bin/mv "$staging_dir/Previous.app" "$TARGET_APP"
  exit 1
fi
/usr/bin/open "$TARGET_APP"

echo "Installed $TARGET_APP"
echo "Previous version retained in $staging_dir"
if [[ "$existing_signature" == *"Signature=adhoc"* ]]; then
  echo "Enable Accessibility once for the new signing identity."
fi
