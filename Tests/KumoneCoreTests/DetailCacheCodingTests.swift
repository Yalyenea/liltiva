import Foundation
import Testing
@testable import KumoneCore

@Suite("Detail cache coding")
struct DetailCacheCodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func albumSummaryPreservesNormalizedAPIFields() throws {
        let summary = try decode(AlbumSummary.self, #"{"id":7,"name":"Album","cover":"cover","artists":[{"name":"A"},{"name":"B"}],"publishTime":1234,"size":12,"subType":"录音室版","alia":["Alias"]}"#)
        let cached = try roundTrip(summary)
        #expect(cached == summary)
        #expect(cached.artistName == "A / B")
        #expect(cached.alias == ["Alias"])
        #expect(cached.picUrl == "cover")
    }

    @Test func detailKeepsTracksNestedArtistAndDescription() throws {
        let response = try decode(AlbumDetailResponse.self, #"{"album":{"id":7,"name":"Album","picUrl":"cover","artist":{"id":9,"name":"Artist","avatar":"portrait","followed":true,"alias":["Alias"],"musicSize":90,"albumSize":4},"description":"Line one\nLine two","company":"Label","publishTime":1234,"size":1,"subType":"Single"},"songs":[{"id":3,"name":"Song","dt":3000}]}"#)
        let cached = try roundTrip(response)
        #expect(cached.album == response.album)
        #expect(cached.songs == response.songs)
        #expect(cached.album.artist?.followed == true)
    }

    @Test func artistFollowMutationSurvivesReopen() throws {
        var artist = try decode(ArtistSummary.self, #"{"id":9,"name":"Artist","img1v1Url":"portrait","briefDesc":"Description","followed":false}"#)
        artist.followed = true
        let cached = try roundTrip(NeteaseAPI.ArtistResponse(artist: artist, hotSongs: []))
        #expect(cached.artist == artist)
        #expect(cached.artist.followed)
        #expect(cached.artist.picUrl == "portrait")
    }

    @Test func chartsAndRecordsPreserveFields() throws {
        let chart = try decode(ToplistItem.self, #"{"id":11,"name":"Chart","coverImgUrl":"cover","updateFrequency":"每天更新","playCount":1200.0,"tracks":[{"first":"Song","second":"Artist"}]}"#)
        #expect(try roundTrip(chart) == chart)
        let record = try decode(PlayRecordItem.self, #"{"playCount":12,"score":8,"song":{"id":3,"name":"Song","dt":3000}}"#)
        #expect(try roundTrip(record) == record)
    }
}
