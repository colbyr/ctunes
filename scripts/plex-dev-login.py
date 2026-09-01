#!/usr/bin/env python3
"""Mint a Plex dev token for local testing.

Runs the same PIN link flow the app uses and writes the result to
.plex-dev.json, which is gitignored. The token is never printed.
"""
import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request

OUT = pathlib.Path(__file__).resolve().parent.parent / ".plex-dev.json"
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


def main():
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
        checked = request(f"https://plex.tv/api/v2/pins/{pin['id']}")
        token = checked.get("authToken")
        if token:
            OUT.write_text(json.dumps(
                {"clientIdentifier": CLIENT_ID, "token": token}, indent=2) + "\n")
            OUT.chmod(0o600)
            print(f"\nToken written to {OUT.name} (gitignored, not printed).")
            return 0
        time.sleep(1)
        print(".", end="", flush=True)

    print("\nTimed out waiting for approval.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
