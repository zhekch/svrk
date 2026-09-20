import XCTest
@testable import TransitCore

final class CancellationTimingTests: XCTestCase {
    private func response(service: String = "", stop: String = "") -> Data {
        Data("""
        <OJP><OJPTripInfoDelivery><Service>\(service)</Service>
        <PreviousCall><siri:StopPointRef>ch:1:sloid:7000</siri:StopPointRef>
        <StopPointName><Text>Bern</Text></StopPointName>
        <ServiceDeparture><TimetabledTime>2026-09-13T10:07:00Z</TimetabledTime></ServiceDeparture>
        \(stop)</PreviousCall>
        <OnwardCall><siri:StopPointRef>ch:1:sloid:7100</siri:StopPointRef>
        <StopPointName><Text>Thun</Text></StopPointName>
        <ServiceArrival><TimetabledTime>2026-09-13T10:26:00Z</TimetabledTime></ServiceArrival>
        </OnwardCall></OJPTripInfoDelivery></OJP>
        """.utf8)
    }

    func testCancelledCallDoesNotCancelWholeTripOrBoardJourney() {
        let data = response(stop: "<Cancelled>true</Cancelled>")
        let timing = OJPTimings.trip(data)
        XCTAssertFalse(timing.cancelled)
        XCTAssertEqual(timing.byStop["ch:1:sloid:7000"]?.cancelled, true)
        XCTAssertEqual(timing.byStop["ch:1:sloid:7100"]?.cancelled, false)
        let xml = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "OJPTripInfoDelivery", with: "StopEvent")
            .replacingOccurrences(of: "<OJP>", with: "<OJP><StopEventResult>")
            .replacingOccurrences(of: "</OJP>", with: "</StopEventResult></OJP>")
        let board = OJPTimings.stopEventJourneys(Data(xml.utf8))
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board.first?.cancelled, false)
        XCTAssertEqual(board.first?.stops.first?.cancelled, true)
    }

    func testJourneyCancellationStillAppliesIncludingNamespacedFlag() {
        for flag in ["<Cancelled>true</Cancelled>", "<ojp:Cancelled>true</ojp:Cancelled>"] {
            XCTAssertTrue(OJPTimings.trip(response(service: flag)).cancelled)
        }
    }

    func testNewTimingReinstatesMatchedCallAndLeavesUnreportedCallAlone() {
        let withdrawn = OJPTimings.trip(response(stop: "<Cancelled>true</Cancelled>"))
        let run = Journey(id: "test", mode: .train, category: "ICE", line: "ICE", number: "2871",
                          operatorName: nil, operatorFull: nil, to: "Thun", from: "Bern", delay: nil,
                          start: withdrawn.calls[0].dep, end: withdrawn.calls[1].arr,
                          complete: true, monitored: true, cancelled: false,
                          source: "test", stops: withdrawn.calls)
        run.stops[1].cancelled = true
        let fresh = OJPTimings.trip(response())
        let bern = fresh.byStop["ch:1:sloid:7000"]!
        XCTAssertEqual(run.apply(JourneyTiming(byStop: ["ch:1:sloid:7000": bern]), at: run.start), 1)
        XCTAssertFalse(run.stops[0].cancelled)
        XCTAssertTrue(run.stops[1].cancelled)
    }
}
