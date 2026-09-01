import PlexKit
import SwiftUI

/// Browse root. Shows the chosen music library, or asks which one to use when
/// the server has more than one and nothing has been picked yet.
struct LibraryView: View {
    let model: AppModel

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

    var body: some View {
        NavigationStack {
            Group {
                if let album = Self.developmentAlbum {
                    // Debug-only deep link so the deeper screens can be driven
                    // in a simulator, where there's no way to tap through.
                    TracksView(model: model, album: album)
                } else if let section = model.selectedSection {
                    ArtistsView(model: model, section: section)
                } else {
                    SectionPicker(model: model)
                }
            }
        }
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
