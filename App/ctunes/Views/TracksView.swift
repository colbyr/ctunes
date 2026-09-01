import PlexKit
import SwiftUI

struct TracksView: View {
    let model: AppModel
    let album: PlexAlbum

    @State private var tracks: [PlexTrack] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                ForEach(tracks) { track in
                    HStack(spacing: 12) {
                        Text(track.index.map(String.init) ?? "–")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(track.title)
                        Spacer()
                        if let seconds = track.durationSeconds {
                            Text(Self.duration(seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                VStack(spacing: 8) {
                    Artwork(url: model.library?.artworkURL(album.thumb, size: 600),
                            size: 180, corner: 10)
                    Text(album.title).font(.headline)
                    if let artist = album.parentTitle {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .textCase(nil)
            }
        }
        .overlay {
            if !loaded { ProgressView() }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let library = model.library else { return }
            tracks = (try? await library.tracks(inAlbum: album.ratingKey)) ?? []
            loaded = true
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
