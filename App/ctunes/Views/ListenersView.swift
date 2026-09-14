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
            // `detail` lands on the page of the first listener with a veto
            // (the seeded one), or the owner's, for simulator checks.
            if ProcessInfo.processInfo.environment["CTUNES_DEV_LISTENERS_SHEET"] == "detail",
               let first = model.roster.listeners.first(where: { !$0.vetoes.isEmpty }) ?? model.roster.listeners.first {
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
        let listeners = model.roster.listeners
        List {
            Section {
                ForEach(listeners) { listener in
                    NavigationLink(value: listener.id) {
                        row(listener)
                    }
                }
                .onDelete { offsets in
                    for id in offsets.map({ listeners[$0].id }) {
                        model.removeListener(id)
                    }
                }
                Button {
                    added = model.addListener(name: Self.newName).id
                } label: {
                    Label("Add Listener", systemImage: "plus.circle.fill")
                }
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

    /// What a listener is called until they're named. The name field
    /// shows it as its placeholder rather than as text to clear.
    static let newName = "New Listener"

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

    /// "Hears everything", or "2 artists & 1 album hidden".
    private static func summary(_ listener: Listener) -> String {
        let count = ListenerDetail.count(listener)
        return count.isEmpty ? "Hears everything" : "\(count.description) hidden"
    }
}

/// One listener's page: name, color, and the full veto list.
/// Artists can be added here from the library; an album or a track is
/// hidden from its own menu or page, where it can be found.
private struct ListenerDetail: View {
    let model: AppModel
    let id: Listener.ID
    let artists: [AlbumGroup]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingName: Bool

    private var listener: Listener? { model.roster.listener(id) }

    var body: some View {
        if let listener {
            content(listener)
        } else {
            ContentUnavailableView("Listener removed", systemImage: "person.slash")
        }
    }

    private func content(_ listener: Listener) -> some View {
        let available = artists.filter { !listener.vetoes(.artist($0.id)) }
        // A listener still called "New Listener" reads as unnamed: the
        // field is empty with that as its placeholder, and clearing a
        // name puts them back there rather than leaving a blank chip.
        let name = Binding(
            get: { listener.name == ListenersList.newName ? "" : listener.name },
            set: { model.renameListener(id, name: $0.isEmpty ? ListenersList.newName : $0) }
        )
        return List {
            Section {
                VStack(spacing: 10) {
                    ListenerAvatar(listener: listener, size: 72)
                    // The palette is a row of dots, not a menu: a menu draws
                    // its icons as template images in the tint, so every
                    // dot came out black.
                    HStack(spacing: 6) {
                        ForEach(ListenerPalette.colors.indices, id: \.self) { index in
                            let selected = index == listener.colorIndex
                            Button {
                                withAnimation(.snappy) { model.setListenerColor(id, index: index) }
                            } label: {
                                // The ring lives inside the frame; drawn
                                // outside it, the row clipped its top and bottom.
                                Circle()
                                    .strokeBorder(Color.ink, lineWidth: 2)
                                    .opacity(selected ? 1 : 0)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        Circle()
                                            .fill(ListenerPalette.color(index))
                                            .frame(width: 26, height: 26)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ListenerPalette.names[index])
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                HStack {
                    Text("Name").frame(width: 64, alignment: .leading)
                    TextField(ListenersList.newName, text: name)
                        .focused($editingName)
                }
            }
            // One list, artists first, then albums, then tracks; the
            // trailing caption says which is which.
            let vetoes = VetoKind.allCases.flatMap { listener.vetoes(of: $0) }
            Section {
                if vetoes.isEmpty {
                    Text("Nothing vetoed — \(listener.name) hears everything.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                } else {
                    ForEach(vetoes) { veto in
                        vetoRow(veto)
                    }
                }
            } header: {
                HStack {
                    Text("Doesn't listen to")
                    Spacer()
                    if !vetoes.isEmpty {
                        Text(Self.count(listener).description)
                    }
                }
            } footer: {
                Text(Self.howToHide)
            }
            Section("Exclude an artist") {
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
        // A just-added listener lands here to be named, keyboard up.
        .onAppear { editingName = listener.name == ListenersList.newName }
    }

    private static let howToHide = "Hide an album or a track from its menu, or from the avatars at the top of its page."

    /// The listener's vetoes by kind, for the row summary and the header.
    static func count(_ listener: Listener) -> HiddenCount {
        HiddenCount(
            artists: listener.vetoes(of: .artist).count,
            albums: listener.vetoes(of: .album).count,
            tracks: listener.vetoes(of: .track).count
        )
    }

    /// A veto with the minus: the title it was saved with, or for an
    /// artist vetoed before titles were kept, the library's name for it.
    /// The caption tells the kinds apart: an artist's album count, or
    /// "Album" / "Track".
    private func vetoRow(_ veto: Veto) -> some View {
        let artist = veto.kind == .artist ? artists.first { $0.id == veto.target.key } : nil
        let title = veto.title.isEmpty ? (artist?.name ?? "Unknown \(veto.kind.rawValue)") : veto.title
        let detail = switch veto.kind {
        case .artist: artist.map { "\($0.albums.count) album\($0.albums.count == 1 ? "" : "s")" } ?? "Artist"
        case .album: "Album"
        case .track: "Track"
        }
        return Button {
            withAnimation(.snappy) { model.removeVeto(veto.target, for: id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle = veto.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func row(_ artist: AlbumGroup, symbol: String, tint: Color) -> some View {
        Button {
            withAnimation(.snappy) { model.toggleVeto(Veto(artistKey: artist.id, title: artist.name), for: id) }
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
