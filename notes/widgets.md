# Home screen widgets

Planned 2026-09-25 and built the same day, steps 1–4 of the plan below.
Everything measured is marked so; "Verify" keeps what still isn't.

## Where the app stood

One target, `ctunes`, in a hand-written `App/ctunes.xcodeproj` with a
single file-system synchronized group. The Siri work had put five
`AudioPlaybackIntent`s in `App/ctunes/Siri/AppShortcuts.swift`, which run
in the app process with no window; `IntentPlayback.ready()` waits for
launch to settle and plays through the screens' paths. The saved mixes
(`SavedMix`, PlexKit) are `Codable`, kept under the `shortcuts` key in
`UserDefaults.standard` and iCloud, and drawn as the play cards on the
browse root, minus the ones every active listener's vetoes empty.

None of that is visible to a widget. A widget is a separate process in a
separate bundle: it cannot read the app's `UserDefaults.standard`, its
Application Support folder, the artwork `URLCache` under `Caches/Artwork`
or the keychain token. It runs under a ~30 MB memory limit and a refresh
budget of a few dozen timeline reloads a day, so it never discovers a
server or talks to Plex itself.

## What was built

**Two widgets in one bundle** (`App/ctunesWidgets/`, target
`ctunesWidgets`, bundle id `com.colbyr.ctunes.widgets`):

- **Shortcut** (`ShortcutWidget`): one card as a button, in the small
  family and as a lock-screen circle. Which card is the widget's own
  setting (`SelectMixIntent`, a `WidgetConfigurationIntent` over
  `MixEntity`); unset, the first card on the Music screen. The whole
  small widget is the play button; there is no open surface.
- **Shortcuts** (`ShortcutsWidget`): the cards as rows, two in medium and
  five in large, each row's body the play button and its chevron a
  `Link` to `ctunes://mix/<id>`.

Each button is `PlayMixIntent(mix:)`, an `AudioPlaybackIntent`, so a tap
starts playback in the app's process without opening it, the same launch
"Shuffle favorites" through Siri relies on. The widget works offline
(`IntentPlayback` plays what is on disk in `.offline`) and its timelines
never expire (`.never`); the app reloads them when the cards change.

**Not a Now Playing widget.** The lock screen already has one, and a home
screen widget goes stale the moment playback stops without a reload; a
Live Activity is the shape for that and the system's own Now Playing
covers it. An On Rotation widget is the natural next one; the URL scheme
for it is in.

## How it hangs together

1. **The extension target.** `com.apple.product-type.app-extension`,
   `NSExtensionPointIdentifier = com.apple.widgetkit-extension` in
   `App/ctunesWidgets-Info.plist`, a `PBXTargetDependency` from the app
   and an Embed Foundation Extensions copy phase (`dstSubfolderSpec = 13`).
   Two more `PBXFileSystemSynchronizedRootGroup`s, `App/ctunesWidgets/`
   (the widget's) and `App/Shared/` (listed by **both** targets), keep the
   no-project-edits property. The project-level configs carry the team,
   the deployment target, Swift 6 and strict concurrency; the widget's
   configs add the product keys and `SWIFT_ACTIVE_COMPILATION_CONDITIONS =
   WIDGET`. The widget links nothing but the system frameworks: it does
   not need PlexKit, since the feed is self-describing. **The widget's
   Info.plist lives outside its synchronized folder**: inside it, the
   folder copies it as a resource and the build fails with "Multiple
   commands produce Info.plist". Measured. So does the app's, for the
   same reason.

2. **The App Group.** `com.apple.security.application-groups` with
   `group.com.colbyr.ctunes` in both entitlements files. **`xcodebuild
   -allowProvisioningUpdates` registered the group, created the widget's
   App ID and issued both team profiles with the group on its own**
   (measured on a `generic/platform=iOS` build); nothing was touched in
   the developer portal. The simulator honours the group too, under
   `Containers/Shared/AppGroup/<id>/`.

3. **The feed** (`App/Shared/WidgetFeed.swift`). One JSON file in the
   group container, `widget.json`: the visible cards in order, each with
   its title, the line under it, what its art is (`favorites`, `artist`,
   `album`, `playlist`, `mix`), the file name of its cover under `thumbs/`,
   its `ArtworkTint` and the style glyph and accent. The `thumbs/` folder
   holds a 200pt JPEG at 2x per cover, named the way the offline store and
   the tint cache key a thumb (`library-metadata-1029-thumb-<stamp>.jpg`),
   rendered by `WidgetFeedWriter` from the image `ImageLoader` already
   has; a cover the app hasn't loaded yet is fetched through the loader.
   A dozen covers is ~300 KB. **The writer runs from the browse root**
   (`MusicView`, a `.task` keyed on the visible cards and their subtitles,
   debounced a second), which is the one place the listener vetoes and
   the playlist counts are already settled. It skips a write when nothing
   changed, prunes thumbs no card names, then
   `WidgetCenter.shared.reloadAllTimelines()`. The blind spot: an iCloud
   change landing while the app is in the background isn't written until
   the root next renders, so the widget shows the old list until then.
   `ArtworkTint` (the struct alone) moved to `App/Shared/` so the widget's
   wash is the app's; the dominant-color pass and the ground modifier
   stayed in `App/ctunes/ArtworkGround.swift`.

4. **The intent** (`App/Shared/PlayMixIntent.swift`). `Button(intent:)`
   needs the type in the extension, but `perform()` reaches
   `IntentPlayback`, which is the whole app. So the file is compiled into
   both and the body is `#if !WIDGET`; the extension's copy returns a
   dialog it never speaks. Simpler than the `@Dependency` protocol the
   plan had. `MixEntity` is the shortcut as Siri and the Shortcuts app see
   it, ids the saved mixes' own; `MixQuery` answers from the model in the
   app (so a mix saved a moment ago resolves before the feed is rewritten)
   and from the feed in the widget. Both binaries' `Metadata.appintents`
   list `PlayMixIntent`, `SelectMixIntent` and `MixEntity`; the app's also
   has the five Siri intents, which stayed where they were. As a side
   effect "Play Shortcut" is an action in the Shortcuts app.

   `IntentPlayback.play(mixID:)` is the card's own path: the fetch moved
   from `LibraryActions` onto the model (`App/ctunes/LibraryFetches.swift`:
   `tracks(of:known:)`, `tracks(ofArtist:)`, `items(of:known:)`,
   `tracks(of pick:)`, `tracks(of picks:)`), since the actions need the
   presentation objects a view owns; the veto and ordering lines stay with
   each caller.

5. **The URL scheme.** `CFBundleURLTypes` with scheme `ctunes` in
   `App/Info.plist`. `DeepLinks` (`App/ctunes/DeepLinks.swift`, held by
   `AppRuntime`) parses `ctunes://mix/<uuid>` (the card's chevron: the
   thing itself for one pick, the builder otherwise), `ctunes://favorites`,
   and `ctunes://album|artist|playlist/<ratingKey>` when the catalog knows
   them, and parks the `LibraryRoute`; `ContentView`'s `.onOpenURL` feeds
   it and `LibraryView` takes it on appear or when it lands, since a cold
   launch from a widget arrives on the connecting screen. **`simctl
   openurl` from the terminal stops at the system's "Open in Tunes for
   Plex?" prompt** (it is another app's link; a widget's own `Link` doesn't
   prompt), which is what `CTUNES_DEV_URL` is for.

## Measured

- The feed, written on the simulator with three seeded shortcuts: the
  favorites card, an album card with its thumb and tint, and a two-pick
  mix card, each with the root's subtitle.
- `PlayMixIntent` through `CTUNES_DEV_INTENT=mix:soulmate`: played the
  album from its first track with the rest queued.
- `CTUNES_DEV_URL=ctunes://mix/<id>`: an album mix opened the album page,
  a two-pick mix opened the builder on it.
- Both simulator binaries embed the group entitlement; the device build
  signs both with team profiles carrying it.

## Verify

- The widgets themselves on a home screen: add each family by hand on
  the phone, tap a card with the app killed and with the phone locked (the
  car's case), watch the button's spinner clear once `ready()` returns
  (up to 12s on a cold launch while the server is found) and the lock
  screen show the track. Nothing on the simulator can add a widget from
  the terminal; DeviceHub replaced Simulator.app, so the widget scheme's
  `_XCWidgetKind`/`_XCWidgetFamily` run is the remaining way to see one
  without a phone.
- Whether the widget shows on the Mac under "Designed for iPad", and
  whether `containerURL` for a `group.` identifier resolves there (macOS
  app groups usually want the team-id prefix). If not, the feed is nil
  and the widgets show the placeholder.
- Whether CarPlay on iOS 27 offers the app's small widget on its
  dashboard, and how the card reads at that size.
- The thumbs' size in the widget process: 400px JPEGs decoded in a
  30 MB process, five at most on one large widget.

## Next

- **On Rotation widget.** The top six albums from `Rotation` into the
  feed with their thumbs, a grid of covers in medium and large, each a
  `Link` to `ctunes://album/<ratingKey>`; the route resolves from the
  catalog, which the root fills.
- **Control.** A `ControlWidget` in the same bundle, a
  `ControlWidgetButton` on `PlayMixIntent` for the starter mix, so
  "Shuffle Favorites" sits in Control Center and on the Action button.

Debug hooks: `CTUNES_DEV_WIDGET_FEED=1` logs the feed written under
category `Widget`; `CTUNES_DEV_INTENT=mix:<title or id>` plays a shortcut
through the widgets' intent; `CTUNES_DEV_URL=ctunes://…` opens a route
the way a widget's link would.
