import PlexKit

/// The fetches behind a menu item, a shortcut card and a widget's tap:
/// the tracks of an album, an artist, a playlist or a mix's picks, from
/// the page that has them or one read of the library. On the model
/// rather than `LibraryActions` because `IntentPlayback` needs them too,
/// with no presentation objects to hand. The library answers from its
/// saved copy and asks the server behind it; a miss it can't fetch is
/// nothing, and the failure is already reported.
extension AppModel {
    /// Every track of an album, from the page that has them or one read.
    func tracks(of album: PlexAlbum, known: [PlexTrack]?) async -> [PlexTrack] {
        if let known { return known }
        guard let library else { return [] }
        return (try? await library.tracks(inAlbum: album.ratingKey)) ?? []
    }

    func tracks(ofArtist key: String) async -> [PlexTrack] {
        guard let library, let section = selectedSection else { return [] }
        return (try? await library.tracks(forArtist: key, inSection: section.key)) ?? []
    }

    /// Every item of a playlist, from the page that has them or one read.
    func items(of playlist: PlexPlaylist, known: [PlaylistItem]?) async -> [PlaylistItem] {
        if let known { return known }
        guard let library else { return [] }
        return (try? await library.items(inPlaylist: playlist.ratingKey)) ?? []
    }

    /// Every track of one pick, as the server lists it.
    func tracks(of pick: MixPick) async -> [PlexTrack] {
        guard let library, let section = selectedSection else { return [] }
        switch pick {
        case .favorites:
            // Newest hearts first, the Favorites page's own default, so
            // Play starts where the list does.
            return FavoritesSort.recent.sorted((try? await library.favoriteTracks(inSection: section.key)) ?? [])
        case .playlist(let key, let title, _):
            return await items(of: PlexPlaylist(ratingKey: key, title: title), known: nil).map(\.track)
        case .artist(let key, _, _):
            return await tracks(ofArtist: key)
        case .album(let key, let title, let artistKey, let artist, let thumb):
            let album = PlexAlbum(ratingKey: key, title: title, parentRatingKey: artistKey, parentTitle: artist, year: nil, thumb: thumb)
            return await tracks(of: album, known: nil)
        }
    }

    /// Every track across the picks, fetched concurrently and laid out
    /// in pick order, each track once; no picks is the whole section.
    /// Not yet filtered: the caller decides which vetoes apply.
    func tracks(of picks: [MixPick]) async -> [PlexTrack] {
        guard let library, let section = selectedSection else { return [] }
        if picks.isEmpty {
            return (try? await library.tracks(inSection: section.key)) ?? []
        }
        let fetched = await withTaskGroup(of: (Int, [PlexTrack]).self) { group in
            for (index, pick) in picks.enumerated() {
                group.addTask { (index, await self.tracks(of: pick)) }
            }
            var all: [(Int, [PlexTrack])] = []
            for await batch in group { all.append(batch) }
            return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen: Set<String> = []
        return fetched.filter { seen.insert($0.ratingKey).inserted }
    }
}
