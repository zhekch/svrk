import XCTest
@testable import TransitCore

final class SelectedRouteTests: XCTestCase {
    func testBernBrigIC6RetainsMappedRouteWhenReadFromMap() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: root.appendingPathComponent("SwissTransit/Resources/Data"))
        let now = try XCTUnwrap(OJPTimings.time("2026-09-07T21:18:00Z"))
        _ = await fleet.drawTimetable(at: Date(timeIntervalSince1970: Double(now)),
            in: BBox(west: 7.3, south: 46.2, east: 8.1, north: 47.0))
        let runs = await fleet.everyRawJourney()
        let candidates = runs.filter { $0.line == "IC6" && $0.to == "Brig" }
        let run = try XCTUnwrap(candidates.first { $0.start <= now && $0.end >= now })
        let fetched = await fleet.journeyGeometry(id: run.id)
        let geometry = try XCTUnwrap(fetched)
        XCTAssertGreaterThan(geometry.path.count, 2)
        XCTAssertTrue(geometry.legSources.contains { $0 != .chord })
        // Opening a train requests OJP. Its alias replaces the timetable
        // record after the map has already drawn the timetable geometry.
        let live = Journey(id: "live-ic6", mode: run.mode, category: run.category,
            line: run.line, number: run.number, operatorName: run.operatorName,
            operatorFull: "Schweizerische Bundesbahnen SBB", to: run.to, from: run.from,
            delay: nil, start: run.start, end: run.end, complete: true, monitored: true,
            cancelled: false, source: "ojp", stops: run.stops, journeyRef: run.journeyRef)
        await fleet.ingestBoardFill([live])
        for second in [0, 1, 5, 30] {
            let selected = await fleet.journey(id: run.id, at: now + second)
            XCTAssertEqual(selected?.id, run.id)
            XCTAssertEqual(selected?.geometry, geometry)
        }
    }

    func testBrigBernRE1KeepsMappedRouteWhenLiveAliasAddsStops() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: root.appendingPathComponent("SwissTransit/Resources/Data"))
        let now = try XCTUnwrap(OJPTimings.time("2026-09-05T10:10:00Z"))
        _ = await fleet.drawTimetable(at: Date(timeIntervalSince1970: Double(now)),
            in: BBox(west: 7.3, south: 46.2, east: 8.1, north: 47.0))
        let vehicle = try await brigBernRE1(in: fleet, at: now)
        let fetched = await fleet.journeyGeometry(id: vehicle.id)
        let geometry = try XCTUnwrap(fetched)
        XCTAssertGreaterThan(geometry.path.count, 2)
        XCTAssertTrue(geometry.legSources.contains { $0 != .chord })

        var liveStops = vehicle.stops
        if liveStops.last?.name.contains("Bern") != true {
            let last = try XCTUnwrap(liveStops.last)
            liveStops.append(Call(
                key: "ch:1:sloid:7000|ojp-bern", ref: "ch:1:sloid:7000", name: "Bern",
                lat: 46.9488, lon: 7.4391, arr: last.arr + 1800, dep: last.arr + 1800,
                sched: last.arr + 1800
            ))
        } else {
            liveStops[liveStops.count - 1].platform = liveStops[liveStops.count - 1].platform == nil ? "3" : "9"
        }
        let live = Journey(
            id: "live-re1-4268", mode: vehicle.mode, category: vehicle.category,
            line: vehicle.line, number: vehicle.stops.first.map { _ in "4268" },
            operatorName: vehicle.operatorName, operatorFull: "BLS AG",
            to: "Bern", from: vehicle.from, delay: nil,
            start: liveStops[0].dep, end: liveStops.last!.arr, complete: true,
            monitored: true, cancelled: false, source: "ojp", stops: liveStops,
            journeyRef: vehicle.journeyRef ?? vehicle.parts?.first?.journeyRef
        )
        await fleet.ingestBoardFill([live])
        let selectedRead = await fleet.journey(id: vehicle.id, at: now)
        let selected = try XCTUnwrap(selectedRead)
        XCTAssertEqual(selected.id, vehicle.id)
        if let kept = selected.geometry {
            XCTAssertGreaterThan(kept.path.count, 2)
        } else {
            let rebuilt = await fleet.journeyGeometry(id: vehicle.id)
            XCTAssertGreaterThan(try XCTUnwrap(rebuilt).path.count, 2)
        }
    }

    func testChainedRE1KeepsIdentityWhenLiveAliasAddsContinuation() async throws {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        let now = 1_788_853_080
        func call(_ name: String, _ ref: String, _ offset: Int) -> Call {
            Call(key: ref, ref: ref, name: name, lat: 46.5, lon: 7.6,
                 arr: now + offset, dep: now + offset, sched: now + offset)
        }
        let head = Journey(
            id: "tt:4268", mode: .train, category: "RE", line: "RE1", number: "4268",
            operatorName: "BLS", operatorFull: "BLS", to: "Bern", from: "Brig",
            delay: nil, start: now, end: now + 3600, complete: true, monitored: false,
            cancelled: false, source: Journey.timetableSource,
            stops: [
                call("Brig", "ch:1:sloid:1609", 0),
                call("Visp", "ch:1:sloid:1605", 1200),
                call("Spiez", "ch:1:sloid:7483", 3600)
            ],
            journeyRef: "ch:1:sjyid:100015:4268-001"
        )
        let tail = Journey(
            id: "tt:4168", mode: .train, category: "RE", line: "RE1", number: "4168",
            operatorName: "BLS", operatorFull: "BLS", to: "Bern", from: "Spiez",
            delay: nil, start: now + 3960, end: now + 5400, complete: true,
            monitored: false, cancelled: false, source: Journey.timetableSource,
            stops: [
                call("Spiez", "ch:1:sloid:7483", 3960),
                call("Thun", "ch:1:sloid:7100", 4500),
                call("Bern", "ch:1:sloid:7000", 5400)
            ],
            journeyRef: "ch:1:sjyid:100015:4168-001"
        )
        let at = Date(timeIntervalSince1970: Double(now + 600))
        await fleet.apply(
            [head.id: head, tail.id: tail], summary: SiriParser.Summary(),
            started: at, bytes: 0, source: "test", current: at, drawnAt: at
        )
        let selectedRead = await fleet.journey(id: head.id, at: now + 600)
        let selected = try XCTUnwrap(selectedRead)
        XCTAssertEqual(selected.to, "Bern")
        XCTAssertEqual(selected.parts?.count, 2)
        let fetchedGeometry = await fleet.journeyGeometry(id: head.id)
        let geometry = try XCTUnwrap(fetchedGeometry)
        XCTAssertGreaterThan(geometry.path.count, 2)

        var liveStops = head.stops
        liveStops.append(contentsOf: tail.stops.dropFirst())
        let live = Journey(
            id: "live:4268", mode: .train, category: "RE", line: "RE1", number: "4268",
            operatorName: "BLS", operatorFull: "BLS", to: "Bern", from: "Brig",
            delay: nil, start: now, end: now + 5400, complete: true, monitored: true,
            cancelled: false, source: "ojp", stops: liveStops,
            journeyRef: head.journeyRef
        )
        await fleet.ingestBoardFill([live])
        let afterRead = await fleet.journey(id: head.id, at: now + 600)
        let after = try XCTUnwrap(afterRead)
        XCTAssertEqual(after.id, selected.id)
        if after.geometry == nil {
            let rebuilt = await fleet.journeyGeometry(id: head.id)
            XCTAssertGreaterThan(try XCTUnwrap(rebuilt).path.count, 2)
        } else {
            XCTAssertGreaterThan(after.geometry!.path.count, 2)
        }
        let aliasRead = await fleet.journey(id: live.id, at: now + 600)
        XCTAssertEqual(try XCTUnwrap(aliasRead).id, selected.id)
    }

    private func brigBernRE1(in fleet: Fleet, at now: Timestamp) async throws -> VehicleSnapshot {
        let runs = await fleet.everyRawJourney()
        let heads = runs.filter {
            $0.line == "RE1" && $0.mode == .train
                && ($0.from.contains("Brig") || $0.stops.first?.name.contains("Brig") == true)
                && $0.start <= now && $0.end >= now
        }
        XCTAssertFalse(heads.isEmpty, "No RE1 from Brig is running in the packed timetable at this moment")
        for head in heads {
            guard let vehicle = await fleet.journey(id: head.id, at: now) else { continue }
            if vehicle.to?.contains("Bern") == true
                || vehicle.stops.contains(where: { $0.name.contains("Bern") }) {
                return vehicle
            }
        }
        let fallback = await fleet.journey(id: heads[0].id, at: now)
        return try XCTUnwrap(fallback)
    }
}
