import XCTest
@testable import TransitCore

final class VehicleTapTests: XCTestCase {
    private let coach: [VehicleTap.Point] = [.init(20, 20), .init(220, 20), .init(220, 28), .init(20, 28)]

    func testWholeCoachIsSelectableIncludingTailAndSides() {
        for point in [VehicleTap.Point(21, 24), .init(219, 24), .init(100, 20), .init(100, 27)] {
            XCTAssertEqual(VehicleTap.distance(from: point, to: coach), 0, accuracy: 0.001)
        }
        XCTAssertEqual(VehicleTap.distance(from: .init(100, 35), to: coach), 7, accuracy: 0.001)
    }

    func testDirectCoachHitBeatsAdjacentTrainHitPadding() {
        let hits = [VehicleTap.Hit(id: "RE1", distance: 0), .init(id: "R11", distance: 2)]
        XCTAssertEqual(VehicleTap.candidates(hits).map(\.id), ["RE1"])
    }

    func testCloseMissKeepsConstantScreenTargetAndRejectsFarVehicles() {
        XCTAssertEqual(VehicleTap.candidates([.init(id: "tram9", distance: 13)]).count, 1)
        XCTAssertTrue(VehicleTap.candidates([.init(id: "tram9", distance: 15)]).isEmpty)
        XCTAssertEqual(VehicleTap.candidates([.init(id: "near", distance: 2), .init(id: "far", distance: 12)]).map(\.id), ["near"])
    }

    func testAmbiguousVehiclesOnlyAndStableOrdering() {
        let hits = [VehicleTap.Hit(id: "b", distance: 0), .init(id: "a", distance: 0), .init(id: "a", distance: 4)]
        XCTAssertEqual(VehicleTap.candidates(hits).map(\.id), ["a", "b"])
        XCTAssertEqual(VehicleTap.candidates(hits.reversed()), VehicleTap.candidates(hits))
        XCTAssertEqual(VehicleTap.candidates([.init(id: "a", distance: 5), .init(id: "b", distance: 7)]).count, 2)
    }

    func testProjectedCurveAndInvalidGeometryDoNotUseHeadOrBoundingBox() {
        let diagonal: [VehicleTap.Point] = [.init(0, 0), .init(100, 100), .init(104, 96), .init(4, -4)]
        XCTAssertEqual(VehicleTap.distance(from: .init(52, 48), to: diagonal), 0, accuracy: 0.001)
        XCTAssertGreaterThan(VehicleTap.distance(from: .init(0, 100), to: diagonal), VehicleTap.reach)
        XCTAssertEqual(VehicleTap.distance(from: .init(0, 0), to: []), .infinity)
        XCTAssertTrue(VehicleTap.candidates([.init(id: "bad", distance: .nan)]).isEmpty)
    }

    func testCentrelineHitIsThePerpendicularToTheRakeNotTheHead() {
        let line: [VehicleTap.Point] = [.init(0, 0), .init(200, 0)]
        XCTAssertEqual(VehicleTap.distance(from: .init(150, 0), toLine: line), 0, accuracy: 0.001)
        XCTAssertEqual(VehicleTap.distance(from: .init(150, 8), toLine: line), 8, accuracy: 0.001)
        XCTAssertEqual(VehicleTap.distance(from: .init(0, 0), toLine: []), .infinity)
    }
}
