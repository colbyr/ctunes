import PlexKit
import SwiftUI

/// The album browser's arrange button: a 34pt circle pinned at the trailing
/// edge of the listener chips, opening one menu with the views inline.
/// Picking one applies it and dismisses.
struct ArrangeChip: View {
    @Binding var view: AlbumView
    /// Only the main browser offers the filter; a mix pool passes nil.
    var downloadedOnly: Binding<Bool>? = nil

    var body: some View {
        Menu {
            Picker("View", selection: $view) {
                ForEach(AlbumView.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.inline)
            if let downloadedOnly {
                Toggle("Downloaded only", systemImage: "arrow.down.circle", isOn: downloadedOnly)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Viewing \(view.title)")
    }
}

/// The chips plus the arrange button as one row. Each screen keeps its own
/// stored view; only the roster is shared.
struct AlbumBrowserControls: View {
    let model: AppModel
    /// Every artist in the library, for the Listeners sheet the chips open.
    let artists: [AlbumGroup]
    @Binding var view: AlbumView
    var downloadedOnly: Binding<Bool>? = nil

    var body: some View {
        ListenerChips(model: model, artists: artists) {
            ArrangeChip(view: $view, downloadedOnly: downloadedOnly)
        }
    }
}

/// "2 artists & 1 album hidden for Laura & Kids" under the chips, or
/// "Everything" when nothing is, so the grid doesn't jump as listeners
/// toggle.
struct HiddenLine: View {
    let model: AppModel
    let count: HiddenCount

    var body: some View {
        Text(count.isEmpty
            ? "Everything"
            : "\(count.description) hidden for \(ListenerRoster.joinNames(model.roster.activeNames))")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// What a list lost to the active listeners' vetoes, counted at the
/// widest level: an album under a hidden artist counts toward the artist,
/// not as an album, so the line says what was vetoed rather than how
/// many rows went.
struct HiddenCount: Equatable {
    var artists = 0
    var albums = 0
    var tracks = 0

    var isEmpty: Bool { artists == 0 && albums == 0 && tracks == 0 }

    /// "2 artists, 1 album & 3 tracks".
    var description: String {
        var parts: [String] = []
        if artists > 0 { parts.append("\(artists) artist\(artists == 1 ? "" : "s")") }
        if albums > 0 { parts.append("\(albums) album\(albums == 1 ? "" : "s")") }
        if tracks > 0 { parts.append("\(tracks) track\(tracks == 1 ? "" : "s")") }
        return ListenerRoster.joinNames(parts)
    }

    /// Over an album list: the artists with an album in it, then the
    /// albums under an artist that isn't hidden.
    static func over(_ albums: [PlexAlbum], hidden: VetoSet) -> HiddenCount {
        var count = HiddenCount()
        var artists: Set<String> = []
        for album in albums {
            if hidden.artists.contains(album.artistKey) {
                artists.insert(album.artistKey)
            } else if hidden.albums.contains(album.ratingKey) {
                count.albums += 1
            }
        }
        count.artists = artists.count
        return count
    }

    /// Over a track list: the artists and albums with a track in it, then
    /// the tracks hidden on their own.
    static func over(_ tracks: [PlexTrack], hidden: VetoSet) -> HiddenCount {
        var count = HiddenCount()
        var artists: Set<String> = []
        var albums: Set<String> = []
        for track in tracks {
            if let artist = track.grandparentRatingKey, hidden.artists.contains(artist) {
                artists.insert(artist)
            } else if let album = track.parentRatingKey, hidden.albums.contains(album) {
                albums.insert(album)
            } else if hidden.tracks.contains(track.ratingKey) {
                count.tracks += 1
            }
        }
        count.artists = artists.count
        count.albums = albums.count
        return count
    }
}

/// One group's heading over its grid. Shared by the main screen and the
/// album mix pool so a group reads the same on both.
struct AlbumGroupHeader: View {
    let group: AlbumGroup

    var body: some View {
        Text(group.name)
            .font(.title3.weight(.semibold))
            // The palette's ink, not the system primary: on dark that is
            // pure white against every other cream label on the page.
            .foregroundStyle(Color.ink)
            .textCase(nil)
    }
}
