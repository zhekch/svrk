import XCTest
@testable import TransitCore

final class UnrelatedTrainContinuationTests: XCTestCase {
    private func pair(line: String = "IC", platform: String? = "5", gap: Int = 4 * 60) -> (Journey, Journey) {
        func call(_ name: String, _ ref: String, _ time: Int, platform: String?) -> Call {
            Call(key: ref, ref: ref, name: name, lat: 47, lon: 8,
                 platform: platform, arr: time, dep: time, sched: time)
        }
        func run(_ number: String, _ calls: [Call]) -> Journey {
            Journey(id: "ic-\(number)", mode: .train, category: "IC", line: line, number: number,
                    operatorName: "SBB", operatorFull: nil, to: calls.last?.name,
                    from: calls[0].name, delay: nil, start: calls[0].dep, end: calls.last!.arr,
                    complete: true, monitored: false, cancelled: false,
                    source: Journey.timetableSource, stops: calls)
        }
        let incoming = run("1302", [
            call("Visp", "ch:1:sloid:1605", 1000, platform: "4"),
            call("Zürich HB", "ch:1:sloid:3000", 8200, platform: "13")
        ])
        let outgoing = run("182", [
            call("Zürich HB", "ch:1:sloid:3000", 8200 + gap, platform: platform),
            call("Schaffhausen", "ch:1:sloid:3424", 10800, platform: "4"),
            call("Singen (Hohentwiel)", "8000073", 12000, platform: nil)
        ])
        return (incoming, outgoing)
    }

    func testReportedICsDoNotJoinInEitherMatchingPath() {
        let (incoming, outgoing) = pair()
        XCTAssertNil(Chains.candidateScore(incoming, outgoing))
        XCTAssertNil(Chains.passengerContinuationScore(incoming, outgoing))
        XCTAssertEqual(Chains.build([incoming, outgoing]).count, 2)
    }

    func testNumberedLineDoesNotOverrideConflictingPlatforms() {
        let (incoming, outgoing) = pair(line: "IC8")
        XCTAssertNil(Chains.candidateScore(incoming, outgoing))
        XCTAssertNil(Chains.passengerContinuationScore(incoming, outgoing))
    }

    func testCategoryAloneDoesNotGrantTwentyMinuteContinuationWindow() {
        let (incoming, outgoing) = pair(platform: "13")
        XCTAssertNil(Chains.candidateScore(incoming, outgoing))
        XCTAssertNil(Chains.passengerContinuationScore(incoming, outgoing))
    }

    func testCategoryAloneNeedsPlatformEvidenceEvenForShortDwell() {
        let (incoming, outgoing) = pair(platform: nil, gap: 60)
        XCTAssertNil(Chains.candidateScore(incoming, outgoing))
        XCTAssertNil(Chains.passengerContinuationScore(incoming, outgoing))
    }

    func testOpeningEitherTrainKeepsItsOwnStopsAndPlatform() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let (incoming, outgoing) = pair()
        await fleet.apply([incoming.id: incoming, outgoing.id: outgoing],
                          summary: SiriParser.Summary(), started: Date(), bytes: 1, source: "test")
        // Check both directions and repeated reads through the cache.
        for _ in 0..<2 {
            let arrival = await fleet.boardWorking(incoming)
            let departure = await fleet.boardWorking(outgoing)
            XCTAssertEqual(arrival.stops.map(\.name), incoming.stops.map(\.name))
            XCTAssertEqual(arrival.stops.last?.platform, "13")
            XCTAssertEqual(departure.stops.map(\.name), outgoing.stops.map(\.name))
            XCTAssertEqual(departure.stops.first?.platform, "5")
            XCTAssertNil(arrival.parts)
            XCTAssertNil(departure.parts)
        }
    }

    func testReportedWorkingsStaySeparateInBundledTimetable() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let register = StopRegister()
        try register.load(stopsFile: data.appendingPathComponent("stops.bin"),
                          foreignFile: data.appendingPathComponent("foreign.bin"))
        let timetable = try TimetableStore(url: data.appendingPathComponent("timetable.bin"))
        let now = try XCTUnwrap(OJPTimings.time("2026-09-20T16:20:00Z"))
        let journeys = timetable.journeys(callingAt: ["ch:1:sloid:3000"],
                                         from: now, to: now + 30 * 60,
                                         place: { register.lookup($0) })
        let incoming = try XCTUnwrap(journeys.first { $0.number == "1302" })
        let outgoing = try XCTUnwrap(journeys.first { $0.number == "182" })
        XCTAssertEqual(incoming.line, "IC")
        XCTAssertEqual(outgoing.line, "IC")
        XCTAssertEqual(incoming.stops.last?.name, "Zürich HB")
        XCTAssertEqual(incoming.stops.last?.platform, "13")
        XCTAssertEqual(outgoing.stops.first?.platform, "5")
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let arrival = await fleet.boardWorking(incoming)
        let departure = await fleet.boardWorking(outgoing)
        XCTAssertEqual(arrival.stops.last?.name, "Zürich HB")
        XCTAssertFalse(arrival.stops.contains { $0.name == "Schaffhausen" })
        XCTAssertEqual(departure.stops.first?.name, "Zürich HB")
        XCTAssertFalse(departure.stops.contains { $0.name == "Visp" })
    }
}
