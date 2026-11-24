#!/usr/bin/env bash
# Archive a Release build and upload it to App Store Connect, signed in with
# the team's App Store Connect API key rather than the Apple Account in
# Xcode's Accounts settings, whose session expires and fails the export with
# "App Store Connect access for … is required".
#
# The key is an Admin team key in 1Password's Apple Developer vault (the .p8
# attached, the key id as `username`, the issuer id as `Issuer`), read through
# scripts/op-read.sh. xcodebuild only takes the key as a file, so it is written
# to a private temp directory for the length of the run and removed on exit.
# Override the item with ASC_UPLOAD_OP_ITEM.
set -euo pipefail

# "Apple App Store Connect (Admin)": cloud signing needs the Admin role, which
# the feedback key lacks.
ITEM="${ASC_UPLOAD_OP_ITEM:-pvymsahqhzxz6eqyq6v6f3cg3u}"
PROJECT=App/ctunes.xcodeproj
SCHEME=ctunes
DD=build/DerivedData
ARCHIVE=build/ctunes.xcarchive

op_read() { "$(dirname "$0")/op-read.sh" "$ITEM" "$1"; }

KEY_ID="$(op_read username | tr -d '[:space:]')"
ISSUER="$(op_read Issuer | tr -d '[:space:]')"

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
