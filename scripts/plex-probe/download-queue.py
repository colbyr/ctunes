#!/usr/bin/env python3
"""Measure the server's download queue (/downloadQueue), the background
transcoder behind Plex's Downloads feature. Findings and the API shape are in
notes/transcoded-downloads.md; this reproduces them.

    python3 scripts/plex-probe/download-queue.py bitrates   # musicBitrate caps, AAC targets, MP3 frame histogram
    python3 scripts/plex-probe/download-queue.py coexist    # a queue job beside a live HLS stream, both orders
    python3 scripts/plex-probe/download-queue.py parallel   # three items at once: sequential or not
    python3 scripts/plex-probe/download-queue.py decision   # directPlay=1 with and without a cap: original or MP3
    python3 scripts/plex-probe/download-queue.py identity   # the CLI identity's decisionError vs the iOS one
    python3 scripts/plex-probe/download-queue.py retain     # leave one finished item; `status <id>` later, then `cleanup`
    python3 scripts/plex-probe/download-queue.py status <id>
    python3 scripts/plex-probe/download-queue.py cleanup    # delete every item in this client's queue
    python3 scripts/plex-probe/download-queue.py log [regex]  # the server log's matching lines

Every measurement adds items to the queue and deletes them again; `retain` is
the one that leaves something behind. Files fetched land under build/probe/.
"""
import json
import struct
import sys
import time
import urllib.parse
import uuid

from plexprobe import CLI_HEADERS, OUT, describe, discover, get, music_section, query, server_log, sessions, tracks

HTTP_TARGET = "add-transcode-target(type=musicProfile&context=streaming&protocol=http&container={container}&audioCodec={codec})"
HLS_TARGET = "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)"

srv, base = discover()
SECTION = music_section(base)["key"]


def queue_id(headers=None):
    st, _, b = get(base + "/downloadQueue", method="POST", headers=headers)
    return json.loads(b)["MediaContainer"]["DownloadQueue"][0]["id"]


QID = queue_id()


def add(rk, bitrate=None, container="mp3", codec="mp3", direct=False, headers=None, extra_in_query=True):
    params = {"keys": f"/library/metadata/{rk}", "protocol": "http", "mediaIndex": "0", "partIndex": "0"}
    params["directPlay"] = params["directStream"] = "1" if direct else "0"
    if bitrate is not None:
        params["musicBitrate"] = str(bitrate)
    target = HTTP_TARGET.format(container=container, codec=codec)
    hdrs = dict(headers or {})
    if extra_in_query:
        params["X-Plex-Client-Profile-Extra"] = target
    else:
        hdrs["X-Plex-Client-Profile-Extra"] = target
    qid = queue_id(headers) if headers else QID
    st, _, b = get(base + f"/downloadQueue/{qid}/add?" + query(params), method="POST", headers=hdrs)
    try:
        return qid, json.loads(b)["MediaContainer"]["AddedQueueItems"][0]["id"]
    except Exception:
        sys.exit(f"add failed: {st} {b[:300]!r}")


def item(iid, qid=QID, headers=None):
    st, _, b = get(base + f"/downloadQueue/{qid}/items/{iid}", headers=headers)
    return (json.loads(b)["MediaContainer"].get("DownloadQueueItem") or [{}])[0]


def wait(iid, qid=QID, limit=60, headers=None):
    """(item, seconds): polls until a terminal status."""
    t0 = time.time()
    while time.time() - t0 < limit:
        it = item(iid, qid, headers)
        if it.get("status") in ("available", "error", "expired"):
            return it, time.time() - t0
        time.sleep(0.5)
    return item(iid, qid, headers), limit


def media(iid, qid=QID, rng=None):
    headers = {"Range": rng} if rng else {}
    return get(base + f"/downloadQueue/{qid}/item/{iid}/media", headers=headers, timeout=60)


def delete(iid, qid=QID, headers=None):
    st, _, _ = get(base + f"/downloadQueue/{qid}/items/{iid}", method="DELETE", headers=headers)
    return st


def pick():
    short = next(t for t in tracks(base, SECTION, "duration:asc") if 20000 <= t["duration"] <= 90000)
    longs = [t for t in tracks(base, SECTION, "duration:desc", 200) if 180000 <= t["duration"] <= 420000][:4]
    return short, longs


def mp3_frames(b):
    """Histogram of frame bitrates over the first 400 frames: shows VBR."""
    bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
    rates = [44100, 48000, 32000]
    i = 0
    if b[:3] == b"ID3":
        s = b[6:10]
        i = 10 + ((s[0] << 21) | (s[1] << 14) | (s[2] << 7) | s[3])
    hist, n = {}, 0
    while i + 4 <= len(b) and n < 400:
        if b[i] == 0xFF and (b[i + 1] & 0xE0) == 0xE0:
            br = bitrates[(b[i + 2] >> 4) & 0xF]
            sr_index = (b[i + 2] >> 2) & 3
            if br == 0 or sr_index == 3:
                break
            hist[br] = hist.get(br, 0) + 1
            n += 1
            i += int(144000 * br / rates[sr_index]) + ((b[i + 2] >> 1) & 1)
        else:
            i += 1
    return dict(sorted(hist.items()))


def save(name, b):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / name).write_bytes(b)


def hls_start(rk):
    """A live HLS transcode the way the app starts one: (session id, segment URLs)."""
    sid = str(uuid.uuid4())
    params = {
        "path": f"/library/metadata/{rk}", "mediaIndex": "0", "partIndex": "0", "protocol": "hls",
        "directPlay": "0", "directStream": "0", "fastSeek": "1", "musicBitrate": "192",
        "session": sid, "X-Plex-Session-Identifier": sid, "X-Plex-Client-Profile-Extra": HLS_TARGET,
    }
    url = base + "/music/:/transcode/universal/start.m3u8?" + query(params)
    st, _, b = get(url, timeout=15)
    variant = next(l for l in b.decode().splitlines() if l and not l.startswith("#"))
    variant_url = urllib.parse.urljoin(url, variant)
    st2, _, vb = get(variant_url, timeout=15)
    segs = [urllib.parse.urljoin(variant_url, l) for l in vb.decode().splitlines() if l and not l.startswith("#")]
    print(f"  hls start -> {st}, variant -> {st2}, {len(segs)} segments, session {sid[:8]}")
    return sid, segs


def segment(url):
    """status/bytes: a killed session answers 200 with an empty body."""
    st, _, b = get(url, timeout=8)
    return f"{st}/{len(b)}"


def hls_stop(sid):
    get(base + f"/music/:/transcode/universal/stop?session={sid}")


# MARK: measurements

def bitrates():
    short, _ = pick()
    print("track:", describe(short))
    jobs = [
        ("mp3@128", add(short["ratingKey"], 128)),
        ("mp3@192", add(short["ratingKey"], 192)),
        ("mp3@320", add(short["ratingKey"], 320)),
        ("aac/mp4@192", add(short["ratingKey"], 192, "mp4", "aac")),
        ("aac/m4a@192", add(short["ratingKey"], 192, "m4a", "aac")),
    ]
    for name, (_, iid) in jobs:
        it, dt = wait(iid)
        if it.get("status") != "available":
            print(f"  {name:12s} {it.get('status')} error={it.get('error')} {it.get('DecisionResult', {}).get('generalDecisionText')}")
        else:
            st, h, b = media(iid)
            kbps = len(b) * 8 / (short["duration"] / 1000) / 1000
            detail = f"frames={mp3_frames(b)}" if b[:3] == b"ID3" else f"magic={b[:12]!r}"
            print(f"  {name:12s} {dt:4.1f}s {len(b):8d}B avg={kbps:4.0f}kbps type={h.get('Content-Type')} {detail}")
            save(f"{name.replace('/', '_')}.bin", b)
        delete(iid)


def coexist():
    _, longs = pick()
    print("a) queue job while a live HLS stream runs")
    sid, segs = hls_start(longs[1]["ratingKey"])
    print("  first segments:", [segment(u) for u in segs[:3]], "sessions:", sessions(base))
    _, iid = add(longs[0]["ratingKey"], 128)
    it, dt = wait(iid)
    print(f"  queue item {it.get('status')} after {dt:.1f}s; segments now:", [segment(u) for u in segs[3:9]])
    st, _, b = media(iid)
    print(f"  queue media -> {st} {len(b)}B avg={len(b) * 8 / (longs[0]['duration'] / 1000) / 1000:.0f}kbps")
    delete(iid)
    hls_stop(sid)

    print("b) live HLS stream started while a queue job runs")
    _, iid = add(longs[2]["ratingKey"], 128)
    t_add = time.time()
    sid, segs = hls_start(longs[3]["ratingKey"])
    results, seen = [], []
    while time.time() - t_add < 60:
        s = item(iid).get("status")
        if not seen or seen[-1][1] != s:
            seen.append((round(time.time() - t_add, 1), s))
        if len(results) < len(segs):
            results.append(segment(segs[len(results)]))
        if s in ("available", "error", "expired") and len(results) >= 10:
            break
        time.sleep(0.4)
    print("  queue item timeline:", seen)
    print("  stream segments during and after:", results[:16])
    delete(iid)
    hls_stop(sid)


def parallel():
    _, longs = pick()
    ids = [add(t["ratingKey"], 128)[1] for t in longs[:3]]
    t0, overlap, samples = time.time(), 0, []
    while time.time() - t0 < 90:
        statuses = [item(i).get("status") for i in ids]
        samples.append((round(time.time() - t0, 1), statuses))
        overlap += statuses.count("processing") >= 2
        if all(s in ("available", "error", "expired") for s in statuses):
            break
        time.sleep(0.5)
    print(f"  done in {time.time() - t0:.1f}s; samples with two or more processing: {overlap}/{len(samples)}")
    for t, s in samples[:: max(1, len(samples) // 8)]:
        print("   ", t, s)
    for i in ids:
        delete(i)


def decision():
    short, longs = pick()
    mp3 = next((t for t in longs if t["Media"][0]["Part"][0].get("container") == "mp3"), longs[0])
    cases = [
        ("mp3 source, direct, cap 320", mp3, dict(direct=True, bitrate=320)),
        ("mp3 source, direct, cap 128", mp3, dict(direct=True, bitrate=128)),
        ("mp3 source, direct, no cap", mp3, dict(direct=True)),
        (f"{short['Media'][0]['Part'][0].get('container')} source, direct, no cap", short, dict(direct=True)),
        (f"{short['Media'][0]['Part'][0].get('container')} source, direct, cap 320", short, dict(direct=True, bitrate=320)),
    ]
    for name, t, kw in cases:
        _, iid = add(t["ratingKey"], **kw)
        it, dt = wait(iid)
        d = it.get("DecisionResult", {})
        st, h, b = media(iid, rng="bytes=0-15") if it.get("status") == "available" else (None, {}, b"")
        print(f"  {name:30s} {it.get('status'):9s} {dt:4.1f}s {d.get('directPlayDecisionText')!r} -> {st} {h.get('Content-Range')} {b[:4]!r}")
        delete(iid)


def identity():
    short, _ = pick()
    qid, iid = add(short["ratingKey"], 128, headers=CLI_HEADERS)
    it, dt = wait(iid, qid, headers=CLI_HEADERS)
    print(f"  CLI identity: {it.get('status')} {it.get('error')} {it.get('DecisionResult')}")
    delete(iid, qid, headers=CLI_HEADERS)
    _, iid = add(short["ratingKey"], 128)
    it, dt = wait(iid)
    print(f"  iOS identity: {it.get('status')} in {dt:.1f}s {it.get('DecisionResult', {}).get('generalDecisionText')!r}")
    delete(iid)


def retain():
    short, _ = pick()
    _, iid = add(short["ratingKey"], 128)
    it, dt = wait(iid)
    print(f"  {time.strftime('%H:%M:%S')} queue {QID} item {iid} {it.get('status')}; check with `status {iid}`, then `cleanup`")


def status(iid):
    it = item(iid)
    st, h, _ = media(iid, rng="bytes=0-15")
    print(f"  {time.strftime('%H:%M:%S')} item {iid} status={it.get('status')} media={st} {h.get('Content-Range')}")


def cleanup():
    st, _, b = get(base + f"/downloadQueue/{QID}/items")
    items = json.loads(b)["MediaContainer"].get("DownloadQueueItem") or []
    for it in items:
        print(f"  delete item {it['id']} ({it.get('status')}) -> {delete(it['id'])}")
    print(f"  queue {QID}: {len(items)} item(s) removed")


COMMANDS = {
    "bitrates": bitrates, "coexist": coexist, "parallel": parallel, "decision": decision,
    "identity": identity, "retain": retain, "cleanup": cleanup,
}

if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        sys.exit(__doc__)
    print("server:", srv.get("productVersion"), "queue:", QID)
    if args[0] == "status":
        status(int(args[1]))
    elif args[0] == "log":
        for line in server_log(base, args[1] if len(args) > 1 else r"[Dd]ownload[Qq]ueue|[Dd]ecision"):
            print(line[:240])
    elif args[0] in COMMANDS:
        print(f"=== {args[0]} ===")
        COMMANDS[args[0]]()
    else:
        sys.exit(f"unknown command {args[0]!r}\n{__doc__}")
    print("sessions:", sessions(base))
