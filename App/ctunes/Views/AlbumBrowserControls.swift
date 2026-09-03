import PlexKit
import SwiftUI

/// The album browser's arrange button: a 34pt circle pinned at the trailing
/// edge of the listener chips, opening one menu with Group by and Sort by.
/// Picking an option applies it and dismisses. The main screen and the album
/// mix builder bind the same stored values, so a choice made in one shows
/// up in the other.
struct ArrangeChip: View {
    @Binding var grouping: AlbumGrouping
    @Binding var sort: AlbumSort

    var body: some View {
        Menu {
            Picker("Group by", selection: $grouping) {
                ForEach(AlbumGrouping.browserOptions, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.inline)
            Picker("Sort by", selection: $sort) {
                ForEach(AlbumSort.browserOptions, id: \.self) { Text($0.browserTitle) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arrange: grouped by \(grouping.title), sorted by \(sort.browserTitle)")
    }

    /// Stored values from before the menu was trimmed to `browserOptions`
    /// would otherwise group the grid by something the menu can't show a
    /// check for.
    static func normalize(grouping: inout AlbumGrouping, sort: inout AlbumSort) {
        if !AlbumGrouping.browserOptions.contains(grouping) { grouping = .artist }
        if !AlbumSort.browserOptions.contains(sort) { sort = .recentlyAdded }
    }
}

/// The chips plus the arrange button as one row. With nobody on the roster
/// there's nothing to toggle, so only the button shows, still pinned right.
struct AlbumBrowserControls: View {
    let model: AppModel
    @Binding var grouping: AlbumGrouping
    @Binding var sort: AlbumSort

    var body: some View {
        if model.roster.listeners.isEmpty {
            ArrangeChip(grouping: $grouping, sort: $sort)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
        } else {
            ListenerChips(model: model) { ArrangeChip(grouping: $grouping, sort: $sort) }
        }
    }
}

/// "2 artists hidden for Laura & Kids", under the chips. Callers show it
/// only when the count is above zero.
struct HiddenArtistsLine: View {
    let model: AppModel
    let count: Int

    var body: some View {
        Label(
            "\(count) artist\(count == 1 ? "" : "s") hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name)))",
            systemImage: "eye.slash"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// One group's heading over its grid: the name, with the album count beside
/// it. Shared by the main screen and the album mix pool so a group reads
/// the same on both.
struct AlbumGroupHeader: View {
    let group: AlbumGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("\(group.albums.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
    }
}
