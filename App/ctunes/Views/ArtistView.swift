import PlexKit
import SwiftUI

/// Pushed onto the navigation path to open an artist's page. Carries the
/// title so the bar reads right before anything loads; an album only knows
/// its artist's key and name, never the portrait.
struct ArtistRoute: Hashable {
    let ratingKey: String
    let title: String
}

/// One artist: portrait, who on the roster hears them, play and shuffle
/// over everything of theirs, then the listener chips and the arrange
/// button over their albums, newest release first until arranged
/// otherwise. Reached from the artist name in Now Playing, on an album,
/// or from the Artists view.
struct ArtistView: View {
    let model: AppModel
    let section: PlexSection
    let route: ArtistRoute
    @Binding var path: NavigationPath
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var albums: [PlexAlbum] = []
    /// Every artist in the section as the listener sheet wants them, for
    /// the chips; empty until the section's albums land.
    @State private var libraryArtists: [AlbumGroup] = []
    /// The portrait, looked up in the section's artist list; nil until it
    /// lands or when the artist has none, when the first cover stands in.
    @State private var portrait: String?
    @State private var loaded = false
    @State private var loading: MixMode?
    /// Whether the action cards are on screen; once they scroll away the
    /// toolbar takes over with icon-only copies.
    @State private var actionsVisible = true
    @State private var scrollPosition = ScrollPosition()
    @State private var nothingToPlay = false
    /// The page's own sort, release order by default; the layout is the
    /// app's. No play history is fetched here, so On Rotation reads the
    /// server's play counts.
    @AppStorage("artistView") private var view: AlbumView = .artist
    @AppStorage(BrowseLayout.key) private var layout: BrowseLayout = .grid

    private var offline: Bool { model.library?.isOffline ?? false }
    private var hidden: VetoSet { model.roster.hidden }
    private var scope: VetoScope { VetoScope(artistKey: route.ratingKey, title: route.title) }
    private var artworkURL: URL? {
        model.library?.artworkURL(portrait ?? albums.first?.thumb, size: 600)
    }

    private static let margin: CGFloat = 16
    /// Same floor as the album browser: wider tiles on a regular width.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 100), spacing: 12, alignment: .top)]
    }
    /// Nothing hidden: an album a listening rider vetoed stays on the
    /// page, dimmed, since the page was opened on purpose.
    private var groups: [AlbumGroup] {
        AlbumBrowse.groups(albums, view: view, scope: .discography)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                Rectangle()
                    .fill(Color.divider)
                    .frame(height: 1)
                    .padding(.init(top: 8, leading: Self.margin, bottom: 0, trailing: Self.margin))
                AlbumBrowserControls(model: model, artists: libraryArtists, view: $view, layout: $layout, scope: .discography)
                    .padding(.top, 16)
                HiddenLine(model: model, count: hiddenCount)
                    .padding(.init(top: 6, leading: Self.margin, bottom: 6, trailing: Self.margin))
                ForEach(groups) { group in
                    Section {
                        items(group.albums)
                            .padding(.init(top: group.name.isEmpty ? 14 : 2, leading: Self.margin, bottom: 0, trailing: Self.margin))
                    } header: {
                        if !group.name.isEmpty {
                            AlbumGroupHeader(group: group)
                                .padding(.leading, Self.margin)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                    }
                }
            }
        }
        .artworkBackground(artworkURL)
        .scrollPosition($scrollPosition)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Past the portrait, the avatars and the cards.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 280
        } action: { _, scrolledPast in
            withAnimation(.snappy) { actionsVisible = !scrolledPast }
        }
        .contentMargins(.bottom, 84, for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            } else if albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "square.stack")
            }
        }
        .navigationTitle(route.title)
        .navigationSubtitle(loaded ? "\(albums.count) album\(albums.count == 1 ? "" : "s")" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ArtistMenu(model: model, ratingKey: route.ratingKey, title: route.title, showArtist: false, showPlayback: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            // The cards' actions follow you down the grid as icons.
            if !actionsVisible {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Mix Albums", systemImage: "square.stack") { play(.playAlbums) }
                        .disabled(albums.isEmpty || loading != nil)
                    Button("Shuffle", systemImage: "shuffle") { play(.shuffleTracks) }
                        .disabled(albums.isEmpty || loading != nil)
                }
            }
        }
        // Keyed on the generation so going offline, or coming back, reloads
        // from whichever library is current.
        .task(id: model.libraryGeneration) {
            await load()
            #if DEBUG
            if let y = ProcessInfo.processInfo.environment["CTUNES_DEV_SCROLL"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(1))
                scrollPosition.scrollTo(y: y)
            }
            #endif
        }
        .refreshable { await load() }
        .alert("Nothing to play", isPresented: $nothingToPlay) {
            Button("OK") {}
        } message: {
            Text(offline ? "None of this artist's tracks are downloaded." : "This artist has no tracks to play.")
        }
    }

    /// Every album is theirs, so no Go to Artist in the menu. An album a
    /// listening rider vetoed stays on the page, dimmed.
    @ViewBuilder private func items(_ albums: [PlexAlbum]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(albums) { album in
                    Button { path.append(album) } label: {
                        AlbumTile(model: model, album: album, showArtist: false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { AlbumMenu(model: model, album: album, showArtist: false) }
                    .modifier(HiddenDim(hidden: hidden.hides(album, within: .artist)))
                }
            }
        case .list:
            BrowseList(items: albums) { album in
                AlbumRow(model: model, album: album, showArtist: false) { path.append(album) } menu: {
                    AlbumMenu(model: model, album: album, showArtist: false)
                }
                .modifier(HiddenDim(hidden: hidden.hides(album, within: .artist)))
            }
        }
    }

    private struct HiddenDim: ViewModifier {
        let hidden: Bool

        func body(content: Content) -> some View {
            content
                .opacity(hidden ? 0.4 : 1)
                .accessibilityHint(hidden ? "Hidden for a listener" : "")
        }
    }

    /// What the active listeners veto among these albums. They stay on
    /// the page dimmed, so the line says how many rather than what went.
    private var hiddenCount: HiddenCount {
        HiddenCount(albums: albums.filter { hidden.hides($0, within: .artist) }.count)
    }

    /// The fetch: on appear, on a library swap, and on pull to refresh.
    /// The section's albums come too, for the listener sheet the chips
    /// open, which lists every artist with an album count.
    private func load() async {
        guard let library = model.library else { return }
        async let artists = library.artists(inSection: section.key)
        async let sectionAlbums = library.albums(inSection: section.key)
        do {
            albums = try await library.albums(forArtist: route.ratingKey, inSection: section.key)
        } catch {
            await model.connectionLost(error)
            if model.library?.isOffline != true { albums = [] }
            return
        }
        loaded = true
        portrait = (try? await artists)?.first { $0.ratingKey == route.ratingKey }?.thumb
        libraryArtists = AlbumBrowse.groups((try? await sectionAlbums) ?? [], view: .artist)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Artwork(url: artworkURL, size: 200, corner: 100)
                .clipShape(.circle)
                .artworkShadow()
                // The badge the tiles carry, or an arrow that downloads the
                // artist, pulled in toward the rim where a circle has room.
                .overlay(alignment: .bottomTrailing) {
                    DownloadOverlay(state: model.downloads.state(artist: route.ratingKey), offline: offline) {
                        Task { await model.downloadArtist(key: route.ratingKey, title: route.title) }
                    } remove: {
                        model.downloads.unpinArtist(route.ratingKey)
                    }
                    .padding(8)
                }
                .contextMenu { ArtistMenu(model: model, ratingKey: route.ratingKey, title: route.title, showArtist: false, showPlayback: false) }
                .padding(.bottom, 8)
            ListenerVetoes(model: model, scope: scope)
            HiddenRightNowLabel(model: model, scope: scope)
            HStack(spacing: 12) {
                MixActionCard(systemImage: "square.stack", title: "Mix Albums", subtitle: nil,
                              enabled: !albums.isEmpty && loading == nil, loading: loading == .playAlbums, tint: nil) { play(.playAlbums) }
                MixActionCard(systemImage: "shuffle", title: "Shuffle", subtitle: nil,
                              enabled: !albums.isEmpty && loading == nil, loading: loading == .shuffleTracks, tint: nil) { play(.shuffleTracks) }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Every track of theirs in one request, then ordered the way the mix
    /// builder does it: whole albums in a shuffled order, or every track
    /// spread-shuffled.
    private func play(_ mode: MixMode) {
        guard let library = model.library, loading == nil else { return }
        loading = mode
        Task {
            defer { loading = nil }
            let fetched = (try? await library.tracks(forArtist: route.ratingKey, inSection: section.key)) ?? []
            // The artist plays even when hidden whole; their vetoed
            // albums and tracks are skipped.
            let playable = fetched.filter { !hidden.hides($0, within: .artist) && (!offline || model.downloads.isAvailable($0)) }
            guard !playable.isEmpty else {
                nothingToPlay = true
                return
            }
            let ordered = switch mode {
            case .shuffleTracks: playable.spreadShuffled()
            case .playAlbums: playable.albumShuffled()
            }
            player.play(ordered, startingAt: 0, library: library)
            nowPlaying.isShown = true
        }
    }
}
