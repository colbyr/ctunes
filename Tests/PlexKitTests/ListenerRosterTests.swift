import Foundation
import Testing
@testable import PlexKit

@Suite("Listener roster")
struct ListenerRosterTests {
    private static func artist(_ key: String) -> Veto { Veto(artistKey: key, title: key.uppercased()) }

    private func roster() -> (ListenerRoster, Listener, Listener) {
        var roster = ListenerRoster()
        let laura = roster.add(name: "Laura", paletteSize: 3)
        let kids = roster.add(name: "Kids", paletteSize: 3)
        roster.toggleVeto(Self.artist("av"), for: laura.id)
        roster.toggleVeto(Self.artist("bd"), for: laura.id)
        roster.toggleVeto(Self.artist("bd"), for: kids.id)
        roster.toggleVeto(Self.artist("bj"), for: kids.id)
        return (roster, laura, kids)
    }

    private static func track(_ key: String, album: String, artist: String) -> PlexTrack {
        let json = """
        {"ratingKey":"\(key)","title":"T\(key)","parentRatingKey":"\(album)","parentTitle":"Album \(album)",
         "grandparentRatingKey":"\(artist)","grandparentTitle":"Artist \(artist)"}
        """
        return try! JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
    }

    private static func album(_ key: String, artist: String) -> PlexAlbum {
        PlexAlbum(ratingKey: key, title: "Album \(key)", parentRatingKey: artist, parentTitle: "Artist \(artist)", year: nil, thumb: nil)
    }

    @Test("nobody listening hides nothing")
    func idle() {
        let (roster, _, _) = roster()
        #expect(roster.hidden.isEmpty)
        #expect(!roster.hides(.artist("av")))
        #expect(roster.vetoers(of: .artist("bd")).map(\.name) == ["Laura", "Kids"])
    }

    @Test("hidden is the union of active listeners' vetoes")
    func union() {
        var (roster, laura, kids) = roster()
        roster.toggleActive(laura.id)
        #expect(roster.hidden.artists == ["av", "bd"])
        roster.toggleActive(kids.id)
        #expect(roster.hidden.artists == ["av", "bd", "bj"])
        #expect(roster.active.map(\.name) == ["You", "Laura", "Kids"])
        #expect(roster.activeNames == ["you", "Laura", "Kids"])
        roster.toggleActive(laura.id)
        #expect(roster.hidden.artists == ["bd", "bj"])
    }

    @Test("an album or track is hidden by its own veto or any wider one")
    func widerVetoes() {
        var (roster, laura, _) = roster()
        roster.toggleActive(laura.id)
        roster.toggleVeto(Veto(album: Self.album("al1", artist: "ok")), for: laura.id)
        roster.toggleVeto(Veto(track: Self.track("t1", album: "al2", artist: "ok")), for: laura.id)
        let hidden = roster.hidden
        #expect(hidden == VetoSet(artists: ["av", "bd"], albums: ["al1"], tracks: ["t1"]))

        // Albums: the artist's veto or the album's own.
        #expect(hidden.hides(Self.album("x", artist: "av")))
        #expect(hidden.hides(Self.album("al1", artist: "ok")))
        #expect(!hidden.hides(Self.album("al2", artist: "ok")))
        // Inside the artist's own page only the album's veto counts.
        #expect(!hidden.hides(Self.album("x", artist: "av"), within: .artist))
        #expect(hidden.hides(Self.album("al1", artist: "ok"), within: .artist))

        // Tracks: any of the three from a library-wide list…
        #expect(hidden.hides(Self.track("t9", album: "y", artist: "av")))
        #expect(hidden.hides(Self.track("t9", album: "al1", artist: "ok")))
        #expect(hidden.hides(Self.track("t1", album: "al2", artist: "ok")))
        #expect(!hidden.hides(Self.track("t2", album: "al2", artist: "ok")))
        // …the album's and the track's inside an artist…
        #expect(!hidden.hides(Self.track("t9", album: "y", artist: "av"), within: .artist))
        #expect(hidden.hides(Self.track("t9", album: "al1", artist: "ok"), within: .artist))
        #expect(hidden.hides(Self.track("t1", album: "al2", artist: "ok"), within: .artist))
        // …only the track's inside an album, and nothing for the track itself.
        #expect(!hidden.hides(Self.track("t9", album: "al1", artist: "av"), within: .album))
        #expect(hidden.hides(Self.track("t1", album: "al1", artist: "av"), within: .album))
        #expect(!hidden.hides(Self.track("t1", album: "al1", artist: "av"), within: .track))
    }

    @Test("a scope names the wider veto that covers an item")
    func scope() {
        var (roster, laura, _) = roster()
        let track = Self.track("t1", album: "al1", artist: "bd")
        let scope = VetoScope(track: track)
        #expect(scope.veto.title == "Tt1")
        #expect(scope.veto.subtitle == "Artist bd · Album al1")
        #expect(scope.wider.map(\.target) == [.album("al1"), .artist("bd")])
        #expect(roster.listener(laura.id).flatMap(scope.covering)?.target == .artist("bd"))
        roster.toggleVeto(Veto(.album("al1"), title: "Album al1"), for: laura.id)
        #expect(roster.listener(laura.id).flatMap(scope.covering)?.target == .artist("bd"))
        roster.toggleVeto(Self.artist("bd"), for: laura.id)
        #expect(roster.listener(laura.id).flatMap(scope.covering)?.target == .album("al1"))
        #expect(VetoScope(album: Self.album("al1", artist: "bd")).wider.map(\.target) == [.artist("bd")])
        #expect(VetoScope(artistKey: "bd", title: "BD").wider.isEmpty)
    }

    @Test("the owner is first, listening by default, and vetoes like anyone")
    func owner() {
        var (roster, _, _) = roster()
        #expect(roster.listeners.first?.isOwner == true)
        #expect(roster.others.map(\.name) == ["Laura", "Kids"])
        #expect(roster.isActive(Listener.ownerID))
        roster.toggleVeto(Self.artist("zz"), for: Listener.ownerID)
        #expect(roster.hidden.artists == ["zz"])
        roster.toggleActive(Listener.ownerID)
        #expect(roster.hidden.isEmpty)
        roster.remove(Listener.ownerID)
        #expect(roster.owner.vetoes.map(\.target) == [.artist("zz")])
    }

    @Test("a roster saved before the owner entry gains one, listening")
    func legacyRoster() throws {
        let legacy = #"{"listeners":[{"id":"7B0E4D5E-5B7E-4E7A-9B6E-1C2D3E4F5A6B","name":"Laura","colorIndex":0,"vetoedArtistKeys":["av"]}],"activeIDs":["7B0E4D5E-5B7E-4E7A-9B6E-1C2D3E4F5A6B"]}"#
        let roster = try JSONDecoder().decode(ListenerRoster.self, from: Data(legacy.utf8))
        #expect(roster.listeners.map(\.name) == ["You", "Laura"])
        #expect(roster.active.map(\.name) == ["You", "Laura"])
        #expect(roster.hidden.artists == ["av"])
    }

    @Test("artist-only vetoes migrate, and are still written for older builds")
    func legacyVetoes() throws {
        let legacy = #"{"id":"7B0E4D5E-5B7E-4E7A-9B6E-1C2D3E4F5A6B","name":"Laura","colorIndex":0,"vetoedArtistKeys":["bd","av"]}"#
        let listener = try JSONDecoder().decode(Listener.self, from: Data(legacy.utf8))
        #expect(listener.vetoes == [Veto(artistKey: "av", title: ""), Veto(artistKey: "bd", title: "")])

        var updated = listener
        updated.vetoes.append(Veto(.album("al"), title: "OK Computer", subtitle: "Radiohead"))
        updated.vetoes.append(Veto(.track("t"), title: "Creep"))
        let data = try JSONEncoder().encode(updated)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json["vetoedArtistKeys"] as? [String] ?? []) == ["av", "bd"])
        let vetoes = try #require(json["vetoes"] as? [[String: Any]])
        #expect(vetoes.map { $0["kind"] as? String } == ["artist", "artist", "album", "track"])
        #expect(vetoes[2]["subtitle"] as? String == "Radiohead")
        #expect(vetoes[3]["subtitle"] == nil)
        // The new field wins when both are present.
        #expect(try JSONDecoder().decode(Listener.self, from: data) == updated)
    }

    @Test("veto toggles round-trip")
    func vetoToggle() {
        var (roster, laura, _) = roster()
        roster.toggleVeto(Self.artist("av"), for: laura.id)
        #expect(roster.listener(laura.id)?.vetoes.map(\.target) == [.artist("bd")])
        roster.toggleVeto(Self.artist("av"), for: laura.id)
        #expect(roster.listener(laura.id)?.vetoes.map(\.target) == [.artist("bd"), .artist("av")])
        // The same key under another kind is another veto.
        roster.toggleVeto(Veto(.album("av"), title: "A"), for: laura.id)
        #expect(roster.listener(laura.id)?.vetoes.count == 3)
        #expect(roster.listener(laura.id)?.vetoes(of: .album).map(\.title) == ["A"])
        roster.removeVeto(.album("av"), for: laura.id)
        #expect(roster.listener(laura.id)?.vetoes.count == 2)
    }

    @Test("un-vetoing an artist leaves their album veto alone")
    func noAbsorption() {
        var (roster, laura, _) = roster()
        roster.toggleActive(laura.id)
        roster.toggleVeto(Veto(album: Self.album("al", artist: "av")), for: laura.id)
        roster.toggleVeto(Self.artist("av"), for: laura.id)
        #expect(!roster.hidden.artists.contains("av"))
        #expect(roster.hidden.hides(Self.album("al", artist: "av")))
    }

    @Test("removing a listener also stops them listening")
    func remove() {
        var (roster, laura, _) = roster()
        roster.toggleActive(laura.id)
        roster.remove(laura.id)
        #expect(roster.others.map(\.name) == ["Kids"])
        #expect(roster.activeIDs == [Listener.ownerID])
        #expect(!roster.isActive(laura.id))
        roster.toggleActive(laura.id)
        #expect(roster.activeIDs == [Listener.ownerID])
    }

    @Test("replacing listeners keeps only the active picks that survive")
    func replaceListeners() throws {
        var (roster, laura, kids) = roster()
        roster.toggleActive(laura.id)
        roster.toggleActive(kids.id)
        var renamed = try #require(roster.listener(laura.id))
        renamed.name = "L"
        roster.toggleVeto(Self.artist("own"), for: Listener.ownerID)
        // A list from an older device has no owner entry; this one's stays.
        roster.replaceListeners(with: [renamed, Listener(name: "Sam")])
        #expect(roster.listeners.map(\.name) == ["You", "L", "Sam"])
        #expect(roster.activeIDs == [Listener.ownerID, laura.id])
        #expect(roster.hidden.artists == ["own", "av", "bd"])
    }

    @Test("colors cycle through the palette")
    func colors() {
        var roster = ListenerRoster()
        let indices = (0..<4).map { roster.add(name: "L\($0)", paletteSize: 3).colorIndex }
        #expect(indices == [1, 2, 0, 1])
    }

    @Test("survives a JSON round-trip")
    func codable() throws {
        var (roster, laura, _) = roster()
        roster.toggleActive(laura.id)
        roster.toggleVeto(Veto(track: Self.track("t", album: "al", artist: "ar")), for: laura.id)
        let data = try JSONEncoder().encode(roster)
        let decoded = try JSONDecoder().decode(ListenerRoster.self, from: data)
        #expect(decoded == roster)
    }

    @Test("names join the way a sentence would")
    func names() {
        #expect(ListenerRoster.joinNames([]) == "")
        #expect(ListenerRoster.joinNames(["Laura"]) == "Laura")
        #expect(ListenerRoster.joinNames(["Laura", "Kids"]) == "Laura & Kids")
        #expect(ListenerRoster.joinNames(["Laura", "Kids", "Sam"]) == "Laura, Kids & Sam")
        #expect(Listener(name: " laura").initial == "L")
    }
}
