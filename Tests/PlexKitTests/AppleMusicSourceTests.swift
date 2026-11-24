import Foundation
import Testing
@testable import PlexKit

@Suite("Apple Music source")
struct AppleMusicSourceTests {
    static func album(_ title: String, by artist: String) -> PlexAlbum {
        PlexAlbum(ratingKey: UUID().uuidString, title: title, parentRatingKey: "a", parentTitle: artist, year: nil, thumb: nil)
    }

    static func track(_ title: String, by artist: String, credited: String? = nil) -> PlexTrack {
        let credit = credited.map { ",\"originalTitle\":\"\($0)\"" } ?? ""
        let json = "{\"ratingKey\":\"\(UUID().uuidString)\",\"title\":\"\(title)\",\"grandparentTitle\":\"\(artist)\"\(credit)}"
        return try! JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
    }

    @Test func keysRoundTrip() {
        let track = PlexTrack.appleMusic(id: "1440857781", title: "Pale Blue Eyes", artist: "The Velvet Underground",
                                         artistKey: "vu", album: "The Velvet Underground", albumID: "1440857061",
                                         index: 4, disc: 1, duration: 340.5,
                                         artwork: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/a/b/600x600bb.jpg"))
        #expect(track.isAppleMusic)
        #expect(track.appleMusicID == "1440857781")
        #expect(track.parentRatingKey == "am-album:1440857061")
        #expect(track.grandparentRatingKey == "vu")
        #expect(track.duration == 340_500)
        #expect(track.part == nil)
        #expect(AppleMusicID.album(in: track.parentRatingKey) == "1440857061")
        #expect(AppleMusicID.song(in: "12345") == nil)
    }

    /// The queue's snapshot and search's recents store tracks whole.
    @Test func survivesCoding() throws {
        let track = PlexTrack.appleMusic(id: "1", title: "Song", artist: "Artist", album: "Album", albumID: "2", duration: 61)
        let back = try JSONDecoder().decode(PlexTrack.self, from: JSONEncoder().encode(track))
        #expect(back == track)
        #expect(back.isAppleMusic)
        let album = PlexAlbum.appleMusic(id: "2", title: "Album", artist: "Artist", year: 1969, trackCount: 10)
        let albumBack = try JSONDecoder().decode(PlexAlbum.self, from: JSONEncoder().encode(album))
        #expect(albumBack == album)
        #expect(albumBack.appleMusicID == "2")
    }

    @Test func aLibraryTrackIsNotAppleMusic() {
        #expect(!Self.track("Song", by: "Artist").isAppleMusic)
        #expect(!Self.album("Album", by: "Artist").isAppleMusic)
    }

    @Test func albumIDFromASongsLink() {
        let url = URL(string: "https://music.apple.com/us/album/pale-blue-eyes/1440857061?i=1440857781")
        #expect(AppleMusicID.album(inSongURL: url) == "1440857061")
        #expect(AppleMusicID.album(inSongURL: URL(string: "https://music.apple.com/us/song/pale-blue-eyes/1440857781")) == nil)
        #expect(AppleMusicID.album(inSongURL: nil) == nil)
    }

    @Test func artworkIsItsOwnURLAtTheSizeAsked() {
        let thumb = "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/ab/cd/cover.jpg/600x600bb.jpg"
        #expect(AppleMusicID.artwork(thumb, size: 400)?.absoluteString
                == "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/ab/cd/cover.jpg/400x400bb.jpg")
        #expect(AppleMusicID.artwork("https://example.com/cover.jpg", size: 400)?.absoluteString == "https://example.com/cover.jpg")
        #expect(AppleMusicID.artwork("/library/metadata/649/thumb/1746246600", size: 400) == nil)
        // And through the library's own builder, which every screen asks.
        let url = PlexLibrary.artworkURL(thumb, size: 900, base: URL(string: "http://10.0.0.2:32400")!, token: "t")
        #expect(url?.host == "is1-ssl.mzstatic.com")
        #expect(url?.lastPathComponent == "900x900bb.jpg")
    }

    @Test func namesFold() {
        #expect(MusicMatch.key("The Velvet Underground") == MusicMatch.key("velvet underground"))
        #expect(MusicMatch.key("Beyoncé") == MusicMatch.key("Beyonce"))
        #expect(MusicMatch.key("Simon & Garfunkel") == MusicMatch.key("Simon and Garfunkel"))
        #expect(MusicMatch.key("Don’t Look Back") == MusicMatch.key("Dont Look Back"))
        #expect(MusicMatch.key("The The") == "the")
        #expect(MusicMatch.key("The") == "the")
    }

    @Test func editionsAreTheSameRecord() {
        #expect(MusicMatch.key("OK Computer (Deluxe Edition)") == MusicMatch.key("OK Computer"))
        #expect(MusicMatch.key("Rumours (2004 Remaster)") == MusicMatch.key("Rumours"))
        #expect(MusicMatch.key("Loaded [Fully Loaded Edition]") == MusicMatch.key("Loaded"))
        #expect(MusicMatch.key("Motion Sickness - Single") == MusicMatch.key("Motion Sickness"))
        #expect(MusicMatch.key("Abbey Road - 2019 Remaster") == MusicMatch.key("Abbey Road"))
        #expect(MusicMatch.key("Stay (feat. Justin Bieber)") == MusicMatch.key("Stay"))
    }

    /// A false match would hide something the library lacks.
    @Test func differentRecordsStayDifferent() {
        #expect(MusicMatch.key("Weezer (Blue Album)") != MusicMatch.key("Weezer (Green Album)"))
        #expect(MusicMatch.key("Led Zeppelin II") != MusicMatch.key("Led Zeppelin III"))
        #expect(MusicMatch.key("Live - At Leeds") != MusicMatch.key("Live"))
        #expect(MusicMatch.key("Mellon Collie and the Infinite Sadness") != MusicMatch.key("Mellon Collie"))
    }

    @Test func ownedAlbumsAndSongs() {
        let owned = MusicMatch.Owned(
            albums: [Self.album("Loaded", by: "The Velvet Underground")],
            tracks: [Self.track("Heroin", by: "The Velvet Underground"),
                     Self.track("Under Pressure", by: "Queen", credited: "Queen & David Bowie")]
        )
        #expect(owned.owns(album: "Loaded (Remastered)", artist: "Velvet Underground"))
        #expect(!owned.owns(album: "Loaded", artist: "Metallica"))
        #expect(!owned.owns(album: "White Light/White Heat", artist: "The Velvet Underground"))
        #expect(owned.owns(albumTitled: "Loaded: Re-Loaded 45th Anniversary Edition") == false)
        #expect(owned.owns(albumTitled: "Loaded (45th Anniversary Edition)"))
        // The track itself, a credited artist's, or anything on an owned album.
        #expect(owned.owns(song: "Heroin", artist: "The Velvet Underground", album: "The Velvet Underground & Nico"))
        #expect(owned.owns(song: "Under Pressure", artist: "Queen & David Bowie", album: nil))
        #expect(owned.owns(song: "Sweet Jane", artist: "The Velvet Underground", album: "Loaded"))
        #expect(!owned.owns(song: "Pale Blue Eyes", artist: "The Velvet Underground", album: "The Velvet Underground"))
    }

    @Test func artistKeyByName() {
        let artists = [PlexArtist(ratingKey: "vu", title: "The Velvet Underground"), PlexArtist(ratingKey: "sr", title: "Sigur Rós")]
        #expect(MusicMatch.artistKey(for: "Velvet Underground", in: artists) == "vu")
        #expect(MusicMatch.artistKey(for: "Sigur Ros", in: artists) == "sr")
        #expect(MusicMatch.artistKey(for: "Nico", in: artists) == nil)
        #expect(MusicMatch.artistKey(for: "", in: artists) == nil)
    }

    @Test func oneAlbumPerTitle() {
        let titles = ["In Rainbows", "In Rainbows (Deluxe)", "Kid A", "In Rainbows"]
        #expect(MusicMatch.uniqued(titles) { $0 } == ["In Rainbows", "Kid A"])
    }

    /// Songs with no library artist group by name, not all together.
    @Test func shuffleGroupsByNameWithoutAKey() {
        let a = PlexTrack.appleMusic(id: "1", title: "One", artist: "Nico")
        let b = PlexTrack.appleMusic(id: "2", title: "Two", artist: "Can")
        let group = PlexTrack.shuffleGrouping[0]
        #expect(group(a) != group(b))
        #expect(group(a) == "Nico")
    }
}
