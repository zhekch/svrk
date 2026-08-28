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
        let folded = name.uppercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
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

    public static let unknown = WagonTraits(
        doubleDeck: false, width: VehicleUnit.standardGaugeWidth, nose: nil,
        driving: nil, length: 26.4, powered: false
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
        return WagonTraits(
            doubleDeck: deck,
            width: isMetreGauge(raw) ? VehicleUnit.metreGaugeWidth : VehicleUnit.standardGaugeWidth,
            nose: nose(raw),
            driving: isDrivingStock(raw),
            length: defaultLength(raw, powered: powered, doubleDeck: deck),
            powered: powered
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
