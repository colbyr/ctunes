#!/usr/bin/env python3
"""Read-only: the server's version, whether the download queue and sync
endpoints answer, and the transcoder, sync and download preferences.

    python3 scripts/plex-probe/server-info.py
"""
import json

from plexprobe import discover, get

srv, base = discover()
print("server:", srv["name"], "productVersion:", srv.get("productVersion"))
print("connection:", base.split("@")[-1])
st, _, b = get(base + "/")
root = json.loads(b)["MediaContainer"]
for key in ("version", "platform", "transcoderAudio", "sync", "backgroundProcessing", "myPlexUsername"):
    print(f"  {key}: {root.get(key)}")

print("\nendpoints:")
for path in ["/downloadQueue", "/sync/items", "/transcode/sessions", "/:/prefs"]:
    st, h, b = get(base + path)
    print(f"  {path}: {st} {h.get('Content-Type', '')} {len(b)}B")

st, h, b = get(base + "/:/prefs")
if st == 200:
    print("\nprefs (transcoder, sync, downloads):")
    for p in json.loads(b)["MediaContainer"]["Setting"]:
        if any(s in p["id"] for s in ("ranscode", "ync", "ownload")):
            print(f"  {p['id']} = {p.get('value')!r}  {p.get('summary', '')[:90]}")
