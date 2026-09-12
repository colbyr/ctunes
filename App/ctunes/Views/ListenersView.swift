import PlexKit
import SwiftUI

/// Listener setup, reached from the listener chips on the Music screen or
/// the Listeners row in Settings. Adding, naming and coloring happen here;
/// picking who's in the car happens on the Music screen itself.
struct ListenersSheet: View {
    let model: AppModel
    /// Every artist in the library, so a veto list can be edited in one place.
    let artists: [AlbumGroup]
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Listener.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            ListenersList(model: model, artists: artists)
                .navigationTitle("Listeners")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task {
            #if DEBUG
            // `detail` lands on the first listener's page, for simulator checks.
            if ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS_SHEET"] == "detail",
               let first = model.roster.listeners.first {
                path = [first.id]
            }
            #endif
        }
    }
}

/// The roster itself. Pushes each listener's page onto whichever stack it
/// sits in, so the sheet and the Settings screen share one list.
struct ListenersList: View {
    let model: AppModel
    let artists: [AlbumGroup]
    /// A just-added listener, pushed straight to its page for naming. Held
    /// here rather than in the enclosing stack's path so the list needs no
    /// knowledge of which stack it's in.
    @State private var added: Listener.ID?

    var body: some View {
        let others = model.roster.others
        List {
            Section("Library owner") {
                NavigationLink(value: Listener.ownerID) {
                    row(model.roster.owner)
                }
            }
            Section {
                ForEach(others) { listener in
                    NavigationLink(value: listener.id) {
                        row(listener)
                    }
                }
                .onDelete { offsets in
                    for id in offsets.map({ others[$0].id }) {
                        model.removeListener(id)
                    }
                }
                Button {
                    added = model.addListener(name: "New Listener").id
                } label: {
                    Label("Add Listener", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Other listeners")
            } footer: {
                Text("Listeners are saved on this phone, not in Plex. Choose who's listening from the Music screen.")
            }
        }
        .settingsBackground()
        .navigationDestination(for: Listener.ID.self) { id in
            ListenerDetail(model: model, id: id, artists: artists)
        }
        .navigationDestination(item: $added) { id in
            ListenerDetail(model: model, id: id, artists: artists)
        }
    }

    private func row(_ listener: Listener) -> some View {
        HStack(spacing: 12) {
            ListenerAvatar(listener: listener, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(listener.name)
                Text(Self.summary(listener))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func summary(_ listener: Listener) -> String {
        let count = listener.vetoedArtistKeys.count
        return count == 0
            ? "Hears everything"
            : "\(count) artist\(count == 1 ? "" : "s") hidden"
    }
}

/// One listener's page: name, color, and the full veto list.
private struct ListenerDetail: View {
    let model: AppModel
    let id: Listener.ID
    let artists: [AlbumGroup]
    @Environment(\.dismiss) private var dismiss

    private var listener: Listener? { model.roster.listener(id) }

    var body: some View {
        if let listener {
            content(listener)
        } else {
            ContentUnavailableView("Listener removed", systemImage: "person.slash")
        }
    }

    private func content(_ listener: Listener) -> some View {
        let vetoed = artists.filter { listener.vetoedArtistKeys.contains($0.id) }
        let available = artists.filter { !listener.vetoedArtistKeys.contains($0.id) }
        let name = Binding(
            get: { listener.name },
            set: { model.renameListener(id, name: $0) }
        )
        return List {
            Section {
                VStack(spacing: 10) {
                    ListenerAvatar(listener: listener, size: 72)
                    // The owner is the amber person, and "You" is their name.
                    if !listener.isOwner {
                        Menu("Change Color") {
                            ForEach(ListenerPalette.colors.indices, id: \.self) { index in
                                Button {
                                    model.setListenerColor(id, index: index)
                                } label: {
                                    Label {
                                        Text(ListenerPalette.names[index])
                                    } icon: {
                                        Image(systemName: index == listener.colorIndex ? "checkmark.circle.fill" : "circle.fill")
                                            .foregroundStyle(ListenerPalette.color(index))
                                    }
                                }
                            }
                        }
                        .font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !listener.isOwner {
                Section {
                    HStack {
                        Text("Name").frame(width: 64, alignment: .leading)
                        TextField("Name", text: name)
                    }
                }
            }
            Section {
                if vetoed.isEmpty {
                    Text(listener.isOwner ? "Nothing vetoed — you hear everything." : "Nothing vetoed — \(listener.name) hears everything.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                } else {
                    ForEach(vetoed) { artist in
                        row(artist, symbol: "minus.circle.fill", tint: .red)
                    }
                }
            } header: {
                HStack {
                    Text("Doesn't listen to")
                    Spacer()
                    Text("\(vetoed.count) artist\(vetoed.count == 1 ? "" : "s")")
                }
            }
            Section("Add an artist") {
                ForEach(available) { artist in
                    row(artist, symbol: "plus.circle.fill", tint: .green)
                }
            }
        }
        .settingsBackground()
        .navigationTitle(listener.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func row(_ artist: AlbumGroup, symbol: String, tint: Color) -> some View {
        Button {
            withAnimation(.snappy) { model.toggleVeto(artistKey: artist.id, for: id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).foregroundStyle(tint).font(.title3)
                Text(artist.name).foregroundStyle(.primary)
                Spacer()
                Text("\(artist.albums.count) album\(artist.albums.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

}
