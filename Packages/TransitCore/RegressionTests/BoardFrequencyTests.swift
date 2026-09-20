import XCTest
@testable import TransitCore

final class BoardFrequencyTests: XCTestCase {
    func testBernBoardCarriesScheduledFrequencyForTram8() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: FileManager.default.temporaryDirectory.appendingPathComponent("board-frequency-\(UUID().uuidString).xml"))
        _ = await fleet.load(from: directory, supporting: false)
        let moment = try XCTUnwrap(OJPTimings.time("2026-09-05T12:53:00Z"))
        let region = BBox(west: 7.42, south: 46.94, east: 7.45, north: 46.96)
        _ = await fleet.drawTimetable(at: Date(timeIntervalSince1970: Double(moment)), in: region)
        let found = await fleet.stationBoard(placeId: "8507000", at: moment, limit: 200)
        let board = try XCTUnwrap(found)
        let trams = board.departures.filter { $0.mode == .tram && $0.line == "8" && !$0.terminates }
        XCTAssertFalse(trams.isEmpty)
        XCTAssertTrue(trams.allSatisfy { ($0.typicalIntervalMinutes ?? 0) > 0 })
        XCTAssertTrue(board.departures.filter(\.terminates).allSatisfy { $0.typicalIntervalMinutes == nil })

        let entry = try XCTUnwrap(trams.first)
        let run = await fleet.journey(id: entry.id, at: moment, boardDeparture: entry.departure)
        let call = try XCTUnwrap(run?.stops.first { $0.dep == entry.departure })
        let ref = try XCTUnwrap(call.ref)
        let platform = await fleet.platformBoard(ref: ref, at: moment)
        let sameService = try XCTUnwrap(platform?.departures.first { $0.id == entry.id })
        XCTAssertEqual(sameService.typicalIntervalMinutes, entry.typicalIntervalMinutes)
    }
}
