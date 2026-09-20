import XCTest
@testable import TransitCore

final class StationOfferTests: XCTestCase {
    private let spiez = Coord(lon: 7.680102, lat: 46.686394)

    private func trail(_ offsets: [Double], speed: Double?, accuracy: Double) -> [RideFix] {
        offsets.enumerated().map { index, metres in
            RideFix(
                coord: Geo.moved(spiez, bearing: 135, metres: metres),
                at: 1_000 + Double(index), speed: speed, accuracy: accuracy
            )
        }
    }

    func testStationaryGPSJitterDoesNotCountAsWalking() {
        // Both endpoint readings fit a stationary phone's 10 m accuracy,
        // but their raw separation implies over 2 m/s.
        XCTAssertTrue(RideMatching.isStill(trail(
            [-8, 3, -2, 4, -3, 2, 8], speed: 0.1, accuracy: 10
        )))
    }

    func testJitterIsMeasuredAroundTheClusterRatherThanItsLastOutlier() {
        XCTAssertTrue(RideMatching.isStill(trail(
            [0, -12, 10, -10, 8, -5, 12], speed: 0.1, accuracy: 15
        )))
    }

    func testStationIdentificationAllowsLessPreciseGPSWithoutChoosingAPlatform() {
        XCTAssertTrue(RideMatching.isStill(trail(
            [0, -12, 10, -10, 8, -5, 12], speed: 0.1, accuracy: 50
        )))
    }

    func testWalkingAndTravelStillRejectAStationaryOffer() {
        XCTAssertFalse(RideMatching.isStill(trail(
            (0..<9).map { Double($0) * 1.8 }, speed: 1.8, accuracy: 10
        )))
        XCTAssertFalse(RideMatching.isStill(trail(
            (0..<9).map { Double($0) * 2 }, speed: nil, accuracy: 1
        )))
        XCTAssertFalse(RideMatching.isStill(trail(
            (0..<9).map { Double($0) * 15 }, speed: 15, accuracy: 10
        )))
    }

    func testInsufficientAndPoorFixesCannotOfferAStation() {
        XCTAssertFalse(RideMatching.isStill(trail([0], speed: 0, accuracy: 5)))
        XCTAssertFalse(RideMatching.isStill(trail([0, 1], speed: 0, accuracy: 5)))
        XCTAssertFalse(RideMatching.isStill(trail(
            [0, 1, 0, 1, 0, 1, 0], speed: 0, accuracy: 80
        )))
    }

    private func fleetWithStops() async throws -> Fleet {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: data.appendingPathComponent("stops.bin").path
        ), "Bundled stop data is required for the Spiez regression")
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        try await fleet.register.load(stopsFile: data.appendingPathComponent("stops.bin"), foreignFile: nil)
        try await fleet.stopPlaces.load(data.appendingPathComponent("stop-places.bin"))
        return fleet
    }

    func testSpiezPlatformOffersTheStationAwayFromItsRegisterPoint() async throws {
        let fleet = try await fleetWithStops()
        // On the southeastern platforms, beyond the single points used by
        // the stop register. Accuracy must not dictate platform length.
        let platform = Geo.moved(spiez, bearing: 135, metres: 80)
        for accuracy in [5.0, 50.0] {
            let found = await fleet.nearbyBoard(
                lon: platform.lon, lat: platform.lat, accuracy: accuracy, at: 1_788_349_200
            )
            guard case let .station(board) = found else {
                return XCTFail("Expected the whole Spiez station, got \(String(describing: found))")
            }
            XCTAssertEqual(board.id, "8507483")
            XCTAssertEqual(board.name, "Spiez")
        }
    }

    func testBeingDownTheStreetDoesNotOfferSpiez() async throws {
        let fleet = try await fleetWithStops()
        let street = Geo.moved(spiez, bearing: 225, metres: 250)
        let found = await fleet.nearbyBoard(
            lon: street.lon, lat: street.lat, accuracy: 5, at: 1_788_349_200
        )
        XCTAssertNil(found)
    }
}
