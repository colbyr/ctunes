# CarPlay

Notes on what it would take to get ctunes onto a car screen.

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

ctunes currently has no entitlements file since nothing it does is protected.

## What CarPlay needs

1. **Entitlement: `com.apple.developer.carplay-audio`.** Requested at
   developer.apple.com/carplay for the app's bundle ID. Apple reviews it; it
   can take days to weeks. Without it the app never appears on the car screen,
   and even the Xcode CarPlay simulator honors the provisioning profile, so it
   is needed for local testing too. This is the long pole. Request it first.

2. **A CarPlay scene.** Add a `CPTemplateApplicationSceneSessionRoleApplication`
   entry to `UISceneConfigurations` in Info.plist pointing at a
   `CPTemplateApplicationSceneDelegate`. CarPlay is a second window scene. The
   SwiftUI `@main App` doesn't expose that role, so the delegate is UIKit code
   living alongside the SwiftUI app.

3. **Template UI, not views.** Audio apps get `CPListTemplate`,
   `CPTabBarTemplate`, `CPNowPlayingTemplate` and little else. Lists are fed
   with `CPListItem`s backed by the library. Now Playing is drawn by the system
   from `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, which the app
   already populates for the lock screen, so that carries over for free.

4. **Background playback.** Audio background mode plus the `AVAudioSession`
   playback category. Already in place.

## Sketch for ctunes

- A `CPTemplateApplicationSceneDelegate` that builds Artists / Albums /
  Favorites list templates from `PlexLibrary` and hands taps to `AudioPlayer`.
- Info.plist scene entry, entitlements file, `CODE_SIGN_ENTITLEMENTS` in the
  project build settings.
- Artwork goes through `CPListItem.image`, so thumbnails have to be fetched to
  `UIImage` ourselves, sized to `CPListItem.maximumImageSize`.
- Test in Xcode's CarPlay simulator (I/O → External Displays → CarPlay) once
  the entitlement is in the profile. `make sim-run` won't drive it.
