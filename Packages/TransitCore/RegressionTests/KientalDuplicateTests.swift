import XCTest
@testable import TransitCore

final class KientalDuplicateTests: XCTestCase {
    func testMidnightBoardMergesOJPAndMirror() async throws {
        try await checkBoard(mirrorFirst: false)
    }

    func testMidnightBoardMergesWhenMirrorArrivesFirst() async throws {
        try await checkBoard(mirrorFirst: true)
    }

    func testOJPAgencyIdentifiesPostAutoWithoutSwissJourneyID() throws {
        let journeys = OJPTimings.stopEventJourneys(KientalDuplicateFixture.ojp)
        XCTAssertEqual(journeys.count, 4)
        XCTAssertTrue(journeys.allSatisfy { $0.operatorName == "ch:1:sboid:100602" })
    }

    private func checkBoard(mirrorFirst: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let places = StopPlaceStore()
        try places.load(data.appendingPathComponent("stop-places.bin"))
        let place = try XCTUnwrap(places.search("Ramslauenen").first { $0.name == "Kiental, Ramslauenen" })
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-19T22:06:00Z"))
        let mirror = MirrorBoard.journeys(from: KientalDuplicateFixture.mirror)
        let ojp = OJPTimings.stopEventJourneys(KientalDuplicateFixture.ojp)
        if mirrorFirst { await fleet.ingestBoardFill(mirror) }
        await fleet.ingestBoardFill(ojp)
        if !mirrorFirst { await fleet.ingestBoardFill(mirror) }
        let stationResult = await fleet.stationBoard(placeId: place.id, at: now)
        let station = try XCTUnwrap(stationResult)
        let ref = try XCTUnwrap(ojp.first?.stops.first { $0.name == place.name }?.ref)
        let platformResult = await fleet.platformBoard(ref: ref, at: now)
        let platform = try XCTUnwrap(platformResult)
        for boardEntries in [station.departures, platform.departures] {
            let entries = boardEntries.filter { $0.line == "220" && !$0.terminates }
            XCTAssertFalse(entries.isEmpty)
            let groups = Dictionary(grouping: entries) { "\($0.to ?? "")|\($0.departure)" }
            XCTAssertTrue(groups.values.allSatisfy { $0.count == 1 })
            for timestamp in [1789883040, 1789884420, 1789888020, 1789890240] {
                XCTAssertEqual(entries.filter { $0.departure == timestamp }.count, 1)
            }
        }
    }
}
