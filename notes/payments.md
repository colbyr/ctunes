# Payments: 7-day free trial, then a subscription

## Context

`notes/launch.md` recommended paid-up-front at $9.99 with no StoreKit code.
This supersedes that: the app is free to download, a 7-day free trial starts
when the user taps through the paywall, and after that it is an auto-renewing
subscription. Nothing in the app is paid today: no StoreKit import, no
`.storekit` file, one native target (no app test target), `com.colbyr.ctunes`
under team `R9CAGXUD49`, iOS 26 floor, Swift 6 strict concurrency.

A one-time unlock after the trial was considered and dropped: StoreKit has
no trial mechanism on a non-consumable, so the 7 days would need a
home-grown clock (appendix), about a day more work and the fragile kind.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Trial mechanism | Apple introductory offer (7 days free) on the subscription, not a home-grown clock | Zero custom trial logic. The clock is per Apple ID, survives reinstall, Apple emails the "trial ends in 3 days" reminder, and cancellation is in Settings where users expect it. The alternative is in the appendix. |
| Product | One auto-renewable subscription, $9.99/year, in one subscription group | One product keeps the paywall to a single button. Monthly can be added to the same group later without touching the entitlement code. Low enough to sit next to Plexamp (free) and Prism ($5 one-time) without a fight. |
| Where the gate sits | A full-screen paywall over `LibraryView` whenever the device has no live entitlement; shown after Plex sign-in and server connect succeed | One gate in one place. Gating playback instead means auditing the nine `player.play(` call sites in `Views/` and every future one (CarPlay). Gating after connect means nobody starts a trial before seeing that the app reaches their server. |
| Entitlement source of truth | `Transaction.currentEntitlements`, re-read on launch, on every `Transaction.updates` event, on scene activation, and when the current expiry date passes | StoreKit 2 serves this from its on-device cache, so it answers offline, which matters because `.offline` renders the same `LibraryView`. No receipt parsing, no server. |
| Grace period | Enabled in App Store Connect; a transaction in grace period is in `currentEntitlements`, so nothing extra to code | A card that expires should not lock a paying user out mid-drive. |
| Paywall UI | `SubscriptionStoreView(groupID:)` with the restore button and policy links, themed as far as its modifiers allow | It renders the "7 days free, then $X/year" copy, the intro-offer eligibility, restore, and the terms/privacy links App Review looks for. A custom paywall is a v1.1 item if it can't be made to sit on the parchment. |
| Family Sharing | On | Free to enable, no code, and the listeners feature already assumes a shared phone. |
| Lifetime unlock | Not in v1 | Cheap to add later as a non-consumable in the same paywall; `currentEntitlements` covers both. Decide after seeing conversion. |
| Plex sign-out | Does not touch the entitlement | It is per Apple ID, not per Plex account. |

### Risk to name up front

Guideline 3.1.2(a) says subscriptions must provide ongoing value. ctunes has
no service behind it. Plenty of local-only utilities ship subscriptions, but a
first submission is where a reviewer asks. Mitigations, in order of cost:
make the App Store description lead with what keeps shipping (CarPlay,
offline, quality settings), keep the paywall honest about the price after the
trial, and, if it is rejected on that ground, add a lifetime non-consumable
next to the yearly plan. That is a one-product addition in App Store Connect
and one extra row in `SubscriptionStoreView`'s sibling `StoreView`.

## App Store Connect (no code, do first, some steps take days)

1. Paid Applications agreement, banking and tax, if not already done for the
   TestFlight build.
2. Create a subscription group, e.g. "ctunes", and one subscription in it:
   product id `com.colbyr.ctunes.yearly`, duration 1 year, $9.99 (Tier 10,
   let Apple equalize the other territories), Family Sharing on.
3. Add an introductory offer to it: type Free, duration 1 week, all
   territories.
4. Enable Billing Grace Period for the group (Subscriptions → Billing Grace
   Period), 16 days, new and renewing.
5. Localization for the group and the product (display name and description
   show in the paywall and on the Apple sheet).
6. A review screenshot of the paywall is required before the product can be
   submitted; it can be a simulator shot from milestone P2.
7. Create a sandbox tester in Users and Access → Sandbox. On a device, sign
   that account in under Settings → App Store → Sandbox Account, never as the
   phone's main Apple ID. In sandbox a 1-week trial lasts 3 minutes and a
   yearly renewal lasts 1 hour, so a full trial → paid → expiry cycle is
   watchable in a sitting.
8. The subscription ships with the first build that uses it: on the version
   page, attach it under In-App Purchases and Subscriptions, or the product
   never leaves "Ready to Submit".

## Milestones

### P0: entitlement model (`App/ctunes/Purchases.swift`)

A `@MainActor @Observable final class Purchases`, owned by `ContentView`
next to `AudioPlayer` and handed down with `.environment(purchases)`.
Not in PlexKit: it has nothing to do with Plex.

State it publishes:

```swift
enum Access: Equatable {
    case unknown        // launch, before StoreKit has answered; never shows the paywall
    case entitled(expires: Date?, isTrial: Bool)
    case lapsed         // no live transaction: never subscribed, trial over, or expired
}
private(set) var access: Access = .unknown
private(set) var products: [Product]   // empty offline; the paywall must cope
```

Behaviour:

- `start()` is called from `ContentView`'s `.task` at launch, before anything
  waits on Plex. It loads `currentEntitlements`, then loops over
  `Transaction.updates` for the life of the app. Every transaction it sees is
  verified (`VerificationResult.payloadValue`), finished (`transaction.finish()`),
  and triggers a `refresh()`. Renewals, Ask to Buy approvals, refunds and
  purchases made on another device all arrive here.
- `refresh()` re-reads `currentEntitlements`, filters to the product id, and
  derives `access`. `isTrial` is `transaction.offer?.type == .introductory`;
  `expires` is `transaction.expirationDate`. It also arms a sleeping task
  that fires `refresh()` at `expires` so a subscription that ends while the
  app is open locks without a relaunch (expiry produces no transaction, so
  `Transaction.updates` alone would miss it).
- `purchase()` calls `product.purchase()`. `.success` finishes the
  transaction and refreshes; `.pending` (Ask to Buy) leaves `access` alone,
  the approval arrives on `updates`; `.userCancelled` is silent.
- `restore()` is `AppStore.sync()` then `refresh()`. Rarely needed with
  StoreKit 2 but App Review expects the button.
- The pure decision, `[Entitlement] + now → Access`, lives in a small
  nonisolated value type with no StoreKit imports so it can be tested. There
  is no app test target yet (`notes/launch.md`, phase 3); until one exists
  the type can live in PlexKit under `Sources/PlexKit/Access.swift` with its
  test next to the others, name notwithstanding. Cases worth a test: no
  transactions → lapsed; one live transaction → entitled; a revoked
  transaction (`revocationDate` set) → lapsed; the introductory flag
  carried through.

### P1: the gate (`ContentView.swift`)

- Create `Purchases` in `ContentView.init` alongside the player and model,
  `.environment(purchases)` next to `.environment(player)`, and
  `purchases.start()` in the existing `.task`.
- Present the paywall with `.fullScreenCover(isPresented:)` bound to
  `purchases.access == .lapsed`, only while `model.state` is one of
  `.signedIn`, `.offline`, `.reconnecting`. Signed-out and connecting screens
  never see it. `.unknown` never presents, so a cold launch does not flash
  the paywall before StoreKit answers.
- **Hand the cover `.environment(player)` and `.environment(purchases)`
  explicitly**, same rule as the Now Playing sheet: a Mac window dragged
  across the compact/regular boundary re-hosts it without the inherited
  environment and traps.
- `onChange(of: purchases.access)` to `.lapsed`: `player.pause()`. The
  lock screen would otherwise keep a paying-looking transport alive over a
  locked app.
- Scene activation (`scenePhase == .active`, already handled here):
  `purchases.refresh()` before the existing reconnect/resume switch.
- `AppModel` is untouched. Access is not a state-machine state; it is a
  second axis, and folding it into `State` would double the cases the
  browse screens already switch on.

### P2: paywall (`App/ctunes/Views/PaywallView.swift`)

`SubscriptionStoreView(groupID:)` inside a `NavigationStack` on
`ParchmentBackground`, with:

- Marketing content at the top: the app icon, one line of what it is, three
  short rows (CarPlay, offline albums, lock screen). No feature checklist
  theatre.
- `.storeButton(.visible, for: .restorePurchases)`.
- `.subscriptionStorePolicyDestination(url:for: .termsOfService)` and
  `.privacyPolicy` pointing at the launch-plan URLs (`colbyr.com/ctunes/…`);
  Apple's standard EULA is acceptable for terms if there is no custom one.
- `.subscriptionStoreControlStyle(.prominentPicker)` or `.buttons`, whichever
  reads better with one product. Foreground `Color.ink`, tint the accent.
- Products empty (offline, or App Store unreachable): the view shows its own
  loading state, but add a footer line "Connect to the internet to start your
  trial" and make sure Sign Out is still reachable from the cover, or a user
  whose card was declined offline has no way out except deleting the app.
  Sign Out is the only escape hatch on the cover; there is no close button.
- `onInAppPurchaseCompletion` is not needed: `Purchases` sees the transaction
  on `updates` and the binding drops the cover.

### P3: Settings (`Views/SettingsView.swift`)

New `subscriptionSection` between `storageSection` and `accountSection`:

- Status row from `purchases.access`: "Free trial, ends 17 Sep", "Renews
  17 Sep 2027", or "Not subscribed" (only visible in the lapsed case if the
  cover ever lets settings show, which it doesn't; keep the case for
  completeness).
- "Manage Subscription" via `.manageSubscriptionsSheet(isPresented:)`.
- "Restore Purchases" calling `purchases.restore()`.
- Version footer stays in `accountSection`.

### P4: local testing setup

- `App/ctunes/Products.storekit`: the subscription group and product with the
  same ids as App Store Connect, the 7-day free intro offer, and the
  time-rate setting bumped (1 real minute = 1 subscription day, or faster)
  so the trial ends during a run. Synced from ASC once the product exists
  (Editor → Sync in Xcode) so the two never drift.
- Attach it to the scheme: `StoreKitConfigurationFileReference` under
  `LaunchAction` in `App/ctunes.xcodeproj/xcshareddata/xcschemes/ctunes.xcscheme`.
  The scheme is checked in, so `make sim` picks it up. Without the reference
  StoreKit talks to the real sandbox from the simulator, which needs an Apple
  ID sign-in there.
- Debug hooks, compiled out of release like the rest of the table in
  `CLAUDE.md`:

  | Variable | Effect |
  |---|---|
  | `CTUNES_DEV_ACCESS` | `lapsed` forces the paywall up, `entitled` forces it down, so the simulator can show the cover without any transaction |
  | `CTUNES_DEV_SETTINGS=1` | already exists; used to screenshot the subscription section |

- Xcode's Transaction Manager (Debug → StoreKit → Manage Transactions)
  refunds, expires and revokes the local transaction to drive every `Access`
  transition without waiting on the clock.

### P5: store hygiene for the change

- App Store description and the "What's New" mention the trial and the price
  after it; App Review reads the paywall against the listing.
- App Privacy questionnaire: still "no data collected". Purchases handled by
  StoreKit and never sent anywhere are Apple's, not yours.
- `PrivacyInfo.xcprivacy`: no new required-reason API from StoreKit.
- TestFlight: testers get the sandbox environment automatically, so the
  trial is 3 minutes and yearly is 1 hour for them too. Say so in the
  TestFlight notes or the first bug report will be "my trial ended after
  three minutes".
- Existing TestFlight testers who paid nothing lose nothing; there is no
  paid-up-front cohort to grandfather because that pricing never shipped.
  Update the pricing row in `notes/launch.md` when this lands.

## Order and effort

```
Day 0    ASC: agreement, group, product, intro offer, grace period, sandbox tester (waits on nothing in code)
Half day P0 model + Access tests
Half day P1 gate + P4 storekit file and scheme; verify in simulator with the time rate
Half day P2 paywall, P3 settings; screenshot for the ASC review field
Then     sandbox on device: trial start, 3-minute expiry, renewal, cancel, restore on a second device, Ask to Buy
```

The Plex-facing code does not change. The work is one model, one view, one
settings section and a scheme edit.

## Verification

- `make test` green with the `Access` cases.
- Simulator with `Products.storekit`: fresh launch shows sign-in, then
  connecting, then the paywall over the grid; Start Free Trial drops it; with
  the time rate compressed, the cover comes back when the trial lapses
  without the app being relaunched, and playback pauses when it does.
- `CTUNES_DEV_ACCESS=lapsed` with `CTUNES_DEV_ALBUM` and autoplay: the
  paywall covers a playing queue and the player pauses.
- Device with a sandbox tester: trial, expiry after 3 minutes, resubscribe,
  Manage Subscription opens the App Store sheet, Restore on a second device
  signed into the same sandbox account unlocks without purchasing.
- Airplane mode after a purchase: relaunch stays unlocked (offline
  `currentEntitlements`); the `.offline` snapshot library renders under no
  cover.
- Mac (Designed for iPad) resize sweep with the paywall up, per the
  `mac-designed-for-ipad-repro` note: no trap when crossing 960pt.
- Archive → Organizer validate passes; the product shows "Ready to Submit"
  and is attached to the version.

## Appendix: the home-grown trial (one-time unlock, or a soft trial)

Two things need this and neither is planned: a **one-time unlock** after the
trial, since StoreKit has no introductory offer on a non-consumable; or a
**soft trial**, where the app is fully open for 7 days and the paywall
appears only when the clock runs out. Either way the clock has to be
anchored somewhere a reinstall cannot reset:
`AppTransaction.shared.originalPurchaseDate` is the date this Apple ID first
downloaded the app, cached on device after the first verified read. Then
`Access` becomes `entitled` when either a subscription transaction is live
or `now < originalPurchaseDate + 7 days`, and the subscription product
carries no introductory offer (or keeps it, giving 14 days total, which is
fine). Costs: a first launch with no App Store reachability has no anchor
and must default open; TestFlight and sandbox report a fake old
`originalPurchaseDate`, so every tester would land on the paywall at first
launch unless `AppTransaction.environment` picks a keychain first-launch
date instead; and Apple sends no "trial ending" reminder, so the app has to
show one itself. About a day more than the plan above, and the fragile kind
of day. If the yearly plan later earns a lifetime option, it goes in as a
second product without any of this: the trial stays on the subscription.
