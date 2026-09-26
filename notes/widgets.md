# Home screen widgets

Written 2026-09-25, before any of it was built. Everything about WidgetKit
below is from Apple's docs and the Xcode widget template, not measured;
"Verify" lists what to check before trusting it.

## Where the app stands

There is one target, `ctunes`, in a hand-written `App/ctunes.xcodeproj`
with a single file-system synchronized group. The Siri work put five
`AudioPlaybackIntent`s in `App/ctunes/Siri/AppShortcuts.swift`, which run
in the app process with no window; `IntentPlayback.ready()` waits for
launch to settle and plays through the screens' paths. `AppRuntime` lives
outside any view and already re-registers the App Shortcuts when the
playlists change. The saved mixes (`SavedMix`, PlexKit) are `Codable`,
kept under the `shortcuts` key in `UserDefaults.standard` and iCloud, and
drawn as the play cards on the browse root, minus the ones every active
listener's vetoes empty.

None of that is visible to a widget. A widget is a separate process in a
separate bundle: it cannot read the app's `UserDefaults.standard`, its
Application Support folder, the artwork `URLCache` under `Caches/Artwork`
or the keychain token. It also runs under a ~30 MB memory limit and a
refresh budget of a few dozen timeline reloads a day, so it should never
discover a server or talk to Plex itself.

## What to build

**A Shortcuts widget**: the saved mix cards as buttons, in the small
(one card), medium (two or three) and large (the row) families. Each
button is a `PlayMixIntent(mixID:)`, an `AudioPlaybackIntent`, so a tap
starts playback in the app's process without opening it, the same way
"Shuffle favorites" through Siri does. Shuffle Favorites is a saved mix
under `SavedMix.starterID`, so it needs nothing of its own. The widget
works offline (`IntentPlayback` plays what is on disk in `.offline`) and
only changes when the mixes do, so it is nearly free of the refresh
budget.

**Not a Now Playing widget.** The lock screen already has one, and a home
screen widget goes stale the moment playback stops without a reload; a
Live Activity is the shape for that and the system's own Now Playing
covers it. An On Rotation widget (the top albums as art, tapping opens
the album) is a good second, once the feed and the URL scheme exist.

## What it needs

1. **An extension target.** `com.apple.product-type.app-extension`,
   `NSExtensionPointIdentifier = com.apple.widgetkit-extension` in its own
   `Info.plist`, bundle id `com.colbyr.ctunes.widgets`, a
   `PBXTargetDependency` from the app and an Embed App Extensions copy
   phase (`PBXCopyFilesBuildPhase`, `dstSubfolderSpec = 13`). A second
   `PBXFileSystemSynchronizedRootGroup` at `App/ctunesWidgets/` keeps the
   no-project-edits property for new files. The project-level Debug and
   Release configs carry the team, the deployment target, Swift 6 and
   `SWIFT_STRICT_CONCURRENCY = complete`, so the target's configs only add
   the product keys. The widget links PlexKit (no UIKit in it) for
   `SavedMix` and the DTOs.

2. **An App Group.** `com.apple.security.application-groups` with
   `group.com.colbyr.ctunes` in both entitlements files. Not a gated
   entitlement, but the App IDs for both bundles need it; automatic
   signing with `-allowProvisioningUpdates` should register the group and
   add it to both (see Verify). The app writes into
   `containerURL(forSecurityApplicationGroupIdentifier:)`; the widget
   reads it. Nothing in the app's own storage moves.

3. **A feed the app writes.** One JSON file in the group container,
   `widget.json`, holding what the widget draws: the visible mix cards in
   order (`[SavedMix]`, the same list the root shows after the listener
   vetoes, so a hidden card is hidden on the home screen too), and later
   the top of On Rotation. Beside it a `thumbs/` folder of small JPEGs
   (~200pt square) keyed the way `ImageLoader` keys tints, by thumb path,
   since the widget cannot load a URL in its view and must not be handed
   `?X-Plex-Token=` URLs anyway. The writer runs where the root already
   settles the cards (a view, which is fine: nothing here is needed for
   playback), then calls `WidgetCenter.shared.reloadTimelines(ofKind:)`.
   Reloads asked for while the app is in front are not counted against
   the budget.

4. **An intent both binaries compile.** A widget's `Button(intent:)`
   needs the intent type in the extension, but `PlayMixIntent.perform()`
   runs in the app and has to reach `IntentPlayback`, which drags in the
   whole app. So the intent goes in a third synchronized group,
   `App/Shared/`, listed by both targets, and reaches the app through a
   protocol in the same file, resolved with `@Dependency` (registered by
   `AppRuntime.init` through `AppDependencyManager.shared.add`). The
   widget process never performs it, so it never resolves the dependency.
   The five Siri intents stay where they are.

   `IntentPlayback` needs a `play(mix:)`. The fetch it wants,
   `tracks(of picks:)`, sits on `LibraryActions` in `ShortcutsView.swift`
   and needs the presentation objects a view owns, so the fetch part moves
   somewhere both can call (a `MixFetch` over the model, or a static on
   `LibraryActions` that takes the model alone); the veto and ordering
   rules are two lines and stay with each caller.

5. **A URL scheme**, for the widget's non-button surface and for the On
   Rotation widget. `CFBundleURLTypes` with scheme `ctunes` in
   `App/Info.plist`; `ctunes://mix/<uuid>` opens the builder on a mix,
   `ctunes://album/<ratingKey>` the album. `.onOpenURL` on the window's
   content hands the route to `LibraryNavigator.open`, or parks it on
   `AppRuntime` for `LibraryView` to take when it appears, since the URL
   can arrive before the stack exists. Small widgets take one
   `widgetURL`; medium and large can `Link` each card.

## Plan

Each step builds and runs on its own.

1. **Target.** The pbxproj objects, an empty `App/ctunesWidgets/` with a
   `Widgets.swift` (`@main WidgetBundle`), a `ShortcutsWidget` whose
   timeline is a placeholder, `Info.plist` and `ctunesWidgets.entitlements`.
   `make sim` builds both through the dependency. Add the widget to a
   simulator home screen by hand and see the placeholder.

2. **Group and feed.** The entitlement on both targets, `WidgetFeed` in
   `App/Shared/` (the `Codable` shape, the container URL, `write` in the
   app, `read` in the widget), the root writing it when its cards settle
   and the thumbs alongside. The widget draws the cards from the feed,
   with the tint from the feed too (`ArtworkTint` is a few bytes and
   already computed for every card's cover), so the widget's ground
   matches the app's.

3. **Play.** `PlayMixIntent` in `App/Shared/`, the dependency protocol,
   the registration in `AppRuntime`, `IntentPlayback.play(mix:)` over the
   moved fetch. Test with the app killed: a tap launches it in the
   background and audio starts, the lock screen shows the track, the
   widget's button does not spin forever (return promptly; the fetch is
   the intent's, not the widget's).

4. **Open.** The URL scheme, the route parsing, `widgetURL` on the small
   family and `Link` on the others.

5. **On Rotation widget.** The top six albums from `Rotation` into the
   feed with their thumbs, a grid of covers in medium and large, each a
   `Link` to the album. Optional; only once 1–4 are in.

6. **Control.** A `ControlWidget` in the same bundle, a
   `ControlWidgetButton` on `PlayMixIntent` for the starter mix, so
   "Shuffle Favorites" sits in Control Center and on the Action button.
   Cheap once 3 is done.

Debug hooks: `CTUNES_DEV_WIDGET_FEED=1` logs the feed written under
category `Widget`; nothing on the simulator can add the widget itself.

Rough size: a day for 1–2, a day for 3–4, an afternoon each for 5 and 6.

## Verify

- Whether `xcodebuild -allowProvisioningUpdates` registers a new App
  Group and attaches it to both App IDs on its own, or the group has to
  be created once in the developer portal. Automatic signing in Xcode
  does; the command line may not.
- That an `AudioPlaybackIntent` fired from a widget button launches the
  app in the background on iOS 27 when the app is not running, not only
  when it is suspended, and that `UIBackgroundModes: audio` is all it
  needs. The docs say so; the Siri path already relies on the same launch.
- That a synchronized group listed by two targets compiles its files into
  both under `objectVersion = 77`, and that `appintentsmetadataprocessor`
  is happy with the same intent type in the app and the extension (the
  Xcode template does exactly this with `AppIntent.swift`, so it should
  be).
- Whether Xcode 27 can still run the widget scheme on the simulator
  (`_XCWidgetKind`, `_XCWidgetFamily` in the environment) to show a
  family without adding it by hand, now that DeviceHub replaced
  Simulator.app. If not, the visual check is a long press on the home
  screen and `simctl io booted screenshot`.
- Whether the widget shows on the Mac under "Designed for iPad", and
  whether CarPlay on iOS 27 offers the app's widgets on its dashboard
  (iOS 26 added CarPlay widgets); if so, the small family should look
  right on a car's screen too, which means the same `PlayMixIntent`
  from the dashboard.
- The feed's size: `[SavedMix]` is tiny, but a dozen thumbs at 200pt are
  a few hundred KB the widget decodes in a 30 MB process. Fine on paper.
