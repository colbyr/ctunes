#!/usr/bin/env bash
# Print a field of the ctunes dev credential from 1Password.
#
#   scripts/plex-token.sh              → the token
#   scripts/plex-token.sh clientIdentifier
#   scripts/plex-token.sh --clear      → drop the local cache
#
# Reads are cached in the login keychain for a day so 1Password only prompts
# once, not on every make target. The keychain item is readable only by the
# `security` tool that wrote it, so the token still never sits on disk in
# plaintext. Override the TTL (seconds) with CTUNES_TOKEN_TTL, or the
# 1Password location with OP_VAULT / OP_ITEM.
set -euo pipefail

VAULT="${OP_VAULT:-Private}"
ITEM="${OP_ITEM:-ctunes dev token}"
TTL="${CTUNES_TOKEN_TTL:-86400}"
SERVICE="ctunes-dev-token-cache"

if [[ "${1:-}" == "--clear" ]]; then
  for field in credential clientIdentifier; do
    security delete-generic-password -s "$SERVICE" -a "$field" >/dev/null 2>&1 || true
  done
  exit 0
fi

FIELD="${1:-credential}"

# Cache hit: the stored secret is "<unix timestamp>:<value>".
if cached="$(security find-generic-password -s "$SERVICE" -a "$FIELD" -w 2>/dev/null)"; then
  stamp="${cached%%:*}"
  value="${cached#*:}"
  if [[ "$stamp" =~ ^[0-9]+$ ]] && (( $(date +%s) - stamp < TTL )); then
    printf '%s\n' "$value"
    exit 0
  fi
fi

if ! command -v op >/dev/null 2>&1; then
  echo "1Password CLI (op) not found. brew install 1password-cli" >&2
  exit 1
fi

if ! value="$(op read "op://${VAULT}/${ITEM}/${FIELD}" 2>/dev/null)"; then
  echo "Couldn't read op://${VAULT}/${ITEM}/${FIELD}." >&2
  echo "Run: python3 scripts/plex-dev-login.py" >&2
  exit 1
fi

# -U updates in place if the item already exists (expired entry).
security add-generic-password -U -s "$SERVICE" -a "$FIELD" \
  -w "$(date +%s):${value}" >/dev/null 2>&1 || true

printf '%s\n' "$value"
