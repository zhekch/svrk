import XCTest
@testable import TransitCore

final class TunnelVisibilityTests: XCTestCase {
    private let west = Coord(lon: 8, lat: 46.5)

    private func point(_ metres: Double, north: Double = 0) -> Coord {
        Coord(
            lon: west.lon + metres / (Geo.metresPerDegree * cos(Geo.toRad(west.lat))),
            lat: west.lat + north / Geo.metresPerDegree
        )
    }

    private func index(length: Double = 3_000, stations: [Coord]) -> TunnelIndex {
        let step = min(100, max(10, length / 10))
        return TunnelIndex(
            [stride(from: 0.0, through: length, by: step).map { point($0) }],
            stations: stations
        )
    }

    func testCoveredPlatformsRemainVisibleWithoutOpeningTheWholeTunnel() throws {
        let index = index(stations: [point(1_500)])
        for along in stride(from: 1_300.0, through: 1_700, by: 25) {
            XCTAssertNotNil(index.onTrack(point(along)))
            XCTAssertNil(index.hiding(at: point(along)))
            XCTAssertEqual(index.fade(at: point(along)), 0)
        }
        for along in [500.0, 1_100, 1_900, 2_500] {
            XCTAssertNotNil(index.hiding(at: point(along)))
            XCTAssertEqual(index.fade(at: point(along)), 1)
        }
        let bore = try XCTUnwrap(index.bores.first)
        XCTAssertEqual(bore.entrance, point(0))
        XCTAssertEqual(bore.exit, point(3_000))
        XCTAssertEqual(bore.altitude(along: bore.length / 2, entrance: 500, exit: 800), 650)
    }

    func testMarkerFadesAtBothStationExitsAndBothTunnelPortals() {
        let index = index(stations: [point(1_500)])
        for along in [18.0, 1_500 - TunnelIndex.stationHalfLength - 18,
                      1_500 + TunnelIndex.stationHalfLength + 18, 2_982] {
            for heading in [90.0, 270.0] {
                XCTAssertEqual(index.fade(at: point(along), heading: heading), 0.5, accuracy: 0.06)
            }
        }
        XCTAssertNil(index.hiding(at: point(500), heading: 0), "Crossing traffic is not underground")
    }

    func testShortCoverDoesNotHideWagons() throws {
        let index = TunnelIndex([stride(from: 0.0, through: 40, by: 10).map { point($0) }])
        let bore = try XCTUnwrap(index.bores.first)
        XCTAssertEqual(bore.length, 40, accuracy: 1)
        XCTAssertLessThan(bore.length, TunnelIndex.minHideMetres)
        for along in stride(from: 0.0, through: 40, by: 5) {
            XCTAssertNil(index.hiding(at: point(along)), "\(along)m into a 40 m cover")
            XCTAssertEqual(index.fade(at: point(along)), 0)
        }
    }

    func testTunnelJustAboveMinHideStillConceals() throws {
        let length = TunnelIndex.minHideMetres + 20
        let index = TunnelIndex([stride(from: 0.0, through: length, by: 10).map { point($0) }])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(index.bores.first).length, TunnelIndex.minHideMetres)
        XCTAssertNotNil(index.hiding(at: point(length / 2)))
        XCTAssertEqual(index.fade(at: point(length / 2)), 1)
        XCTAssertEqual(index.fade(at: point(18)), 0.5, accuracy: 0.06)
    }

    func testShortStubAfterUndergroundStationStaysVisible() throws {
        // Station at 50 m on a 310 m bore: the platform window covers 0...270,
        // leaving a 40 m stub to the portal. Leaving the station must not
        // swallow the whole rake and spit it out at the arch.
        let index = index(length: 310, stations: [point(50)])
        let bore = try XCTUnwrap(index.bores.first)
        XCTAssertEqual(bore.stations.first?.lowerBound ?? -1, 0, accuracy: 1)
        XCTAssertEqual(bore.stations.first?.upperBound ?? -1, 270, accuracy: 2)
        for along in stride(from: 0.0, through: 310, by: 10) {
            XCTAssertNil(index.hiding(at: point(along)), "\(along)m on a station plus a short stub")
            XCTAssertEqual(index.fade(at: point(along)), 0)
        }
        XCTAssertNotNil(index.onTrack(point(290)), "The stub is still tunnel track")
    }

    func testLongTunnelBeyondTheStationStillHides() {
        let index = index(length: 3_000, stations: [point(1_500)])
        XCTAssertNil(index.hiding(at: point(1_500)))
        XCTAssertNotNil(index.hiding(at: point(1_500 + TunnelIndex.stationHalfLength + 40)))
        XCTAssertEqual(
            index.fade(at: point(1_500 + TunnelIndex.stationHalfLength + 18)),
            0.5,
            accuracy: 0.06
        )
    }

    func testStationDoesNotExposeAnUnrelatedTunnelBesideIt() {
        let index = index(stations: [point(1_500, north: 100)])
        XCTAssertNotNil(index.hiding(at: point(1_500)))
        XCTAssertEqual(index.fade(at: point(1_500)), 1)
    }

    func testShortGapBetweenCoveredPlatformsStaysVisible() {
        let index = index(stations: [point(400), point(900)])
        // 400 ± 220 = 180...620, 900 ± 220 = 680...1120, a 60 m gap.
        for along in stride(from: 180.0, through: 1_120, by: 20) {
            XCTAssertNil(index.hiding(at: point(along)), "\(along)m between close covered platforms")
        }
        XCTAssertNotNil(index.hiding(at: point(80)))
        XCTAssertNotNil(index.hiding(at: point(1_500)))
    }

    func testOverlappingPlatformSectionsHaveNoHiddenGap() {
        let index = index(stations: [point(1_350), point(1_650)])
        for along in stride(from: 1_150.0, through: 1_850, by: 25) {
            XCTAssertNil(index.hiding(at: point(along)))
        }
        XCTAssertNotNil(index.hiding(at: point(1_000)))
        XCTAssertNotNil(index.hiding(at: point(2_000)))
    }

    func testBernCoveredTracksUseRegisteredRailPlatforms() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: data.appendingPathComponent("railnet.bin").path
        ), "Bundled railway data is required for the Bern regression")
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        try await fleet.register.load(stopsFile: data.appendingPathComponent("stops.bin"), foreignFile: nil)
        try await fleet.stopPlaces.load(data.appendingPathComponent("stop-places.bin"))
        try await fleet.railnet.load(data.appendingPathComponent("railnet.bin"))
        let box = BBox(west: 7.41, south: 46.94, east: 7.46, north: 46.97)
        let tunnelBit = await fleet.trackKindBit("tunnel")
        let lines = await fleet.trackLines(in: box, kindMask: tunnelBit)
        let stations = await fleet.tunnelStationPoints(in: box)
        let index = TunnelIndex(lines.map(\.points), stations: stations)
        let bern = Coord(lon: 7.4391, lat: 46.9490)
        let platforms = stations.filter { Geo.metres($0, bern) < 400 }
        XCTAssertGreaterThan(platforms.count, 10)
        var covered = 0
        for platform in platforms {
            guard let hit = index.onTrack(platform) else { continue }
            covered += 1
            XCTAssertNil(index.hiding(at: platform), "Bern platform at \(platform) was hidden")
            XCTAssertFalse(index.bores[hit.bore].stations.isEmpty)
        }
        XCTAssertGreaterThan(covered, 5, "The regression must exercise real tunnel-tagged station tracks")
        let stillHidden = index.bores.flatMap(\.points).filter { index.hiding(at: $0) != nil }
        XCTAssertFalse(stillHidden.isEmpty, "Tunnels outside platforms must remain hidden")
    }
}
