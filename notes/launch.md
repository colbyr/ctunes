# ctunes launch plan

## Context

ctunes is a working, hardware-verified Plex music client (M0–M7 done). It has never
been packaged for anyone but the developer. The goal is a paid, public App Store
release of a deliberately simple, album-focused client: no playlists by design,
CarPlay in v1, iOS 26 floor, TestFlight first.

Current state that matters (from the inventory):

- No app icon image, blank launch screen, empty accent color.
- No `PrivacyInfo.xcprivacy`, no entitlements file, no privacy policy / support URL.
- No logging, crash reporting, archive/upload path, or CI.
- App target has zero tests; the one behaviour PLAN.md admits was never watched
  end to end is the queue rolling over when a track finishes on its own.
- Zero third-party deps; PlexKit has 74 tests.
- `notes/carplay.md` already has the CarPlay design; nothing is built.
- Working tree is dirty (ListenerChips + spread-shuffle note uncommitted).

## Decisions

| Question | Decision |
|---|---|
| Scope | Lean 1.0 + CarPlay. Playlists stay out on purpose. Offline, iPad, widgets later. |
| iOS floor | 26.0 |
| Rollout | Public TestFlight link for a few weeks, then App Store |
| Pricing | **Paid up front, one-time, $9.99** (see below) |

### Pricing recommendation

Go paid-up-front rather than yearly subscription:

- Guideline 3.1.2 says subscriptions must deliver ongoing value. ctunes has no
  server, no sync, no content; review rejections of subs on pure local utilities
  are common enough that it's a real risk on a first submission.
- The competition sets the frame: Plexamp is free, Prism is a ~$5 one-time buy
  with CarPlay + offline. A yearly sub for a simpler app is a hard sell.
- Paid-up-front needs **zero StoreKit code**: no paywall, no restore-purchases
  flow, no receipt validation, no trial mechanics. TestFlight *is* the free trial.
- If it later earns a sub (e.g. offline downloads as a "Pro" tier), converting
  to free + IAP is supported: `AppTransaction.originalPurchaseDate` grandfathers
  existing buyers.

Why $9.99 and not $4.99: expected volume is small, CarPlay is a paid-tier
feature everywhere else, and it's easier to cut price than raise it. Can be
revisited at TestFlight exit.

## Phases

### Phase 0 — Today (unblocks the long pole)

1. **Request the CarPlay audio entitlement** at developer.apple.com/carplay for
   `com.colbyr.ctunes`. Days to weeks; everything in Phase 2 waits on it. The
   form wants a description of the app and a screenshot or two, so the
   MusicView/NowPlaying screens are enough.
2. Create the App Store Connect record (name check: "ctunes" availability;
   fallback names decided now, not at submission).
3. Accept the Paid Applications agreement in ASC, set up banking/tax. This
   takes days to clear and blocks any paid release, including TestFlight of
   a paid-tier build.
4. Commit or stash the dirty working tree.

### Phase 1 — Store hygiene (can start immediately, parallel with Phase 0)

Files: `App/ctunes/Assets.xcassets/`, `App/Info.plist`, `App/ctunes.xcodeproj/project.pbxproj`, new `App/ctunes/PrivacyInfo.xcprivacy`, new `App/ctunes/ctunes.entitlements`.

- App icon: 1024×1024 into the existing appiconset (plus dark/tinted variants
  for iOS 18+ icon styles). AccentColor gets a real value.
- Launch screen: at minimum a background color + icon via `UILaunchScreen`.
- `PrivacyInfo.xcprivacy`: declare UserDefaults (`CA92.1`) and, if URLCache
  triggers it, file-timestamp reasons. Data collection: none. Tracking: none.
- Entitlements file + `CODE_SIGN_ENTITLEMENTS` (empty now, CarPlay added in Phase 2).
- Add `CFBundleURLTypes` for the `ctunes` scheme used by the auth callback.
- Bump `MARKETING_VERSION` scheme: 1.0 / build auto-incremented by the
  archive target below.
- Sanitize `PlexError.http` so raw server body text never reaches the UI.
- Surface `toggleFavorite` failures (currently set on `errorMessage` but
  never shown on browse screens).
- First-run Local Network priming: explain why the prompt appears before it
  fires, and link to Settings when `noServerReachable` is hit (this is the #1
  support ticket for every third-party Plex client).
- Remote-streaming note: since 2025 Plex gates remote streaming behind Plex
  Pass / Remote Watch Pass. Make the error for a 4xx from a remote
  connection say so, so it isn't blamed on ctunes.

### Phase 2 — CarPlay (after entitlement lands)

Follow `notes/carplay.md`:

- `CPTemplateApplicationSceneDelegate` (UIKit file alongside the SwiftUI app),
  scene entry in `UISceneConfigurations`, `com.apple.developer.carplay-audio`
  in the entitlements file.
- Tabs: Albums (grouped by artist, mirrors MusicView), Favorites, Mixes
  (Artist Mix / Album Mix as one-tap "play a mix" items, no builder UI).
- Now Playing is free via the existing `MPNowPlayingInfoCenter` /
  `MPRemoteCommandCenter` wiring in `AudioPlayer`; shuffle/repeat commands
  are already registered.
- Artwork through `ImageLoader` resized to `CPListItem.maximumImageSize`.
- Test in the Xcode CarPlay simulator, then in a real car. Cold-launch from
  the car with the phone locked is the case that breaks (library not loaded
  yet): the delegate must wait on `AppModel` reaching `signedIn`.

### Phase 3 — Hardening and observability

- `Logger` (os.log) with a `ctunes` subsystem in `AppModel`, `AudioPlayer`,
  `PlexClient`. Nothing exists today; a TestFlight bug report with no logs is
  useless. Keep it private-by-default; no tokens.
- Crash reporting: Xcode Organizer / TestFlight crash logs are enough for v1.
  No third-party SDK, keeps the privacy manifest at "none".
- Verify the queue auto-rollover end to end on hardware (`CTUNES_DEV_AUTOPLAY=last`
  exists for exactly this). Add a `PlayQueue`-level test for the
  `finishIfRunPastEnd` path if it's expressible without AVPlayer.
- Direct-play failure: an unsupported codec on someone else's library today
  fails silently. At minimum surface the error and skip to the next track;
  transcode fallback is a v1.1 item.
- Sign out must clear keychain token, section choice, art caches. (The
  track cache is already cleared, from `ContentView.onChange(of: model.state)`.)
- Add a **test target to the xcodeproj** so `make test` covers the app too;
  even a handful of `AppModel` state-machine tests is worth it.

### Phase 4 — Release pipeline

- `Makefile`: `archive`, `export`, `upload` targets using `xcodebuild -archive`
  / `-exportArchive` with an `ExportOptions.plist`, and `xcrun altool` or
  `notarytool`-style upload via App Store Connect API key (stored in
  1Password, read via `op` like the dev token).
- Build number = git commit count or `agvtool` bump in the target.
- Optional: GitHub Actions running `make test` on push. Archive stays local;
  Xcode Cloud is more setup than it's worth for one person.

### Phase 5 — TestFlight (2–4 weeks)

- External testing needs a beta review (lighter than App Review, 1–2 days).
- Public link, cap ~100 testers, post in r/PleX and Plex forums with the
  "album-focused, not Plexamp" pitch.
- Beta feedback in TestFlight captures screenshots + logs automatically.
- Exit criteria: no crash in the last build for 7 days, CarPlay confirmed on
  ≥2 head units by testers, sign-in works on ≥1 server not yours.

### Phase 6 — App Store submission

Required artifacts (none exist today):

- Privacy policy URL and support URL (colbyr.com/ctunes/privacy, /ctunes/support
  or a GitHub Pages page; email link is enough for support).
- App Store screenshots: 6.9" and 6.5" iPhone sets; CarPlay screenshots
  optional but sell the feature.
- Description, subtitle, keywords ("plex", "music", "carplay", "album").
  "Plex" in the app name is a trademark risk; keep it in keywords/description
  only.
- App Privacy questionnaire: no data collected. Local network usage explained.
- Review notes: a demo Plex account/server. Reviewers will not have Plex.
  Options: a throwaway plex.tv account pointed at a small public-domain
  library on a cheap VPS, or a Plex server you leave running for review week.
  This is mandatory; "sign in with your own Plex" gets rejected under 2.1.
- Age rating, category Music, price tier $9.99.

## Sequencing / critical path

```
Day 0    CarPlay entitlement request, ASC record, Paid Apps agreement
Wk 1-2   Phase 1 hygiene + Phase 3 logging/hardening + Phase 4 pipeline
Wk 2-4   CarPlay build (blocked on entitlement; if it slips, TestFlight without it)
Wk 3-4   Internal TestFlight → external beta review → public link
Wk 4-8   Beta period; legal pages, screenshots, review server set up
Wk 8+    Submit; expect one rejection round, usually the demo account
```

If the CarPlay entitlement hasn't arrived by the time TestFlight is ready, ship
TestFlight without it and add it in a later beta build. Don't hold the beta.

## Explicitly deferred (v1.1+)

Background downloads for pinned albums (pins themselves shipped in
`notes/offline.md`; gating them behind a Pro IAP is still open), iPad,
widgets/Live Activity,
transcode fallback, queue reordering, spread shuffle (`notes/spread-shuffle.md`),
artist pages, Siri/App Intents.

## Verification

- `make test` green; new app-target tests run from Xcode.
- `make run` on device: sign in fresh, browse, play, lock screen, kill app,
  relaunch restores state.
- `CTUNES_DEV_AUTOPLAY=last` confirms queue rollover.
- CarPlay simulator: cold launch with app not running, browse, play, Now Playing
  controls; then a real head unit.
- Archive → validate in Xcode Organizer passes (catches missing icon, privacy
  manifest, entitlement mismatches before upload).
- TestFlight build installs on a phone that has never had the dev build.
