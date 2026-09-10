import PlexKit
import SwiftUI

/// Browse root. Shows the chosen music library, or asks which one to use when
/// the server has more than one and nothing has been picked yet.
struct LibraryView: View {
    let model: AppModel
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var searching = false
    /// True while a mix builder is on top of the stack; the search pill then
    /// filters the builder's pool instead of popping back to the root.
    @State private var buildingMix = false
    @State private var nowPlaying = NowPlayingPresentation()
    @Environment(AudioPlayer.self) private var player
    /// Compact is a phone, where Now Playing covers the screen with its
    /// header scrolling; regular but too narrow for the column (an iPad in
    /// portrait, a small Mac window) covers it with a title bar instead.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The window's width, measured rather than read off the size class:
    /// see `NowPlayingPresentation.isColumn`.
    @State private var width: CGFloat = 0

    /// Narrower than this and Now Playing is a presentation: the phone
    /// layout. An iPad is a column in landscape and a cover in portrait,
    /// where a column would leave two tiles across.
    private static let columnThreshold: CGFloat = 960
    /// A share of the window rather than a fixed inspector width, so the
    /// column grows with the window instead of staying a strip beside an
    /// ever wider grid.
    private var columnWidth: CGFloat { min(max(width * 0.36, 360), 560) }

    /// The cover while the window is narrow.
    private var presented: Binding<Bool> {
        Binding(
            get: { nowPlaying.isShown && !nowPlaying.isColumn },
            set: { nowPlaying.isShown = $0 }
        )
    }

    var body: some View {
        // Now Playing's one host: a trailing column beside the stack in a
        // wide window, always there, and a presentation over the stack in
        // a narrow one. Not `.inspector`, which follows the size class: on
        // the Mac that only turns compact a hair above the window's minimum
        // width, so the column stayed however small the window got, and
        // its width was capped well under what a wide window can afford.
        HStack(spacing: 0) {
            stack
            if nowPlaying.isColumn {
                Rectangle()
                    .fill(Color.divider)
                    .frame(width: 1)
                    .ignoresSafeArea()
                NowPlayingView(model: model, style: .column)
                    .frame(width: columnWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        // Chrome is ink, not amber: the back chevron, the toolbar buttons.
        // Amber is reserved for what acts, and those set it by hand.
        .tint(Color.ink)
        .animation(.snappy, value: nowPlaying.isColumn)
        .environment(nowPlaying)
        // The cover is handed the observables by hand. When a Mac window
        // drags across the compact/regular boundary UIKit re-hosts the
        // open presentation, and that pass evaluates the content without
        // the environment it inherited from above: "No Observable object
        // of type AudioPlayer found", a trap, at 730pt every time.
        .fullScreenCover(isPresented: presented) {
            NowPlayingView(model: model, style: sizeClass == .compact ? .phone : .fullScreen)
                .environment(player)
                .environment(nowPlaying)
        }
        // An artist tapped in Now Playing: the cover has closed itself (or
        // the column stays), and the page goes onto the stack behind it.
        .onChange(of: nowPlaying.requestedArtist) { _, route in
            guard let route else { return }
            path.append(route)
            nowPlaying.requestedArtist = nil
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            self.width = width
            let column = width >= Self.columnThreshold
            guard column != nowPlaying.isColumn else { return }
            nowPlaying.isColumn = column
            // Crossing either way closes the presentation: into the column
            // it is redundant, out of it the column is gone and the stack
            // should be what's left, not a cover over it.
            nowPlaying.isShown = false
        }
        // Results live on the root, so opening search from deeper in the
        // stack pops back to it. Pushing an album folds the pill back to its
        // icon but keeps the filter, so popping returns to the same results.
        .onChange(of: searching) { _, active in
            if active && !path.isEmpty && !buildingMix { path = NavigationPath() }
        }
        .onChange(of: path.isEmpty) { _, atRoot in
            if !atRoot { searching = false }
        }
        // A builder's query filters its pool only; popping back to the root
        // shouldn't leave the root showing results for it.
        .onChange(of: buildingMix) { _, building in
            if !building {
                query = ""
                searching = false
            }
        }
        .task {
            if let album = Self.developmentAlbum {
                path.append(album)
            }
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_ARTIST"], !raw.isEmpty {
                let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                path.append(ArtistRoute(ratingKey: parts[0], title: parts.count > 1 ? parts[1] : "Artist"))
            }
            if let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_MIX"],
               let kind = MixKind(rawValue: String(raw.prefix { $0 != ":" })) {
                path.append(kind)
            }
            if ProcessInfo.processInfo.environment["CTUNES_DEV_FAVORITES"] == "1" {
                path.append(FavoritesRoute())
            }
            if let seed = ProcessInfo.processInfo.environment["CTUNES_DEV_SEARCH"], !seed.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                searching = true
                if seed != "1" { query = seed }
            }
            #endif
        }
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            Group {
                if let section = model.selectedSection {
                    // Keyed on the section so switching libraries from
                    // Settings starts the screen over instead of leaving the
                    // old albums under the new title.
                    MusicView(model: model, section: section, query: $query, path: $path)
                        .id(section.key)
                } else {
                    SectionPicker(model: model)
                }
            }
            // Declared at the stack root so a seeded path can reach it.
            .navigationDestination(for: PlexAlbum.self) { album in
                TracksView(model: model, album: album, path: $path)
            }
            .navigationDestination(for: ArtistRoute.self) { route in
                if let section = model.selectedSection {
                    ArtistView(model: model, section: section, route: route, path: $path)
                }
            }
            .navigationDestination(for: MixKind.self) { kind in
                if let section = model.selectedSection {
                    MixBuilderView(model: model, section: section, kind: kind, query: $query, building: $buildingMix)
                }
            }
            .navigationDestination(for: FavoritesRoute.self) { _ in
                if let section = model.selectedSection {
                    FavoritesView(model: model, section: section)
                }
            }
        }
        // Attached to the stack, not to its root view: on the root view the
        // inset is replaced along with the content on every push, so the
        // mini player vanishes as soon as you navigate anywhere.
        .safeAreaInset(edge: .bottom) {
            BottomBar(model: model, query: $query, searching: $searching)
        }
        // The bar lifts itself from the keyboard's frame notification.
        // SwiftUI's own avoidance is applied to whichever screen is on top
        // when the keyboard rises, so a search opened from an album page
        // popped with the bar still under the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// Debug-only deep link so the deeper screens can be driven in a
    /// simulator, where there's no way to tap through. Pushes onto the stack
    /// rather than replacing the root, so navigation behaves as it really does.
    static var developmentAlbum: PlexAlbum? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_ALBUM"],
              !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 3).map(String.init)
        return PlexAlbum(
            ratingKey: parts[0],
            title: parts.count > 1 ? parts[1] : "Album",
            parentRatingKey: parts.count > 3 ? parts[3] : nil,
            parentTitle: parts.count > 2 ? parts[2] : nil,
            year: nil,
            thumb: nil
        )
        #else
        return nil
        #endif
    }
}

private struct SectionPicker: View {
    let model: AppModel

    var body: some View {
        List(model.sections) { section in
            Button {
                model.selectSection(section)
            } label: {
                Label(section.title, systemImage: "music.note.list")
            }
        }
        .parchment()
        .navigationTitle("Choose a library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sign out") { Task { await model.signOut() } }
            }
        }
    }
}
