# The plex.tv 404s on Sep 2 (evening): outage, not a shadow ban

## Verdict

The 404s were a Plex-side incident, not throttling or a security flag on us.
Plex's status page has an incident, "Issues with plex.tv API" on the
*Authentication and API server (plex.tv)* component, whose symptoms and timing
match what we saw. Nothing in our process tripped a control, though the way we
use the dev token would be the first thing to fix if one ever did (see
"What could plausibly trip a real control").

## Timeline (all UTC, Sep 3; subtract 4h for EDT)

| Time | Event | Source |
|---|---|---|
| 20:35 (Sep 2) | Last plex.tv traffic from any Claude session before the gap | transcript `65a35f8e` |
| 00:06 | Polish session starts; only reads code for the first five minutes | transcript `55b96859` |
| 00:11:35 | First plex.tv request of the session (app launch with the real token) fails | " |
| 00:11:57 | `make live-test`: `.http(status: 404, body: Optional(""))` from `/api/v2/resources` | " |
| 00:20–00:25 | App on `main` (stash) fails identically; live test then passes 3× in a row | " |
| 00:26–00:27 | `curl` to `/api/v2/resources` **and** `/api/v2/user`: 404 regardless of client id, product, or User-Agent | " |
| 00:27:45 | Same requests return 200 | " |
| 00:39:16 | 404 ×7 at 5s intervals, then 200 | " |
| 00:44:08 | 404 ×11 at 5s intervals, then 200 | " |
| 00:55 | Plex opens the incident: "We're investigating issues impacting API services for some users. This can affect account auth (sign-in & PIN verification) and creation, access to Downloads page items, and more. You may experience slow responses or failures." | status.plex.tv |
| 01:17 | "A fix has been implemented, we are monitoring that traffic properly comes back to normal" | status.plex.tv |

Incident page: https://status.plex.tv/incidents/01M1JC6YVMEAVCGD2XR9661NZ4

The block was already in place at the session's very first plex.tv request, before
the session had sent anything. The preceding 3.5 hours had no Claude activity at
all. Whatever started it was not this session, and the "other app on the same
network can't sign in" report is the same outage: sign-in and PIN verification are
exactly what Plex listed as impacted.

## Why the response shape says "outage" rather than "block"

The 404s did not come from the Plex application. Compare headers:

Normal plex.tv reply (401 without a token, captured Sep 3 01:09 UTC):

```
HTTP/1.1 401 Unauthorized
Date: ...
Content-Type: application/json
Content-Length: 83
Connection: keep-alive
cache-control: no-cache
set-cookie: _my-plex_session_32=...
x-request-id: 4ed45d1d2d3bdb76e6424dbf62bc730c
x-runtime: 0.083636
vary: Origin
strict-transport-security: ...
x-frame-options: SAMEORIGIN
x-content-type-options: nosniff
x-xss-protection: 1; mode=block
referrer-policy: origin-when-cross-origin
{"errors":[{"code":1001,"message":"User could not be authenticated","status":401}]}
```

The 404 during the window:

```
HTTP/1.1 404 Not Found
strict-transport-security: max-age=31536000; includeSubDomains; preload
x-frame-options: SAMEORIGIN
x-xss-protection: 1; mode=block
date: Thu, 03 Sep 2026 00:27:34 GMT
content-length: 0
```

No `x-request-id`, no `x-runtime`, no session cookie, no `Content-Type`, no JSON
error body, and none of the load-balancer-cased headers. The Rails app never
handled the request. Every genuine Plex rejection we know of is explicit: `401`
with `code 1001`, `429` with `code 1003 "API rate limit exceeded"`, or the
IP-lockout text below. An empty 404 from a layer in front of the app, alternating
with 200s request by request, is what a partially failed backend pool looks like,
and it matches Plex's own wording ("some users", "slow responses or failures").

plex.tv resolves to EC2 addresses (`44.210.41.33`, `35.172.142.61`,
`34.238.225.186`), so this is AWS load balancing, not Cloudflare, despite the
Cloudflare blog post about www.plex.tv.

## Two misdiagnoses in that session, corrected

- **"The app got a bogus token."** It did not. `scripts/plex-token.sh` prints its
  error to stderr, and `$(...)` captures stdout only, so a failed read yields an
  empty `CTUNES_DEV_TOKEN`, which `developmentToken()` treats as unset. The app
  fell back to the keychain token. No garbage token was ever sent to plex.tv, in
  this session or the earlier ones on Sep 2 (02:02, 02:03, 14:06 UTC) where the
  1Password read really did fail.
- **"The 1Password read failed."** At 00:11:57 it was `cat -A` (not a macOS flag)
  exiting immediately and closing the pipe; `op read` got SIGPIPE and the script
  reported "Couldn't read". Twenty seconds later the token read fine (`exit=0`,
  20 chars). 1Password was never locked during that session.

## Known Plex security and abuse controls (research)

None of these presents as a bare 404, which is the main reason to rule them out.

- **IP-level sign-in lockout.** `401` with the message *"User could not be
  authenticated. This IP appears to be having trouble signing in to an account
  (detected repeated failures)"* or *"Sign in has been temporarily disabled: too
  many failed attempts"*. Triggered by repeated failed password sign-ins from one
  IP; lifts on its own after hours to days; no self-service reset. Threads:
  https://forums.plex.tv/t/605846, https://forums.plex.tv/t/462241,
  https://forums.plex.tv/t/399936. We never attempt password sign-in, so the only
  way to hit it is a human retrying a wrong password.
- **API rate limiter.** `429` with `{"code":1003,"message":"API rate limit
  exceeded"}`. Documented cases are all server-side: certificate signing requests,
  `servers.xml` publish, payment methods. It sticks until Plex staff reset it.
  https://forums.plex.tv/t/886080, https://forums.plex.tv/t/941675,
  https://forums.plex.tv/t/941743
- **Token invalidation.** Tokens die when the account changes password with "sign
  out connected devices", or when a device is removed from
  https://app.plex.tv/desktop/#!/settings/devices. Plex forced this broadly after
  the Sep 2025 breach. Presents as `401`, permanently, not intermittently.
- **Device-bound JWT auth.** Plex is rolling out JWTs bound to a per-device public
  key; plexapi.dev says identity headers "help Plex enforce rate limits or
  compatibility checks" and that the client identifier should be "stable for the
  lifetime of your app installation". Legacy `X-Plex-Token` still works and PMS
  only understands legacy tokens (https://forums.plex.tv/t/934478). Nothing found
  describing enforcement against a legacy token used from several identifiers.
- **Third-party client policy.** Since Apr 2025 remote streaming through
  non-Plex apps needs a Plex Pass, enforced on Roku from Nov 2025 and extending to
  "any third party clients using the API" in 2026. That is a PMS-side playback
  gate, not a plex.tv API block.
- **Cloudflare token invalidation** (Plex blog): tokens that transited Cloudflare
  during the 2017 Cloudbleed window were invalidated. Historical only.

## What could plausibly trip a real control

Recorded so we can fix it before it matters. None of it caused the 404s.

1. **One token, many client identifiers.** The dev token was minted by
   `scripts/plex-dev-login.py` as device `ctunes-dev-cli` / product `ctunes-dev`,
   but every consumer presents it differently:
   - the simulator app: its own keychain-minted UUID, product `ctunes`
   - `make live-test`: `ctunes-dev-cli`, product `ctunes-dev`
   - the curl probes in that session: a fresh `uuidgen`, `ctunes-dev-cli`, and
     `other-id-1234`
   Each new identifier + token pair registers another device on the account (see
   the devices page for strays). That is the single most "shared token" looking
   pattern we produce, and the thing a device-binding heuristic would key on.
2. **Volume is low.** Roughly 70 plex.tv-touching commands across nine sessions on
   Sep 2, each one or two `/api/v2/resources` calls. Under one request a minute
   averaged; bursts of maybe 10 in a minute during test loops. Nowhere near
   anything Plex has been seen to limit.
3. **Probing loops during an incident.** The 20 and 30 iteration curl loops at 5s
   intervals ran while the service was degraded. Harmless here, but if Plex were
   ever applying a block, hammering during it is how to extend one.
4. **Simulator reinstalls** (`simctl uninstall`, Sep 2 15:21 UTC) can mint a new
   client identifier if the keychain item does not survive, which registers yet
   another device. Not confirmed either way.
5. **Physical phone + simulator + CLI** all under one account from one home IP is
   normal Plex usage and not a concern.

## How to tell next time, in under a minute

1. Check https://status.plex.tv first.
2. `curl -sS -D - -o /dev/null https://plex.tv/api/v2/user -H 'Accept: application/json'`
   with no token. A healthy service answers `401` with `x-request-id` and a JSON
   `code 1001` body. An empty-bodied 404 or 5xx without `x-request-id` is their
   edge, not us.
3. With the token, a real rejection is a `401`/`429` with a JSON `code`. Read the
   message; the IP lockout and rate limiter both say so in words.
4. `make live-test` separates plex.tv from the app in one command.

## Follow-ups worth doing (not done here)

- Have the simulator dev path present the same client identifier the token was
  minted with (`scripts/plex-token.sh clientIdentifier`), or mint the dev token
  from the simulator's identity, so the token stays on one device.
- Make `make sim-run-live` fail loudly when `plex-token.sh` prints nothing,
  instead of silently launching signed-out.
- Tidy stray `ctunes` / `ctunes-dev` devices at
  https://app.plex.tv/desktop/#!/settings/devices.
