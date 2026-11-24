#!/usr/bin/env bash
# Archive a Release build and upload it to App Store Connect, signed in with
# the team's App Store Connect API key rather than the Apple Account in
# Xcode's Accounts settings, whose session expires and fails the export with
# "App Store Connect access for … is required".
#
# The key is an Admin team key in 1Password (the .p8 attached,
# the key id as `username`, the issuer id as `Issuer`). xcodebuild only takes
# the key as a file, so it is written to a private temp directory for the
# length of the run and removed on exit. Override with ASC_UPLOAD_OP_ITEM.
set -euo pipefail

VAULT="${OP_VAULT:-Private}"
# "Apple App Store Connect (Admin)": cloud signing needs the Admin role, which
# the feedback key lacks. Referenced by UUID so a rename doesn't break it.
ITEM="${ASC_UPLOAD_OP_ITEM:-dv4cxt2phfxmp5i2rhxsofuozi}"
# "Apple App Store Connect (Developer)", the feedback key. The issuer id is
# the team's, the same for every key, so it answers when ITEM has none.
ISSUER_ITEM="${ASC_OP_ITEM:-schb6jmus3gptj36srkqxjh7vm}"
PROJECT=App/ctunes.xcodeproj
SCHEME=ctunes
DD=build/DerivedData
ARCHIVE=build/ctunes.xcarchive

if ! command -v op >/dev/null 2>&1; then
  echo "1Password CLI (op) not found. brew install 1password-cli" >&2
  exit 1
fi

op_read() {
  local item="${2:-$ITEM}"
  op read "op://${VAULT}/${item}/$1" || {
    echo "Couldn't read op://${VAULT}/${item}/$1." >&2
    exit 1
  }
}

KEY_ID="$(op_read username | tr -d '[:space:]')"
ISSUER="$(op_read Issuer | tr -d '[:space:]')"
[[ -n "$ISSUER" ]] || ISSUER="$(op_read Issuer "$ISSUER_ITEM" | tr -d '[:space:]')"

KEY_DIR="$(mktemp -d)"
chmod 700 "$KEY_DIR"
trap 'rm -rf "$KEY_DIR"' EXIT
KEY_PATH="$KEY_DIR/AuthKey_${KEY_ID}.p8"
( umask 077; op_read "AuthKey_${KEY_ID}.p8" > "$KEY_PATH" )

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$KEY_ID"
  -authenticationKeyIssuerID "$ISSUER"
)

rm -rf "$ARCHIVE" build/export
xcodebuild -scheme "$SCHEME" -project "$PROJECT" -derivedDataPath "$DD" \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" "${AUTH[@]}" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export \
  "${AUTH[@]}"
