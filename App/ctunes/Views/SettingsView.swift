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
        case shortcuts
        case storage
    }

    private var offline: Bool { model.state == .offline }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                librarySection
                playbackSection
                downloadsSection
                listenersSection
                shortcutsSection
                storageSection
                accountSection
            }
            .settingsBackground()
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
                case .shortcuts:
                    ShortcutsList(model: model) { dismiss() }
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
            switch ProcessInfo.processInfo.environment["CTUNES_DEV_SETTINGS"] {
            case "storage": path.append(Page.storage)
            case "shortcuts": path.append(Page.shortcuts)
            default: break
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
            Text("Anything below Original is transcoded to AAC by the server, and the tracks you play are kept in the play cache at that quality. Downloaded tracks always play as stored. Takes effect from the next track.")
        }
    }

    /// The download quality mirrors the streaming one but is its own
    /// setting: downloads mostly happen at home. The cellular switch
    /// gates the whole pump, pins and the play cache alike.
    @ViewBuilder private var downloadsSection: some View {
        @Bindable var downloads = model.downloads
        Section {
            Picker("Download Quality", selection: $downloads.quality) {
                ForEach(StreamQuality.allCases, id: \.self) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.navigationLink)
            Toggle("Download on Cellular", isOn: $downloads.allowsCellular)
        } header: {
            Text("Downloads")
        } footer: {
            Text(downloadsFooter)
        }
    }

    private var downloadsFooter: String {
        var lines = ["Anything below Original is converted to MP3 by the server before it downloads, at up to the chosen bitrate. Tracks already downloaded keep their quality; remove and download again to change it."]
        lines.append(model.downloads.allowsCellular
            ? "Downloads and the play cache use cellular data."
            : "Downloads wait for Wi-Fi, and nothing played on cellular is kept.")
        return lines.joined(separator: " ")
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
            Text("Each listener can hide artists, albums and tracks. Choose who's listening from the Music screen.")
        }
    }

    private var listenersSummary: String {
        let names = model.roster.listeners.map(\.name)
        return names.isEmpty ? "No listeners" : ListenerRoster.joinNames(names)
    }

    @ViewBuilder private var shortcutsSection: some View {
        Section {
            NavigationLink(value: Page.shortcuts) {
                HStack(spacing: 12) {
                    Image(systemName: "play.square.stack")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shortcuts")
                        Text(shortcutsSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("The play buttons at the top of the Music screen: mixes saved from the Mix Builder, played in order, shuffled or mixed by album.")
        }
    }

    /// "Shuffle Favorites, Play Road Trip" under the Shortcuts row.
    private var shortcutsSummary: String {
        let titles = model.shortcuts.map(\.title)
        return titles.isEmpty ? "No shortcuts" : titles.joined(separator: ", ")
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
