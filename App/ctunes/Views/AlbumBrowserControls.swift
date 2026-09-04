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
/// stored view; only the roster is shared. With nobody on the roster
/// there's nothing to toggle, so only the button shows, still pinned right.
struct AlbumBrowserControls: View {
    let model: AppModel
    @Binding var view: AlbumView
    var downloadedOnly: Binding<Bool>? = nil

    var body: some View {
        if model.roster.listeners.isEmpty {
            ArrangeChip(view: $view, downloadedOnly: downloadedOnly)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
        } else {
            ListenerChips(model: model) { ArrangeChip(view: $view, downloadedOnly: downloadedOnly) }
        }
    }
}

/// "2 artists hidden for Laura & Kids" under the chips, or "Everything"
/// when nothing is, so the grid doesn't jump as listeners toggle.
struct HiddenArtistsLine: View {
    let model: AppModel
    let count: Int

    var body: some View {
        Text(count > 0
            ? "\(count) artist\(count == 1 ? "" : "s") hidden for \(ListenerRoster.joinNames(model.roster.active.map(\.name)))"
            : "Everything")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// One group's heading over its grid. Shared by the main screen and the
/// album mix pool so a group reads the same on both.
struct AlbumGroupHeader: View {
    let group: AlbumGroup

    var body: some View {
        Text(group.name)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }
}
