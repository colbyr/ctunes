#!/usr/bin/env python3
"""Mint a Plex dev token and store it in 1Password.

Runs the same PIN link flow the app uses, then writes the token to a
1Password item so it never lands on disk. The token is never printed.

  python3 scripts/plex-dev-login.py

Override the destination with OP_VAULT / OP_ITEM.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

VAULT = os.environ.get("OP_VAULT", "Private")
ITEM = os.environ.get("OP_ITEM", "ctunes dev token")
CLIENT_ID = "ctunes-dev-cli"
HEADERS = {
    "Accept": "application/json",
    "X-Plex-Product": "ctunes-dev",
    "X-Plex-Client-Identifier": CLIENT_ID,
    "X-Plex-Version": "1.0",
    "X-Plex-Device": "CLI",
    "X-Plex-Platform": "macOS",
}


def request(url, method="GET"):
    req = urllib.request.Request(url, method=method, headers=HEADERS)
    with urllib.request.urlopen(req) as response:
        return json.load(response)


def item_exists():
    return subprocess.run(
        ["op", "item", "get", ITEM, "--vault", VAULT],
        capture_output=True,
    ).returncode == 0


def store(token):
    """Create or update the item. Values go through argv, never a file."""
    fields = [f"credential={token}", f"clientIdentifier={CLIENT_ID}"]
    if item_exists():
        cmd = ["op", "item", "edit", ITEM, "--vault", VAULT, *fields]
    else:
        cmd = ["op", "item", "create",
               "--category", "API Credential",
               "--title", ITEM,
               "--vault", VAULT,
               *fields]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        return False
    return True


def main():
    if not shutil.which("op"):
        print("1Password CLI (op) not found. brew install 1password-cli", file=sys.stderr)
        return 1

    pin = request("https://plex.tv/api/v2/pins?strong=true", method="POST")
    params = urllib.parse.urlencode({
        "clientID": CLIENT_ID,
        "code": pin["code"],
        "context[device][product]": "ctunes-dev",
    })
    print("\nApprove this device in your browser:\n")
    print(f"  https://app.plex.tv/auth#?{params}\n")
    print("Waiting (2 min timeout). You'll land on watch.plex.tv — that's expected.")

    deadline = time.time() + 120
    while time.time() < deadline:
        token = request(f"https://plex.tv/api/v2/pins/{pin['id']}").get("authToken")
        if token:
            print()
            if not store(token):
                print("Approved, but storing in 1Password failed.", file=sys.stderr)
                return 1
            print(f"Stored in 1Password: op://{VAULT}/{ITEM}/credential")
            return 0
        time.sleep(1)
        print(".", end="", flush=True)

    print("\nTimed out waiting for approval.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
