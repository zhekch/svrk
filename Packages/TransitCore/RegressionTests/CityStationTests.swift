import XCTest
@testable import TransitCore

final class CityStationTests: XCTestCase {
    private let thun = Coord(lon: 7.63, lat: 46.758)

    private func place(_ name: String, rail: Bool = true, lon: Double = 7.63) -> StopPlace {
        StopPlace(id: name, name: name, lon: lon, lat: 46.758, rail: rail, kerbs: 0)
    }

    func testOnlyEnabledAtZoomTenAndFurtherOut() {
        XCTAssertTrue(CityStation.isEnabled(at: 9))
        XCTAssertTrue(CityStation.isEnabled(at: 10))
        XCTAssertFalse(CityStation.isEnabled(at: 10.001))
        XCTAssertFalse(CityStation.isEnabled(at: 11.5))
        XCTAssertFalse(CityStation.isEnabled(at: .nan))
    }

    func testCityNameSelectsRailwayInsteadOfBusOrDistrictStation() {
        let station = place("Thun")
        let found = CityStation.resolve(named: "Thun", near: thun, among: [
            place("Thun, Bahnhof", rail: false), place("Thun Nord"), station,
            place("Thun", rail: false)
        ])
        XCTAssertEqual(found, station)
    }

    func testMainStationSuffixAndFoldedBilingualNames() {
        let hb = place("Zürich HB")
        XCTAssertEqual(CityStation.resolve(named: "Zurich", near: thun,
            among: [place("Zürich Oerlikon"), hb]), hb)
        let biel = place("Biel/Bienne")
        XCTAssertEqual(CityStation.resolve(named: "Bienne", near: thun, among: [biel]), biel)
        let basel = place("Basel SBB")
        XCTAssertEqual(CityStation.resolve(named: "Basel", near: thun,
            among: [place("Basel Bad Bf"), basel]), basel)
    }

    func testNoUnrelatedOrDistantStationFallback() {
        XCTAssertNil(CityStation.resolve(named: "Hilterfingen", near: thun,
            among: [place("Thun"), place("Hilterfingen", rail: false)]))
        XCTAssertNil(CityStation.resolve(named: "Thun", near: thun,
            among: [place("Thun", lon: 8.5), place("Thun Nord")]))
        XCTAssertNil(CityStation.resolve(named: "", near: thun, among: [place("Thun")]))
    }

    func testScreenshotTownsResolveAgainstBundledStationRegister() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = StopPlaceStore()
        try store.load(root.appendingPathComponent("SwissTransit/Resources/Data/stop-places.bin"))
        let timetable = try TimetableStore(url: root.appendingPathComponent("SwissTransit/Resources/Data/timetable.bin"))
        XCTAssertTrue(timetable.isRailwayStation("8508253"), "Heimberg needs timetable evidence")
        for (name, centre) in [
            ("Heimberg", Coord(lon: 7.605, lat: 46.793)),
            ("Thun", thun),
            ("Spiez", Coord(lon: 7.680, lat: 46.687)),
            ("Wimmis", Coord(lon: 7.639, lat: 46.675))
        ] {
            let nearby = store.nearby(lon: centre.lon, lat: centre.lat,
                within: CityStation.searchRadius, limit: .max)
            let station = try XCTUnwrap(CityStation.resolve(named: name, near: centre, among: nearby,
                isRailway: { $0.rail || timetable.isRailwayStation($0.id) }), name)
            XCTAssertEqual(station.name, name)
            XCTAssertTrue(station.rail || timetable.isRailwayStation(station.id))
        }
    }
}
