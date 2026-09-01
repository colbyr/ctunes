#!/usr/bin/env bash
# Print a field of the ctunes dev credential from 1Password.
#
#   scripts/plex-token.sh              → the token
#   scripts/plex-token.sh clientIdentifier
#
# Override the location with OP_VAULT / OP_ITEM.
set -euo pipefail

FIELD="${1:-credential}"
VAULT="${OP_VAULT:-Private}"
ITEM="${OP_ITEM:-ctunes dev token}"

if ! command -v op >/dev/null 2>&1; then
  echo "1Password CLI (op) not found. brew install 1password-cli" >&2
  exit 1
fi

if ! op read "op://${VAULT}/${ITEM}/${FIELD}" 2>/dev/null; then
  echo "Couldn't read op://${VAULT}/${ITEM}/${FIELD}." >&2
  echo "Run: python3 scripts/plex-dev-login.py" >&2
  exit 1
fi
