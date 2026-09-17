import Foundation
import Testing
@testable import PlexKit

@Suite("Saved mixes")
struct SavedMixTests {
    private static let playlist = MixPick.playlist(ratingKey: "10", title: "Road Trip", thumb: "/playlists/10/composite/1")
    private static let artist = MixPick.artist(ratingKey: "20", title: "Bon Jovi", thumb: "/library/metadata/20/thumb/1")
    private static let album = MixPick.album(ratingKey: "30", title: "Slippery When Wet", artistKey: "20", artist: "Bon Jovi", thumb: nil)

    @Test("title is the verb then the name")
    func titles() {
        #expect(SavedMix.starter.title == "Shuffle Favorites")
        #expect(SavedMix(name: "Road Trip", picks: [Self.playlist], style: .play).title == "Play Road Trip")
        #expect(SavedMix(name: "Bon Jovi", picks: [Self.artist], style: .mixAlbums).title == "Mix Albums Bon Jovi")
    }

    @Test("one album, playlist or the favorites gets Play; anything else Mix Albums")
    func styles() {
        #expect(PlayStyle.cases(for: [Self.album]) == [.play, .shuffle])
        #expect(PlayStyle.cases(for: [Self.playlist]) == [.play, .shuffle])
        #expect(PlayStyle.cases(for: [.favorites]) == [.play, .shuffle])
        #expect(PlayStyle.cases(for: [Self.artist]) == [.mixAlbums, .shuffle])
        #expect(PlayStyle.cases(for: [Self.album, Self.playlist]) == [.mixAlbums, .shuffle])
        #expect(PlayStyle.cases(for: []) == [.mixAlbums, .shuffle])
    }

    @Test("a name is suggested from the picks")
    func suggestedNames() {
        #expect(SavedMix.suggestedName(for: []) == "Everything")
        #expect(SavedMix.suggestedName(for: [Self.artist]) == "Bon Jovi")
        #expect(SavedMix.suggestedName(for: [Self.artist, Self.playlist]) == "Bon Jovi & Road Trip")
        #expect(SavedMix.suggestedName(for: [Self.artist, Self.playlist, Self.album]) == "Bon Jovi & 2 more")
    }

    @Test("round-trips through JSON, every kind of pick")
    func codable() throws {
        let mixes = [
            SavedMix.starter,
            SavedMix(name: "Everything", picks: [], style: .shuffle),
            SavedMix(name: "Jersey", picks: [Self.playlist, Self.artist, Self.album], style: .mixAlbums),
        ]
        let data = try JSONEncoder().encode(mixes)
        let decoded = try JSONDecoder().decode([SavedMix].self, from: data)
        #expect(decoded == mixes)
        #expect(decoded.map(\.style) == mixes.map(\.style))
        #expect(decoded[2].picks[0].thumb == "/playlists/10/composite/1")
        guard case .album(_, _, let artistKey, let artist, _) = decoded[2].picks[2] else {
            Issue.record("album lost its kind")
            return
        }
        #expect(artistKey == "20")
        #expect(artist == "Bon Jovi")
    }

    @Test("an unknown style from a newer build plays plain")
    func unknownStyle() throws {
        let json = #"[{"id":"00000000-0000-4000-8000-000000000002","name":"Favorites","picks":[{"kind":"favorites"}],"style":"karaoke"}]"#
        let decoded = try JSONDecoder().decode([SavedMix].self, from: Data(json.utf8))
        #expect(decoded.first?.style == .play)
        #expect(decoded.first?.picks == [.favorites])
    }

    @Test("a pick's identity is the kind and key, not the title")
    func identity() {
        let before = MixPick.playlist(ratingKey: "1", title: "Old", thumb: nil)
        let after = MixPick.playlist(ratingKey: "1", title: "New", thumb: "/x")
        #expect(before == after)
        #expect(before.id == "playlist:1")
        #expect(MixPick.favorites.id == "favorites:")
        #expect(MixPick.artist(ratingKey: "1", title: "Old", thumb: nil) != before)
    }

    @Test("an artist or album pick is hidden by its own veto or a wider one")
    func hidden() {
        let set = VetoSet(artists: ["a1"], albums: ["b2"])
        #expect(MixPick.artist(ratingKey: "a1", title: "", thumb: nil).isHidden(by: set))
        #expect(!MixPick.artist(ratingKey: "a2", title: "", thumb: nil).isHidden(by: set))
        #expect(MixPick.album(ratingKey: "b1", title: "", artistKey: "a1", artist: nil, thumb: nil).isHidden(by: set))
        #expect(MixPick.album(ratingKey: "b2", title: "", artistKey: "a2", artist: nil, thumb: nil).isHidden(by: set))
        #expect(!MixPick.album(ratingKey: "b3", title: "", artistKey: "a2", artist: nil, thumb: nil).isHidden(by: set))
        #expect(!MixPick.favorites.isHidden(by: set))
    }
}
