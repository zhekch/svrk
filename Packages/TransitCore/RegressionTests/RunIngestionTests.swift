import XCTest
@testable import TransitCore

final class RunIngestionTests: XCTestCase {
    func testLuzernBoatFeedsResolveOneRunBeforeBoardPresentation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: root.appendingPathComponent("SwissTransit/Resources/Data"), supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-07T17:24:00Z"))
        let firstBoard = await fleet.stationBoard(placeId: "8508492", at: now, limit: 200)
        let initial = try XCTUnwrap(firstBoard)
        let mirror = MirrorBoard.journeys(from: LuzernBoardFixture.mirror)
        let originals = initial.departures.filter { row in mirror.contains { $0.start == row.departure } }
        XCTAssertEqual(originals.count, 3)
        XCTAssertEqual(mirror.map { $0.stops.last!.name }, ["Alpnachstad (See)", "Alpnachstad (See)", "Küssnacht am Rigi (See)"])
        await fleet.ingestBoardFill(mirror)
        await fleet.ingestBoardFill(MirrorBoard.journeys(from: LuzernBoardFixture.mirror))
        let stored = await fleet.boardFillJourneys()
        XCTAssertEqual(stored.count, 3, "Aliases must not create extra stored records")
        let filledBoard = await fleet.stationBoard(placeId: "8508492", at: now, limit: 200)
        let board = try XCTUnwrap(filledBoard)
        for live in mirror {
            let rows = board.departures.filter { $0.departure == live.start && $0.mode == .boat }
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertFalse(row.line.hasPrefix("BAT"))
            let original = try XCTUnwrap(originals.first { $0.departure == live.start })
            let oldID = await fleet.journey(id: original.id, at: live.start, boardDeparture: original.departure)
            let alias = await fleet.journey(id: live.id, at: live.start)
            XCTAssertEqual(oldID?.id, alias?.id)
            XCTAssertEqual(alias?.to.map(StopNaming.display), row.to)
            let platform = try XCTUnwrap(oldID?.stops.first?.ref)
            let platformBoard = await fleet.platformBoard(ref: platform, at: now, limit: 200)
            XCTAssertEqual(platformBoard?.departures.filter { $0.departure == live.start }.count, 1)
        }
    }

    func testHourlyStansstadRunsShareThePublishedServiceAfterLiveIngestion() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: root.appendingPathComponent("SwissTransit/Resources/Data"), supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-07T17:25:00Z"))
        let initial = await fleet.stationBoard(placeId: "8505000", at: now, limit: 240)
        let later = await fleet.stationBoard(placeId: "8505000", at: now + 3_600, limit: 240)
        let rows = [try XCTUnwrap(initial), try XCTUnwrap(later)].compactMap {
            $0.departures.first { $0.to == "Stansstad" && $0.line == "IRLEX" && !$0.terminates }
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.departure)).count, 2)
        var feeds: [Journey] = []
        for row in rows.prefix(2) {
            let read = await fleet.journey(id: row.id, at: now, boardDeparture: row.departure)
            let vehicle = try XCTUnwrap(read)
            let ref = try XCTUnwrap(vehicle.journeyRef)
            let number = ref.split(separator: ":").last!.split(separator: "-").first.map(String.init)!
            feeds.append(Journey(id: ref, mode: .train, category: "IRLEX",
                line: OJPTimings.lineName(code: "IRLEX", number: number), number: number,
                operatorName: vehicle.operatorName, operatorFull: nil, to: vehicle.to, from: vehicle.from,
                delay: nil, start: vehicle.stops[0].dep, end: vehicle.stops.last!.arr,
                complete: true, monitored: true, cancelled: false, source: "ojp",
                stops: vehicle.stops, journeyRef: ref))
        }
        await fleet.ingestBoardFill(feeds)
        let refreshed = await fleet.stationBoard(placeId: "8505000", at: now, limit: 240)
        let times = Set(rows.prefix(2).map(\.departure))
        let hourly = try XCTUnwrap(refreshed).departures.filter { times.contains($0.departure) && $0.to == "Stansstad" }
        XCTAssertEqual(hourly.count, 2, "Different departures must remain different runs")
        XCTAssertEqual(Set(hourly.map(\.line)), ["IRLEX"])
        if hourly.count == 2 { XCTAssertTrue(hourly[0].sameService(as: hourly[1]), "The main board must group these as one expandable service") }
    }
}
