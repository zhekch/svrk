import Foundation

// What each service normally runs, so the map can draw a train without asking
// anybody.
//
// The formation service answers one train at a time, fifty times a minute, for
// eleven companies. A map that morphed its dots into real vehicles by *asking*
// would need a request per train per screenful — hundreds of them on a zoom
// into Zürich, for eleven companies' worth of trains and none of the buses. So
// the drawing is built from what is already known about the line, and the
// service is asked only about the one train somebody has actually tapped.
//
// Two things follow from that, and both are deliberate.
//
// **These are typical formations, not facts about today's train.** An IC1 is a
// double-deck unit, an IR16 is a KISS, an S-Bahn out of Zürich is a four-car
// DTZ — right on most days and wrong whenever a set is swapped, strengthened
// for an event, or short-formed for a fault. Being wrong here costs a drawing
// that is one coach out, which is the same order of wrong as the dot it
// replaces. It does not appear in any number the app prints.
//
// **Anything the service does answer is written down.** `VehicleLayoutStore`
// records the real formation of every train that gets tapped, so the table
// below is a first guess that the app corrects as it is used — and a train
// looked at once is drawn correctly ever after.
//
// Lengths are metres of real vehicle, taken from the manufacturers' figures for
// the classes named. Where a class runs in more than one length the commonest
// one is used.

public enum LayoutLibrary {

    // MARK: - Paint

    /// The companies whose colours are worth telling apart.
    ///
    /// Keyed by the short code `OperatorRegister` hands back — SBB, BLS, PAG,
    /// SVB — because that is the field a `VehicleSnapshot` already carries.
    /// Everything not in here falls back to the mode's own colour, which is
    /// what the dot was drawn in, so an unknown operator changes shape without
    /// changing colour.
    static let liveries: [String: Livery] = [
        // The national operator, and the one worth getting right first.
        //
        // SBB stock is not "white". Every modern long-distance set — FV-Dosto,
        // Giruno, the refitted IC2000 and EW IV rakes — is a pale silver-white
        // body under a broad red band that runs the length of the vehicle above
        // the windows, with red doors and a red cab front; and the thing on the
        // end of the loco-hauled ones is a Re 460, which is red all over. From
        // directly above, all of that is a hairline along the edge of a grey
        // box, which is why the flat drawing paints SBB grey and is right to.
        // From a tilted camera the band is most of the side, and a train that
        // does not have it does not read as SBB at all.
        "SBB": Livery(body: "#eceef1", roof: "#8e959d", trim: "#e2001a", glass: "#2b3440", stroke: "#3d434c", powered: "#e2001a", belt: "#e2001a"),
        "CFF": Livery(body: "#eceef1", roof: "#8e959d", trim: "#e2001a", glass: "#2b3440", stroke: "#3d434c", powered: "#e2001a", belt: "#e2001a"),
        "FFS": Livery(body: "#eceef1", roof: "#8e959d", trim: "#e2001a", glass: "#2b3440", stroke: "#3d434c", powered: "#e2001a", belt: "#e2001a"),
        // BLS. The NINA and the MUTZ are both green over white with the green
        // carried up around the cab, so the band is the *lighter* one here —
        // the one operator in the country whose stripe runs the other way.
        "BLS": Livery(body: "#00963f", roof: "#8f978f", trim: "#e8e2d2", glass: "#22332a", stroke: "#0a4526", belt: "#f0efe6"),
        // Rhaetian Railway, metre gauge, unmistakably red. The Capricorn puts a
        // white band over it; the older stock does not, and red-on-red is what
        // that comes to.
        "RHB": Livery(body: "#c8102e", roof: "#9aa1ab", trim: "#f2f2f2", glass: "#2b3440", stroke: "#6d0a19", belt: "#f2f2f2"),
        // Südostbahn. The Traverso and the Voralpen-Express stock are white and
        // silver with a black band and red doors — not the black vehicles the
        // first pass made of them.
        "SOB": Livery(body: "#e9ebee", roof: "#8b8f95", trim: "#e2001a", glass: "#20262d", stroke: "#3a3d41", belt: "#1d1d1b"),
        // Thurbo's GTWs: apple green, with the green carried over the whole
        // side and a white flash. One colour, so no band.
        "THU": Livery(body: "#5aa832", roof: "#9aa1ab", trim: "#ffffff", glass: "#22332a", stroke: "#255214"),
        "THURBO": Livery(body: "#5aa832", roof: "#9aa1ab", trim: "#ffffff", glass: "#22332a", stroke: "#255214"),
        "TPF": Livery(body: "#e30613", roof: "#9aa1ab", trim: "#ffffff", glass: "#2b3440", stroke: "#79070c"),
        "MOB": Livery(body: "#00539b", roof: "#9aa1ab", trim: "#f0c419", glass: "#22303f", stroke: "#00294d", belt: "#f0c419"),
        "ZB": Livery(body: "#e30613", roof: "#9aa1ab", trim: "#ffffff", glass: "#2b3440", stroke: "#79070c"),
        "AB": Livery(body: "#005ca9", roof: "#9aa1ab", trim: "#ffffff", glass: "#22303f", stroke: "#003257", belt: "#eef1f4"),
        "SZU": Livery(body: "#0069b4", roof: "#9aa1ab", trim: "#ffffff", glass: "#22303f", stroke: "#00395f", belt: "#eef1f4"),
        "TRN": Livery(body: "#009ee0", roof: "#9aa1ab", trim: "#ffffff", glass: "#22303f", stroke: "#005a80"),
        "MBC": Livery(body: "#005ca9", roof: "#9aa1ab", trim: "#ffffff", glass: "#22303f", stroke: "#003257"),
        "TRAVYS": Livery(body: "#004f9f", roof: "#9aa1ab", trim: "#ffcc00", glass: "#22303f", stroke: "#002d5a"),
        "RA": Livery(body: "#e2001a", roof: "#9aa1ab", trim: "#ffffff", glass: "#2b3440", stroke: "#7a000e"),

        // The road. PostAuto's yellow is the single most recognisable livery in
        // the country and the one most worth getting onto the map.
        "PAG": Livery(body: "#ffcc00", roof: "#d8ba3e", trim: "#e2001a", glass: "#2b3440", stroke: "#8a6f00"),
        "PTT": Livery(body: "#ffcc00", roof: "#d8ba3e", trim: "#e2001a", glass: "#2b3440", stroke: "#8a6f00"),
        // City operators, in the colours their fleets are actually painted.
        // Bern: red with a white band, on the trams and the buses alike.
        "SVB": Livery(body: "#e2001a", roof: "#a2a7ad", trim: "#ffffff", glass: "#2b3440", stroke: "#7a000e", belt: "#f2f2f2"),
        // Zürich. The Cobra and the Flexity are blue below the windows and
        // white above them, and that split is most of how a VBZ tram is
        // recognised from any angle at all.
        "VBZ": Livery(body: "#005bab", roof: "#a2a7ad", trim: "#ffffff", glass: "#22303f", stroke: "#003462", belt: "#f2f2f2"),
        // Basel: BVB green under a cream band, which is the oldest continuous
        // livery in the country and has outlived four generations of tram.
        "BVB": Livery(body: "#009640", roof: "#a2a7ad", trim: "#f5efdd", glass: "#22332a", stroke: "#005524", belt: "#f5efdd"),
        "BLT": Livery(body: "#ffd500", roof: "#c9b23b", trim: "#005ca9", glass: "#2b3440", stroke: "#8a7300"),
        "TPG": Livery(body: "#f39200", roof: "#c08536", trim: "#ffffff", glass: "#2b3440", stroke: "#8a5300"),
        "TL": Livery(body: "#e30613", roof: "#a2a7ad", trim: "#ffffff", glass: "#2b3440", stroke: "#79070c"),
        "VBL": Livery(body: "#e2001a", roof: "#a2a7ad", trim: "#ffffff", glass: "#2b3440", stroke: "#7a000e"),
        "VBSG": Livery(body: "#e2001a", roof: "#a2a7ad", trim: "#ffffff", glass: "#2b3440", stroke: "#7a000e"),
        "AAR": Livery(body: "#005ca9", roof: "#a2a7ad", trim: "#ffffff", glass: "#22303f", stroke: "#003257"),

        // Foreign operators reaching into Switzerland, so an ICE through Basel
        // is not painted as an SBB train.
        "DB": Livery(body: "#f4f6f8", roof: "#b3b8bf", trim: "#ec0016", glass: "#2b3440", stroke: "#8c1018", powered: "#f4f6f8", belt: "#ec0016"),
        "OBB": Livery(body: "#f2f4f6", roof: "#b3b8bf", trim: "#e2002a", glass: "#2b3440", stroke: "#8c1018", powered: "#e2002a", belt: "#e2002a"),
        "SNCF": Livery(body: "#e4e8ee", roof: "#9aa1ab", trim: "#a8022a", glass: "#22303f", stroke: "#4b4f57", powered: "#a8022a", belt: "#8f1a3c"),
        "TI": Livery(body: "#d9dde3", roof: "#9aa1ab", trim: "#b5121b", glass: "#22303f", stroke: "#4b4f57"),
        "TRE": Livery(body: "#d9dde3", roof: "#9aa1ab", trim: "#b5121b", glass: "#22303f", stroke: "#4b4f57"),
    ]

    /// The liveries a fleet wears besides the one above, and on what.
    ///
    /// One colour per company is a lie in the places it matters most. Geneva is
    /// the case that forced this: the trams on the Cornavin trunk are not all
    /// the same colour and never have been — the standard fleet is TPG's orange
    /// and white, and a substantial part of it runs in a full blue wrap — so a
    /// map that painted every one of them orange showed a uniformity the street
    /// does not have, and the eye went looking for the fault.
    ///
    /// Two honest limits, both deliberate.
    ///
    /// **Which vehicle wears which is not knowable.** No feed this app reads
    /// says what a running journey is painted; there is no fleet number in
    /// SIRI-ET at all. So the choice is made by hashing the journey's own id —
    /// stable for as long as that journey exists and across launches, arbitrary
    /// beyond that. It is right about the *mix* and never about the individual,
    /// which is exactly the claim `LayoutLibrary` already makes about formations.
    ///
    /// **The first entry is the standard livery**, so an operator with no
    /// variants draws exactly as it did before it acquired any.
    struct FleetLiveries: Sendable {
        /// The modes this applies to. A company's trams and its buses are not
        /// painted from the same tin.
        var modes: Set<Mode>
        var liveries: [Livery]
    }

    static let variants: [String: FleetLiveries] = [
        // Geneva. Orange and white is the fleet livery; the blue is the wrap a
        // large slice of the tram fleet carries, and on the 12 and 18 the two
        // follow each other through Cornavin all day.
        "TPG": FleetLiveries(modes: [.tram], liveries: [
            Livery(body: "#f39200", roof: "#5c6169", trim: "#ffffff", glass: "#2b3440", stroke: "#8a5300"),
            Livery(body: "#1d4f9c", roof: "#5c6169", trim: "#ffffff", glass: "#22303f", stroke: "#0d2a57"),
        ]),
    ]

    /// Which of an operator's liveries a given vehicle wears.
    ///
    /// Hashed rather than random, and hashed with a written-down function
    /// rather than with `Hasher`: Swift's is seeded per process, so the same
    /// tram would change colour every time the app was launched — which is
    /// worse than one colour for the whole fleet, because it is one colour for
    /// the whole fleet that flickers.
    public static func variant(operatorName: String?, mode: Mode, seed: String) -> Int {
        guard let code = operatorName?.uppercased(), let set = variants[code],
              set.modes.contains(mode), set.liveries.count > 1
        else { return 0 }
        return Int(stableHash(seed) % UInt64(set.liveries.count))
    }

    /// FNV-1a, because it is four lines and it gives the same answer next week.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    /// The paint for one vehicle: the operator's where it is known, the mode's
    /// otherwise.
    ///
    /// `modeColour` is handed in rather than looked up because the mode palette
    /// lives in the app, beside every other colour the map draws — and a module
    /// with no UIKit in it has no business owning half of it.
    public static func livery(
        operatorName: String?, mode: Mode, modeColour: String, variant: Int = 0
    ) -> Livery {
        if let code = operatorName?.uppercased() {
            if let set = variants[code], set.modes.contains(mode), !set.liveries.isEmpty {
                let count = set.liveries.count
                return set.liveries[((variant % count) + count) % count]
            }
            if let known = liveries[code] { return known }
        }
        return Livery(
            body: modeColour, roof: "#9aa1ab", trim: "#ffffff",
            glass: "#22303f", stroke: "rgba(0,0,0,0.75)"
        )
    }

    /// The paint for stock that is nothing like the fleet it belongs to.
    ///
    /// Lausanne is the whole reason this exists. `tl` is a red company — its
    /// buses and its trolleybuses are red, and the operator table says so — but
    /// neither line called a metro is a red vehicle. The m1 railcars and the m2
    /// trains are both white with grey and a red flash, so painting them from
    /// the operator's tin put two solid red worms across Lausanne that look
    /// nothing like the things they stand for.
    static func stockLivery(mode: Mode, line: String?, operatorName: String?, base: Livery) -> Livery {
        guard operatorName?.uppercased() == "TL", mode == .metro else { return base }
        return Livery(
            body: "#eef1f4", roof: "#9198a1", trim: "#e30613",
            glass: "#2b3440", stroke: "#6b7178"
        )
    }

    // MARK: - The stock

    /// The classes this table can name, built from their real dimensions.
    public enum Stock {

        /// A locomotive-hauled push-pull train: a driving trailer at the front,
        /// coaches, and the locomotive pushing at the back.
        ///
        /// Front-first, which is the direction of travel — so on the outward
        /// run the cab car leads and the locomotive is at the rear. That is how
        /// nearly every Swiss loco-hauled train is worked, and drawing the
        /// locomotive at the front instead would put the wrong shape at the end
        /// somebody is standing next to on a platform half the time.
        public static func pushPull(
            coaches: Int, doubleDeck: Bool = false, coachLength: Double = 26.4,
            firstClassAtRear: Bool = true, dining: Bool = false
        ) -> [VehicleUnit] {
            var units: [VehicleUnit] = []
            let bodies = max(1, coaches)
            // The cab car is one of the coaches, not an extra one.
            units.append(VehicleUnit(
                kind: .drivingCar, length: coachLength, cabFront: true,
                doubleDeck: doubleDeck, band: .second, doors: doubleDeck ? 2 : 2
            ))
            for index in 1..<bodies {
                // First class rides next to the locomotive on nearly every
                // Swiss intercity, and the restaurant sits on the boundary
                // between the two classes.
                let fromRear = bodies - index
                let band: ClassBand
                if dining && fromRear == 2 { band = .dining }
                else if firstClassAtRear && fromRear <= 2 { band = .first }
                else { band = .second }
                units.append(VehicleUnit(
                    kind: .coach, length: coachLength, doubleDeck: doubleDeck, band: band
                ))
            }
            units.append(VehicleUnit(
                kind: .locomotive, length: 18.5, cabFront: true, cabBack: true,
                pantographs: 2, band: .none, doors: 0
            ))
            return units
        }

        /// A multiple unit: a cab at each end, everything in between a middle
        /// car, and no locomotive anywhere.
        public static func multipleUnit(
            cars: Int, carLength: Double, width: Double = VehicleUnit.standardGaugeWidth,
            doubleDeck: Bool = false, doors: Int = 2, dining: Bool = false,
            firstClassAtFront: Bool = true, nose: Nose? = nil
        ) -> [VehicleUnit] {
            let count = max(1, cars)
            if count == 1 {
                return [VehicleUnit(
                    kind: .drivingCar, length: carLength, width: width,
                    cabFront: true, cabBack: true, pantographs: 1,
                    doubleDeck: doubleDeck, band: .mixed, doors: doors, nose: nose
                )]
            }
            var units: [VehicleUnit] = []
            for index in 0..<count {
                let isFirstCar = index == 0
                let isLastCar = index == count - 1
                let band: ClassBand
                if dining && index == count / 2 { band = .dining }
                else if firstClassAtFront && index == 0 { band = .first }
                else { band = .second }
                units.append(VehicleUnit(
                    kind: isFirstCar || isLastCar ? .drivingCar : .coach,
                    length: carLength, width: width,
                    cabFront: isFirstCar, cabBack: isLastCar,
                    // Pantographs on the cars that carry them: on a Swiss unit
                    // that is usually the two next to the middle.
                    pantographs: (index == 1 || index == count - 2) ? 1 : 0,
                    doubleDeck: doubleDeck, band: band, doors: doors,
                    // Only the ends of a unit have a nose to shape; the cars in
                    // between are boxes whatever the train is.
                    nose: isFirstCar || isLastCar ? nose : nil
                ))
            }
            return units
        }

        /// A high-speed train: a power car at each end and coaches between.
        public static func powerCarSet(coaches: Int, coachLength: Double, powerCar: Double) -> [VehicleUnit] {
            // A power car is a locomotive by every other measure and nothing
            // like one from above: an ICE 1 or a TGV ends in six or seven
            // metres of unbroken taper, where a Re 460 ends in a flat slab two
            // metres deep. Drawn as a locomotive it was the one shape on the
            // whole map somebody could name from the platform and could not
            // recognise on the screen.
            var units: [VehicleUnit] = [VehicleUnit(
                kind: .locomotive, length: powerCar, cabFront: true,
                pantographs: 1, band: .none, doors: 0, nose: .streamlined
            )]
            for index in 0..<max(1, coaches) {
                units.append(VehicleUnit(
                    kind: .coach, length: coachLength,
                    band: index < 2 ? .first : (index == 3 ? .dining : .second)
                ))
            }
            units.append(VehicleUnit(
                kind: .locomotive, length: powerCar, cabBack: true,
                pantographs: 1, band: .none, doors: 0, nose: .streamlined
            ))
            return units
        }

        /// An articulated tram: modules joined by bellows, so the whole thing is
        /// one body with joints rather than a set of coupled vehicles.
        public static func tram(modules: Int, length: Double, width: Double = 2.3) -> [VehicleUnit] {
            let count = max(2, modules)
            let each = length / Double(count)
            return (0..<count).map { index in
                VehicleUnit(
                    kind: index == 0 || index == count - 1 ? .drivingCar : .module,
                    length: each, width: width,
                    cabFront: index == 0, cabBack: index == count - 1,
                    pantographs: index == count / 2 ? 1 : 0,
                    band: .none, doors: 2,
                    joint: index == 0 ? .none : .bellows,
                    // A tram is flat-fronted. Given the taper a railway driving
                    // car gets, a five-module Combino came out with a point at
                    // each end and read as a very short high-speed train.
                    nose: .blunt
                )
            }
        }

        /// A bus. One body, or two or three where it bends.
        ///
        /// `trolley` is recorded and not drawn. A trolleybus collects from twin
        /// trolley poles, which from above are two thin lines trailing off the
        /// back of the roof and nothing a map can show — and the pantograph
        /// cross that stood in for them was the single strongest thing on the
        /// drawing saying "tram" about a vehicle that is not one. What tells
        /// them apart now is the wheels; see `VehicleShape.trim`.
        public static func bus(length: Double, sections: Int = 1, trolley: Bool = false) -> [VehicleUnit] {
            _ = trolley
            let count = max(1, sections)
            if count == 1 {
                return [VehicleUnit(
                    kind: .bus, length: length, width: VehicleUnit.busWidth,
                    cabFront: true, band: .none, doors: 2
                )]
            }
            let each = length / Double(count)
            return (0..<count).map { index in
                VehicleUnit(
                    // Every section of an articulated bus is a bus, however it
                    // is hinged. Calling the trailers `.module` made a
                    // double-articulated trolleybus and a five-module tram the
                    // same drawing at different lengths — which is exactly the
                    // pair somebody in Zürich most needs to tell apart, since
                    // both are blue and both bend twice.
                    kind: .bus, length: each,
                    width: VehicleUnit.busWidth, cabFront: index == 0,
                    // The last section of an articulated bus is the one with a
                    // back to it; the ones before it end in a bellows.
                    cabBack: index == count - 1,
                    band: .none, doors: index == 0 ? 2 : 1,
                    joint: index == 0 ? .none : .bellows
                )
            }
        }

        public static func boat(length: Double, beam: Double) -> [VehicleUnit] {
            [VehicleUnit(
                kind: .hull, length: length, width: beam, cabFront: true,
                band: .none, doors: 0
            )]
        }

        public static func cabin(length: Double, width: Double = 2.6, cars: Int = 1) -> [VehicleUnit] {
            (0..<max(1, cars)).map { index in
                VehicleUnit(
                    kind: .cabin, length: length, width: width,
                    cabFront: index == 0, cabBack: index == max(1, cars) - 1,
                    band: .none, doors: 2
                )
            }
        }
    }

    // MARK: - Named classes

    /// The classes by name, so the service table below reads as rolling stock
    /// rather than as arithmetic.
    static func named(_ name: String) -> ([VehicleUnit], String)? {
        switch name {
        // Standard-gauge main line.
        case "IC2000":  return (Stock.pushPull(coaches: 8, doubleDeck: true, coachLength: 26.8, dining: true), "Re 460 + IC2000")
        case "EWIV":    return (Stock.pushPull(coaches: 7, coachLength: 26.4, dining: true), "Re 460 + EW IV")
        case "ICN":     return (Stock.multipleUnit(cars: 7, carLength: 26.9, dining: true, nose: .streamlined), "RABDe 500 ICN")
        case "GIRUNO":  return (Stock.multipleUnit(cars: 11, carLength: 18.4, dining: true, nose: .streamlined), "RABe 501 Giruno")
        case "ETR610":  return (Stock.multipleUnit(cars: 7, carLength: 26.9, dining: true, nose: .streamlined), "RABe 503 Astoro")
        case "DOSTO":   return (Stock.multipleUnit(cars: 8, carLength: 25.0, doubleDeck: true, dining: true), "RABe 502 FV-Dosto")
        case "DOSTO4":  return (Stock.multipleUnit(cars: 4, carLength: 25.0, doubleDeck: true), "RABDe 502 FV-Dosto")
        case "KISS":    return (Stock.multipleUnit(cars: 6, carLength: 25.0, doubleDeck: true), "RABe 511 KISS")
        case "KISS4":   return (Stock.multipleUnit(cars: 4, carLength: 25.0, doubleDeck: true), "RABe 511 KISS")
        case "DTZ":     return (Stock.multipleUnit(cars: 4, carLength: 25.0, doubleDeck: true, doors: 3), "RABe 514 DTZ")
        case "MUTZ":    return (Stock.multipleUnit(cars: 4, carLength: 26.2, doubleDeck: true, doors: 3), "RABe 515 MUTZ")
        case "FLIRT":   return (Stock.multipleUnit(cars: 4, carLength: 18.6, doors: 2), "RABe 523 FLIRT")
        case "FLIRT6":  return (Stock.multipleUnit(cars: 6, carLength: 17.6, doors: 2), "RABe 523 FLIRT, 6 cars")
        case "TRAVERSO": return (Stock.multipleUnit(cars: 4, carLength: 18.6, dining: true), "RABe 526 Traverso")
        case "NINA":    return (Stock.multipleUnit(cars: 3, carLength: 20.0, doors: 2), "RABe 525 NINA")
        case "GTW":     return (Stock.multipleUnit(cars: 3, carLength: 18.0, doors: 2), "RABe 526 GTW")
        case "DOMINO":  return (Stock.pushPull(coaches: 3, coachLength: 25.0, firstClassAtRear: false), "RBDe 560 Domino")
        case "ICE":     return (Stock.powerCarSet(coaches: 12, coachLength: 26.4, powerCar: 20.6), "ICE 1")
        case "ICE4":    return (Stock.multipleUnit(cars: 12, carLength: 28.8, dining: true, nose: .streamlined), "ICE 4")
        case "TGV":     return (Stock.powerCarSet(coaches: 8, coachLength: 18.7, powerCar: 22.2), "TGV Lyria 2N2")
        case "RJX":     return (Stock.pushPull(coaches: 8, coachLength: 26.5, dining: true), "Railjet")
        case "NIGHTJET": return (Stock.pushPull(coaches: 11, coachLength: 26.4), "Nightjet")

        // Metre gauge. Narrower and shorter, which is the whole difference a
        // top view can show between an RhB train and an SBB one.
        case "ALLEGRA": return (Stock.multipleUnit(cars: 3, carLength: 16.5, width: VehicleUnit.metreGaugeWidth), "RhB ABe 8/12 Allegra")
        case "CAPRICORN": return (Stock.multipleUnit(cars: 4, carLength: 19.0, width: VehicleUnit.metreGaugeWidth), "RhB ABe 4/16 Capricorn")
        case "RHBRAKE": return (Stock.pushPull(coaches: 6, coachLength: 16.4, firstClassAtRear: true), "RhB Ge 4/4 + coaches")
        case "GOLDENPASS": return (Stock.multipleUnit(cars: 5, carLength: 15.0, width: VehicleUnit.metreGaugeWidth), "MOB panoramic")
        case "ADLER":   return (Stock.multipleUnit(cars: 4, carLength: 17.5, width: VehicleUnit.metreGaugeWidth), "zb ABeh 150 ADLER")

        default: return nil
        }
    }

    // MARK: - What each line runs

    /// Line → class, for the services worth naming individually.
    ///
    /// Uppercased and stripped of spaces, because the feed publishes an IC 1 as
    /// `IC1`, `IC 1` and occasionally `IC01` depending on which half of the
    /// country filed it.
    static let byLine: [String: String] = [
        // Intercity.
        "IC1": "DOSTO", "IC2": "GIRUNO", "IC3": "IC2000", "IC4": "DOSTO",
        "IC5": "ICN", "IC6": "IC2000", "IC8": "IC2000", "IC21": "GIRUNO",
        "IC51": "ICN", "IC61": "IC2000", "IC81": "IC2000",
        // Interregio.
        "IR13": "DOSTO4", "IR15": "ICN", "IR16": "KISS", "IR17": "KISS",
        "IR26": "IC2000", "IR27": "IC2000", "IR35": "KISS", "IR36": "KISS",
        "IR37": "DOSTO4", "IR46": "DOSTO4", "IR65": "EWIV", "IR66": "EWIV",
        "IR70": "DOSTO4", "IR75": "DOSTO4", "IR90": "ICN", "IR95": "EWIV",
        // Named trains.
        "GEX": "RHBRAKE", "BEX": "GOLDENPASS", "PE": "TRAVERSO", "VAE": "TRAVERSO",
    ]

    /// Category → class, for everything the line table does not name.
    static let byCategory: [String: String] = [
        "IC": "IC2000", "ICN": "ICN", "IR": "DOSTO4", "IRE": "FLIRT",
        "RE": "DOMINO", "R": "FLIRT", "RB": "FLIRT",
        "S": "FLIRT", "SN": "FLIRT", "SP": "FLIRT",
        "ICE": "ICE4", "TGV": "TGV", "RJ": "RJX", "RJX": "RJX",
        "EC": "ETR610", "EN": "NIGHTJET", "NJ": "NIGHTJET", "CNL": "NIGHTJET",
        "PE": "TRAVERSO", "GEX": "RHBRAKE", "BEX": "GOLDENPASS", "VAE": "TRAVERSO",
        "RHB": "ALLEGRA", "D": "EWIV", "EXT": "EWIV",
    ]

    /// Operator → the class that company runs on an ordinary local service,
    /// applied before the category table.
    ///
    /// This is where the drawing stops being generic: a Zürich S-Bahn is a
    /// four-car double-decker and a Basel one is a FLIRT, and both are filed as
    /// category `S` by the same feed.
    static let localByOperator: [String: String] = [
        "SBB": "DTZ", "CFF": "DTZ", "FFS": "DTZ",
        "BLS": "MUTZ", "SOB": "TRAVERSO", "THU": "GTW", "THURBO": "GTW",
        "RHB": "CAPRICORN", "ZB": "ADLER", "MOB": "GOLDENPASS",
        "TPF": "FLIRT", "SZU": "FLIRT", "AB": "GTW", "TRN": "FLIRT",
        "RA": "DOMINO", "MBC": "GTW", "TRAVYS": "DOMINO",
    ]

    /// Trams and buses, by the operator that runs them.
    ///
    /// A tram is its city's tram: Bern runs 32 m Combinos, Zürich 36 m Cobras
    /// and 43 m Flexitys, Basel 43 m. A bus is 12 m unless the operator is one
    /// of the four cities that run articulated fleets on most of their routes.
    static func road(mode: Mode, operatorName: String?, line: String? = nil) -> ([VehicleUnit], String) {
        let code = operatorName?.uppercased() ?? ""
        switch mode {
        case .tram:
            switch code {
            case "VBZ": return (Stock.tram(modules: 5, length: 36.0), "Cobra Be 5/6")
            case "SVB": return (Stock.tram(modules: 5, length: 32.0), "Combino Be 4/6")
            case "BVB": return (Stock.tram(modules: 7, length: 43.0), "Flexity Be 6/8")
            case "BLT": return (Stock.tram(modules: 7, length: 45.0), "Tango Be 6/10")
            case "TPG": return (Stock.tram(modules: 7, length: 42.0), "Cityrunner")
            case "TL":  return (Stock.tram(modules: 5, length: 30.7, width: 2.5), "M1")
            default:    return (Stock.tram(modules: 5, length: 33.0), "Tram")
            }
        case .metro:
            // Lausanne runs two lines called a metro and they are not remotely
            // the same vehicle. Reading the mode alone drew both as the m2,
            // which put a pair of stubby pointed pods along the Renens viaduct
            // where the m1 actually runs.
            //
            // The **m1** is not a metro at all. It is the TSOL: a standard-gauge
            // light railway on the surface, worked by Bem 4/6 railcars — one
            // articulated body 30.7 m long and 2.65 m wide, flat-fronted, two
            // sections over a centre joint, and no gap anywhere in the middle
            // of it.
            //
            // The **m2** is the real thing and the only one in the country:
            // rubber-tyred, driverless, two cars of about 15.3 m coupled, the
            // whole train a shade over 30 m in a tunnel under the city.
            if normalise(line) == "M1" {
                return (Stock.tram(modules: 2, length: 30.7, width: 2.65), "Bem 4/6")
            }
            // No first class on it, which is not a detail: `multipleUnit` puts
            // a first-class band on the leading car by default, and a metro
            // that has never had classes was drawing a yellow stripe down one
            // of its two cars.
            return (Stock.multipleUnit(
                cars: 2, carLength: 15.3, width: 2.5, doors: 3,
                firstClassAtFront: false, nose: .blunt
            ), "MS2")
        case .boat:
            switch code {
            case "CGN": return (Stock.boat(length: 68.0, beam: 8.6), "Belle Époque")
            case "ZSG": return (Stock.boat(length: 55.0, beam: 10.0), "Motorschiff")
            default:    return (Stock.boat(length: 45.0, beam: 9.0), "Motorschiff")
            }
        case .cable:
            return (Stock.cabin(length: 12.0, width: 3.0), "Funicular")
        default:
            switch code {
            // The trolleybus cities, which run articulated and in Zürich,
            // Geneva and Lucerne double-articulated stock on the trunk routes.
            case "VBZ", "TPG", "VBL": return (Stock.bus(length: 24.7, sections: 3, trolley: true), "Double-articulated trolleybus")
            case "SVB", "BVB", "BLT", "TL", "VBSG": return (Stock.bus(length: 18.0, sections: 2, trolley: code == "SVB" || code == "VBSG"), "Articulated bus")
            case "PAG", "PTT": return (Stock.bus(length: 12.0), "PostAuto")
            default: return (Stock.bus(length: 12.0), "Bus")
            }
        }
    }

    // MARK: - Resolution

    /// What to draw for a vehicle nobody has looked up.
    ///
    /// In order: the line, the operator's usual local stock, the category, and
    /// then the mode — each one a wider guess than the last, and the last one
    /// always answers, so there is no vehicle the map cannot draw.
    public static func layout(
        mode: Mode, category: String?, line: String?, operatorName: String?,
        modeColour: String, variant: Int = 0
    ) -> VehicleLayout {
        let paint = stockLivery(
            mode: mode, line: line, operatorName: operatorName,
            base: livery(
                operatorName: operatorName, mode: mode,
                modeColour: modeColour, variant: variant
            )
        )

        guard mode == .train else {
            let (units, name) = road(mode: mode, operatorName: operatorName, line: line)
            return VehicleLayout(units: units, livery: paint, name: name).resolvingStripes()
        }

        let lineKey = normalise(line)
        let categoryKey = normalise(category)
        let operatorKey = operatorName?.uppercased() ?? ""

        // A local service run by a company with a known fleet is that fleet,
        // whatever the category says. Applied only to the local categories: an
        // SBB *intercity* is not a four-car DTZ.
        let isLocal = ["S", "SN", "SP", "R", "RB", "RE", "IRE"].contains(categoryKey)

        let className = byLine[lineKey]
            ?? (isLocal ? localByOperator[operatorKey] : nil)
            ?? byCategory[categoryKey]
            ?? localByOperator[operatorKey]
            ?? "FLIRT"

        guard let (units, name) = named(className) else {
            return VehicleLayout(
                units: Stock.multipleUnit(cars: 4, carLength: 18.6),
                livery: paint, name: "Train"
            ).resolvingStripes()
        }
        return VehicleLayout(units: units, livery: paint, name: name).resolvingStripes()
    }

    /// `IC 1` and `ic1` are the same line; `S 12` and `S12` are the same line.
    static func normalise(_ text: String?) -> String {
        guard let text else { return "" }
        return text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}
