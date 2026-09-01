import PlexKit
import SwiftUI

/// Browse root. Shows the chosen music library, or asks which one to use when
/// the server has more than one and nothing has been picked yet.
struct LibraryView: View {
    let model: AppModel
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let section = model.selectedSection {
                    MusicView(model: model, section: section)
                } else {
                    SectionPicker(model: model)
                }
            }
            // Declared at the stack root so a seeded path can reach it.
            .navigationDestination(for: PlexAlbum.self) { album in
                TracksView(model: model, album: album)
            }
        }
        // Attached to the stack, not to its root view: on the root view the
        // inset is replaced along with the content on every push, so the
        // mini player vanishes as soon as you navigate anywhere.
        .safeAreaInset(edge: .bottom) { MiniPlayer(model: model) }
        .task {
            if let album = Self.developmentAlbum {
                path.append(album)
            }
        }
    }

    /// Debug-only deep link so the deeper screens can be driven in a
    /// simulator, where there's no way to tap through. Pushes onto the stack
    /// rather than replacing the root, so navigation behaves as it really does.
    static var developmentAlbum: PlexAlbum? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CTUNES_DEV_ALBUM"],
              !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 2).map(String.init)
        return PlexAlbum(
            ratingKey: parts[0],
            title: parts.count > 1 ? parts[1] : "Album",
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
        .navigationTitle("Choose a library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sign out") { Task { await model.signOut() } }
            }
        }
    }
}
