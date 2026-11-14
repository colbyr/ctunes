import PlexKit
import SwiftUI

/// What stands for a mix: its one pick's art (the heart disc for the
/// favorites, a round portrait for an artist, the cover or composite
/// otherwise), and for several picks or none Quick Mix's own
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
            // The square of the playlists grid, the one drawing of it.
            FavoritesArt(size: size, corner: 6)
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

extension MixPick {
    /// An artist from just a key and name, with the portrait the browse
    /// root's catalog has for them.
    @MainActor static func artist(_ ratingKey: String, title: String) -> MixPick {
        let thumb = AppRuntime.shared.catalog.artists.first { $0.ratingKey == ratingKey }?.thumb
        return .artist(ratingKey: ratingKey, title: title, thumb: thumb)
    }

    /// The outline of its art: round for an artist's portrait, a
    /// rounded square for a cover and the favorites.
    var artShape: AnyShape {
        switch kind {
        case .artist: AnyShape(.circle)
        case .album, .playlist, .favorites: AnyShape(.rect(cornerRadius: 6))
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
        case .play: "In order: playlists as listed, albums front to back, artists oldest first, favorites newest first."
        case .shuffle: "Every track, shuffled and spread by artist and album."
        case .mixAlbums: "Whole albums in shuffled order."
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
    /// Plays a saved mix: fetched fresh each tap, since hearts and
    /// playlists change, ordered by its style, minus what the active
    /// listeners hide by any veto, since a mix is a mixed bag. Favorites
    /// alone with nothing hearted yet say so rather than "Nothing to play".
    /// A mix that plays goes to the front of Quick Mix's Recent row.
    @discardableResult
    func play(_ mix: SavedMix, presenting: Bool = true) async -> Bool {
        let tracks = await model.tracks(of: mix.picks)
        if tracks.isEmpty, mix.picks == [.favorites], !offline {
            navigator.notice = "No favorites yet. Tap ··· on a track, or the heart in Now Playing, to favorite it."
            return false
        }
        guard play(mix.style.ordered(tracks), within: nil, presenting: presenting) else { return false }
        model.recordMix(mix.picks, style: mix.style, player: player)
        return true
    }
}

// MARK: - Saving one

/// Pinning a recent mix to the Music screen: a name, prefilled from the
/// picks, and how to play, starting from how it last played. Saving a
/// mix already pinned updates it in place.
struct SaveMixSheet: View {
    let model: AppModel
    let picks: [MixPick]
    /// The saved mix being edited, if any.
    let editing: SavedMix.ID?
    /// How it plays to begin with, when not editing one.
    var style: PlayStyle? = nil
    var onSave: (SavedMix.ID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chosen: PlayStyle = .shuffle

    private var existing: SavedMix? { editing.flatMap { model.shortcut($0) } }
    private var styles: [PlayStyle] { PlayStyle.cases(for: picks) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var finalName: String { trimmed.isEmpty ? SavedMix.suggestedName(for: picks) : trimmed }

    var body: some View {
        NavigationStack {
            MixForm(model: model, picks: picks, name: $name, style: $chosen, autofocus: existing == nil)
            .navigationTitle(existing == nil ? "Pin Mix" : "Update Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Pin" : "Save") {
                        let name = finalName
                        if let existing {
                            model.updateShortcut(existing.id) {
                                $0.name = name
                                $0.picks = picks
                                $0.style = chosen
                            }
                            onSave(existing.id)
                        } else {
                            onSave(model.addShortcut(name: name, picks: picks, style: chosen).id)
                        }
                        dismiss()
                    }
                    .tint(Color.mix)
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    chosen = existing.style
                } else if let style {
                    chosen = style
                }
                // A mix that was one playlist and grew loses Play.
                if !styles.contains(chosen) { chosen = styles[0] }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A pin's name, how it plays and what it plays: the Pin Mix sheet's
/// form, and the editor's in the mixer, where a pick can be removed.
struct MixForm: View {
    let model: AppModel
    let picks: [MixPick]
    @Binding var name: String
    @Binding var style: PlayStyle
    /// The name field takes the keyboard on appear: a new pin.
    var autofocus = false
    /// Removes a pick; nil where the picks are fixed.
    var remove: ((MixPick) -> Void)? = nil
    @FocusState private var editingName: Bool

    private var styles: [PlayStyle] { PlayStyle.cases(for: picks) }
    private var finalName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? SavedMix.suggestedName(for: picks) : trimmed
    }

    var body: some View {
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
                PickRows(model: model, picks: picks, remove: remove)
            } header: {
                Text(picks.count == 1 ? "Plays" : "Mixes")
            } footer: {
                if remove != nil {
                    Text("Tap albums, artists or playlists behind this sheet to add them.")
                }
            }
        }
        .settingsBackground()
        .onAppear { editingName = autofocus }
        // Picks that no longer offer the style take the first they do.
        .onChange(of: styles) { _, styles in
            if !styles.contains(style), let first = styles.first { style = first }
        }
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
    var remove: ((MixPick) -> Void)? = nil

    var body: some View {
        ForEach(picks, id: \.id) { pick in
            HStack(spacing: 12) {
                PickArt(model: model, pick: pick, size: 32)
                Text(pick.title).lineLimit(1)
                Spacer()
                Text(pick.kind.label).font(.caption).foregroundStyle(.secondary)
                if let remove {
                    Button { remove(pick) } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(pick.title)")
                }
            }
        }
        .onDelete(perform: remove.map { remove in { offsets in offsets.map { picks[$0] }.forEach(remove) } })
        if picks.isEmpty {
            Text(remove == nil ? "Nothing picked: the whole library." : "Nothing picked yet.").foregroundStyle(.secondary)
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
                Text("Mixes pinned to the Music screen. Hidden when everything in it is hidden for the current listeners.")
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
                    Label("Edit in Mixer", systemImage: "slider.horizontal.3")
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
