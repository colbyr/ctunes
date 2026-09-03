import PlexKit
import SwiftUI

/// The album browser's arrange button: a 34pt circle pinned at the trailing
/// edge of the listener chips, opening one menu with the sorts inline under
/// a Sort header and the groupings in a submenu, since grouping is the
/// rarer change. Picking an option applies it and dismisses.
struct ArrangeChip: View {
    @Binding var grouping: AlbumGrouping
    @Binding var sort: AlbumSort

    var body: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(AlbumSort.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.inline)
            Picker("Group", systemImage: "square.grid.2x2", selection: $grouping) {
                ForEach(AlbumGrouping.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sorted by \(sort.title), grouped by \(grouping.title)")
    }
}

/// The chips plus the arrange button as one row. Each screen keeps its own
/// stored sort and grouping; only the roster is shared. With nobody on the roster
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
        Text("\(count) artist\(count == 1 ? "" : "s") hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name)))")
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
