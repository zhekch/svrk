import XCTest
@testable import TransitCore

final class RoutePatternTests: XCTestCase {
    private let path = [Coord(lon: 7, lat: 46), Coord(lon: 7.1, lat: 46), Coord(lon: 7.15, lat: 46.05)]
    private let bounds = BBox(west: 6, south: 45, east: 9, north: 48)

    func testZoomKeepsExistingMarksAtTheSameCoordinates() {
        let pattern = RoutePattern(path: path)
        let fine = pattern.marks(spacing: 48, in: bounds)
        let coarse = pattern.marks(spacing: 96, in: bounds)
        for mark in coarse {
            let existing = fine.first { $0.distance == mark.distance }
            XCTAssertEqual(existing?.coordinate, mark.coordinate)
            XCTAssertEqual(existing?.direction, mark.direction)
        }
        let nearbyZoom = pattern.marks(spacing: 55, in: bounds)
        XCTAssertEqual(fine.map(\.coordinate), nearbyZoom.map(\.coordinate))
        XCTAssertLessThan(nearbyZoom[0].scale, fine[0].scale)
    }

    func testPanningOnlyFiltersMarksWithoutRestartingThePattern() {
        let pattern = RoutePattern(path: path)
        let window = BBox(west: 7.04, south: 45, east: 7.12, north: 48)
        let full = pattern.marks(spacing: 64, in: bounds)
        XCTAssertEqual(pattern.marks(spacing: 64, in: window).map(\.coordinate),
                       full.filter { window.contains(lon: $0.coordinate.lon, lat: $0.coordinate.lat) }.map(\.coordinate))
    }

    func testVisibleLengthExcludesGeometryBehindTheViewport() {
        let pattern = RoutePattern(path: [Coord(lon: 7, lat: 46), Coord(lon: 8, lat: 46)])
        let window = BBox(west: 7.4, south: 45.9, east: 7.5, north: 46.1)
        XCTAssertEqual(pattern.visibleLength(in: window),
                       Geo.metres(Coord(lon: 7.4, lat: 46), Coord(lon: 7.5, lat: 46)), accuracy: 0.001)
        XCTAssertEqual(pattern.visibleLength(in: BBox(west: 9, south: 45, east: 10, north: 47)), 0)
    }

    func testMovingVehicleOnlyRevealsAdditionalDots() {
        let pattern = RoutePattern(path: path)
        let before = pattern.marks(spacing: 64, in: bounds, through: 2000)
        let after = pattern.marks(spacing: 64, in: bounds, through: 2200)
        XCTAssertEqual(before.map(\.coordinate), Array(after.prefix(before.count)).map(\.coordinate))
        XCTAssertGreaterThan(after.count, before.count)
    }

    func testRevisitedTrackUsesDistanceAlongTheCurrentLeg() {
        let pattern = RoutePattern(path: [path[0], path[1], path[0]])
        let outbound = pattern.distance(from: 0, to: 1, progress: 0.5)
        let inbound = pattern.distance(from: 1, to: 2, progress: 0.5, trailing: 20)
        XCTAssertEqual(inbound, outbound * 3 - 20, accuracy: 0.001)
    }
}
