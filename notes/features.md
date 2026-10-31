# Feature list

Written 2026-10-30 from the code: the views, `AppModel`, `AudioPlayer`,
CarPlay, Siri and the widgets. Debug-only hooks are left out. The Now
Playing, Storage and Quick Mix screens were checked by their labels and
controls rather than line by line.

## Sign-in and library

- Sign in with Plex using a link code in a browser sheet
- The server is found and remembered automatically; there is no server picker
- A Library picker in Settings when the server has more than one music library
- Opens the last library from saved data at once and connects behind it
- Sign Out asks first, then removes this device's downloads

## Connection

- Banner: "Looking for your server", then "Slow connection", then "Offline" with Try again
- Retries on its own (10s, backing off to once a minute) and again when the app or car screen comes to the front
- Moves between Wi-Fi and cellular without losing your place or the queue
- Offline: browse the saved library and play what is downloaded

## Home screen

- Quick Mix and Playlists cards, then the Shortcut cards
- Browse Albums, Artists or Playlists, as a grid or a list
- Sorts: On Rotation, Recently Added, A to Z (Release Date on an artist's page), Back Catalog
- Over playlists the first two read Most Played and Recently Updated
- Each screen keeps its own sort
- "Downloaded only" filter chip
- Listener chips to choose who is listening, with a count of what is hidden
- Pull to refresh on every browse screen

## Album and artist pages

- The ground is tinted from the cover art
- Play and Shuffle on an album, Mix Albums and Shuffle on an artist; they move into the toolbar when scrolled past
- A download button on the album cover
- Tap a listener's avatar to hide the album or artist for them
- Track rows: the playing track highlighted, unplayable or hidden tracks dimmed
- Swipe a track to favorite it

## Favorites

- Hearted tracks; sort by Recently Favorited, Artist or Album
- Play and Shuffle, and Download from the More menu
- Swipe to Unfavorite

## Playlists

- Create, rename and delete
- Add tracks from any menu
- Reorder in Edit mode, swipe to remove
- Sorts inside a playlist: Playlist Order, Title, Artist, Album
- Smart playlists are read-only
- The Playlists page has its own grid or list, sorts and filter

## Item menus (long press or ···)

- Go to Artist, Album or Playlist
- Play, Shuffle, Play Next, Add to Queue
- Add to Playlist, with New Playlist…
- Favorite
- Download, Stop, Retry, Cancel, Remove
- Listeners submenu ("Who hears X")
- In the queue: Move to End, Remove from Queue

## Search

- One ranked list of artists, albums, playlists and songs
- Suggests ways to finish the query
- Recently Searched (20 items, with Clear)
- Offline it matches the downloaded tracks

## Now Playing

- A sheet on a phone; a full-screen cover or a column beside the library on iPad and Mac
- Art, heart, scrubber, previous, play/pause, next, AirPlay
- Previous restarts the track after 3s of play
- Repeat (Off, All, One) and Shuffle; turning shuffle off restores the order
- Up Next: tap to jump, swipe to remove, ··· menu
- "That's everything" when the queue ends, with Play again
- The mini player above the bottom bar on every screen

## Playback

- Lock screen, Control Center and headphone controls, shuffle and repeat included
- Every shuffle spreads tracks out by artist and album
- Survives Siri, calls and car assistants, resuming only when the system says to
- Unplugging headphones or the car leaves it paused
- The next tracks are fetched ahead so they don't stream twice

## Quick Mix and Shortcuts

- Pick artists, albums, playlists or Favorites; nothing picked is the whole library
- Styles: Play, Shuffle, Mix Albums
- Save a mix as a named Shortcut card
- Settings → Shortcuts: reorder, rename, restyle, delete, New Mix…
- A card is hidden when everything in it is hidden for the current listeners
- Synced through iCloud per library

## Listeners

- Add, rename and remove listeners, in six colors
- Hide artists, albums or tracks per listener, synced through iCloud
- A listener's page lists what they don't hear and adds artists to it
- "Hidden right now — X is listening" explains a hidden page

## Settings and storage

- Streaming Quality and Download Quality: Original (default), 320, 192 or 128 kbps
- Download on Cellular, on by default
- Keep Favorites Downloaded
- Storage: a usage bar, downloads by artist, album and track (swipe to remove), Remove All Downloads, Retry stalled downloads
- Max Cache Size: 500 MB, 1, 2 (default), 5 or 10 GB, and Remove Cached Tracks

## CarPlay

- Tabs: On Rotation, Artists (A to Z with an index), Recently Added, Favorites, Playlists
- Recently Added is dropped on a car that shows four tabs
- Album, artist and playlist screens with Play and Shuffle or Mix Albums
- Now Playing with Shuffle, Repeat, Up Next and a button to the artist
- Screens for connecting, signed out, choosing a library and an unreachable server
- Follows the listeners' hidden items and what plays offline

## Siri

- Shortcuts: Shuffle Favorites, Play On Rotation ("play music"), Play or Shuffle a playlist by name, Resume, Play a saved Shortcut
- "Play X" for any artist, album, song or playlist, with shuffle, repeat, play next and add to queue
- "Tunes" works as the app name
- Plays without opening the app

## Widgets

- Shortcut (small and lock screen circle): tap to play the chosen shortcut
- Shortcuts (medium shows 2, large up to 5): tap a row to play it, the chevron opens it in the app

## Other

- `ctunes://` links to favorites, a mix, an album, an artist or a playlist
- iPhone, iPad, Mac (as an iPad app) and iPhone Duo

## Not finished or limited on purpose

- Siri's queue warm-up is an empty placeholder
- Siri can't open music from a URL
- Smart playlists can't be edited
- Editing, hearts and downloads are off with no connection
