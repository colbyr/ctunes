#!/usr/bin/env bash
# Print a field of the ctunes dev credential from 1Password.
#
#   scripts/plex-token.sh              → the token
#   scripts/plex-token.sh clientIdentifier
#
# Read through the vault's service account (scripts/op-read.sh), so there is
# no prompt and nothing to cache. Override the item with OP_ITEM.
set -euo pipefail

ITEM="${OP_ITEM:-mrtczbfwuz5fcyjnwfechsvqg4}"   # "ctunes dev token"

"$(dirname "$0")/op-read.sh" "$ITEM" "${1:-credential}" || {
  echo "Run: python3 scripts/plex-dev-login.py" >&2
  exit 1
}
