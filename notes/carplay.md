# CarPlay

The entitlement was granted on 2026-09-11 and the scene landed the same day.
The first half of this note is the background; "What was built" and
"Testing" are the parts that matter now.

## What an entitlement is

An entitlement is a key-value flag baked into the app's code signature that
tells iOS the app may use a protected capability. It is granted at build time,
not at runtime.

- Declared in a `.entitlements` plist, referenced from the project via
  `CODE_SIGN_ENTITLEMENTS`.
- The provisioning profile lists which entitlements the App ID is allowed to
  carry. If the file claims one the profile doesn't allow, signing fails or the
  app won't install.
- iOS checks the signed entitlement when the app uses the capability, so it
  can't be faked after the fact.

Most entitlements are self-service: toggle a capability in Xcode's Signing &
Capabilities tab and Apple adds it to the App ID. A few are gated and need
Apple's approval first. CarPlay is one of them.

## What CarPlay needs

1. **Entitlement: `com.apple.developer.carplay-audio`.** Requested at
   developer.apple.com/carplay for the app's bundle ID. Apple reviews it; it
   took about two weeks. Now in `App/ctunes.entitlements`.

2. **A CarPlay scene.** A `CPTemplateApplicationSceneSessionRoleApplication`
   entry under `UISceneConfigurations` in `App/Info.plist`, pointing at
   `CarPlaySceneDelegate`. CarPlay is a second window scene, so
   `UIApplicationSupportsMultipleScenes` had to go to `true`; that also lets
   an iPad or the Mac open more than one window of the app, which is why the
   model and player moved out of `ContentView` (below). The SwiftUI `App`
   has no slot for the CarPlay role, so the delegate is UIKit code beside it.

3. **Template UI, not views.** Audio apps get `CPListTemplate`,
   `CPTabBarTemplate`, `CPNowPlayingTemplate`, `CPAlertTemplate` and little
   else. Now Playing is drawn by the system from `MPNowPlayingInfoCenter`
   and `MPRemoteCommandCenter`, which the app already fills for the lock
   screen, so transport, scrubbing, shuffle and repeat carried over for free.

4. **Background playback.** Already in place.

## What was built

- **`AppRuntime`** (`App/ctunes/AppRuntime.swift`): the one `AppModel` and
  `AudioPlayer`, shared by every scene. A car can launch the app with the
  phone locked and no window at all, so bootstrap, the player's
  `connectionLost` hook, the `adopt` on a library swap and the stop on
  sign-out live here rather than on `ContentView`, which now just reads
  `AppRuntime.shared`. They follow the model through `Observations`.
- **`CarPlaySceneDelegate`** (`App/ctunes/CarPlay/`): builds a
  `CarPlayController` on connect and tears it down on disconnect.
- **`CarPlayController`**: a `CPTabBarTemplate` with four lists, On
  Rotation, Artists, Recently Added and Favorites, from the same fetches the
  browse root and Favorites make (`albums`, `artists`, `favoriteTracks`,
  `playHistory` scored by `Rotation`), minus the active listeners' vetoes.
  An album drills to Play, Shuffle and its tracks; an artist to Mix Albums,
  Shuffle and their albums by release date; Favorites has Shuffle Favorites
  and Play over the tracks, newest heart first. Every shuffle is the spread
  shuffle. A tap on a track plays its list from that row and pushes Now
  Playing, whose Up Next button lists the queue (a tap jumps there) and
  whose artist button opens the artist. Offline only tracks with a file
  enter the queue and nothing to play is an alert, as in the item menus.
  The playing row shows the indicator on every list in the stack.
- The root follows `AppModel.state`: a message list while connecting,
  signed out, or with no library picked; "Try again" on `connectFailed`.
  The tab bar survives a library swap (Wi-Fi to cellular mid-drive), whose
  lists just refill; a veto flip re-renders from the cached fetch.
- Artwork goes through `ImageLoader` at the grid's 400px URL and is drawn
  into `CPListItem.maximumImageSize` at the car's display scale off the
  main actor.

Out of scope for now: mixes, search, section switching, the Downloaded-only
filter, and Siri intents.

## Testing

`make sim` compiles the scene and `otool -s __TEXT __entitlements` on the
simulator binary shows the entitlement embedded. Beyond that the terminal
can't reach the car screen:

- Xcode 27 has no `Simulator.app`; `DeviceHub.app` replaces it and the
  CarPlay simulator is a DeviceKit plugin inside it. `simctl io booted
  enumerate` lists a CarPlay-type screen (ID 3, 720x480) that
  `screenConfig --display=3 power on` powers, but it renders black with
  nothing driving a session. Open the CarPlay display from DeviceHub's UI.
- The real test is the phone in a car, or the CarPlay simulator over USB.
  The first device build after the grant needs `-allowProvisioningUpdates`
  (`make device` passes it) so the profile picks up the capability; if
  signing complains, enable CarPlay Audio on the App ID at
  developer.apple.com first.
- Check the CarPlay log with
  `log show --info --predicate 'process == "ctunes" AND (category == "AudioPlayer" OR eventMessage CONTAINS "CarPlay")'`.
