import XCTest
@testable import TransitCore

final class MapMotionTests: XCTestCase {
    private let region = BBox(west: 7.50, south: 46.72, east: 7.69, north: 46.86)
    private let noon = OJPTimings.time("2026-09-05T10:00:00Z")!

    private func fleet() async throws -> Fleet {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("timetable.bin").path
        ), "Bundled timetable is required")
        let fleet = Fleet(snapshotURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("map-motion-\(UUID().uuidString).xml"))
        _ = await fleet.load(from: directory, supporting: false)
        let drawn = await fleet.drawTimetable(
            at: Date(timeIntervalSince1970: Double(noon)), in: region
        )
        XCTAssertTrue(drawn)
        return fleet
    }

    func testS44LeavesThunWithoutSelectionAndSelectingDoesNotRepositionIt() async throws {
        let fleet = try await fleet()
        let journeys = await fleet.everyRawJourney()
        let run = try XCTUnwrap(journeys.sorted { $0.id < $1.id }.first { journey in
            journey.line == "S44" && journey.stops.first?.name == "Thun"
                && journey.stops[0].dep >= noon && journey.stops.count > 1
        })
        let thun = try XCTUnwrap(run.stops.firstIndex { $0.name == "Thun" })
        XCTAssertLessThan(thun, run.stops.count - 1)
        let departure = Positioning.departsAt(run, thun)
        let initial = await fleet.vehicles(in: region, at: departure,
                                          withGeometry: false)
        let standing = try XCTUnwrap(initial.first { $0.id == run.id })
        XCTAssertFalse(standing.moving)
        var final = standing
        // Keep exactly the same viewport, with no selected ID. Simulate the
        // slowest visible-map cadence across departure and a minute of travel.
        for second in 1...60 {
            let frame = await fleet.vehicles(in: region, at: departure + second,
                                             withGeometry: false)
            final = try XCTUnwrap(frame.first { $0.id == run.id })
        }
        XCTAssertTrue(final.moving)
        XCTAssertGreaterThan(Geo.metres(
            Coord(lon: standing.lon, lat: standing.lat),
            Coord(lon: final.lon, lat: final.lat)
        ), 100)
        let panel = await fleet.journey(id: final.id, at: departure + 60)
        XCTAssertNotNil(panel)
        let selected = await fleet.vehicles(in: region, at: departure + 60,
                                            withGeometry: false, including: final.id)
        let tapped = try XCTUnwrap(selected.first { $0.id == final.id })
        XCTAssertEqual(tapped.lon, final.lon, accuracy: 0.000001)
        XCTAssertEqual(tapped.lat, final.lat, accuracy: 0.000001)
    }

    func testMonitoredTrainsRemainEligibleAndRecentAnswersDoNotStarveOthers() async throws {
        let fleet = try await fleet()
        let candidates = await fleet.awaitingLiveTiming(in: region, at: noon, limit: 100)
        XCTAssertGreaterThan(candidates.count, 1)
        let first = try XCTUnwrap(candidates.first)
        let journeys = await fleet.everyRawJourney()
        let run = try XCTUnwrap(journeys.first { $0.id == first.id })
        run.monitored = true
        let refreshed = await fleet.awaitingLiveTiming(in: region, at: noon, limit: 100)
        XCTAssertTrue(refreshed.contains { $0.id == first.id },
                      "Monitored is provenance, not a permanent freshness flag")
        let held = Set(candidates.dropLast().map(\.ref))
        let next = await fleet.awaitingLiveTiming(
            in: region, at: noon, limit: 1, excludingJourneyRefs: held
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertFalse(held.contains(try XCTUnwrap(next.first).ref),
                       "Fresh answers must be removed before applying the limit")
    }
}
