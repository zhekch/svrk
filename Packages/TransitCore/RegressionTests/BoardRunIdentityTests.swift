import XCTest
@testable import TransitCore

final class BoardRunIdentityTests: XCTestCase {
    func testSpiezStationAndPlatformMergeLiveAliasIntoScheduledDeparture() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-05T09:23:00Z"))
        let initial = await fleet.stationBoard(placeId: "8507483", at: now, limit: 200)
        let scheduled = try XCTUnwrap(initial?.departures.first { $0.line == "GPX" })
        // The GoldenPass Express runs Interlaken–Zweisimmen–Montreux as one
        // train: it changes bogies at Zweisimmen rather than changing trains,
        // and the feed files that as two trips under the *same* train number
        // joined by an in-seat transfer. All 137 of the GPX links in the
        // archive are at Zweisimmen and all join same-numbered trips.
        //
        // This used to read "Zweisimmen", which was the inference failing
        // rather than the railway: a gauge change is a change of track, so
        // `candidateScore` rejected the continuation on the platform test and
        // the board stopped at the leg it could see. A board row for a train a
        // passenger rides to Montreux without getting off says Montreux.
        XCTAssertEqual(scheduled.to, "Montreux",
                       "The GoldenPass Express carries on to Montreux through the gauge change")
        let read = await fleet.journey(id: scheduled.id, at: now, boardDeparture: scheduled.departure)
        let vehicle = try XCTUnwrap(read)
        let reference = try XCTUnwrap(vehicle.journeyRef)
        let call = try XCTUnwrap(vehicle.stops.first { $0.dep == scheduled.departure })
        let platformRef = try XCTUnwrap(call.ref)
        let live = Journey(
            id: "test:live-gpx", mode: .train, category: nil, line: "GPX4068", number: nil,
            operatorName: vehicle.operatorName, operatorFull: vehicle.operatorFull,
            to: vehicle.to, from: vehicle.from, delay: nil,
            start: vehicle.stops[0].dep, end: vehicle.stops.last!.arr,
            complete: true, monitored: true, cancelled: false, source: "test",
            stops: vehicle.stops, journeyRef: reference
        )
        await fleet.ingestBoardFill([live])
        let station = await fleet.stationBoard(placeId: "8507483", at: now, limit: 200)
        let platform = await fleet.platformBoard(ref: platformRef, at: now, limit: 200)
        for departures in [try XCTUnwrap(station).departures, try XCTUnwrap(platform).departures] {
            let matches = departures.filter {
                $0.runIdentity?.references.contains(reference) == true
                    && $0.runIdentity?.scheduledDeparture == scheduled.runIdentity?.scheduledDeparture
            }
            XCTAssertEqual(matches.count, 1, "Both board APIs must return one GoldenPass departure")
            let kept = try XCTUnwrap(matches.first)
            let opened = await fleet.journey(id: kept.id, at: now, boardDeparture: kept.departure)
            XCTAssertEqual(opened.flatMap(LoadService.Key.init(vehicle:))?.journeyID, reference,
                           "The surviving row must still open the correct live-data subject")
        }
        // This timetable row is reused tomorrow. Live data for a scheduled
        // panel must update that cached occurrence, never today's instance.
        let nextDay = await fleet.stationBoard(placeId: "8507483", at: now + 86_400, limit: 200)
        let tomorrow = try XCTUnwrap(nextDay?.departures.first { $0.id == scheduled.id })
        await fleet.applyTiming(JourneyTiming(byStop: [:], cancelled: true), to: tomorrow.id,
                                boardDeparture: tomorrow.departure)
        let todayRead = await fleet.journey(id: scheduled.id, at: now, boardDeparture: scheduled.departure)
        let tomorrowRead = await fleet.journey(id: tomorrow.id, at: now, boardDeparture: tomorrow.departure)
        XCTAssertEqual(todayRead?.cancelled, false)
        XCTAssertEqual(tomorrowRead?.cancelled, true)
    }

    private func boardEntry(
        _ id: String, ref: String?, line: String, mode: Mode = .train,
        departure: Int = 1_800_000_000, delay: Int = 0,
        route: [String] = ["Spiez", "Zweisimmen", "Montreux"],
        operatorName: String = "operator", observed: Bool = false, number: String? = nil
    ) -> BoardEntry {
        let calls = route.enumerated().map { index, station in
            Call(key: station, ref: station, name: station, lat: 46, lon: 7,
                 arr: departure + index * 600 + delay * 60,
                 dep: departure + index * 600 + delay * 60,
                 sched: departure + index * 600)
        }
        let journey = Journey(
            id: id, mode: mode, category: nil, line: line, number: number,
            operatorName: operatorName, operatorFull: nil, to: route.last, from: route[0],
            delay: delay, start: calls[0].dep, end: calls.last!.arr,
            complete: true, monitored: observed, cancelled: false,
            source: id.hasPrefix("tt:") ? Journey.timetableSource : "live",
            stops: calls, journeyRef: ref
        )
        return BoardEntry(
            id: id, mode: mode, line: line, to: route.last, from: route[0],
            departure: calls[0].dep, arrival: calls[0].arr, platform: "5",
            delay: delay == 0 ? nil : delay, observed: observed, running: observed,
            runIdentity: BoardRunIdentity(journey: journey, at: 0)
        )
    }

    func testMontreuxLabelsCollapseByPublishedWorking() {
        let rows = [
            boardEntry("tt:1", ref: "ch:1:sjyid:100015:4068-001", line: "PEGPX"),
            boardEntry("live", ref: "ch:1:sjyid:100015:4068-002", line: "GPX4068", observed: true)
        ]
        let result = Fleet.collapseDuplicateRuns(rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "live")
        XCTAssertEqual(Fleet.collapseDuplicateRuns(rows.reversed()), result)
    }

    func testLuganoBoatsDeduplicateAcrossBadgesButKeepLaterSailing() {
        let route = ["Lugano Centrale (lago)", "Paradiso (lago)", "Gandria (lago)"]
        let rows = [
            boardEntry("tt:boat", ref: "ch:1:sjyid:100099:3623-001", line: "3623", mode: .boat, route: route),
            boardEntry("boat-live", ref: "ch:1:sjyid:100099:3623-001", line: "BAT3623", mode: .boat, route: route),
            boardEntry("tt:boat", ref: "ch:1:sjyid:100099:3623-001", line: "3623", mode: .boat,
                  departure: 1_800_000_000 + 150 * 60, route: route)
        ]
        XCTAssertEqual(Fleet.collapseDuplicateRuns(rows).count, 2)
    }

    func testLiveDelayDoesNotCreateAnotherDeparture() {
        let result = Fleet.collapseDuplicateRuns([
            boardEntry("tt:1", ref: "published", line: "PEGPX"),
            boardEntry("live", ref: "published", line: "GPX4068", delay: 12, observed: true)
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.departure, 1_800_000_000 + 12 * 60)
        XCTAssertEqual(result.first?.delay, 12)
    }

    func testDifferentCoursesDoNotCollapseEvenWithIdenticalBoardText() {
        let result = Fleet.collapseDuplicateRuns([
            boardEntry("tt:1", ref: "ch:1:sjyid:100015:4068-001", line: "RE1"),
            boardEntry("tt:2", ref: "ch:1:sjyid:100015:4070-001", line: "RE1")
        ])
        XCTAssertEqual(result.count, 2)
    }

    func testRepeatedIDInTheNextMinuteOrDayIsAnotherDeparture() {
        let rows = [0, 60, 86_400].map {
            boardEntry("tt:reused", ref: "published-run", line: "1", departure: 1_800_000_000 + $0)
        }
        let result = Fleet.collapseDuplicateRuns(rows)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map(\.eventID)).count, 3)
    }

    func testOpaqueReferencesStillRespectExplicitDifferentCourseNumbers() {
        let rows = [
            boardEntry("opaque-a", ref: nil, line: "BAT", mode: .boat, number: "3623"),
            boardEntry("opaque-b", ref: nil, line: "BAT", mode: .boat, number: "3624")
        ]
        XCTAssertEqual(Fleet.collapseDuplicateRuns(rows).count, 2)
    }

    func testDifferentFeedNamespacesNeedMatchingBookedRoute() {
        let rows = [
            boardEntry("tt:1", ref: "ch:1:sjyid:100099:3623-001", line: "3623", mode: .boat),
            boardEntry("ch:1:ServiceJourney:opaque", ref: nil, line: "BAT3623", mode: .boat)
        ]
        XCTAssertEqual(Fleet.collapseDuplicateRuns(rows).count, 1)
        var differentOperator = rows[1]
        differentOperator.runIdentity?.operatorName = "ANOTHER"
        XCTAssertEqual(Fleet.collapseDuplicateRuns([rows[0], differentOperator]).count, 2)
        var differentSchedule = rows[1]
        differentSchedule.runIdentity?.onward[1].departure += 300
        XCTAssertEqual(Fleet.collapseDuplicateRuns([rows[0], differentSchedule]).count, 2)
    }

    func testCompleteInternationalRunWinsOverBorderTruncation() {
        let shorter = boardEntry("tt:ec", ref: "ch:1:sjyid:100001:63-001", line: "EC63",
                            route: ["Spiez", "Brig", "Domodossola"], observed: true)
        let full = boardEntry("ojp:ec", ref: "ch:1:sjyid:100001:63-005", line: "EC63",
                         route: ["Spiez", "Brig", "Domodossola", "Milano Centrale"])
        let result = Fleet.collapseDuplicateRuns([shorter, full])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.to, "Milano Centrale")
        XCTAssertEqual(result.first?.id, "ojp:ec", "Opening the row must resolve the complete run")
    }

    func testSplitBranchesAndUnidentifiedLookalikesStaySeparate() {
        let a = boardEntry("tt:a", ref: "ch:1:sjyid:100015:123-001", line: "S44",
                      route: ["Bern", "Burgdorf", "Solothurn"])
        let b = boardEntry("tt:b", ref: "ch:1:sjyid:100015:123-002", line: "S44",
                      route: ["Bern", "Burgdorf", "Sumiswald"])
        XCTAssertEqual(Fleet.collapseDuplicateRuns([a, b]).count, 2)
        var unidentified = a
        unidentified.id = "another"
        unidentified.runIdentity = nil
        var noMetadata = a
        noMetadata.runIdentity = nil
        XCTAssertEqual(Fleet.collapseDuplicateRuns([noMetadata, unidentified]).count, 2)
    }

    func testPanoramaPrefixIsTheNamedTrain() {
        XCTAssertEqual(Journey.publishedLine("PEGEX"), "GEX")
        XCTAssertEqual(Journey.publishedLine("PE GEX"), "GEX")
        XCTAssertEqual(Journey.publishedLine("GEX901"), "GEX")
        XCTAssertEqual(Journey.publishedLine("PEGPX"), "GPX")
        XCTAssertEqual(Journey.publishedLine("GPX4068"), "GPX")
        XCTAssertEqual(Journey.publishedLine("PEBEX"), "BEX")
        XCTAssertEqual(Journey.publishedLine("PE"), "PE")
        XCTAssertEqual(Journey.publishedLine("PE72"), "PE72")
        XCTAssertEqual(Journey.publishedLine("IR38"), "IR38")
        XCTAssertEqual(Journey.publishedLine("BAT3623", mode: .boat), "3623")
    }

    func testGlacierExpressAliasesCollapseAcrossOperators() {
        let rhb = boardEntry("tt:gex", ref: "ch:1:sjyid:100012:903-001", line: "GEX",
                        operatorName: "RhB", number: "903")
        let live = boardEntry("live:pe", ref: "ch:1:sjyid:100029:903-001", line: "PEGEX",
                         operatorName: "MGB", observed: true, number: "903")
        let result = Fleet.collapseDuplicateRuns([rhb, live])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "live:pe")
        XCTAssertEqual(result.first?.line, "GEX")
        let unlabeled = [
            boardEntry("tt:mgb", ref: nil, line: "GEX", operatorName: "MGB", number: "901"),
            boardEntry("mirror", ref: nil, line: "PEGEX", operatorName: "RhB", observed: true, number: "901")
        ]
        XCTAssertEqual(Fleet.collapseDuplicateRuns(unlabeled).count, 1)
    }

    func testIR38AndGlacierExpressAtTheSameMinuteStaySeparate() {
        let ir = boardEntry("tt:ir", ref: "ch:1:sjyid:100012:1120-001", line: "IR38",
                       route: ["St. Moritz", "Celerina", "Samedan", "Bergün/Bravuogn",
                               "Filisur", "Tiefencastel", "Thusis", "Chur"],
                       operatorName: "RhB", number: "1120")
        let gex = boardEntry("tt:gex", ref: nil, line: "GEX",
                        route: ["St. Moritz", "Celerina", "Samedan", "Bergün/Bravuogn",
                                "Filisur", "Tiefencastel", "Thusis", "Chur"],
                        operatorName: "MGB", number: "901")
        XCTAssertEqual(Fleet.collapseDuplicateRuns([ir, gex]).count, 2)
    }

    func testNumericLinesDoNotCollapseAcrossOperators() {
        let post = boardEntry("pag", ref: "ch:1:sjyid:100602:1-001", line: "1", mode: .bus,
                         operatorName: "PAG", number: "1")
        let city = boardEntry("svb", ref: "ch:1:sjyid:100144:1-001", line: "1", mode: .bus,
                         operatorName: "SVB", number: "1")
        XCTAssertEqual(Fleet.collapseDuplicateRuns([post, city]).count, 2)
    }

    func testPublishedJourneyRefPrefersSwissJourneyIDOverTimetableRow() {
        let entry = boardEntry("tt:1", ref: "ch:1:sjyid:100015:4068-001", line: "PEGPX")
        XCTAssertEqual(
            entry.runIdentity?.publishedJourneyRef,
            "ch:1:sjyid:100015:4068-001"
        )
    }

    func testPublishedJourneyRefIgnoresABareTimetableRow() {
        let entry = boardEntry("tt:1", ref: nil, line: "GEX")
        XCTAssertNil(entry.runIdentity?.publishedJourneyRef)
        XCTAssertNil(BoardRunIdentity.publishedJourneyRef(id: "tt:41903"))
    }

    func testPublishedJourneyRefUsesALiveIdWhenThatIsTheReference() {
        let entry = boardEntry("live-run", ref: nil, line: "IC1", observed: true)
        XCTAssertEqual(entry.runIdentity?.publishedJourneyRef, "live-run")
        XCTAssertEqual(
            BoardRunIdentity.publishedJourneyRef(id: "ch:1:sjyid:100001:818-001"),
            "ch:1:sjyid:100001:818-001"
        )
    }

    func testThroughHeadsignDoesNotOutrunThisWorking() {
        let calls = ["St. Moritz", "Celerina", "Samedan", "Bergün/Bravuogn",
                     "Filisur", "Tiefencastel", "Thusis", "Chur"].enumerated().map { index, station in
            Call(key: station, ref: station, name: station, lat: 46, lon: 7,
                 arr: 1_800_000_000 + index * 600, dep: 1_800_000_000 + index * 600,
                 sched: 1_800_000_000 + index * 600)
        }
        let journey = Journey(
            id: "gex-901", mode: .train, category: nil, line: "GEX", number: "901",
            operatorName: "RhB", operatorFull: nil, to: "Brig Bahnhofplatz", from: "St. Moritz",
            delay: nil, start: calls[0].dep, end: calls.last!.arr,
            complete: true, monitored: false, cancelled: false, source: Journey.timetableSource,
            stops: calls, journeyRef: nil
        )
        XCTAssertEqual(Journey.reachedDestination(journey), "Chur")
        XCTAssertEqual(Journey.reachedDestination(journey, from: 0), "Chur")
    }

    func testShortHeadsignAtAJunctionIsNotTheDestinationOnceTheRunContinues() {
        let names = ["Bern", "Thun", "Spiez", "Mülenen", "Frutigen", "Brig"]
        let calls = names.enumerated().map { index, station in
            Call(key: station, ref: station, name: station, lat: 46, lon: 7,
                 arr: 1_800_000_000 + index * 600, dep: 1_800_000_000 + index * 600,
                 sched: 1_800_000_000 + index * 600)
        }
        let journey = Journey(
            id: "re1", mode: .train, category: nil, line: "RE1", number: "4270",
            operatorName: "BLS", operatorFull: nil, to: "Spiez", from: "Bern",
            delay: nil, start: calls[0].dep, end: calls.last!.arr,
            complete: true, monitored: false, cancelled: false, source: Journey.timetableSource,
            stops: calls, journeyRef: nil
        )
        XCTAssertEqual(Journey.reachedDestination(journey), "Brig")
        XCTAssertEqual(Journey.reachedDestination(journey, from: 1), "Brig")
    }

    func testSplitHeadsignIsKeptWhenThePackedTripEndsAtTheJunction() {
        let calls = ["Bern", "Thun", "Spiez"].enumerated().map { index, station in
            Call(key: station, ref: station, name: station, lat: 46, lon: 7,
                 arr: 1_800_000_000 + index * 600, dep: 1_800_000_000 + index * 600,
                 sched: 1_800_000_000 + index * 600)
        }
        let journey = Journey(
            id: "re1", mode: .train, category: nil, line: "RE1", number: "4270",
            operatorName: "BLS", operatorFull: nil, to: "Brig | Zweisimmen", from: "Bern",
            delay: nil, start: calls[0].dep, end: calls.last!.arr,
            complete: true, monitored: false, cancelled: false, source: Journey.timetableSource,
            stops: calls, journeyRef: nil
        )
        XCTAssertEqual(Journey.reachedDestination(journey), "Brig | Zweisimmen")
        XCTAssertEqual(Journey.reachedDestination(journey, from: 1), "Brig | Zweisimmen")
    }

    func testStMoritzMorningGlacierExpressIsNotTheRegional() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 8, hour: 2, minute: 7
        ))).timeIntervalSince1970
        let loadedBoard = await fleet.stationBoard(
            placeId: "8509253", at: Int(now.rounded()), limit: 200
        )
        let board = try XCTUnwrap(loadedBoard)
        let sevenOhFive = board.departures.filter {
            let date = Date(timeIntervalSince1970: TimeInterval($0.departure))
            return calendar.component(.hour, from: date) == 7
                && calendar.component(.minute, from: date) == 5
                && $0.mode == .train && !$0.terminates
        }
        let ir = sevenOhFive.filter { $0.line == "IR38" }
        let gex = sevenOhFive.filter { $0.line == "GEX" }
        XCTAssertEqual(ir.count, 1, "IR38 1120 to Chur must keep its own row")
        XCTAssertEqual(gex.count, 1, "GEX 901 must not be folded into the regional")
        XCTAssertEqual(ir.first?.to, "Chur")
        XCTAssertEqual(gex.first?.to, "Chur", "The RhB working ends at Chur; do not advertise Brig")
        XCTAssertNotEqual(ir.first?.id, gex.first?.id)
    }
}
