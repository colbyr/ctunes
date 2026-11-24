import PlexKit
import SwiftUI

/// How Apple Music reads on screen (COL-117, `notes/apple-music.md`).
///
/// **The library is home and carries no mark; only what comes from Apple
/// Music is marked**, with the one glyph below, wherever it appears: a
/// search row, an artist page's shelf, Up Next, the mini player, Now
/// Playing. A page that is all Apple Music (an album's) says so once, in
/// its header, rather than on every row.
enum AppleMusicMark {
    static let symbol = "applelogo"

    /// The glyph, to lead a line of text: `Text("\(AppleMusicMark.image) 1997")`.
    static var image: Image { Image(systemName: symbol) }

    /// A subtitle led by the mark, one `Text` so it truncates as one line.
    static func text(_ line: String) -> Text {
        Text("\(image) \(line)")
    }
}

/// "Apple Music" spelled out under an album's art, with what the page
/// knows beside it: the header's one statement of where this is from.
struct AppleMusicLabel: View {
    var detail: String? = nil

    var body: some View {
        Text("\(AppleMusicMark.image) Music\(detail.map { " · \($0)" } ?? "")")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: .capsule)
            .accessibilityLabel("From Apple Music\(detail.map { ", \($0)" } ?? "")")
    }
}

/// The header over a group of Apple Music results: the name, and under it
/// why they are there.
struct AppleMusicGroupHeader: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AlbumGroupHeader(name: title)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Where the heart sits, for a song with no heart to give: a heart is a
/// rating on the Plex server, which has no such track. The slot says
/// where the song is from instead, and opens it in the Music app, where
/// it can be loved or added to a library.
struct AppleMusicSourceButton: View {
    let track: PlexTrack
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            Section("Playing from Apple Music") {
                OpenInMusicButton(key: track.ratingKey)
            }
        } label: {
            AppleMusicMark.image
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("From Apple Music")
    }
}

struct OpenInMusicButton: View {
    /// A song's or an album's key.
    let key: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = AppleMusic.shared.musicAppURL(for: key) {
            Button { openURL(url) } label: {
                Label("Open in Music", systemImage: "arrow.up.forward.app")
            }
        }
    }
}

/// An Apple Music album's menu, in the order every item menu keeps:
/// playback, then Go to, then the way out to the Music app. No Create
/// Mix, Download or Listeners: a pick, a pin and a veto are all the
/// library's.
struct AppleMusicAlbumMenu: View {
    let model: AppModel
    let album: PlexAlbum
    /// The page's tracks when it has them; nil fetches on demand.
    var tracks: [PlexTrack]? = nil
    /// Off on the album's own page, which has the cards.
    var showAlbum = true
    var showArtist = true
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(LibraryNavigator.self) private var navigator

    var body: some View {
        let actions = LibraryActions(model: model, player: player, nowPlaying: nowPlaying, navigator: navigator)
        if AppleMusic.shared.canPlay {
            Section {
                if showAlbum {
                    Button { Task { actions.play(await fetch(), within: .album) } } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { Task { actions.shuffle(await fetch(), within: .album) } } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                Button { Task { actions.enqueue(await fetch(), within: .album, next: true) } } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { Task { actions.enqueue(await fetch(), within: .album, next: false) } } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        Section {
            if showAlbum {
                Button { actions.open(.album(album)) } label: {
                    Label("Go to Album", systemImage: MixPickKind.album.symbol)
                }
            }
            // Only an artist the library has: theirs is the page there is.
            if showArtist, let key = album.parentRatingKey, let artist = album.parentTitle {
                Button { actions.open(.artist(ArtistRoute(ratingKey: key, title: artist))) } label: {
                    Label("Go to Artist", systemImage: MixPickKind.artist.symbol)
                }
            }
        }
        Section {
            OpenInMusicButton(key: album.ratingKey)
        }
    }

    private func fetch() async -> [PlexTrack] {
        if let tracks, !tracks.isEmpty { return tracks }
        return (try? await AppleMusic.shared.page(for: album, artists: AppRuntime.shared.catalog.artists).tracks) ?? []
    }
}

/// The artist page's shelf: albums of theirs the library doesn't have,
/// under the library's own, in the page's layout. Nothing at all when
/// Apple Music is off or has none.
struct AppleMusicShelf: View {
    let model: AppModel
    let albums: [PlexAlbum]
    let layout: BrowseLayout
    let columns: [GridItem]
    @Binding var path: NavigationPath

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                AppleMusicGroupHeader(title: "More on Apple Music",
                                      caption: "Albums that aren't in your library")
                switch layout {
                case .grid:
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(albums) { album in
                            Button { path.append(album) } label: {
                                AlbumTile(model: model, album: album, showArtist: false)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { AppleMusicAlbumMenu(model: model, album: album, showArtist: false) }
                        }
                    }
                case .list:
                    BrowseList(items: albums) { album in
                        AlbumRow(model: model, album: album, showArtist: false) { path.append(album) } menu: {
                            AppleMusicAlbumMenu(model: model, album: album, showArtist: false)
                        }
                    }
                }
            }
        }
    }
}

/// Settings → Apple Music: the switch, what it does, and what state the
/// account is in.
struct AppleMusicSettingsView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabling = false

    private var music: AppleMusic { AppleMusic.shared }

    var body: some View {
        List {
            Section {
                Toggle("Fill Gaps from Apple Music", isOn: Binding(
                    get: { music.isEnabled },
                    set: { on in
                        guard on else { return music.isEnabled = false }
                        enabling = true
                        Task {
                            await music.enable()
                            enabling = false
                        }
                    }
                ))
                .tint(Color.amber)
                .disabled(enabling)
                if music.isEnabled {
                    LabeledContent("Status") {
                        Text(Self.summary(music.status))
                            .foregroundStyle(music.status == .ready ? .secondary : Color.accentText)
                    }
                    if music.status == .denied {
                        Button("Allow in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            } footer: {
                Text(footer)
            }
            Section {
                bullet("magnifyingglass", "Search shows songs and albums you don't have, under your library's results.")
                bullet("person", "An artist's page lists their albums that aren't in your library.")
                bullet(AppleMusicMark.symbol, "Anything from Apple Music carries this mark. Your library is never marked.")
                bullet("list.bullet", "Apple Music songs sit in the queue beside your own: Play Next, Add to Queue, shuffle and repeat all work across both.")
                bullet("heart.slash", "They can't be favorited, downloaded or added to a Plex playlist, and they need a connection.")
            } header: {
                Text("How it works")
            }
            #if DEBUG
            Section("Debug") {
                NavigationLink("Playback Spike") { AppleMusicSpikeView(model: model) }
            }
            #endif
        }
        .settingsBackground()
        .navigationTitle("Apple Music")
        .navigationBarTitleDisplayMode(.inline)
        // Access is changed in the Settings app; look again on the way back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { music.refresh() }
        }
    }

    private var footer: String {
        switch music.status {
        case .off: "Your Plex library stays the whole app. Switch this on to fill what it's missing from Apple Music."
        case .needsAccess: "Allow access to Apple Music to finish switching this on."
        case .denied: "Disc Changer isn't allowed to use Apple Music on this device."
        case .noSubscription: "This Apple Account has no Apple Music subscription, so songs can be found but not played."
        case .ready: "Only what your library doesn't have is shown."
        }
    }

    static func summary(_ status: AppleMusic.Status) -> String {
        switch status {
        case .off: "Off"
        case .needsAccess: "Needs access"
        case .denied: "Not allowed"
        case .noSubscription: "No subscription"
        case .ready: "On"
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}
