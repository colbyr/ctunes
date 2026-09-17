import PlexKit
import SwiftUI

// MARK: - The card

/// One saved mix as it sits at the top of the Music screen: a raised card
/// so it reads as an action rather than another row. The body plays; the
/// chevron past the rule opens the thing itself for a single pick, and
/// the mix builder on the picks otherwise. A long press edits or removes.
struct ShortcutCard: View {
    let model: AppModel
    let mix: SavedMix
    let subtitle: String?
    let loading: Bool
    let action: () -> Void
    let open: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    MixArt(model: model, picks: mix.picks, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mix.title).font(.headline).lineLimit(1)
                        if let subtitle {
                            // One line: a longer listener list wrapping made
                            // the card grow as listeners toggled.
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if loading {
                        ProgressView()
                    } else {
                        Image(systemName: mix.style.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(mix.accent)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
            }
            .disabled(loading)
            Rectangle()
                .fill(Color.divider)
                .frame(width: 1)
                .padding(.vertical, 12)
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .accessibilityLabel(mix.picks.count == 1 ? "Open \(mix.name)" : "Edit \(mix.name)")
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 24)
        .contextMenu {
            Button(action: edit) {
                Label("Edit in Mix Builder", systemImage: "slider.horizontal.3")
            }
            Button(role: .destructive) { model.removeShortcut(mix.id) } label: {
                Label("Remove Shortcut", systemImage: "bookmark.slash")
            }
        }
    }
}

/// What stands for a mix: its one pick's art (the heart disc for the
/// favorites, a round portrait for an artist, the cover or composite
/// otherwise), and for several picks or none the mix builder's own
/// glyph. Shared by the card and the Settings rows.
struct MixArt: View {
    let model: AppModel
    let picks: [MixPick]
    let size: CGFloat

    var body: some View {
        if picks.count == 1 {
            PickArt(model: model, pick: picks[0], size: size)
        } else {
            Image(systemName: "square.stack")
                .font(size >= 44 ? .title3 : .body)
                .foregroundStyle(Color.mix)
                .frame(width: size, height: size)
                .background(Color.mix.opacity(0.16), in: .circle)
        }
    }
}

struct PickArt: View {
    let model: AppModel
    let pick: MixPick
    let size: CGFloat

    var body: some View {
        switch pick {
        case .favorites:
            Image(systemName: "heart.fill")
                .font(size >= 44 ? .title3 : .body)
                .foregroundStyle(Color.heartInk)
                .frame(width: size, height: size)
                .background(Color.heart, in: .circle)
        case .artist:
            Artwork(url: model.library?.artworkURL(pick.thumb), size: size, corner: 6, placeholder: "music.microphone")
                .clipShape(.circle)
        case .playlist:
            Artwork(url: model.library?.artworkURL(pick.thumb), size: size, corner: 6, placeholder: "music.note.list")
        case .album:
            Artwork(url: model.library?.artworkURL(pick.thumb), size: size, corner: 6)
        }
    }
}

extension PlayStyle {
    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .shuffle: "shuffle"
        case .mixAlbums: "square.stack"
        }
    }

    var explanation: String {
        switch self {
        case .play: "The picks in order, each as it is listed: a playlist's order, an album front to back, an artist's albums oldest first, favorites newest first."
        case .shuffle: "Every track shuffled, spread out by artist and album."
        case .mixAlbums: "Whole albums front to back, the albums shuffled."
        }
    }
}

extension SavedMix {
    /// The style glyph's color: the heart for the favorites alone, the
    /// playlists' teal for a playlist alone, amber for one artist or
    /// album, and the builder's blue for a real mix.
    var accent: Color {
        guard picks.count == 1 else { return .mix }
        switch picks[0].kind {
        case .favorites: return .heart
        case .playlist: return .playlist
        case .artist, .album: return .accentText
        }
    }

    /// "Favorites", "Album · Bon Jovi", "Bon Jovi, Road Trip & 1 album",
    /// "The whole library": what the mix is, for the Settings rows.
    var caption: String {
        switch picks.count {
        case 0:
            return "The whole library"
        case 1:
            if case .album(_, _, _, let artist?, _) = picks[0], !artist.isEmpty { return "Album · \(artist)" }
            return picks[0].kind.label
        case 2, 3:
            return ListenerRoster.joinNames(picks.map(\.title))
        default:
            let counts = MixPickKind.allCases.compactMap { kind -> String? in
                let n = picks.filter { $0.kind == kind }.count
                guard n > 0 else { return nil }
                return kind == .favorites ? "Favorites" : "\(n) \(kind.label.lowercased())\(n == 1 ? "" : "s")"
            }
            return ListenerRoster.joinNames(counts)
        }
    }
}

// MARK: - Playing one

extension LibraryActions {
    /// Every track of one pick, as the server lists it. A fetch failure
    /// runs the usual rediscovery and yields nothing; the favorites are
    /// asked again once the library has moved, since the address may have
    /// gone stale between Wi-Fi and cellular.
    func tracks(of pick: MixPick) async -> [PlexTrack] {
        guard let library = model.library, let section = model.selectedSection else { return [] }
        switch pick {
        case .favorites:
            // Newest hearts first, the Favorites page's own default, so
            // Play starts where the list does.
            do {
                return FavoritesSort.recent.sorted(try await library.favoriteTracks(inSection: section.key))
            } catch {
                guard await model.connectionLost(error), let current = model.library else { return [] }
                return FavoritesSort.recent.sorted((try? await current.favoriteTracks(inSection: section.key)) ?? [])
            }
        case .playlist(let key, let title, _):
            return await items(of: PlexPlaylist(ratingKey: key, title: title), known: nil).map(\.track)
        case .artist(let key, _, _):
            return await tracks(ofArtist: key)
        case .album(let key, let title, let artistKey, let artist, let thumb):
            let album = PlexAlbum(ratingKey: key, title: title, parentRatingKey: artistKey, parentTitle: artist, year: nil, thumb: thumb)
            return await tracks(of: album, known: nil)
        }
    }

    /// Every track across the picks, fetched concurrently and laid out
    /// in pick order, each track once; no picks is the whole section.
    /// Not yet filtered: the caller decides which vetoes apply.
    func tracks(of picks: [MixPick]) async -> [PlexTrack] {
        guard let library = model.library, let section = model.selectedSection else { return [] }
        if picks.isEmpty {
            do {
                return try await library.tracks(inSection: section.key)
            } catch {
                await model.connectionLost(error)
                return []
            }
        }
        let fetched = await withTaskGroup(of: (Int, [PlexTrack]).self) { group in
            for (index, pick) in picks.enumerated() {
                group.addTask { (index, await self.tracks(of: pick)) }
            }
            var all: [(Int, [PlexTrack])] = []
            for await batch in group { all.append(batch) }
            return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen: Set<String> = []
        return fetched.filter { seen.insert($0.ratingKey).inserted }
    }

    /// Plays a saved mix: fetched fresh each tap, since hearts and
    /// playlists change, ordered by its style, minus what the active
    /// listeners hide by any veto, since a mix is a mixed bag. Favorites
    /// alone with nothing hearted yet say so rather than "Nothing to play".
    func play(_ mix: SavedMix) async {
        let tracks = await tracks(of: mix.picks)
        if tracks.isEmpty, mix.picks == [.favorites], !offline {
            navigator.notice = "No favorites yet. Tap ··· on a track, or the heart in Now Playing, to favorite it."
            return
        }
        play(mix.style.ordered(tracks), within: nil)
    }
}

// MARK: - Saving one

/// The builder's Save: a name, prefilled from the picks, and how to play.
/// Saving a mix already on the screen updates it in place.
struct SaveMixSheet: View {
    let model: AppModel
    let picks: [MixPick]
    /// The saved mix being edited, if any.
    let editing: SavedMix.ID?
    /// Called with the saved mix's id, so the builder keeps editing it.
    let onSave: (SavedMix.ID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var style: PlayStyle = .shuffle
    @FocusState private var editingName: Bool

    private var existing: SavedMix? { editing.flatMap { model.shortcut($0) } }
    private var styles: [PlayStyle] { PlayStyle.cases(for: picks) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var finalName: String { trimmed.isEmpty ? SavedMix.suggestedName(for: picks) : trimmed }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Name").frame(width: 64, alignment: .leading)
                        TextField(SavedMix.suggestedName(for: picks), text: $name)
                            .focused($editingName)
                            .submitLabel(.done)
                    }
                } footer: {
                    Text("Appears on the Music screen as “\(style.verb) \(finalName)”.")
                }
                Section {
                    StyleRows(styles: styles, style: $style, accent: .mix)
                } header: {
                    Text("Plays as")
                } footer: {
                    Text(style.explanation)
                }
                Section {
                    PickRows(model: model, picks: picks)
                } header: {
                    Text(picks.count == 1 ? "Plays" : "Mixes")
                }
            }
            .settingsBackground()
            .navigationTitle(existing == nil ? "Save Mix" : "Update Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = finalName
                        if let existing {
                            model.updateShortcut(existing.id) {
                                $0.name = name
                                $0.picks = picks
                                $0.style = style
                            }
                            onSave(existing.id)
                        } else {
                            onSave(model.addShortcut(name: name, picks: picks, style: style).id)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    style = existing.style
                }
                // A mix that was one playlist and grew loses Play.
                if !styles.contains(style) { style = styles[0] }
                editingName = existing == nil
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The offered styles as rows with a check on the chosen one.
private struct StyleRows: View {
    let styles: [PlayStyle]
    @Binding var style: PlayStyle
    let accent: Color

    var body: some View {
        ForEach(styles) { option in
            Button {
                withAnimation(.snappy) { style = option }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: option.symbol)
                        .foregroundStyle(accent)
                        .frame(width: 24)
                    Text(option.verb).foregroundStyle(.primary)
                    Spacer()
                    if option == style {
                        Image(systemName: "checkmark").fontWeight(.semibold)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The picks as rows, or the one line that says there are none.
private struct PickRows: View {
    let model: AppModel
    let picks: [MixPick]

    var body: some View {
        ForEach(picks, id: \.id) { pick in
            HStack(spacing: 12) {
                PickArt(model: model, pick: pick, size: 32)
                Text(pick.title).lineLimit(1)
                Spacer()
                Text(pick.kind.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        if picks.isEmpty {
            Text("Nothing picked: the whole library.").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings

/// The saved mixes as a list to keep: reorder, swipe to remove, tap to
/// rename or change how one plays, open the builder for a new one. Pushes
/// onto whichever stack it sits in, like the listeners' list.
struct ShortcutsList: View {
    let model: AppModel
    /// Closes the sheet the list sits in, so the builder can open under it.
    let close: () -> Void
    @Environment(LibraryNavigator.self) private var navigator

    /// Its own type rather than a bare id: the listeners' list pushes
    /// `UUID`s on the same Settings stack.
    private enum Page: Hashable {
        case detail(SavedMix.ID)
    }

    var body: some View {
        let shortcuts = model.shortcuts
        List {
            Section {
                ForEach(shortcuts) { mix in
                    NavigationLink(value: Page.detail(mix.id)) {
                        row(mix)
                    }
                }
                .onDelete { offsets in
                    for id in offsets.map({ shortcuts[$0].id }) {
                        model.removeShortcut(id)
                    }
                }
                .onMove { source, destination in
                    model.moveShortcuts(from: source, to: destination)
                }
                Button {
                    close()
                    navigator.open(.mix(MixRoute()))
                } label: {
                    Label("New Mix…", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("Shortcuts are the play buttons at the top of the Music screen: mixes saved from the Mix Builder. One whose every pick is hidden for the people listening stays off the screen until they change.")
            }
        }
        .settingsBackground()
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if shortcuts.count > 1 {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
        .navigationDestination(for: Page.self) { page in
            switch page {
            case .detail(let id): ShortcutDetail(model: model, id: id, close: close)
            }
        }
    }

    private func row(_ mix: SavedMix) -> some View {
        HStack(spacing: 12) {
            MixArt(model: model, picks: mix.picks, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(mix.title)
                Text(mix.caption)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// One saved mix's page: its name, how it plays, what it mixes, and
/// Remove. The picks change in the builder, opened from here.
private struct ShortcutDetail: View {
    let model: AppModel
    let id: SavedMix.ID
    let close: () -> Void
    @Environment(LibraryNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let mix = model.shortcut(id) {
            content(mix)
        } else {
            ContentUnavailableView("Shortcut removed", systemImage: "bookmark.slash")
        }
    }

    private func content(_ mix: SavedMix) -> some View {
        let name = Binding(
            get: { mix.name },
            set: { value in model.updateShortcut(id) { $0.name = value } }
        )
        let style = Binding(
            get: { mix.style },
            set: { value in model.updateShortcut(id) { $0.style = value } }
        )
        return List {
            Section {
                HStack {
                    Text("Name").frame(width: 64, alignment: .leading)
                    TextField(SavedMix.suggestedName(for: mix.picks), text: name)
                }
            } footer: {
                Text("Appears as “\(mix.title)”.")
            }
            Section {
                // A mix saved under a style its picks no longer offer (an
                // older build, or edited picks) keeps it until changed.
                let styles = PlayStyle.cases(for: mix.picks)
                StyleRows(styles: styles.contains(mix.style) ? styles : styles + [mix.style], style: style, accent: mix.accent)
            } header: {
                Text("Plays as")
            } footer: {
                Text(mix.style.explanation)
            }
            Section {
                PickRows(model: model, picks: mix.picks)
                Button {
                    close()
                    navigator.open(.mix(MixRoute(mixID: id)))
                } label: {
                    Label("Edit in Mix Builder", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text(mix.picks.count == 1 ? "Plays" : "Mixes")
            }
            Section {
                Button("Remove Shortcut", role: .destructive) {
                    model.removeShortcut(id)
                    dismiss()
                }
                .foregroundStyle(.red)
            }
        }
        .settingsBackground()
        .navigationTitle(mix.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
