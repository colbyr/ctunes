import CarPlay
import Observation
import PlexKit
import UIKit

/// Drives the car screen from the shared model and player. Templates, not
/// views: an audio app gets lists, a tab bar and the system's Now Playing,
/// which is drawn from the same `MPNowPlayingInfoCenter` and remote
/// commands the lock screen already uses, so transport, shuffle and repeat
/// come for free. The lists fetch through `model.library` the way a screen
/// does, drop the active listeners' vetoes, and hand taps to `AudioPlayer`.
/// Offline, only a track with a file enters the queue, as in the item menus.
@MainActor
final class CarPlayController: NSObject, CPNowPlayingTemplateObserver {
    private let interface: CPInterfaceController
    private let model: AppModel
    private let player: AudioPlayer

    /// The root tabs, filled once the library answers and refilled when it
    /// is swapped. Kept across swaps so a phone that walks from Wi-Fi to
    /// cellular mid-browse doesn't lose its place in the stack.
    private let rotationList = CPListTemplate(title: "On Rotation", sections: [])
    private let artistsList = CPListTemplate(title: "Artists", sections: [])
    private let recentList = CPListTemplate(title: "Recently Added", sections: [])
    private let favoritesList = CPListTemplate(title: "Favorites", sections: [])
    private var tabBar: CPTabBarTemplate?

    private var albums: [PlexAlbum] = []
    private var artists: [PlexArtist] = []
    private var favorites: [PlexTrack] = []
    private var rotation: Rotation = .none
    /// The library generation the lists were fetched from; nil until then.
    private var loadedGeneration: Int?
    private var loading: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []

    /// What the root should be for the model's state. A message is a list
    /// with nothing in it but the empty-view text (and a "Try again" row
    /// when there is something to retry).
    private enum Root: Equatable {
        case message(title: String, subtitle: String, retry: Bool)
        case library
    }
    private var root: Root?

    /// A car screen holds about eight rows; sixty albums is already a scroll.
    private static let albumLimit = min(60, Int(CPListTemplate.maximumItemCount))

    init(interfaceController: CPInterfaceController, runtime: AppRuntime) {
        interface = interfaceController
        model = runtime.model
        player = runtime.player
        super.init()
        configureLists()
        configureNowPlaying()
        followModel()
        followPlayer()
    }

    /// The scene is gone: stop following the model, and stop being the Now
    /// Playing observer, which is a shared object that outlives the scene.
    func disconnect() {
        observers.forEach { $0.cancel() }
        observers = []
        loading?.cancel()
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: - Root

    private func configureLists() {
        rotationList.tabImage = UIImage(systemName: "arrow.trianglehead.2.clockwise")
        artistsList.tabImage = UIImage(systemName: "music.microphone")
        recentList.tabImage = UIImage(systemName: "clock")
        favoritesList.tabImage = UIImage(systemName: "heart.fill")
        for list in [rotationList, artistsList, recentList, favoritesList] {
            list.emptyViewTitleVariants = ["Loading…"]
        }
    }

    /// Re-evaluates the root on every state, library, section or veto
    /// change. `Observations` fires once for the current values, so the
    /// first pass sets the root at connect time.
    private func followModel() {
        let model = model
        observers.append(Task { @MainActor [weak self] in
            let changes = Observations {
                (
                    state: model.state,
                    generation: model.libraryGeneration,
                    section: model.selectedSection?.key,
                    hidden: model.roster.hiddenArtistKeys
                )
            }
            for await change in changes {
                guard let self else { return }
                self.apply(generation: change.generation)
            }
        })
    }

    private func apply(generation: Int) {
        let desired = desiredRoot()
        if desired != root {
            root = desired
            setRoot(desired)
        }
        guard desired == .library else { return }
        if loadedGeneration != generation {
            reload(generation: generation)
        } else {
            render()
        }
    }

    private func desiredRoot() -> Root {
        switch model.state {
        case .loading, .connecting:
            return .message(title: "Connecting…", subtitle: "Looking for your Plex server.", retry: false)
        case .signedOut, .linking:
            return .message(
                title: "Sign in on your iPhone",
                subtitle: "Open Tunes for Plex on your phone to link your Plex account.",
                retry: false
            )
        case .connectFailed:
            return .message(
                title: "Can't reach your server",
                subtitle: model.errorMessage ?? "No Plex server answered.",
                retry: true
            )
        case .signedIn, .offline, .reconnecting:
            guard model.selectedSection != nil else {
                return .message(
                    title: "Choose a library on your iPhone",
                    subtitle: "This server has more than one music library.",
                    retry: false
                )
            }
            return .library
        }
    }

    private func setRoot(_ root: Root) {
        switch root {
        case .message(let title, let subtitle, let retry):
            tabBar = nil
            interface.setRootTemplate(messageTemplate(title: title, subtitle: subtitle, retry: retry), animated: true, completion: nil)
        case .library:
            let bar = CPTabBarTemplate(templates: [rotationList, artistsList, recentList, favoritesList])
            tabBar = bar
            interface.setRootTemplate(bar, animated: true, completion: nil)
        }
    }

    private func messageTemplate(title: String, subtitle: String, retry: Bool) -> CPListTemplate {
        let list = CPListTemplate(title: "Tunes", sections: [])
        list.emptyViewTitleVariants = [title]
        list.emptyViewSubtitleVariants = [subtitle]
        guard retry else { return list }
        // A list with rows shows no empty view, so the message becomes a
        // row of its own above the action.
        let notice = CPListItem(text: title, detailText: subtitle)
        notice.isEnabled = false
        let again = CPListItem(text: "Try again", detailText: nil, image: UIImage(systemName: "arrow.clockwise"))
        again.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.model.connect()
                completion()
            }
        }
        list.updateSections([CPListSection(items: [notice, again])])
        return list
    }

    // MARK: - Library

    /// The same four fetches the browse root and Favorites make. A failure
    /// runs the usual rediscovery; the lists keep whatever they had.
    private func reload(generation: Int) {
        loading?.cancel()
        guard let library = model.library, let section = model.selectedSection else { return }
        loading = Task { @MainActor [weak self] in
            do {
                async let plays = library.playHistory(inSection: section.key, since: .now - Rotation.window)
                async let favorites = library.favoriteTracks(inSection: section.key)
                async let artists = library.artists(inSection: section.key)
                let albums = try await library.albums(inSection: section.key)
                // Optional: On Rotation falls back to play counts without it.
                let history = (try? await plays) ?? []
                let (favoriteTracks, artistList) = try await (favorites, artists)
                guard let self, !Task.isCancelled else { return }
                self.albums = albums
                self.artists = artistList
                self.favorites = favoriteTracks
                self.rotation = Rotation(history: history, albums: albums)
                self.loadedGeneration = generation
                self.render()
            } catch {
                guard let self, !Task.isCancelled else { return }
                await self.model.connectionLost(error)
            }
        }
    }

    /// Fills the four tabs from what was fetched, minus the artists the
    /// active listeners veto. Cheap enough to run again when a veto flips.
    private func render() {
        guard loadedGeneration != nil else { return }
        let hidden = model.roster.hiddenArtistKeys
        let visible = albums.filter { !hidden.contains($0.artistKey) }

        let onRotation = AlbumView.mostPlayed.sorted(visible, rotation: rotation).prefix(Self.albumLimit)
        rotationList.emptyViewTitleVariants = ["Nothing played yet"]
        rotationList.updateSections([CPListSection(items: onRotation.map(albumItem))])

        let recent = AlbumView.recentlyAdded.sorted(visible).prefix(Self.albumLimit)
        recentList.emptyViewTitleVariants = ["No albums"]
        recentList.updateSections([CPListSection(items: recent.map(albumItem))])

        artistsList.emptyViewTitleVariants = ["No artists"]
        artistsList.updateSections(artistSections(artists.filter { !hidden.contains($0.ratingKey) }))

        let hearted = favorites.filter { !hidden.contains($0.grandparentRatingKey ?? "") }
        favoritesList.emptyViewTitleVariants = ["No favorites yet"]
        favoritesList.emptyViewSubtitleVariants = ["Heart a track on your iPhone and it shows up here."]
        favoritesList.updateSections(favoriteSections(hearted))
    }

    /// Alphabetical, one section per initial with an index letter, capped
    /// at what the car will show.
    private func artistSections(_ artists: [PlexArtist]) -> [CPListSection] {
        let sorted = AlbumView.artist.sorted(artists).prefix(Int(CPListTemplate.maximumItemCount))
        var order: [String] = []
        var groups: [String: [CPListItem]] = [:]
        for artist in sorted {
            let initial = artist.title.first.map { $0.isLetter ? String($0).uppercased() : "#" } ?? "#"
            if groups[initial] == nil { order.append(initial) }
            groups[initial, default: []].append(artistItem(artist))
        }
        return order.map { CPListSection(items: groups[$0] ?? [], header: $0, sectionIndexTitle: $0) }
    }

    /// Newest heart first, the Favorites page's default order, under a
    /// Shuffle and a Play row.
    private func favoriteSections(_ tracks: [PlexTrack]) -> [CPListSection] {
        guard !tracks.isEmpty else { return [] }
        let ordered = tracks.enumerated().sorted { a, b in
            (a.element.lastRatedAt ?? -1, -a.offset) > (b.element.lastRatedAt ?? -1, -b.offset)
        }.map(\.element)
        let actions = CPListSection(items: [
            actionItem("Shuffle Favorites", symbol: "shuffle") { [weak self] in self?.shuffle(ordered) },
            actionItem("Play", symbol: "play.fill") { [weak self] in self?.play(ordered) },
        ])
        let rows = ordered.prefix(Int(CPListTemplate.maximumItemCount) - 2).map { track in
            trackItem(track, detail: track.grandparentTitle, in: ordered)
        }
        return [actions, CPListSection(items: rows)]
    }

    // MARK: - Drill-down

    /// The album's tracks under Play and Shuffle. The spinner on the tapped
    /// row runs until the fetch is back, which `completion` ends.
    private func showAlbum(_ album: PlexAlbum) async {
        let tracks = await tracks(of: album)
        var sections: [CPListSection] = []
        if !tracks.isEmpty {
            sections.append(CPListSection(items: [
                actionItem("Play", symbol: "play.fill") { [weak self] in self?.play(tracks) },
                actionItem("Shuffle", symbol: "shuffle") { [weak self] in self?.shuffle(tracks) },
            ]))
            let rows = tracks.prefix(Int(CPListTemplate.maximumItemCount) - 2).map { track in
                trackItem(track, detail: track.trackArtist ?? Self.duration(track), in: tracks)
            }
            sections.append(CPListSection(items: rows, header: album.parentTitle, sectionIndexTitle: nil))
        }
        let list = CPListTemplate(title: album.title, sections: sections)
        list.emptyViewTitleVariants = [offline ? "Nothing here is downloaded." : "Nothing to play."]
        push(list)
    }

    /// The artist's albums by release date under Mix Albums and Shuffle,
    /// the artist page's two hero cards.
    private func showArtist(ratingKey: String, title: String) async {
        guard let library = model.library, let section = model.selectedSection else { return }
        let albums: [PlexAlbum]
        do {
            albums = try await library.albums(forArtist: ratingKey, inSection: section.key)
        } catch {
            await model.connectionLost(error)
            return
        }
        let hidden = model.roster.hiddenArtistKeys
        var sections: [CPListSection] = []
        if !albums.isEmpty, !hidden.contains(ratingKey) {
            sections.append(CPListSection(items: [
                actionItem("Mix Albums", symbol: "square.on.square") { [weak self] in
                    guard let self else { return }
                    self.mixAlbums(await self.tracks(ofArtist: ratingKey))
                },
                actionItem("Shuffle", symbol: "shuffle") { [weak self] in
                    guard let self else { return }
                    self.shuffle(await self.tracks(ofArtist: ratingKey))
                },
            ]))
            sections.append(CPListSection(items: AlbumView.artist.sorted(albums).map(albumItem)))
        }
        let list = CPListTemplate(title: title, sections: sections)
        list.emptyViewTitleVariants = ["No albums"]
        push(list)
    }

    /// What follows the current track. A tap jumps the queue there and
    /// returns to Now Playing.
    private func showUpNext() {
        let entries = Array(player.upcoming.prefix(Int(CPListTemplate.maximumItemCount)))
        let items = entries.map { entry in
            let item = CPListItem(text: entry.item.title, detailText: entry.item.grandparentTitle)
            item.handler = { [weak self] _, completion in
                self?.player.jump(to: entry)
                self?.showNowPlaying()
                completion()
            }
            loadArtwork(entry.item.thumb, into: item)
            return item
        }
        let list = CPListTemplate(title: "Up Next", sections: items.isEmpty ? [] : [CPListSection(items: items)])
        list.emptyViewTitleVariants = ["Nothing up next"]
        push(list)
    }

    private func push(_ template: CPTemplate) {
        interface.pushTemplate(template, animated: true, completion: nil)
    }

    /// Now Playing is one shared template: pushing it twice is an error,
    /// so an instance already in the stack is popped back to instead.
    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        if interface.templates.contains(where: { $0 === nowPlaying }) {
            interface.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            push(nowPlaying)
        }
    }

    // MARK: - Rows

    private func albumItem(_ album: PlexAlbum) -> CPListItem {
        let item = CPListItem(text: album.title, detailText: album.parentTitle)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.showAlbum(album)
                completion()
            }
        }
        loadArtwork(album.thumb, into: item)
        return item
    }

    private func artistItem(_ artist: PlexArtist) -> CPListItem {
        let item = CPListItem(text: artist.title, detailText: nil)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.showArtist(ratingKey: artist.ratingKey, title: artist.title)
                completion()
            }
        }
        loadArtwork(artist.thumb, into: item)
        return item
    }

    /// A track row plays its list from that row. `userInfo` carries the
    /// rating key so `markPlaying` can find the row later.
    private func trackItem(_ track: PlexTrack, detail: String?, in list: [PlexTrack]) -> CPListItem {
        let item = CPListItem(text: track.title, detailText: detail)
        item.userInfo = track.ratingKey
        item.playingIndicatorLocation = .trailing
        item.isPlaying = player.currentTrack?.ratingKey == track.ratingKey
        item.handler = { [weak self] _, completion in
            self?.play(list, from: track)
            completion()
        }
        return item
    }

    /// A Play/Shuffle-style row with a symbol. The spinner runs until the
    /// action, which may fetch, is done.
    private func actionItem(_ title: String, symbol: String, action: @escaping @MainActor () async -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
        item.handler = { _, completion in
            Task { @MainActor in
                await action()
                completion()
            }
        }
        return item
    }

    private static func duration(_ track: PlexTrack) -> String? {
        track.durationSeconds.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
    }

    /// Follows the queue so the row of the playing track shows the
    /// indicator on every list in the stack, and loses it when the queue
    /// moves on.
    private func followPlayer() {
        let player = player
        observers.append(Task { @MainActor [weak self] in
            for await key in Observations({ player.currentTrack?.ratingKey }) {
                guard let self else { return }
                self.markPlaying(key)
            }
        })
    }

    private func markPlaying(_ key: String?) {
        var templates = interface.templates
        if let tabBar { templates += tabBar.templates }
        for case let list as CPListTemplate in templates {
            for section in list.sections {
                for case let item as CPListItem in section.items {
                    guard let rowKey = item.userInfo as? String else { continue }
                    item.isPlaying = rowKey == key
                }
            }
        }
    }

    // MARK: - Artwork

    /// Same URL the grids use, so this is normally a cache hit, drawn into
    /// the car's row size at the car's scale rather than handed over at
    /// 400px for the head unit to shrink.
    private func loadArtwork(_ thumb: String?, into item: CPListItem) {
        guard let library = model.library, let url = library.artworkURL(thumb) else { return }
        let size = CPListItem.maximumImageSize
        let scale = interface.carTraitCollection.displayScale
        Task { @MainActor [weak item] in
            guard let image = await ImageLoader.shared.image(for: url) else { return }
            let fitted = await Task.detached(priority: .userInitiated) {
                image.filling(size, scale: scale)
            }.value
            item?.setImage(fitted)
        }
    }

    // MARK: - Playback

    private var offline: Bool { model.library?.isOffline ?? false }

    /// Offline, only a track with a file can enter the queue.
    private func playable(_ tracks: [PlexTrack]) -> [PlexTrack] {
        offline ? tracks.filter { model.downloads.isAvailable($0) } : tracks
    }

    /// The whole list from the top, or from one of its tracks, then Now
    /// Playing. Nothing to play is an alert, never silence.
    private func play(_ tracks: [PlexTrack], from track: PlexTrack? = nil) {
        guard let library = model.library else { return }
        let tracks = playable(tracks)
        guard !tracks.isEmpty else { return nothingToPlay() }
        let start = track.flatMap { track in tracks.firstIndex { $0.id == track.id } } ?? 0
        player.play(tracks, startingAt: start, library: library)
        showNowPlaying()
    }

    /// Every shuffle in the app is the spread shuffle.
    private func shuffle(_ tracks: [PlexTrack]) {
        play(tracks.spreadShuffled())
    }

    /// Whole albums front to back, the album order shuffled.
    private func mixAlbums(_ tracks: [PlexTrack]) {
        play(tracks.albumShuffled())
    }

    private func nothingToPlay() {
        let alert = CPAlertTemplate(
            titleVariants: [offline ? "Nothing here is downloaded." : "Nothing to play."],
            actions: [CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                self?.interface.dismissTemplate(animated: true, completion: nil)
            }]
        )
        interface.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Every track of an album, remembered for offline like a browsed page.
    private func tracks(of album: PlexAlbum) async -> [PlexTrack] {
        guard let library = model.library else { return [] }
        do {
            let tracks = try await library.tracks(inAlbum: album.ratingKey)
            await model.rememberTracks(tracks, inAlbum: album)
            return tracks
        } catch {
            await model.connectionLost(error)
            return []
        }
    }

    private func tracks(ofArtist key: String) async -> [PlexTrack] {
        guard let library = model.library, let section = model.selectedSection else { return [] }
        do {
            return try await library.tracks(forArtist: key, inSection: section.key)
        } catch {
            await model.connectionLost(error)
            return []
        }
    }

    // MARK: - Now Playing

    /// Shuffle and repeat buttons drive the remote-command center, which
    /// the player already answers; Up Next and the artist button come here.
    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.isAlbumArtistButtonEnabled = true
        nowPlaying.updateNowPlayingButtons([CPNowPlayingShuffleButton(), CPNowPlayingRepeatButton()])
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.showUpNext() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            guard let track = self.player.currentTrack,
                  let key = track.grandparentRatingKey, let title = track.grandparentTitle
            else { return }
            await self.showArtist(ratingKey: key, title: title)
        }
    }
}

private extension UIImage {
    /// Aspect-filled into `size` points at `scale`. Covers are square, so
    /// this is a resize; anything else is cropped to the row's square.
    func filling(_ size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let ratio = max(size.width / self.size.width, size.height / self.size.height)
        let drawn = CGSize(width: self.size.width * ratio, height: self.size.height * ratio)
        let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: origin, size: drawn))
        }
    }
}
