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

/// What is known about one train: what it was made of, and how often.
///
/// Three things, which is all the database turned out to need. The wagons it
/// was made of, front first — as class names, not as a drawing. How many
/// observations have agreed. When it was last seen.
///
/// Everything else that used to be here was either a deduction or a copy.
/// The formation was stored as a finished drawing, fourteen fields per
/// vehicle, thirteen of them read off the class name at the moment it arrived
/// and then frozen; `WagonCatalogue.units` remakes all of them on demand, so
/// a better reading now reaches records written months ago. A separate
/// `matchedLibrary` flag existed only because a confirmation was stored as an
/// absence rather than as a formation — now that every sighting writes its
/// wagons down, "the guess held up" is simply an observation like any other,
/// and the counting below no longer needs a special case for it.
public struct LayoutRecord: Sendable, Codable, Equatable {
    /// The vehicles, in the direction of travel, front first.
    ///
    /// Empty means the service was asked and had nothing — see `isSilence`.
    public var wagons: [StoredWagon]
    /// When the service last answered about this train.
    public var seen: Date
    /// How many observations have agreed with this record.
    ///
    /// The reason a single odd working of the S42 cannot overwrite the line:
    /// the usual four-car set has been seen fifty times, the strengthened one
    /// once, and the count is what tells them apart.
    public var count: Int

    public init(wagons: [StoredWagon], seen: Date, count: Int = 1) {
        self.wagons = wagons
        self.seen = seen
        self.count = count
    }

    /// How many vehicles the service said it had — the one number worth
    /// showing a reader as evidence, and now simply a fact about the list
    /// rather than a field that could disagree with it.
    public var units: Int { wagons.count }

    /// Whether this is a record of the service having nothing to say.
    ///
    /// Worth keeping, and worth keeping apart from a sighting. The map asks
    /// about the trains in view a few at a time, and about a third of what it
    /// asks about — a working the realtime system has not filed, a train that
    /// is not running today — comes back empty. Without a note of that, every
    /// sweep asks the same questions again and the quota goes on silences.
    public var isSilence: Bool { wagons.isEmpty }

    enum CodingKeys: String, CodingKey { case wagons = "w", seen = "s", count = "c" }
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
    /// What each class of stock has been measured at, by family.
    ///
    /// Kept apart from the formations on purpose. A length belongs to the
    /// class, not to the working: a `RABe 515` car is the same length on every
    /// train that has one, so it is worth storing once rather than once per
    /// wagon per working — which is what the old per-unit dimensions were.
    /// A few hundred numbers against six and a half thousand.
    private var classes: [String: ClassFacts] = [:]
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

    /// How many lines have a formation on file.
    ///
    /// Not "how many have a *correction*", which is what this counted while a
    /// confirmation was stored as an absence. Every sighting is written down
    /// now, agreeing ones included, so what this answers is how many lines the
    /// app has ever been told about — which is the more useful number and the
    /// one the offline sheet was already labelling it as.
    public var patternCount: Int {
        lock.lock(); defer { lock.unlock() }
        return patterns.values.filter { !$0.isSilence }.count
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
        // This journey's own drawing is held exactly as the service gave it,
        // measured lengths and all, so the train somebody has tapped is drawn
        // from the register rather than from a class average. The tiers behind
        // it are stored as names and rebuilt here.
        let exact = learnedKey.flatMap { journeys[$0] }
        let remembered: [StoredWagon]? = exact != nil ? nil : pattern.flatMap { key in
            slot.flatMap { slots[SlotKey(pattern: key, slot: $0)]?.wagons }
                ?? patterns[key]?.wagons
        }
        let knownClasses = remembered == nil ? [:] : classes
        lock.unlock()

        let paint = LayoutLibrary.livery(
            operatorName: vehicle.operatorName, mode: vehicle.mode,
            modeColour: modeColour, variant: variant
        )
        // What the library thinks this line runs. Wanted either way: as the
        // answer when nothing has been learned, and as the shape to lend to a
        // remembered formation whose wagons have no class names — see the
        // `like:` parameter on `WagonCatalogue.units`.
        let guess = LayoutLibrary.layout(
            mode: vehicle.mode, category: vehicle.category, line: vehicle.line,
            operatorName: vehicle.operatorName, modeColour: modeColour, variant: variant
        )
        let learned = exact ?? remembered.flatMap {
            WagonCatalogue.layout(
                of: $0, livery: paint, like: Self.representative(of: guess),
                measured: knownClasses
            )
        }
        let answer = learned?.painted(paint) ?? guess

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

    /// The body most typical of a train, for lending to a nameless wagon.
    ///
    /// The middle one, not the first. The leading vehicle of nearly every Swiss
    /// train is the odd one out — a locomotive, a driving trailer, an end car
    /// with a nose on it — and lending *that* to a rake would draw a train of
    /// six locomotives. What is wanted is the ordinary coach in the middle,
    /// which is what most of the train is made of.
    static func representative(of layout: VehicleLayout) -> VehicleUnit? {
        let coaches = layout.units.filter { $0.kind != .locomotive }
        guard !coaches.isEmpty else { return layout.units.first }
        return coaches[coaches.count / 2]
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

    /// What a class of stock has been measured at, for anything that wants to
    /// know without going through a formation.
    public func facts(forClass family: String) -> ClassFacts? {
        lock.lock(); defer { lock.unlock() }
        return classes[family]
    }

    /// How many classes of stock have been measured.
    public var classCount: Int {
        lock.lock(); defer { lock.unlock() }
        return classes.count
    }

    /// How many line-and-hour combinations have been observed.
    public var slotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return slots.count
    }

    /// Note that the service was asked about this train and had nothing.
    public func noteSilence(key: LayoutKey, at moment: Date) {
        lock.lock()
        records[key] = LayoutRecord(wagons: [], seen: moment)
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
        let paint = LayoutLibrary.livery(
            operatorName: operatorName, mode: mode, modeColour: modeColour
        )
        // What the service actually said, kept exactly, with the register's own
        // measured lengths in it. This is the drawing for *this* journey and it
        // is never written to disk — see `journeys`.
        guard let observed = Self.layout(from: formation, at: moment, livery: paint)
        else { return false }

        // What goes on file: the names, and nothing that can be deduced from
        // them. `WagonCatalogue.units` puts the rest back at drawing time.
        let wagons = Self.wagons(from: formation, at: moment)
        guard !wagons.isEmpty else { return false }

        let guess = LayoutLibrary.layout(
            mode: mode, category: category, line: line,
            operatorName: operatorName, modeColour: modeColour
        )
        let matches = guess.drawsAlike(observed)

        let incoming = LayoutRecord(wagons: wagons, seen: moment, count: 1)

        // What the register measured, filed against the class rather than the
        // train. This is the only place a real dimension enters the database,
        // and it is what lets a NINA stop being drawn at intercity length.
        let measurements = Self.measurements(from: formation, at: moment)

        lock.lock()
        for (family, metres) in measurements {
            classes[family] = classes[family]?.adding(metres) ?? ClassFacts(length: metres)
        }
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
            // On a tie, the formation the library already expects wins. That
            // is what lets a line stop being drawn short: one odd working and
            // one normal one is one sighting each, and without the tiebreak the
            // odd one would hold the line for having got there first.
            // Judged on what will actually be drawn, which means parsing the
            // stored names exactly as the draw path does — the library's own
            // body lent to any wagon the register did not name. Without the
            // loan a formation of nameless wagons came out as a rake of 26.4 m
            // coaches, matched nothing, and the tie never broke.
            let template = Self.representative(of: guess)
            let known = classes
            let agrees: (LayoutRecord) -> Bool = { record in
                WagonCatalogue.layout(
                    of: record.wagons, livery: paint, like: template, measured: known
                ).map(guess.drawsAlike) ?? false
            }
            Self.tally(
                incoming, at: pattern, incumbents: &patterns,
                challengers: &challengers, agreesWithLibrary: agrees
            )
            if let slot {
                Self.tally(
                    incoming, at: SlotKey(pattern: pattern, slot: slot),
                    incumbents: &slots, challengers: &slotChallengers,
                    agreesWithLibrary: agrees
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
        incumbents: inout [Key: LayoutRecord], challengers: inout [Key: LayoutRecord],
        agreesWithLibrary: (LayoutRecord) -> Bool = { _ in false }
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
            if let incumbent = incumbents[key], beats(rival, incumbent, agreesWithLibrary) {
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
        if let incumbent = incumbents[key], beats(incoming, incumbent, agreesWithLibrary) {
            incumbents[key] = incoming
            challengers[key] = incumbent
            return
        }
        challengers[key] = incoming
    }

    /// Whether two records describe the same formation, for counting.
    ///
    /// A list of class names compared for equality, which is the whole of it.
    /// This used to compare two finished drawings with a tolerance on every
    /// length and a special case for "the library was right", because a
    /// confirmation was stored as the *absence* of a formation. Storing what
    /// was seen either way turned the question back into the simple one it
    /// always was: were these the same vehicles, in the same order.
    static func sameFormation(_ a: LayoutRecord, _ b: LayoutRecord) -> Bool {
        a.wagons == b.wagons
    }

    /// Whether a rival should replace the line's usual formation.
    ///
    /// Strictly more sightings, with a tie going to whichever formation the
    /// library already expects — so one short-formed train and one normal one
    /// leaves the line drawn as the library thought, which is the case a
    /// correction that is no longer needed must not survive.
    static func beats(
        _ rival: LayoutRecord, _ incumbent: LayoutRecord,
        _ agreesWithLibrary: (LayoutRecord) -> Bool = { _ in false }
    ) -> Bool {
        if rival.count > incumbent.count { return true }
        if rival.count < incumbent.count { return false }
        return agreesWithLibrary(rival) && !agreesWithLibrary(incumbent)
    }

    /// The formation as a drawing, exactly as the service gave it.
    ///
    /// The same parse every stored formation goes through, with the two things
    /// the register knows and a class name cannot laid over the top: how long
    /// this particular vehicle measured, and whether it is shut to passengers
    /// today. Neither is written down — a length belongs to the class closely
    /// enough for every other working of the line, and "shut today" is not a
    /// fact about the line at all — so this is the one drawing in the app that
    /// is better than what the database can reconstruct, and it is used for the
    /// one train that has actually been looked up.
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

        var units = WagonCatalogue.units(from: wagons(from: formation, at: moment))
        // Both lists come from the same stop's coaches, so they are the same
        // length; the guard is here so that a future change which breaks that
        // gives up rather than pairing a coach with somebody else's body.
        guard units.count == stop.coaches.count else { return nil }

        for (index, coach) in stop.coaches.enumerated() {
            // The register's own length wherever it has one, which is what
            // makes a fetched formation draw better than a remembered one: a
            // real 26.4 m coach next to a real 18.7 m one is a difference the
            // map can show and a class average can only smooth over.
            if let measured = coach.length, measured > 4, measured < 60 {
                units[index].length = measured
            }
            units[index].closed = coach.isClosed
        }

        return VehicleLayout(
            units: units, livery: livery,
            name: WagonCatalogue.name(units: units), source: .observed
        ).resolvingStripes()
    }

    /// What this formation measured, by class.
    ///
    /// One entry per class rather than per vehicle: eight cars of the same
    /// class in one train are one measurement of that class, not eight, or a
    /// long train would outvote every other sighting of the stock in it.
    static func measurements(
        from formation: TrainFormation, at moment: Date
    ) -> [String: Double] {
        let stops = formation.stops.filter { !$0.isEmpty }
        guard let stop = stops.min(by: { $0.distance(from: moment) < $1.distance(from: moment) })
            ?? stops.first
        else { return [:] }

        var found: [String: [Double]] = [:]
        for coach in stop.coaches {
            guard let type = WagonType(coach.typeName),
                  let metres = ClassFacts.plausible(coach.length)
            else { continue }
            found[type.family, default: []].append(metres)
        }
        // The middle measurement of the class within this train, so one coach
        // filed with the length of the whole rake does not carry the class.
        return found.compactMapValues { lengths in
            lengths.isEmpty ? nil : lengths.sorted()[lengths.count / 2]
        }
    }

    /// The vehicles of a train, as names to be written down.
    ///
    /// Read at the stop nearest the moment asked about, for the same reason
    /// `layout(from:at:livery:)` is: a train that splits is not the same train
    /// before and after, and taking the first stop would file the whole train
    /// as what it is only until it divides.
    static func wagons(from formation: TrainFormation, at moment: Date) -> [StoredWagon] {
        let stops = formation.stops.filter { !$0.isEmpty }
        guard let stop = stops.min(by: { $0.distance(from: moment) < $1.distance(from: moment) })
            ?? stops.first
        else { return [] }

        // Where the train is really two trains, which the service states and
        // the map used to throw away. Read from both sides of the join because
        // it is published twice and not always consistently — the same reading
        // the coach strip in the panel has always made, so the two drawings of
        // one train now agree about how many trains it is. See
        // `FormationView.naturalLayout` and `StoredWagon.startsUnit`.
        let coaches = stop.coaches
        return coaches.indices.map { index in
            // The service's own code alongside the register's name. It states
            // what a name can only imply — which vehicle is the engine, which
            // car of a unit is the first-class one — and neither is knowable
            // from the name of a `RABe 511` whose every car is a `RABe 511`.
            StoredWagon(
                type: WagonType(coaches[index].typeName), kind: coaches[index].kind,
                startsUnit: index > 0
                    && (coaches[index].noAccessForward || coaches[index - 1].noAccessBackward)
            )
        }
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
        var loadedClasses: [String: ClassFacts] = [:]
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
            for entry in file.classes { loadedClasses[entry.family] = entry.facts }
        }

        lock.lock()
        records = loaded
        patterns = loadedPatterns
        challengers = loadedChallengers
        slots = loadedSlots
        slotChallengers = loadedSlotChallengers
        classes = loadedClasses
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
        let stock = classes
            .sorted { $0.key < $1.key }
            .map { Stock(family: $0.key, facts: $0.value) }
        let hadChanges = dirty
        dirty = false
        lock.unlock()

        guard hadChanges || !FileManager.default.fileExists(atPath: url.path) else { return true }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let file = File(
            version: Self.version, entries: entries, patterns: lines,
            slots: hours, classes: stock
        )
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
    /// tier. 4 is where a unit stopped writing down the fields that hold their
    /// default — which took the bundled database from 1.4 MB to 640 kB without
    /// losing a fact, since an absent field is one that was ordinary.
    ///
    /// Neither older file is *wrong*: its formations still draw exactly as they
    /// did, because every dimension the drawing needs was already baked into
    /// the units. So rather than discard eight hundred learned trains,
    /// `scripts/migrate-vehicle-layouts.py` lifts a version 2 or 3 file to this
    /// one. What it cannot invent is the class names, which version 2 never
    /// stored; those fill in as each train is next observed.
    static let version = 5

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
        /// What each class of stock has been measured at. A few hundred numbers
        /// that make every formation in the file draw at the right length.
        var classes: [Stock] = []

        init(
            version: Int, entries: [Entry], patterns: [Pattern] = [],
            slots: [Slot] = [], classes: [Stock] = []
        ) {
            self.version = version
            self.entries = entries
            self.patterns = patterns
            self.slots = slots
            self.classes = classes
        }

        /// Every list but `entries` is optional, and written by hand rather
        /// than synthesised because a default value does not make a synthesised
        /// decoder tolerant of a missing key — it still throws, the file is
        /// rejected whole, and a store that rejects its seed looks exactly like
        /// one that has forgotten everything it was ever told. That is how
        /// adding `classes` silently emptied a database of eight hundred
        /// trains, and it is worth one explicit initialiser to make the next
        /// addition harmless.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
            patterns = try c.decodeIfPresent([Pattern].self, forKey: .patterns) ?? []
            slots = try c.decodeIfPresent([Slot].self, forKey: .slots) ?? []
            classes = try c.decodeIfPresent([Stock].self, forKey: .classes) ?? []
        }
    }

    /// One class of rolling stock, and what it measures.
    struct Stock: Codable {
        var family: String
        var facts: ClassFacts
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
