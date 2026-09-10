import PlexKit
import SwiftUI

/// Everything that used to hang off the ••• menu on the Music screen, laid
/// out as a settings list so each item can show its current value, explain
/// itself in a footer and confirm before it destroys anything. Grouped by
/// what the reader is asking: which library, how it plays, who's listening,
/// what's on disk, and the account itself.
struct SettingsSheet: View {
    let model: AppModel
    /// Every artist in the library, for the listeners' veto lists.
    let artists: [AlbumGroup]
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    /// Bytes of cached audio, for the clear row; nil until read.
    @State private var cacheUsage: Int?
    @State private var confirmingRemoveDownloads = false
    @State private var confirmingSignOut = false

    private enum Page: Hashable {
        case listeners
    }

    private var offline: Bool { model.state == .offline }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                librarySection
                playbackSection
                listenersSection
                storageSection
                accountSection
            }
            .parchment()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .listeners:
                    ListenersList(model: model, artists: artists)
                        .navigationTitle("Listeners")
                }
            }
        }
        .task(id: player.currentTrack?.id) {
            cacheUsage = await player.cacheUsage()
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveDownloads, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { model.downloads.removeAll() }
        } message: {
            Text("Pinned albums and favorites will stream again. Nothing is removed from your library.")
        }
        .confirmationDialog("Sign out of Plex?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                dismiss()
                Task { await model.signOut() }
            }
        } message: {
            Text("Downloads and listener vetoes on this device are removed. Your library and ratings stay on the server.")
        }
    }

    // MARK: - Sections

    @ViewBuilder private var librarySection: some View {
        Section {
            LabeledContent("Server", value: model.serverName ?? "—")
            if model.sections.count > 1 {
                Picker("Library", selection: librarySelection) {
                    ForEach(model.sections) { section in
                        Text(section.title).tag(section.key)
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(offline)
            } else if let section = model.selectedSection {
                LabeledContent("Library", value: section.title)
            }
        } header: {
            Text("Library")
        } footer: {
            if offline {
                Text("Offline. Playing downloaded music until the server answers.")
            }
        }
    }

    /// Picking a library restarts the Music screen on the new section; the
    /// picker only lists what the server offered, so an unknown key can't
    /// come back from it.
    private var librarySelection: Binding<String> {
        Binding(
            get: { model.selectedSection?.key ?? "" },
            set: { key in
                guard let section = model.sections.first(where: { $0.key == key }) else { return }
                model.selectSection(section)
            }
        )
    }

    @ViewBuilder private var playbackSection: some View {
        Section {
            Picker("Streaming Quality", selection: Binding(
                get: { player.streamQuality },
                set: { player.streamQuality = $0 }
            )) {
                ForEach(StreamQuality.allCases, id: \.self) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(offline)
        } header: {
            Text("Playback")
        } footer: {
            Text("Anything below Original is transcoded to AAC by the server. Downloaded tracks always play as stored. Takes effect from the next track.")
        }
    }

    @ViewBuilder private var listenersSection: some View {
        Section {
            NavigationLink(value: Page.listeners) {
                HStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listeners")
                        Text(listenersSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Each listener can hide artists. Choose who's listening from the Music screen.")
        }
    }

    private var listenersSummary: String {
        let names = model.roster.listeners.map(\.name)
        return names.isEmpty ? "Just you" : ListenerRoster.joinNames(["You"] + names)
    }

    @ViewBuilder private var storageSection: some View {
        Section {
            Toggle("Keep Favorites Offline", isOn: Binding(
                get: { model.isFavoritesPinned },
                set: { on in Task { await model.setFavoritesPinned(on) } }
            ))
            .disabled(offline)
            LabeledContent("Downloads", value: Self.bytes(model.downloads.usage))
            if model.downloads.usage > 0 {
                Button("Remove All Downloads", role: .destructive) {
                    confirmingRemoveDownloads = true
                }
                .foregroundStyle(.red)
            }
            LabeledContent("Cached Tracks", value: Self.bytes(cacheUsage ?? 0))
            if let cacheUsage, cacheUsage > 0 {
                Button("Clear Cached Tracks") {
                    Task {
                        await player.clearCache()
                        self.cacheUsage = await player.cacheUsage()
                    }
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Downloads are albums and favorites you keep offline. Cached tracks are recently played and upcoming tracks kept so they don't stream twice; they clear themselves at 2 GB.")
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                .foregroundStyle(.red)
        } footer: {
            Text(Self.versionLine)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "ctunes \(version) (\(build))"
    }

    /// "0 KB" rather than the formatter's "Zero KB" for an empty root.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(count))
    }
}
