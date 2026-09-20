import XCTest
@testable import TransitCore

final class AsconaBoardTests: XCTestCase {
    private let stationID = "8591522"
    private let stationRef = "ch:1:sloid:91522"
    private let scheduled = 1_788_768_540 // 10:09 Europe/Zurich

    func testMirrorDoesNotInventAnArrivalOrLoseTheQueriedStopIdentity() throws {
        let run = try XCTUnwrap(MirrorBoard.journeys(from: AsconaBoardFixture.mirror).first)
        XCTAssertEqual(run.stops[0].name, "Ascona, Scuole")
        XCTAssertEqual(run.stops[0].ref, stationRef,
                       "The first pass-list placeholder carries the destination's ID")
        XCTAssertEqual(run.stops[0].arr, scheduled,
                       "An absent arrival must not become the mirror's 10:11:45 query clock")
        XCTAssertEqual(run.stops[0].dep, scheduled)
        XCTAssertEqual(run.stops[0].sched, scheduled)
        XCTAssertEqual(run.trainNumber, "1054", "Line 1 is not course 1054")
    }

    func testStationPlatformAndBothVehicleIDsShareTheLiveBus() async throws {
        try await checkLiveBus(mirrorFirst: false)
    }

    func testLateLiveAnswerReplacesTheMirrorCardAndKeepsPolling() async throws {
        try await checkLiveBus(mirrorFirst: true)
    }

    private func checkLiveBus(mirrorFirst: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let beforeDeparture = scheduled - 60
        _ = await fleet.drawTimetable(at: Date(timeIntervalSince1970: Double(beforeDeparture)),
                                     in: BBox(west: 8.70, south: 46.10, east: 8.90, north: 46.25))
        let initial = await fleet.stationBoard(placeId: stationID, at: beforeDeparture)
        let original = try XCTUnwrap(initial?.departures.first {
            $0.line == "1" && $0.to == "Losone, Sottochiesa" && $0.departure == scheduled
        })
        let live = OJPTimings.stopEventJourneys(AsconaBoardFixture.ojp)
        let liveID = try XCTUnwrap(live.first?.id)
        let platformRef = try XCTUnwrap(live.first?.stops.first {
            StopRegister.stationOf($0.ref) == stationRef
        }?.ref)
        let mirror = MirrorBoard.journeys(from: AsconaBoardFixture.mirror)
        // Match the production order: OJP first, then the mirror. The mirror
        // must never bring back a second white card over the live answer.
        if mirrorFirst { await fleet.ingestBoardFill(mirror) }
        await fleet.ingestBoardFill(live)
        if !mirrorFirst { await fleet.ingestBoardFill(mirror) }
        for moment in [beforeDeparture, scheduled + 120] {
            let station = await fleet.stationBoard(placeId: stationID, at: moment)
            let platform = await fleet.platformBoard(ref: platformRef, at: moment)
            for entries in [try XCTUnwrap(station).departures, try XCTUnwrap(platform).departures] {
                let rows = entries.filter {
                    $0.line == "1" && $0.to == "Losone, Sottochiesa"
                        && abs(($0.runIdentity?.scheduledDeparture ?? $0.departure) - scheduled) < 60
                }
                XCTAssertEqual(rows.count, 1, "This bus has one departure, with its delay on the main row")
                let row = try XCTUnwrap(rows.first)
                XCTAssertEqual(row.delay, 4)
                XCTAssertEqual(row.departure, scheduled + 240)
                let open = await fleet.journey(id: row.id, at: moment)
                let card = try XCTUnwrap(open)
                let call = try XCTUnwrap(card.stops.first { StopRegister.stationOf($0.ref) == stationRef })
                XCTAssertEqual(call.delay, row.delay)
                XCTAssertEqual(call.dep, row.departure)
                XCTAssertEqual(card.from, "Gordola, Centro Professionale")
            }
        }
        let mirrorID = try XCTUnwrap(mirror.first?.id)
        for id in [original.id, liveID, mirrorID] {
            let open = await fleet.journey(id: id, at: scheduled + 120)
            let call = try XCTUnwrap(open?.stops.first { StopRegister.stationOf($0.ref) == stationRef })
            XCTAssertEqual(call.delay, 4, "A map ID must also open the live version")
            XCTAssertEqual(call.dep, scheduled + 240)
        }

        // An open OJP card has no raw timetable ID. Its periodic response
        // must still update that card, its old mirror alias and the map bus.
        let update = JourneyTiming(byStop: [platformRef: CallTiming(
            planned: scheduled, expectedDeparture: scheduled + 360,
            plannedDeparture: scheduled
        )])
        let touched = await fleet.applyTiming(update, to: liveID,
                                             at: Date(timeIntervalSince1970: Double(scheduled + 120)))
        XCTAssertGreaterThan(touched, 0)
        await fleet.ingestBoardFill(MirrorBoard.journeys(from: AsconaBoardFixture.mirror))
        for id in [original.id, liveID, mirrorID] {
            let open = await fleet.journey(id: id, at: scheduled + 120)
            let call = try XCTUnwrap(open?.stops.first { StopRegister.stationOf($0.ref) == stationRef })
            XCTAssertEqual(call.delay, 6)
            XCTAssertEqual(call.dep, scheduled + 360)
        }
        let refreshed = await fleet.stationBoard(placeId: stationID, at: scheduled + 120)
        let rows = try XCTUnwrap(refreshed).departures.filter {
            $0.line == "1" && $0.to == "Losone, Sottochiesa"
                && $0.runIdentity?.scheduledDeparture == scheduled
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.delay, 6)
        XCTAssertEqual(rows.first?.departure, scheduled + 360)
    }
}
