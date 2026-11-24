#if DEBUG
import MusicKit
import PlexKit
import SwiftUI

/// SPIKE (COL-117): search the Apple Music catalog and put songs into the
/// player's queue beside Plex tracks, to see the handoff between the two
/// engines on a real phone, the lock screen and the car. Debug builds only,
/// reached from the foot of Settings.
struct AppleMusicSpikeView: View {
    let model: AppModel
    @Environment(AudioPlayer.self) private var player
    @State private var authorization = MusicAuthorization.currentStatus
    @State private var canPlayCatalog: Bool?
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var error: String?
    @State private var writesNowPlaying = AudioPlayer.writesNowPlayingForAppleMusic
    @State private var releasesSession = AppleMusicEngine.releasesSession
    @State private var padsQueue = AppleMusicEngine.padsQueue
    @State private var mixableSession = AppleMusicEngine.holdsMixableSession

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Authorization", value: "\(authorization)")
                LabeledContent("Can play catalog", value: canPlayCatalog.map { $0 ? "yes" : "no" } ?? "…")
                if authorization != .authorized {
                    Button("Request access") {
                        Task {
                            authorization = await MusicAuthorization.request()
                            await refreshSubscription()
                        }
                    }
                }
                Toggle("We write lock screen info", isOn: $writesNowPlaying)
                    .onChange(of: writesNowPlaying) { _, on in
                        AudioPlayer.writesNowPlayingForAppleMusic = on
                    }
                Toggle("Release our audio session first", isOn: $releasesSession)
                    .onChange(of: releasesSession) { _, on in
                        AppleMusicEngine.releasesSession = on
                    }
                Toggle("Hold our session mixable (overrides release)", isOn: $mixableSession)
                    .onChange(of: mixableSession) { _, on in
                        AppleMusicEngine.holdsMixableSession = on
                    }
                Toggle("Pad MusicKit's queue (lock screen next/previous)", isOn: $padsQueue)
                    .onChange(of: padsQueue) { _, on in
                        AppleMusicEngine.padsQueue = on
                    }
            }
            Section {
                TextField("Search Apple Music", text: $query)
                    .onSubmit { Task { await search() } }
                    .autocorrectionDisabled()
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Start a Plex album first, then Play Next a song here: the queue hands Plex → Apple Music → Plex. Logs: category AppleMusic.")
            }
            Section("Results") {
                ForEach(results) { song in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(song.title)
                            Text("\(song.artistName) · \(song.albumTitle ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Play Now") { enqueue(song, .now) }
                            Button("Play Next") { enqueue(song, .next) }
                            Button("Add to Queue") { enqueue(song, .end) }
                            Divider()
                            Button("Prewarm MusicKit with this") {
                                player.appleMusic.prewarm(song)
                            }
                            Button("Raw MusicKit (pauses Plex, no queue)") {
                                player.pause()
                                player.appleMusic.rawPlay(song)
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("Apple Music Spike")
        .task { await refreshSubscription() }
    }

    private enum Placement { case now, next, end }

    private func enqueue(_ song: Song, _ placement: Placement) {
        guard let library = model.library else {
            error = "No library open"
            return
        }
        let track = AppleMusic.shared.track(song, artists: [])
        switch placement {
        case .now: player.play([track], startingAt: 0, library: library)
        case .next: player.playNext([track], library: library)
        case .end: player.addToQueue([track], library: library)
        }
    }

    private func refreshSubscription() async {
        guard MusicAuthorization.currentStatus == .authorized else { return }
        do {
            canPlayCatalog = try await MusicSubscription.current.canPlayCatalogContent
        } catch {
            self.error = "\(error)"
        }
    }

    private func search() async {
        guard !query.isEmpty else { return }
        error = nil
        do {
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
            request.limit = 15
            results = Array(try await request.response().songs)
        } catch {
            self.error = "\(error)"
        }
    }
}
#endif
