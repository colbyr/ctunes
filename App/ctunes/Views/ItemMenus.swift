import PlexKit
import SwiftUI

/// Where the stack should go next. The menus sit on rows, tiles and covers
/// on every screen, most of which have no path of their own, so a menu
/// posts the route here and `LibraryView`, which owns the path, pushes it.
/// Also carries the one-line notice an action shows when it had nothing to
/// do ("Nothing to play"), presented by the same host.
@MainActor @Observable
final class LibraryNavigator {
    var requested: LibraryRoute?
    var notice: String?
    /// The tracks a new playlist should start with, none included: the
    /// host asks for a name, creates it and opens its page.
    var composing: [PlexTrack]?
    /// A playlist to rename; the host asks for the new name.
    var renaming: PlexPlaylist?
    /// A playlist to delete; the host confirms first.
    var deleting: PlexPlaylist?
    /// A download to remove; the host confirms first.
    var removing: DownloadRemoval?

    func open(_ route: LibraryRoute) { requested = route }
}

enum LibraryRoute: Hashable {
    case artist(ArtistRoute)
    case album(PlexAlbum)
    case playlist(PlexPlaylist)
    /// The mix builder, on a saved mix's picks or the last selection.
    case mix(MixRoute)
    case favorites
}

/// The work behind the menu items. Built by each menu from the environment
/// rather than held anywhere: it is a handful of references, and the
/// menus are the only callers.
@MainActor
struct LibraryActions {
    let model: AppModel
    let player: AudioPlayer
    let nowPlaying: NowPlayingPresentation
    let navigator: LibraryNavigator

    var offline: Bool { model.library?.isOffline ?? false }

    /// What can enter the queue from a collection: offline, only a track
    /// with a file; and never a track the active listeners hide inside
    /// the collection (`within`), so an album skips its vetoed tracks and
    /// an artist their vetoed albums. The one track a menu was opened on
    /// is always kept: it was chosen on purpose.
    func playable(_ tracks: [PlexTrack], within container: VetoKind?, keeping chosen: PlexTrack? = nil) -> [PlexTrack] {
        let hidden = model.roster.hidden
        return tracks.filter {
            ($0.id == chosen?.id || !hidden.hides($0, within: container))
                && (!offline || model.downloads.isAvailable($0))
        }
    }

    /// The whole list from the top, or from one of its tracks. Nothing
    /// to play is a notice, never silence.
    func play(_ tracks: [PlexTrack], within container: VetoKind?, from track: PlexTrack? = nil) {
        guard let library = model.library else { return }
        let tracks = playable(tracks, within: container, keeping: track)
        guard !tracks.isEmpty else { return nothingToPlay() }
        let start = track.flatMap { track in tracks.firstIndex { $0.id == track.id } } ?? 0
        player.play(tracks, startingAt: start, library: library)
        nowPlaying.isShown = true
    }

    /// Every shuffle in the app is the spread shuffle. With a leading
    /// track it plays first and the rest of the list follows shuffled.
    func shuffle(_ tracks: [PlexTrack], within container: VetoKind?, leading track: PlexTrack? = nil) {
        guard let track else { return play(tracks.spreadShuffled(), within: container) }
        let rest = tracks.filter { $0.id != track.id }.spreadShuffled()
        play([track] + rest, within: container, from: track)
    }

    /// Whole albums front to back, the album order shuffled, the way the
    /// artist page's Mix Albums does it.
    func mixAlbums(_ tracks: [PlexTrack], within container: VetoKind?) {
        play(tracks.albumShuffled(), within: container)
    }

    func enqueue(_ tracks: [PlexTrack], within container: VetoKind?, next: Bool) {
        guard let library = model.library else { return }
        let tracks = playable(tracks, within: container)
        guard !tracks.isEmpty else { return nothingToPlay() }
        next ? player.playNext(tracks, library: library)
             : player.addToQueue(tracks, library: library)
    }

    /// A queued entry moved to right after the current track, or to the
    /// end: removed and re-added, which the queue's ids make safe with
    /// duplicates.
    func move(_ entry: PlayQueue<PlexTrack>.Entry, next: Bool) {
        guard let library = model.library else { return }
        player.remove(entry)
        next ? player.playNext([entry.item], library: library)
             : player.addToQueue([entry.item], library: library)
    }

    /// Appends to a playlist and says what happened: the server drops
    /// tracks already there, so "Already in" is common and worth a line.
    func add(_ tracks: [PlexTrack], to playlist: PlexPlaylist) async {
        guard !tracks.isEmpty else { return navigator.notice = "Nothing to add." }
        guard let added = await model.add(tracks, to: playlist) else {
            return navigator.notice = "Couldn't add to \(playlist.title)."
        }
        navigator.notice = added == 0
            ? "Already in \(playlist.title)."
            : "Added \(PlexPlaylist.trackCount(added)) to \(playlist.title)."
    }

    /// Asks the host for a name and starts a playlist with the tracks.
    func compose(_ tracks: [PlexTrack]) {
        if nowPlaying.isShown, !nowPlaying.isColumn { nowPlaying.isShown = false }
        navigator.composing = tracks
    }

    func download(_ album: PlexAlbum, known: [PlexTrack]?) async {
        guard let library = model.library, !library.isOffline else { return }
        let tracks = await model.tracks(of: album, known: known)
        guard !tracks.isEmpty else { return }
        model.downloads.pin(album, tracks: tracks, section: model.selectedSection?.key ?? "", library: library)
    }

    func download(_ track: PlexTrack) {
        guard let library = model.library, !library.isOffline else { return }
        model.downloads.pin([track], library: library)
    }

    /// The whole artist, every album; nothing to pin is a notice.
    func downloadArtist(key: String, title: String) async {
        if await !model.downloadArtist(key: key, title: title) {
            navigator.notice = "Nothing to download."
        }
    }

    /// The download items every menu offers, given whether the item is
    /// pinned and how far along, the same glyphs as the mark on its art:
    /// Download when it isn't pinned (partial included, since the arrow
    /// finishes the job); while a pin is coming down, Stop; while it
    /// waits, Retry and Cancel; once it is down, Remove. Cancel and Remove
    /// ask first; Stop is the one that doesn't, since it is in flight.
    @ViewBuilder
    func downloadItems(pinned: Bool, state: DownloadState, download: @escaping () -> Void, remove: @escaping @MainActor () -> Void) -> some View {
        if !offline {
            Section {
                if !pinned {
                    Button(action: download) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                } else if state.isStalled {
                    Button {
                        model.downloads.retry { await model.resumeDownloads() }
                    } label: {
                        Label("Retry Download", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { removeDownload(remove, cancels: true) } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                } else if state.isDownloading {
                    Button(action: remove) {
                        Label("Stop Download", systemImage: "stop.circle")
                    }
                } else {
                    Button(role: .destructive) { removeDownload(remove) } label: {
                        Label("Remove Download", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }

    /// Posts the remove for the host to confirm; a cover over the host
    /// closes first so the dialog has somewhere to land.
    func removeDownload(_ remove: @escaping @MainActor () -> Void, cancels: Bool = false) {
        if nowPlaying.isShown, !nowPlaying.isColumn { nowPlaying.isShown = false }
        navigator.removing = DownloadRemoval(cancels: cancels, action: remove)
    }

    /// Navigation from inside the Now Playing cover closes it first; the
    /// column stays where it is.
    func open(_ route: LibraryRoute) {
        if nowPlaying.isShown, !nowPlaying.isColumn { nowPlaying.isShown = false }
        navigator.open(route)
    }

    func nothingToPlay() {
        navigator.notice = offline ? "Nothing here is downloaded." : "Nothing to play."
    }
}

// MARK: - Menus

/// Long-press menu for an artist, wherever one is drawn: a grid heading,
/// a mix tile, the portrait, the name under an album.
struct ArtistMenu: View {
    let model: AppModel
    let ratingKey: String
    let title: String
    /// Both off on the artist's own page, where the page has the link
    /// and the hero cards.
    var showArtist = true
    var showPlayback = true
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator

    var body: some View {
        let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
        if showArtist {
            Section {
                Button { actions.open(.artist(ArtistRoute(ratingKey: ratingKey, title: title))) } label: {
                    Label("Go to Artist", systemImage: "music.microphone")
                }
            }
        }
        if showPlayback {
            Section {
                Button {
                    Task { actions.mixAlbums(await model.tracks(ofArtist: ratingKey), within: .artist) }
                } label: {
                    Label("Mix Albums", systemImage: "square.stack")
                }
                Button {
                    Task { actions.shuffle(await model.tracks(ofArtist: ratingKey), within: .artist) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }
        }
        // Vetoes are not applied here: they apply when the playlist plays.
        AddToPlaylistMenu(model: model) { await model.tracks(ofArtist: ratingKey) }
        actions.downloadItems(
            pinned: model.downloads.isPinned(artist: ratingKey),
            state: model.downloads.state(artist: ratingKey),
            download: { Task { await actions.downloadArtist(key: ratingKey, title: title) } },
            remove: { model.downloads.unpinArtist(ratingKey) }
        )
        ListenersMenu(model: model, scope: VetoScope(artistKey: ratingKey, title: title))
    }
}

/// Long-press menu for an album: a tile in any grid, or the cover on its
/// own page, where the tracks are already loaded and handed in.
struct AlbumMenu: View {
    let model: AppModel
    let album: PlexAlbum
    /// The page's tracks when it has them; nil fetches on demand.
    var tracks: [PlexTrack]? = nil
    /// Off on the artist's page, where every tile is theirs.
    var showArtist = true
    /// Off on the album's own page, which has the link and the Play and
    /// Shuffle cards; the queue items stay.
    var showAlbum = true
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator

    private var offline: Bool { model.library?.isOffline ?? false }
    /// Offline, an album with no file has nothing to queue.
    private var playable: Bool { !offline || model.downloads.hasDownloads(album) }

    var body: some View {
        let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
        Section {
            if showAlbum {
                Button { actions.open(.album(album)) } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            if showArtist, let key = album.parentRatingKey, let artist = album.parentTitle {
                Button { actions.open(.artist(ArtistRoute(ratingKey: key, title: artist))) } label: {
                    Label("Go to Artist", systemImage: "music.microphone")
                }
            }
        }
        if playable {
            Section {
                if showAlbum {
                    Button {
                        Task { actions.play(await model.tracks(of: album, known: tracks), within: .album) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        Task { actions.shuffle(await model.tracks(of: album, known: tracks), within: .album) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                Button {
                    Task { actions.enqueue(await model.tracks(of: album, known: tracks), within: .album, next: true) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { actions.enqueue(await model.tracks(of: album, known: tracks), within: .album, next: false) }
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        AddToPlaylistMenu(model: model) { await model.tracks(of: album, known: tracks) }
        // An album under an artist pin reads as pinned; removing it
        // narrows the artist to their other albums.
        actions.downloadItems(
            pinned: model.downloads.isPinned(album),
            state: model.downloads.state(album),
            download: { Task { await actions.download(album, known: tracks) } },
            remove: { model.downloads.unpin(album) }
        )
        ListenersMenu(model: model, scope: VetoScope(album: album))
    }
}

/// Long-press menu for a playlist: a tile in the grid, a search result,
/// or the `···` on its own page, where the items are already loaded and
/// handed in. Playing it skips what the active listeners hide by any
/// veto: a playlist is opened on purpose but it is a mixed bag, and a
/// vetoed artist inside it is exactly what a veto is for.
struct PlaylistMenu: View {
    let model: AppModel
    let playlist: PlexPlaylist
    /// The page's items when it has them; nil fetches on demand.
    var items: [PlaylistItem]? = nil
    /// Off on the playlist's own page, which has the link and the Play
    /// and Shuffle cards; the queue items stay.
    var showPlaylist = true
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator

    private var offline: Bool { model.library?.isOffline ?? false }
    /// Offline, a playlist with no file has nothing to queue.
    private var playable: Bool { !offline || model.downloads.hasDownloads(playlist) }

    var body: some View {
        let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
        let tracks: () async -> [PlexTrack] = { await model.items(of: playlist, known: items).map(\.track) }
        if showPlaylist {
            Section {
                Button { actions.open(.playlist(playlist)) } label: {
                    Label("Go to Playlist", systemImage: "music.note.list")
                }
            }
        }
        if playable {
            Section {
                if showPlaylist {
                    Button {
                        Task { actions.play(await tracks(), within: nil) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        Task { actions.shuffle(await tracks(), within: nil) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                Button {
                    Task { actions.enqueue(await tracks(), within: nil, next: true) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { actions.enqueue(await tracks(), within: nil, next: false) }
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        // A smart playlist is a saved filter: the server names and fills
        // it, so no edits here. Every write is refused offline.
        if !offline, !playlist.smart {
            Section {
                Button { navigator.renaming = playlist } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button(role: .destructive) { navigator.deleting = playlist } label: {
                    Label("Delete Playlist…", systemImage: "trash")
                }
            }
        }
        actions.downloadItems(
            pinned: model.downloads.isPinned(playlist),
            state: model.downloads.state(playlist),
            download: { Task { await model.setPlaylistPinned(playlist, true) } },
            remove: { model.downloads.unpin(playlist) }
        )
    }
}

/// The Add to Playlist submenu every artist, album and track menu
/// carries: one entry per regular playlist (a smart playlist can't be
/// added to) and "New Playlist…" last. The tracks are fetched in the
/// action, the way Play does, with no vetoes applied: they apply when
/// the playlist plays. Hidden offline, like Download.
struct AddToPlaylistMenu: View {
    let model: AppModel
    /// The playlist the tracks are already in, left out of the list.
    var excluding: PlexPlaylist? = nil
    let tracks: () async -> [PlexTrack]
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator

    private var offline: Bool { model.library?.isOffline ?? false }

    var body: some View {
        if !offline {
            let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
            let regular = AlbumView.artist.sorted(model.playlists.filter { !$0.smart && $0.ratingKey != excluding?.ratingKey })
            Section {
                Menu {
                    ForEach(regular) { playlist in
                        Button(playlist.title) {
                            Task { await actions.add(await tracks(), to: playlist) }
                        }
                    }
                    if !regular.isEmpty { Divider() }
                    Button {
                        Task { actions.compose(await tracks()) }
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                } label: {
                    Label("Add to Playlist", systemImage: "music.note.list")
                }
            }
        }
    }
}

/// Where a track row sits, which decides what its menu can offer.
enum TrackPlacement {
    /// A row in a list that can be played from that row: the album page,
    /// Favorites. `siblings` is the list, in its order.
    case list(siblings: [PlexTrack])
    /// A row of a playlist's page: plays like `.list`, and on a regular
    /// playlist the item can be removed from it. `siblings` is the page's
    /// rows, in order.
    case playlistItem(PlaylistItem, in: PlexPlaylist, siblings: [PlexTrack])
    /// A row of Up Next: the queue actions move it instead of copying it.
    case queued(PlayQueue<PlexTrack>.Entry)
    /// The track playing now: the art in Now Playing, the mini player.
    case playing
}

/// Long-press menu for a track, and what the row's ··· button opens.
struct TrackMenu: View {
    let model: AppModel
    let track: PlexTrack
    let placement: TrackPlacement
    /// Off on the album's own page.
    var showAlbum = true
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator

    private var offline: Bool { model.library?.isOffline ?? false }
    private var playable: Bool { !offline || model.downloads.isAvailable(track) }

    var body: some View {
        let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
        let favorite = model.isFavorite(track)
        Section {
            if let key = track.grandparentRatingKey, let artist = track.grandparentTitle {
                Button { actions.open(.artist(ArtistRoute(ratingKey: key, title: artist))) } label: {
                    Label("Go to Artist", systemImage: "music.microphone")
                }
            }
            if showAlbum, let album = track.album {
                Button { actions.open(.album(album)) } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
        switch placement {
        case .list(let siblings), .playlistItem(_, _, let siblings):
            // The siblings are the album's tracks or an already-filtered
            // list, so only a sibling's own veto can drop it; this track
            // stays whatever hides it, it was tapped.
            if playable {
                Section {
                    Button { actions.play(siblings, within: .album, from: track) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { actions.shuffle(siblings, within: .album, leading: track) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    Button { actions.enqueue([track], within: .track, next: true) } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button { actions.enqueue([track], within: .track, next: false) } label: {
                        Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                }
            }
        case .queued(let entry):
            Section {
                Button { actions.move(entry, next: true) } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { actions.move(entry, next: false) } label: {
                    Label("Move to End", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        case .playing:
            EmptyView()
        }
        // Hearts are read-only offline, and so are downloads. A track
        // under an album or artist pin reads as downloaded; removing it
        // narrows that pin to the rest.
        if !offline {
            Section {
                Button {
                    Task { await model.toggleFavorite(track) }
                } label: {
                    Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.slash" : "heart")
                }
                actions.downloadItems(
                    pinned: model.downloads.isPinned(track),
                    state: model.downloads.state(track),
                    download: { actions.download(track) },
                    remove: { model.downloads.unpin(track) }
                )
            }
        }
        // The playlist a row already sits in is left out of the list.
        if case .playlistItem(_, let playlist, _) = placement {
            AddToPlaylistMenu(model: model, excluding: playlist) { [track] }
        } else {
            AddToPlaylistMenu(model: model) { [track] }
        }
        ListenersMenu(model: model, scope: VetoScope(track: track))
        switch placement {
        case .queued(let entry):
            Section {
                Button(role: .destructive) { player.remove(entry) } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        case .playlistItem(let item, let playlist, _):
            // A smart playlist's items are the server's; a regular one's
            // go by their item id. The page reloads on the generation the
            // write bumps, so the row leaves when the server agrees.
            if !offline, !playlist.smart, item.playlistItemID != nil {
                Section {
                    Button(role: .destructive) {
                        Task { await model.remove(item, from: playlist) }
                    } label: {
                        Label("Remove from Playlist", systemImage: "text.badge.minus")
                    }
                }
            }
        case .list, .playing:
            EmptyView()
        }
    }
}

/// The Listeners submenu: one check per listener, on while they hear this
/// artist, album or track. Off is a veto, the same one the avatars on the
/// album and artist pages toggle. A listener whose wider veto already
/// covers the item (the album's artist, say) shows off and disabled with
/// the reason, since flipping it here couldn't change what they hear.
/// Works offline; the roster never leaves the phone.
struct ListenersMenu: View {
    let model: AppModel
    let scope: VetoScope

    var body: some View {
        Menu {
            Section("Who hears \(scope.veto.title)") {
                ForEach(model.roster.listeners) { listener in
                    if let covering = scope.covering(listener) {
                        Toggle(isOn: .constant(false)) {
                            Text(listener.name)
                            Text("All of \(covering.title) is hidden")
                        }
                        .disabled(true)
                    } else {
                        Toggle(isOn: Binding(
                            get: { !listener.vetoes(scope.veto.target) },
                            set: { _ in model.toggleVeto(scope.veto, for: listener.id) }
                        )) {
                            Text(listener.name)
                        }
                    }
                }
            }
        } label: {
            Label("Listeners", systemImage: "person.2")
        }
    }
}

/// The ··· at the trailing edge of a track row, opening the same menu a
/// long press does. Plain so a tap on it never reads as a tap on the row.
struct MoreButton<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }
}

extension View {
    /// A row's long press. The lifted preview is a copy of the row on the
    /// page's ground: the default is a snapshot with a clear background,
    /// which floats as bare text over whatever is behind it. `inset` pads
    /// a `List` row, whose insets aren't part of the view.
    func rowContextMenu<MenuItems: View>(inset: CGFloat = 0, @ViewBuilder _ menu: @escaping () -> MenuItems) -> some View {
        contextMenu { menu() } preview: {
            padding(.horizontal, inset)
                .background(Color.parchmentTop)
        }
    }
}

extension PlexTrack {
    /// The album this track is on, as far as the track knows it: enough
    /// to push the album page, which fetches the rest by rating key.
    var album: PlexAlbum? {
        guard let parentRatingKey, let parentTitle else { return nil }
        return PlexAlbum(
            ratingKey: parentRatingKey,
            title: parentTitle,
            parentRatingKey: grandparentRatingKey,
            parentTitle: grandparentTitle,
            year: nil,
            thumb: thumb
        )
    }
}
