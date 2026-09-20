import XCTest
@testable import TransitCore

final class LiveBoardPresentationTests: XCTestCase {
    func testDisplayMinuteMatchesThePrintedClock() throws {
        let planned = try XCTUnwrap(OJPTimings.time("2026-09-06T17:46:00Z"))
        XCTAssertEqual(Clock.displayMinute(planned), planned)
        XCTAssertEqual(Clock.displayMinute(planned + 29), planned)
        XCTAssertEqual(Clock.displayMinute(planned + 30), planned)
        XCTAssertEqual(Clock.displayMinute(planned + 59), planned)
        XCTAssertEqual(Clock.displayMinute(planned + 60), planned + 60)
        XCTAssertEqual(Clock.remainingMinutes(until: planned + 40, from: planned - 23 * 60), 23)
        XCTAssertEqual(Clock.remainingMinutes(until: planned + 40, from: planned - 23 * 60 + 59), 23)
    }

    func testReportableDelayStillRoundsToWholeMinutes() {
        for seconds in [270, 280, 299, 300, 329] {
            XCTAssertEqual(SiriParser.reportableDelay(seconds), 5)
        }
    }

    func testTurnbackLabelChangesAtArrivalWithoutChangingPhysicalSelection() {
        for (line, next, mode) in [("315", "316", Mode.bus), ("S20", "RE80", Mode.train)] {
            let stops = [
                Call(key: "a", name: "Origin", lat: 46, lon: 8, arr: 100, dep: 100),
                Call(key: "b", name: "Locarno", lat: 46, lon: 8, arr: 200, dep: 200)
            ]
            var vehicle = VehicleSnapshot(
                id: "physical", mode: mode, line: line, to: "Locarno", from: "Origin",
                lon: 8, lat: 46, moving: true, stops: stops,
                layover: Layover(until: 299, line: next, to: "Lugano", id: "outgoing")
            )
            XCTAssertEqual(vehicle.displayLine, line)
            vehicle.moving = false
            XCTAssertEqual(vehicle.displayLine, line, "An intermediate stop is not a turnback")
            vehicle.index = 1
            XCTAssertEqual(vehicle.displayLine, next)
            XCTAssertEqual(vehicle.displayDestination, "Lugano")
            XCTAssertEqual(vehicle.id, "physical")
            XCTAssertEqual(vehicle.line, line, "Keep the arriving identity for its explanation and live queries")
            vehicle.layover = Layover(until: 299)
            XCTAssertEqual(vehicle.displayLine, line, "An ambiguous split cannot advertise an arbitrary child")
        }
    }

    func testMelideLiveEstimateAppearsOnceInMainStationAndPlatformBoards() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-06T17:42:00Z"))
        let results = await fleet.search("Melide", at: now)
        let station = try XCTUnwrap(results.stations.first { $0.name == "Melide" })
        let initial = await fleet.stationBoard(placeId: station.id, at: now)
        let row = try XCTUnwrap(initial?.departures.first { $0.line == "S10" && $0.to == "Biasca" })
        let read = await fleet.journey(id: row.id, at: now, boardDeparture: row.departure)
        let vehicle = try XCTUnwrap(read)
        let ref = try XCTUnwrap(vehicle.journeyRef)
        let call = try XCTUnwrap(vehicle.stops.first { $0.dep == row.departure })
        let platform = try XCTUnwrap(call.ref)
        let iso = ISO8601DateFormatter()
        func time(_ stamp: Int) -> String { iso.string(from: Date(timeIntervalSince1970: Double(stamp))) }
        let calls = vehicle.stops.map { stop in
            let wrapper = stop.dep < row.departure ? "PreviousCall" : stop.dep == row.departure ? "ThisCall" : "OnwardCall"
            let estimate = stop.dep == row.departure
                ? "<EstimatedTime>\(time(stop.dep + 280))</EstimatedTime>" : ""
            return """
            <\(wrapper)><siri:StopPointRef>\(stop.ref!)</siri:StopPointRef>
            <StopPointName><Text>\(stop.name)</Text></StopPointName>
            <ServiceArrival><TimetabledTime>\(time(stop.arr))</TimetabledTime></ServiceArrival>
            <ServiceDeparture><TimetabledTime>\(time(stop.dep))</TimetabledTime>\(estimate)</ServiceDeparture>
            </\(wrapper)>
            """
        }.joined()
        let xml = """
        <StopEventResult><StopEvent>\(calls)<Service><JourneyRef>\(ref)</JourneyRef>
        <PublicCode>S10</PublicCode><DestinationText>Biasca</DestinationText><PtMode>rail</PtMode>
        </Service></StopEvent></StopEventResult>
        """
        let journeys = OJPTimings.stopEventJourneys(Data(xml.utf8))
        let delayed = try XCTUnwrap(journeys.first?.stops.first { $0.ref == platform })
        XCTAssertEqual(delayed.delay, 5)
        XCTAssertEqual(delayed.dep, row.departure + 280)
        XCTAssertEqual(delayed.sched, row.departure)
        await fleet.ingestBoardFill(journeys)
        let board = await fleet.stationBoard(placeId: station.id, at: now)
        let platformBoard = await fleet.platformBoard(ref: platform, at: now)
        for entries in [try XCTUnwrap(board).departures, try XCTUnwrap(platformBoard).departures] {
            let sameRun = entries.filter {
                $0.runIdentity?.references.contains(ref) == true
                    && $0.runIdentity?.scheduledDeparture == row.runIdentity?.scheduledDeparture
            }
            XCTAssertEqual(sameRun.count, 1, "The delayed departure must replace the scheduled main row")
            let next = try XCTUnwrap(sameRun.first)
            XCTAssertEqual(next.delay, 5)
            XCTAssertEqual(next.departure, row.departure + 280)
            XCTAssertEqual(Clock.displayMinute(next.departure), row.departure + 240)
        }
    }

    func testBoardNamesTheThroughDestinationNotTheJunctionLeg() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        func call(_ name: String, _ ref: String, _ time: Int, platform: String? = nil) -> Call {
            Call(key: ref, ref: ref, name: name, lat: 46.6, lon: 7.6,
                 platform: platform, arr: time, dep: time, sched: time)
        }
        let incoming = Journey(
            id: "re1-south", mode: .train, category: "RE", line: "RE1", number: "4271",
            operatorName: "BLS", operatorFull: "BLS", to: "Spiez", from: "Brig",
            delay: nil, start: 1000, end: 2800, complete: true, monitored: false,
            cancelled: false, source: Journey.timetableSource,
            stops: [
                call("Brig", "ch:1:sloid:1609", 1000),
                call("Frutigen", "ch:1:sloid:7479", 2200),
                call("Spiez", "ch:1:sloid:7483:1:2", 2800, platform: "2"),
            ]
        )
        let onward = Journey(
            id: "re1-north", mode: .train, category: "RE", line: "RE1", number: "4273",
            operatorName: "BLS", operatorFull: "BLS", to: "Bern", from: "Spiez",
            delay: nil, start: 2920, end: 4000, complete: true, monitored: false,
            cancelled: false, source: Journey.timetableSource,
            stops: [
                call("Spiez", "ch:1:sloid:7483:1:2", 2920, platform: "2"),
                call("Thun", "ch:1:sloid:7100", 3400),
                call("Bern", "ch:1:sloid:7000", 4000),
            ]
        )
        await fleet.apply(
            [incoming.id: incoming, onward.id: onward],
            summary: SiriParser.Summary(), started: Date(), bytes: 1, source: "test"
        )
        let working = await fleet.boardWorking(incoming)
        XCTAssertEqual(Journey.reachedDestination(working, from: 1), "Bern")
        XCTAssertEqual(working.stops.map(\.name), ["Brig", "Frutigen", "Spiez", "Thun", "Bern"])
    }

    func testSplitHeadsignIsKeptAndOutgoingKeepsBernOrigin() async {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        func call(_ name: String, _ ref: String, _ time: Int) -> Call {
            Call(key: ref, ref: ref, name: name, lat: 46.6, lon: 7.6,
                 arr: time, dep: time, sched: time)
        }
        // Different platform SLOIDs, as packed RE1 actually files the Spiez
        // split: map chaining refuses a platform change, the board must not.
        let incoming = Journey(
            id: "re1-4157", mode: .train, category: "RE", line: "RE1", number: "4157",
            operatorName: "BLS", operatorFull: "BLS", to: "Brig | Zweisimmen", from: "Bern",
            delay: nil, start: 1000, end: 2800, complete: true, monitored: false,
            cancelled: false, source: Journey.timetableSource,
            stops: [
                call("Bern", "ch:1:sloid:7000", 1000),
                call("Thun", "ch:1:sloid:7100", 2200),
                call("Spiez", "ch:1:sloid:7483:1:3", 2800),
            ]
        )
        let onward = Journey(
            id: "re1-4257", mode: .train, category: "RE", line: "RE1", number: "4257",
            operatorName: "BLS", operatorFull: "BLS", to: "Brig", from: "Spiez",
            delay: nil, start: 2920, end: 4000, complete: true, monitored: false,
            cancelled: false, source: Journey.timetableSource,
            stops: [
                call("Spiez", "ch:1:sloid:7483:1:1", 2920),
                call("Frutigen", "ch:1:sloid:7479", 3400),
                call("Brig", "ch:1:sloid:1609", 4000),
            ]
        )
        await fleet.apply(
            [incoming.id: incoming, onward.id: onward],
            summary: SiriParser.Summary(), started: Date(), bytes: 1, source: "test"
        )
        let coupled = await fleet.boardWorking(incoming)
        XCTAssertEqual(Journey.reachedDestination(coupled), "Brig | Zweisimmen")
        XCTAssertEqual(coupled.stops.map(\.name), ["Bern", "Thun", "Spiez", "Frutigen", "Brig"])
        let outgoing = await fleet.boardWorking(onward)
        XCTAssertEqual(outgoing.from, "Bern")
        XCTAssertEqual(outgoing.stops.map(\.name), ["Bern", "Thun", "Spiez", "Frutigen", "Brig"])
        let opened = await fleet.journey(id: onward.id, at: 3000)
        XCTAssertEqual(opened?.from, "Bern")
        XCTAssertEqual(opened?.to, "Brig | Zweisimmen")
        XCTAssertFalse(opened?.from.contains("Spiez") == true)
    }

    func testFrutigenRE1BoardNamesBernNotSpiez() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-11T12:06:00Z"))
        let results = await fleet.search("Frutigen", at: now)
        let station = try XCTUnwrap(results.stations.first { $0.name == "Frutigen" })
        let loaded = await fleet.stationBoard(placeId: station.id, at: now, limit: 80)
        let board = try XCTUnwrap(loaded)
        let northbound = board.departures.filter { entry in
            guard entry.line == "RE1" else { return false }
            let dest = entry.to ?? ""
            return !dest.contains("Brig") && !dest.contains("Zweisimmen")
                && !dest.contains("Domodossola")
        }
        XCTAssertFalse(northbound.isEmpty, "Frutigen should have a northbound RE1")
        let described = northbound.map {
            "\($0.to ?? "?") dep=\($0.departure) plat=\($0.platform ?? "-")"
        }.joined(separator: ", ")
        XCTAssertTrue(northbound.contains { $0.to == "Bern" },
                      "Northbound RE1 continues to Bern, not the Spiez junction: \(described)")
        let next = try XCTUnwrap(northbound.min { $0.departure < $1.departure })
        XCTAssertEqual(next.to, "Bern", "The next northbound RE1 should be Bern (\(described))")
    }

    func testThunRE1BoardNamesBrigNotTheSpiezJunction() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-11T17:46:00Z"))
        let results = await fleet.search("Thun", at: now)
        let station = try XCTUnwrap(results.stations.first { $0.name == "Thun" })
        let loaded = await fleet.stationBoard(placeId: station.id, at: now, limit: 80)
        let board = try XCTUnwrap(loaded)
        let re1 = board.departures.filter { $0.line == "RE1" }
        let described = re1.map {
            "\($0.to ?? "?") dep=\($0.departure) plat=\($0.platform ?? "-")"
        }.joined(separator: ", ")
        let next = try XCTUnwrap(re1.min { $0.departure < $1.departure })
        XCTAssertNotEqual(next.to, "Spiez", "RE1 from Thun is not a Spiez shuttle (\(described))")
        XCTAssertTrue(
            Self.isRE1ThroughDestination(next.to),
            "RE1 should name the through destination (\(described))"
        )
    }

    func testThunRE1BoardStillNamesBrigWhenTheMapFleetHasThePackedLeg() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-11T17:46:00Z"))
        _ = await fleet.drawTimetable(
            at: Date(timeIntervalSince1970: Double(now)),
            in: BBox(west: 7.55, south: 46.70, east: 7.70, north: 46.80)
        )
        let results = await fleet.search("Thun", at: now)
        let station = try XCTUnwrap(results.stations.first { $0.name == "Thun" })
        let loaded = await fleet.stationBoard(placeId: station.id, at: now, limit: 80)
        let board = try XCTUnwrap(loaded)
        let re1 = board.departures.filter { $0.line == "RE1" }
        let described = re1.map {
            "\($0.to ?? "?") dep=\($0.departure) plat=\($0.platform ?? "-")"
        }.joined(separator: ", ")
        let next = try XCTUnwrap(re1.min { $0.departure < $1.departure })
        XCTAssertNotEqual(next.to, "Spiez", "A live packed Spiez leg must not win the board (\(described))")
        XCTAssertTrue(
            Self.isRE1ThroughDestination(next.to),
            "RE1 should name the through destination even with a live fleet (\(described))"
        )
    }

    func testBernMorningRE1OpensPastSpiezLikeSBB() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-11T18:20:00Z"))
        let results = await fleet.search("Bern", at: now)
        let station = try XCTUnwrap(results.stations.first { $0.name == "Bern" || $0.name.hasPrefix("Bern") })
        let loaded = await fleet.stationBoard(placeId: station.id, at: now, limit: 80)
        let board = try XCTUnwrap(loaded)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        let re1 = board.departures.filter { $0.line == "RE1" }
        let described = re1.prefix(12).map {
            let parts = calendar.dateComponents(
                [.hour, .minute],
                from: Date(timeIntervalSince1970: Double($0.departure))
            )
            let hh = String(format: "%02d", parts.hour ?? 0)
            let mm = String(format: "%02d", parts.minute ?? 0)
            return "\($0.to ?? "?") \($0.from) \(hh):\(mm) id=\($0.id)"
        }.joined(separator: " | ")
        let row = try XCTUnwrap(re1.first { entry in
            let parts = calendar.dateComponents(
                [.hour, .minute],
                from: Date(timeIntervalSince1970: Double(entry.departure))
            )
            return parts.hour == 5 && (parts.minute ?? 0) >= 25 && (parts.minute ?? 0) <= 40
        }, "No 05:25–05:40 RE1 at Bern (\(described))")
        XCTAssertNotEqual(row.to, "Spiez", "Board row to=\(row.to ?? "?") from=\(row.from) (\(described))")
        XCTAssertTrue(
            (row.to ?? "").contains("Brig") || (row.to ?? "").contains("Zweisimmen")
                || (row.to ?? "").contains("Domodossola"),
            "Keep the packed split headsign, not the Spiez junction (\(described))"
        )
        let packedRead = await fleet.journey(
            id: row.id, at: now, boardDeparture: row.departure, through: false
        )
        let packed = try XCTUnwrap(packedRead)
        XCTAssertFalse(packed.stops.isEmpty, "The packed timetable must open the card before through-working")
        let read = await fleet.journey(id: row.id, at: now, boardDeparture: row.departure)
        let opened = try XCTUnwrap(read)
        XCTAssertGreaterThanOrEqual(opened.stops.count, packed.stops.count)
        let names = opened.stops.map(\.name)
        XCTAssertTrue(
            names.contains(where: { $0.contains("Mülenen") || $0.contains("Frutigen") || $0.contains("Brig") }),
            "Opened RE1 must continue past Spiez, stops=\(names) to=\(opened.to ?? "?") from=\(opened.from) rowTo=\(row.to ?? "?")"
        )
        XCTAssertNotEqual(opened.to, "Spiez")
        XCTAssertFalse(opened.from.contains("Spiez"), "Through RE1 is from Bern, not Spiez: from=\(opened.from)")
    }

    func testSpiezMorningRE1KeepsBernOriginWithoutNetwork() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        // 06:05 Europe/Zurich on the morning of RE1 4157/4257.
        let now = try XCTUnwrap(OJPTimings.time("2026-09-12T04:05:00Z"))
        let results = await fleet.search("Spiez", at: now)
        let station = try XCTUnwrap(results.stations.first { $0.name == "Spiez" })
        let loaded = await fleet.stationBoard(placeId: station.id, at: now, limit: 80)
        let board = try XCTUnwrap(loaded)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        let southbound = board.departures.filter { entry in
            guard entry.line == "RE1" else { return false }
            if entry.to == "Bern" { return false }
            let parts = calendar.dateComponents(
                [.hour, .minute],
                from: Date(timeIntervalSince1970: Double(entry.departure))
            )
            return parts.hour == 6 && (parts.minute ?? 0) <= 20
        }
        let described = southbound.map {
            "to=\($0.to ?? "?") from=\($0.from) dep=\($0.departure)"
        }.joined(separator: " | ")
        let row = try XCTUnwrap(southbound.min { $0.departure < $1.departure },
                                "No southbound RE1 at Spiez around 06:05 (\(described))")
        XCTAssertTrue(
            (row.to ?? "").contains("Brig") || (row.to ?? "").contains("Zweisimmen")
                || (row.to ?? "").contains("Domodossola"),
            "Southbound RE1 must keep the packed destination, not Spiez (\(described))"
        )
        let read = await fleet.journey(id: row.id, at: now, boardDeparture: row.departure)
        let opened = try XCTUnwrap(read)
        let names = opened.stops.map(\.name)
        XCTAssertTrue(names.contains(where: { $0.contains("Bern") }),
                      "Outgoing RE1 started in Bern, stops=\(names) from=\(opened.from)")
        XCTAssertTrue(
            names.contains(where: { $0.contains("Mülenen") || $0.contains("Frutigen") || $0.contains("Brig") }),
            "Outgoing RE1 must keep the southbound calls, stops=\(names)"
        )
        XCTAssertFalse(opened.from.contains("Spiez"), "from=\(opened.from)")
    }

    private static func isRE1ThroughDestination(_ name: String?) -> Bool {
        guard let name else { return false }
        if ["Brig", "Domodossola", "Domodossola (I)", "Bern"].contains(name) { return true }
        return name.contains("Brig") && name.contains("Zweisimmen")
    }
}
