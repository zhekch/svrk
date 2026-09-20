import XCTest
@testable import TransitCore

final class BoardExpiryTests: XCTestCase {
    private func time(_ text: String) -> Timestamp { OJPTimings.time(text)! }

    func testPastDeparturesExpireEvenWhenTrainIsStillRunning() {
        let now = time("2026-09-13T11:09:30Z")
        var row = BoardEntry(id: "ice", mode: .train, line: "ICE", to: "Brig", from: "Basel",
                             departure: now - 3600, arrival: now - 3660, running: true)
        XCTAssertFalse(row.isUpcoming(at: now))
        row.departure = Clock.displayMinute(now)
        XCTAssertTrue(row.isUpcoming(at: now), "The departure minute still reads now")
        XCTAssertFalse(row.isUpcoming(at: Clock.displayMinute(now) + 60))
        row.departure = now + 300
        row.delay = 65
        XCTAssertTrue(row.isUpcoming(at: now), "Use the delayed time, not the original timetable slot")
    }

    func testMidnightDropsYesterdayWithoutHidingNextDeparture() {
        let now = time("2026-09-11T22:40:00Z") // Saturday 00:40 in Switzerland
        let rows = ["2026-09-11T21:31:00Z", "2026-09-11T22:08:00Z", "2026-09-11T23:06:00Z"].map {
            BoardEntry(id: $0, mode: .train, line: "IC", from: "Bern", departure: time($0), arrival: time($0))
        }
        XCTAssertEqual(rows.filter { $0.isUpcoming(at: now) }.map(\.departure), [time("2026-09-11T23:06:00Z")])
        XCTAssertTrue(rows[0].isUpcoming(at: time("2026-09-11T21:30:00Z")), "Time travel uses the chosen clock")
    }

    func testEnrichmentKeepsUpcomingVisitWhenSameTrainAlreadyVisitedStation() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SwissTransit/Resources/Data")
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: dir, supporting: false)
        let now = time("2026-09-13T11:09:30Z")
        let refs = ["ch:1:sloid:7000:3:6", "ch:1:sloid:7100:2:2", "ch:1:sloid:7000:3:6", "ch:1:sloid:3000"]
        let moments = [now - 3600, now - 1800, now + 300, now + 3600]
        let names = ["Bern", "Thun", "Bern", "Zürich HB"]
        let calls = refs.indices.map { i in
            Call(key: "visit-\(i)", ref: refs[i], name: names[i], lat: 46.95, lon: 7.44,
                 platform: i == 1 ? "2" : "6", arr: moments[i] - 60,
                 dep: moments[i], sched: moments[i], scheduledArrival: moments[i] - 60)
        }
        let journey = Journey(id: "expiry-loop", mode: .train, category: "TEST", line: "TEST", number: "999999",
                              operatorName: nil, operatorFull: nil, to: "Zürich HB", from: "Bern", delay: nil,
                              start: calls[0].dep, end: calls.last!.arr, complete: true, monitored: false,
                              cancelled: false, source: "test", stops: calls)
        let date = Date(timeIntervalSince1970: Double(now))
        await fleet.apply([journey.id: journey], summary: .init(), started: date,
                          bytes: 0, source: "test", current: date)
        for preview in [true, false] {
            let station = await fleet.stationBoard(placeId: "8507000", at: now, preview: preview)
            let platform = await fleet.platformBoard(ref: refs[0], at: now, preview: preview)
            for board in [try XCTUnwrap(station).departures, try XCTUnwrap(platform).departures] {
                XCTAssertFalse(board.contains { !$0.isUpcoming(at: now) })
                let row = try XCTUnwrap(board.first { $0.id == journey.id })
                XCTAssertEqual(row.departure, now + 300, "Enrichment must select the upcoming visit, not the first Bern call")
                XCTAssertEqual(row.runIdentity?.scheduledDeparture, now + 300)
            }
        }
    }
}
