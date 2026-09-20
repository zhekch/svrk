import XCTest
@testable import TransitCore

final class ICEReplacementTests: XCTestCase {
    private let now = 1_789_295_580 // 2026-09-13 12:33 Europe/Zurich
    private var moment: Date { Date(timeIntervalSince1970: Double(now)) }

    private func fleet(_ original: Journey) async throws -> Fleet {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: dir, supporting: false)
        try await fleet.register.load(stopsFile: dir.appendingPathComponent("stops.bin"), foreignFile: nil)
        await fleet.apply([original.id: original], summary: .init(), started: moment,
                          bytes: 0, source: "test", current: moment)
        return fleet
    }

    private func withdrawn(_ original: Journey) -> TripUpdate {
        // Screenshot's old entry: six calls cancelled, endpoints still running.
        TripUpdate(tripID: original.id, stops: original.stops.enumerated().map { index, call in
            StopTimeUpdate(stopID: call.ref, sequence: index + 1,
                           arrival: call.arr, departure: call.dep, skipped: (1...6).contains(index))
        })
    }

    func testLiveICEReplacesPartialCancellationInEitherOrderAndOnLaterRefresh() async throws {
        for reverse in [false, true] {
            let original = ICEReplacementFixture.original()
            let fleet = try await fleet(original)
            let old = withdrawn(original)
            _ = await fleet.applyRealtime(RealtimeFeed(updates: [old]), at: moment)
            XCTAssertEqual(original.stops.filter(\.cancelled).count, 6)
            let added = ICEReplacementFixture.update
            for _ in 0..<2 {
                _ = await fleet.applyRealtime(RealtimeFeed(updates: reverse ? [added, old] : [old, added]), at: moment)
                let all = await fleet.everyRawJourney()
                XCTAssertEqual(all.count, 1)
                XCTAssertEqual(all.first?.id, original.id)
                XCTAssertEqual(original.line, "ICE")
                XCTAssertEqual(original.trainNumber, "2871")
                XCTAssertEqual(original.journeyRef, "ch:1:sjyid:100001:2871-874")
                XCTAssertFalse(original.extra)
                XCTAssertFalse(original.cancelled)
                XCTAssertFalse(original.stops.contains(where: \.cancelled))
                for (call, update) in zip(original.stops, added.stops.dropFirst()) {
                    XCTAssertEqual(call.ref, update.stopID)
                    if let arr = update.arrival { XCTAssertEqual(call.arr, arr) }
                    if let dep = update.departure { XCTAssertEqual(call.dep, dep) }
                }
                let opened = await fleet.journey(id: added.tripID, at: now)
                XCTAssertEqual(opened?.line, "ICE", "An open extra card must resolve to the ICE")
                XCTAssertEqual(opened?.id, original.id)
            }
            // An old update arriving alone must not restore withdrawn platforms.
            _ = await fleet.applyRealtime(RealtimeFeed(updates: [old]), at: moment)
            XCTAssertFalse(original.stops.contains(where: \.cancelled))
            XCTAssertEqual(original.stops[1].ref, added.stops[2].stopID)
        }
    }

    func testExistingExtraRecordAndItsAliasesAreRemovedWhenTimetableArrives() async throws {
        let original = ICEReplacementFixture.original()
        let fleet = try await fleet(original)
        // A different timetable slot initially prevents reconciliation.
        for i in original.stops.indices { original.stops[i].sched! += 3600 }
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [ICEReplacementFixture.update]), at: moment)
        let before = await fleet.everyRawJourney()
        XCTAssertEqual(before.count, 2)
        for i in original.stops.indices { original.stops[i].sched! -= 3600 }
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [ICEReplacementFixture.update]), at: moment)
        let after = await fleet.everyRawJourney()
        XCTAssertEqual(after.count, 1)
        let alias = await fleet.journey(id: ICEReplacementFixture.id, at: now)
        XCTAssertEqual(alias?.id, original.id)
        XCTAssertEqual(alias?.line, "ICE")
    }

    func testAmbiguousOrDifferentDayExtraIsNotMerged() async throws {
        for ambiguous in [false, true] {
            let original = ICEReplacementFixture.original()
            let fleet = try await fleet(original)
            var added = ICEReplacementFixture.update
            if ambiguous {
                let other = ICEReplacementFixture.original()
                other.id = "another-ice"
                other.number = "999"
                other.journeyRef = "ch:1:sjyid:100001:999-001"
                await fleet.apply([original.id: original, other.id: other], summary: .init(),
                                  started: moment, bytes: 0, source: "test", current: moment)
            } else {
                for i in added.stops.indices {
                    added.stops[i].arrival = added.stops[i].arrival.map { $0 + 86400 }
                    added.stops[i].departure = added.stops[i].departure.map { $0 + 86400 }
                }
            }
            _ = await fleet.applyRealtime(RealtimeFeed(updates: [added]), at: moment)
            let all = await fleet.everyRawJourney()
            XCTAssertTrue(all.contains { $0.id == added.tripID && $0.extra })
            XCTAssertEqual(original.number, "101")
        }
    }

    func testReplacementCancellationAppliesToCanonicalTrain() async throws {
        let original = ICEReplacementFixture.original()
        let fleet = try await fleet(original)
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [ICEReplacementFixture.update]), at: moment)
        let cancel = TripUpdate(tripID: ICEReplacementFixture.id, relationship: .canceled)
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [cancel, withdrawn(original)]), at: moment)
        XCTAssertTrue(original.cancelled)
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [ICEReplacementFixture.update]), at: moment)
        XCTAssertFalse(original.cancelled)
    }

    func testReplacementIdentitySurvivesTimetableRefreshAndAppearsOnceOnBoard() async throws {
        let original = ICEReplacementFixture.original()
        let fleet = try await fleet(original)
        let added = ICEReplacementFixture.update
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [added]), at: moment)
        let freshPlan = ICEReplacementFixture.original()
        await fleet.apply([freshPlan.id: freshPlan], summary: .init(), started: moment,
                          bytes: 0, source: "test", current: moment)
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [withdrawn(freshPlan), added]), at: moment)
        let all = await fleet.everyRawJourney()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.number, "2871")
        XCTAssertFalse(all.first!.stops.contains(where: \.cancelled))
        let board = await fleet.stationBoard(placeId: "8507483", at: now, limit: 200)
        let rows = try XCTUnwrap(board).departures.filter {
            $0.runIdentity?.references.contains(original.id) == true
                || $0.runIdentity?.references.contains(added.tripID) == true
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.line, "ICE")
        let alias = await fleet.journey(id: added.tripID, at: now)
        XCTAssertEqual(alias?.id, original.id)
    }

    func testReplacementMappingDoesNotConsumeNextDaysOccurrence() async throws {
        let original = ICEReplacementFixture.original()
        let fleet = try await fleet(original)
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [ICEReplacementFixture.update]), at: moment)
        let tomorrow = ICEReplacementFixture.original()
        for index in tomorrow.stops.indices {
            tomorrow.stops[index].arr += 86400
            tomorrow.stops[index].dep += 86400
            tomorrow.stops[index].sched! += 86400
            tomorrow.stops[index].scheduledArrival! += 86400
        }
        tomorrow.start += 86400; tomorrow.end += 86400
        let date = moment.addingTimeInterval(86400)
        await fleet.apply([tomorrow.id: tomorrow], summary: .init(), started: date,
                          bytes: 0, source: "test", current: date)
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [withdrawn(tomorrow)]), at: date)
        XCTAssertEqual(tomorrow.number, "101")
        XCTAssertEqual(tomorrow.stops.filter(\.cancelled).count, 6)
    }

    func testEmbeddedJourneyReferenceRequiresRecognizedShapeAndMatchingDate() {
        var update = ICEReplacementFixture.update
        XCTAssertEqual(update.journeyReference, "ch:1:sjyid:100001:2871-874")
        update.startDate = "20260914"
        XCTAssertNil(update.journeyReference)
        update.tripID = "random_2871"
        XCTAssertNil(update.journeyReference)
    }
}
