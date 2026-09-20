import XCTest
@testable import TransitCore

final class RE1StitchingTests: XCTestCase {
    func test4269MapSelectionIncludesBernBeforeSpiez() async throws {
        let (fleet, runs, now) = try await fixture()
        let run = try XCTUnwrap(runs.first { re1($0, "4269") && $0.start <= now && now <= $0.end })
        let read = await fleet.journey(id: run.id, at: now)
        assertThroughJourney(try XCTUnwrap(read), selectedID: run.id)
    }

    /// A working that parts ends at the junction, so both halves stay offerable.
    ///
    /// The feed names both — RE1 4269 for Domodossola and R11 6821 for
    /// Zweisimmen — and folding either one in silently turns a train that parts
    /// into a train that does not. The panel is built for this case: it shows
    /// the trunk to Spiez and offers the branches beside it, with the coaches
    /// bound for each. `loadBranches` treats a portion the vehicle already
    /// reaches as its own, so a trunk running through to Domodossola would
    /// leave only Zweisimmen to choose — the direction picker collapsing to one
    /// direction, and the formation with it.
    ///
    /// The opposite direction is not ambiguous and is still joined: 4269 has
    /// one origin, so `test4269MapSelectionIncludesBernBeforeSpiez` expects
    /// Bern. A train with two destinations and a destination with one train are
    /// different questions.
    func test4169PartsAtSpiezSoNeitherHalfIsFoldedIn() async throws {
        let (fleet, runs, now) = try await fixture()
        let run = try XCTUnwrap(runs.first { re1($0, "4169") })
        let read = await fleet.journey(id: run.id, at: now)
        let opened = try XCTUnwrap(read)
        XCTAssertEqual(opened.id, run.id)
        XCTAssertEqual(opened.from, "Bern")
        XCTAssertEqual(opened.stops.last?.name, "Spiez", "the trunk ends where it parts")
        XCTAssertEqual(opened.stops.filter { $0.name == "Spiez" }.count, 1)
        XCTAssertFalse(opened.stops.contains { $0.name == "Mülenen" },
                       "Mülenen is on the Domodossola half alone")
        XCTAssertFalse(opened.stops.contains { $0.name.contains("Zweisimmen") })
        // Both are still advertised, which is how the reader is told there is a
        // choice to make rather than being handed one of them.
        let advertised = try XCTUnwrap(opened.to)
        XCTAssertTrue(advertised.contains("Domodossola"), advertised)
        XCTAssertTrue(advertised.contains("Zweisimmen"), advertised)
    }

    /// The 15:39 out of Bern, which is the one that was reported wrong.
    ///
    /// 4177 parts at Spiez into RE1 4277 for Domodossola and R11 6829 for
    /// Zweisimmen. Ending the trunk at Spiez is right; the fix first attempted
    /// for it — running the trunk through to Domodossola — was not. It took the
    /// Zweisimmen half out of the direction picker and out of the formation,
    /// presenting a train that parts as one with a single destination.
    func testBernQuarterToFourEndsTheTrunkAtSpiezWithBothHalvesPresent() async throws {
        let data = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        // 15:39 Zurich, the departure in the screenshot.
        let now = try XCTUnwrap(OJPTimings.time("2026-09-20T13:45:00Z"))
        _ = await fleet.drawTimetable(
            at: Date(timeIntervalSince1970: Double(now)),
            in: BBox(west: 7.3, south: 45.9, east: 8.4, north: 47.0)
        )
        let runs = await fleet.everyRawJourney()
        let run = try XCTUnwrap(runs.first { re1($0, "4177") })
        let read = await fleet.journey(id: run.id, at: now)
        let opened = try XCTUnwrap(read)

        XCTAssertEqual(opened.stops.first?.name, "Bern")
        XCTAssertEqual(opened.stops.last?.name, "Spiez")
        XCTAssertEqual(opened.stops.filter { $0.name == "Spiez" }.count, 1)
        XCTAssertFalse(opened.stops.contains { $0.name.contains("Domodossola") },
                       "neither half may be folded into the trunk")
        XCTAssertFalse(opened.stops.contains { $0.name.contains("Zweisimmen") })
        // Both halves are in the fleet, which is what the picker offers from.
        XCTAssertTrue(runs.contains { re1($0, "4277") }, "the Domodossola half")
    }

    func testLivePredecessorAliasDoesNotCompeteWithItsPackedCopy() async throws {
        let (fleet, runs, now) = try await fixture()
        let predecessor = try XCTUnwrap(runs.first { re1($0, "4169") })
        let run = try XCTUnwrap(runs.first { re1($0, "4269") && $0.start <= now && now <= $0.end })
        var stops = predecessor.stops
        for index in stops.indices {
            stops[index].arr += 60
            stops[index].dep += 60
            stops[index].delay = 1
        }
        let live = Journey(
            id: "live:4169", mode: predecessor.mode, category: predecessor.category,
            line: predecessor.line, number: predecessor.number,
            operatorName: predecessor.operatorName, operatorFull: predecessor.operatorFull,
            to: predecessor.to, from: predecessor.from, delay: 1,
            start: predecessor.start + 60, end: predecessor.end + 60,
            complete: true, monitored: true, cancelled: false, source: "ojp",
            stops: stops, journeyRef: predecessor.journeyRef
        )
        await fleet.ingestBoardFill([live])
        let read = await fleet.journey(id: run.id, at: now)
        let opened = try XCTUnwrap(read)
        assertThroughJourney(opened, selectedID: run.id)
        XCTAssertEqual(opened.stops.first?.dep, stops.first?.dep,
                       "The through route must retain the live observation")
    }

    func testDifferentNumberedPredecessorsRemainAmbiguous() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        func run(_ number: String, from: String, to: String, start: Int, end: Int, platform: String) -> Journey {
            Journey(
                id: number, mode: .train, category: "RE", line: "RE1", number: number,
                operatorName: "BLS", operatorFull: nil, to: "Brig", from: from,
                delay: nil, start: start, end: end, complete: true, monitored: false,
                cancelled: false, source: Journey.timetableSource, stops: [
                    Call(key: from, name: from, lat: 46.7, lon: 7.6, platform: platform,
                         arr: start, dep: start, sched: start),
                    Call(key: to, name: to, lat: 46.6, lon: 7.7, platform: platform,
                         arr: end, dep: end, sched: end)
                ]
            )
        }
        // Different platforms keep physical map chaining out of this test;
        // both incoming passenger headsigns qualify for the through lookup.
        let a = run("4169", from: "Bern", to: "Spiez", start: 1000, end: 2800, platform: "2")
        let b = run("4171", from: "Bern", to: "Spiez", start: 1000, end: 2800, platform: "2")
        let outgoing = run("4269", from: "Spiez", to: "Brig", start: 2920, end: 6000, platform: "3")
        await fleet.apply([a.id: a, b.id: b, outgoing.id: outgoing],
                          summary: SiriParser.Summary(), started: Date(), bytes: 1, source: "test")
        let read = await fleet.journey(id: outgoing.id, at: 3000)
        XCTAssertEqual(read?.from, "Spiez", "Distinct numbered trains must not be deduplicated")
    }

    /// The BLS working, not merely something carrying that number.
    ///
    /// A train number is unique per operator and nothing more: on this day
    /// "4169" is also a Menziken bus and a Thun one. Picking by number alone
    /// therefore depended on dictionary order and failed roughly every other
    /// run, on a different assertion each time. The journey reference names the
    /// operator in it, so it picks one working and always the same one.
    private func re1(_ journey: Journey, _ number: String) -> Bool {
        journey.journeyRef == "ch:1:sjyid:100015:\(number)-001"
    }

    private func fixture() async throws -> (Fleet, [Journey], Timestamp) {
        let data = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-20T10:17:00Z"))
        _ = await fleet.drawTimetable(
            at: Date(timeIntervalSince1970: Double(now)),
            in: BBox(west: 7.3, south: 46.2, east: 8.1, north: 47.0)
        )
        let runs = await fleet.everyRawJourney()
        return (fleet, runs, now)
    }

    private func assertThroughJourney(_ opened: VehicleSnapshot, selectedID: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(opened.id, selectedID, file: file, line: line)
        XCTAssertEqual(opened.from, "Bern", file: file, line: line)
        XCTAssertEqual(opened.stops.first?.name, "Bern", file: file, line: line)
        XCTAssertTrue(opened.stops.contains { $0.name == "Thun" }, file: file, line: line)
        XCTAssertEqual(opened.stops.filter { $0.name == "Spiez" }.count, 1, file: file, line: line)
        XCTAssertTrue(opened.stops.contains { $0.name == "Mülenen" }, file: file, line: line)
        XCTAssertTrue(opened.to?.contains("Domodossola") == true, file: file, line: line)
    }
}
