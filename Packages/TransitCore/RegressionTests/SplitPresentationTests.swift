import XCTest
@testable import TransitCore

final class SplitPresentationTests: XCTestCase {
    func testTrunkTitleNamesBothDestinationsInsteadOfJunction() {
        let split = TrainFormation.Split(stopName: "Burgdorf", stopUIC: 8508005, moment: nil, portions: [
            .init(destination: "Solothurn", fromPosition: 1, toPosition: 4),
            .init(destination: "Sumiswald-Grünen", fromPosition: 5, toPosition: 8)
        ])
        XCTAssertEqual(split.destinations(continuingTo: "Burgdorf"), ["Solothurn", "Sumiswald-Grünen"])
        XCTAssertEqual(split.destinations(continuingTo: "Solothurn"), ["Solothurn", "Sumiswald-Grünen"])
        XCTAssertEqual(split.destinations(continuingTo: nil), ["Solothurn", "Sumiswald-Grünen"])
    }

    func testForeignTailIsAbsorbedAfterTheBorderStop() {
        let journey = Journey(
            id: "ec", mode: .train, category: "EC", line: "EC", number: "57",
            operatorName: "SBB", operatorFull: "SBB", to: "Domodossola (I)", from: "Basel SBB",
            delay: nil, start: 0, end: 100, complete: true, monitored: false,
            cancelled: false, source: "test",
            stops: [
                Call(key: "brig", name: "Brig", lat: 46.3, lon: 8.0, precise: true, arr: 50, dep: 55),
                Call(key: "domo", ref: "8301003", name: "Domodossola (I)", lat: 46.1, lon: 8.3,
                     precise: false, arr: 100, dep: 100),
            ]
        )
        let extras = [
            Call(key: "d", ref: "8301003", name: "Domodossola", lat: 46.1, lon: 8.3,
                 precise: false, arr: 100, dep: 105),
            Call(key: "s", ref: "8301033", name: "Stresa", lat: 45.88, lon: 8.53,
                 precise: false, arr: 140, dep: 142),
            Call(key: "m", ref: "8301003x", name: "Milano Centrale", lat: 45.49, lon: 9.18,
                 precise: false, arr: 200, dep: 200),
        ]
        XCTAssertTrue(journey.absorb(extras: extras, resolve: { _, _ in nil }))
        XCTAssertEqual(journey.stops.map(\.name), ["Brig", "Domodossola (I)", "Stresa", "Milano Centrale"])
        XCTAssertEqual(journey.to, "Milano Centrale")
    }

    func testForeignHeadIsAbsorbedBeforeTheBorderStop() {
        let journey = Journey(
            id: "ec66", mode: .train, category: "EC", line: "EC", number: "66",
            operatorName: "SBB", operatorFull: "SBB", to: "Basel SBB", from: "Domodossola (I)",
            delay: nil, start: 100, end: 400, complete: true, monitored: false,
            cancelled: false, source: "test",
            stops: [
                Call(key: "domo", ref: "8301003", name: "Domodossola (I)", lat: 46.1, lon: 8.3,
                     precise: false, arr: 100, dep: 108),
                Call(key: "brig", name: "Brig", lat: 46.3, lon: 8.0, precise: true, arr: 140, dep: 145),
                Call(key: "basel", ref: "ch:1:sloid:10", name: "Basel SBB", lat: 47.55, lon: 7.59,
                     precise: true, arr: 400, dep: 400),
            ]
        )
        let extras = [
            Call(key: "m", ref: "8301700", name: "Milano Centrale", lat: 45.49, lon: 9.18,
                 precise: false, arr: 0, dep: 0),
            Call(key: "d", ref: "8301003", name: "Domodossola", lat: 46.1, lon: 8.3,
                 precise: false, arr: 100, dep: 108),
            Call(key: "b", name: "Brig", lat: 46.3, lon: 8.0, precise: true, arr: 140, dep: 145),
            Call(key: "ba", ref: "ch:1:sloid:10", name: "Basel SBB", lat: 47.55, lon: 7.59,
                 precise: true, arr: 400, dep: 400),
            // TripInfo repeats the whole call list; that must not duplicate rows.
            Call(key: "m2", ref: "8301700", name: "Milano Centrale", lat: 45.49, lon: 9.18,
                 precise: false, arr: 0, dep: 0),
            Call(key: "d2", ref: "8301003", name: "Domodossola", lat: 46.1, lon: 8.3,
                 precise: false, arr: 100, dep: 108),
        ]
        XCTAssertTrue(journey.absorb(extras: extras, resolve: { _, _ in nil }))
        XCTAssertEqual(
            journey.stops.map(\.name),
            ["Milano Centrale", "Domodossola (I)", "Brig", "Basel SBB"]
        )
        XCTAssertEqual(journey.from, "Milano Centrale")
        XCTAssertEqual(journey.start, 0)
    }

    func testExceptionalStopInTheMiddleIsAbsorbedAndFlagged() {
        let journey = Journey(
            id: "s4", mode: .train, category: "S", line: "S4", number: "85486",
            operatorName: "SBB", operatorFull: "SBB", to: "Thun", from: "Bern",
            delay: nil, start: 0, end: 800, complete: true, monitored: false,
            cancelled: false, source: "test",
            stops: [
                Call(key: "bern", ref: "ch:1:sloid:7000", name: "Bern", lat: 46.95, lon: 7.44,
                     precise: true, arr: 0, dep: 0),
                Call(key: "belp", ref: "ch:1:sloid:7003", name: "Belp", lat: 46.89, lon: 7.50,
                     precise: true, arr: 400, dep: 400),
                Call(key: "thun", ref: "ch:1:sloid:7100", name: "Thun", lat: 46.75, lon: 7.63,
                     precise: true, arr: 800, dep: 800),
            ]
        )
        let extras = [
            Call(key: "bern", ref: "ch:1:sloid:7000", name: "Bern", lat: 46.95, lon: 7.44,
                 precise: true, arr: 0, dep: 0),
            Call(key: "euro", ref: "ch:1:sloid:6161", name: "Bern Europaplatz", lat: 46.94, lon: 7.43,
                 precise: true, arr: 180, dep: 180, extra: true),
            Call(key: "belp", ref: "ch:1:sloid:7003", name: "Belp", lat: 46.89, lon: 7.50,
                 precise: true, arr: 400, dep: 400),
            Call(key: "thun", ref: "ch:1:sloid:7100", name: "Thun", lat: 46.75, lon: 7.63,
                 precise: true, arr: 800, dep: 800),
        ]
        XCTAssertTrue(journey.absorb(extras: extras, resolve: { _, _ in nil }))
        XCTAssertEqual(
            journey.stops.map(\.name),
            ["Bern", "Bern Europaplatz", "Belp", "Thun"]
        )
        XCTAssertEqual(journey.stops.map(\.extra), [false, true, false, false])
    }

    func testUnplacedExtrasAreNotAbsorbed() {
        let journey = Journey(
            id: "ic61", mode: .train, category: "IC", line: "IC 61", number: "61",
            operatorName: "SBB", operatorFull: "SBB", to: "Basel SBB", from: "Interlaken Ost",
            delay: nil, start: 0, end: 800, complete: true, monitored: false,
            cancelled: false, source: "ojp",
            stops: [
                Call(key: "ilo", ref: "ch:1:sloid:7500", name: "Interlaken Ost",
                     lat: 46.690, lon: 7.869, precise: true, arr: 0, dep: 0),
                Call(key: "basel", ref: "ch:1:sloid:10", name: "Basel SBB",
                     lat: 47.547, lon: 7.589, precise: true, arr: 800, dep: 800),
            ]
        )
        let extras = [
            Call(key: "ghost-head", ref: "missing:1", name: "Unknown Origin",
                 lat: 0, lon: 0, arr: -400, dep: -400),
            Call(key: "ilo", ref: "ch:1:sloid:7500", name: "Interlaken Ost",
                 lat: 46.690, lon: 7.869, precise: true, arr: 0, dep: 0),
            Call(key: "ghost-mid", ref: "missing:2", name: "Empty Formation",
                 lat: 0, lon: 0, arr: 400, dep: 400, extra: true),
            Call(key: "basel", ref: "ch:1:sloid:10", name: "Basel SBB",
                 lat: 47.547, lon: 7.589, precise: true, arr: 800, dep: 800),
            Call(key: "ghost-tail", ref: "missing:3", name: "Unknown Terminus",
                 lat: 0, lon: 0, arr: 1200, dep: 1200),
        ]
        XCTAssertFalse(journey.absorb(extras: extras, resolve: { _, _ in nil }))
        XCTAssertEqual(journey.stops.map(\.name), ["Interlaken Ost", "Basel SBB"])
        XCTAssertTrue(journey.stops.allSatisfy(\.isPlaced))
    }

    func testPassingTimeInTheMiddleIsNotAbsorbedAsExceptional() {
        let journey = Journey(
            id: "ic81", mode: .train, category: "IC", line: "IC81", number: "814",
            operatorName: "SBB", operatorFull: "SBB", to: "Interlaken Ost", from: "Spiez",
            delay: nil, start: 0, end: 1080, complete: true, monitored: false,
            cancelled: false, source: "test",
            stops: [
                Call(key: "spiez", ref: "ch:1:sloid:7108", name: "Spiez", lat: 46.69, lon: 7.68,
                     precise: true, arr: 0, dep: 0),
                Call(key: "west", ref: "ch:1:sloid:7478", name: "Interlaken West", lat: 46.68, lon: 7.85,
                     precise: true, arr: 1080, dep: 1080),
            ]
        )
        let extras = [
            Call(key: "spiez", ref: "ch:1:sloid:7108", name: "Spiez", lat: 46.69, lon: 7.68,
                 precise: true, arr: 0, dep: 0),
            Call(key: "leis", ref: "ch:1:sloid:7474", name: "Leissigen", lat: 46.65, lon: 7.77,
                 precise: true, arr: 600, dep: 600),
            Call(key: "west", ref: "ch:1:sloid:7478", name: "Interlaken West", lat: 46.68, lon: 7.85,
                 precise: true, arr: 1080, dep: 1080),
        ]
        XCTAssertFalse(journey.absorb(extras: extras, resolve: { _, _ in nil }))
        XCTAssertEqual(journey.stops.map(\.name), ["Spiez", "Interlaken West"])
    }

    func testTerminatingHalfAtTheJunctionStaysInTheTitle() {
        let split = TrainFormation.Split(stopName: "Brig", stopUIC: 8501609, moment: nil, portions: [
            .init(destination: "Milano Centrale", fromPosition: 1, toPosition: 7),
            .init(destination: "Brig", fromPosition: 8, toPosition: 14)
        ])
        XCTAssertEqual(
            split.destinations(continuingTo: "Domodossola (I)"),
            ["Milano Centrale", "Brig"]
        )
    }

    func testResolvedWorkingEndpointReplacesIntermediateCoachGoal() throws {
        let formation = try XCTUnwrap(JSONDecoder().decode(
            FormationResponse.self, from: Data(SpiezDestinationFixture.incoming.utf8)
        ).digest())
        let split = try XCTUnwrap(formation.split)
        XCTAssertEqual(split.destinations(continuingTo: "Spiez", resolved: [1: "Domodossola (I)"]),
                       ["Domodossola (I)", "Zweisimmen"])
    }

    func testSelectedWaitingTrainGetsRouteBeforeDeparture() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: directory)
        let now = Int(try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-05T13:07:00+02:00")).timeIntervalSince1970)
        _ = await fleet.drawTimetable(at: Date(timeIntervalSince1970: Double(now)),
                                     in: BBox(west: 7.55, south: 46.70, east: 7.70, north: 46.85))
        let journeys = await fleet.everyRawJourney()
        let incoming = try XCTUnwrap(journeys.first { $0.journeyRef == "ch:1:sjyid:100015:16449-001" })
        XCTAssertGreaterThan(incoming.start, now)
        let geometry = await fleet.journeyGeometry(id: incoming.id)
        let route = try XCTUnwrap(geometry)
        XCTAssertEqual(route.legs.count, incoming.stops.count)
        XCTAssertNotNil(route.relation)
        let selected = await fleet.journey(id: incoming.id, at: now)
        XCTAssertEqual(selected?.geometry, route)
    }
}
