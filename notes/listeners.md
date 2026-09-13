# Listeners and vetoes

Who rides along, and what each of them would rather not hear. The roster
lives in `Sources/PlexKit/Listeners.swift`; `AppModel` owns it and syncs
the listeners through iCloud's key-value store (CLAUDE.md has the
storage details).

## The model

- A `Listener` has `vetoes: [Veto]`, in the order added, each target once.
- A `Veto` is a `VetoTarget` (`.artist`, `.album` or `.track` with the
  ratingKey) plus the `title` and `subtitle` it was saved with. The title
  rides along because the listener's page has to name a track or an album
  on any device, and nothing in the app holds every track. Identity is
  the target; the title is a label.
- `ListenerRoster.hidden` is a `VetoSet`: the active listeners' keys, one
  set per kind. Everything that filters reads this, never a listener.
- Legacy: `vetoedArtistKeys` decodes into artist vetoes with empty titles
  (the listener page names them from the library's artist list) and is
  still encoded, derived, so a device on an older build keeps the artist
  vetoes it understands. Its write would drop album and track vetoes,
  last writer wins; acceptable for one household's devices.

## The rules

1. **Hidden** means hidden by the item's own veto or any wider one. An
   album is hidden by its artist's veto; a track by its album's or its
   artist's. `VetoSet.hides(album)`, `hides(track)`.
2. **A collection opened on purpose still plays**, skipping only what is
   hidden inside it: `hides(track, within: .album)` is the track's own
   veto, `within: .artist` the track's and its album's, `within: .track`
   nothing (a track picked from a menu is always meant). `nil` is a
   library-wide list (favorites, a mix, the car's tabs), where every veto
   counts. `LibraryActions.playable` in `ItemMenus.swift` applies this
   for every menu action; the album page, artist page, mix builder,
   favorites and CarPlay apply it themselves.
3. **Vetoes don't absorb each other.** Pins narrow (an artist pin becomes
   album pins when one album is removed) because file wanting depends on
   it; here the union is enough, and un-vetoing an artist should leave an
   album veto made on purpose. The listener's page therefore lists both
   when both exist.
4. **The page's avatars toggle the page's item.** Artist page: the
   artist. Album page: the album, no longer the artist. The avatars show
   that veto alone; `HiddenRightNowLabel` explains when a wider veto is
   what hides the page ("all of The Beatles is hidden for Laura").
5. **The Listeners submenu is on every artist, album and track menu**,
   fed a `VetoScope` (the item's veto and the wider ones that could
   cover it, narrowest first). A listener a wider veto already covers
   shows off and disabled with the reason; flipping it there could not
   change what they hear.
6. **Rows dim, tiles dim, lists drop.** On the album page a track hidden
   on its own stays as a dimmed row with "Hidden for Laura"; on the artist
   page a hidden album is a dimmed tile. Library-wide lists (browse,
   favorites, mix pools, CarPlay) drop hidden items and say so in the
   `HiddenLine` ("2 artists & 1 album hidden for Laura"), counted at the
   widest level by `HiddenCount`.
7. **Adding.** Artists from the listener's page (the whole library is
   one list); albums and tracks from their menus or the avatars on their
   page, which is where they can be found. The page's footer says so.

## Checking it

`make sim`, then launch with `SIMCTL_CHILD_CTUNES_DEV_TOKEN` and
`SIMCTL_CHILD_CTUNES_DEV_LISTENERS=album:<key>` (or `track:<key>`, or an
artist key) with `CTUNES_DEV_ALBUM` or `CTUNES_DEV_ARTIST` for the page.
The roster persists in `UserDefaults`, so uninstall between scenarios or
the seed won't run again. The context menus can't be opened from the
terminal; check the disabled listener toggle by hand.
