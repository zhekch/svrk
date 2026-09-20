import XCTest
@testable import TransitCore

final class SpiezLiveContinuityTests: XCTestCase {
    func testRealtimeDecoderReadsExplicitPlatformAssignment() throws {
        func message(_ field: UInt8, _ bytes: [UInt8]) -> [UInt8] {
            precondition(bytes.count < 128)
            return [field << 3 | 2, UInt8(bytes.count)] + bytes
        }
        let ref = "ch:1:sloid:7483:2:3"
        let properties = message(1, Array(ref.utf8))
        let stop: [UInt8] = [8, 1] + message(6, properties)
        let descriptor = message(1, Array("tt:1".utf8))
        let trip = message(1, descriptor) + message(2, stop)
        let feed = Protobuf.feed(Data(message(2, message(3, trip))))
        let update = try XCTUnwrap(feed.updates.first?.stops.first)
        XCTAssertEqual(update.sequence, 1)
        XCTAssertEqual(update.assignedStopID, ref)
        XCTAssertNil(update.stopID)
    }

    private func call(_ name: String, _ ref: String, _ time: Int, lat: Double) -> Call {
        Call(key: ref, ref: ref, name: name, lat: lat, lon: 7.68, arr: time, dep: time, sched: time)
    }
    private func run(_ id: String, line: String = "RE1", stops: [Call]) -> Journey {
        Journey(id: id, mode: .train, category: nil, line: line, number: nil,
                operatorName: "BLS", operatorFull: "BLS", to: stops.last?.name,
                from: stops[0].name, delay: nil, start: stops[0].dep, end: stops.last!.arr,
                complete: true, monitored: false, cancelled: false, source: Journey.timetableSource, stops: stops)
    }
    private var incoming: Journey {
        run("incoming", stops: [call("Bern", "ch:1:sloid:7000", 1000, lat: 46.95),
                                call("Spiez", "ch:1:sloid:7483", 2800, lat: 46.68)])
    }
    private func snapshot(_ journey: Journey, index: Int, moving: Bool = false) -> VehicleSnapshot {
        VehicleSnapshot(id: journey.id, mode: .train, line: journey.line, to: journey.to,
                        from: journey.from, lon: 7.68, lat: 46.68, moving: moving,
                        index: index, stops: journey.stops)
    }

    func testExpiredOpenCardStaysAtSpiezInsteadOfReturningToBern() throws {
        let journey = incoming
        let now = Positioning.standsUntil(journey) + 60
        XCTAssertNil(Positioning.position(of: journey, at: now))
        let panel = try XCTUnwrap(Positioning.panelPosition(of: journey, at: now))
        XCTAssertEqual(panel.index, 1)
        XCTAssertEqual(panel.lat, 46.68, accuracy: 0.00001)
        XCTAssertFalse(panel.moving)
    }

    func testSplitHandoffKeepsRE1GoingToBrigAndHonoursChosenR11() throws {
        let source = incoming
        let brig = run("brig", stops: [call("Spiez", "ch:1:sloid:7483", 2920, lat: 46.68),
                                       call("Brig", "ch:1:sloid:1609", 6000, lat: 46.32)])
        let r11 = run("zweisimmen", line: "R11", stops: [call("Spiez", "ch:1:sloid:7483", 2920, lat: 46.68),
                                                        call("Zweisimmen", "ch:1:sloid:7501", 5400, lat: 46.55)])
        // A published split, as the feed states it: one working, two successors.
        let published = ThroughGraph(links: [
            ThroughLink(from: [source.id], to: [brig.id]),
            ThroughLink(from: [source.id], to: [r11.id]),
        ])
        XCTAssertEqual(Chains.build([source, brig, r11], published: published).count, 3)
        XCTAssertNil(Chains.continuation(of: source, among: [brig, r11], preferredID: nil, at: 2919))
        XCTAssertEqual(Chains.continuation(of: source, among: [brig, r11], preferredID: nil, at: 2920)?.id, brig.id)
        XCTAssertEqual(Chains.continuation(of: source, among: [brig, r11], preferredID: r11.id, at: 2920)?.id, r11.id)
        brig.cancelled = true
        XCTAssertNil(Chains.continuation(of: source, among: [brig, r11], preferredID: nil, at: 2920))
    }

    func testPastSplitDisappearsFromBrigServiceAfterSpiez() {
        let split = TrainFormation.Split(stopName: "Spiez", stopUIC: 8507483, moment: nil, portions: [])
        let through = run("through", stops: incoming.stops + [
            call("Frutigen", "ch:1:sloid:7479", 3700, lat: 46.58),
            call("Brig", "ch:1:sloid:1609", 6000, lat: 46.32)])
        XCTAssertTrue(split.isUpcoming(for: snapshot(through, index: 0, moving: true), at: 2500))
        XCTAssertTrue(split.isUpcoming(for: snapshot(through, index: 1), at: 2850))
        XCTAssertFalse(split.isUpcoming(for: snapshot(through, index: 1, moving: true), at: 3000))
        XCTAssertFalse(split.isUpcoming(for: snapshot(through, index: 2), at: 3700))
        let portion = run("brig", stops: Array(through.stops.dropFirst()))
        XCTAssertFalse(split.isUpcoming(for: snapshot(portion, index: 0), at: 2900))
    }

    private func fixture() async throws -> (Fleet, Journey, String, Int) {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: directory, supporting: false)
        try await fleet.register.load(stopsFile: directory.appendingPathComponent("stops.bin"), foreignFile: nil)
        let moment = try XCTUnwrap(OJPTimings.time("2026-09-05T13:12:00Z"))
        _ = await fleet.drawTimetable(at: Date(timeIntervalSince1970: Double(moment)),
                                     in: BBox(west: 7.60, south: 46.60, east: 7.72, north: 46.75))
        let all = await fleet.everyRawJourney()
        let journey = try XCTUnwrap(all.sorted { $0.id < $1.id }.first {
            $0.line == "R11" && $0.stops.first?.name == "Spiez"
                && $0.start >= moment - 600 && $0.start < moment + 3600
        })
        var changedRef: String?
        for code in ["2", "3", "4", "5"] {
            if let platform = await fleet.register.platformPoint(station: "ch:1:sloid:7483", code: code),
               platform.id != journey.stops[0].ref { changedRef = platform.id; break }
        }
        return (fleet, journey, try XCTUnwrap(changedRef), moment)
    }

    private func update(_ journey: Journey, ref: String, id: String? = nil) -> TripUpdate {
        TripUpdate(tripID: id ?? journey.id, routeID: "91-11-G-j26-1",
                   relationship: id == nil ? .scheduled : .added,
                   stops: journey.stops.enumerated().map { index, stop in
            StopTimeUpdate(stopID: index == 0 ? ref : stop.ref, sequence: index + 1,
                           arrival: stop.arr, departure: stop.dep)
        })
    }

    func testCancellationPlusChangedPlatformRetainsScheduledIdentityInEitherFeedOrder() async throws {
        for reverse in [false, true] {
            let (fleet, original, ref, now) = try await fixture()
            let addedID = "platform-reissue"
            let new = update(original, ref: ref, id: addedID)
            let cancelled = TripUpdate(tripID: original.id, relationship: .canceled)
            let updates = reverse ? [new, cancelled] : [cancelled, new]
            for _ in 0..<2 {
                _ = await fleet.applyRealtime(RealtimeFeed(updates: updates), at: Date(timeIntervalSince1970: Double(now)))
                let all = await fleet.everyRawJourney()
                let retained = try XCTUnwrap(all.first { $0.id == original.id })
                XCTAssertFalse(retained.cancelled)
                XCTAssertFalse(retained.extra)
                XCTAssertEqual(retained.operatorName, "BLS")
                XCTAssertEqual(retained.stops[0].ref, ref)
                XCTAssertFalse(all.contains { $0.id == addedID })
            }
        }
    }

    func testDirectPlatformAssignmentUpdatesTheExistingCallAndCanReinstateIt() async throws {
        let (fleet, journey, ref, now) = try await fixture()
        let oldKey = journey.stops[0].key
        journey.cancelled = true
        journey.stops[0].cancelled = true
        let assigned = TripUpdate(tripID: journey.id, stops: [StopTimeUpdate(sequence: 1, assignedStopID: ref)])
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [assigned]), at: Date(timeIntervalSince1970: Double(now)))
        XCTAssertEqual(journey.stops[0].ref, ref)
        XCTAssertEqual(journey.stops[0].key, oldKey)
        XCTAssertFalse(journey.stops[0].cancelled)
        XCTAssertFalse(journey.cancelled)
    }

    func testUnrelatedExtraIsNotMergedAndCancelledTrainIsNotDrawn() async throws {
        let (fleet, original, ref, now) = try await fixture()
        var new = update(original, ref: ref, id: "different-run")
        for i in new.stops.indices {
            new.stops[i].arrival = new.stops[i].arrival.map { $0 + 600 }
            new.stops[i].departure = new.stops[i].departure.map { $0 + 600 }
        }
        _ = await fleet.applyRealtime(RealtimeFeed(updates: [new, TripUpdate(tripID: original.id, relationship: .canceled)]),
                                      at: Date(timeIntervalSince1970: Double(now)))
        let all = await fleet.everyRawJourney()
        XCTAssertTrue(all.contains { $0.id == "different-run" && $0.extra })
        let visible = await fleet.vehicles(in: BBox(west: 7, south: 46, east: 8, north: 47),
                                           at: original.start, withGeometry: false, including: original.id)
        XCTAssertFalse(visible.contains { $0.cancelled })
    }
}
