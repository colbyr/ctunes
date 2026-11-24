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
starts was the first answer; it is what made 3a, and holding the session
mixable replaces it (the release toggle only applies with that one off). Our
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
Once `RemotePlayerService` starts, mediaremoted routes remote commands to it
(`Sending command … NextTrack … to com.apple.MediaPlayer.RemotePlayerService`),
and our `MPRemoteCommandCenter` handlers never see them. Apple documents this
for the application player: the framework handles the commands itself. With a
queue of one, MusicKit's "next" reset the song to 0 and paused.

Worked around by padding MusicKit's queue (2026-11-21, toggle "Pad MusicKit's
queue", on by default): the song is loaded three times and played from the
middle copy, so a remote next or previous moves `queue.currentEntry`, which the
poll reads within 30–100ms of mediaremoted sending the command.

- A move onto the copy after the song before its last 3s is a next; within the
  last 3s it is the song ending (173.1s of 173.3s both times), which replaces
  the "clock reset, then paused" end detection. A move onto the copy before it
  is a previous pressed early; later in the song MusicKit restarts it itself
  and only the clock going back is logged. Previous is untested on the device.
- `Queue(entries, startingAt:)` is not honoured for three entries of one song:
  the first was current. The engine steps on with `skipToNextEntry()`, and
  **the queue's current entry lags that call returning** (~20ms): read at
  once it still named the first entry, and the poll took our own step for a
  remote next and skipped the song.
- Repeat-one reloads the entry, since MusicKit has moved onto the padding.
- **`skipToNextEntry()` can return without moving.** Asked right after the
  queue replaced one still playing (an Apple Music entry straight after
  another), it left the song on the first copy with nothing before it, and
  every remote previous restarted the song. From a Plex track it took within
  20ms every time. The engine pauses the old queue and waits for it before
  the swap, then checks the position and asks again (five times, 400ms
  apart). Why MusicKit drops it is unknown.
- Nothing is read from MusicKit until the load has settled (`settled`): the
  entry is briefly nil while the queue is swapped, which read as the song
  ending and skipped it, and the status and clock are the last queue's.
- **The end is taken 0.15s early** (`preemptEnd`, a timer set in the last
  1.5s): left to roll into the padding, the opening of the copy was heard
  before the pause landed. A song longer than its catalog duration loses the
  difference; a shorter one still ends through the entry moving.
- The engine also looks on `queue.objectWillChange` and
  `state.objectWillChange` (a hop later, and again after 40ms, since the
  publisher fires before the value lands), so the padding copy is paused as
  the move lands rather than up to a poll (250ms) later. Not yet measured.
- MusicKit's own shuffle would reorder the padding and its repeat would loop
  it, so both are set off at every load, and one leaving off is read as one
  press: passed to `toggleShuffle` / `cycleRepeat` and put back. Untested, and
  the car's buttons will then show MusicKit's state (off), not ours. CarPlay
  is untested altogether.

**3a. In the background, AVPlayer can't take the audio back from MusicKit.**
Found once the padding made a locked-phone handoff possible; a song playing
out into a Plex track with the phone locked hits it too. audiomxd refuses our
session: `CMSUtility_IsAllowedToStopOthers: Client ctunes can't stop others
because it is in the background and not the NowPlaying app`, then `Operation
denied. Cannot interrupt others` (-12985). The now-playing app is
`RemotePlayerService`, a different pid. The Plex item loads and never plays,
nothing throws, and every later press goes to a stopped MusicKit.

- Waiting for MusicKit to stop doesn't help: refused 200ms after its status
  left `.playing`. Its session stays active on a deactivate timer.
- What works (toggle "Hold our session mixable", on by default): rather than
  releasing our session when MusicKit starts, keep it active with
  `.mixWithOthers`. A mixable session interrupts nobody, so AVPlayer starts
  under it at the handoff. **Then, and only once AVPlayer is playing**, set
  the category back to exclusive: asked 16ms after the player had started,
  the same request interrupted MusicKit and made us the now-playing app
  again; asked 35ms after the handoff with the stream still loading, it was
  refused, without throwing, and the track never played.
  `reclaimExclusiveSession` waits for `timeControlStatus == .playing` plus
  300ms, checks the player is still playing 700ms later, and falls back to
  mixable and retries otherwise.
- That iOS allows the takeover from a client already playing is inferred from
  those runs, not documented. Untested: a slow stream (the lock screen stays
  MusicKit's until the player starts), a handoff while paused.

**4. MusicKit's status walk at load.** It goes stopped → paused → playing while
it prepares; read naively that is "paused by someone else, resumed by someone
else", which flickered the play button. Fixed: transitions are ignored until
the first `.playing` after a load.

**5. Catalog search 401.** The first searches after enabling the MusicKit App
Service failed with `developerTokenInvalid`, then a parse error on the error
body ("invalid JSON"). Fine minutes later. Propagation, presumably.

**6. The car shows an Apple Music song as paused** (2026-11-22, in a car).
Audio, transitions and every control worked. But the system keeps two players
for the app, ours (`com.colbyr.ctunes … default`) and the one MusicKit runs
for us (`RemotePlayerService/com.colbyr.ctunes`), and **CarPlay's Now Playing
reads ours**: its commands came to our handlers through an Apple Music song
(both seeks did), unlike the lock screen's. Ours has no stated playback state,
so mediaremoted infers one from our own audio (`setting inferred playback
state from <Playing> to <Paused>` at every handoff to MusicKit). The car drew
the play glyph and a still scrubber at rate 1; a seek moved it to the new
position and it sat there.

- `MPNowPlayingInfoCenter.playbackState = .playing` changes nothing on iOS:
  no line from mediaremoted, the inferred state stood.
- A loop of silence in our process under the mixable session doesn't count as
  playing either. Only our own non-mixable session playing does, and that is
  what cuts MusicKit off. Both were removed.
- Untested: the "We write lock screen info" toggle off, which now clears our
  info for the song so only MusicKit's player has any. The car may then show
  MusicKit's player (playing, clock moving), with its title and artwork, its
  shuffle and repeat state, and next and previous going to it (the padded
  queue). The fallback is writing the elapsed time once a second so the
  scrubber moves under a wrong glyph.
- The same gap is the play/pause flicker on the lock screen at a handoff: ours
  goes paused 0.1 to 1s before MusicKit's goes playing.
- Also fixed: a status MusicKit already held when the load settled was never
  reported as running, which would leave our rate at 0 for the song. Not seen
  on the drive.

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
work, and with the padded queue and the mixable session the lock screen's next
works through an Apple Music song, in both directions, with the phone locked.
Both rest on behaviour measured here rather than documented (a remote next
moving the queue, iOS letting a playing client take the audio back), so each
needs watching across iOS releases.

In the car everything works but the display (problem 6). Lock screen previous
works. Not yet tested: our now-playing writes off (the car's display rides on
it), Siri or a call during an Apple Music song, AirPods and headset buttons.

## Still to test in the car

All during an Apple Music song unless said otherwise. Collect a log after
(`--start` around the drive works hours later). DeviceHub's CarPlay screen
will do for anything about the display, since a muted song still reports
playing.

With "We write lock screen info" **off** (the open question from problem 6):

- **Does Now Playing show the song playing, the scrubber moving?** If it
  still reads paused, the fallback is the elapsed time written once a second.
- Whose title, artist, album and artwork show, in the car and on the lock
  screen, and whether they blink or show the last Plex track's at a handoff
  in either direction.
- Where next and previous go. With our info up they came to our handlers;
  with it cleared they may go to MusicKit, and the padded queue has never
  caught a press from the car. Into and out of a Plex track, and between two
  Apple Music songs.
- Scrubbing from the car: whether the seek lands, and the end is still taken
  cleanly after one near the end.
- Play/pause from the screen and from the car's own button or steering
  wheel: one press each way, and the glyph agreeing with the audio.
- Shuffle and repeat: whether a press arrives (`mirrored` in the log) and
  what the buttons show, since MusicKit's own state is always off.

With the toggle either way:

- Starting playback from the car with the phone locked and the app not
  running, on an Apple Music entry and on a Plex one. A queue restored from
  the last launch can't play its Apple Music entries (the songs are only in
  memory); what the queue does next is untested.
- A song playing out into a Plex track, and a Plex track into a song, with
  the phone locked the whole time (3a held on the desk, never in the car).
- A weak signal at the handoff back to Plex: the player has to be playing
  before the session is taken back, and until then presses go to a stopped
  MusicKit.
- The car's voice assistant, Siri or a call taking the audio during a song,
  and whether the song resumes after.
- Unplugging or the car switching off during a song: music must not carry on
  from the phone's speaker.
- The play/pause flicker at each handoff, and whether the car shows it.

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
