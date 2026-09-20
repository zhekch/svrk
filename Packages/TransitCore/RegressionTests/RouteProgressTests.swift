import XCTest
@testable import TransitCore

final class RouteProgressTests: XCTestCase {
    func testInferredConnectionsKeepTheirPlaceAcrossAReturnJourney() {
        let a = Coord(lon: 7, lat: 46), b = Coord(lon: 7.1, lat: 46)
        let path = [a, b, a, b]
        let geometry = JourneyGeometry(path: path, legs: [0, 1, 2, 3], source: .osmRoute, mixed: true,
                                       legSources: [.route, .chord, .chord], relation: nil, ways: [], routeName: nil)
        let ranges = RouteProgress(path: path).inferredRanges(in: geometry)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].lowerBound, Geo.metres(a, b), accuracy: 0.001)
        XCTAssertEqual(ranges[0].upperBound, 3 * Geo.metres(a, b), accuracy: 0.001)
    }

    func testMappedAndEntirelyEstimatedRoutesRemainDistinctWithoutLegMetadata() {
        let path = [Coord(lon: 7, lat: 46), Coord(lon: 7.1, lat: 46)]
        var geometry = JourneyGeometry(path: path, legs: [0, 1], source: .straight, mixed: false,
                                       legSources: [], relation: nil, ways: [], routeName: nil)
        let progress = RouteProgress(path: path)
        XCTAssertEqual(progress.inferredRanges(in: geometry), [0...Geo.metres(path[0], path[1])])
        geometry.source = .railGraph
        XCTAssertTrue(progress.inferredRanges(in: geometry).isEmpty)
    }

    func testNativeTrimConvertsGroundDistanceAndClampsAtRouteEnds() {
        let a = Coord(lon: 7.5, lat: 46), b = Coord(lon: 7.5, lat: 47)
        let length = Geo.metres(a, b)
        let route = RouteProgress(path: [a, b])
        let expected = (northing(46.5) - northing(46)) / (northing(47) - northing(46))
        XCTAssertEqual(route.fraction(atGroundDistance: length / 2), expected, accuracy: 1e-10)
        XCTAssertEqual(route.fraction(atGroundDistance: -20), 0)
        XCTAssertEqual(route.fraction(atGroundDistance: length + 20), 1)
    }

    func testSplitUsesCurrentVisitOnAnOutAndBackRoute() {
        let a = Coord(lon: 7, lat: 46), b = Coord(lon: 7.1, lat: 46)
        let path = [a, b, a]
        let progress = RouteProgress(path: path)
        let vehicle = Coord(lon: 7.05, lat: 46)
        let outbound = progress.split(at: vehicle, from: 0, to: 1, progress: 0.5, within: 0...2)
        let inbound = progress.split(at: vehicle, from: 1, to: 2, progress: 0.5, within: 0...2)
        XCTAssertEqual(outbound.before.count, 2)
        XCTAssertEqual(inbound.before.count, 3)
        XCTAssertEqual(outbound.after.first, vehicle)
        XCTAssertEqual(inbound.after.first, vehicle)
    }

    func testOffscreenVehicleCannotPutASeamAtTheViewportEdge() {
        let path = (0...10).map { Coord(lon: 7 + Double($0) * 0.01, lat: 46) }
        let progress = RouteProgress(path: path)
        let ahead = progress.split(at: path[2], from: 0, to: 10, progress: 0.2, within: 6...9)
        XCTAssertTrue(ahead.before.isEmpty)
        XCTAssertEqual(ahead.after, Array(path[6...9]))
        let behind = progress.split(at: path[8], from: 0, to: 10, progress: 0.8, within: 1...4)
        XCTAssertTrue(behind.after.isEmpty)
        XCTAssertEqual(behind.before, Array(path[1...4]))
    }

    func testSimplificationPreservesTheMarkerAsTheSharedVertex() {
        let path = [Coord(lon: 7, lat: 46), Coord(lon: 7.05, lat: 46.001), Coord(lon: 7.1, lat: 46)]
        let marker = Coord(lon: 7.05, lat: 46.0011)
        let split = RouteProgress(path: path).split(at: marker, from: 0, to: 2, progress: 0.5, within: 0...2)
        XCTAssertEqual(Geo.simplify(split.before, toleranceMetres: 500).last, marker)
        XCTAssertEqual(Geo.simplify(split.after, toleranceMetres: 500).first, marker)
    }
    private func northing(_ latitude: Double) -> Double {
        log(tan(.pi / 4 + latitude * .pi / 360))
    }

    func testNorthboundRouteDoesNotPutDottedCutoffAheadOfTrain() {
        // Ground metres put this northbound train halfway along the route,
        // but Mercator scales the northern half more. The old 0.5 cutoff
        // therefore painted travelled dots into track the train had not reached.
        let path = [46.0, 46.5, 47.0].map { Coord(lon: 7.5, lat: $0) }
        let progress = RouteProgress(path: path)
        let expected = (northing(46.5) - northing(46)) / (northing(47) - northing(46))
        let fraction = progress.fraction(from: 0, to: 2, progress: 0.5)
        XCTAssertEqual(fraction, expected, accuracy: 1e-10)
        XCTAssertLessThan(fraction, 0.499)
    }

    func testProgressWithinALegUsesTheTrainPointRatherThanProjectedLegFraction() {
        let path = [46.0, 46.5, 47.0].map { Coord(lon: 7.5, lat: $0) }
        let progress = RouteProgress(path: path)
        let expected = (northing(46.75) - northing(46)) / (northing(47) - northing(46))
        XCTAssertEqual(progress.fraction(from: 1, to: 2, progress: 0.5), expected, accuracy: 1e-10)
    }

    func testReversalsChooseTheCurrentLegAndProgressStaysContinuousAtStops() {
        let a = Coord(lon: 7.5, lat: 46), b = Coord(lon: 7.5, lat: 47)
        let progress = RouteProgress(path: [a, b, a])
        let outward = progress.fraction(from: 0, to: 1, progress: 0.5)
        let homeward = progress.fraction(from: 1, to: 2, progress: 0.5)
        XCTAssertLessThan(outward, 0.5)
        XCTAssertGreaterThan(homeward, 0.5)
        XCTAssertEqual(outward + homeward, 1, accuracy: 1e-10)
        XCTAssertEqual(progress.fraction(from: 0, to: 1, progress: 1),
                       progress.fraction(from: 1, to: 2, progress: 0))
        XCTAssertEqual(progress.fraction(from: 2, to: 2, progress: 0), 1)
    }

    func testDiagonalSegmentMatchesPositioningsLinearCoordinateInterpolation() {
        let path = [Coord(lon: 7, lat: 46), Coord(lon: 9, lat: 47)]
        let progress = RouteProgress(path: path)
        let dx = 2 * Double.pi / 180
        let dy = northing(47) - northing(46)
        // At half the leg, Positioning uses (8, 46.5), not the great-circle
        // midpoint. Its projection along the rendered segment is the cutoff.
        let x = Double.pi / 180
        let y = northing(46.5) - northing(46)
        let expected = (x * dx + y * dy) / (dx * dx + dy * dy)
        XCTAssertEqual(progress.fraction(from: 0, to: 1, progress: 0.5), expected, accuracy: 1e-10)
    }

    func testNearestFractionPinsTheSeamToTheVehicleOnASlicedPath() {
        let path = (0...10).map { Coord(lon: 7.5, lat: 46.0 + Double($0) * 0.01) }
        let full = RouteProgress(path: path)
        let slice = Array(path[3...7])
        let window = RouteProgress(path: slice)
        let vehicle = path[5]
        let fullFraction = full.fraction(from: 0, to: 10, progress: 0.5)
        XCTAssertEqual(full.fraction(nearestTo: vehicle), fullFraction, accuracy: 1e-6)
        XCTAssertEqual(window.fraction(nearestTo: vehicle), 0.5, accuracy: 1e-4)
    }

    func testSplitMeetsAtTheVehicle() {
        let path = (0...4).map { Coord(lon: 7.5, lat: 46.0 + Double($0) * 0.01) }
        let progress = RouteProgress(path: path)
        let vehicle = Coord(lon: 7.5, lat: 46.025)
        let parts = progress.split(at: vehicle)
        XCTAssertGreaterThanOrEqual(parts.before.count, 2)
        XCTAssertGreaterThanOrEqual(parts.after.count, 2)
        let seam = parts.before.last!
        XCTAssertEqual(seam.lat, vehicle.lat, accuracy: 1e-8)
        XCTAssertEqual(parts.after.first!.lat, vehicle.lat, accuracy: 1e-8)
        XCTAssertLessThan(parts.before[0].lat, vehicle.lat)
        XCTAssertGreaterThan(parts.after.last!.lat, vehicle.lat)
    }

    func testNearestFractionOnASingleLongSegmentDoesNotSnapToTheEnd() {
        // A straight S-Bahn after Douglas–Peucker is often two vertices. Ground
        // metres for the midpoint are ~55 km; the Mercator span is ~0.02. The
        // old `min(span, alongMetres)` therefore always returned `span`, and
        // the whole visible path was painted as already travelled.
        let path = [Coord(lon: 7.5, lat: 46.0), Coord(lon: 7.5, lat: 47.0)]
        let progress = RouteProgress(path: path)
        let mid = Coord(lon: 7.5, lat: 46.5)
        let expected = (northing(46.5) - northing(46)) / (northing(47) - northing(46))
        XCTAssertEqual(progress.fraction(nearestTo: mid), expected, accuracy: 1e-10)
        XCTAssertLessThan(progress.fraction(nearestTo: mid), 0.499)
        XCTAssertGreaterThan(progress.fraction(nearestTo: mid), 0.4)
    }

    func testNearestFractionInsideALongStraightStaysOnTheTrain() {
        let path = (0...4).map { Coord(lon: 7.5, lat: 46.0 + Double($0) * 0.01) }
        let progress = RouteProgress(path: path)
        let vehicle = Coord(lon: 7.5, lat: 46.025)
        let expected = (northing(46.025) - northing(46)) / (northing(46.04) - northing(46))
        XCTAssertEqual(progress.fraction(nearestTo: vehicle), expected, accuracy: 1e-8)
    }

    func testWindowAroundASeedDropsTheOffscreenTail() {
        let path = (0...100).map { Coord(lon: 7.5, lat: 46.0 + Double($0) * 0.01) }
        let box = BBox(west: 7.4, south: 46.45, east: 7.6, north: 46.55)
        let window = Geo.window(path, around: 50, inside: box)
        XCTAssertEqual(window?.lo, 44)
        XCTAssertEqual(window?.hi, 56)
        XCTAssertLessThan((window?.hi ?? 0) - (window?.lo ?? 0), 20)
        XCTAssertTrue(box.contains(lon: path[50].lon, lat: path[50].lat))
    }

    func testDegenerateRoutesAndClampedProgressRemainFinite() {
        let a = Coord(lon: 7.5, lat: 46), b = Coord(lon: 7.5, lat: 47)
        XCTAssertEqual(RouteProgress(path: []).fraction(from: 0, to: 1, progress: 0.5), 0)
        XCTAssertEqual(RouteProgress(path: [a, a]).fraction(from: 0, to: 1, progress: 0.5), 0)
        let progress = RouteProgress(path: [a, a, b])
        XCTAssertEqual(progress.fraction(from: 0, to: 2, progress: -1), 0)
        XCTAssertEqual(progress.fraction(from: 0, to: 2, progress: 2), 1)
        XCTAssertTrue(progress.fraction(from: 0, to: 2, progress: 0.5).isFinite)
        XCTAssertEqual(progress.fraction(from: -1, to: 2, progress: 0.5), 0)
        XCTAssertEqual(progress.fraction(from: 0, to: 2, progress: .nan), 0)
    }

    func testVisibleWindowFollowsTheMapInsteadOfAnOffscreenTrain() throws {
        let path = (0...100).map { Coord(lon: 7.5, lat: 46 + Double($0) * 0.01) }
        let box = BBox(west: 7.4, south: 46.7, east: 7.6, north: 46.8)
        let window = try XCTUnwrap(Geo.visibleWindow(path, inside: box))
        XCTAssertLessThanOrEqual(window.lo, 70)
        XCTAssertGreaterThanOrEqual(window.hi, 80)
        XCTAssertLessThan(window.hi - window.lo, 15)
        XCTAssertNil(Geo.visibleWindow(path, inside: BBox(west: 8, south: 46, east: 9, north: 47)))
    }

    func testVisibleWindowKeepsCrossingsAndEveryReentry() throws {
        let box = BBox(west: 7, south: 46, east: 8, north: 47)
        let path = [Coord(lon: 6, lat: 46.2), Coord(lon: 9, lat: 46.2),
                    Coord(lon: 9, lat: 46.8), Coord(lon: 6, lat: 46.8)]
        let window = try XCTUnwrap(Geo.visibleWindow(path, inside: box))
        XCTAssertEqual(window.lo, 0)
        XCTAssertEqual(window.hi, 3)
        XCTAssertEqual(Geo.clipped(Array(path[window.lo...window.hi]), to: box).count, 2)
        XCTAssertNil(Geo.visibleWindow([], inside: box))
        XCTAssertNil(Geo.visibleWindow([path[0]], inside: box))
    }
}
