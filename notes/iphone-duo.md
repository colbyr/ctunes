# iPhone Duo

Apple's foldable, announced 2026-10-05, shipping 2026-10-23 with iOS
27.1. Two displays: the outer one is 466×678pt (compact width), the
inner one 669×951pt (regular both ways) and rotates to 951×669. Built
with the 27.1 SDK the app runs edge to edge, and the status bar, the
camera and every toolbar item move into a vertical strip down one
edge: on the outer display always, on the inner one in landscape.
Apple's prep page is developer.apple.com/iphone-duo/prepare; `xcrun
agent skills export` writes the `app-resizability` skill the page
refers to, which is the authoritative list of what to stop doing
(`UIScreen.main`, orientation, idiom, symmetric safe areas). The app
had none of those, so this note is about the layout.

## What was built

- **Now Playing is the left page of a wide window.** `LibraryView`
  takes the column when the window is 960pt or wider, as before, or
  when it is wider than tall and at least 800 usable. A Duo open in
  landscape is 951pt less the vertical strip's inset, about 850 to a
  `GeometryProxy`, which the old 960 line missed; an 11" iPad's 834
  portrait is taller than wide and keeps the cover. The column is half
  the window, capped at 560, and leads: held open like a book the fold
  runs down the middle, so the player is the left page and the library
  the right. This moved the column from the trailing edge on the iPad
  and the Mac too (the browser is still the bigger side past 1120).
- **Now Playing's header is two panes of an `ArrangementView`** (iOS
  27.1, `.split`): the artist, album and art as the primary, the
  title, scrubber and transport over the queue as the secondary. Flat,
  the split is stacked in the column and the portrait cover and side by
  side in a cover wider than tall; half folded like a laptop the fold is
  the division, so the art sits on the top half and the controls by the
  hands. The art pane asks for two fifths of a stacked split
  (`splitArrangementLayoutRatio`): a 669pt column then shows art of
  about 180 and a queue row and a half under the transport, where the
  old 400pt art left no room for the queue at all. The art's frame caps
  height as well as width so a short pane shrinks it instead of
  dropping it. On iOS 27.0 the panes are the `VStack` they replaced.
- **Search joins the vertical strip.** `VerticalBarProbe` reads
  `toolbarVerticalEdge` (27.1) into `LibraryNavigator.hasVerticalBar`;
  with it set, every browse screen adds `SearchBarItem`, a Search
  toolbar item that lands in the strip under the screen's own icons,
  and `BottomBar` drops its search pill until a search is open, when the
  pill comes back as the field. The mini player pill stays at the
  bottom; it is a custom view, and the strip takes only bar items.

## Measured

- With `.split.axes(.vertical)` a cover wider than tall showed the
  primary alone: the queue was gone. Default axes fix it.
- A primary with `splitArrangementFixedLayoutSize(vertical:)` whose
  ideal height exceeds the pane takes the whole pane. The ratio is the
  reliable lever.
- Without a ratio the split is about 55/45; the old header (art plus
  transport) in the top pane squeezed the art to nothing.
- The strip's inset is about 95pt in landscape on the inner display.
- Text-only items (Done, Sign out) stay horizontal, as Apple says;
  symbol items (back, ···, Play, Shuffle, Settings, Search) stack.

## Verify

Checked in the Xcode 27.1 Duo simulator (`notes/../memory` has the
driving details): closed, the browse root, album page scrolled, the
Now Playing sheet and Settings; open in landscape, the column beside
the album page. The iPad Pro 13 on iOS 27.0 showed the leading column
over the fallback stack. Not yet seen: the inner display in portrait
(the cover's stacked split), the laptop pose and the book pose, which
the simulator only folds from DeviceHub.

## Next

- The portrait cover and both folded poses, above.
- App Store screenshots for the Duo (required from April 2027): outer
  1398×2034, inner 2007×2853.
- iPhone orientations are portrait-only in the project; the inner
  display rotates the app anyway, so landscape on a plain iPhone is a
  separate decision.
