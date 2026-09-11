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

    func open(_ route: LibraryRoute) { requested = route }
}

enum LibraryRoute: Hashable {
    case artist(ArtistRoute)
    case album(PlexAlbum)
}

/// The work behind the menu items. Built by each menu from the environment
/// rather than held anywhere: it is a handful of references, and the
/// menus are the only callers.
@MainActor
private struct LibraryActions {
    let model: AppModel
    let player: AudioPlayer
    let nowPlaying: NowPlayingPresentation
    let navigator: LibraryNavigator

    var offline: Bool { model.library?.isOffline ?? false }

    /// Offline, only a track with a file can enter the queue.
    func playable(_ tracks: [PlexTrack]) -> [PlexTrack] {
        offline ? tracks.filter { model.downloads.isAvailable($0) } : tracks
    }

    /// The whole list from the top, or from one of its tracks. Nothing
    /// to play is a notice, never silence.
    func play(_ tracks: [PlexTrack], from track: PlexTrack? = nil) {
        guard let library = model.library else { return }
        let tracks = playable(tracks)
        guard !tracks.isEmpty else { return nothingToPlay() }
        let start = track.flatMap { track in tracks.firstIndex { $0.id == track.id } } ?? 0
        player.play(tracks, startingAt: start, library: library)
        nowPlaying.isShown = true
    }

    /// Every shuffle in the app is the spread shuffle. With a leading
    /// track it plays first and the rest of the list follows shuffled.
    func shuffle(_ tracks: [PlexTrack], leading track: PlexTrack? = nil) {
        guard let track else { return play(tracks.spreadShuffled()) }
        let rest = tracks.filter { $0.id != track.id }.spreadShuffled()
        play([track] + rest)
    }

    /// Whole albums front to back, the album order shuffled, the way the
    /// artist page's Mix Albums does it.
    func mixAlbums(_ tracks: [PlexTrack]) {
        play(tracks.albumShuffled())
    }

    func enqueue(_ tracks: [PlexTrack], next: Bool) {
        guard let library = model.library else { return }
        let tracks = playable(tracks)
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

    /// Every track of an album, from the page that has them or one fetch.
    /// A fetch failure runs the usual rediscovery and yields nothing.
    func tracks(of album: PlexAlbum, known: [PlexTrack]?) async -> [PlexTrack] {
        if let known { return known }
        guard let library = model.library else { return [] }
        do {
            let tracks = try await library.tracks(inAlbum: album.ratingKey)
            await model.rememberTracks(tracks, inAlbum: album)
            return tracks
        } catch {
            await model.connectionLost(error)
            return []
        }
    }

    func tracks(ofArtist key: String) async -> [PlexTrack] {
        guard let library = model.library, let section = model.selectedSection else { return [] }
        do {
            return try await library.tracks(forArtist: key, inSection: section.key)
        } catch {
            await model.connectionLost(error)
            return []
        }
    }

    func download(_ album: PlexAlbum, known: [PlexTrack]?) async {
        guard let library = model.library, !library.isOffline else { return }
        let tracks = await tracks(of: album, known: known)
        guard !tracks.isEmpty else { return }
        model.downloads.pin(album, tracks: tracks, section: model.selectedSection?.key ?? "", library: library)
    }

    /// Navigation from inside the Now Playing cover closes it first; the
    /// column stays where it is.
    func open(_ route: LibraryRoute) {
        if nowPlaying.isShown, !nowPlaying.isColumn { nowPlaying.isShown = false }
        navigator.open(route)
    }

    private func nothingToPlay() {
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
                    Task { actions.mixAlbums(await actions.tracks(ofArtist: ratingKey)) }
                } label: {
                    Label("Mix Albums", systemImage: "square.on.square")
                }
                Button {
                    Task { actions.shuffle(await actions.tracks(ofArtist: ratingKey)) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }
        }
        ListenersMenu(model: model, artistKey: ratingKey, artist: title)
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
                        Task { actions.play(await actions.tracks(of: album, known: tracks)) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        Task { actions.shuffle(await actions.tracks(of: album, known: tracks)) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                Button {
                    Task { actions.enqueue(await actions.tracks(of: album, known: tracks), next: true) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { actions.enqueue(await actions.tracks(of: album, known: tracks), next: false) }
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        if !offline {
            Section {
                switch model.downloads.status(album) {
                case nil:
                    Button {
                        Task { await actions.download(album, known: tracks) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                case let status? where status.isStalled:
                    Button {
                        model.downloads.retry { await model.resumeDownloads() }
                    } label: {
                        Label("Retry Download", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    Button(role: .destructive) { model.downloads.unpin(album) } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                case .pending?:
                    Button(role: .destructive) { model.downloads.unpin(album) } label: {
                        Label("Stop Download", systemImage: "stop.circle")
                    }
                default:
                    Button(role: .destructive) { model.downloads.unpin(album) } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                }
            }
        }
        if let key = album.parentRatingKey {
            ListenersMenu(model: model, artistKey: key, artist: album.parentTitle)
        }
    }
}

/// Where a track row sits, which decides what its menu can offer.
enum TrackPlacement {
    /// A row in a list that can be played from that row: the album page,
    /// Favorites. `siblings` is the list, in its order.
    case list(siblings: [PlexTrack])
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
        case .list(let siblings):
            if playable {
                Section {
                    Button { actions.play(siblings, from: track) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { actions.shuffle(siblings, leading: track) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    Button { actions.enqueue([track], next: true) } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button { actions.enqueue([track], next: false) } label: {
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
        // Hearts are read-only offline.
        if !offline {
            Section {
                Button {
                    Task { await model.toggleFavorite(track) }
                } label: {
                    Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.slash" : "heart")
                }
            }
        }
        if let key = track.grandparentRatingKey {
            ListenersMenu(model: model, artistKey: key, artist: track.grandparentTitle)
        }
        if case .queued(let entry) = placement {
            Section {
                Button(role: .destructive) { player.remove(entry) } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        }
    }
}

/// The Listeners submenu: one check per listener, on while they hear this
/// artist. Off is a veto, the same one the avatars on the album and artist
/// pages toggle. Works offline; the roster never leaves the phone.
struct ListenersMenu: View {
    let model: AppModel
    let artistKey: String
    let artist: String?

    var body: some View {
        Menu {
            Section(artist.map { "Who hears \($0)" } ?? "Who hears this artist") {
                ForEach(model.roster.listeners) { listener in
                    Toggle(isOn: Binding(
                        get: { !listener.vetoedArtistKeys.contains(artistKey) },
                        set: { _ in model.toggleVeto(artistKey: artistKey, for: listener.id) }
                    )) {
                        Text(listener.name)
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
