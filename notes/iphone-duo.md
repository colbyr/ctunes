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
  portrait is taller than wide and keeps the cover. The column leads:
  held open like a book the fold runs down the middle, so the player is
  the left page and the library the right. **Its edge is the crease**:
  iOS 27.1 reports the fold as a `division` reserved region, placed
  even while flat with `includeInactive`, and the column ends on its
  midpoint. Half the usable width stopped 50pt short, since the vertical
  strip's inset is all on the trailing side. Without a fold the column
  is half the window, capped at 560, which moved it from the trailing
  edge on the iPad and the Mac too (the browser is still the bigger
  side past 1120).
- **Grid tiles follow the pane's width**, not the size class
  (`BrowseTile.minimum(forWidth:)`): the browser beside the column is
  about 375pt and still regular, where the 180pt floor gave one tile
  across. Under 560 the floor is the phone's 100, so three across.
- **The column is the phone's Now Playing, half the screen wide.** The
  same `List` as the sheet: names over the art, the title, the
  transport, then Up Next, all scrolling together, with no title row
  (a "Now Playing" heading over the art read as redundant; the artist
  line is padded to sit level with the stack's inline title instead,
  38pt under a vertical bar, 12 otherwise). A pinned split header (the art beside the names, the
  transport over the queue) beside the browser read as a different
  screen from the one the phone shows. The art is sized from a
  measurement of the column (`columnArtEdge`: the width less 56 of
  margins, no taller than 40% of the column, centred), since a List row
  whose height follows its width recurses on the Mac during a live
  resize; full-width art of 419pt in a 669pt column also pushed the
  transport off screen, and half the height still crowded it, so it is
  268 there. The laptop fold no longer divides the column.
- **The sheet and the cover follow a lagging size class.** Now Playing
  opened as the sheet on the outer display, then the device opened to
  landscape: the size class flipped to regular, the body was evaluated
  with the flag still set, and the cover binding (live on a regular
  width) presented a cover in the same pass as the host's
  `onChange(of: sizeClass)` dropped the flag. The log showed the flag
  false and the column chosen while the cover measured itself on
  screen: a presentation SwiftUI took as dismissed, so the × (setting
  an already-false flag) and nothing else could close it. The bindings
  now read `presentingIn`, a state the size-class change sets after
  dropping the flag, so the pass that sees the new size class sees no
  flag either. The cover also measures itself against
  `NowPlayingPresentation.wantsColumn` and drops the flag when the
  window is column-wide, since a full-screen presentation takes the
  host's view out of the window and the host can't.
- **The cover keeps the two-pane header**: an `ArrangementView` (iOS
  27.1, `.split`), the art pane as the primary, the scrubber and
  transport over the queue as the secondary. Flat, the split is stacked
  in the portrait cover and side by side in a cover wider than tall;
  half folded like a laptop the fold is the division, so the art sits
  on the top half and the controls by the hands. The art pane asks for
  45% of a stacked split (`splitArrangementLayoutRatio`). **In a
  stacked split the art pane is wider than tall**, so the names and
  title sit beside the art rather than under it (`namesBesideArt`, off
  `splitArrangementAxis` in the environment through `SplitAxisProbe`),
  and the art's edge is measured in a `GeometryReader`: the pane's
  height, or the width left after 180pt for the text. A side-by-side
  split, and iOS 27.0's `VStack`, keep the names over the art.
- **The column has no `NavigationStack`.** Beside the browser's
  stack on a Duo a second stack reserved a trailing inset the width of
  the vertical bar (about 85pt), so the column's content ran 335pt wide
  in a 475pt column. `toolbarVerticalBehavior(.disabled)` on that stack
  turned the bar off for the whole window instead. The cover keeps
  its stack for the close button.
- **Search joins the vertical strip.** `VerticalBarProbe` reads
  `toolbarVerticalEdge` (27.1) into `LibraryNavigator.hasVerticalBar`;
  with it set, every browse screen adds `SearchBarItem`, a Search
  toolbar item that lands in the strip under the screen's own icons,
  and `BottomBar` drops its search pill until a search is open, when the
  pill comes back as the field. The mini player pill stays at the
  bottom; it is a custom view, and the strip takes only bar items.
- **The play cards join the strip too.** The album, artist, playlist,
  Favorites and mix builder pages already hand their Play and Shuffle
  (Mix Albums and Shuffle) cards to the toolbar as icons once the cards
  scroll away; under a vertical bar (`iconsInBar`) the icons are there
  from the start and the page shows no cards, so the strip reads back,
  ···, Play, Shuffle, Search down one edge.
- **The mini player sits level with Search.** The strip's bottom item
  is a 47pt glass circle whose foot is 25pt from the window's edge, 12pt
  inside the strip's 82pt inset; the pill was 52pt, 26pt up, with 20pt
  of trailing padding, so its top sat 6pt higher and 30pt of air lay
  between the two. Under a vertical bar the pill is 48pt (`short`),
  25pt up, with no trailing padding: 12pt of air, tops and feet within
  a point. Measured off a 3x screenshot of the closed outer display.

## Measured

- With `.split.axes(.vertical)` a cover wider than tall showed the
  primary alone: the queue was gone. Default axes fix it.
- A primary with `splitArrangementFixedLayoutSize(vertical:)` whose
  ideal height exceeds the pane takes the whole pane. The ratio is the
  reliable lever.
- Without a ratio the split is about 55/45; the old header (art plus
  transport) in the top pane squeezed the art to nothing.
- An `HStack` of a flexible square and a text column gave the square
  140pt of a 419pt strip whatever the `layoutPriority` and `minWidth`;
  measuring the edge is the reliable way.
- The strip's inset is about 95pt in landscape on the inner display.
- Text-only items (Done, Sign out) stay horizontal, as Apple says;
  symbol items (back, ···, Play, Shuffle, Settings, Search) stack.
- The fold region's `midX` in the host's space is 475.5 of 951 in
  landscape, with the hinge reported `fullyOpen 180°`; the simulator's
  screenshot draws no crease, so check the divider against the centre.
- `onHingeChange` streams the angle while the simulator folds; the
  status reads `closed` from about 80° down. A debug build logs it under
  `Layout` (`VerticalBarProbe`), which is how a fold is noticed from the
  terminal.

## Verify

Checked in the Xcode 27.1 Duo simulator: closed, the browse root, the
album page scrolled, the Now Playing sheet and Settings; open in
landscape, flat and in the book pose, the column on the crease beside
the album page, the artist page and the mix builder with their cards
in the strip, and the browse root at three tiles across. The iPad Pro
13 on iOS 27.0 showed the leading column over the fallback stack. Not
yet seen: the inner display in portrait (the cover's stacked split),
the laptop pose, the pill beside the strip's search item after the
48pt change (the pose is the user's; the numbers are measured), and
the column during a live resize on the Mac. The open-to-landscape move
with the sheet up was replayed by hand after the fix: the sheet went,
the column came.

## Next

- The portrait cover and both folded poses, above.
- App Store screenshots for the Duo (required from April 2027): outer
  1398×2034, inner 2007×2853.
- iPhone orientations are portrait-only in the project; the inner
  display rotates the app anyway, so landscape on a plain iPhone is a
  separate decision.
