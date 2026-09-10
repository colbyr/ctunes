import Foundation
import Testing
@testable import PlexKit

@Suite("Listener roster")
struct ListenerRosterTests {
    private func roster() -> (ListenerRoster, Listener, Listener) {
        var roster = ListenerRoster()
        let laura = roster.add(name: "Laura", paletteSize: 3)
        let kids = roster.add(name: "Kids", paletteSize: 3)
        roster.toggleVeto(artistKey: "av", for: laura.id)
        roster.toggleVeto(artistKey: "bd", for: laura.id)
        roster.toggleVeto(artistKey: "bd", for: kids.id)
        roster.toggleVeto(artistKey: "bj", for: kids.id)
        return (roster, laura, kids)
    }

    @Test("nobody listening hides nothing")
    func idle() {
        let (roster, _, _) = roster()
        #expect(roster.hiddenArtistKeys.isEmpty)
        #expect(!roster.hides("av"))
        #expect(roster.vetoers(of: "bd").map(\.name) == ["Laura", "Kids"])
    }

    @Test("hidden is the union of active listeners' vetoes")
    func union() {
        var (roster, laura, kids) = roster()
        roster.toggleActive(laura.id)
        #expect(roster.hiddenArtistKeys == ["av", "bd"])
        roster.toggleActive(kids.id)
        #expect(roster.hiddenArtistKeys == ["av", "bd", "bj"])
        #expect(roster.active.map(\.name) == ["You", "Laura", "Kids"])
        #expect(roster.activeNames == ["you", "Laura", "Kids"])
        roster.toggleActive(laura.id)
        #expect(roster.hiddenArtistKeys == ["bd", "bj"])
    }

    @Test("the owner is first, listening by default, and vetoes like anyone")
    func owner() {
        var (roster, _, _) = roster()
        #expect(roster.listeners.first?.isOwner == true)
        #expect(roster.others.map(\.name) == ["Laura", "Kids"])
        #expect(roster.isActive(Listener.ownerID))
        roster.toggleVeto(artistKey: "zz", for: Listener.ownerID)
        #expect(roster.hiddenArtistKeys == ["zz"])
        roster.toggleActive(Listener.ownerID)
        #expect(roster.hiddenArtistKeys.isEmpty)
        roster.remove(Listener.ownerID)
        #expect(roster.owner.vetoedArtistKeys == ["zz"])
    }

    @Test("a roster saved before the owner entry gains one, listening")
    func legacyRoster() throws {
        let legacy = #"{"listeners":[{"id":"7B0E4D5E-5B7E-4E7A-9B6E-1C2D3E4F5A6B","name":"Laura","colorIndex":0,"vetoedArtistKeys":["av"]}],"activeIDs":["7B0E4D5E-5B7E-4E7A-9B6E-1C2D3E4F5A6B"]}"#
        let roster = try JSONDecoder().decode(ListenerRoster.self, from: Data(legacy.utf8))
        #expect(roster.listeners.map(\.name) == ["You", "Laura"])
        #expect(roster.active.map(\.name) == ["You", "Laura"])
        #expect(roster.hiddenArtistKeys == ["av"])
    }

    @Test("veto toggles round-trip")
    func vetoToggle() {
        var (roster, laura, _) = roster()
        roster.toggleVeto(artistKey: "av", for: laura.id)
        #expect(roster.listener(laura.id)?.vetoedArtistKeys == ["bd"])
        roster.toggleVeto(artistKey: "av", for: laura.id)
        #expect(roster.listener(laura.id)?.vetoedArtistKeys == ["av", "bd"])
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
        roster.toggleVeto(artistKey: "own", for: Listener.ownerID)
        // A list from an older device has no owner entry; this one's stays.
        roster.replaceListeners(with: [renamed, Listener(name: "Sam")])
        #expect(roster.listeners.map(\.name) == ["You", "L", "Sam"])
        #expect(roster.activeIDs == [Listener.ownerID, laura.id])
        #expect(roster.hiddenArtistKeys == ["own", "av", "bd"])
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
