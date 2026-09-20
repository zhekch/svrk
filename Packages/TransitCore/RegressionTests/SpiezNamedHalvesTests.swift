import XCTest
@testable import TransitCore

/// RE1 4177 out of Bern on 20 September, which parts at Spiez and said so in a
/// way nothing here was reading.
///
/// The card showed twelve coaches under one arrow reading "toward Domodossola
/// (I) | Zweisimmen", a stop list with no way to reach Zweisimmen, and a map
/// line that ran to Spiez and stopped. Three symptoms, and between them two
/// causes: the trunk had swallowed the Domodossola half (so the stop list ran
/// past the parting while the drawn line did not), and the parting itself was
/// published only as a relationship, which `split` did not read.
final class SpiezNamedHalvesTests: XCTestCase {
    private func formation(_ json: String) throws -> TrainFormation {
        try XCTUnwrap(JSONDecoder().decode(FormationResponse.self, from: Data(json.utf8)).digest())
    }

    /// Twelve coaches, one goal, and a train that parts all the same.
    func testSeparationAloneIsEnoughToFindTheParting() throws {
        let train = try formation(SpiezNamedHalvesFixture.incoming)
        XCTAssertEqual(train.stops.map(\.stopName), ["Bern", "Münsingen", "Thun", "Spiez"])
        XCTAssertEqual(train.stops[2].coaches.count, 12)
        // The goals never name two destinations, which is what used to be the
        // whole of the evidence for a split.
        XCTAssertTrue(train.stops.allSatisfy { $0.portions.count <= 1 })

        let split = try XCTUnwrap(train.split, "the `T` relationship names the parting")
        XCTAssertEqual(split.stopName, "Spiez")
        XCTAssertEqual(split.stopUIC, 8507483)
        XCTAssertEqual(Set(split.branches.compactMap(\.trainNumber)), [4277, 6829])
        XCTAssertEqual(
            Set(split.branches.compactMap(\.journeyID)),
            ["ch:1:sjyid:100015:6829-001", "ch:1:sjyid:100015:4277-001"]
        )
        // The goal on the way in is kept, because it is what puts coach numbers
        // beside the half that has them.
        XCTAssertEqual(split.portions.count, 1)
        XCTAssertEqual(split.portions[0].fromPosition, 1)
        XCTAssertEqual(split.portions[0].toPosition, 12)
        XCTAssertEqual(split.portions[0].destinationUIC, 8301003)
    }

    /// A relationship naming a station this working does not call at belongs to
    /// another leg of the same physical train, and is not this card's parting.
    func testSeparationElsewhereIsNotThisWorkingsSplit() throws {
        let train = try formation(SpiezNamedHalvesFixture.incoming)
        let moved = TrainFormation(
            trainNumber: train.trainNumber, operatorCode: train.operatorCode, runs: train.runs,
            totalLength: train.totalLength, totalSeats: train.totalSeats,
            vehicleCount: train.vehicleCount, axleCount: train.axleCount,
            lastUpdate: train.lastUpdate, stops: train.stops,
            relationships: [TrainFormation.Relationship(
                kind: .separation, direction: .after, stopName: "Visp", stopUIC: 8501609,
                others: [TrainFormation.Working(trainNumber: 4277, journeyID: "x")]
            )]
        )
        XCTAssertNil(moved.split)
    }

    /// The coach goals still win where the service files them, and they still
    /// carry the workings the relationship names beside them.
    func testCoachGoalsStillDescribeASplitTheyNameThemselves() throws {
        let train = try formation(SpiezDestinationFixture.incoming)
        let split = try XCTUnwrap(train.split)
        XCTAssertEqual(split.stopName, "Spiez")
        XCTAssertEqual(split.portions.count, 2)
        XCTAssertEqual(split.portions.map(\.destination), ["Brig", "Zweisimmen"])
        XCTAssertEqual(Set(split.branches.compactMap(\.trainNumber)), [4277, 6829])
    }

    /// The direction arrow over the drawing names what the coaches are for.
    ///
    /// `FormationView` picks the goal over the service's own destination when
    /// one goal covers every coach drawn; this is the fact that makes that
    /// choice the right one, and the fact the arrow was contradicting.
    func testEveryDrawnCoachIsCoveredByTheOneGoal() throws {
        let train = try formation(SpiezNamedHalvesFixture.incoming)
        let thun = try XCTUnwrap(train.stop(named: "Thun"))
        let portion = try XCTUnwrap(thun.portions.first)
        XCTAssertEqual(thun.portions.count, 1)
        XCTAssertTrue(thun.coaches.allSatisfy {
            $0.position >= portion.fromPosition && $0.position <= portion.toPosition
        })
        // And named, so the arrow has something to print: the service sends the
        // Italian station as a number and no name at all.
        XCTAssertNil(portion.destination)
        let named = train.naming { $0 == 8301003 ? "Domodossola (I)" : nil }
        XCTAssertEqual(named.stop(named: "Thun")?.portions.first?.destination, "Domodossola (I)")
    }

    /// Both halves resolve to real workings, which is what the picker lists and
    /// what the map draws its extra lines from.
    ///
    /// The Zweisimmen half is the one this exists for: it changes line number
    /// at the parting — an RE1 becoming an R11 — so the same-line rule that
    /// keeps `onward` from adopting any train leaving Spiez at the right minute
    /// rejects it, and the only thing that can vouch for it is its name.
    func testBothNamedHalvesResolveAtSpiez() async throws {
        let data = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-20T14:00:00Z"))
        _ = await fleet.drawTimetable(
            at: Date(timeIntervalSince1970: Double(now)),
            in: BBox(west: 7.0, south: 45.8, east: 8.5, north: 47.2)
        )
        let runs = await fleet.everyRawJourney()
        let trunk = try XCTUnwrap(runs.first { $0.journeyRef == "ch:1:sjyid:100015:4177-001" })

        // The trunk itself ends where it parts, so both halves are somebody
        // else's working and neither is already drawn.
        let read = await fleet.journey(id: trunk.id, at: now)
        let opened = try XCTUnwrap(read)
        XCTAssertEqual(opened.stops.map(\.name), ["Bern", "Münsingen", "Thun", "Spiez"])

        let parting = try XCTUnwrap(trunk.stops.last)
        let published = await fleet.publishedBranches(of: trunk.id, journeyRef: trunk.journeyRef)
        XCTAssertTrue(published.contains { $0.journeyID == "ch:1:sjyid:100015:6829-001" })

        // Driven from the recorded response the way the panel is: the names
        // come out of the formation, not out of this test.
        let split = try XCTUnwrap(formation(SpiezNamedHalvesFixture.incoming).split)
        var reached: [String] = []
        for working in split.branches {
            let half = await fleet.onward(
                from: split.stopName, stopUIC: split.stopUIC, notBefore: parting.arr, to: nil,
                mode: .train, operatorName: trunk.operatorName, line: nil,
                workings: [working], at: now
            )
            let found = try XCTUnwrap(half, "no working for \(working.journeyID ?? "?")")
            XCTAssertEqual(found.stops.first?.name, "Spiez")
            reached.append(found.stops.last?.name ?? "")
        }
        XCTAssertEqual(Set(reached), ["Zweisimmen", "Domodossola (I)"])

        // Without a name, the Zweisimmen half stays unfindable — the same-line
        // rule is what stops an RE1 adopting an unrelated R11, and this is the
        // check the named lookup exists to get around honestly.
        let unnamed = await fleet.onward(
            from: "Spiez", stopUIC: 8507483, notBefore: parting.arr, to: "Zweisimmen",
            mode: .train, operatorName: trunk.operatorName, line: trunk.line,
            workings: [], at: now
        )
        XCTAssertNil(unnamed)
    }

    /// The Italian end of the run has a name here, which is what the arrow over
    /// the drawing prints when the service sends the goal as a bare number.
    func testTheForeignGoalCanBeNamed() async throws {
        let data = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("stops.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let names = await fleet.stopNames(uic: [8301003])
        XCTAssertEqual(names[8301003], "Domodossola (I)", "the goal must read as the branch's own destination does")
    }

    /// The parting is known before any formation request is made.
    ///
    /// The card used to learn that a train comes apart only from the formation
    /// service: a network request per train, covering eleven companies. Until
    /// it answered there was no picker, no branch stops and one line on the
    /// map, and for an operator that publishes no formation there never was.
    /// The packed through-services already hold it, offline, for the whole
    /// timetable.
    func testThePartingIsKnownFromThePackedTimetableAlone() async throws {
        let data = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: data, supporting: false)
        let now = try XCTUnwrap(OJPTimings.time("2026-09-20T14:00:00Z"))
        _ = await fleet.drawTimetable(
            at: Date(timeIntervalSince1970: Double(now)),
            in: BBox(west: 7.0, south: 45.8, east: 8.5, north: 47.2)
        )
        let runs = await fleet.everyRawJourney()
        let trunk = try XCTUnwrap(runs.first { $0.journeyRef == "ch:1:sjyid:100015:4177-001" })
        let parting = try XCTUnwrap(trunk.stops.last)

        let read = await fleet.publishedSplit(
            of: trunk.id, journeyRef: trunk.journeyRef, at: parting
        )
        let split = try XCTUnwrap(read)
        XCTAssertEqual(split.stopName, "Spiez")
        XCTAssertEqual(split.stopUIC, 8507483)
        XCTAssertEqual(Set(split.branches.compactMap(\.trainNumber)), [4277, 6829])
        // It cannot say which coaches go where, and does not pretend to: that
        // is the part the formation adds.
        XCTAssertTrue(split.portions.isEmpty)

        // Two halves, four names: the graph spells each working both as a trip
        // id and as a journey reference, and one link carries both spellings of
        // one train. Counting names rather than links is what would make an
        // ordinary through service look like a parting.
        let spellings = await fleet.publishedBranches(
            of: trunk.id, journeyRef: trunk.journeyRef
        )
        XCTAssertEqual(spellings.count, 4)
        XCTAssertEqual(split.branches.count, 2)

        // A working with no successor at all is not a parting either.
        let onward = try XCTUnwrap(runs.first { $0.journeyRef == "ch:1:sjyid:100015:4277-001" })
        let end = try XCTUnwrap(onward.stops.last)
        let single = await fleet.publishedSplit(
            of: onward.id, journeyRef: onward.journeyRef, at: end
        )
        XCTAssertNil(single)
    }
}
