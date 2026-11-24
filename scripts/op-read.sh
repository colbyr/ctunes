#!/usr/bin/env bash
# Print one field of an item in the "Apple Developer" 1Password vault.
#
#   scripts/op-read.sh <item> <field>
#
# Reads go through the vault's read-only service account, whose token sits in
# the login keychain (service `apple-developer-op-service-account`, account
# `op`), so no read waits on a 1Password prompt. Without that keychain item it
# falls back to the signed-in `op` session, which prompts. Writes (make token)
# can't use the service account and always take the session.
#
# Vault and items are referenced by ID so a rename doesn't break a script.
set -euo pipefail

VAULT="${OP_VAULT:-wlsoejymgzbclrj4a3euqwn6me}"   # Apple Developer
ITEM="${1:?item}"
FIELD="${2:?field}"

if ! command -v op >/dev/null 2>&1; then
  echo "1Password CLI (op) not found. brew install 1password-cli" >&2
  exit 1
fi

if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && token="$(security find-generic-password \
    -s apple-developer-op-service-account -a op -w 2>/dev/null)"; then
  export OP_SERVICE_ACCOUNT_TOKEN="$token"
fi

if ! op read "op://${VAULT}/${ITEM}/${FIELD}"; then
  echo "Couldn't read op://${VAULT}/${ITEM}/${FIELD}." >&2
  exit 1
fi
