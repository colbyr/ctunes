import PlexKit
import SwiftUI

/// Browse root: every album in the library, grouped under its artist. The
/// query comes from the floating search pill and matches either name.
struct MusicView: View {
    let model: AppModel
    let section: PlexSection
    @Binding var query: String
    @Binding var path: NavigationPath
    @Environment(AudioPlayer.self) private var player

    @State private var albums: [PlexAlbum] = []
    /// Fetched with the albums so the shuffle row can say how many tracks
    /// it would play; nil until the request lands.
    @State private var favorites: [PlexTrack]?
    @State private var loaded = false
    @State private var loadingFavorites = false
    @State private var noFavorites = false
    @State private var everyFavoriteHidden = false
    @State private var showingListeners = false

    private var hidden: Set<String> { model.roster.hiddenArtistKeys }
    private var groups: [ArtistGroup] {
        ArtistGroup.grouped(albums, matching: query, hiding: hidden)
    }
    /// Artists actually in this library that the active listeners hide, so
    /// the count under the chips doesn't include vetoes from another section.
    private var hiddenCount: Int {
        ArtistGroup.grouped(albums, matching: "").filter { hidden.contains($0.id) }.count
    }

    var body: some View {
        List {
            if !model.roster.listeners.isEmpty {
                Section {
                    ListenerChips(model: model)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                .listSectionSpacing(8)
            }
            if query.isEmpty {
                Section {
                    Button(action: shuffleFavorites) {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Shuffle Favorites")
                                    if let subtitle = favoritesSubtitle {
                                        Text(subtitle)
                                            .font(.caption).foregroundStyle(Color.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "heart.fill").foregroundStyle(.pink)
                            }
                            Spacer()
                            if loadingFavorites {
                                ProgressView()
                            } else {
                                Image(systemName: "shuffle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(loadingFavorites)
                }
            }
            ForEach(groups) { group in
                Section(group.name) {
                    // Tiles push onto the path by hand: a NavigationLink in a
                    // List row makes the whole row a link too, so one tap
                    // pushed two albums and back landed on the wrong one.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(group.albums) { album in
                            Button { path.append(album) } label: {
                                AlbumTile(model: model, album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listSectionSpacing(2)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        // Room to scroll the last row clear of the floating bottom pills.
        .contentMargins(.bottom, 72, for: .scrollContent)
        .overlay {
            if !loaded {
                ProgressView()
            } else if albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "square.stack")
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle(section.title)
        // What the active listeners hide, said once under the title.
        .navigationSubtitle(hiddenCount > 0
            ? "\(hiddenCount) artist\(hiddenCount == 1 ? "" : "s") hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name)))"
            : "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Listeners…", systemImage: "person.2") { showingListeners = true }
                    if model.sections.count > 1 {
                        Button("Change library") { model.clearSectionChoice() }
                    }
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            guard let library = model.library else { return }
            async let favoriteTracks = library.favoriteTracks(inSection: section.key)
            albums = (try? await library.albums(inSection: section.key)) ?? []
            loaded = true
            favorites = try? await favoriteTracks
            #if DEBUG
            if ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS_SHEET"] != nil {
                showingListeners = true
            }
            #endif
        }
        .alert("No favorites yet", isPresented: $noFavorites) {
            Button("OK") {}
        } message: {
            Text("Swipe a track left, or tap the heart in Now Playing, to favorite it.")
        }
        .alert("Nothing to shuffle", isPresented: $everyFavoriteHidden) {
            Button("OK") {}
        } message: {
            Text("Every favorite is by an artist hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name))).")
        }
        .sheet(isPresented: $showingListeners) {
            ListenersSheet(model: model, artists: ArtistGroup.grouped(albums, matching: ""))
        }
    }

    /// "32 tracks for you & Laura"; just the count with no listeners set up,
    /// just the listeners until the count arrives, nothing with neither.
    private var favoritesSubtitle: String? {
        let names = model.roster.active.map(\.name)
        let who = model.roster.listeners.isEmpty
            ? nil
            : "for " + (names.isEmpty ? "just you" : ListenerRoster.joinNames(["you"] + names))
        let count = favorites.map { allowed($0).count }
            .map { "\($0) track\($0 == 1 ? "" : "s")" }
        let parts = [count, who].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func allowed(_ tracks: [PlexTrack]) -> [PlexTrack] {
        tracks.filter { !hidden.contains($0.grandparentRatingKey ?? "") }
    }

    /// Every favorite track in the library, in a fresh random order each tap.
    /// Shuffling once at enqueue time is all this needs; the player has no
    /// shuffle mode of its own.
    private func shuffleFavorites() {
        guard let library = model.library, !loadingFavorites else { return }
        loadingFavorites = true
        Task {
            defer { loadingFavorites = false }
            // Fetched fresh rather than reusing the count's copy: hearts may
            // have been toggled since the screen loaded.
            let fetched = (try? await library.favoriteTracks(inSection: section.key)) ?? []
            favorites = fetched
            guard !fetched.isEmpty else {
                noFavorites = true
                return
            }
            let playable = allowed(fetched)
            guard !playable.isEmpty else {
                everyFavoriteHidden = true
                return
            }
            player.play(playable.shuffled(), startingAt: 0, library: library)
        }
    }
}

/// Who's in the car. The owner is always in; each listener toggles.
private struct ListenerChips: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Chip(active: true) {
                        OwnerAvatar()
                        Text("You")
                    }
                    ForEach(model.roster.listeners) { listener in
                        let active = model.roster.isActive(listener.id)
                        Button {
                            withAnimation(.snappy) { model.toggleListening(listener.id) }
                        } label: {
                            Chip(active: active) {
                                ListenerAvatar(listener: listener).opacity(active ? 1 : 0.45)
                                Text(listener.name)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(active ? "\(listener.name) is listening" : "\(listener.name) is not listening")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.vertical, 4)
    }

    private struct Chip<Content: View>: View {
        let active: Bool
        @ViewBuilder let content: Content

        var body: some View {
            HStack(spacing: 7) { content }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.secondary))
                .padding(.leading, 5)
                .padding(.trailing, 14)
                .frame(height: 34)
                .background(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.background), in: .capsule)
                .contentShape(.capsule)
        }
    }
}

private struct AlbumTile: View {
    let model: AppModel
    let album: PlexAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(url: model.library?.artworkURL(album.thumb), size: nil, corner: 8)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.footnote)
                    .lineLimit(1)
                Text(album.year.map(String.init) ?? "—")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// One artist's albums. Grouping happens on the client because the flat
/// section query is a single request; asking per artist would be one per row.
struct ArtistGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let albums: [PlexAlbum]

    /// Groups albums by artist, drops hidden artists, and applies the search
    /// text. An artist-name
    /// match keeps the whole group; otherwise only the matching albums remain,
    /// so searching a title still shows who made it.
    static func grouped(
        _ albums: [PlexAlbum],
        matching query: String,
        hiding hidden: Set<String> = []
    ) -> [ArtistGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

        var order: [String] = []
        var byArtist: [String: [PlexAlbum]] = [:]
        for album in albums {
            let key = album.parentRatingKey ?? album.parentTitle ?? album.ratingKey
            if hidden.contains(key) { continue }
            if byArtist[key] == nil { order.append(key) }
            byArtist[key, default: []].append(album)
        }

        return order.compactMap { key in
            let albums = byArtist[key] ?? []
            let name = albums.first?.parentTitle ?? "Unknown Artist"
            guard !needle.isEmpty else {
                return ArtistGroup(id: key, name: name, albums: newestFirst(albums))
            }
            if name.lowercased().contains(needle) {
                return ArtistGroup(id: key, name: name, albums: newestFirst(albums))
            }
            let matches = albums.filter { $0.title.lowercased().contains(needle) }
            return matches.isEmpty
                ? nil
                : ArtistGroup(id: key, name: name, albums: newestFirst(matches))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Newest release first. Albums the server has no year for sort to the
    /// top, ahead of the dated ones.
    private static func newestFirst(_ albums: [PlexAlbum]) -> [PlexAlbum] {
        albums.sorted { lhs, rhs in
            switch (lhs.year, rhs.year) {
            case let (l?, r?) where l != r: return l > r
            case (nil, .some): return true
            case (.some, nil): return false
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }
}
