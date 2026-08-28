import Foundation

// What a wagon *is*, kept apart from what it looks like.
//
// The learned database used to write down a drawing: bodies with lengths, and
// a `Livery` beside them. Both halves of that were wrong in the same way.
//
// The livery was wrong because it is not a fact about the train. Paint belongs
// to the company, and the company is known from the journey without asking
// anybody — so every stored layout carried six colour strings that were
// recomputed and overwritten the moment they were read back (see
// `VehicleLayoutStore.layout(for:modeColour:)`, which has always ended in
// `.painted(paint)`). A repaint of a fleet made every record on disk wrong
// about something the record had no business holding.
//
// The dimensions were wrong in the subtler direction. They are *derived*: the
// register says a vehicle is an `RABe511_6_1` or a `Bt(2E)Fam`, and everything
// the drawing wants — how long, how wide, double-deck or not, what shape the
// nose is, whether anybody drives from that end — was read off that string at
// the moment the formation arrived and then thrown away. So the database
// remembered the conclusions and forgot the evidence, which meant a better
// reading of the same names could never be applied to anything already stored.
// Improving the deck-detection rule fixed only trains nobody had looked up yet.
//
// So what is stored now is the register's own word for each vehicle, and this
// file is the part that reads it. `WagonType` is the name, canonicalised once.
// `WagonTraits` is what the name implies about the shape. `WagonCatalogue` is
// the reading, and the one place a class name is interpreted — which is what
// lets the interpretation improve without a migration, because the names on
// disk do not change when the rules for reading them do.

/// A class of rolling stock, as the register names it.
///
/// Held as a string rather than as an enumeration on purpose. The register
/// names several hundred classes and gains more; an enumeration would turn
/// every unfamiliar one into `.unknown` and lose the only evidence there was.
/// A string that does not parse is still a string that can be parsed better
/// next year, and still tells a reader what the train was made of.
public struct WagonType: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The name as the register wrote it, upper-cased and stripped of the
    /// separators it is inconsistent about.
    ///
    /// The register writes the same class as `RABe 511`, `RABe511` and
    /// `RABe511_6_1` depending on which half of the response it came from, and
    /// three spellings of one class is three entries in the database for one
    /// train. Folding at the door is what stops that.
    public let raw: String

    /// Nil where the register said nothing, which is common enough to be the
    /// reason this is failable rather than a fatal error: a train the realtime
    /// system knows and the rolling-stock register does not comes through with
    /// its formation intact and its class names missing.
    public init?(_ name: String?) {
        guard let name else { return nil }
        // Whitespace and dashes go; underscores stay. The register uses an
        // underscore to mark a car's position in a set — `RABe511_6_3` is car
        // three of a six-car 511 — and dropping it ran the numbers together
        // into `RABE51163`, which is the same string to a computer and
        // unreadable to the person the stored evidence is for.
        let folded = name.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard !folded.isEmpty else { return nil }
        self.raw = folded
    }

    /// For a string already known to be canonical.
    private init(canonical: String) { self.raw = canonical }

    /// This type reduced to the identity that decides a shape and a paint.
    ///
    /// What goes in a `VehicleModelKey`, and nothing else should. A mesh is
    /// baked once per distinct key and kept for the life of the process, so a
    /// key that carries the *raw* name bakes one copy of the same coach for
    /// every position it can occupy in a set — eight identical Mutz cars, or a
    /// sixteen-coach train that used to be two meshes becoming sixteen. See
    /// `family`.
    public var canonical: WagonType { WagonType(canonical: family) }

    public var description: String { raw }

    /// What this class implies about the shape drawn for it.
    public var traits: WagonTraits { WagonCatalogue.traits(of: self) }

    /// The coarse identity that decides a mesh and a paint.
    ///
    /// Not `raw`, and the difference is the whole reason this exists. A solid
    /// wagon is baked once per distinct `VehicleModelKey` and kept — see
    /// `VehicleModel` — and the key contains the unit, so anything that varies
    /// between two wagons that look identical multiplies the meshes for
    /// nothing. The register varies plenty: an eight-car Mutz arrives as
    /// `RABe515_6_1` through `RABe515_6_8`, which is eight names, one shape and
    /// — keyed on the raw name — eight copies of one mesh.
    ///
    /// So the family drops the position suffix and keeps the two things that
    /// genuinely change the drawing: the class itself and whether it is
    /// double-deck. `RABE511_6_1` and `RABE511_6_4` are one family;
    /// `A` and `A(2E)` are two, because one of them has another floor.
    public var family: String { WagonCatalogue.family(of: self) }
}

/// One wagon, as the database remembers it.
///
/// The whole of what is now written down about a vehicle, and it is worth being
/// blunt about how little that is. A stored unit used to be fourteen fields —
/// length, width, cabs, doors, pantographs, deck, joint, nose, stripe — and
/// thirteen of them were *deductions*, made once from the class name and the
/// vehicle's place in the train, then repeated on disk for every vehicle of
/// every train in the country. Six and a half thousand of them came to most of
/// a megabyte of the app saying what a coach already is.
///
/// So the deductions are gone and the evidence stays. `WagonCatalogue.units`
/// makes all of them again at the moment of drawing, which is both smaller and
/// strictly better: improve the reading of a name and every record ever
/// stored improves with it, including ones written by an older build.
///
/// Two fields, not one, and the second earns its place twice over.
///
/// The register's name is silent about things the *service* states outright.
/// It does not always say which vehicle is the locomotive — a rake can come
/// back with every vehicle, engine included, named the same thing — and it
/// cannot say which car of a multiple unit is the first-class one, because
/// every car of a `RABe 511` is called a `RABe 511`. Both were being read off
/// the name, and both were wrong: an engine drawn as a coach, and a whole
/// train drawn as half first class.
///
/// So the service's own word for the vehicle is kept beside the name. One
/// short enum — `LK`, `2`, `12`, `WR` — which carries the class, the
/// locomotive and the luggage van in a single field, and which the name is
/// only consulted about when it is missing.
public struct StoredWagon: Sendable, Codable, Hashable {
    /// The register's name for this vehicle — `RABe511_6_3`, `Bpm`, `A(2E)`.
    /// Nil for a train the realtime system has and the register does not.
    public var type: WagonType?
    /// What the formation service called it. Nil falls back to reading the
    /// name — see `WagonCatalogue.band(of:)` and `kind(of:)`.
    public var kind: CoachKind?

    public init(type: WagonType?, kind: CoachKind? = nil) {
        self.type = type
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case type = "t", kind = "k" }

    /// Written short, because there are thousands of these and the long
    /// spellings were the file.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(kind, forKey: .kind)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(WagonType.self, forKey: .type)
        kind = try c.decodeIfPresent(CoachKind.self, forKey: .kind)
    }
}

/// What has actually been measured about a class of stock.
///
/// The one number the catalogue cannot read off a name. `A(2E)` says
/// double-deck and `RABe 525` says a three-car NINA, but neither says how long
/// a car is, and the difference is not small: every multiple unit in the
/// country was being drawn at intercity-coach length, which turns a 47-metre
/// NINA into 79 metres of train. Length is the one thing a top view can say
/// that a dot cannot, so getting it wrong is most of the drawing being wrong.
///
/// Guessing a table of them would have been worse than the average it replaced
/// — a few hundred classes, hand-written from memory, confidently wrong. The
/// register sends a real measurement with every formation, so this is learned
/// instead, and it belongs to the *class* rather than to the formation: a
/// `RABe 515` car is the same length on every train that has one, so it is
/// stored once and not once per wagon per working.
public struct ClassFacts: Sendable, Codable, Equatable {
    /// Mean body length over couplers, in metres.
    public var length: Double
    /// How many vehicles have gone into that mean.
    ///
    /// A mean rather than the last value seen, because the register is not
    /// perfect: a coach occasionally comes through with a length that belongs
    /// to the whole train or to nothing at all, and one of those should move
    /// the answer a little rather than replace it.
    public var count: Int

    public init(length: Double, count: Int = 1) {
        self.length = length
        self.count = count
    }

    /// This class, having seen one more vehicle of it.
    public func adding(_ measured: Double) -> ClassFacts {
        // Capped so a class the app has watched all year still moves when the
        // stock genuinely changes, and so the arithmetic cannot drift.
        let weight = min(count, 50)
        return ClassFacts(
            length: (length * Double(weight) + measured) / Double(weight + 1),
            count: count + 1
        )
    }

    /// Whether a length the register gave is worth believing.
    ///
    /// A vehicle shorter than a car or longer than two coaches is the register
    /// answering a different question — the length of the whole train, or a
    /// field left at zero.
    public static func plausible(_ metres: Double?) -> Double? {
        guard let metres, metres > 4, metres < 60 else { return nil }
        return metres
    }
}

/// What a class name says about the vehicle it names.
///
/// Every field here was already being computed — scattered across five static
/// functions on `VehicleLayoutStore`, each parsing the same string a slightly
/// different way. Gathered into one value so the string is read once and the
/// answers cannot disagree with each other.
public struct WagonTraits: Sendable, Hashable {
    /// Two floors, which from above is a wider roof and no deep window recess.
    public var doubleDeck: Bool
    /// Body width in metres, which on a top view is the only place the gauge
    /// shows.
    public var width: Double
    /// The shape of the driving end, where the class decides it. Nil means
    /// "whatever the kind implies", which is what nearly every class wants.
    public var nose: Nose?
    /// Whether somebody drives from this vehicle. Nil where the name is not one
    /// the table knows, which is a different answer from "no" — see
    /// `VehicleLayoutStore.layout(from:at:livery:)`, where a `nil` at the end
    /// of a hauled rake means "assume the driving trailer that is nearly always
    /// there" and a `false` means "the register says otherwise".
    public var driving: Bool?
    /// Body length over couplers, for a class the formation did not measure.
    public var length: Double
    /// Whether this is a vehicle that pulls, and so one painted in the
    /// company's locomotive colours rather than its coaching ones.
    public var powered: Bool
    /// What shape family the class belongs to.
    ///
    /// The field that turned this table from a description of a *box* into a
    /// description of a vehicle. Everything else here — how long, how wide, two
    /// floors or one — could be satisfied by an extrusion, and for a long time
    /// was: every wagon in the country was one box with a bevel on the front.
    /// This is what says which box, and `Silhouette` is where the answer is
    /// spelled out.
    public var silhouette: Silhouette

    public static let unknown = WagonTraits(
        doubleDeck: false, width: VehicleUnit.standardGaugeWidth, nose: nil,
        driving: nil, length: 26.4, powered: false, silhouette: .generic
    )
}

/// The reading of a class name: the one place in the app that interprets one.
///
/// Everything here is a pure function of the string, which is what makes the
/// database durable. A stored formation is a list of names; what those names
/// mean is decided here, at the moment of drawing, by whatever version of the
/// app is doing the drawing. A better rule improves every record ever stored,
/// including the ones written by an older build, without touching the file.
public enum WagonCatalogue {

    // MARK: - The cache
    //
    // Parsing is cheap and doing it per wagon per frame is not. The traits of a
    // class are constant for the life of the process — it is a string table
    // lookup with a fixed answer — so they are worked out once and kept.
    //
    // Behind a lock rather than in an actor for the reason the layout store is:
    // this is read from the draw path, and an `await` per wagon per frame to
    // reach a dictionary is the wrong shape entirely. The critical section is a
    // dictionary lookup.

    private static let lock = NSLock()
    private nonisolated(unsafe) static var traitCache: [String: WagonTraits] = [:]
    private nonisolated(unsafe) static var familyCache: [String: String] = [:]

    /// A bound rather than a measurement. The country has a few hundred classes
    /// in traffic; anything past this is a name being generated rather than
    /// looked up, and an unbounded cache reachable from a draw loop is a leak
    /// waiting for a long day.
    private static let cacheLimit = 2_000

    public static func traits(of type: WagonType) -> WagonTraits {
        lock.lock()
        if let held = traitCache[type.raw] { lock.unlock(); return held }
        lock.unlock()

        let computed = parse(type.raw)

        lock.lock()
        if traitCache.count > cacheLimit { traitCache.removeAll(keepingCapacity: true) }
        traitCache[type.raw] = computed
        lock.unlock()
        return computed
    }

    static func family(of type: WagonType) -> String {
        lock.lock()
        if let held = familyCache[type.raw] { lock.unlock(); return held }
        lock.unlock()

        let computed = foldFamily(type.raw)

        lock.lock()
        if familyCache.count > cacheLimit { familyCache.removeAll(keepingCapacity: true) }
        familyCache[type.raw] = computed
        lock.unlock()
        return computed
    }

    // MARK: - The reading

    /// Everything one class name implies, worked out in a single pass.
    static func parse(_ raw: String) -> WagonTraits {
        let deck = isDoubleDeck(raw)
        let powered = isPowered(raw)
        let shape = silhouette(raw, powered: powered, doubleDeck: deck)
        return WagonTraits(
            doubleDeck: deck,
            width: isMetreGauge(raw) ? VehicleUnit.metreGaugeWidth : VehicleUnit.standardGaugeWidth,
            // The class's own nose where the table names one; otherwise
            // whatever the shape family implies, which is where nearly every
            // answer now comes from. Kept as two fields rather than folded into
            // one because they answer different questions: `nose` is an
            // override a caller may set, and the silhouette is what the class
            // *is*. See `VehicleShape.profiles`.
            nose: nose(raw) ?? shape.nose,
            driving: isDrivingStock(raw),
            length: defaultLength(raw, powered: powered, doubleDeck: deck),
            powered: powered,
            silhouette: shape
        )
    }

    /// The class, without the position of one car within a set.
    ///
    /// `RABE511_6_1` is the first car of a six-car 511; the underscores are
    /// already gone by the time this sees it, so what arrives is `RABE5116 1`
    /// — no, `RABE51161`. The digits after the class number are the set and the
    /// position within it, and neither changes the shape.
    ///
    /// So: take the leading letters, then the first run of digits, and stop.
    /// Anything in brackets that says `2E` is kept, because another floor is
    /// not a detail.
    static func foldFamily(_ raw: String) -> String {
        var letters = ""
        var digits = ""
        var index = raw.startIndex
        while index < raw.endIndex, raw[index].isLetter {
            letters.append(raw[index])
            index = raw.index(after: index)
        }
        while index < raw.endIndex, raw[index].isNumber {
            digits.append(raw[index])
            index = raw.index(after: index)
        }
        // A class with no letters at all is not a class name; keep it whole
        // rather than folding it to nothing and merging it with every other
        // unreadable string.
        guard !letters.isEmpty else { return raw }
        // The set number of a multiple unit runs on past the class — `RABE511`
        // is the class and the `61` after it is the set and the car. Three
        // digits is every Swiss class number worth naming (`460`, `511`, `502`)
        // and two covers the older ones (`4/4` has already lost its slash).
        let number = digits.count > 3 ? String(digits.prefix(3)) : digits
        return letters + number + (isDoubleDeck(raw) ? "(2E)" : "")
    }

    /// Public because the formation panel draws the deck line off it: the
    /// question "is this a double-decker" is answered from the class name in
    /// exactly one place, and the side elevation must not answer it a second
    /// way and disagree with the map.
    public static func isDoubleDeck(_ raw: String) -> Bool {
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
        raw.contains("(2E") || raw.contains("DD")
            || raw.hasPrefix("RABE502") || raw.hasPrefix("RABDE502")
            || raw.hasPrefix("RABE511") || raw.hasPrefix("RABE512")
            || raw.hasPrefix("RABE514") || raw.hasPrefix("RABE515")
            || raw.hasPrefix("RABE516")
    }

    static func isMetreGauge(_ raw: String) -> Bool {
        // The fold takes out spaces, underscores and dashes and leaves the
        // slash, because a slash is part of how these classes are written and
        // not punctuation between two halves of a name: `ABe 8/12` folds to
        // `ABE8/12`. Both spellings are matched anyway — the register is not
        // consistent enough to be trusted on it, and the class that arrives as
        // `ABe812` is the same tram either way.
        for prefix in ["ABE8/12", "ABE812", "ABE4/16", "ABE416"] where raw.hasPrefix(prefix) {
            return true
        }
        // `Ge`, `Beh` and `ABeh` are metre gauge wherever they appear — the
        // RhB, the Zentralbahn and the mountain railways.
        return raw.hasPrefix("GE") || raw.hasPrefix("BEH") || raw.hasPrefix("ABEH")
    }

    /// Whether the class named is one with a cab in it, or nil where the class
    /// is not one the table knows.
    static func isDrivingStock(_ raw: String) -> Bool? {
        guard !raw.isEmpty else { return nil }
        // Longest first: `ABT` and `ABE` both start with `AB`, and `BT` is a
        // prefix of nothing but itself.
        for prefix in drivingPrefixes where raw.hasPrefix(prefix) { return true }
        return false
    }

    private static let drivingPrefixes: [String] = [
        "RABDE", "RABE", "RBDE", "RBE", "ABE", "BDE", "ETR", "ICE", "TGV",
        "ABT", "BDT", "BT", "AT",
    ].sorted { $0.count > $1.count }

    /// Whether this is a vehicle that pulls.
    ///
    /// The locomotive classes proper — `Re`, `Ee`, `Ge`, `Bm`, `Am` — plus the
    /// power cars of a high-speed set. A driving trailer is emphatically not
    /// one of these: it has a cab and no motor, which is exactly the
    /// distinction that decides whether it is painted in the company's
    /// locomotive colours.
    static func isPowered(_ raw: String) -> Bool {
        // Checked before the locomotive prefixes because `RE` is a prefix of
        // nothing among them but `RABE`/`RBE` start with `R` too — and a
        // multiple unit is self-powered without being a locomotive.
        for prefix in drivingPrefixes where raw.hasPrefix(prefix) { return false }
        return locomotivePrefixes.contains { raw.hasPrefix($0) }
    }

    private static let locomotivePrefixes = [
        "RE", "EE", "GE", "BM", "AM", "TM", "HGE", "DE", "EM",
    ]

    /// The shape of the nose the named class carries, where it has one worth
    /// drawing differently.
    static func nose(_ raw: String) -> Nose? {
        guard !raw.isEmpty else { return nil }
        // The high-speed and tilting sets: an ICE, a TGV, a Giruno, an Astoro
        // and an ICN all end in several metres of unbroken taper.
        let streamlined = ["ICE", "TGV", "ETR", "RABE501", "RABE503", "RABDE500"]
        if streamlined.contains(where: { raw.hasPrefix($0) }) { return .streamlined }
        return nil
    }

    // MARK: - What shape the class is

    /// Which shape family a class name names.
    ///
    /// The table the whole exercise turns on, and it is worth saying what kind
    /// of table it is. It is not a catalogue of Swiss rolling stock — that
    /// would be several hundred rows, most of them guessed, and confidently
    /// wrong is worse than uniformly approximate. It is a list of the
    /// *silhouettes* the country runs, matched by the prefixes that reliably
    /// identify them, with everything unmatched falling through to `.generic`
    /// and being drawn exactly as it always was.
    ///
    /// Order is load-bearing throughout. `RABE511` has to be tested before
    /// `RABE5`, `ABEH` before `ABE`, `WR` before `R`; and the double-deck test
    /// runs first of all, because `Bt(2E)` is a driving trailer whose shape is
    /// decided by the two floors behind the cab rather than by the `Bt`.
    static func silhouette(_ raw: String, powered: Bool, doubleDeck: Bool) -> Silhouette {
        guard !raw.isEmpty else { return .generic }

        /// Whether the name begins with any of these.
        func any(_ prefixes: [String]) -> Bool {
            prefixes.contains { raw.hasPrefix($0) }
        }

        // The high-speed and tilting sets, before anything else looks at them:
        // a `RABe 501` is a multiple unit by every structural test and it is
        // not shaped like one.
        if any(["RABE501", "RABE503", "RABDE500", "ETR"]) { return .highSpeedCar }
        if any(["ICE", "TGV"]) {
            // A power car and a coach of the same set are filed under the same
            // name, and the register does not say which is which. The one that
            // can be told apart is the driving vehicle, and the formation
            // service says so — see `kind(of:)`, which is what actually decides
            // it. This is the passenger body.
            return .highSpeedCar
        }

        // Two floors. Checked before the unit and coach tests because it
        // outranks both: an `AD(2E)` is a coach and a `Bt(2E)` is a driving
        // trailer, and what makes each of them recognisable is the storey.
        if doubleDeck {
            // The units carry their class number; the hauled IC2000 stock is
            // named for what is inside it and nothing else.
            if any(["RABE", "RABDE", "RBDE"]) { return .doubleDeckUnit }
            return .doubleDeckCoach
        }

        // The vehicles that pull. `isPowered` has already excluded every
        // multiple unit and driving trailer, so what is left really is a
        // machine — and the small ones are a different shape from the big ones.
        if powered {
            // A `Tm` is a tractor and an `Ee` is a yard shunter: both are half
            // the height of a main-line locomotive and mostly bonnet.
            if any(["TM", "EE", "EM"]) { return .shunter }
            return .electricLoco
        }

        // Metre gauge, and the mountain.
        //
        // `H` is the letter that matters here: in Swiss practice it marks a
        // rack drive, so `BDhe`, `Bhe`, `ABeh` and `HGe` are all vehicles built
        // to climb. The rack railcars are short, tall and upright — a Rigi
        // BDhe, a Pilatus Bhe, a Jungfrau or Wengernalp car, a Gornergrat Bhe —
        // and drawn as ordinary railcars they were the flattest, longest thing
        // on a mountain that has nothing flat or long on it.
        if any(["BDHE", "BHE", "ABDHE", "BEH", "ABEH2", "ABEH4", "ABEH8", "HE"]) {
            return .rackTrainCar
        }
        // The zb's Fink and Adler, and the RhB's Allegra and Capricorn: modern
        // narrow-gauge units, low and short but not rack railcars.
        if any(["ABEH15", "ABEH16", "ABE8/12", "ABE812", "ABE4/16", "ABE416", "ABEH"]) {
            return .narrowGaugeUnit
        }

        // The multiple units, by class number. Every one of these is a
        // single-deck unit with a low floor and a moulded front; what separates
        // them is which Stadler product it is.
        if any(["RABE526", "RABE527", "RABE528", "RABDE526"]) {
            // The GTW and the Traverso. The power module in the middle of a GTW
            // is a different shape again, and only the formation can say which
            // car it is — see `kind(of:)`.
            return .lowFloorUnit
        }
        if any(["RABE5", "RABDE5", "RBDE5", "RBE5", "RABE4", "RBE4"]) { return .suburbanUnit }
        // A driving trailer takes the shape of the train it is on, and the only
        // thing its name settles is that somebody drives from it. A `Bt` on the
        // front of a Domino set is a suburban cab; the double-deck ones have
        // already been caught above.
        if any(["BT", "ABT", "BDT", "AT"]) { return .suburbanUnit }
        if any(["RABE", "RABDE", "RBDE", "RBE", "ABE", "BDE"]) { return .suburbanUnit }

        // Hauled stock, named for what is inside it.
        if raw.hasPrefix("WR") { return .intercityCoach }
        // Couchettes and sleepers, which run through Switzerland every night on
        // the Nightjet and have small high windows because there are berths
        // behind them.
        if any(["BC", "WL", "AB3", "WLAB", "BCM"]) { return .sleeperCoach }
        // A luggage van is a `D` and nothing else: `AD` is a first-class coach
        // with a compartment in it, and is a coach.
        if raw.hasPrefix("D") { return .luggageVan }
        if any(["A", "B"]) { return .intercityCoach }

        return .generic
    }

    /// How long a vehicle of this class is, for a formation that did not say.
    ///
    /// The register usually gives a real length and that always wins — it is
    /// most of why a fetched formation draws better than a guessed one. This is
    /// the fallback, and it is a fallback worth having: a locomotive drawn at
    /// coach length is the single most obvious thing a top view can get wrong.
    static func defaultLength(_ raw: String, powered: Bool, doubleDeck: Bool) -> Double {
        if powered { return 18.5 }
        if raw.hasPrefix("D") { return 18.0 }
        return doubleDeck ? 26.8 : 26.4
    }

    // MARK: - What the register calls a class

    /// Which class a wagon carries, as far as its name gives it away.
    ///
    /// Swiss stock is named for what is inside it, which is most of why storing
    /// the name is enough to draw from. `A` is first, `B` is second, `AB` is
    /// both, `WR` is the dining car, `D` is the luggage van. A driving trailer
    /// keeps its class letter and adds a `t`, so a `Bt` is a second-class
    /// vehicle somebody drives from.
    ///
    /// The one case it cannot answer is a car *inside* a multiple unit: a
    /// `RABe 511` is a first-and-second-class train, and the name of car three
    /// does not say which of the two that car is. That is why `StoredWagon`
    /// keeps the band the service reported alongside the name rather than
    /// trusting this for everything — this is the fallback, not the authority.
    static func band(of raw: String) -> ClassBand {
        if isPowered(raw) { return .none }
        // Checked first: `WR` would otherwise read as a second-class `R`-
        // something, and the dining car is the one vehicle on a train that a
        // passenger looks for by colour.
        if raw.hasPrefix("WR") || raw.hasPrefix("WRB") { return .dining }

        // Only the letters before the first digit or bracket describe the
        // vehicle; `A4(LBT)` is a first-class coach and the `4` and the tunnel
        // code say nothing about its class.
        var prefix = ""
        for character in raw {
            guard character.isLetter else { break }
            prefix.append(character)
        }
        let first = prefix.contains("A")
        let second = prefix.contains("B")
        switch (first, second) {
        case (true, true): return .mixed
        case (true, false): return .first
        case (false, true): return .second
        case (false, false): return prefix.hasPrefix("D") ? .none : .second
        }
    }

    /// What class the service's own code says the vehicle carries.
    static func band(of kind: CoachKind) -> ClassBand {
        switch kind {
        case .first: return .first
        case .second: return .second
        case .mixed: return .mixed
        case .restaurant, .diningFirst, .diningSecond: return .dining
        case .locomotive, .luggage, .fictitious, .parked: return .none
        case .couchette, .sleeper, .family, .classless: return .second
        }
    }

    /// What kind of body this is, as the outline cares about it.
    ///
    /// The service first, because it states outright what a name can only
    /// imply — and sometimes contradicts. A rake can come back with every
    /// vehicle named the same thing, engine included, and read off the name
    /// alone the locomotive is drawn as one more coach.
    static func kind(of wagon: StoredWagon) -> UnitKind {
        switch wagon.kind {
        case .locomotive: return .locomotive
        case .luggage: return .van
        case .some: return .coach
        case nil: break
        }
        guard let type = wagon.type else { return .coach }
        if traits(of: type).powered { return .locomotive }
        // A luggage van is a `D` and nothing else — `AD` is a first-class coach
        // with a luggage compartment, and is drawn as a coach.
        return type.raw.hasPrefix("D") ? .van : .coach
    }

    // MARK: - The drawing, from the names alone

    /// A train's wagons, as bodies to be drawn.
    ///
    /// The other half of the bargain the database now makes. It writes down
    /// what each vehicle *is* and nothing about how to draw it, on the
    /// understanding that this can reconstruct the drawing at any time — so a
    /// better reading of the same names improves every record ever stored,
    /// including the ones written by an older build.
    ///
    /// Everything positional is worked out here rather than remembered: which
    /// ends have cabs, which vehicles carry a pantograph, where the couplings
    /// are. None of that is a property of a wagon, all of it is a property of a
    /// wagon's place in a train, and storing it per vehicle was storing the
    /// same deduction several thousand times over.
    /// - Parameter like: what to make a vehicle look like when its name is not
    ///   known. A record migrated from an older file has the count and the
    ///   classes of its wagons and no class names — version 2 never stored them
    ///   — and drawn from nothing at all every such train came out as a rake of
    ///   26.4 m coaches, which turns a hundred-metre regional unit into a
    ///   hundred-and-sixty-metre intercity. The library already knows what the
    ///   line normally runs, so its own body is a far better guess than a
    ///   global average, and the count — which *is* real evidence — still
    ///   comes from the observation. Ignored for any wagon that has a name.
    /// - Parameter measured: what a class of stock has actually been measured
    ///   at, by family — see `ClassFacts`. Where a class is in here it wins
    ///   over everything the name merely implies, because it is the one figure
    ///   that was observed rather than deduced.
    public static func units(
        from wagons: [StoredWagon], like template: VehicleUnit? = nil,
        measured: [String: ClassFacts] = [:]
    ) -> [VehicleUnit] {
        guard !wagons.isEmpty else { return [] }
        let kinds = wagons.map { kind(of: $0) }
        let hasLocomotive = kinds.contains(.locomotive)

        /// Whether this end of the train is one somebody drives from.
        ///
        /// With no locomotive anywhere the train is a multiple unit and is
        /// driven from both ends, whatever any vehicle is called — there is
        /// nothing else in it that could drive it. Letting a name the prefix
        /// table does not carry veto that is how an EC out of Milano came to be
        /// drawn with a flat wall across its nose.
        func driven(_ index: Int) -> Bool {
            guard hasLocomotive else { return true }
            if kinds[index] == .locomotive { return true }
            return wagons[index].type.flatMap { traits(of: $0).driving } ?? true
        }
        let cabAtFront = driven(0)
        let cabAtBack = driven(wagons.count - 1)

        return wagons.enumerated().map { index, wagon in
            let kind = kinds[index]
            let leading = index == 0
            let trailing = index == wagons.count - 1
            // The name where there is one; the line's usual stock where there
            // is not; a plain standard-gauge coach where there is neither.
            let traits = wagon.type.map { self.traits(of: $0) }
                ?? template.map {
                    WagonTraits(
                        doubleDeck: $0.doubleDeck, width: $0.width, nose: $0.nose,
                        driving: nil, length: $0.length, powered: false,
                        // The line's usual stock is a better guess at the shape
                        // than nothing is, and it is the *only* guess available
                        // for a record migrated from version 2 — those carry no
                        // class names at all. A train the library thinks is a
                        // MUTZ, observed with four vehicles and no names, is
                        // then drawn as four double-deck unit bodies rather
                        // than as four anonymous boxes.
                        silhouette: $0.silhouette
                    )
                }
                ?? .unknown

            // A locomotive has a cab at both ends wherever it is standing.
            let cabFront = kind == .locomotive ? true : (leading && cabAtFront)
            let cabBack = kind == .locomotive ? true : (trailing && cabAtBack)

            // Measured first, implied second. A class the app has watched is
            // drawn at the length it was seen to be; one it has not is drawn at
            // whatever its name suggests.
            let observed = wagon.type.flatMap { measured[$0.family]?.length }

            return VehicleUnit(
                kind: kind,
                length: observed ?? (kind == .van ? 18.0 : traits.length),
                width: traits.width,
                cabFront: cabFront, cabBack: cabBack,
                // Only on a vehicle that pulls. A driving trailer has a cab and
                // no pantograph — it is the unpowered end of the train — so
                // putting one on every end car drew a Bt as though it were a
                // railcar.
                pantographs: kind == .locomotive
                    ? 2 : (!hasLocomotive && (leading || trailing) ? 1 : 0),
                doubleDeck: traits.doubleDeck,
                // What the service said this vehicle is; failing that, what
                // its name implies; failing both, nothing.
                band: wagon.kind.map { band(of: $0) }
                    ?? wagon.type.map { band(of: $0.raw) } ?? .none,
                doors: kind == .locomotive ? 0 : 2,
                joint: leading ? .none : .coupler,
                nose: (cabFront || cabBack) ? traits.nose : nil,
                type: wagon.type,
                // The shape family, on every vehicle and not only the ends.
                //
                // Unlike the nose, this is a fact about the whole body: an
                // intermediate KISS car has no cab and is still a double-deck
                // unit car, four and a half metres tall with two window bands.
                // The nose is what the *ends* wear and this is what the vehicle
                // is, which is why the two are separate fields.
                //
                // Except for the one vehicle whose place in the train decides
                // it: a locomotive at the head of a rake is a machine whatever
                // the register calls the coaches around it, and a rake filed
                // with every vehicle under one name would otherwise put a
                // window band down the side of the engine.
                silhouette: kind == .locomotive && !traits.powered
                    ? (traits.silhouette == .highSpeedCar ? .highSpeedPower : .electricLoco)
                    : traits.silhouette
            )
        }
    }

    /// A whole train, drawn from its wagons' names.
    public static func layout(
        of wagons: [StoredWagon], livery: Livery, like template: VehicleUnit? = nil,
        measured: [String: ClassFacts] = [:], source: LayoutSource = .observed
    ) -> VehicleLayout? {
        let units = units(from: wagons, like: template, measured: measured)
        guard !units.isEmpty else { return nil }
        return VehicleLayout(
            units: units, livery: livery, name: name(units: units), source: source
        ).resolvingStripes()
    }

    /// What the train is, in words: "Locomotive + 8 coaches", "6-car unit".
    public static func name(units: [VehicleUnit]) -> String {
        let locomotives = units.count { $0.kind == .locomotive }
        let coaches = units.count - locomotives
        if locomotives > 0 {
            let engine = locomotives == 1 ? "Locomotive" : "\(locomotives) locomotives"
            return "\(engine) + \(coaches) coach\(coaches == 1 ? "" : "es")"
        }
        return "\(units.count)-car unit"
    }

    // MARK: - Paint

    /// The paint for one wagon, given what the company paints its trains.
    ///
    /// The seam the whole file exists for. A formation is now a list of class
    /// names, and the two things a drawing needs from a name are its shape —
    /// above — and its colour, which is here.
    ///
    /// The company decides nearly all of it, and that is not a shortcoming: a
    /// Swiss train is painted by whoever runs it, and `LayoutLibrary` already
    /// knows every operator in the country. What the class adds is the
    /// exception, and there is essentially one of it, which `Livery` has always
    /// carried a field for: the vehicles that pull are painted differently from
    /// the ones that are pulled. SBB is the case — red locomotives, light grey
    /// coaches — and until now "is this a locomotive" was answered from the
    /// formation's own coach kind, which is silent for a power car filed as
    /// anything else.
    ///
    /// Returning the base unchanged is the common and correct answer. This is
    /// the hook for stock painted unlike its fleet, and it is deliberately
    /// narrow: inventing colours for classes nobody has checked would make the
    /// map confidently wrong, which is worse than uniformly approximate.
    public static func livery(for type: WagonType?, base: Livery) -> Livery {
        guard let type, traits(of: type).powered else { return base }
        // The company's locomotive colour, promoted to the body — so a Re 460
        // at the head of a grey IC2000 rake is drawn red, which is the one unit
        // on that train with a shape and a colour of its own.
        guard base.powered != base.body else { return base }
        return Livery(
            body: base.powered, roof: base.roof, trim: base.trim,
            glass: base.glass, stroke: base.stroke,
            powered: base.powered, belt: base.powered
        )
    }
}
