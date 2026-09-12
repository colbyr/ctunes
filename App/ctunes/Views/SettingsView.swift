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
    @State private var confirmingSignOut = false

    private enum Page: Hashable {
        case listeners
        case storage
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
                case .storage:
                    StorageList(model: model)
                }
            }
            .navigationDestination(for: DownloadRoute.self) { route in
                switch route {
                case .artist(let key): DownloadedArtistPage(model: model, key: key)
                case .album(let album): DownloadedAlbumPage(model: model, album: album)
                }
            }
        }
        .task {
            #if DEBUG
            // `storage` lands on the Storage page, for simulator checks.
            if ProcessInfo.processInfo.environment["CTUNES_DEV_SETTINGS"] == "storage" {
                path.append(Page.storage)
            }
            #endif
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
        let names = model.roster.others.map(\.name)
        return names.isEmpty ? "Just you" : ListenerRoster.joinNames(["You"] + names)
    }

    @ViewBuilder private var storageSection: some View {
        Section {
            NavigationLink(value: Page.storage) {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage")
                        Text(storageSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Downloads are the artists, albums, tracks and favorites you keep offline. The play cache holds recently played and upcoming tracks so they don't stream twice.")
        }
    }

    /// "1.2 GB downloaded · 2 artists, 5 albums" under the Storage row.
    private var storageSummary: String {
        let inventory = model.downloads.inventory
        var parts: [String] = []
        if !inventory.artists.isEmpty { parts.append(DownloadText.count(inventory.artists.count, "artist")) }
        if !inventory.albums.isEmpty { parts.append(DownloadText.count(inventory.albums.count, "album")) }
        if !inventory.tracks.isEmpty { parts.append(DownloadText.count(inventory.tracks.count, "track")) }
        if inventory.favoritesPinned { parts.append("favorites") }
        let size = "\(DownloadText.bytes(model.downloads.usage)) downloaded"
        return parts.isEmpty ? size : "\(size) · \(parts.joined(separator: ", "))"
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

}
