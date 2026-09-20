#!/usr/bin/env python3
"""Print TestFlight feedback for ctunes from the App Store Connect API.

    scripts/testflight-feedback.py            → screenshots and crashes, newest first
    scripts/testflight-feedback.py --days 7   → only the last week

Screenshots and crash logs are saved under build/feedback/<submission id>/.
The API key lives in 1Password (the .p8 as an attachment, the key id as
`username`, the issuer id as `Issuer`); it is piped from `op` into `openssl`
and never written to disk. Override the item with ASC_OP_ITEM.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

VAULT = os.environ.get("OP_VAULT", "Private")
ITEM = os.environ.get("ASC_OP_ITEM", "App Store Connect API Key")
BUNDLE_ID = "com.colbyr.ctunes"
API = "https://api.appstoreconnect.apple.com"
OUT = Path(__file__).resolve().parent.parent / "build" / "feedback"


def op_read(field):
    result = subprocess.run(
        ["op", "read", f"op://{VAULT}/{ITEM}/{field}"], capture_output=True
    )
    if result.returncode != 0:
        sys.exit(f"Couldn't read op://{VAULT}/{ITEM}/{field}: {result.stderr.decode().strip()}")
    return result.stdout


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_signature(der):
    """openssl emits DER SEQUENCE { r, s }; a JWT wants r || s, 32 bytes each."""
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    raw = b""
    for _ in range(2):
        length = der[i + 1]
        raw += der[i + 2 : i + 2 + length].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + length
    return raw


def make_token():
    key_id = op_read("username").decode().strip()
    issuer = op_read("Issuer").decode().strip()
    key = op_read(f"AuthKey_{key_id}.p8")
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    message = b64url(json.dumps(header).encode()) + "." + b64url(json.dumps(payload).encode())
    # The key goes in on stdin, so the message is what takes the file.
    with tempfile.NamedTemporaryFile() as f:
        f.write(message.encode())
        f.flush()
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", "/dev/stdin", f.name],
            input=key, capture_output=True, check=True,
        ).stdout
    return message + "." + b64url(raw_signature(der))


def get(token, path, missing_ok=False):
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        sys.exit(f"{error.code} {path}\n{error.read().decode()}")


def submissions(token, app_id, kind):
    body = get(token, f"/v1/apps/{app_id}/{kind}?limit=200&sort=-createdDate&include=build")
    builds = {b["id"]: b["attributes"]["version"] for b in body.get("included", []) if b["type"] == "builds"}
    for item in body["data"]:
        item["buildNumber"] = builds.get(item["relationships"]["build"]["data"]["id"], "?")
    return body["data"]


def save(url, path):
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as response:
        path.write_bytes(response.read())


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--days", type=int, help="only feedback from the last N days")
    args = parser.parse_args()

    token = make_token()
    apps = get(token, f"/v1/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=name")["data"]
    if not apps:
        sys.exit(f"No app with bundle id {BUNDLE_ID}")
    app_id = apps[0]["id"]

    items = submissions(token, app_id, "betaFeedbackScreenshotSubmissions")
    items += submissions(token, app_id, "betaFeedbackCrashSubmissions")
    items.sort(key=lambda item: item["attributes"]["createdDate"], reverse=True)
    if args.days:
        cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
        items = [
            item for item in items
            if datetime.fromisoformat(item["attributes"]["createdDate"].replace("Z", "+00:00")) >= cutoff
        ]

    for item in items:
        a = item["attributes"]
        crash = item["type"] == "betaFeedbackCrashSubmissions"
        print(f"{'CRASH' if crash else 'FEEDBACK'}  {a['createdDate']}  build {item['buildNumber']}  {item['id']}")
        print(f"  {a['deviceModel']}  {a['devicePlatform']} {a['osVersion']}  {a['connectionType']}  {a.get('email') or 'anonymous'}")
        if a.get("comment"):
            print(f"  “{a['comment']}”")
        folder = OUT / item["id"]
        for index, shot in enumerate(a.get("screenshots") or []):
            path = folder / f"screenshot-{index}.jpg"
            save(shot["url"], path)
            print(f"  {path}")
        if crash:
            # Apple drops the log of an older crash while still listing the submission.
            path = folder / "crash.log"
            log = None if path.exists() else get(
                token, f"/v1/betaFeedbackCrashSubmissions/{item['id']}/crashLog", missing_ok=True
            )
            if log:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(log["data"]["attributes"]["logText"])
            print(f"  {path}" if path.exists() else "  (crash log no longer available)")
        print()

    if not items:
        print("No feedback.")


if __name__ == "__main__":
    main()
