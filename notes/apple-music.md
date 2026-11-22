# Apple Music: a spike playing Apple Music songs inside the Plex queue

COL-117. Status: **spike, on branch `worktree-apple-music-spike`, not on main.**
Findings from one evening of device testing (iPhone Duo, iOS 27, 2026-11-21).

## Context

The goal is mixing, not either/or: Apple Music songs sitting in the same queue,
mixes and playlists as Plex tracks. The question the spike answers first is
whether playback can be shared at all, since everything else (library reads,
matching, ids) is ordinary work once it can.

**Apple Music audio never reaches `AVPlayer`.** It is DRM'd; MusicKit hands out
no URL and no file. It plays only through `ApplicationMusicPlayer` (or
`SystemMusicPlayer`, which is the Music app's own queue). So a mixed queue is
one queue with two engines: `AudioPlayer` keeps the queue, cursor, shuffle and
repeat, and hands an Apple Music entry to `ApplicationMusicPlayer` as a queue of
one, watches it end, and advances by hand, the same way it already advances
`AVPlayer` by hand rather than with `AVQueuePlayer`. None of the cache, pins,
transcoder or `-1005`/stall recovery applies to those entries.

## What the spike does

- `App/ctunes/AppleMusicEngine.swift`: the MusicKit side. An entry is a
  `PlexTrack` with `ratingKey` `am:<catalog id>`, decoded from a hand-built
  payload (so the queue, Up Next and shuffle need no change); the `Song` is kept
  by that key. `load` sets the queue to the one song, `prepareToPlay`, `play`.
  A 250ms poll of `state.playbackStatus`, `playbackTime` and
  `queue.currentEntry` drives the clock and the end.
- `AudioPlayer`: `loadCurrentItem` routes `am:` entries to `loadAppleMusic`,
  which pauses and empties `AVPlayer` first so its stall, silent-pause and
  end-of-item watchers stand down. Transport (`resume`, `pause`, `seek`,
  repeat-one, `finish`) branches on `appleMusic.isActive`; timeline reports
  skip `am:` entries; the time-control observer ignores `AVPlayer` while
  MusicKit plays.
- Settings → Spikes → Apple Music (Debug only, `AppleMusicSpikeView`):
  authorization, `canPlayCatalogContent`, catalog search with Play Now / Play
  Next / Add to Queue, a raw MusicKit play that bypasses the queue, a prewarm,
  and two toggles (we write lock screen info; release our audio session first).
- Every handoff, status transition, remote command and now-playing snapshot is
  logged at `notice` under category `AppleMusic`. `info` lines are not kept on
  the device: they are gone by the time the log is collected.

## Findings

### Works

- **Handoff in both directions.** Plex → Apple Music is ~0.8s from the handoff
  to the clock running (0.6–0.9s of it is `prepareToPlay` + `play`; 0.17s when
  the song was already prepared). Apple Music → Plex sounds immediate. A small
  audible pause, no overlap.
- **End of an Apple Music song is detectable**, with care: MusicKit resets
  `playbackTime` to 0 and only then reports `.paused` (≈0.2s later). Judging
  the end on the furthest time seen while running (≥ duration − 3s) works;
  judging it on the clock at the pause never does.
- **Our now-playing info survives.** With us writing it, the lock screen kept
  our title, rate and artwork through MusicKit's playback; MusicKit didn't
  overwrite it (8 keys, ours, 1s and 4s after it started).
- **The lock screen reaches us until MusicKit plays.** A "next" pressed during
  a Plex track arrives at our handler, which hands off to MusicKit fine.

### Problems

**1. Our audio session and MusicKit's fight.** MusicKit plays out of process,
in `RemotePlayerService`, under a session of its own (`MediaPlayback`,
non-mixable). Ours is the same, so whichever activates last interrupts the
other. Our `resume()` activating the session before handing play to MusicKit
interrupted it (fixed: the MusicKit branch now comes first). Releasing our
session (`setActive(false, .notifyOthersOnDeactivation)`) before MusicKit
starts is on by default; untested whether it is needed. Our
`didBecomeInactiveNotification` fires on every handoff to MusicKit and must be
ignored while MusicKit plays, or the player marks itself paused.

**2. Screen capture mutes Apple Music, silently.** Every "playing, no audio"
run was `RemotePlayerService` logging
`screenRecordingChanged(isRecording:true)` → `muted player:true`, "Enforcing
policy due to screen recording". The cause was DeviceHub paired with the phone,
which counts as capture. Status and clock carry on as if playing; nothing in
MusicKit's API says it is muted. The Music app behaves the same, so this is
policy, not a bug, but in the product a silent song looks broken: check
`UIScreen`/scene capture state and say why. (Deleting and reinstalling the
Music app seemed to fix it once; it was coincidence.)

**3. While MusicKit plays, the lock screen talks to MusicKit, not to us.**
This is the open one. Once `RemotePlayerService` starts, mediaremoted routes
remote commands to it (`Sending command … NextTrack … to
com.apple.MediaPlayer.RemotePlayerService`), and our `MPRemoteCommandCenter`
handlers never see them. With a queue of one, MusicKit's "next" resets the song
to 0 and pauses; our engine sees "paused at 0, not near the end" and records it
as someone else pausing. Every later press goes to MusicKit too. Shuffle and
repeat from the lock screen will be lost the same way, and CarPlay presumably
with them (untested). Reproduced twice.

Candidate fixes, not yet tried:

- Infer the command from MusicKit's state: a reset to 0 mid-song with the
  entry unchanged reads as next; previous/seek likewise. Cheap, heuristic,
  and the poll already sees the transitions.
- Give MusicKit every consecutive Apple Music entry, so next moves inside its
  queue. Helps between Apple Music songs only, not into Plex.
- Look for a way to keep our app the command target (`SystemMusicPlayer` is
  worse: it is the Music app's queue). Unknown whether any exists.

**4. MusicKit's status walk at load.** It goes stopped → paused → playing while
it prepares; read naively that is "paused by someone else, resumed by someone
else", which flickered the play button. Fixed: transitions are ignored until
the first `.playing` after a load.

**5. Catalog search 401.** The first searches after enabling the MusicKit App
Service failed with `developerTokenInvalid`, then a parse error on the error
body ("invalid JSON"). Fine minutes later. Propagation, presumably.

## Setup it needed

- MusicKit enabled under App Services for `com.colbyr.ctunes` in the developer
  portal. It is not an entitlement, so `-allowProvisioningUpdates` doesn't set
  it.
- `NSAppleMusicUsageDescription` in `App/Info.plist`, `MusicAuthorization.request()`,
  and an Apple Music subscription for catalog playback
  (`MusicSubscription.current.canPlayCatalogContent`).
- A new phone needs `-allowProvisioningDeviceRegistration` beside
  `-allowProvisioningUpdates` for `xcodebuild` to register it (added to
  `make device` on the branch).
- Reading the phone's log: `sudo /usr/bin/log collect --device-udid <udid>
  --last 15m --output x.logarchive`, then `log show x.logarchive`. Plain
  `log show` on the Mac reads the Mac's log; zsh's builtin `log` shadows the
  binary in some shells. Useful predicates: our category `AppleMusic`;
  `process == "audiomxd"` with `INTERRUPTING` / `setIsPlayerMuted` / `is
  starting playback` for who holds the audio; `process == "mediaremoted"` with
  `Sending command` for where a lock screen press went;
  `process == "RemotePlayerService"` for MusicKit's own reasons.

## Verdict so far

Two engines in one queue is possible: playback, handoff and end detection all
work. Whether it is shippable turns on problem 3: lock screen and car controls
during an Apple Music song. Until that is solved or worked around, an Apple
Music song in the queue breaks the remote controls the app has worked hardest
on (`notes/carplay.md`).

Not yet tested: CarPlay, Siri or a call during an Apple Music song, the
release-session toggle off, our now-playing writes off.

## Beyond playback (not started)

- Ids: every `PlexTrack`/`ratingKey` consumer (vetoes, mix picks, recents,
  widget feed, Siri's `SiriID`) needs an identity that names its source.
- Library: `MusicLibraryRequest` for the user's library, `MusicCatalogSearchRequest`
  for the catalog, as a second `LibrarySource`-shaped reader.
- Gaps: no timestamped play history (On Rotation would keep its own log), no
  pins or files (only what the Music app downloaded plays offline), favorites
  through `/v1/me/ratings`.
- Mixing modes, cheapest first: mixed queues and mixes; Apple Music filling gaps
  on artist pages; one merged library with matching (Plex rarely has ISRCs).
