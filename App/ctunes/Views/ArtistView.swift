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
/// over everything of theirs, and their albums newest first. Reached from
/// the artist name in Now Playing, on an album, or from the Artists view.
struct ArtistView: View {
    let model: AppModel
    let section: PlexSection
    let route: ArtistRoute
    @Binding var path: NavigationPath
    @Environment(AudioPlayer.self) private var player
    @Environment(NowPlayingPresentation.self) private var nowPlaying
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var albums: [PlexAlbum] = []
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

    private var offline: Bool { model.library?.isOffline ?? false }
    private var artworkURL: URL? {
        model.library?.artworkURL(portrait ?? albums.first?.thumb, size: 600)
    }

    private static let margin: CGFloat = 16
    /// Same floor as the album browser: wider tiles on a regular width.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 100), spacing: 12, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.init(top: 8, leading: Self.margin, bottom: 16, trailing: Self.margin))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(albums) { album in
                        Button { path.append(album) } label: {
                            AlbumTile(model: model, album: album, showArtist: false)
                        }
                        .buttonStyle(.plain)
                        // Every tile here is theirs, so no Go to Artist.
                        .contextMenu { AlbumMenu(model: model, album: album, showArtist: false) }
                    }
                }
                .padding(.init(top: 8, leading: Self.margin, bottom: 0, trailing: Self.margin))
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
                    Button("Mix Albums", systemImage: "square.on.square") { play(.playAlbums) }
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

    /// The fetch: on appear, on a library swap, and on pull to refresh.
    private func load() async {
        guard let library = model.library else { return }
        async let artists = library.artists(inSection: section.key)
        do {
            let fetched = try await library.albums(forArtist: route.ratingKey, inSection: section.key)
            albums = AlbumView.artist.sorted(fetched)
        } catch {
            await model.connectionLost(error)
            if model.library?.isOffline != true { albums = [] }
            return
        }
        loaded = true
        portrait = (try? await artists)?.first { $0.ratingKey == route.ratingKey }?.thumb
    }

    private var header: some View {
        VStack(spacing: 12) {
            Artwork(url: artworkURL, size: 200, corner: 100)
                .clipShape(.circle)
                .artworkShadow()
                .contextMenu { ArtistMenu(model: model, ratingKey: route.ratingKey, title: route.title, showArtist: false, showPlayback: false) }
                .padding(.bottom, 8)
            ListenerVetoes(model: model, artistKey: route.ratingKey)
            HiddenRightNowLabel(model: model, artistKey: route.ratingKey)
            HStack(spacing: 12) {
                MixActionCard(systemImage: "square.on.square", title: "Mix Albums", subtitle: nil,
                              enabled: !albums.isEmpty && loading == nil, loading: loading == .playAlbums, tint: .accentText) { play(.playAlbums) }
                MixActionCard(systemImage: "shuffle", title: "Shuffle", subtitle: nil,
                              enabled: !albums.isEmpty && loading == nil, loading: loading == .shuffleTracks, tint: .accentText) { play(.shuffleTracks) }
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
            let playable = offline ? fetched.filter { model.downloads.isAvailable($0) } : fetched
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
