# The App Review account

App Review needs a Plex account to sign in with. It is a separate plex.tv
account that the owner account has invited to the Mac Mini server, with only
the **Demo Music** library shared. Its login is in 1Password,
`Private / Plex (App Store Review)`, with username, password and the
two-factor verification code. Put those in the App Store Connect review
notes.

## Shared servers take their own token (the 401)

The first sign-in with this account got a 401 from the server. The app was
sending the account's plex.tv token to the server. A server the account
owns accepts that token. A server shared with the account rejects it and
accepts only the `accessToken` that `/api/v2/resources` lists for it.
Measured as the review account on Oct 19:

| Request | Token | Result |
|---|---|---|
| `/library/sections` | account's plex.tv token | 401 |
| `/library/sections` | resource `accessToken` | 200, Demo Music |

Fixed by `PlexServer.accessToken`, which the probes and `PlexLibrary` use for
every request and every stream and artwork URL. The last token is kept in
the keychain (`server-token.<machineIdentifier>`) so offline artwork URLs
match what the image cache saw online. Every flow tested before this used
the owner account, which is why nothing caught it.

## Testing as the reviewer

`op` reads the item when 1Password's CLI integration is on. If `op` reports
"No accounts configured" even with that setting on, check whether macOS
denied the terminal access to other apps' data: `op` then can't read
1Password's settings file
(`OP_DEBUG=1 op account list --debug` shows "operation not permitted").
Run `tccutil reset SystemPolicyAppData com.googlecode.iterm2` and allow the
prompt when it comes back.

To get a token, sign in as the reviewer: `POST https://plex.tv/api/v2/users/signin`
with `login`, `password` and `verificationCode`, form-encoded, plus the
usual `X-Plex-*` identity headers. Use one fixed client identifier, or every
run registers another device on the account. Then pass the token as
`SIMCTL_CHILD_CTUNES_DEV_TOKEN` (with `CTUNES_DEV_ALBUM` and
`CTUNES_DEV_AUTOPLAY=1` to check playback). Verified this way on Oct 19:
the library loads and an album plays.

## Before submitting

- **Make sure the reviewer won't end up on the relay.** In the simulator the
  app connected over the remote address `45-79-129-106…plex.direct`, and
  every local address failed. Reviewers are never on the LAN. If Remote
  Access isn't direct, they stream through Plex's relay, whose bandwidth is
  capped, and Original quality could stall. Check Settings → Remote Access
  on the server.
- **Keep the server up during review.** If the server can't be reached, the
  reviewer gets the offline or connect-failed screen, which is a likely
  rejection. Don't let the Mac Mini sleep, update or restart while the
  build is in review.
- **Keep the share as it is.** If the invite is revoked or Demo Music is
  removed from it, the server drops out of the account's resources or the
  library request fails.
- **Changing the review account's password invalidates its tokens.** Update
  1Password and the review notes together.
