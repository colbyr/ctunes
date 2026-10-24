# Payments: paid up front, $9.99, one time

## Context

An earlier version of this note planned a free download, a 7-day trial
and a $9.99/year subscription. That was dropped before any of it was
built: it meant a paywall, an entitlement model, an expiry timer, a
grace period, a sandbox test cycle and a Settings section. That's about
two days of code plus App Store Connect setup, and it put a Guideline
3.1.2(a) question to App Review ("subscriptions must provide ongoing
value") for an app with no service behind it. The reasoning for paying
once is also in `notes/launch.md` (Pricing recommendation).

## Decisions

| Question | Decision | Why |
|---|---|---|
| Model | Paid up front, one time, $9.99 | No StoreKit code, no paywall, no restore flow, nothing for review to question. People who run their own Plex server tend to avoid subscriptions, so a single price is part of the pitch next to Plexamp (needs Plex Pass). |
| Price | $9.99 (US), Apple's equalization elsewhere | Expected volume is small, CarPlay and offline are paid features in every comparable app, and a price is easier to cut than raise. |
| Trial | None in the app. TestFlight is the beta, Apple's refund flow is the backstop | A trial for a one-time purchase needs a home-made clock (StoreKit has no introductory offer on a non-consumable). |
| Family Sharing | On | Free, no code, and listeners already assume a shared phone. |
| Way out | Free download + a $9.99 non-consumable unlock, buyers grandfathered (below) | Only if sales show "will it work with my server?" is costing buyers. Nothing is built for it now. |

## App Store Connect

1. Paid Applications agreement, banking and tax. Without them a paid
   app can't be released, even after review passes.
2. Pricing and Availability → price $9.99, all territories (or trim).
3. Family Sharing on (same page).
4. Description, below. App Review checks the listing against the app, so
   the listing shouldn't promise anything the build doesn't do.
5. Review notes still need the demo Plex account (`notes/launch.md`,
   App Store prep). A paid app gets no special treatment there.

TestFlight testers don't pay and keep getting builds. Once the price is
set, a tester who wants the App Store build buys it like anyone else.

## Listing copy (draft)

Subtitle (30 chars max): **Your Plex music, made simple**

> ctunes plays the music on your Plex server. Sign in, pick your library,
> and play an album.
>
> • CarPlay, the lock screen and Siri
> • Downloads for offline listening, at the quality you choose
> • Shuffle that spreads out artists and albums
> • Listeners: share a phone without sharing taste. Hide an artist for
>   the kids and keep it for yourself
> • Shortcuts and widgets for the mixes you play most
> • Streaming quality settings for cellular
>
> One purchase. No subscription, no account beyond your Plex one, no data
> collected.
>
> Requires a Plex Media Server with a music library. ctunes is not
> affiliated with Plex, Inc.

"Requires a Plex Media Server" is the line that cuts refunds: it's what
a buyer most needs to know first. Keep "Plex" out of the app name
(trademark), but it's fine in the description and keywords.

## Way out: free download + unlock, buyers grandfathered

Only if numbers call for it. Apple's documented pattern: read the
version the person first installed, and anyone who installed before the
switch is unlocked.

```swift
import StoreKit

/// True when this Apple ID first downloaded ctunes while it was paid.
func boughtWhilePaid() async -> Bool {
    guard case .verified(let app) = try? await AppTransaction.shared else { return false }
    // On iOS `originalAppVersion` is CFBundleVersion (the build number), not
    // the marketing version. Xcode bumps it on upload, so pin the first free
    // build's number here from App Store Connect.
    let firstFreeBuild = 0  // TODO: set when the free build is archived
    guard let original = Int(app.originalAppVersion) else { return false }
    return original < firstFreeBuild
}
```

Things to know before relying on it:

- **Ship the check one release before the switch.** The free build has
  to recognise earlier buyers from its first launch.
- `AppTransaction.shared` is cached on the device after the first verified
  read, so it works offline after that. A first launch with no App Store
  connection has no answer yet: default to unlocked, check again later.
- Sandbox and TestFlight report `originalAppVersion` as `"1.0"`, which
  isn't an integer. Gate on `app.environment == .production`, and use a
  debug override (`CTUNES_DEV_ACCESS`) to test both branches.
- The unlock itself is one non-consumable (`com.colbyr.ctunes.unlock`),
  `Transaction.currentEntitlements` for the check, `StoreView(ids:)` for
  the sheet and a Restore button. Unlocked = `boughtWhilePaid() ||`
  an entitlement for that product.
- Pick the free tier's limit by feature, not by time: no clock to build or
  get wrong. Downloads, CarPlay and Siri/widgets are the obvious paid
  side; browsing and streaming stay free so "does it reach my server" is
  answered before anyone pays.

About a day of work when the time comes. Until then there's no StoreKit
code in the app, and that's on purpose.
