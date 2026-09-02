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
        #expect(roster.active.map(\.name) == ["Laura", "Kids"])
        roster.toggleActive(laura.id)
        #expect(roster.hiddenArtistKeys == ["bd", "bj"])
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
        #expect(roster.listeners.map(\.name) == ["Kids"])
        #expect(roster.activeIDs.isEmpty)
        #expect(!roster.isActive(laura.id))
        roster.toggleActive(laura.id)
        #expect(roster.activeIDs.isEmpty)
    }

    @Test("colors cycle through the palette")
    func colors() {
        var roster = ListenerRoster()
        let indices = (0..<4).map { roster.add(name: "L\($0)", paletteSize: 3).colorIndex }
        #expect(indices == [0, 1, 2, 0])
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
