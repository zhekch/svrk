import Foundation

// The half of the layout database that is not written by hand.
//
// `LayoutLibrary` says what a line normally runs, which is enough to draw every
// vehicle in the country without asking anybody anything. What it cannot say is
// what *this* train is: a set swapped for a fault, an IC strengthened for a
// Saturday, a Regio running four coaches instead of three. The formation
// service knows all of that, and the app already asks it — once, for the one
// train somebody has tapped, because that is when a passenger is entitled to
// the real answer.
//
// So this is the thing that remembers. Every formation that comes back is
// turned into a layout and counted against the line it belongs to — the S42
// as a whole, not one working of it — and the map draws the usual set
// thereafter. A single odd working is drawn as itself for this journey and
// is not what the database remembers the line as.
//
// Two decisions about it are worth stating.
//
// **A confirmation is worth as much as a correction.** Where the real formation
// draws the same as the library's guess, nothing about the drawing changes and
// there is nothing to store — but the fact that it was *checked* is worth
// keeping, because it is the only thing that distinguishes a guess that has
// held up from one nobody has ever tested. Those are stored as a single flag
// rather than as a second copy of the layout.
//
// **The usual formation stays until something else has been seen more often.**
// Recency used to win, so one strengthened S42 redrew every other working of
// it. The count is what stops that. The odd working is cached for this
// journey only and forgotten when the app is next launched.

/// Which train a stored layout belongs to.
public struct LayoutKey: Hashable, Sendable, Codable {
    /// The company, as the formation service spells it — `SBBP`, `BLSP`.
    public var operatorCode: String
    public var trainNumber: Int

    public init(operatorCode: String, trainNumber: Int) {
        self.operatorCode = operatorCode
        self.trainNumber = trainNumber
    }

    public init(_ key: FormationKey) {
        self.init(operatorCode: key.operatorCode.rawValue, trainNumber: key.trainNumber)
    }
}

/// A whole service rather than one working of it.
///
/// The train number is the accurate key and the wrong one to stop at. "The
/// S42" is not a train, it is forty trains a day: 18642 at three o'clock and
/// 18646 at five, each with its own number and its own record. So a formation
/// learned by tapping the three o'clock one taught the map nothing about the
/// five o'clock one, and the drawing went back to the library's guess between
/// them — which reads exactly like the database forgetting what it was told.
///
/// A line almost always runs one kind of set all day. Filing what was seen
/// against the line as well as against the working makes one tap teach the map
/// about every other working of that line, which is what "it learns" has to
/// mean for it to be worth anything.
public struct PatternKey: Hashable, Sendable, Codable {
    /// The operator's short code, upper-cased.
    public var operatorName: String
    /// The line as published, folded — `S42`, `IC1`, `IR16`.
    public var line: String

    /// Nil where there is no line to file against — which is most of the road
    /// network, where the "line" is a route number the formation service has
    /// never heard of anyway.
    public init?(operatorName: String?, line: String?) {
        let folded = LayoutLibrary.normalise(line)
        guard !folded.isEmpty else { return nil }
        self.operatorName = (operatorName ?? "").uppercased()
        self.line = folded
    }
}

/// What is known about one train.
public struct LayoutRecord: Sendable, Codable, Equatable {
    /// The formation as the service last gave it. Nil where it drew the same as
    /// the library already thought, which is the common case and not worth a
    /// second copy of.
    public var layout: VehicleLayout?
    /// Whether the library's guess was checked against a real formation and
    /// held.
    public var matchedLibrary: Bool
    /// When the service last answered about this train.
    public var seen: Date
    /// How many units the service said it had, kept even for a match because it
    /// is the one number worth showing a reader as evidence.
    public var units: Int
    /// How many observations have agreed with this record.
    ///
    /// The reason a single odd working of the S42 cannot overwrite the line:
    /// the usual four-car set has been seen fifty times, the strengthened one
    /// once, and the count is what tells them apart.
    public var count: Int

    public init(
        layout: VehicleLayout?, matchedLibrary: Bool, seen: Date, units: Int,
        count: Int = 1
    ) {
        self.layout = layout
        self.matchedLibrary = matchedLibrary
        self.seen = seen
        self.units = units
        self.count = count
    }

    /// Whether this is a record of the service having nothing to say.
    ///
    /// Worth keeping, and worth keeping apart from a confirmation. The map asks
    /// about the trains in view a few at a time, and about a third of what it
    /// asks about — a working the realtime system has not filed, a train that
    /// is not running today — comes back empty. Without a note of that, every
    /// sweep asks the same questions again and the quota goes on silences.
    public var isSilence: Bool { layout == nil && !matchedLibrary && units == 0 }

    enum CodingKeys: String, CodingKey {
        case layout, matchedLibrary, seen, units, count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent(VehicleLayout.self, forKey: .layout)
        matchedLibrary = try c.decode(Bool.self, forKey: .matchedLibrary)
        seen = try c.decode(Date.self, forKey: .seen)
        units = try c.decode(Int.self, forKey: .units)
        // A file written before counts existed is one sighting of whatever it
        // held — the honest default, and what lets the bundled seed load.
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }
}

/// The learned half of the layout database.
///
/// Not an actor. Every read is on the draw path — fifteen times a second, once
/// per vehicle on screen — and an `await` per vehicle per frame would put the
/// whole drawing behind a suspension queue for a dictionary lookup. The
/// contents are behind a lock instead, which is what the access pattern
/// actually needs: many short reads from one thread and a rare write from
/// another.
public final class VehicleLayoutStore: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LayoutKey: LayoutRecord] = [:]
    /// What each *line* usually runs, counted rather than overwritten.
    ///
    /// A line almost always runs one kind of set all day. The first observation
    /// of the S42 taught the map about every working of it, which is what
    /// "it learns" has to mean — and the next observation used to *replace*
    /// that, so one strengthened train redrew the whole line. The count is
    /// what stops that: the usual formation stays until something else has
    /// been seen more often.
    private var patterns: [PatternKey: LayoutRecord] = [:]
    /// The other formation a line has been seen as, while it is still losing.
    ///
    /// Held so a real change of stock can take over (six-car all afternoon
    /// against a four-car morning) without a single odd working doing the
    /// same. Not a third slot: anything that matches neither is a new
    /// challenger and the previous one is forgotten.
    private var challengers: [PatternKey: LayoutRecord] = [:]
    /// This journey's own formation, where it is not the line's usual one.
    ///
    /// In memory only. A unique working of the S42 has to be drawn as itself
    /// for as long as it is on the map, and must not be what the database
    /// remembers the S42 as tomorrow.
    private var journeys: [LayoutKey: VehicleLayout] = [:]
    /// Resolved layouts, so a screenful of vehicles is not a screenful of
    /// table lookups and string folding fifteen times a second.
    private var resolved: [String: VehicleLayout] = [:]
    private var dirty = false
    private let url: URL?

    public init(url: URL? = nil) {
        self.url = url
    }

    /// How many individual workings are on file.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    /// How many lines have a correction on file.
    public var patternCount: Int {
        lock.lock(); defer { lock.unlock() }
        return patterns.values.filter { $0.layout != nil }.count
    }

    // MARK: - Reading

    /// What to draw for a vehicle.
    ///
    /// The learned entry where there is one, the library otherwise — and either
    /// way painted in the operator's colours, because a formation says what a
    /// train is made of and nothing at all about who owns it.
    public func layout(for vehicle: VehicleSnapshot, modeColour: String) -> VehicleLayout {
        // Keyed on everything the answer depends on rather than on the vehicle
        // id: a cache keyed by id would hold one entry per running journey,
        // 18,000 of them, for what is really a few hundred distinct answers.
        // Which of the operator's liveries this one wears, where the fleet runs
        // in more than one. Seeded from the journey id and folded into the key:
        // it is a handful of extra entries — one per livery, not one per
        // vehicle — and left out of the key the first tram of the day decided
        // the colour of every tram in the city.
        let variant = LayoutLibrary.variant(
            operatorName: vehicle.operatorName, mode: vehicle.mode, seed: vehicle.id
        )
        let cacheKey = [
            vehicle.mode.rawValue, vehicle.category ?? "", vehicle.line,
            vehicle.operatorName ?? "", learnedKey(of: vehicle).map(describe) ?? "",
            String(variant),
        ].joined(separator: "|")

        lock.lock()
        if let held = resolved[cacheKey] {
            lock.unlock()
            return held
        }
        // This journey first — a unique working is drawn as itself while it
        // is on the map — then the line, which is what the rest of the
        // workings of it should look like.
        let learned = learnedKey(of: vehicle).flatMap { journeys[$0] }
            ?? PatternKey(operatorName: vehicle.operatorName, line: vehicle.line)
                .flatMap { patterns[$0]?.layout }
        lock.unlock()

        let paint = LayoutLibrary.livery(
            operatorName: vehicle.operatorName, mode: vehicle.mode,
            modeColour: modeColour, variant: variant
        )
        let answer = learned?.painted(paint) ?? LayoutLibrary.layout(
            mode: vehicle.mode, category: vehicle.category, line: vehicle.line,
            operatorName: vehicle.operatorName, modeColour: modeColour, variant: variant
        )

        lock.lock()
        // A bound, not a measurement: the country cannot produce more distinct
        // answers than this in one session, and an unbounded cache on a draw
        // path is a leak waiting for a long day.
        if resolved.count > 4_000 { resolved.removeAll(keepingCapacity: true) }
        resolved[cacheKey] = answer
        lock.unlock()
        return answer
    }

    /// What the store knows about one train, for the panel to say so.
    public func record(for key: LayoutKey) -> LayoutRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[key]
    }

    /// What the store has counted for a line.
    public func pattern(for key: PatternKey) -> LayoutRecord? {
        lock.lock(); defer { lock.unlock() }
        return patterns[key]
    }

    /// Note that the service was asked about this train and had nothing.
    public func noteSilence(key: LayoutKey, at moment: Date) {
        lock.lock()
        records[key] = LayoutRecord(
            layout: nil, matchedLibrary: false, seen: moment, units: 0
        )
        dirty = true
        lock.unlock()
    }

    /// The key a running vehicle files under, or nil where there is no question
    /// to ask — a bus, a tram, a company outside the eleven that publish.
    public func key(for vehicle: VehicleSnapshot) -> LayoutKey? { learnedKey(of: vehicle) }

    /// The key a running vehicle files under, where it has one.
    ///
    /// The same reading `FormationKey` does, because it has to be: a layout
    /// learned under one spelling and looked up under another is a layout that
    /// is never found again.
    private func learnedKey(of vehicle: VehicleSnapshot) -> LayoutKey? {
        guard vehicle.mode == .train else { return nil }
        // The leg being run, not the journey as a whole — a Swiss service that
        // changes number partway is filed by the service under each number
        // separately. Without a call list to place the vehicle in, the journey's
        // own id is the best available.
        let leg = vehicle.parts?.first { $0.start <= vehicle.index && vehicle.index <= $0.end }
        guard let parsed = FormationKey(
            journeyID: vehicle.formationReference(leg: leg), operationDate: ""
        ) else { return nil }
        return LayoutKey(parsed)
    }

    private func describe(_ key: LayoutKey) -> String {
        "\(key.operatorCode)#\(key.trainNumber)"
    }

    // MARK: - Learning

    /// File what the service said about a train.
    ///
    /// Returns whether anything was learned, so a caller can say "this is the
    /// real formation" rather than "this is what the line usually runs".
    @discardableResult
    public func learn(
        _ formation: TrainFormation, key: LayoutKey, at moment: Date,
        mode: Mode, category: String?, line: String, operatorName: String?,
        modeColour: String
    ) -> Bool {
        guard let observed = Self.layout(
            from: formation, at: moment,
            livery: LayoutLibrary.livery(operatorName: operatorName, mode: mode, modeColour: modeColour)
        ) else { return false }

        let guess = LayoutLibrary.layout(
            mode: mode, category: category, line: line,
            operatorName: operatorName, modeColour: modeColour
        )
        let matches = guess.drawsAlike(observed)

        let incoming = LayoutRecord(
            layout: matches ? nil : observed, matchedLibrary: matches,
            seen: moment, units: observed.units.count, count: 1
        )

        lock.lock()
        records[key] = incoming
        // This journey is always drawn as what the service just said, even
        // when that is not what the line usually runs.
        journeys[key] = observed
        if let pattern = PatternKey(operatorName: operatorName, line: line) {
            tally(incoming, against: pattern)
        }
        // The resolution cache holds answers built without any of this in it.
        resolved.removeAll(keepingCapacity: true)
        dirty = true
        lock.unlock()
        return !matches
    }

    /// Count this observation against the line, without letting a single
    /// different working replace what has been seen more often.
    private func tally(_ incoming: LayoutRecord, against pattern: PatternKey) {
        if var incumbent = patterns[pattern], Self.sameFormation(incumbent, incoming) {
            incumbent.count += 1
            incumbent.seen = incoming.seen
            patterns[pattern] = incumbent
            return
        }
        if var rival = challengers[pattern], Self.sameFormation(rival, incoming) {
            rival.count += 1
            rival.seen = incoming.seen
            if let incumbent = patterns[pattern], Self.beats(rival, incumbent) {
                patterns[pattern] = rival
                challengers[pattern] = incumbent
            } else {
                challengers[pattern] = rival
            }
            return
        }
        if patterns[pattern] == nil {
            patterns[pattern] = incoming
            return
        }
        if let incumbent = patterns[pattern], Self.beats(incoming, incumbent) {
            patterns[pattern] = incoming
            challengers[pattern] = incumbent
            return
        }
        challengers[pattern] = incoming
    }

    /// Whether two records describe the same formation, for counting.
    ///
    /// A library confirmation is a formation too: "the S42 is what we thought"
    /// is the vote that should accumulate against a one-off strengthening.
    static func sameFormation(_ a: LayoutRecord, _ b: LayoutRecord) -> Bool {
        if a.matchedLibrary && b.matchedLibrary { return true }
        if a.matchedLibrary || b.matchedLibrary { return false }
        guard let left = a.layout, let right = b.layout else { return false }
        return left.drawsAlike(right)
    }

    /// Whether a rival should replace the line's usual formation.
    ///
    /// Strictly more sightings, with a tie going to the library — so one
    /// short-formed train and one normal one leaves the line drawn as the
    /// library already thought, which is the case a correction that is no
    /// longer needed must not survive.
    static func beats(_ rival: LayoutRecord, _ incumbent: LayoutRecord) -> Bool {
        if rival.count > incumbent.count { return true }
        if rival.count < incumbent.count { return false }
        return rival.matchedLibrary && !incumbent.matchedLibrary
    }

    /// The formation as a drawing.
    ///
    /// Read at the stop nearest the moment asked about, because a train that
    /// splits is not the same train before and after — the service lists the
    /// formation stop by stop for exactly that reason, and taking the first
    /// stop would draw the whole train right up until it stopped being one.
    public static func layout(
        from formation: TrainFormation, at moment: Date, livery: Livery
    ) -> VehicleLayout? {
        let stops = formation.stops.filter { !$0.isEmpty }
        guard let stop = stops.min(by: { $0.distance(from: moment) < $1.distance(from: moment) })
            ?? stops.first
        else { return nil }
        guard !stop.coaches.isEmpty else { return nil }

        // Which ends of this train are driven from.
        //
        // Nothing in the response says so — the service describes what a
        // passenger finds inside a coach, and a cab is not something a
        // passenger finds. So it is worked out from the shape of the train,
        // which is enough because Swiss practice is so uniform.
        //
        // A train with no locomotive in it is a multiple unit and is driven
        // from both ends. A train with one is worked push-pull: the locomotive
        // end is a locomotive, and the *other* end is a driving trailer, which
        // is how nearly every loco-hauled passenger train in the country runs.
        // Both of those were got wrong first by asking only whether a
        // locomotive was present anywhere: that put a plain wall on the far end
        // of every hauled rake — the Bt a passenger is standing next to on the
        // platform at Bern — and, on a rake drawn with its locomotive pushing
        // at the back, on the front of the train as well.
        //
        // Where the rolling-stock register named the class, that wins: `Bt`,
        // `ABt` and `BDt` are driving trailers by definition and `RABe`,
        // `RABDe`, `RBDe` and `ETR` are units whose end cars always have a cab.
        let hasLocomotive = stop.coaches.contains { $0.kind == .locomotive }
        let leadingCoach = stop.coaches.first
        let trailingCoach = stop.coaches.last

        /// Whether this end of the train is one somebody drives from.
        ///
        /// The class name only gets a say where the train has a locomotive in
        /// it. That is the only case where the question is real — is the far
        /// end a driving trailer or a plain coach — and it is the case the
        /// register's names were consulted for.
        ///
        /// With no locomotive anywhere, the train is a multiple unit and is
        /// driven from both ends, whatever any coach is called. There is
        /// nothing else in it that could drive it. Letting the name veto that
        /// is how an EC out of Milano came to be drawn with a flat wall across
        /// its nose: the service named the leading vehicle something the
        /// prefix table does not carry, the table answered "not driving stock",
        /// and a seven-car unit lost the one end everybody looks at.
        func driven(_ coach: Coach?) -> Bool {
            guard hasLocomotive else { return true }
            return coach?.kind == .locomotive || (Self.isDrivingStock(coach?.typeName) ?? true)
        }
        let cabAtFront = driven(leadingCoach)
        let cabAtBack = driven(trailingCoach)

        var units: [VehicleUnit] = []
        for (index, coach) in stop.coaches.enumerated() {
            let isFirst = index == 0
            let isLast = index == stop.coaches.count - 1
            units.append(unit(
                from: coach, leading: isFirst, trailing: isLast,
                cabAtFront: cabAtFront, cabAtBack: cabAtBack,
                selfPowered: !hasLocomotive, joint: isFirst ? .none : .coupler
            ))
        }

        return VehicleLayout(
            units: units, livery: livery,
            name: name(units: units, formation: formation), source: .observed
        ).resolvingStripes()
    }

    /// One coach, as a body.
    static func unit(
        from coach: Coach, leading: Bool, trailing: Bool,
        cabAtFront: Bool, cabAtBack: Bool, selfPowered: Bool, joint: Joint
    ) -> VehicleUnit {
        let kind: UnitKind
        switch coach.kind {
        case .locomotive: kind = .locomotive
        case .luggage: kind = .van
        default: kind = .coach
        }

        // See `layout(from:at:livery:)` for how the two ends were decided. A
        // locomotive has a cab at both ends wherever it is standing.
        let cabFront = kind == .locomotive ? true : (leading && cabAtFront)
        let cabBack = kind == .locomotive ? true : (trailing && cabAtBack)

        let band: ClassBand
        switch coach.kind {
        case .first: band = .first
        case .second: band = .second
        case .mixed: band = .mixed
        case .restaurant, .diningFirst, .diningSecond: band = .dining
        case .locomotive, .luggage, .fictitious, .parked: band = .none
        case .couchette, .sleeper, .family, .classless: band = .second
        }

        // The register's own length wherever it has one, which is the whole
        // reason a fetched formation draws better than a guessed one: a real
        // 26.4 m coach next to a real 18.7 m one is a difference the map can
        // show and the library can only average over.
        let length = coach.length.flatMap { $0 > 4 && $0 < 60 ? $0 : nil }
            ?? Self.defaultLength(kind: kind, typeName: coach.typeName)

        return VehicleUnit(
            kind: kind, length: length,
            width: Self.isMetreGauge(coach.typeName)
                ? VehicleUnit.metreGaugeWidth : VehicleUnit.standardGaugeWidth,
            cabFront: cabFront, cabBack: cabBack,
            // Only on a vehicle that pulls. A driving trailer has a cab and no
            // pantograph — it is the unpowered end of the train — so putting
            // one on every end car drew a Bt as though it were a railcar.
            pantographs: kind == .locomotive
                ? 2 : (selfPowered && (leading || trailing) ? 1 : 0),
            doubleDeck: Self.isDoubleDeck(coach.typeName),
            band: band, doors: kind == .locomotive ? 0 : 2,
            closed: coach.isClosed, joint: joint,
            // The service says what is inside a coach and never what it looks
            // like, so the shape of the nose has to come off the class name —
            // and without it a formation the app had *learned* was drawn worse
            // than the one it had guessed: an ICE looked up by tapping it lost
            // the long nose the library gives it untapped.
            nose: (cabFront || cabBack) ? Self.nose(for: coach.typeName) : nil
        )
    }

    /// Whether the class named is one with a cab in it, or nil where the class
    /// is not named at all.
    static func isDrivingStock(_ typeName: String?) -> Bool? {
        guard let raw = typeName?.uppercased(), !raw.isEmpty else { return nil }
        let prefixes = ["RABE", "RABDE", "RBDE", "RBE", "ABE", "BDE", "ETR", "ICE", "TGV", "BT", "ABT", "BDT", "AT"]
        // Longest first: `ABT` and `ABE` both start with `AB`, and `BT` is a
        // prefix of nothing but itself.
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where raw.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// The shape of the nose the named class carries, where it has one worth
    /// drawing differently.
    static func nose(for typeName: String?) -> Nose? {
        guard let raw = typeName?.uppercased().filter({ !$0.isWhitespace }), !raw.isEmpty
        else { return nil }
        // The high-speed and tilting sets: an ICE, a TGV, a Giruno, an Astoro
        // and an ICN all end in several metres of unbroken taper.
        let streamlined = ["ICE", "TGV", "ETR", "RABE501", "RABE503", "RABDE500"]
        if streamlined.contains(where: { raw.hasPrefix($0) }) { return .streamlined }
        return nil
    }

    /// Public because the formation panel draws the deck line off it: the
    /// question "is this a double-decker" is answered from the class name in
    /// exactly one place, and the side elevation must not answer it a second
    /// way and disagree with the map.
    public static func isDoubleDeck(_ typeName: String?) -> Bool {
        guard let raw = typeName?.uppercased() else { return false }
        // IC2000 stock carries `2E` — *zwei Etagen* — in a bracket after the
        // class letter: `AD(2E)`, `A(2E)`, `BR(2E)`, `WRB(2E)`, `Bt(2E)Fam`.
        // The `D` in `AD` is a luggage compartment, so reading a `D` for
        // *Doppelstock* named the wrong letter and matched none of them, and
        // every IC2000 the app had looked up was drawn as a single-decker.
        //
        // `(2E` and not `(2E)`, because the bracket does not always close after
        // the two characters: the bicycle coach of an IC2000 rake is filed
        // `B(2E/Velo)`. Matching the closing paren left exactly one coach of
        // every such train without its deck line — a double-decker drawn among
        // eight others as though it were the odd single-deck one.
        //
        // Nothing else in the register's naming uses that bracket: the EW IV
        // coaches an IC2000 is strengthened with are `A4(LBT)`, `B4(LBT)-K` and
        // `Bt4(GBT/Velo)`, and they are single-deck. `DD` is kept for the stock
        // that spells it out. The FV-Dosto and the KISS are `RABe 502` and
        // `RABe 511`, and the DTZ `RABe 514`.
        return raw.contains("(2E") || raw.contains("DD") || raw.hasPrefix("RABE502") || raw.hasPrefix("RABDE502")
            || raw.hasPrefix("RABE511") || raw.hasPrefix("RABE512") || raw.hasPrefix("RABE514")
            || raw.hasPrefix("RABE515") || raw.hasPrefix("RABE516")
    }

    static func isMetreGauge(_ typeName: String?) -> Bool {
        guard let raw = typeName?.uppercased() else { return false }
        return raw.hasPrefix("ABE8/12") || raw.hasPrefix("ABE4/16") || raw.hasPrefix("GE")
            || raw.hasPrefix("BEH") || raw.hasPrefix("ABEH")
    }

    static func defaultLength(kind: UnitKind, typeName: String?) -> Double {
        switch kind {
        case .locomotive: return 18.5
        case .van: return 18.0
        default: return isDoubleDeck(typeName) ? 26.8 : 26.4
        }
    }

    /// What the train is, in words: "Locomotive + 8 coaches", "6-car unit".
    static func name(units: [VehicleUnit], formation: TrainFormation) -> String {
        let locomotives = units.count { $0.kind == .locomotive }
        let coaches = units.count - locomotives
        if locomotives > 0 {
            let engine = locomotives == 1 ? "Locomotive" : "\(locomotives) locomotives"
            return "\(engine) + \(coaches) coach\(coaches == 1 ? "" : "es")"
        }
        return "\(units.count)-car unit"
    }

    // MARK: - Disk

    /// Read whatever was learned — on this device, and before it ever ran.
    ///
    /// Two files, and the order matters. `seed` is the copy that ships in the
    /// bundle: what the app already knew when it was built, which survives the
    /// container being wiped by a reinstall and means a fresh install is not a
    /// fresh start. The device's own file is read over the top of it, because
    /// anything learned here is newer than anything shipped.
    ///
    /// A file that will not parse is discarded rather than repaired. Everything
    /// in it can be asked for again, one train at a time, and a store that
    /// half-loads is worse than one that starts empty: it draws some trains
    /// from yesterday's knowledge and some from the library, with nothing
    /// saying which.
    public func load(seededBy seed: URL? = nil) {
        var loaded: [LayoutKey: LayoutRecord] = [:]
        var loadedPatterns: [PatternKey: LayoutRecord] = [:]
        var loadedChallengers: [PatternKey: LayoutRecord] = [:]
        // A silence goes stale in a way a formation does not. "Train 4021 is
        // not filed" is true of the day it was asked on; the train may well run
        // tomorrow. A drawing, by contrast, is the same set next week.
        let cutoff = Date().addingTimeInterval(-Self.silenceLife)

        for url in [seed, self.url].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder.layouts.decode(File.self, from: data),
                  file.version == Self.version
            else { continue }
            for entry in file.entries where !(entry.record.isSilence && entry.record.seen < cutoff) {
                loaded[entry.key] = entry.record
            }
            for entry in file.patterns {
                loadedPatterns[entry.key] = entry.record
                if let rival = entry.challenger { loadedChallengers[entry.key] = rival }
            }
        }

        lock.lock()
        records = loaded
        patterns = loadedPatterns
        challengers = loadedChallengers
        journeys.removeAll(keepingCapacity: true)
        resolved.removeAll(keepingCapacity: true)
        dirty = false
        lock.unlock()
    }

    /// Write it back, if anything has been learned since the last time.
    ///
    /// Returns whether a file is now on disk, so a caller can offer to hand it
    /// over. The write used to be a bare `try?`: `Library/Application Support`
    /// does not exist for an app that has never written there, and a store that
    /// silently failed to save looked exactly like one that had saved and then
    /// forgotten — which is the report this was found from.
    @discardableResult
    public func save() -> Bool {
        guard let url else { return false }
        lock.lock()
        let entries = records
            .sorted { ($0.key.operatorCode, $0.key.trainNumber) < ($1.key.operatorCode, $1.key.trainNumber) }
            .map { Entry(key: $0.key, record: $0.value) }
        let heldChallengers = challengers
        let lines = patterns
            .sorted { ($0.key.operatorName, $0.key.line) < ($1.key.operatorName, $1.key.line) }
            .map { Pattern(key: $0.key, record: $0.value, challenger: heldChallengers[$0.key]) }
        let hadChanges = dirty
        dirty = false
        lock.unlock()

        guard hadChanges || !FileManager.default.fileExists(atPath: url.path) else { return true }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let file = File(version: Self.version, entries: entries, patterns: lines)
        do {
            try JSONEncoder.layouts.encode(file).write(to: url, options: .atomic)
            lastError = nil
            return true
        } catch {
            // Said out loud rather than swallowed. There is nothing useful to
            // do about it here, and every reason for the caller to be able to
            // tell "nothing to save" from "could not save".
            lock.lock(); lastError = "\(error)"; dirty = true; lock.unlock()
            return false
        }
    }

    /// Why the last save failed, where it did.
    public private(set) var lastError: String?

    /// The file, once it is written — for handing to somebody who wants to keep
    /// it. Nil where nothing has been learned yet.
    public func exported() -> URL? {
        guard save(), let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Bump on any change of shape. A file written by an older version is
    /// discarded, which costs nothing: it is a record of questions that can be
    /// asked again.
    static let version = 2

    /// How long a "the service has nothing for this train" note stands.
    static let silenceLife: TimeInterval = 7 * 24 * 3600

    struct File: Codable {
        var version: Int
        var entries: [Entry]
        /// Absent in a file written before lines were learned as well as
        /// workings, which the version check already rejects — defaulted so a
        /// hand-written seed need not carry an empty array.
        var patterns: [Pattern] = []
    }

    struct Entry: Codable {
        var key: LayoutKey
        var record: LayoutRecord
    }

    struct Pattern: Codable {
        var key: PatternKey
        var record: LayoutRecord
        /// The losing formation, where the line has been seen as more than one
        /// thing. Absent in a file written before counts, and in the common
        /// case of a line that only ever runs one set.
        var challenger: LayoutRecord?
    }
}

extension JSONDecoder {
    fileprivate static let layouts: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

extension JSONEncoder {
    fileprivate static let layouts: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}
