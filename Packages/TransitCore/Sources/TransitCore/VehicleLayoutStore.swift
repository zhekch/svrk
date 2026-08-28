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
    /// What each line runs *at a given hour*, which is the tier that stops two
    /// true observations of one line from being a contradiction.
    ///
    /// The RE1 is two units coupled at eight in the morning and one of them at
    /// eleven. Filed against the line alone those are not two facts, they are
    /// one fact seen twice and disagreeing with itself, and the count below
    /// settles it by drawing whichever is more common over both. Filed against
    /// the line *and the hour* they are two facts about two different trains,
    /// which is what they always were. See `TimeSlot`.
    private var slots: [SlotKey: LayoutRecord] = [:]
    /// The losing formation for one slot, on the same terms as `challengers`.
    private var slotChallengers: [SlotKey: LayoutRecord] = [:]
    /// Resolved layouts, so a screenful of vehicles is not a screenful of
    /// table lookups and string folding fifteen times a second.
    private var resolved: [ResolvedKey: VehicleLayout] = [:]
    /// The local offset from UTC, kept until the transition it lasts to.
    ///
    /// Worked out inside the same critical section the cache lookup already
    /// takes, so placing a vehicle in its hour costs no extra locking and, on
    /// all but two days a year, no work at all. See `ZoneOffset`.
    private var zone: ZoneOffset?
    /// Kept so the observer can be taken down with the store.
    private var zoneWatch: (any NSObjectProtocol)?
    private var dirty = false
    private let url: URL?

    public init(url: URL? = nil) {
        self.url = url
        // A phone carried across a border must stop filing trains in the hours
        // of the country it left. Asked for once here rather than checked on
        // every lookup: it is a thing that happens a handful of times in the
        // life of an install, and checking for it per vehicle per frame was
        // paying for it several thousand times a second.
        //
        // Only the cached offset is thrown away. What has already been learned
        // stays — a formation observed at eight in the morning in Zurich was
        // observed at eight in the morning, and is not retrospectively about
        // some other hour because the reader has since flown somewhere.
        zoneWatch = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.zone = nil
            // The resolved answers were placed in hours read with the old
            // offset, so they name the wrong slots now.
            self.resolved.removeAll(keepingCapacity: true)
            self.lock.unlock()
        }
    }

    deinit {
        if let zoneWatch { NotificationCenter.default.removeObserver(zoneWatch) }
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

    /// Everything a resolved layout depends on.
    ///
    /// A struct rather than the joined string this used to be, and the change
    /// is worth a note because it sits on the hottest path in the app. Building
    /// the key was `[String].joined(separator:)` — six strings, an array and one
    /// more string, allocated per vehicle per frame purely to be hashed and
    /// thrown away. A few hundred vehicles at fifteen frames a second is tens of
    /// thousands of needless allocations a second, and that was the price of
    /// looking something up in a dictionary.
    ///
    /// Hashing this hashes the strings the snapshot already holds and copies
    /// none of them. That is what pays for the hour below: the slot makes the
    /// key one field wider and the key as a whole considerably cheaper.
    struct ResolvedKey: Hashable {
        var mode: Mode
        var category: String?
        var line: String
        var operatorName: String?
        var learned: LayoutKey?
        var variant: Int
        /// Nil for anything with no timetable to place it in the day by, which
        /// is every vehicle the slot tier does not apply to anyway.
        var slot: TimeSlot?
    }

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
        let learnedKey = learnedKey(of: vehicle)
        let pattern = PatternKey(operatorName: vehicle.operatorName, line: vehicle.line)

        lock.lock()
        // Which hour of which kind of day this working belongs to. Read off the
        // vehicle's own timetable rather than off the clock, so it is constant
        // for the life of the journey — which is what lets it sit in a cache
        // key at all. See `slot(of:)`.
        let slot = pattern == nil ? nil : self.slot(of: vehicle)
        let cacheKey = ResolvedKey(
            mode: vehicle.mode, category: vehicle.category, line: vehicle.line,
            operatorName: vehicle.operatorName, learned: learnedKey,
            variant: variant, slot: slot
        )
        if let held = resolved[cacheKey] {
            lock.unlock()
            return held
        }
        // Most specific first, and each tier is a strictly better answer than
        // the one behind it:
        //
        // 1. this journey, because a unique working is drawn as itself for as
        //    long as it is on the map;
        // 2. this line at this hour — the eight o'clock RE1 and not the eleven
        //    o'clock one, which is the whole reason slots exist;
        // 3. this line, whenever, which is what it looked like before the app
        //    had ever heard of hours;
        // 4. the library, where everything starts.
        //
        // The third tier is why adding the second cannot make the drawing
        // worse. An hour nobody has observed falls straight through to the
        // line-wide answer, which is exactly what the map drew before.
        let learned = learnedKey.flatMap { journeys[$0] }
            ?? pattern.flatMap { key in
                slot.flatMap { slots[SlotKey(pattern: key, slot: $0)]?.layout }
                    ?? patterns[key]?.layout
            }
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
        // path is a leak waiting for a long day. Raised along with the hour in
        // the key — the same few hundred answers can now appear under any hour
        // actually on screen, which even as the clock is scrubbed is a handful
        // and never the whole forty-eight.
        if resolved.count > 12_000 { resolved.removeAll(keepingCapacity: true) }
        resolved[cacheKey] = answer
        lock.unlock()
        return answer
    }

    /// Which slot a working belongs to.
    ///
    /// The train's own scheduled time at the call it is standing at or running
    /// from, which is the honest reading of "when is this train". Not the wall
    /// clock: the map can be scrubbed to another hour, and a vehicle shown at
    /// eight in the morning is an eight-in-the-morning working whatever time it
    /// is outside. Not the *delayed* time either — a train an hour late is
    /// still the working it was booked as, and the formation it was
    /// strengthened to is the one for the hour it was meant to run in.
    ///
    /// Callers hold `lock`.
    private func slot(of vehicle: VehicleSnapshot) -> TimeSlot? {
        guard let seconds = Self.scheduledSeconds(of: vehicle) else { return nil }
        return TimeSlot(epochSeconds: seconds, offsetFromUTC: offset(at: seconds))
    }

    /// The booked time this working is at, in epoch seconds.
    static func scheduledSeconds(of vehicle: VehicleSnapshot) -> Int? {
        // The call being stood at, where the index points at one. A journey
        // whose index has run off the end of its calls is finishing, and the
        // last call is the right answer for it.
        let call = vehicle.stops.indices.contains(vehicle.index)
            ? vehicle.stops[vehicle.index]
            : vehicle.stops.last
        guard let call else { return nil }
        // `sched` is the printed time, which is what the timetable repeats on.
        // `dep` carries the delay and so drifts between polls — and a value
        // that moves cannot sit in a cache key without invalidating it every
        // time the feed refreshes.
        let booked = call.sched ?? call.dep
        // A call with no time at all is filed by nothing. Better no slot than a
        // slot at the epoch, which would put every such train in one bucket and
        // teach them things about each other.
        return booked > 0 ? booked : nil
    }

    /// The local offset from UTC at a moment, remembered between calls.
    ///
    /// Two integer comparisons in the case that matters, which is every call
    /// but the first and the two a year that cross a clock change. Reading
    /// `TimeZone.current` here to notice a phone that had moved cost a retain
    /// and two identifier strings compared per vehicle per frame; the same fact
    /// is now learned by being told — see `init`.
    ///
    /// Callers hold `lock`.
    private func offset(at epochSeconds: Int) -> Int {
        if let zone, zone.covers(epochSeconds) { return zone.seconds }
        let measured = ZoneOffset.around(
            Date(timeIntervalSince1970: TimeInterval(epochSeconds)), zone: .current
        )
        zone = measured
        return measured.seconds
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

    /// What the store has counted for a line at one hour of the day.
    ///
    /// Nil where that hour has never been observed, which is the ordinary case
    /// for most of the day on most lines — and is not a gap, because the line's
    /// own record answers for it. See the tiers in `layout(for:modeColour:)`.
    public func slotRecord(for key: SlotKey) -> LayoutRecord? {
        lock.lock(); defer { lock.unlock() }
        return slots[key]
    }

    /// How many line-and-hour combinations have been observed.
    public var slotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return slots.count
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
    ///
    /// `slot` is which working of the line this is — see `TimeSlot`. Handed in
    /// rather than taken from `moment` because the two are not the same thing:
    /// `moment` is when the app asked, and the slot is when the train runs. A
    /// train tapped at half past eleven at night while the clock is scrubbed
    /// back to the morning peak is a morning-peak working, and filing it under
    /// the hour the phone happens to be showing would teach the database that
    /// the RE1 runs eight coaches at midnight. Nil files against the line only,
    /// which is what the app did before slots existed.
    @discardableResult
    public func learn(
        _ formation: TrainFormation, key: LayoutKey, at moment: Date,
        mode: Mode, category: String?, line: String, operatorName: String?,
        modeColour: String, slot: TimeSlot? = nil
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
            // Both tiers, from the one observation, and it is the same
            // observation in each. The line-wide tally is not a summary of the
            // slots and is not meant to be: it is the answer for every hour
            // nobody has looked at yet, and it stays useful exactly as long as
            // that is most of them.
            Self.tally(incoming, at: pattern, incumbents: &patterns, challengers: &challengers)
            if let slot {
                Self.tally(
                    incoming, at: SlotKey(pattern: pattern, slot: slot),
                    incumbents: &slots, challengers: &slotChallengers
                )
            }
        }
        // The resolution cache holds answers built without any of this in it.
        resolved.removeAll(keepingCapacity: true)
        dirty = true
        lock.unlock()
        return !matches
    }

    /// Which slot a vehicle's working falls in, for a caller about to `learn`.
    public func slot(for vehicle: VehicleSnapshot) -> TimeSlot? {
        lock.lock(); defer { lock.unlock() }
        return slot(of: vehicle)
    }

    /// Count this observation, without letting a single different working
    /// replace what has been seen more often.
    ///
    /// Generic over the key, and static, because the rule is the same rule
    /// whether it is being applied to a line or to one hour of one line — and
    /// having written it twice would have been the surest way to end up with
    /// two subtly different ideas of what beats what. Static so the two
    /// dictionaries can be handed in as `inout` without the compiler having to
    /// reason about overlapping access to `self`.
    static func tally<Key: Hashable>(
        _ incoming: LayoutRecord, at key: Key,
        incumbents: inout [Key: LayoutRecord], challengers: inout [Key: LayoutRecord]
    ) {
        if var incumbent = incumbents[key], sameFormation(incumbent, incoming) {
            incumbent.count += 1
            incumbent.seen = incoming.seen
            incumbents[key] = incumbent
            return
        }
        if var rival = challengers[key], sameFormation(rival, incoming) {
            rival.count += 1
            rival.seen = incoming.seen
            if let incumbent = incumbents[key], beats(rival, incumbent) {
                incumbents[key] = rival
                challengers[key] = incumbent
            } else {
                challengers[key] = rival
            }
            return
        }
        if incumbents[key] == nil {
            incumbents[key] = incoming
            return
        }
        if let incumbent = incumbents[key], beats(incoming, incumbent) {
            incumbents[key] = incoming
            challengers[key] = incumbent
            return
        }
        challengers[key] = incoming
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

        // The class name, read once. Everything below that used to parse the
        // string separately now reads a field off this — which is how the deck
        // line, the gauge and the nose came to be able to disagree with each
        // other about the same vehicle, each having its own copy of the rules.
        let type = WagonType(coach.typeName)
        let traits = type.map(WagonCatalogue.traits(of:)) ?? .unknown

        // The register's own length wherever it has one, which is the whole
        // reason a fetched formation draws better than a guessed one: a real
        // 26.4 m coach next to a real 18.7 m one is a difference the map can
        // show and the library can only average over.
        let length = coach.length.flatMap { $0 > 4 && $0 < 60 ? $0 : nil }
            ?? (kind == .locomotive ? 18.5 : kind == .van ? 18.0 : traits.length)

        return VehicleUnit(
            kind: kind, length: length,
            width: traits.width,
            cabFront: cabFront, cabBack: cabBack,
            // Only on a vehicle that pulls. A driving trailer has a cab and no
            // pantograph — it is the unpowered end of the train — so putting
            // one on every end car drew a Bt as though it were a railcar.
            pantographs: kind == .locomotive
                ? 2 : (selfPowered && (leading || trailing) ? 1 : 0),
            doubleDeck: traits.doubleDeck,
            band: band, doors: kind == .locomotive ? 0 : 2,
            closed: coach.isClosed, joint: joint,
            // The service says what is inside a coach and never what it looks
            // like, so the shape of the nose has to come off the class name —
            // and without it a formation the app had *learned* was drawn worse
            // than the one it had guessed: an ICE looked up by tapping it lost
            // the long nose the library gives it untapped.
            nose: (cabFront || cabBack) ? traits.nose : nil,
            // The evidence, kept. Everything above is a reading of this, and a
            // reading can be improved; the name cannot be recovered once it has
            // been thrown away.
            type: type
        )
    }

    // MARK: - Reading a class name
    //
    // All of this used to live here, five static functions each parsing the
    // same register string its own way. It lives in `WagonCatalogue` now, for
    // one reason: the string is stored on the unit, so the reading has to be
    // something the app can do at any time rather than only at the moment a
    // formation arrives. What is left are the two spellings other files call
    // by name, forwarded rather than deleted so nothing outside has to know
    // that the parsing moved.

    /// Whether the class named is one with a cab in it, or nil where the class
    /// is not named at all.
    static func isDrivingStock(_ typeName: String?) -> Bool? {
        WagonType(typeName).flatMap { WagonCatalogue.traits(of: $0).driving }
    }

    /// Public because the formation panel draws the deck line off it: the
    /// question "is this a double-decker" is answered from the class name in
    /// exactly one place, and the side elevation must not answer it a second
    /// way and disagree with the map.
    public static func isDoubleDeck(_ typeName: String?) -> Bool {
        WagonType(typeName).map { WagonCatalogue.traits(of: $0).doubleDeck } ?? false
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
        var loadedSlots: [SlotKey: LayoutRecord] = [:]
        var loadedSlotChallengers: [SlotKey: LayoutRecord] = [:]
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
            for entry in file.slots {
                loadedSlots[entry.key] = entry.record
                if let rival = entry.challenger { loadedSlotChallengers[entry.key] = rival }
            }
        }

        lock.lock()
        records = loaded
        patterns = loadedPatterns
        challengers = loadedChallengers
        slots = loadedSlots
        slotChallengers = loadedSlotChallengers
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
        let heldSlotChallengers = slotChallengers
        // Sorted on the same three fields the key is, so a file written twice
        // from the same knowledge is the same bytes — which is what makes one
        // of these diffable when it is checked in as the bundled seed.
        let hours = slots
            .sorted {
                ($0.key.pattern.operatorName, $0.key.pattern.line, $0.key.slot.weekend ? 1 : 0, $0.key.slot.hour)
                    < ($1.key.pattern.operatorName, $1.key.pattern.line, $1.key.slot.weekend ? 1 : 0, $1.key.slot.hour)
            }
            .map { Slot(key: $0.key, record: $0.value, challenger: heldSlotChallengers[$0.key]) }
        let hadChanges = dirty
        dirty = false
        lock.unlock()

        guard hadChanges || !FileManager.default.fileExists(atPath: url.path) else { return true }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let file = File(version: Self.version, entries: entries, patterns: lines, slots: hours)
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
    ///
    /// 3 is where the stored layout stopped carrying a `Livery` and its units
    /// started carrying a `WagonType`, and where lines gained the per-hour
    /// tier. A version 2 file is not *wrong* — its formations still draw
    /// exactly as they did, since every dimension the drawing needs was already
    /// baked into the units — so rather than discard eight hundred learned
    /// trains, `scripts/migrate-vehicle-layouts.py` lifts one to this version.
    /// What it cannot invent is the class names, which version 2 never stored;
    /// those fill in as each train is next observed.
    static let version = 3

    /// How long a "the service has nothing for this train" note stands.
    static let silenceLife: TimeInterval = 7 * 24 * 3600

    struct File: Codable {
        var version: Int
        var entries: [Entry]
        /// Absent in a file written before lines were learned as well as
        /// workings, which the version check already rejects — defaulted so a
        /// hand-written seed need not carry an empty array.
        var patterns: [Pattern] = []
        /// What each line runs at each hour. Defaulted for the same reason, and
        /// legitimately empty for a long time after the format arrives: a slot
        /// is only written once a train has actually been observed in it, and
        /// until then every hour falls through to `patterns`.
        var slots: [Slot] = []
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

    /// One line at one hour of one kind of day.
    struct Slot: Codable {
        var key: SlotKey
        var record: LayoutRecord
        /// The losing formation for this hour. Rarer than the line-wide one and
        /// kept for the same reason: an hour whose stock genuinely changes has
        /// to be able to change, without one relief working doing it.
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
