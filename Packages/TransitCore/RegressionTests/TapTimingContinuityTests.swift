import XCTest
@testable import TransitCore

final class TapTimingContinuityTests: XCTestCase {
    private let start = 1_800_000_000

    private func train(duration: Int = 600) -> Journey {
        Journey(
            id: "running", mode: .train, category: "S", line: "S4", number: nil,
            operatorName: nil, operatorFull: nil, to: "Burgdorf", from: "Bern",
            delay: nil, start: start, end: start + duration, complete: true,
            monitored: false, cancelled: false, source: Journey.timetableSource,
            stops: [
                Call(key: "bern", ref: "bern", name: "Bern", lat: 46.95, lon: 7.44,
                     arr: start, dep: start, sched: start),
                Call(key: "burgdorf", ref: "burgdorf", name: "Burgdorf", lat: 47.05, lon: 7.62,
                     arr: start + duration, dep: start + duration, sched: start + duration)
            ]
        )
    }

    private func onTime(_ run: Journey, seconds: Int) -> JourneyTiming {
        JourneyTiming(byStop: [
            "bern": CallTiming(planned: start + seconds, expectedDeparture: start + seconds,
                               plannedDeparture: start + seconds),
            "burgdorf": CallTiming(planned: run.end + seconds, expectedArrival: run.end + seconds,
                                   plannedArrival: run.end + seconds)
        ])
    }

    func testOnTimePrecisionUpdateDoesNotReturnDepartedTrainToPlatform() throws {
        let run = train()
        let now = start + 25
        let before = try XCTUnwrap(Positioning.position(of: run, at: now))
        XCTAssertTrue(before.moving)
        XCTAssertEqual(run.apply(onTime(run, seconds: 20), at: now), 2)
        XCTAssertEqual(run.delay, 0, "The operator still reports this service as on time")
        let corrected = try XCTUnwrap(Positioning.position(of: run, at: Double(now), settling: false))
        XCTAssertFalse(corrected.moving, "This fixture must reproduce a correction back to Bern")

        var previous = before.progress
        for step in 0...240 {
            let stamp = Double(now) + Double(step) / 4
            let drawn = try XCTUnwrap(Positioning.position(of: run, at: stamp))
            XCTAssertTrue(drawn.moving, "An already-departed train must not announce departure again")
            XCTAssertGreaterThanOrEqual(drawn.progress, previous - 1e-8)
            previous = drawn.progress
        }
        XCTAssertNil(run.settle)
    }

    func testRepeatedSmallUpdatesPreserveCurrentDrawnProgress() throws {
        let run = train()
        var last = try XCTUnwrap(Positioning.position(of: run, at: start + 120)).progress
        for elapsed in 0...90 {
            let now = start + 120 + elapsed
            if elapsed == 0 || elapsed == 10 || elapsed == 20 {
                let seconds = 10 + elapsed / 2
                let timing = JourneyTiming(byStop: [
                    "bern": CallTiming(planned: start, expectedDeparture: start + seconds,
                                       plannedDeparture: start),
                    "burgdorf": CallTiming(planned: start + 600, expectedArrival: start + 600 + seconds,
                                           plannedArrival: start + 600)
                ])
                _ = run.apply(timing, at: now)
            }
            let drawn = try XCTUnwrap(Positioning.position(of: run, at: now))
            XCTAssertTrue(drawn.moving)
            XCTAssertGreaterThanOrEqual(drawn.progress, last - 1e-8)
            last = drawn.progress
        }
        XCTAssertNil(run.settle)
    }

    func testSmallCorrectionNearArrivalDoesNotRunPastTheNewArrivalTime() throws {
        let run = train()
        let now = start + 598
        var previous = try XCTUnwrap(Positioning.position(of: run, at: now)).progress
        _ = run.apply(onTime(run, seconds: 20), at: now)
        for elapsed in 0..<22 {
            let drawn = try XCTUnwrap(Positioning.position(of: run, at: now + elapsed))
            XCTAssertTrue(drawn.moving)
            XCTAssertGreaterThanOrEqual(drawn.progress, previous - 1e-8)
            previous = drawn.progress
        }
        let arrived = try XCTUnwrap(Positioning.position(of: run, at: now + 22))
        XCTAssertFalse(arrived.moving)
        XCTAssertEqual(arrived.index, 1)
    }

    func testLargeDepartureDelayIsStillAppliedPromptlyWhenArrivalIsUnchanged() throws {
        let run = train()
        let now = start + 120
        _ = run.apply(JourneyTiming(byStop: [
            "bern": CallTiming(planned: start, expectedDeparture: start + 300, plannedDeparture: start)
        ]), at: now)
        XCTAssertLessThanOrEqual(run.settle?.over ?? 0, 1)
        let drawn = try XCTUnwrap(Positioning.position(of: run, at: now + 1))
        XCTAssertFalse(drawn.moving)
        XCTAssertEqual(run.delay, 5)
    }

    func testIdenticalResponseDoesNotRestartSmallCorrection() throws {
        let run = train()
        let now = start + 120
        let timing = onTime(run, seconds: 20)
        _ = run.apply(timing, at: now)
        let correction = try XCTUnwrap(run.settle)
        _ = run.apply(timing, at: now + 5)
        XCTAssertEqual(run.settle, correction)
    }

    func testStationLevelTimingDoesNotReplaceKnownPlatformGeometry() {
        for quay in [nil, "1A-D"] as [String?] {
            let run = train()
            let platformRef = "ch:1:sloid:7000:0:1"
            run.stops[0].ref = platformRef
            run.stops[0].platform = "1"
            run.stops[0].precise = true
            let geometry = JourneyGeometry(
                path: [run.stops[0].coord, Coord(lon: 7.5, lat: 47.02), run.stops[1].coord],
                legs: [0, 2], source: .osmRoute, mixed: false, legSources: [.route],
                relation: nil, ways: [], routeName: nil, refined: true
            )
            run.geometry = geometry
            _ = run.apply(JourneyTiming(byStop: [
                "ch:1:sloid:7000": CallTiming(
                    planned: start, expectedDeparture: start, plannedDeparture: start,
                    expectedQuay: quay
                )
            ]), at: start + 120)
            XCTAssertEqual(run.stops[0].ref, platformRef)
            XCTAssertTrue(run.stops[0].precise)
            XCTAssertEqual(run.geometry, geometry, "A less precise stop ID is not a changed platform")
        }
    }

    func testSelectedCardAndCameraStayWithTheMovingTrainAfterLiveRefresh() async throws {
        let run = train()
        let now = start + 25
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let date = Date(timeIntervalSince1970: Double(now))
        await fleet.apply([run.id: run], summary: SiriParser.Summary(),
                          started: date, bytes: 0, source: "test", current: date)
        let preview = await fleet.journey(id: run.id, at: now, through: false)
        var previous = try XCTUnwrap(preview).progress
        let touched = await fleet.applyTiming(onTime(run, seconds: 20), to: run.id, at: date)
        XCTAssertEqual(touched, 2)
        for elapsed in 0...60 {
            let stamp = now + elapsed
            let response = await fleet.journey(id: run.id, at: stamp)
            let card = try XCTUnwrap(response)
            XCTAssertTrue(card.moving)
            XCTAssertEqual(card.index, 0)
            XCTAssertGreaterThanOrEqual(card.progress, previous - 1e-8)
            previous = card.progress
            let target = await fleet.settledPosition(of: run.id, at: stamp)
            let camera = try XCTUnwrap(target)
            XCTAssertLessThan(Geo.metres(camera, Coord(lon: card.lon, lat: card.lat)), 2,
                              "Camera catch-up must not pull back to the uncorrected platform")
        }
    }
}
