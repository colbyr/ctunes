import PlexKit
import SwiftUI

/// How a browse screen lays its items out: covers in a grid, or rows
/// with the art at the leading edge. Per screen, like the sort: the root,
/// an artist's page and the mix pools each keep their
/// own, so the root can stay a grid while an artist's page reads as a list.
enum BrowseLayout: String, CaseIterable {
    case grid, list

    var title: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

extension BrowseSubject {
    var systemImage: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "person.2"
        case .playlists: "music.note.list"
        }
    }
}

/// The album browser's arrange buttons: two 34pt circles pinned at the
/// trailing edge of the listener chips. The first is what the page shows
/// and how (the subject, where the page has one, then grid or list), its
/// glyph the current layout; the second is the order. Picking one applies
/// it and dismisses.
struct ArrangeChip: View {
    @Binding var view: AlbumView
    @Binding var layout: BrowseLayout
    /// What the sorts are over, for the Artists view's name.
    var scope: BrowseScope = .albums
    /// Only the root and Quick Mix browse more than one kind.
    var subject: Binding<BrowseSubject>? = nil
    /// The kinds on offer: Quick Mix has no playlists.
    var subjects: [BrowseSubject] = BrowseSubject.allCases

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if let subject {
                    Picker("Browse", selection: subject) {
                        ForEach(subjects, id: \.self) { Label($0.title, systemImage: $0.systemImage) }
                    }
                    .pickerStyle(.inline)
                }
                Picker("Layout", selection: $layout) {
                    ForEach(BrowseLayout.allCases, id: \.self) { Label($0.title, systemImage: $0.systemImage) }
                }
                .pickerStyle(.inline)
            } label: {
                ChipIcon(systemImage: layout.systemImage)
            }
            .accessibilityLabel(subject.map { "Showing \($0.wrappedValue.title.lowercased()) as a \(layout.title.lowercased())" }
                ?? "Showing a \(layout.title.lowercased())")
            Menu {
                Picker("Sort", selection: $view) {
                    ForEach(AlbumView.cases(in: scope), id: \.self) { Text($0.title(in: scope)) }
                }
                .pickerStyle(.inline)
            } label: {
                ChipIcon(systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sorted by \(view.title(in: scope))")
        }
        .buttonStyle(.plain)
    }

    private struct ChipIcon: View {
        let systemImage: String

        var body: some View {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: .circle)
                .contentShape(.circle)
        }
    }
}

/// The chips plus the arrange button as one row. Each screen keeps its own
/// stored sort; the roster and the layout are shared. The download filter,
/// where a screen has one, is the chip at the head of the row.
struct AlbumBrowserControls: View {
    let model: AppModel
    /// Every artist in the library, for the Listeners sheet the chips open.
    let artists: [AlbumGroup]
    @Binding var view: AlbumView
    @Binding var layout: BrowseLayout
    var scope: BrowseScope = .albums
    var subject: Binding<BrowseSubject>? = nil
    var subjects: [BrowseSubject] = BrowseSubject.allCases
    /// Only the main browser and Quick Mix filter.
    var downloadedOnly: Binding<Bool>? = nil

    var body: some View {
        ListenerChips(model: model, artists: artists, downloadedOnly: downloadedOnly) {
            ArrangeChip(view: $view, layout: $layout, scope: scope, subject: subject, subjects: subjects)
        }
    }
}

/// "11 albums hidden" under the chips, counted in what the list shows,
/// or "Everything" when nothing is ("All Downloads" under the download
/// filter), so the grid doesn't jump as listeners toggle. Who is
/// listening is already on the chips above, so it isn't repeated.
struct HiddenLine: View {
    let model: AppModel
    let count: HiddenCount
    var downloadedOnly = false

    var body: some View {
        Text(count.isEmpty
            ? (downloadedOnly ? "All Downloads" : "Everything")
            : "\(count.description) hidden")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// How many of a list's own rows the active listeners' vetoes hide, in
/// the list's unit: albums on an album grid, artists on an artist grid,
/// tracks on a track list. An album under a hidden artist counts as an
/// album, since that is what left the grid.
struct HiddenCount: Equatable {
    var artists = 0
    var albums = 0
    var tracks = 0

    var isEmpty: Bool { artists == 0 && albums == 0 && tracks == 0 }

    /// "11 albums"; only one unit is ever set.
    var description: String {
        var parts: [String] = []
        if artists > 0 { parts.append("\(artists) artist\(artists == 1 ? "" : "s")") }
        if albums > 0 { parts.append("\(albums) album\(albums == 1 ? "" : "s")") }
        if tracks > 0 { parts.append("\(tracks) track\(tracks == 1 ? "" : "s")") }
        return ListenerRoster.joinNames(parts)
    }

    /// The albums hidden by their own veto or their artist's.
    static func over(_ albums: [PlexAlbum], hidden: VetoSet) -> HiddenCount {
        HiddenCount(albums: albums.filter { hidden.hides($0) }.count)
    }

    /// The tracks hidden by their own veto or a wider one.
    static func over(_ tracks: [PlexTrack], hidden: VetoSet) -> HiddenCount {
        HiddenCount(tracks: tracks.filter { hidden.hides($0) }.count)
    }
}

/// One group's heading over its items. Shared by the main screen, under
/// either subject, and the album mix pool so a group reads the same on
/// both.
struct AlbumGroupHeader: View {
    let name: String

    init(name: String) { self.name = name }
    init(group: AlbumGroup) { name = group.name }

    var body: some View {
        Text(name)
            .font(.title3.weight(.semibold))
            // The palette's ink, not the system primary: on dark that is
            // pure white against every other cream label on the page.
            .foregroundStyle(Color.ink)
            .textCase(nil)
    }
}
