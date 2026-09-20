import XCTest
@testable import TransitCore

final class BernDelayTests: XCTestCase {
    private let bookedBern = "ch:1:sloid:7000:3:5"
    private let liveBern = "ch:1:sloid:7000:5:9"
    private let thun = "ch:1:sloid:7100:2:2"
    private func time(_ value: String) -> Timestamp { OJPTimings.time("2026-09-02T\(value)Z")! }

    // Actual OJP call fragments for IC6 640/646, retrieved 2026-09-02.
    // Times are UTC; 21:37:12 here is 23:37:12 in Switzerland.
    private var arrivalXML: String {
        """
        <OnwardCall><siri:StopPointRef>\(liveBern)</siri:StopPointRef>
        <PlannedQuay><Text xml:lang="de">5</Text></PlannedQuay>
        <EstimatedQuay><Text xml:lang="de">9</Text></EstimatedQuay>
        <ServiceArrival><TimetabledTime>2026-09-02T21:25:00Z</TimetabledTime>
        <EstimatedTime>2026-09-02T21:37:12Z</EstimatedTime></ServiceArrival><Order>5</Order></OnwardCall>
        """
    }
    private var departureXML: String {
        """
        <OnwardCall><siri:StopPointRef>\(liveBern)</siri:StopPointRef>
        <PlannedQuay><Text xml:lang="de">5</Text></PlannedQuay>
        <EstimatedQuay><Text xml:lang="de">9</Text></EstimatedQuay>
        <ServiceDeparture><TimetabledTime>2026-09-02T21:36:00Z</TimetabledTime>
        <EstimatedTime>2026-09-02T21:45:00Z</EstimatedTime></ServiceDeparture><Order>1</Order></OnwardCall>
        """
    }
    private var arrival: JourneyTiming { OJPTimings.trip(Data(arrivalXML.utf8)) }
    private var departure: JourneyTiming { OJPTimings.trip(Data(departureXML.utf8)) }

    private func call(_ ref: String, _ name: String, _ clock: String, platform: String = "5") -> Call {
        Call(key: "\(ref)|\(clock)", ref: ref, name: name, lat: 46.95, lon: 7.44,
             platform: platform, precise: true, arr: time(clock), dep: time(clock), sched: time(clock))
    }
    private func journey(_ id: String, _ stops: [Call]) -> Journey {
        Journey(id: id, mode: .train, category: "IC", line: "IC6", number: id,
                operatorName: "SBB", operatorFull: "SBB", to: stops.last?.name,
                from: stops[0].name, delay: nil, start: stops[0].dep, end: stops.last!.arr,
                complete: true, monitored: false, cancelled: false,
                source: Journey.timetableSource, stops: stops)
    }
    private func head() -> Journey {
        journey("640", [call(thun, "Thun", "21:04:00", platform: "2"),
                        call(bookedBern, "Bern", "21:25:00")])
    }
    private func tail() -> Journey {
        journey("646", [call(bookedBern, "Bern", "21:36:00"),
                        call("ch:1:sloid:218:3:4", "Olten", "22:03:00", platform: "4")])
    }

    func testQuayTextWithLanguageAttributeIsParsed() {
        XCTAssertEqual(arrival.byStop[liveBern]?.expectedQuay, "9")
        XCTAssertEqual(arrival.byStop[liveBern]?.expectedArrival, time("21:37:12"))
        XCTAssertEqual(departure.byStop[liveBern]?.expectedDeparture, time("21:45:00"))
    }

    func testChangedPlatformDoesNotDropBernDelayOrMoveCallIdentity() {
        let run = head()
        let key = run.stops[1].key
        var timing = arrival
        timing.byStop[thun] = CallTiming(planned: time("21:04:00"),
            expectedDeparture: time("21:19:00"), plannedDeparture: time("21:04:00"))
        XCTAssertEqual(run.apply(timing, at: time("21:20:00")), 2)
        XCTAssertEqual(run.stops[1].arr, time("21:37:12"))
        XCTAssertEqual(run.stops[1].dep, time("21:37:12"), "Synthetic terminal departure stays coherent")
        XCTAssertEqual(run.stops[1].delay, 12)
        XCTAssertEqual(run.stops[1].platform, "9")
        XCTAssertEqual(run.stops[1].ref, liveBern)
        XCTAssertEqual(run.stops[1].key, key)
        XCTAssertEqual(run.stops[1].arr - run.stops[0].dep, 18 * 60 + 12,
                       "The leg must not be compressed to six minutes")
        XCTAssertEqual(run.apply(timing, at: time("21:21:00")), 2,
                       "A second update matches the saved schedule, not already-delayed times")
    }

    func testDifferentVisitOrServiceDayCannotMatchByStationAlone() {
        let run = head()
        let before = run.stops
        XCTAssertEqual(run.apply(departure, at: time("21:20:00")), 0,
                       "Bern departure under 646 must not overwrite 640 arrival")
        let tomorrow = JourneyTiming(byStop: [liveBern: CallTiming(
            planned: time("21:25:00") + 86400, expectedArrival: time("21:37:12") + 86400)])
        XCTAssertEqual(run.apply(tomorrow, at: time("21:20:00")), 0)
        XCTAssertEqual(run.stops, before)
    }

    func testAmbiguousChangedPlatformsAreNotGuessed() {
        let run = head()
        var timing = arrival
        timing.byStop["ch:1:sloid:7000:5:10"] = timing.byStop[liveBern]
        XCTAssertEqual(run.apply(timing, at: time("21:20:00")), 0)
        XCTAssertEqual(run.stops[1].platform, "5")
    }

    func testExactPlatformWinsOverSiblingAndUnrelatedStationIsIgnored() {
        let run = head()
        var timing = arrival
        timing.byStop[bookedBern] = CallTiming(planned: time("21:25:00"),
            expectedArrival: time("21:30:00"), plannedArrival: time("21:25:00"))
        XCTAssertEqual(run.apply(timing, at: time("21:20:00")), 1)
        XCTAssertEqual(run.stops[1].arr, time("21:30:00"))
        let unrelated = JourneyTiming(byStop: ["ch:1:sloid:7001:5:9": timing.byStop[liveBern]!])
        XCTAssertEqual(run.apply(unrelated, at: time("21:20:00")), 0)
    }

    func testRepeatedVisitsToSameStopRetainTheirOwnTimes() {
        func visit(_ clock: String, _ expected: String) -> String {
            """
            <OnwardCall><siri:StopPointRef>\(bookedBern)</siri:StopPointRef>
            <ServiceDeparture><TimetabledTime>2026-09-02T\(clock)Z</TimetabledTime>
            <EstimatedTime>2026-09-02T\(expected)Z</EstimatedTime></ServiceDeparture></OnwardCall>
            """
        }
        let run = journey("loop", [call(bookedBern, "Bern", "21:00:00"),
            call("ch:1:sloid:7100:2:2", "Thun", "21:30:00"),
            call(bookedBern, "Bern", "22:00:00")])
        let timing = OJPTimings.trip(Data((visit("21:00:00", "21:05:00")
            + visit("22:00:00", "22:12:00")).utf8))
        XCTAssertEqual(run.apply(timing, at: time("21:10:00")), 2)
        XCTAssertEqual(run.stops[0].dep, time("21:05:00"))
        XCTAssertEqual(run.stops[2].dep, time("22:12:00"))
    }

    func testXMLAttributesDoNotMatchLongerTagNames() {
        let xml: Substring = "<Textual>wrong</Textual><Text xml:lang='de' note='a>b'>9</Text>"
        XCTAssertEqual(OJPLoad.first(xml, "Text"), "9")
        XCTAssertEqual(OJPLoad.blocks(xml, "Text").map(String.init), ["9"])
        XCTAssertEqual(OJPLoad.first("<Text xml:lang='de'/><Text>9</Text>", "Text"), "9")
    }

    func testPlatformChangeAlsoUpdatesMappedLocation() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("stops.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        try await fleet.register.load(stopsFile: data.appendingPathComponent("stops.bin"), foreignFile: nil)
        let registered = await fleet.register.lookup(liveBern)
        let expected = try XCTUnwrap(registered)
        let run = head()
        await fleet.apply([run.id: run], summary: SiriParser.Summary(), started: Date(), bytes: 0, source: "test")
        _ = await fleet.applyTiming(arrival, to: run.id,
            at: Date(timeIntervalSince1970: Double(time("21:20:00"))))
        XCTAssertEqual(run.stops[1].lon, expected.lon)
        XCTAssertEqual(run.stops[1].lat, expected.lat)
        XCTAssertTrue(run.stops[1].precise)
    }

    func testContinuationFoldKeepsArrivalAndDepartureInEitherUpdateOrder() async throws {
        for tailFirst in [false, true] {
            let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
            let a = head(), b = tail()
            await fleet.apply([a.id: a, b.id: b], summary: SiriParser.Summary(),
                              started: Date(), bytes: 0, source: "test")
            let before = await fleet.fleetVehicles()
            XCTAssertEqual(before.count, 1)
            let updates = tailFirst ? [(b.id, departure), (a.id, arrival)] : [(a.id, arrival), (b.id, departure)]
            for (id, timing) in updates {
                let touched = await fleet.applyTiming(timing, to: id,
                    at: Date(timeIntervalSince1970: Double(time("21:20:00"))))
                XCTAssertEqual(touched, 1)
            }
            let after = await fleet.fleetVehicles()
            let joined = try XCTUnwrap(after.first)
            XCTAssertEqual(after.count, 1)
            XCTAssertTrue(joined === before[0], "No whole-fleet rebuild for live corrections")
            XCTAssertEqual(joined.stops[1].arr, time("21:37:12"))
            XCTAssertEqual(joined.stops[1].dep, time("21:45:00"))
            XCTAssertEqual(joined.stops[1].platform, "9")
            XCTAssertEqual(joined.stops[1].ref, liveBern)
        }
    }
}
