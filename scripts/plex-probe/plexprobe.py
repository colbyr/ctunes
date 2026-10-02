"""Shared bits for the server probes: the dev token, discovery, one request helper.

Run from anywhere. The token and client identifier come from PLEX_TOKEN and
PLEX_CLIENT_ID, or failing those from scripts/plex-token.sh (1Password, cached
in the login keychain for a day). The token rides in a header, never a URL.

The identity is iOS-shaped (Platform iOS, Product ctunes, Device iPhone) under
the dev client identifier plus "-ios": the download queue refuses the CLI
identity, which has no client profile on the server (see
notes/transcoded-downloads.md). The suffix is fixed so the probes register one
device on the account, not one per run.
"""
import concurrent.futures
import io
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
OUT = REPO / "build" / "probe"


def _token_field(field=None):
    cmd = [str(SCRIPTS / "plex-token.sh")] + ([field] if field else [])
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


TOKEN = os.environ.get("PLEX_TOKEN") or _token_field()
CLIENT_ID = os.environ.get("PLEX_CLIENT_ID") or _token_field("clientIdentifier")

HEADERS = {
    "Accept": "application/json",
    "X-Plex-Token": TOKEN,
    "X-Plex-Client-Identifier": CLIENT_ID + "-ios",
    "X-Plex-Product": "ctunes",
    "X-Plex-Version": "1.0",
    "X-Plex-Device": "iPhone",
    "X-Plex-Platform": "iOS",
    "X-Plex-Platform-Version": "27.0",
}

# The CLI's own identity, for the one probe that shows the difference.
CLI_HEADERS = {
    **HEADERS,
    "X-Plex-Client-Identifier": CLIENT_ID,
    "X-Plex-Product": "ctunes-dev",
    "X-Plex-Device": "CLI",
    "X-Plex-Platform": "macOS",
}


def get(url, timeout=5, headers=None, method="GET", data=None):
    """(status, headers, body); status None and the error text as the body
    when the request never got an answer."""
    h = dict(HEADERS)
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h, method=method, data=data)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except Exception as e:  # noqa: BLE001 - the probes print whatever happened
        return None, {}, str(e).encode()


def query(params):
    """Strictly percent-encoded, like PlexLibrary.streamURL: the profile extra
    carries `&` and `=` the server would otherwise split on."""
    return "&".join(
        f"{urllib.parse.quote(k, safe='')}={urllib.parse.quote(str(v), safe='')}"
        for k, v in params.items()
    )


def discover():
    """The first server on the account and the connection that answered,
    local ones preferred. Every connection is probed at once, as the app does."""
    st, _, body = get("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=0", timeout=10)
    if st != 200:
        sys.exit(f"plex.tv resources: {st} {body[:200]!r}")
    servers = [r for r in json.loads(body) if "server" in r.get("provides", "")]
    if not servers:
        sys.exit("no server on the account")
    srv = servers[0]
    conns = srv["connections"]

    def probe(c):
        s, _, _ = get(c["uri"] + "/identity", timeout=4)
        return c, s

    with concurrent.futures.ThreadPoolExecutor(len(conns)) as ex:
        results = list(ex.map(probe, conns))
    ok = [c for c, s in results if s == 200]
    ok.sort(key=lambda c: (not c.get("local"), c.get("relay", False)))
    if not ok:
        sys.exit(f"no connection answered: {[(c['address'], s) for c, s in results]}")
    return srv, ok[0]["uri"]


def sessions(base):
    """Live transcode sessions as (progress, context, codec)."""
    st, _, b = get(base + "/transcode/sessions")
    mc = json.loads(b)["MediaContainer"]
    if not mc.get("size"):
        return []
    return [
        (round(m["TranscodeSession"].get("progress", 0)), m["TranscodeSession"].get("context"), m["TranscodeSession"].get("audioCodec"))
        for m in mc.get("Metadata", [])
    ]


def music_section(base):
    st, _, b = get(base + "/library/sections")
    sections = [s for s in json.loads(b)["MediaContainer"]["Directory"] if s["type"] == "artist"]
    return next((s for s in sections if "music" in s["title"].lower()), sections[-1])


def tracks(base, section, sort, n=60):
    st, _, b = get(
        base + f"/library/sections/{section}/all?type=10&sort={sort}",
        headers={"X-Plex-Container-Start": "0", "X-Plex-Container-Size": str(n)},
    )
    return json.loads(b)["MediaContainer"].get("Metadata", [])


def describe(t):
    part = t["Media"][0]["Part"][0]
    return (
        f"rk={t['ratingKey']} {t.get('grandparentTitle')} / {t['title']} "
        f"{t['duration'] / 1000:.0f}s {part.get('container')} {part.get('size', 0) / 1e6:.1f}MB"
    )


def server_log(base, pattern, last=60):
    """Lines of the server's own log matching `pattern`, from the diagnostics zip."""
    st, h, b = get(base + "/diagnostics/logs", timeout=120)
    if st != 200:
        return [f"diagnostics/logs: {st}"]
    z = zipfile.ZipFile(io.BytesIO(b))
    name = next(n for n in z.namelist() if n.endswith("Plex Media Server.log"))
    lines = z.read(name).decode("utf-8", "replace").splitlines()
    return [l for l in lines if re.search(pattern, l)][-last:]
