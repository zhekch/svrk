import XCTest
@testable import TransitCore

final class RunStoreTests: XCTestCase {
    private let booked = 1_788_853_080

    private func run(
        _ id: String, mode: Mode, source: String, reference: String? = nil,
        number: String = "55", offset: Int = 0, delay: Int = 0,
        route: [String] = ["a", "b", "c"], operatorName: String = "operator"
    ) -> Journey {
        let stops = route.enumerated().map { index, station in
            Call(key: station, ref: "ch:1:sloid:\(station)", name: station,
                 lat: 47, lon: 8, arr: booked + offset + index * 600 + delay * 60,
                 dep: booked + offset + index * 600 + delay * 60,
                 delay: delay == 0 ? nil : delay, sched: booked + offset + index * 600,
                 scheduledArrival: booked + offset + index * 600)
        }
        return Journey(id: id, mode: mode, category: nil,
            line: source == Journey.timetableSource ? "service" : "FEED55",
            number: number, operatorName: operatorName, operatorFull: nil,
            to: route.last, from: route[0], delay: delay == 0 ? nil : delay,
            start: stops[0].dep, end: stops.last!.arr, complete: true,
            monitored: source == "ojp", cancelled: false, source: source,
            stops: stops, journeyRef: reference)
    }

    func testGeometrySurvivesAliasAndTimetableRefreshForEveryMode() {
        for mode in Mode.allCases {
            let store = RunStore()
            let plan = run("tt", mode: mode, source: Journey.timetableSource)
            GeometryBuilder(relations: RelationStore(), railnet: RailNet()).attach(to: plan)
            let geometry = plan.geometry
            store.ingest(plan)
            store.ingest(run("tt", mode: mode, source: Journey.timetableSource))
            let live = run("live", mode: mode, source: "ojp", delay: 4)
            for index in live.stops.indices { live.stops[index].key = "live-\(index)" }
            let canonical = store.ingest(live)
            XCTAssertEqual(canonical.geometry, geometry, "\(mode): feed keys and delays do not change the path")
        }
    }

    func testGeometryIsNotReusedAfterPlatformCoordinateOrCallChanges() {
        for change in 0..<3 {
            let store = RunStore()
            let plan = run("tt", mode: .train, source: Journey.timetableSource)
            GeometryBuilder(relations: RelationStore(), railnet: RailNet()).attach(to: plan)
            store.ingest(plan)
            let live = run("live", mode: .train, source: "ojp")
            switch change {
            case 0: live.stops[1].platform = "9"
            case 1: live.stops[1].lon += 0.001
            default:
                live.stops.append(Call(key: "d", ref: "ch:1:sloid:d", name: "d",
                    lat: 47, lon: 8, arr: booked + 1800, dep: booked + 1800))
            }
            XCTAssertNil(store.ingest(live).geometry)
        }
    }

    func testEveryModeAndFeedOrderStoresOneRecordAndResolvesEveryAlias() {
        for mode in Mode.allCases {
            for order in [[0, 1, 2], [2, 1, 0], [1, 0, 2], [1, 2, 0], [0, 2, 1], [2, 0, 1]] {
                let store = RunStore()
                let inputs = [
                    run("tt:55", mode: mode, source: Journey.timetableSource,
                        reference: "ch:1:sjyid:100144:SKI-55"),
                    run("mirror:55", mode: mode, source: "mirror", number: "000055"),
                    run("live:55", mode: mode, source: "ojp", delay: 4)
                ]
                for index in order { store.ingest(inputs[index]) }
                XCTAssertEqual(store.values.count, 1, "\(mode), order \(order)")
                let canonical = store.values[0]
                XCTAssertEqual(canonical.source, "ojp")
                XCTAssertEqual(canonical.line, "service")
                XCTAssertEqual(canonical.stops[0].dep, booked + 240)
                XCTAssertEqual(canonical.journeyRef, "ch:1:sjyid:100144:SKI-55")
                for alias in ["tt:55", "mirror:55", "live:55", "ch:1:sjyid:100144:SKI-55"] {
                    XCTAssertTrue(store.journey(id: alias) === canonical)
                }
                store.ingest(run("mirror:55", mode: mode, source: "mirror"))
                XCTAssertEqual(store.values.count, 1)
                XCTAssertEqual(store.values[0].stops[0].dep, booked + 240,
                               "A late mirror response must not erase live timing")
            }
        }
    }

    func testDifferentCoursesOperatorsModesAndSplitBranchesStayDistinct() {
        for mode in Mode.allCases {
            let store = RunStore()
            store.ingest(run("a", mode: mode, source: "ojp"))
            store.ingest(run("b", mode: mode, source: "ojp", number: "56"))
            store.ingest(run("c", mode: mode, source: "ojp", operatorName: "other"))
            store.ingest(run("d", mode: mode, source: "ojp", route: ["a", "b", "fork"]))
            XCTAssertEqual(store.values.count, 4, "\(mode)")
        }
        let store = RunStore()
        for mode in Mode.allCases { store.ingest(run(mode.rawValue, mode: mode, source: "ojp")) }
        XCTAssertEqual(store.values.count, Mode.allCases.count)
    }

    func testReusedIDsKeepTheNextDepartureAndNextDayAndResolveByTime() {
        let store = RunStore()
        for offset in [0, 60, 3_600, 86_400] {
            store.ingest(run("reused", mode: .boat, source: "mirror", offset: offset))
        }
        XCTAssertEqual(store.values.count, 4)
        XCTAssertNil(store.journey(id: "reused"), "An unscoped reused ID is ambiguous")
        XCTAssertEqual(store.journey(id: "reused", at: booked + 86_400)?.start, booked + 86_400)
        store.prune(around: booked)
        XCTAssertEqual(store.values.count, 4)
        store.prune(around: booked + 4 * 86_400)
        XCTAssertTrue(store.values.isEmpty)
    }

    func testPartialBoardObservationResolvesToCompleteRun() {
        let store = RunStore()
        let plan = run("tt", mode: .bus, source: Journey.timetableSource)
        store.ingest(plan)
        let partial = run("mirror", mode: .bus, source: "mirror")
        partial.stops.removeFirst()
        partial.start = partial.stops[0].dep
        store.ingest(partial)
        XCTAssertEqual(store.values.count, 1)
        XCTAssertEqual(store.values[0].stops.count, 3)
        XCTAssertTrue(store.journey(id: "mirror") === plan)
    }

    func testMirrorDelayEnrichesTheCanonicalPlan() {
        let store = RunStore()
        store.ingest(run("tt", mode: .tram, source: Journey.timetableSource))
        store.ingest(run("mirror", mode: .tram, source: "mirror", delay: 6))
        XCTAssertEqual(store.values.count, 1)
        XCTAssertEqual(store.values[0].stops[0].dep, booked + 360)
        XCTAssertEqual(store.values[0].line, "service")
    }

    func testFleetRefreshAndRealtimeResolveTheOriginalTimetableID() async throws {
        for refresh in [false, true] {
            let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
            let now = Date(timeIntervalSince1970: Double(booked))
            let plan = run("tt:55", mode: .bus, source: Journey.timetableSource)
            await fleet.apply([plan.id: plan], summary: SiriParser.Summary(),
                              started: now, bytes: 0, source: "test", current: now)
            await fleet.ingestBoardFill([run("live:55", mode: .bus, source: "ojp", delay: 4)])
            if refresh {
                let fresh = run("tt:55", mode: .bus, source: Journey.timetableSource)
                await fleet.apply([fresh.id: fresh], summary: SiriParser.Summary(),
                                  started: now, bytes: 0, source: "test", current: now)
            }
            let report = await fleet.applyRealtime(RealtimeFeed(updates: [
                TripUpdate(tripID: "tt:55", delay: 420)
            ]), at: now)
            XCTAssertEqual(report.matchedByRef, 1)
            let raw = await fleet.everyRawJourney()
            XCTAssertEqual(raw.count, 1)
            XCTAssertEqual(raw.first?.stops[0].dep, booked + 420)
            let board = await fleet.boardFillJourneys()
            XCTAssertEqual(board.count, 1)
            XCTAssertTrue(raw.first === board.first, "Map and board must receive the same live correction")
        }
    }

    func testOneFeedBatchCannotRetainBothCanonicalAndAliasRecords() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let plan = run("a-plan", mode: .tram, source: Journey.timetableSource)
        let live = run("z-live", mode: .tram, source: "ojp", delay: 4)
        let now = Date(timeIntervalSince1970: Double(booked))
        await fleet.apply([plan.id: plan, live.id: live], summary: SiriParser.Summary(),
                          started: now, bytes: 0, source: "test", current: now)
        let raw = await fleet.everyRawJourney()
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.source, "ojp")
    }

    func testChangingFeedAliasDoesNotRetireASecondCopyOfTheVehicle() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let now = Date()
        let offset = Int(now.timeIntervalSince1970) - booked - 1_800
        let plan = run("tt", mode: .bus, source: Journey.timetableSource, offset: offset)
        await fleet.apply([plan.id: plan], summary: SiriParser.Summary(),
                          started: now, bytes: 0, source: "test", current: now)
        await fleet.ingestBoardFill([run("live", mode: .bus, source: "ojp", offset: offset)])
        let fresh = run("tt", mode: .bus, source: Journey.timetableSource, offset: offset)
        await fleet.apply([fresh.id: fresh], summary: SiriParser.Summary(),
                          started: now, bytes: 0, source: "test", current: now)
        let status = await fleet.currentStatus()
        XCTAssertEqual(status.journeys, 1)
        XCTAssertEqual(status.retained, 0, "The timetable alias is still present as the live run")
    }
}
