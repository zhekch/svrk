import XCTest
@testable import TransitCore

final class VehicleRenderingTests: XCTestCase {
    func testModelPlacementsRemainRigidAcrossDrawingScales() throws {
        let subject = VehicleSnapshot(
            id: "ch:1:sjyid:100001:711-001", mode: .train, category: "IC", line: "IC6",
            operatorName: "SBB", from: "Bern", lon: 7.44, lat: 46.948,
            bearing: 90, moving: true, index: 0, progress: 0,
            stops: [], geometry: nil, onTrack: false
        )
        let layout = VehicleLayoutStore().layout(for: subject, modeColour: "#ff3b30")
        let reference = try XCTUnwrap(VehicleShape.footprint(
            of: subject, layout: layout, metresPerPoint: 0.25,
            solid: true, extruded: false, emerged: 1
        ))
        XCTAssertFalse(reference.placements.isEmpty)
        for metres in [0.1, 0.5, 1.0, 2.0, 4.0] {
            let drawing = try XCTUnwrap(VehicleShape.footprint(
                of: subject, layout: layout, metresPerPoint: metres,
                solid: true, extruded: false, emerged: 1
            ))
            XCTAssertEqual(drawing.placements.count, reference.placements.count)
            for (actual, expected) in zip(drawing.placements, reference.placements) {
                XCTAssertEqual(actual.model, expected.model)
                XCTAssertEqual(actual.at, expected.at)
                XCTAssertEqual(actual.heading, expected.heading)
                XCTAssertEqual(actual.length, expected.length)
                XCTAssertEqual(actual.widthScale, expected.widthScale)
                XCTAssertEqual(actual.heightScale, expected.heightScale)
            }
        }
    }

}
