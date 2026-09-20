import XCTest
@testable import TransitCore

final class KientalOperatorTests: XCTestCase {
    func testBus220WithoutAJourneyReferenceResolvesPostAuto() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("timetable.bin").path
        ), "Bundled timetable is required")
        let fleet = Fleet(snapshotURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("kiental-operator-\(UUID().uuidString).xml"))
        _ = await fleet.load(from: directory, supporting: false)
        let moment = try XCTUnwrap(OJPTimings.time("2026-09-05T09:56:00Z"))
        let loaded = await fleet.drawTimetable(
            at: Date(timeIntervalSince1970: Double(moment)),
            behind: 12 * 3600, ahead: 12 * 3600,
            in: BBox(west: 7.65, south: 46.53, east: 7.80, north: 46.65)
        )
        XCTAssertTrue(loaded)
        let journeys = await fleet.everyRawJourney()
        let buses = journeys.filter {
            $0.mode == .bus && $0.line == "220"
                && $0.stops.contains { $0.name.contains("Ramslauenen") }
                && $0.stops.contains { $0.name.contains("Reichenbach") }
        }
        XCTAssertFalse(buses.isEmpty)
        XCTAssertTrue(buses.contains { $0.journeyRef == nil },
                      "Exercise the missing-reference path shown in the screenshot")
        XCTAssertTrue(buses.allSatisfy { $0.operatorName == "PAG" },
                      "Agency 801 must still name PostAuto when no journey reference exists")
    }
}
