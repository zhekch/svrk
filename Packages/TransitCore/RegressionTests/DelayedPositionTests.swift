import XCTest
@testable import TransitCore

final class DelayedPositionTests: XCTestCase {
    private func makeJourney() -> Journey {
        Journey(id: "delayed", mode: .train, category: "S", line: "S10", number: nil,
                operatorName: nil, operatorFull: nil, to: "C", from: "A", delay: nil, start: 1000, end: 2500,
                complete: true, monitored: false, cancelled: false, source: Journey.timetableSource,
                stops: [
                    Call(key: "a", ref: "a", name: "A", lat: 46, lon: 8, arr: 1000, dep: 1000, sched: 1000),
                    Call(key: "b", ref: "b", name: "B", lat: 46.1, lon: 8, arr: 1600, dep: 1660, sched: 1660),
                    Call(key: "c", ref: "c", name: "C", lat: 46.2, lon: 8, arr: 2500, dep: 2500, sched: 2500)
                ])
    }

    func testDepartureOnlyDelayMovesArrivalOnceAndCardMatchesMap() throws {
        let journey = makeJourney()
        let timing = JourneyTiming(byStop: ["b": CallTiming(
            planned: 1660, expectedDeparture: 1960, plannedArrival: 1600, plannedDeparture: 1660
        )])
        for now in [1450, 1480, 1510] {
            _ = journey.apply(timing, at: now)
            XCTAssertEqual(journey.stops[1].arr, 1900)
            XCTAssertEqual(journey.stops[1].dep, 1960)
            XCTAssertEqual(journey.stops[1].expectedArrival, 1900)
        }
        let before = try XCTUnwrap(Positioning.position(of: journey, at: 1850))
        XCTAssertTrue(before.moving)
        XCTAssertEqual(before.index, 0)
        XCTAssertEqual(Positioning.nextStopIndex(journey.stops, at: 1850), 1)
        let atStop = try XCTUnwrap(Positioning.position(of: journey, at: 1910))
        XCTAssertFalse(atStop.moving)
        XCTAssertEqual(atStop.index, 1)
        XCTAssertEqual(Positioning.nextStopIndex(journey.stops, at: 1910), 2)
    }

    func testExplicitArrivalAndLongerDepartureDelayRemainDifferent() {
        let journey = makeJourney()
        _ = journey.apply(JourneyTiming(byStop: ["b": CallTiming(
            planned: 1660, expectedArrival: 1900, expectedDeparture: 2080,
            plannedArrival: 1600, plannedDeparture: 1660
        )]), at: 1450)
        XCTAssertEqual(journey.stops[1].expectedArrival, 1900)
        XCTAssertEqual(journey.stops[1].expectedDeparture, 2080)
        XCTAssertEqual(journey.stops[1].delay, 7)
        XCTAssertEqual(Positioning.nextStopIndex(journey.stops, at: 1950), 2)
    }

    func testRepeatedGTFSArrivalDelayDoesNotAccumulate() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let journey = makeJourney()
        let update = TripUpdate(tripID: journey.id, stops: [StopTimeUpdate(sequence: 2, arrivalDelay: 300)])
        for now in [1450, 1480, 1510] {
            _ = await fleet.apply(update, to: journey, at: now)
            XCTAssertEqual(journey.stops[1].arr, 1900)
            XCTAssertEqual(journey.stops[1].dep, 1960)
            XCTAssertEqual(journey.stops[1].scheduledArrival, 1600)
        }
    }

    func testLateCorrectionCannotLeaveMapOnOldTimesForMinutes() throws {
        let journey = makeJourney()
        let now = 1500
        _ = journey.apply(JourneyTiming(byStop: ["b": CallTiming(
            planned: 1660, expectedArrival: 1960, expectedDeparture: 2020,
            plannedArrival: 1600, plannedDeparture: 1660
        )]), at: now)
        for stamp in [now + 1, now + 30, now + 90] {
            let drawn = try XCTUnwrap(Positioning.position(of: journey, at: stamp))
            let live = try XCTUnwrap(Positioning.position(of: journey, at: Double(stamp), settling: false))
            XCTAssertEqual(drawn.lat, live.lat, accuracy: 1e-9)
            XCTAssertEqual(drawn.index, live.index)
            XCTAssertEqual(drawn.progress, live.progress, accuracy: 1e-9)
        }
    }

    func testTripLevelDelayUpdatesTheClockAsWellAsTheBadge() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let journey = makeJourney()
        for now in [1100, 1130] {
            _ = await fleet.apply(TripUpdate(tripID: journey.id, delay: 300), to: journey, at: now)
            XCTAssertEqual(journey.delay, 5)
            XCTAssertEqual(journey.stops[1].arr, 1900)
            XCTAssertEqual(journey.stops[1].dep, 1960)
        }
    }
}
