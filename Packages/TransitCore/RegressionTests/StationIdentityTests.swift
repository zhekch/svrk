import XCTest
@testable import TransitCore

final class StationIdentityTests: XCTestCase {
    private func fleet() async throws -> Fleet {
        let root = ProcessInfo.processInfo.environment["SVRK_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: directory)
        return fleet
    }

    private let now = Int(ISO8601DateFormatter().date(from: "2026-09-05T15:00:00+02:00")!.timeIntervalSince1970)

    func testStationTapResolvesIdentityBeforeBuildingDepartures() async throws {
        let fleet = try await fleet()
        let start = ContinuousClock.now
        let preview = await fleet.stationBoard(placeId: "ch:1:sloid:7000:0:1", at: now, loadingOnly: true)
        let elapsed = start.duration(to: .now)
        let loading = try XCTUnwrap(preview)
        XCTAssertEqual(loading.id, "8507000")
        XCTAssertEqual(loading.name, "Bern")
        XCTAssertTrue(loading.isLoading)
        XCTAssertTrue(loading.departures.isEmpty)
        XCTAssertTrue(loading.serving.isEmpty)

        let fullStart = ContinuousClock.now
        let full = await fleet.stationBoard(placeId: loading.id, at: now)
        let board = try XCTUnwrap(full)
        print("Bern station identity: \(elapsed); departure board: \(fullStart.duration(to: .now))")
        XCTAssertEqual(board.id, loading.id)
        XCTAssertEqual(board.name, loading.name)
        XCTAssertFalse(board.isLoading)
        XCTAssertFalse(board.departures.isEmpty)
        XCTAssertEqual(board.lon, loading.lon)
        XCTAssertEqual(board.lat, loading.lat)
    }

    func testBernPackedPreviewArrivesWithoutThroughWorkingOrLiveData() async throws {
        let fleet = try await fleet()
        await fleet.prepareBoardIndexes()
        let previewStart = ContinuousClock.now
        let previewBoard = await fleet.stationBoard(placeId: "8507000", at: now, preview: true)
        let previewElapsed = previewStart.duration(to: .now)
        let preview = try XCTUnwrap(previewBoard)
        print("Bern packed preview: \(previewElapsed)")
        XCTAssertFalse(preview.departures.isEmpty)
        XCTAssertTrue(preview.serving.isEmpty, "Serving routes belong on the full board")
        XCTAssertLessThan(previewElapsed, Duration.seconds(2))

        let fullStart = ContinuousClock.now
        let fullBoard = await fleet.stationBoard(placeId: "8507000", at: now)
        let fullElapsed = fullStart.duration(to: .now)
        let full = try XCTUnwrap(fullBoard)
        print("Bern full board after indexes: \(fullElapsed)")
        XCTAssertFalse(full.departures.isEmpty)
        XCTAssertLessThan(fullElapsed, Duration.seconds(4))
        XCTAssertTrue(
            full.departures.contains { $0.typicalIntervalMinutes != nil }
                || preview.departures.count == full.departures.count,
            "The full read should add cadence or at least keep the packed rows"
        )
    }

    func testPlatformTapRetainsTrackBeforeLoadingDepartures() async throws {
        let fleet = try await fleet()
        let ref = "ch:1:sloid:7000:0:1"
        let preview = await fleet.plateBoard(id: ref, at: now, loadingOnly: true)
        let loading = try XCTUnwrap(preview)
        let full = await fleet.plateBoard(id: ref, at: now)
        let board = try XCTUnwrap(full)
        XCTAssertEqual(loading.id, board.id)
        XCTAssertEqual(loading.code, board.code)
        XCTAssertEqual(loading.name, board.name)
        XCTAssertEqual(loading.rail, board.rail)
        XCTAssertTrue(loading.isLoading)
        XCTAssertTrue(loading.departures.isEmpty)
        XCTAssertFalse(board.isLoading)
    }

    func testGenericAliasesKeepNamedNeighbouringStopsSeparate() {
        for (child, parent) in [("Bern, Hauptbahnhof", "Bern"), ("Bern Hauptbahnhof", "Bern"),
                                ("Bern, Bahnhof", "Bern"), ("Zürich, Bahnhof", "Zürich HB"),
                                ("Lausanne, gare", "Lausanne"), ("Lugano, Stazione", "Lugano")] {
            XCTAssertTrue(Fleet.isGenericStationStop(child, stationName: parent))
            XCTAssertTrue(Fleet.partOfStation(child, parent))
        }
        for child in ["Bern, Welle 7", "Bern, Schanzenstrasse", "Bern, Wankdorf Bahnhof", "Bernex, Bahnhof"] {
            XCTAssertFalse(Fleet.isGenericStationStop(child, stationName: "Bern"))
        }
        let rail = StopPlace(id: "rail", name: "Bern", lon: 7.4391, lat: 46.9488, rail: true, kerbs: 0)
        let bus = StopPlace(id: "bus", name: "Bern", lon: rail.lon, lat: rail.lat, rail: false, kerbs: 1)
        XCTAssertFalse(Fleet.isStationParent(bus, of: rail), "a railway station must never be demoted to a bus stop")
        XCTAssertTrue(Fleet.isStationParent(rail, of: bus))
        var distant = rail
        distant.lon += 0.03
        XCTAssertFalse(Fleet.isStationParent(distant, of: bus))
    }

    func testBernTrainReferencesOpenCombinedInterchange() async throws {
        let fleet = try await fleet()
        for id in ["8507000", "ch:1:sloid:7000", "ch:1:sloid:7000:0:1",
                   "ch:1:sloid:7000_gen:ch:1:sloid:7000:0:1_pf:1AB"] {
            let result = await fleet.stationBoard(placeId: id, at: now)
            let board = try XCTUnwrap(result, id)
            XCTAssertEqual(board.id, "8507000", id)
            XCTAssertEqual(board.name, "Bern", id)
            let modes = Set(board.departures.map(\.mode))
            XCTAssertTrue(modes.contains(.train), "\(id): \(modes)")
            XCTAssertTrue(modes.contains(.tram), "\(id): \(modes)")
            XCTAssertTrue(modes.contains(.bus), "\(id): \(modes)")
        }
    }

    func testBernGenericStationAliasesUseSameBoard() async throws {
        let fleet = try await fleet()
        let places = await fleet.stopPlaces.nearby(lon: 7.4391, lat: 46.9491, within: 650, limit: 200)
        let aliases = places.filter { ["Bern, Bahnhof", "Bern, Hauptbahnhof", "Bern Hauptbahnhof"].contains($0.name) }
        XCTAssertFalse(aliases.isEmpty)
        for alias in aliases {
            let board = await fleet.stationBoard(placeId: alias.id, at: now)
            XCTAssertEqual(board?.id, "8507000", "\(alias.id): \(alias.name)")
            XCTAssertTrue(board?.departures.contains { $0.mode == .train } == true)
            XCTAssertTrue(board?.departures.contains { $0.mode == .tram } == true)
        }
    }

    func testLookupDoesNotConfusePlatformIdentityWithNearbyStops() async throws {
        let fleet = try await fleet()
        for (sloid, didok) in [("7000", "8507000"), ("7483", "8507483"), ("7100", "8507100")] {
            let expected = await fleet.stopPlaces.place(id: didok)
            XCTAssertNotNil(expected)
            for ref in ["ch:1:sloid:\(sloid)", "ch:1:sloid:\(sloid):0:1", "ch:1:sloid:\(sloid)_gen_pf:1"] {
                let found = await fleet.stopPlaces.place(id: ref)
                XCTAssertEqual(found, expected)
            }
        }
        for ref in ["not-a-station", "ch:1:sjyid:100001:7000", "ch:1:sloid:unknown"] {
            let found = await fleet.stopPlaces.place(id: ref)
            XCTAssertNil(found)
        }
    }
}
