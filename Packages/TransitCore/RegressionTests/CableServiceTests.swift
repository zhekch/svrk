import XCTest
@testable import TransitCore

final class CableServiceTests: XCTestCase {
    private func calls(at departure: Int, duration: Int = 300, reverse: Bool = false) -> [Call] {
        let a = Call(key: "a", ref: "ch:1:sloid:100", name: "Valley", lat: 46.9, lon: 7.4,
                     arr: departure, dep: departure)
        let b = Call(key: "b", ref: "ch:1:sloid:101", name: "Summit", lat: 46.91, lon: 7.4,
                     arr: departure + duration, dep: departure + duration)
        if !reverse { return [a, b] }
        var reversed = [b, a]
        reversed[0].arr = departure; reversed[0].dep = departure
        reversed[1].arr = departure + duration; reversed[1].dep = departure + duration
        return reversed
    }

    private func vehicle(_ id: String = "cabin", lon: Double = 7.4, reverse: Bool = false) -> VehicleSnapshot {
        VehicleSnapshot(id: id, mode: .cable, line: "1", operatorName: "Lift",
                        from: reverse ? "Summit" : "Valley", lon: lon, lat: 46.9,
                        stops: calls(at: 1000, reverse: reverse))
    }

    private func journey(_ departure: Int, reverse: Bool = false, duration: Int = 300) -> Journey {
        Journey(id: "run-\(departure)-\(reverse)", mode: .cable, category: nil, line: "1",
                number: nil, operatorName: "Lift", operatorFull: nil, to: "Summit", from: "Valley",
                delay: nil, start: departure, end: departure + duration, complete: true,
                monitored: false, cancelled: false, source: "test",
                stops: calls(at: departure, duration: duration, reverse: reverse))
    }

    func testNearbyRunsMergeAcrossCoordinateCellsAndKeepSelection() {
        let a = vehicle("a", lon: 7.400004)
        let b = vehicle("b", lon: 7.40008, reverse: true)
        let c = vehicle("c", lon: 7.40015)
        let found = CableService.collapse([a, b, c], selectedID: "b")
        XCTAssertEqual(found.map(\.id), ["b"])
        XCTAssertEqual(found[0].lon, b.lon)
    }

    func testDifferentServicesAndSeparatedCabinsRemainSeparate() {
        let a = vehicle("a")
        var otherLine = vehicle("line"); otherLine.line = "2"
        var otherOperator = vehicle("operator"); otherOperator.operatorName = "Other"
        var branch = vehicle("branch"); branch.stops[1].ref = "ch:1:sloid:102"
        var bus = vehicle("bus"); bus.mode = .bus
        let separated = vehicle("distant", lon: 7.401)
        let vehicles = [a, otherLine, otherOperator, branch, bus, separated]
        XCTAssertEqual(CableService.collapse(vehicles, selectedID: nil).count, vehicles.count)
    }

    func testFrequencyDeduplicatesRunsAndSeparatesDirections() {
        let journeys = [journey(1000), journey(1000), journey(1600), journey(2200),
                        journey(1300, reverse: true), journey(1900, reverse: true)]
        let summary = CableService.summarize(vehicle(), journeys: journeys)
        XCTAssertEqual(summary.headwaySeconds, 600)
        XCTAssertEqual(summary.journeySeconds, 300)
        XCTAssertEqual(summary.frequencyText, "About every 10 min")
        XCTAssertFalse(summary.usesServiceCard)
    }

    func testFrequentGondolaUsesServiceCardButSparseShuttleDoesNot() {
        let summary = CableService.summarize(vehicle(), journeys: [journey(1000), journey(1060), journey(1120)])
        XCTAssertTrue(summary.usesServiceCard)
        XCTAssertEqual(summary.headwaySeconds, 60)
        let sparse = CableService.summarize(vehicle(), journeys: [journey(1000), journey(1900), journey(2800)])
        XCTAssertFalse(sparse.usesServiceCard)
    }

    func testMissingFrequencyIsOmittedAndDuplicateTimesNeverMeanContinuousService() {
        let summary = CableService.summarize(vehicle(), journeys: [journey(1000), journey(1000), journey(1000)])
        XCTAssertNil(summary.headwaySeconds)
        XCTAssertNil(summary.frequencyText)
        var noCalls = vehicle(); noCalls.stops = []
        XCTAssertNil(CableService.summarize(noCalls, journeys: []).journeyTimeText)
    }

    func testZeroMinuteLiftJourneyDoesNotClaimZeroTravelTime() {
        var lift = vehicle(); lift.category = "ASC"
        let summary = CableService.summarize(lift, journeys: [journey(1000, duration: 0)])
        XCTAssertTrue(summary.usesServiceCard)
        XCTAssertEqual(summary.journeyTimeText, "Under 1 min")
    }

    func testBernLiftFromBundledTimetableGroupsAndHasFrequency() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: FileManager.default.temporaryDirectory.appendingPathComponent("cable-\(UUID().uuidString).xml"))
        _ = await fleet.load(from: directory, supporting: false)
        let moment = try XCTUnwrap(OJPTimings.time("2026-09-05T12:39:00Z"))
        let region = BBox(west: 7.445, south: 46.943, east: 7.457, north: 46.950)
        _ = await fleet.drawTimetable(at: Date(timeIntervalSince1970: Double(moment)), in: region)
        let all = await fleet.vehicles(in: region, at: moment, withGeometry: false)
        let lifts = all.filter { $0.mode == .cable && $0.line == "2352" }
        XCTAssertGreaterThan(lifts.count, 1)
        let grouped = CableService.collapse(lifts, selectedID: nil)
        XCTAssertEqual(grouped.count, 1)
        let lift = try XCTUnwrap(grouped.first)
        let summary = await fleet.cableService(for: lift, at: moment)
        XCTAssertNotNil(summary.frequencyText)
        XCTAssertNotNil(summary.journeyTimeText)
        XCTAssertTrue(summary.usesServiceCard)
        print("Bern lift: \(summary.frequencyText ?? "nil"), journey \(summary.journeyTimeText ?? "nil")")
    }
}
