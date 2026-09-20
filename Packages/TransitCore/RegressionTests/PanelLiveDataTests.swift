import XCTest
@testable import TransitCore

final class PanelLiveDataTests: XCTestCase {
    func testArrivingTrainWaitsForItsOutgoingWorkingBeforePanelPreview() {
        let stops = [
            Call(key: "Thun", name: "Thun", lat: 46.75, lon: 7.63, arr: 100, dep: 100),
            Call(key: "Bern", name: "Bern", lat: 46.95, lon: 7.44, arr: 200, dep: 200)
        ]
        var arrival = VehicleSnapshot(
            id: "arriving", mode: .train, line: "S4", to: "Bern", from: "Thun",
            lon: 7.44, lat: 46.95, moving: false, index: 1, stops: stops,
            layover: Layover(until: 299, line: "S4", to: "Burgdorf", id: "departing")
        )
        XCTAssertTrue(arrival.isStandingAtLastStop,
                      "Do not preview Bern as terminal while the Burgdorf working is unresolved")
        XCTAssertEqual(arrival.displayDestination, "Burgdorf")

        arrival.layover = nil
        XCTAssertTrue(arrival.isStandingAtLastStop,
                      "The continuation may only be found by the through-working lookup")

        arrival.moving = true
        XCTAssertFalse(arrival.isStandingAtLastStop, "An approaching train can still preview its current run")
        arrival.moving = false
        arrival.index = 0
        XCTAssertFalse(arrival.isStandingAtLastStop, "An intermediate stop needs no opening hold")
        arrival.stops = []
        arrival.index = -1
        XCTAssertFalse(arrival.isStandingAtLastStop, "An empty route is not a terminal arrival")
    }

    func testResolvedDepartureCanOpenDirectlyAtTheTurnbackStation() {
        let departure = VehicleSnapshot(
            id: "departing", mode: .train, line: "S4", to: "Burgdorf", from: "Bern",
            lon: 7.44, lat: 46.95, moving: false, index: 0, stops: [
                Call(key: "Bern", name: "Bern", lat: 46.95, lon: 7.44, arr: 300, dep: 300),
                Call(key: "Burgdorf", name: "Burgdorf", lat: 47.06, lon: 7.62, arr: 600, dep: 600)
            ]
        )
        XCTAssertFalse(departure.isStandingAtLastStop)
        XCTAssertEqual(departure.stops[departure.index].name, "Bern")
        XCTAssertEqual(departure.displayDestination, "Burgdorf")
    }

    func testBoardSnapshotResolvesLiveDataWithoutEnteringMapFleet() async throws {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let first = Call(key: "Bern", name: "Bern", lat: 46.948, lon: 7.439,
                         arr: 1_787_437_800, dep: 1_787_437_800)
        let vehicle = VehicleSnapshot(
            id: "tt:41903", mode: .train, line: "IC8", from: "Bern",
            lon: 7.439, lat: 46.948, stops: [first],
            journeyRef: "ch:1:sjyid:100001:818-001"
        )
        let absent = await fleet.journeyRef(for: vehicle.id)
        XCTAssertNil(absent, "A board-only run need not exist in the map fleet")
        let key = try XCTUnwrap(LoadService.Key(vehicle: vehicle))
        XCTAssertEqual(key.journeyID, "ch:1:sjyid:100001:818-001")
        XCTAssertEqual(key.day, "2026-08-23")
    }

    func testDelayedDepartureAfterMidnightKeepsItsScheduledServiceDay() throws {
        var first = Call(key: "Bern", name: "Bern", lat: 46.948, lon: 7.439,
                         arr: 1_787_437_800, dep: 1_787_437_800)
        first.sched = 1_787_435_400 // Scheduled 23:50, actually leaving 00:30.
        var vehicle = VehicleSnapshot(
            id: "tt:41903", mode: .train, line: "IC8", from: "Bern",
            lon: 7.439, lat: 46.948, stops: [first], journeyRef: "published-run"
        )
        XCTAssertEqual(LoadService.Key(vehicle: vehicle)?.day, "2026-08-22")
        vehicle.stops[0].sched! += 86_400
        vehicle.stops[0].dep += 86_400
        XCTAssertEqual(LoadService.Key(vehicle: vehicle)?.day, "2026-08-23",
                       "The same timetable ID on another day needs another request key")
        vehicle.journeyRef = nil
        XCTAssertNil(LoadService.Key(vehicle: vehicle), "Never send an internal timetable ID to OJP")
    }
}
