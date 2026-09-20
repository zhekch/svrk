import XCTest
@testable import TransitCore

final class FormationDisplayBoundsTests: XCTestCase {
    func testUnlabelledPlatformEndsDoNotAddScrollableSpace() {
        let bounds = FormationDisplayBounds(
            platformWidth: 1200, trainStart: 400, trainWidth: 180,
            sectorStart: 200, sectorWidth: 600
        )
        XCTAssertEqual(bounds.lower, 200)
        XCTAssertEqual(bounds.upper, 800)
        XCTAssertEqual(bounds.width, 600)
        XCTAssertEqual(bounds.position(of: 400), 200, "Train and sectors share the cropped origin")
    }

    func testAccessPointsStayAlignedWithoutInventingEndMarkers() {
        let bounds = FormationDisplayBounds(
            platformWidth: 1200, trainStart: 400, trainWidth: 180,
            sectorStart: 200, sectorWidth: 600
        )
        XCTAssertNil(bounds.position(of: 100))
        XCTAssertEqual(bounds.position(of: 200), 0)
        XCTAssertEqual(bounds.position(of: 500), 300)
        XCTAssertEqual(bounds.position(of: 800), 600)
        XCTAssertNil(bounds.position(of: 900))
    }

    func testNoSectorDataKeepsTheFullPlatform() {
        let bounds = FormationDisplayBounds(
            platformWidth: 1200, trainStart: 400, trainWidth: 180,
            sectorStart: 400, sectorWidth: 0
        )
        XCTAssertEqual(bounds.lower, 0)
        XCTAssertEqual(bounds.width, 1200)
        XCTAssertEqual(bounds.position(of: 400), 400)
    }

    func testIncompleteSectorDataNeverClipsTheTrain() {
        let bounds = FormationDisplayBounds(
            platformWidth: 1200, trainStart: 100, trainWidth: 800,
            sectorStart: 200, sectorWidth: 600
        )
        XCTAssertEqual(bounds.lower, 100)
        XCTAssertEqual(bounds.upper, 900)
    }

    func testLeadingEmptySectorsStayBeforeTrainNearMappedPlatformStart() {
        // Frutigen-like formation: empty H/G before eight coaches in F–B.
        // The mapped nose is only 40 pt from the platform start, but H/G
        // account for 300 pt of schematic padding, so sectors start at -260.
        let trainStart = 40.0
        let leadingPadding = 300.0
        let sectorStart = trainStart - leadingPadding
        let bounds = FormationDisplayBounds(
            platformWidth: 1500, trainStart: trainStart, trainWidth: 800,
            sectorStart: sectorStart, sectorWidth: 1300
        )

        XCTAssertEqual(bounds.lower, -260)
        XCTAssertEqual(bounds.width, 1300, "No extra blank platform tail")
        XCTAssertEqual(bounds.position(of: sectorStart), 0)
        XCTAssertEqual(bounds.position(of: trainStart), 300)
        XCTAssertEqual(bounds.position(of: sectorStart + leadingPadding),
                       bounds.position(of: trainStart), "First blue sector starts with the train")
        XCTAssertEqual(bounds.position(of: sectorStart + leadingPadding + 800),
                       bounds.position(of: trainStart + 800), "Last occupied sector ends with the train")
    }

    func testTrainAtZeroStillLeavesRoomForLeadingSectors() {
        let bounds = FormationDisplayBounds(
            platformWidth: 1000, trainStart: 0, trainWidth: 600,
            sectorStart: -200, sectorWidth: 900
        )
        XCTAssertEqual(bounds.lower, -200)
        XCTAssertEqual(bounds.position(of: 0), 200)
        XCTAssertEqual(bounds.position(of: 600), 800)
        XCTAssertEqual(bounds.width, 900)
    }

    func testAccessPointsUseSameTranslationAsTrainAndSectors() {
        let bounds = FormationDisplayBounds(
            platformWidth: 1500, trainStart: 40, trainWidth: 800,
            sectorStart: -260, sectorWidth: 1300
        )
        XCTAssertEqual(bounds.position(of: 0), 260, "Mapped start keeps its true position")
        XCTAssertEqual(bounds.position(of: 140), 400, "Stairs remain 100 pt behind the train nose")
        XCTAssertEqual(bounds.position(of: 1040), 1300)
        XCTAssertNil(bounds.position(of: 1041), "Do not invent an access marker at the cropped end")
    }
}
