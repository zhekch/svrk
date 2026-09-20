import XCTest
@testable import TransitCore

final class SituationMatchingTests: XCTestCase {
    private let bern = "ch:1:sloid:7000"
    private let murten = "ch:1:sloid:4400"
    private let bls = "ch:1:sboid:100015"

    private func service(_ notices: [Situation]) async throws -> SituationService {
        struct Held: Encodable {
            var unplanned: [Situation]
            var planned: [Situation]
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("situation-matching-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = Held(unplanned: notices.filter { !$0.planned }, planned: notices.filter(\.planned))
        try JSONEncoder().encode(held).write(to: directory.appendingPathComponent("situations.json"))
        let service = SituationService()
        await service.setIncludesPlanned(true)
        await service.nameOperators { ref in
            switch ref {
            case "ch:1:sboid:100015": return "BLS"
            case "ch:1:sboid:100001": return "SBB"
            default: return nil
            }
        }
        await service.keepAnswers(in: directory)
        return service
    }

    func testMurtenWorksDoNotMatchRE1ThroughBern() async throws {
        // Scope from the notice shown on 5 September 2026. Bern appears in
        // the affected stops, but the notice explicitly names only S5/S52.
        let notice = Situation(
            id: "murten-kerzers", planned: true,
            windows: [.init(from: 1788555600, until: 1788748800)],
            summary: "Interrupted service Murten/Morat - Kerzers",
            lines: ["S5", "S52"],
            stopPlaces: ["ch:1:sloid:4128", murten, "ch:1:sloid:4140",
                         "ch:1:sloid:4129", "ch:1:sloid:4486", "ch:1:sloid:4487",
                         "ch:1:sloid:16154", "ch:1:sloid:4489", bern, "ch:1:sloid:4488"],
            operators: [bls]
        )
        let service = try await service([notice])
        let moment = try XCTUnwrap(OJPTimings.time("2026-09-05T12:29:00Z"))
        let re1 = await service.forVehicle(id: "re1", line: "RE1", operatorName: "BLS",
                                           stopRefs: [bern], at: moment)
        XCTAssertTrue(re1.isEmpty)
        for line in ["S5", "S52"] {
            let affected = await service.forVehicle(id: line, line: line, operatorName: "BLS",
                                                    stopRefs: [bern, murten], at: moment)
            XCTAssertEqual(affected.map(\.id), [notice.id])
        }
        let board = await service.forStop(ref: bern, at: moment)
        XCTAssertEqual(board.map(\.id), [notice.id])
    }

    func testMatchingLineCannotOverrideUnrelatedStops() async throws {
        let service = try await service([Situation(id: "local", planned: true,
            lines: ["S5"], stopPlaces: [murten], operators: [bls])])
        let found = await service.forVehicle(id: "s5", line: "S5", operatorName: "BLS",
                                             stopRefs: [bern], at: 1000)
        XCTAssertTrue(found.isEmpty)
    }

    func testStopNoticeWithoutLineRestrictionsAppliesToAnyCallingService() async throws {
        let service = try await service([Situation(id: "closed", planned: false, stopPlaces: [bern])])
        let found = await service.forVehicle(id: "bus", line: "12", operatorName: nil,
                                             stopRefs: [bern + ":1:21"], at: 1000)
        XCTAssertEqual(found.map(\.id), ["closed"])
    }

    func testLineOnlyNoticeRequiresTheRightOperator() async throws {
        let service = try await service([Situation(id: "line", planned: false,
            lines: ["S5"], operators: [bls])])
        for name in ["BLS", "SBB", nil] as [String?] {
            let found = await service.forVehicle(id: "train", line: "S5", operatorName: name,
                                                 stopRefs: [bern], at: 1000)
            XCTAssertEqual(found.map(\.id), name == "BLS" ? ["line"] : [])
        }
    }

    func testSharedStopAndLineCannotOverrideExplicitJourneys() async throws {
        let service = try await service([Situation(id: "specific-run", planned: true,
            lines: ["RE1"], stopPlaces: [bern], journeys: ["ch:1:sjyid:bls:123"], operators: [bls])])
        let found = await service.forVehicle(id: "tt:999", line: "RE1", operatorName: "BLS",
                                             stopRefs: [bern], at: 1000)
        XCTAssertTrue(found.isEmpty)
    }

    func testPublishedJourneyReferencesMatchTimetableRowsAndJoinedParts() async throws {
        let ref = "ch:1:sjyid:bls:123"
        let service = try await service([Situation(id: "specific-run", planned: true,
                                                   journeys: [ref])])
        let timetable = await service.forVehicle(id: "tt:999", line: "RE1", operatorName: "BLS",
                                                  stopRefs: [], journeyRefs: [ref], at: 1000)
        XCTAssertEqual(timetable.map(\.id), ["specific-run"])
        let livePart = await service.forVehicle(id: "other", parts: [ref], line: "RE1",
                                                operatorName: "BLS", stopRefs: [], at: 1000)
        XCTAssertEqual(livePart.map(\.id), ["specific-run"])
    }

    func testExpiredNoticeIsStillExcluded() async throws {
        let service = try await service([Situation(id: "expired", planned: true,
            windows: [.init(from: 100, until: 200)], lines: ["S5"], operators: [bls])])
        let found = await service.forVehicle(id: "s5", line: "S5", operatorName: "BLS",
                                             stopRefs: [], at: 1000)
        XCTAssertTrue(found.isEmpty)
    }

    func testStoredWorksCatalogueIsNotTreatedAsDueOnTheNextLaunch() async throws {
        struct Held: Encodable {
            var unplanned: [Situation]
            var planned: [Situation]
            var plannedAt: Date
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("situation-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = Held(
            unplanned: [],
            planned: [Situation(id: "works", planned: true, lines: ["S5"], operators: [bls])],
            plannedAt: Date()
        )
        try JSONEncoder().encode(held).write(to: directory.appendingPathComponent("situations.json"))
        let service = SituationService()
        await service.setIncludesPlanned(true)
        await service.keepAnswers(in: directory)
        let due = await service.plannedRefreshDue()
        XCTAssertFalse(due, "a catalogue written this session must not trigger another 113 MB parse")
        let counts = await service.counts
        XCTAssertEqual(counts.planned, 1)
    }
}
