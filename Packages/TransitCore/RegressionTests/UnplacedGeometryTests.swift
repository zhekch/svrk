import XCTest
@testable import TransitCore

final class UnplacedGeometryTests: XCTestCase {
    func testAChordToNullIslandIsNotAPlausibleRoute() {
        let interlaken = Coord(lon: 7.869, lat: 46.690)
        let sea = Coord(lon: 0, lat: 0)
        XCTAssertFalse(sea.isPlaced)
        XCTAssertTrue(Geo.hasUnplaced([interlaken, sea]))
        XCTAssertTrue(Geo.hasJump([interlaken, sea]))
        XCTAssertFalse(Geo.plausibleRoute([interlaken, sea], from: interlaken, to: sea))
        XCTAssertEqual(Geo.withoutUnplaced([interlaken, sea, Coord(lon: 7.68, lat: 46.69)]),
                       [interlaken, Coord(lon: 7.68, lat: 46.69)])
    }

    func testGeometryBuilderDoesNotDrawThroughAfrica() throws {
        let now = 1_700_000_000
        let journey = Journey(
            id: "ic61", mode: .train, category: "IC", line: "IC 61", number: "61",
            operatorName: "SBB", operatorFull: "SBB", to: "Spiez", from: "Interlaken Ost",
            delay: nil, start: now, end: now + 900, complete: true, monitored: false,
            cancelled: false, source: "ojp",
            stops: [
                Call(key: "ilo", name: "Interlaken Ost", lat: 46.6904, lon: 7.8690,
                     precise: true, arr: now, dep: now),
                Call(key: "ghost", ref: "missing", name: "Empty Formation", lat: 0, lon: 0,
                     arr: now + 450, dep: now + 450, extra: true),
                Call(key: "spiez", name: "Spiez", lat: 46.6864, lon: 7.6801,
                     precise: true, arr: now + 900, dep: now + 900),
            ]
        )
        GeometryBuilder(relations: RelationStore(), railnet: RailNet()).attach(to: journey)
        let path = try XCTUnwrap(journey.geometry?.path)
        XCTAssertGreaterThan(path.count, 1)
        XCTAssertFalse(Geo.hasUnplaced(path), "path vertices: \(path)")
        XCTAssertGreaterThan(path.map(\.lat).min() ?? 0, 40)
        XCTAssertLessThan(path.map(\.lat).max() ?? 90, 55)
        XCTAssertGreaterThan(path.map(\.lon).min() ?? 0, 5)
        XCTAssertLessThan(path.map(\.lon).max() ?? 90, 12)

        let moving = try XCTUnwrap(Positioning.position(of: journey, at: now + 450))
        XCTAssertGreaterThan(moving.lat, 40)
        XCTAssertLessThan(moving.speed, 400)
    }

    func testParseDropsANullIslandVertex() throws {
        let json = """
        {
          "elements": [
            {"type":"relation","id":61,"tags":{"type":"route","route":"train","ref":"IC 61"},
             "members":[
               {"type":"way","ref":10,"role":"","geometry":[
                 {"lat":46.690,"lon":7.869},
                 {"lat":0.0,"lon":0.0},
                 {"lat":46.686,"lon":7.680}
               ]}
             ]}
          ]
        }
        """.data(using: .utf8)!
        let routes = try OSMRouteParser.parse(json)
        XCTAssertEqual(routes.count, 1)
        XCTAssertFalse(Geo.hasUnplaced(routes[0].path))
        XCTAssertEqual(routes[0].path.count, 2)
    }

    func testBBoxIgnoresUnplacedStops() throws {
        let now = 1_700_000_000
        let stops = [
            Call(key: "ilo", name: "Interlaken Ost", lat: 46.690, lon: 7.869, arr: now, dep: now),
            Call(key: "ghost", name: "Nowhere", lat: 0, lon: 0, arr: now, dep: now),
            Call(key: "basel", name: "Basel SBB", lat: 47.547, lon: 7.589, arr: now, dep: now),
        ]
        let box = try XCTUnwrap(OSMRouteClient.bbox(of: stops, pad: 0))
        XCTAssertGreaterThan(box.south, 40)
        XCTAssertGreaterThan(box.west, 5)
        XCTAssertEqual(OSMRouteClient.sampleStops(stops).map(\.name),
                       ["Interlaken Ost", "Basel SBB"])
    }

    func testPackedIC61StaysInEuropeAfterUnplacedExtras() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let routes = root.appendingPathComponent("SwissTransit/Resources/Data/routes.bin")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: routes.path))
        let store = RelationStore()
        try store.load(routes)
        let now = 1_700_000_000
        let journey = Journey(
            id: "ic61", mode: .train, category: "IC", line: "IC 61", number: "61",
            operatorName: "SBB", operatorFull: "SBB", to: "Basel SBB", from: "Interlaken Ost",
            delay: nil, start: now, end: now + 7200, complete: true, monitored: false,
            cancelled: false, source: "ojp",
            stops: [
                Call(key: "ilo", name: "Interlaken Ost", lat: 46.6904, lon: 7.8690,
                     precise: true, arr: now, dep: now),
                Call(key: "spiez", name: "Spiez", lat: 46.6864, lon: 7.6801,
                     precise: true, arr: now + 900, dep: now + 960),
                Call(key: "thun", name: "Thun", lat: 46.7549, lon: 7.6296,
                     precise: true, arr: now + 1500, dep: now + 1560),
                Call(key: "bern", name: "Bern", lat: 46.9488, lon: 7.4391,
                     precise: true, arr: now + 2400, dep: now + 2520),
                Call(key: "olten", name: "Olten", lat: 47.3519, lon: 7.9076,
                     precise: true, arr: now + 4200, dep: now + 4260),
                Call(key: "basel", name: "Basel SBB", lat: 47.5474, lon: 7.5896,
                     precise: true, arr: now + 7200, dep: now + 7200),
            ]
        )
        let extras = [
            Call(key: "ghost-head", ref: "missing:1", name: "Unknown Origin",
                 lat: 0, lon: 0, arr: now - 600, dep: now - 600),
            Call(key: "ilo", name: "Interlaken Ost", lat: 46.6904, lon: 7.8690,
                 arr: now, dep: now),
            Call(key: "ghost-mid", ref: "missing:2", name: "Empty Formation",
                 lat: 0, lon: 0, arr: now + 400, dep: now + 400, extra: true),
            Call(key: "basel", name: "Basel SBB", lat: 47.5474, lon: 7.5896,
                 arr: now + 7200, dep: now + 7200),
        ]
        _ = journey.absorb(extras: extras, resolve: { _, _ in nil })
        XCTAssertTrue(journey.stops.allSatisfy(\.isPlaced))
        GeometryBuilder(relations: store, railnet: RailNet()).attach(to: journey)
        let path = try XCTUnwrap(journey.geometry?.path)
        XCTAssertGreaterThan(path.count, 2)
        XCTAssertFalse(Geo.hasUnplaced(path))
        XCTAssertGreaterThan(path.map(\.lat).min() ?? 0, 45)
        XCTAssertLessThan(path.map(\.lat).max() ?? 90, 49)
        XCTAssertGreaterThan(path.map(\.lon).min() ?? 0, 6)
        XCTAssertLessThan(path.map(\.lon).max() ?? 90, 9)
        let moving = try XCTUnwrap(Positioning.position(of: journey, at: now + 300))
        XCTAssertLessThan(moving.speed, 400)
        XCTAssertGreaterThan(moving.lat, 45)
    }
}
