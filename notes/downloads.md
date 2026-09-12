# Downloads v1: artist and track pins, badges everywhere, a manager in Settings

## Context

`notes/offline.md` shipped pins at two grains: an album, and the favorites set. The album
page's badge and the row glyphs read the pinned root directly, `OfflineStore.statuses()`
covered pinned albums only, and Settings had a byte count and a Remove All. There was no
way to keep a whole artist, keep one track, see what an album with two pinned favorites
looks like on the grid, or see where 1.5 GB went.

Decisions made up front:

- **Three pin kinds, one tree, kept disjoint.** Artist over album over track. Pinning an
  artist absorbs their album and track pins; removing an album under an artist narrows the
  artist to their other albums; removing a track under an album narrows the album to its
  other tracks. Removing never widens or silently keeps: what you swiped away is gone from
  disk unless the favorites pin still wants it, and what you didn't is still kept, under a
  narrower pin. The manager shows each pin once, at its own level.
- **The badge reflects the pinned root, not the cache root.** A file left from a play is
  playable offline and is dimmed accordingly, but it is not a download and gets no mark.
- **One read for everything.** `OfflineStore.inventory(server:)` walks the pinned root
  once, folds the manifest and the saved track lists over it, and hands back a value the app
  mirrors. Views derive every badge, count and byte figure from that value; nothing stats
  the disk per row.
- **Artist totals come from the section's album list.** An artist with three albums, one
  pinned, is partial, not complete, even though the store has never seen the other two:
  `PlexAlbum.leafCount` from `/library/sections/{key}/albums` gives every album a track
  count, and `Downloads` keeps the list the browse root loaded (or the snapshot's).

Non-goals: following an artist pin as new albums arrive on the server; per-track art;
background downloads; a cellular switch.

## Layout

```
<server>/manifest.json           artists: {key → title, thumb, section, pinnedAt}
                                 albums:  {key → title, section, pinnedAt, album}
                                 favoritesPinned
<server>/artists/<key>.json      [PlexAlbum] the artist had when pinned
<server>/albums/<key>.json       [PlexTrack] per album browsed or pinned (unchanged)
<server>/tracks.json             [PlexTrack] pinned on their own
<server>/favorites.json          (unchanged)
<server>/art/<name>.jpg          covers and portraits, one request each at pin time
```

`Manifest.init(from:)` decodes a v1 manifest (no `artists`, no `album` record) as is; an
old album pin gets a synthetic record from its saved tracks for the manager's row.

Wanted files: artist pins' albums' tracks, album pins' tracks, track pins, favorites when
on. `unpin*` diffs the wanted set before and after and hands the difference to the cache,
which renames those files back into the cache root, as before.

## State

```swift
struct AlbumDownloadStatus { artistKey, done, known, missing, failed, undownloadable, bytes, pinned }
enum DownloadState { none, downloading(done, total, stalled), partial(done, total), complete(undownloadable) }
```

An album's `total` is `max(known, leafCount, done + missing + undownloadable)`. `missing`
counts fetchable tracks a pin wants with no file; `stalled` when every one of them is
inside the cache's failure backoff. An artist is the `Rollup` sum over its albums. The
inventory keeps a status for every browsed album, even with nothing down, so the artist
rollup counts its tracks; an album known only through a heart and never browsed has no
entry once the heart is gone.

`DownloadBadge(state:)` draws a white arrow on a glass disc tinted dark (so it holds up
on white art), with a ring that fills as the download does: dotted while downloading (an
exclamation mark once stalled), half for partial, whole for complete. It sits on every
album tile, the album cover, the artist portrait and both mix pools. The cover and the
portrait show a bare white arrow with a shadow instead when nothing is down; tapping it
downloads, and Stop and Remove stay in the menu. Track rows keep `arrow.down.circle.fill`,
dotted while the file is on its way.

## Menus and the manager

`LibraryActions.downloadItems` is the one shape for artists and albums: Download when not
pinned; Stop while downloading; Retry and Remove once stalled; Remove when complete or
partial-by-intent. Tracks get Download or Stop/Remove beside the heart. `AppModel.
downloadArtist` fetches the album list and the artist's tracks in one go each and files
the tracks per album.

`StorageList` (Settings → Storage): a bar of downloads and play cache against the phone's
capacity (from `volumeAvailableCapacityForImportantUsage`, the figure iPhone Storage
shows), the favorites toggle with its own count, Artists, Albums and Tracks sections in
pin order, Remove All, then the play cache: its size, a picker for the limit (500 MB to
10 GB, `AudioPlayer.cacheLimit`, evicting at once when lowered) and Clear. An artist row
opens their albums, an album row opens its tracks with per-track sizes; swipe removes at
any level and the page pops itself once its pin is gone.

## Verification

`make test` (138, all in `OfflineStoreTests` for the store). In the simulator with
`CTUNES_DEV_ALBUM` set: `CTUNES_DEV_PIN=artist` wrote `artists/2899.json`, the three
album lists, the portrait and three covers, and the artist page showed the solid badge on
the portrait and every tile; `CTUNES_DEV_PIN=track` on another album showed the half
ring on the cover and the glyph on one row; `CTUNES_DEV_SETTINGS=storage` listed the
artist pin and a v1 album pin with sizes under the storage bar.

## Follow-ups

- Refresh artist pins on connect so a new album by a pinned artist downloads.
- A per-row progress figure in the manager while an artist is coming down.
- A "downloaded only" filter on the artist page's grid.
