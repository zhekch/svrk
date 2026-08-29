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
        // Südostbahn, which is a *copper* company and was drawn as a white one.
        //
        // The Traverso — the Voralpen-Express and the Treno Gottardo, which is
        // what nearly every SOB working on this map is — is wrapped in a warm
        // metallic bronze with a black window band and a red line along the
        // sill. It is the most distinctive paint on the eastern network and the
        // one nothing else wears; drawn in the white the FLIRTs used to carry
        // it read as an SBB unit with a dark stripe, which is the fleet it is
        // most often standing next to.
        "SOB": Livery(body: "#b4713a", roof: "#8b8f95", trim: "#e2001a", glass: "#20262d", stroke: "#5f3a15", belt: "#1d1d1b"),
        // Thurbo's GTWs: apple green, with the green carried over the whole
        // side and a white flash. One colour, so no band.
        "THU": Livery(body: "#5aa832", roof: "#9aa1ab", trim: "#ffffff", glass: "#22332a", stroke: "#255214"),
        "THURBO": Livery(body: "#5aa832", roof: "#9aa1ab", trim: "#ffffff", glass: "#22332a", stroke: "#255214"),
        // Fribourg. A tpf vehicle is white with red on it, not a red
        // vehicle: the buses carry a red front and a red tail on a white
        // body, and the RER's FLIRTs are white under a red band.
        "TPF": Livery(body: "#f1f3f5", roof: "#9aa1ab", trim: "#e3051b", glass: "#2b3440", stroke: "#8d1119", belt: "#e3051b"),
        "MOB": Livery(body: "#00539b", roof: "#9aa1ab", trim: "#f0c419", glass: "#22303f", stroke: "#00294d", belt: "#f0c419"),
        "ZB": Livery(body: "#e30613", roof: "#9aa1ab", trim: "#ffffff", glass: "#2b3440", stroke: "#79070c"),
        // Appenzeller Bahnen are red and always have been — the blue here
        // was simply wrong. The Tango sets running through St. Gallen are red
        // with a white flash along the skirt.
        "AB": Livery(body: "#d3232e", roof: "#9aa1ab", trim: "#ffffff", glass: "#2b3440", stroke: "#7c1119", belt: "#f0f1f3"),
        // The Sihltal and Uetliberg lines are red, top to bottom: a Re 456
        // and a rake of red double-deckers, with white only around the
        // windows. Blue was a guess and it was the wrong one.
        "SZU": Livery(body: "#d5232a", roof: "#9aa1ab", trim: "#ffffff", glass: "#2b3440", stroke: "#7c1119"),
        // transN: white with a lime green front and skirt, on the FLIRTs and
        // the buses alike.
        "TRN": Livery(body: "#f0f2f4", roof: "#9aa1ab", trim: "#78be20", glass: "#22332a", stroke: "#3f6b1a", belt: "#78be20"),
        // Morges–Bière–Cossonay: white with a green band carried round the
        // cab.
        "MBC": Livery(body: "#f0f2f4", roof: "#9aa1ab", trim: "#00a04a", glass: "#22332a", stroke: "#1d5c33", belt: "#00a04a"),
        // TRAVYS runs unpainted-looking silver-white stock with the red
        // wordmark and nothing else on it.
        "TRAVYS": Livery(body: "#e4e7ea", roof: "#9aa1ab", trim: "#d81e30", glass: "#2b3440", stroke: "#5b6169"),
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
        // Baselland Transport: yellow with a red waist stripe, which is what
        // separates a BLT Tango from the BVB green it shares track with. The
        // blue trim here belonged to no vehicle BLT has ever run.
        "BLT": Livery(body: "#ffd400", roof: "#c9b23b", trim: "#e2001a", glass: "#2b3440", stroke: "#8a7300", belt: "#e2001a"),
        "TPG": Livery(body: "#f39200", roof: "#c08536", trim: "#ffffff", glass: "#2b3440", stroke: "#8a5300"),
        // Lausanne is not a red company. A tl trolleybus is white with a
        // deep blue roof cap and a blue skirt at the front, and so is the rest
        // of the fleet. See `stockLivery` for the two metro lines, which are
        // different again.
        "TL": Livery(body: "#f2f4f7", roof: "#a2a7ad", trim: "#1c3f94", glass: "#22303f", stroke: "#16305f", belt: "#1c3f94"),
        // Lucerne is white and blue, and has been for forty years. The
        // trolleybuses on the Seebrücke are a white body under a blue band —
        // the fleet was mainly blue and is now mainly white — and drawing them
        // red put a colour on the busiest square in central Switzerland that
        // is not on any vehicle in it.
        "VBL": Livery(body: "#f3f5f8", roof: "#a2a7ad", trim: "#0a4f9c", glass: "#22303f", stroke: "#0a3466", belt: "#0a4f9c"),
        // St. Gallen: white with a red band at the waist and a dark cap over
        // the windscreen. Red is the right colour and it is the *band*, not
        // the vehicle.
        "VBSG": Livery(body: "#f3f4f6", roof: "#a2a7ad", trim: "#e2001a", glass: "#2b3440", stroke: "#7a000e", belt: "#e2001a"),
        "AAR": Livery(body: "#005ca9", roof: "#a2a7ad", trim: "#ffffff", glass: "#22303f", stroke: "#003257"),

        // The mountain, which until now had no colours at all — every rack
        // railway and every gondola in the country fell through to the mode
        // palette and came out the same orange. These are the fleets a visitor
        // to Switzerland is most likely to be looking at, and no two of them
        // are painted alike.
        //
        // Rigi Bahnen. Deep red bodies under a *cream roof* that is most of
        // what one sees from above and from a hillside — the open-sided
        // trailers are more roof than body. This is the Arth-Goldau line's
        // stock and the works trains; Vitznau's Stadler sets are cream with
        // olive ends and are painted in `stockLivery`, which is the only place
        // that knows which of the mountain's two railways a working is on.
        "RB": Livery(body: "#a01c22", roof: "#e6e1d2", trim: "#efe9d8", glass: "#2b3440", stroke: "#5e0f13"),
        // The Pilatus railway: the steepest in the world, and a deep crimson.
        "PB": Livery(body: "#b01329", roof: "#8d9298", trim: "#f2f2f2", glass: "#2b3440", stroke: "#66091a"),
        // Jungfraubahn, in the cream-over-ochre it has worn up the Eiger since
        // before anybody photographed it in colour.
        "JB": Livery(body: "#c07a24", roof: "#9aa1ab", trim: "#e9dcb4", glass: "#2b3440", stroke: "#6d4413", belt: "#e9dcb4"),
        // Wengernalpbahn: green under a cream band, with a yellow front.
        "WAB": Livery(body: "#3f7d3a", roof: "#9aa1ab", trim: "#f0d64a", glass: "#22332a", stroke: "#22461f", belt: "#e6e2c4"),
        // The Gornergrat, which is not red but a burnt copper-brown — a colour
        // nothing else in the country wears, and unmistakable against snow.
        "GGB": Livery(body: "#a8452a", roof: "#8d9298", trim: "#f0ece4", glass: "#2b3440", stroke: "#5f2415"),
        // Matterhorn Gotthard: red over a white skirt.
        "MGB": Livery(body: "#e2001a", roof: "#9aa1ab", trim: "#f2f2f2", glass: "#2b3440", stroke: "#7a000e"),
        // Montreux–Vevey–Riviera, including the Rochers-de-Naye rack line:
        // cream over navy.
        "MVR": Livery(body: "#e8e0c8", roof: "#9aa1ab", trim: "#1e3a6e", glass: "#22303f", stroke: "#16264a", belt: "#1e3a6e"),
        // Transports Publics du Chablais: a pale grass green.
        "TPC": Livery(body: "#7ab648", roof: "#9aa1ab", trim: "#ffffff", glass: "#22332a", stroke: "#3f6b1a", belt: "#e6e8d8"),
        // Brienz Rothorn: dark green carriages behind a steam locomotive.
        "BRB": Livery(body: "#2f5236", roof: "#7d8489", trim: "#d8cfae", glass: "#22332a", stroke: "#1a2f1e"),

        // The regional companies whose colours were missing rather than wrong.
        // Zug: white under a blue band, on a fleet that is nearly all bus.
        "ZVB": Livery(body: "#f2f4f7", roof: "#a2a7ad", trim: "#0a4f9c", glass: "#22303f", stroke: "#0a3466", belt: "#0a4f9c"),
        // Regionalverkehr Bern-Solothurn: red with a silver band, which is
        // near enough Bernmobil's colours to be confusing on the ground and
        // exactly right on the map.
        "RBS": Livery(body: "#d8232a", roof: "#a2a7ad", trim: "#ffffff", glass: "#2b3440", stroke: "#7a000e", belt: "#e8eaec"),

        // Foreign operators reaching into Switzerland, so an ICE through Basel
        // is not painted as an SBB train.
        "DB": Livery(body: "#f4f6f8", roof: "#b3b8bf", trim: "#ec0016", glass: "#2b3440", stroke: "#8c1018", powered: "#f4f6f8", belt: "#ec0016"),
        // Both spellings. The federal register writes it `ÖBB`, and
        // `uppercased()` leaves the umlaut alone — so the ASCII key here has
        // never once matched a real journey, and every Railjet through Buchs
        // was painted as whatever the mode palette said.
        "ÖBB": Livery(body: "#f2f4f6", roof: "#b3b8bf", trim: "#e2002a", glass: "#2b3440", stroke: "#8c1018", powered: "#e2002a", belt: "#e2002a"),
        "OEBB": Livery(body: "#f2f4f6", roof: "#b3b8bf", trim: "#e2002a", glass: "#2b3440", stroke: "#8c1018", powered: "#e2002a", belt: "#e2002a"),
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
        // On the water it chooses the *ship* rather than the paint, and it is
        // the same idea for the same reason. A lake fleet is a dozen individual
        // vessels and no feed says which one is out today, so the mix is drawn
        // honestly and the individual is not claimed. See `fleet(of:)`.
        //
        // Modulo the fleet's own size rather than something larger, because
        // this number goes into `VehicleLayoutStore`'s cache key: one entry per
        // ship on the lake is a dozen, and one entry per hash is thousands.
        if mode == .boat {
            let ships = fleet(of: operatorName?.uppercased() ?? "")
            guard ships.count > 1 else { return 0 }
            return Int(stableHash(seed) % UInt64(ships.count))
        }
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
        // The water first, because on the water the operator's own colours are
        // reliably the wrong answer and the mode's are worse — see
        // `boatLivery`. Here rather than in `stockLivery`, which is only
        // consulted by `layout`: a *learned* formation is painted straight from
        // this function, and a hook the learned path never reached would have
        // repainted every boat somebody actually tapped on.
        if mode == .boat { return boatLivery(operatorName: operatorName) }
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
    /// What a lake vessel is painted, which is not what her owner's trains are.
    ///
    /// Every boat on this map used to be drawn in the mode's own light blue,
    /// which is the colour of the *lake* — so a ship was a blue block on blue
    /// water and the one place the map most needed a silhouette had none. The
    /// operators that do have a livery in the table above made it worse rather
    /// than better: BLS works the Thunersee, and `Blüemlisalp` is not a green
    /// boat. She is white, like every other working vessel in the country.
    ///
    /// So the water gets its own tin, and it is the same tin for everybody with
    /// one colour changed. That is not a simplification, it is what a Swiss
    /// lake looks like: white hull, white superstructure, a near-black strake
    /// at the waterline, pale decks — and then one company colour, carried in
    /// the two places a ship has ever carried one, the sheer stripe along the
    /// bulwark and the funnel. Funnel marks are the oldest identification
    /// system in shipping and they work here for the reason they worked from a
    /// pier: they are the only saturated thing on an otherwise white object.
    static func boatLivery(operatorName: String?) -> Livery {
        let accent: String
        switch operatorName?.uppercased() ?? "" {
        case "CGN": accent = "#123a6e"          // Léman, in CGN's deep blue
        case "SGV": accent = "#c8102e"          // Vierwaldstättersee
        case "ZSG": accent = "#0a4f9c"          // Zürichsee, the city's blue
        case "BLS", "BLSSCHIFF": accent = "#00963f"  // Thun and Brienz
        case "SBS": accent = "#005ca9"          // Bodensee
        case "URH": accent = "#1c6fb0"          // Untersee und Rhein
        case "LNM": accent = "#00609c"          // Neuchâtel, Bienne, Morat
        case "BSG": accent = "#d8232a"          // Biel
        case "SNL": accent = "#1b6ca8"          // Lugano
        case "NLM": accent = "#0b5ea8"          // Lago Maggiore
        case "SGZ", "ZBS": accent = "#e2001a"   // Zugersee
        default: accent = "#2b4a6f"
        }
        return Livery(
            // Not pure white. A hull in the sun is a hull with a sky on it, and
            // #ffffff on a pale basemap is a hole rather than a ship.
            body: "#f4f6f8",
            // Decks, seen from above, which on these ships is planking and
            // pale painted steel — warmer than the cold grey every train roof
            // in this file wears, and that difference is worth keeping: from
            // straight down, the deck is most of what a boat is.
            roof: "#bab4a8",
            trim: accent,
            glass: "#22303f",
            stroke: "#3c434c",
            belt: accent
        )
    }

    static func stockLivery(
        mode: Mode, line: String?, operatorName: String?, category: String? = nil,
        base: Livery
    ) -> Livery {
        // The Rigi's Vitznau line, for the same reason and a stronger one: the
        // register files both of the mountain's railways under `RB`, and since
        // 2021 the two are not the same colour. The Stadler sets on 82 are a
        // cream train with a dark window band and *olive* driving ends — the
        // one livery in the country whose ends are the first thing anybody
        // names — and painted from the company's tin they came out as the deep
        // red of the cars they replaced.
        // The GoldenPass Express, which is a dark blue train and is drawn from
        // two companies' tins depending on where it is: BLS pulls it from
        // Interlaken to Zweisimmen and MOB pushes it on to Montreux, so read
        // from the operator it was green for half its run and mid-blue for the
        // other half, and it is neither. The train is painted, not the fleet.
        if normalise(line) == "GPX" || normalise(category) == "GPX" {
            return Livery(
                body: "#16304e", roof: "#8f959c", trim: "#c8a75a",
                glass: "#22303f", stroke: "#0a1c2f", belt: "#c8a75a"
            )
        }
        if operatorName?.uppercased() == "RB", normalise(line) == "82" {
            return Livery(
                body: "#e3dbc6", roof: "#b6b9bd", trim: "#3b4046",
                glass: "#2b3440", stroke: "#6f6a58",
                belt: "#3b4046", ends: "#63644d"
            )
        }
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
            firstClassAtRear: Bool = true, dining: Bool = false,
            coach: Silhouette? = nil, locomotive: Silhouette = .electricLoco
        ) -> [VehicleUnit] {
            var units: [VehicleUnit] = []
            let bodies = max(1, coaches)
            // What the coaches are shaped like, said once. A deck flag is not
            // a shape — an IC2000 coach and an EW IV are both "a coach" and
            // stand half a metre apart at the roof — so the caller may name the
            // silhouette outright and the deck flag decides it otherwise.
            let body = coach ?? (doubleDeck ? .doubleDeckCoach : .intercityCoach)
            // The cab car is one of the coaches, not an extra one.
            units.append(VehicleUnit(
                kind: .drivingCar, length: coachLength, cabFront: true,
                doubleDeck: doubleDeck, band: .second, doors: doubleDeck ? 2 : 2,
                silhouette: body
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
                    kind: .coach, length: coachLength, doubleDeck: doubleDeck, band: band,
                    silhouette: body
                ))
            }
            units.append(VehicleUnit(
                kind: .locomotive, length: 18.5, cabFront: true, cabBack: true,
                pantographs: 2, band: .none, doors: 0, silhouette: locomotive
            ))
            return units
        }

        /// A multiple unit: a cab at each end, everything in between a middle
        /// car, and no locomotive anywhere.
        public static func multipleUnit(
            cars: Int, carLength: Double, width: Double = VehicleUnit.standardGaugeWidth,
            doubleDeck: Bool = false, doors: Int = 2, dining: Bool = false,
            firstClassAtFront: Bool = true, nose: Nose? = nil,
            silhouette: Silhouette? = nil
        ) -> [VehicleUnit] {
            let count = max(1, cars)
            // Every car of a unit is the same shape, cabs aside — which is the
            // whole idea of a multiple unit and the reason one silhouette
            // covers the set. The deck flag decides it where the caller has
            // not, so a table entry written before this existed still draws
            // something better than a box.
            let body = silhouette ?? (doubleDeck ? .doubleDeckUnit : .suburbanUnit)
            if count == 1 {
                return [VehicleUnit(
                    kind: .drivingCar, length: carLength, width: width,
                    cabFront: true, cabBack: true, pantographs: 1,
                    doubleDeck: doubleDeck, band: .mixed, doors: doors, nose: nose,
                    silhouette: body
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
                    nose: isFirstCar || isLastCar ? nose : nil,
                    silhouette: body
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
                pantographs: 1, band: .none, doors: 0, nose: .streamlined,
                silhouette: .highSpeedPower
            )]
            for index in 0..<max(1, coaches) {
                units.append(VehicleUnit(
                    kind: .coach, length: coachLength,
                    band: index < 2 ? .first : (index == 3 ? .dining : .second),
                    // Lower-roofed than an intercity coach, because everything
                    // built for 300 km/h is. Next to an EW IV rake in the same
                    // station it is the difference a platform actually shows.
                    silhouette: .highSpeedCar
                ))
            }
            units.append(VehicleUnit(
                kind: .locomotive, length: powerCar, cabBack: true,
                pantographs: 1, band: .none, doors: 0, nose: .streamlined,
                silhouette: .highSpeedPower
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
                    nose: .blunt,
                    silhouette: .tramCar
                )
            }
        }

        /// A GTW: two long low-floor cars with the machinery standing between
        /// them.
        ///
        /// Worth its own builder because the thing that makes a GTW
        /// recognisable is not a dimension. It is a four-metre blank tower
        /// between two low cars — the whole traction package in one container,
        /// full height, no windows — and a `multipleUnit` of three equal cars
        /// draws the one vehicle in the country with an obvious middle as three
        /// identical boxes. Thurbo runs most of the eastern regional network
        /// with these, so it is a shape a great many dots on this map ought to
        /// have.
        /// A GTW: two long low-floor cars with the machinery standing between
        /// them.
        ///
        /// The module is the whole point. A GTW is the one design in the
        /// country whose *middle* identifies it — four metres of blank,
        /// full-height traction container between two low cars, so the roofline
        /// goes low, tall, low — and drawn as three equal cars it is a short
        /// train and nothing else.
        ///
        /// The catch, and it is worth knowing about because it will come up
        /// again: a library layout has to be reproducible from what the
        /// database stores, which is class names plus one measured length per
        /// class. Every car of a GTW is a `RABe 526`, so a formation rebuilt
        /// from file would give all three bodies the same length, disagree with
        /// this, and be filed as a correction to a guess that was right. The
        /// fix is not to weaken the guess but to teach the *reading* the same
        /// rule — see `WagonCatalogue.tractionModule`, which puts the short
        /// middle body back on the observation side so the two paths reach the
        /// same drawing from the same evidence.
        public static func gtw(
            carLength: Double = 17.4, width: Double = VehicleUnit.standardGaugeWidth
        ) -> [VehicleUnit] {
            [
                VehicleUnit(
                    kind: .drivingCar, length: carLength, width: width,
                    cabFront: true, band: .first, doors: 2, joint: .none,
                    silhouette: .lowFloorUnit
                ),
                VehicleUnit(
                    kind: .coach, length: WagonCatalogue.gtwModuleLength, width: width,
                    pantographs: 1, band: .second, doors: 0,
                    silhouette: .gtwPower
                ),
                VehicleUnit(
                    kind: .drivingCar, length: carLength, width: width,
                    cabBack: true, band: .second, doors: 2,
                    silhouette: .lowFloorUnit
                ),
            ]
        }

        /// A metre-gauge locomotive and the coaches behind it.
        ///
        /// The Glacier Express, the GoldenPass and the Bernina line, which
        /// between them are most of what a visitor to this country photographs.
        /// `panorama` is what earns the builder: those coaches are glazed to
        /// the centre line, and a roof that is a window is the one feature a
        /// tilted camera sees more of than any other. Drawn with the grey roof
        /// every other vehicle gets, a Glacier Express was a rake of grey boxes.
        public static func narrowRake(
            coaches: Int, coachLength: Double = 16.4, panorama: Bool = false,
            width: Double = VehicleUnit.metreGaugeWidth
        ) -> [VehicleUnit] {
            let body: Silhouette = panorama ? .panoramaCoach : .intercityCoach
            var units: [VehicleUnit] = [VehicleUnit(
                kind: .locomotive, length: 12.9, width: width,
                cabFront: true, cabBack: true, pantographs: 2,
                band: .none, doors: 0, silhouette: .electricLoco
            )]
            for index in 0..<max(1, coaches) {
                units.append(VehicleUnit(
                    kind: .coach, length: coachLength, width: width,
                    cabBack: index == max(1, coaches) - 1,
                    band: index == 0 ? .first : .second, doors: 2,
                    silhouette: body
                ))
            }
            return units
        }

        /// The GoldenPass Express, which is neither of the trains beside it.
        ///
        /// A `narrowRake` with a locomotive at the head and plain ends was
        /// wrong about the two things anybody recognises it by. It is worked
        /// *push-pull from a panoramic control car* — an `Ast 181` at one end,
        /// the locomotive and an interface car at the other, so the shape at
        /// the front is a driving car with a raked screen and not a machine —
        /// and its coaches are dark blue, which no other train in the country
        /// is. See `stockLivery`, which paints it whichever company's
        /// locomotive happens to be on the back that day.
        ///
        /// The interface car earns its place: the couplers at the two ends of
        /// this train are not the same, because the train is not on the same
        /// gauge at the two ends of its journey, and the `Bsi` is what stands
        /// between the automatic coupler of the rake and the buffers of a BLS
        /// locomotive.
        public static func goldenPassExpress(
            coaches: Int = 5, coachLength: Double = 18.8, width: Double = 2.70
        ) -> [VehicleUnit] {
            var units: [VehicleUnit] = [VehicleUnit(
                kind: .drivingCar, length: coachLength, width: width,
                cabFront: true, band: .first, doors: 2,
                // A slight one. The control car's front is a raked screen with
                // the corners drawn in — a moulding rather than a point, and
                // nothing like the flat wall on the end of a coach.
                nose: .bulb, silhouette: .panoramaCoach
            )]
            for index in 0..<max(1, coaches) {
                units.append(VehicleUnit(
                    kind: .coach, length: coachLength, width: width,
                    band: index == 0 ? .first : .second, doors: 2,
                    silhouette: .panoramaCoach
                ))
            }
            units.append(VehicleUnit(
                kind: .locomotive, length: 16.6, width: width,
                cabFront: true, cabBack: true, pantographs: 2,
                band: .none, doors: 0, silhouette: .electricLoco
            ))
            return units
        }

        /// A rack railway train: a railcar, and the trailers it pushes up the
        /// hill in front of it.""
        ///
        /// The shape the map was most obviously wrong about, and it was wrong
        /// twice over. A Rigi, Pilatus, Jungfrau or Gornergrat working arrives
        /// filed under category `CC`, which this app maps to `.cable` — and
        /// `.cable` drew a twelve-metre funicular cabin. So the busiest
        /// mountain railway in the country was a single grey pod, for a train
        /// that is in fact two or three short red bodies with deep roofs, and
        /// on the Rigi they are open-sided.
        ///
        /// Pushed rather than pulled, which is the whole of how a rack railway
        /// is worked: the powered vehicle is always on the downhill end, so the
        /// train is drawn trailers-first. Whether "first" is up the hill or
        /// down it is the direction of travel and nothing this can know, but
        /// getting the *order* right means the railcar is at one end rather
        /// than in the middle.
        public static func rackTrain(
            railcar: Double, trailers: Int = 1, trailerLength: Double = 14.0,
            width: Double = VehicleUnit.metreGaugeWidth, openSided: Bool = false
        ) -> [VehicleUnit] {
            var units: [VehicleUnit] = []
            for index in 0..<max(0, trailers) {
                units.append(VehicleUnit(
                    kind: .coach, length: trailerLength, width: width,
                    // The leading trailer is a driving trailer: somebody has to
                    // see where the train is going when it is being pushed.
                    cabFront: index == 0,
                    band: .none, doors: 2, joint: index == 0 ? .none : .coupler,
                    silhouette: openSided ? .rackTrailer : .rackTrainCar
                ))
            }
            units.append(VehicleUnit(
                kind: .drivingCar, length: railcar, width: width,
                cabFront: units.isEmpty, cabBack: true, pantographs: 1,
                band: .none, doors: 2, joint: units.isEmpty ? .none : .coupler,
                silhouette: .rackTrainCar
            ))
            return units
        }

        /// A modern articulated rack unit: one vehicle in two sections.
        ///
        /// Not a railcar pushing a trailer, which is what every other cog
        /// railway in the country runs and what this one ran until 2021. Six
        /// Stadler sets have worked Vitznau–Rigi Kulm since then, and they are
        /// a different vehicle in every way a top view can see: 34.8 m over the
        /// couplers rather than 31, one body rather than two with a gap in it,
        /// a cab at each end rather than a cab and a driving trailer, and a
        /// centre joint with a bellows in it where the coupler used to be.
        ///
        /// The joint is the part worth being careful about. Two sections over
        /// an articulation are continuous — no gap, no chamfer, no second
        /// windscreen — so the ends of the *unit* are the only two ends there
        /// are, which is exactly what `.bellows` says.
        public static func rackUnit(
            length: Double = 34.8, width: Double = 2.70
        ) -> [VehicleUnit] {
            let section = length / 2
            return [
                VehicleUnit(
                    kind: .drivingCar, length: section, width: width,
                    cabFront: true, pantographs: 1,
                    band: .none, doors: 2, joint: .none,
                    silhouette: .rackUnit
                ),
                VehicleUnit(
                    kind: .drivingCar, length: section, width: width,
                    cabBack: true,
                    band: .none, doors: 2, joint: .bellows,
                    silhouette: .rackUnit
                ),
            ]
        }

        /// A gondola, an aerial tramway cabin, or a chair on a lift.
        ///
        /// Not a train, which is what these were being drawn as. A cabin hangs
        /// from a rope: it is small, it is narrow, it is rounded at both ends
        /// and — the part no amount of shaping could substitute for — it is
        /// eight metres above the ground rather than on it. See
        /// `Silhouette.hover`, which is where the height lives, and
        /// `VehicleShape.mesh`, which draws the arm and the grip over it.
        ///
        /// One body. A gondola line is a great many cabins and the feed reports
        /// each as its own journey, so a "vehicle" here is one cabin and
        /// drawing it as a coupled set would put a train in the sky.
        public static func aerialCabin(length: Double, width: Double) -> [VehicleUnit] {
            [VehicleUnit(
                kind: .cabin, length: length, width: width,
                cabFront: true, cabBack: true,
                band: .none, doors: 1, silhouette: .aerialCabin
            )]
        }

        /// A bus. One body, or two or three where it bends.
        ///
        /// `trolley` is recorded and not drawn. A trolleybus collects from twin
        /// trolley poles, which from above are two thin lines trailing off the
        /// back of the roof and nothing a map can show — and the pantograph
        /// cross that stood in for them was the single strongest thing on the
        /// drawing saying "tram" about a vehicle that is not one. What tells
        /// them apart now is the wheels; see `VehicleShape.trim`.
        public static func bus(
            length: Double, sections: Int = 1, trolley: Bool = false,
            silhouette: Silhouette? = nil
        ) -> [VehicleUnit] {
            let count = max(1, sections)
            // A trolleybus is a hand taller than a diesel one, because the
            // traction gear a diesel keeps in its tail is on the roof — and on
            // a street where both run that roofline is the only thing telling
            // them apart, now that the poles are gone. Recording the flag and
            // drawing nothing was the old answer; this is what it should have
            // been spent on.
            let body = silhouette ?? (trolley ? .trolleybus : .cityBus)
            if count == 1 {
                return [VehicleUnit(
                    kind: .bus, length: length, width: VehicleUnit.busWidth,
                    cabFront: true, band: .none, doors: 2, silhouette: body
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
                    joint: index == 0 ? .none : .bellows,
                    silhouette: body
                )
            }
        }

        /// One vessel, of a named class of vessel.
        ///
        /// `beam` is the hull's beam on the waterline and not the width over
        /// the paddle boxes, which is the number a steamer's own registry
        /// quotes second and the one the drawing works out for itself — see
        /// `ShipDecks.PaddleBox.spread`. Giving it the over-boxes figure here
        /// would have widened the hull instead of adding the boxes, and a
        /// steamer would have come out as a very fat motor ship.
        public static func ship(
            length: Double, beam: Double, _ silhouette: Silhouette
        ) -> [VehicleUnit] {
            [VehicleUnit(
                kind: .hull, length: length, width: beam, cabFront: true,
                band: .none, doors: 0, silhouette: silhouette
            )]
        }

        public static func boat(length: Double, beam: Double) -> [VehicleUnit] {
            ship(length: length, beam: beam, .boatHull)
        }

        public static func cabin(length: Double, width: Double = 2.6, cars: Int = 1) -> [VehicleUnit] {
            (0..<max(1, cars)).map { index in
                VehicleUnit(
                    kind: .cabin, length: length, width: width,
                    cabFront: index == 0, cabBack: index == max(1, cars) - 1,
                    band: .none, doors: 2, silhouette: .funicularCar
                )
            }
        }
    }

    // MARK: - The lake fleets

    /// One vessel: what she is called, how big she is, and what shape of ship.
    ///
    /// Named, and the names are real. Nothing on screen ever prints one — the
    /// panel is told `Dampfschiff` or `Motorschiff`, which is a claim about the
    /// *class* and is true of whichever ship it turns out to be. The names are
    /// here because they are what the dimensions were read off, and a table of
    /// anonymous numbers is a table nobody can check.
    struct Vessel: Sendable {
        var name: String
        var length: Double
        var beam: Double
        var shape: Silhouette

        init(_ name: String, _ length: Double, _ beam: Double, _ shape: Silhouette) {
            self.name = name; self.length = length; self.beam = beam; self.shape = shape
        }

        /// What the panel is told this is.
        var kindName: String {
            switch shape {
            case .paddleSteamer: return "Dampfschiff"
            case .panoramaShip: return "Panoramaschiff"
            default: return "Motorschiff"
            }
        }
    }

    /// What a lake operator actually floats.
    ///
    /// The one place in this library where the entries are individual vehicles
    /// rather than classes, and it has to be: a lake fleet is a dozen ships, no
    /// two of them alike, three of which were launched before the First World
    /// War. There is no class to average — `Stadt Luzern` is not a member of a
    /// type, she is a ship.
    ///
    /// **Which one is running is not knowable**, exactly as which livery a
    /// Geneva tram wears is not knowable: no feed this app reads carries a
    /// vessel name. So the choice is hashed off the journey's own id — see
    /// `variant(operatorName:mode:seed:)` — which is stable for as long as the
    /// journey exists and arbitrary beyond that. The claim being made is about
    /// the *mix* on the lake and never about the individual boat, and on the
    /// Vierwaldstättersee that mix really is five paddle steamers among the
    /// motor ships, all summer, every summer.
    static func fleet(of code: String) -> [Vessel] {
        switch code {
        // Lac Léman: the largest surviving fleet of Belle Époque paddle
        // steamers anywhere in the world, and eight of them are CGN's.
        case "CGN":
            return [
                Vessel("La Suisse", 78.5, 8.6, .paddleSteamer),
                Vessel("Simplon", 78.5, 8.6, .paddleSteamer),
                Vessel("Savoie", 68.0, 8.4, .paddleSteamer),
                Vessel("Rhône", 68.3, 8.4, .paddleSteamer),
                Vessel("Montreux", 68.3, 8.4, .paddleSteamer),
                Vessel("Vevey", 66.0, 8.4, .paddleSteamer),
                Vessel("Italie", 66.0, 8.4, .paddleSteamer),
                Vessel("Henry-Dunant", 55.0, 9.6, .motorVessel),
                Vessel("Lausanne", 50.0, 9.4, .motorVessel),
                Vessel("Ville-de-Genève", 47.0, 9.0, .motorVessel),
                Vessel("Léman", 40.0, 8.4, .motorVessel),
                Vessel("NaviExpress", 45.0, 10.6, .panoramaShip),
            ]
        // The Vierwaldstättersee, which runs five steamers and two of the
        // glassiest ships in the country out of the same berths at Luzern.
        case "SGV":
            return [
                Vessel("Stadt Luzern", 63.5, 8.0, .paddleSteamer),
                Vessel("Schiller", 63.0, 7.7, .paddleSteamer),
                Vessel("Uri", 62.7, 7.5, .paddleSteamer),
                Vessel("Unterwalden", 62.3, 7.5, .paddleSteamer),
                Vessel("Gallia", 61.0, 7.4, .paddleSteamer),
                Vessel("Waldstätter", 55.0, 10.0, .motorVessel),
                Vessel("Titlis", 47.0, 8.6, .motorVessel),
                Vessel("Rütli", 40.0, 8.0, .motorVessel),
                Vessel("Saphir", 48.0, 10.2, .panoramaShip),
                Vessel("Diamant", 47.8, 10.4, .panoramaShip),
                Vessel("Cirrus", 34.0, 8.4, .panoramaShip),
            ]
        // The Zürichsee: two steamers, one all-glass ship, and a lot of
        // ordinary motor boats on the short crossings.
        case "ZSG":
            return [
                Vessel("Stadt Zürich", 59.2, 6.9, .paddleSteamer),
                Vessel("Stadt Rapperswil", 59.0, 6.9, .paddleSteamer),
                Vessel("Panta Rhei", 51.0, 11.7, .panoramaShip),
                Vessel("Helvetia", 55.0, 9.6, .motorVessel),
                Vessel("Wädenswil", 48.0, 9.0, .motorVessel),
                Vessel("Linth", 40.0, 8.2, .motorVessel),
                Vessel("Albis", 33.0, 7.4, .motorVessel),
                Vessel("Etzel", 33.0, 7.4, .motorVessel),
            ]
        // The Thuner- and Brienzersee, worked by BLS — which is the reason the
        // paint below cannot be read off the operator. BLS is a green railway
        // and its ships are white like everybody else's.
        case "BLS", "BLSSCHIFF":
            return [
                Vessel("Blüemlisalp", 63.5, 7.2, .paddleSteamer),
                Vessel("Berner Oberland", 56.0, 9.6, .motorVessel),
                Vessel("Stadt Thun", 50.0, 9.0, .motorVessel),
                Vessel("Jungfrau", 47.0, 8.6, .motorVessel),
                Vessel("Niesen", 44.0, 8.4, .motorVessel),
                Vessel("Brienz", 38.0, 7.8, .motorVessel),
            ]
        // The Bodensee, which has no steamer left and one catamaran.
        case "SBS":
            return [
                Vessel("Säntis", 55.0, 10.0, .motorVessel),
                Vessel("St. Gallen", 50.0, 9.6, .motorVessel),
                Vessel("Thurgau", 47.0, 9.2, .motorVessel),
                Vessel("Zürich", 40.0, 8.6, .motorVessel),
                Vessel("Konstanz", 32.6, 10.6, .panoramaShip),
            ]
        // The Untersee and the Rhine down to Schaffhausen: shallow, narrow
        // water, and therefore small flat ships.
        case "URH":
            return [
                Vessel("Schaffhausen", 42.0, 8.4, .motorVessel),
                Vessel("Thurgau", 38.0, 8.0, .motorVessel),
                Vessel("Munot", 33.0, 7.4, .motorVessel),
                Vessel("Stein am Rhein", 33.0, 7.4, .motorVessel),
            ]
        case "LNM":
            return [
                Vessel("Ville de Neuchâtel", 45.0, 8.8, .motorVessel),
                Vessel("Fribourg", 40.0, 8.4, .motorVessel),
                Vessel("Cygne", 33.0, 7.4, .motorVessel),
            ]
        // Biel, and the country's first solar catamaran with it.
        case "BSG":
            return [
                Vessel("Petersinsel", 38.0, 8.0, .motorVessel),
                Vessel("Rousseau", 33.0, 7.4, .motorVessel),
                Vessel("MobiCat", 33.0, 12.0, .panoramaShip),
            ]
        case "SNL":
            return [
                Vessel("Lugano", 40.0, 8.2, .motorVessel),
                Vessel("Ceresio", 35.0, 7.6, .motorVessel),
                Vessel("Milano", 33.0, 7.4, .motorVessel),
            ]
        case "NLM":
            return [
                Vessel("Verbania", 45.0, 8.8, .motorVessel),
                Vessel("Locarno", 40.0, 8.2, .motorVessel),
            ]
        case "SGZ", "ZBS":
            return [
                Vessel("Rigi", 40.0, 8.2, .motorVessel),
                Vessel("Schwan", 33.0, 7.4, .motorVessel),
            ]
        default:
            // A lake this table has never heard of runs one ordinary motor
            // ship, which is what nearly all of them do.
            return [Vessel("Motorschiff", 42.0, 8.6, .motorVessel)]
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
        case "ICN":     return (Stock.multipleUnit(cars: 7, carLength: 26.9, dining: true, nose: .streamlined, silhouette: .highSpeedCar), "RABDe 500 ICN")
        case "GIRUNO":  return (Stock.multipleUnit(cars: 11, carLength: 18.4, dining: true, nose: .streamlined, silhouette: .highSpeedCar), "RABe 501 Giruno")
        case "ETR610":  return (Stock.multipleUnit(cars: 7, carLength: 26.9, dining: true, nose: .streamlined, silhouette: .highSpeedCar), "RABe 503 Astoro")
        case "DOSTO":   return (Stock.multipleUnit(cars: 8, carLength: 25.0, doubleDeck: true, dining: true), "RABe 502 FV-Dosto")
        case "DOSTO4":  return (Stock.multipleUnit(cars: 4, carLength: 25.0, doubleDeck: true), "RABDe 502 FV-Dosto")
        case "KISS":    return (Stock.multipleUnit(cars: 6, carLength: 25.0, doubleDeck: true), "RABe 511 KISS")
        case "KISS4":   return (Stock.multipleUnit(cars: 4, carLength: 25.0, doubleDeck: true), "RABe 511 KISS")
        case "DTZ":     return (Stock.multipleUnit(cars: 4, carLength: 25.0, doubleDeck: true, doors: 3), "RABe 514 DTZ")
        case "MUTZ":    return (Stock.multipleUnit(cars: 4, carLength: 26.2, doubleDeck: true, doors: 3), "RABe 515 MUTZ")
        case "FLIRT":   return (Stock.multipleUnit(cars: 4, carLength: 18.6, doors: 2), "RABe 523 FLIRT")
        case "FLIRT6":  return (Stock.multipleUnit(cars: 6, carLength: 17.6, doors: 2), "RABe 523 FLIRT, 6 cars")
        case "TRAVERSO": return (Stock.multipleUnit(cars: 4, carLength: 18.6, dining: true, silhouette: .lowFloorUnit), "RABe 526 Traverso")
        // The NINA, at the length it is: a three-car unit is 47.7 m over the
        // couplers, not the sixty metres three intercity-ish bodies came to.
        case "NINA":    return (Stock.multipleUnit(cars: 3, carLength: 15.9, width: 3.03, doors: 2), "RABe 525 NINA")
        // The Lötschberger — a NINA with a longer body count and a front BLS
        // had redesigned. Four sections over 62.7 m, three metres wide, and
        // nearly flat at the ends where every other Stadler product in the
        // country carries a deep moulded nose. See `WagonCatalogue.nose`, which
        // says the same thing from the class name, so a fetched formation and
        // this guess draw the same vehicle.
        case "LOETSCHBERGER": return (Stock.multipleUnit(cars: 4, carLength: 15.7, width: 3.03, doors: 2, nose: .blunt), "RABe 535 Lötschberger")
        case "GTW":     return (Stock.gtw(), "RABe 526 GTW")
        case "DOMINO":  return (Stock.pushPull(coaches: 3, coachLength: 25.0, firstClassAtRear: false, coach: .suburbanUnit, locomotive: .suburbanUnit), "RBDe 560 Domino")
        case "ICE":     return (Stock.powerCarSet(coaches: 12, coachLength: 26.4, powerCar: 20.6), "ICE 1")
        case "ICE4":    return (Stock.multipleUnit(cars: 12, carLength: 28.8, dining: true, nose: .streamlined, silhouette: .highSpeedCar), "ICE 4")
        case "TGV":     return (Stock.powerCarSet(coaches: 8, coachLength: 18.7, powerCar: 22.2), "TGV Lyria 2N2")
        case "RJX":     return (Stock.pushPull(coaches: 8, coachLength: 26.5, dining: true, coach: .highSpeedCar), "Railjet")
        case "NIGHTJET": return (Stock.pushPull(coaches: 11, coachLength: 26.4, coach: .sleeperCoach), "Nightjet")

        // Metre gauge. Narrower and shorter, which is the whole difference a
        // top view can show between an RhB train and an SBB one.
        case "ALLEGRA": return (Stock.multipleUnit(cars: 3, carLength: 16.5, width: VehicleUnit.metreGaugeWidth, silhouette: .narrowGaugeUnit), "RhB ABe 8/12 Allegra")
        case "CAPRICORN": return (Stock.multipleUnit(cars: 4, carLength: 19.0, width: VehicleUnit.metreGaugeWidth, silhouette: .narrowGaugeUnit), "RhB ABe 4/16 Capricorn")
        case "RHBRAKE": return (Stock.narrowRake(coaches: 6, coachLength: 16.4, panorama: true), "RhB Ge 4/4 + panorama coaches")
        case "GOLDENPASS": return (Stock.narrowRake(coaches: 5, coachLength: 15.0, panorama: true), "MOB panoramic")
        case "GPX": return (Stock.goldenPassExpress(), "GoldenPass Express")
        case "ADLER":   return (Stock.multipleUnit(cars: 4, carLength: 17.5, width: VehicleUnit.metreGaugeWidth, silhouette: .narrowGaugeUnit), "zb ABeh 150 ADLER")
        case "KOMET":   return (Stock.multipleUnit(cars: 3, carLength: 17.4, width: VehicleUnit.metreGaugeWidth, silhouette: .narrowGaugeUnit), "MGB ABDeh 4/8 Komet")
        // The catch-all for a metre-gauge company with no entry of its own,
        // and much better than the standard-gauge FLIRT they used to fall
        // through to: narrower, shorter, and lower at the roof, which on a
        // valley floor beside an SBB train is the whole difference.
        case "NARROW":  return (Stock.multipleUnit(cars: 3, carLength: 16.0, width: VehicleUnit.metreGaugeWidth, silhouette: .narrowGaugeUnit), "Narrow-gauge railcar")

        default: return nil
        }
    }

    // MARK: - What each line runs

    /// Operator and line → class, for a line whose number is not its own.
    ///
    /// `byLine` below is keyed on the line alone, which is safe for the
    /// national products — there is one IC 1 and one IR 16 — and is not safe
    /// for a regional number. Line numbers repeat: there is an R 41 in the
    /// Mattertal and another in the Jura, and they are different companies
    /// running different trains. So a regional entry has to say whose line it
    /// means, and this is looked at before the plain table.
    ///
    /// `R12` is Spiez–Frutigen, on the north ramp of the Lötschberg, worked by
    /// the Lötschberger the ramp is named after — not by the double-deck MUTZ
    /// that BLS runs on the Bern S-Bahn, which is what `localByOperator` would
    /// otherwise hand it.
    static let byOperatorLine: [String: String] = [
        "BLS|R12": "LOETSCHBERGER",
    ]

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
        "GPX": "GPX",
    ]

    /// Category → class, for everything the line table does not name.
    static let byCategory: [String: String] = [
        "IC": "IC2000", "ICN": "ICN", "IR": "DOSTO4", "IRE": "FLIRT",
        "RE": "DOMINO", "R": "FLIRT", "RB": "FLIRT",
        "S": "FLIRT", "SN": "FLIRT", "SP": "FLIRT",
        "ICE": "ICE4", "TGV": "TGV", "RJ": "RJX", "RJX": "RJX",
        "EC": "ETR610", "EN": "NIGHTJET", "NJ": "NIGHTJET", "CNL": "NIGHTJET",
        "PE": "TRAVERSO", "GEX": "RHBRAKE", "BEX": "GOLDENPASS", "VAE": "TRAVERSO",
        "GPX": "GPX",
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
        // The metre-gauge companies, which used to fall through to a
        // standard-gauge FLIRT — a vehicle three metres too long and a
        // quarter of a metre too wide for every line they run on.
        "MGB": "KOMET", "MVR": "NARROW", "TPC": "NARROW", "BOB": "NARROW",
        "LEB": "NARROW", "NSTCM": "NARROW", "CJ": "NARROW", "ASM": "NARROW",
    ]

    /// Trams and buses, by the operator that runs them.
    ///
    /// A tram is its city's tram: Bern runs 32 m Combinos, Zürich 36 m Cobras
    /// and 43 m Flexitys, Basel 43 m. A bus is 12 m unless the operator is one
    /// of the four cities that run articulated fleets on most of their routes.
    static func road(
        mode: Mode, operatorName: String?, line: String? = nil, category: String? = nil,
        variant: Int = 0
    ) -> ([VehicleUnit], String) {
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
                firstClassAtFront: false, nose: .blunt, silhouette: .metroCar
            ), "MS2")
        case .boat:
            // A catamaran is a catamaran whoever owns it, and the feed says so
            // outright: `Categories` folds the product code `KAT` into this
            // mode alongside the ordinary boats. Both of the country's real
            // ones — the Bodensee crossing and Biel's solar boat — are wide,
            // low, glass-sided ships and nothing like the fleet around them.
            if normalise(category) == "KAT" {
                return (
                    Stock.ship(length: 33.0, beam: 11.4, .panoramaShip),
                    "Katamaran"
                )
            }
            let ships = fleet(of: code)
            // `variant` is the hash of the journey's own id — right about the
            // mix on the lake, never about the individual ship. See `fleet`.
            let ship = ships[((variant % ships.count) + ships.count) % ships.count]
            return (
                Stock.ship(length: ship.length, beam: ship.beam, ship.shape),
                ship.kindName
            )
        case .cable:
            // `.cable` is four completely different vehicles wearing one word,
            // and it used to draw one twelve-metre pod for all of them.
            //
            // The feed does say which. `Categories` folds `FUN`, `GB`, `LB`,
            // `PB`, `SL`, `CC` and `ASC` into this mode because they all
            // travel by something other than their own wheels on a level
            // track — but a cog railway is a *train*, a funicular is a car on
            // a slope, and a gondola is a box in the sky. Drawing them alike
            // put a Rigi Bahnen working, which is two or three short red
            // bodies with white roofs, on the map as a single grey pod; and it
            // put every gondola in the Alps on the ground under its own rope.
            //
            // So the category is consulted here rather than thrown away at the
            // parser. It costs one string comparison on a path that runs when
            // a layout is first built, and it is the difference between four
            // recognisable vehicles and one that is wrong about all of them.
            switch normalise(category) {
            case "CC":
                return cogRailway(code, line: line)
            case "GB", "SL":
                // A gondola cabin seats six or eight and is a shade over two
                // metres long; a chair on a lift is smaller still. Both hang.
                return (Stock.aerialCabin(length: 2.4, width: 2.1), "Gondola")
            case "LB", "PB", "AS":
                // An aerial tramway car — a Pendelbahn or a Luftseilbahn —
                // carries eighty people and is the size of a small bus, and it
                // hangs from the same kind of rope.
                return (Stock.aerialCabin(length: 6.4, width: 3.4), "Cable car")
            default:
                // A funicular, and the lifts filed as `ASC` with it: a car on
                // rails on a hillside, which is the one thing in this mode
                // that really does stand on the ground.
                return (Stock.cabin(length: 12.0, width: 3.0), "Funicular")
            }
        default:
            switch code {
            // The trolleybus cities, which run articulated and in Zürich,
            // Geneva and Lucerne double-articulated stock on the trunk routes.
            // The trolleybus cities. The wires are not drawn — see `Stock.bus`
            // — but the vehicle under them is a hand taller than a diesel one,
            // and on a street carrying both that roofline is now the whole of
            // how they are told apart.
            case "VBZ", "TPG", "VBL", "TL":
                return (Stock.bus(length: 24.7, sections: 3, trolley: true), "Double-articulated trolleybus")
            case "SVB", "VBSG", "VBSH", "VB", "VMCV", "TPF":
                return (Stock.bus(length: 18.0, sections: 2, trolley: true), "Articulated trolleybus")
            case "BVB", "BLT", "ZVB", "RBS", "AVA", "BOS", "VZO", "RVBW", "TPL":
                return (Stock.bus(length: 18.0, sections: 2), "Articulated bus")
            // A PostAuto is not a city bus. It is a coach: high floor, luggage
            // bays under it, and a metre taller at the sill than the low-floor
            // stock a city runs — which is what a vehicle built to cross a pass
            // and carry the skis has to be.
            case "PAG", "PTT", "PAGT", "AFA", "AAGL", "AAGR", "AAGS", "AAGU":
                return (Stock.bus(length: 12.0, silhouette: .coachBus), "PostAuto")
            default: return (Stock.bus(length: 12.0), "Bus")
            }
        }
    }

    /// What each of the country's cog railways runs.
    ///
    /// Short trains, and the differences between them are large enough to be
    /// worth naming: the Pilatus is 800 mm gauge and its cars are the size of a
    /// minibus, the Rigi is standard gauge and pushes open-sided trailers, the
    /// Jungfrau and Wengernalp cars are metre-gauge and nearly as long as a
    /// tram module. Drawn at one size they would all be the Jungfrau, which on
    /// the Pilatus is a vehicle three times too big for the mountain.
    static func cogRailway(_ code: String, line: String?) -> ([VehicleUnit], String) {
        switch code {
        // Rigi Bahnen: standard gauge — the only rack railway in the country
        // that is — and the two lines up the mountain no longer run the same
        // vehicle as each other.
        //
        // **82 is Vitznau–Rigi Kulm**, and since 2021 it is worked by six
        // Stadler articulated sets: one 34.8 m vehicle in two sections, cream
        // with olive ends. Nothing about the old picture survives — not the
        // length, not the number of bodies, not the gap in the middle, and
        // certainly not the red.
        //
        // **81 is Arth-Goldau–Rigi Kulm**, which still runs the BDhe 4/4 and
        // its open-sided trailer and has four of the same Stadler sets on order
        // for 2030. Until they arrive the old drawing is the right one, which
        // is why this is keyed on the line and not on the company.
        case "RB":
            if normalise(line) == "82" {
                return (Stock.rackUnit(), "Rigi Stadler")
            }
            return (
                Stock.rackTrain(
                    railcar: 16.6, trailers: 1, trailerLength: 14.4,
                    width: 2.70, openSided: true
                ),
                "Rigi BDhe 4/4"
            )
        // The steepest rack railway in the world, and the smallest vehicle on
        // it: 800 mm gauge, and a car that holds forty people.
        case "PB":
            return (
                Stock.rackTrain(railcar: 6.6, trailers: 0, width: 2.10),
                "Pilatus Bhe 1/2"
            )
        case "JB":
            return (
                Stock.rackTrain(railcar: 17.6, trailers: 1, trailerLength: 17.0, width: 2.70),
                "Jungfraubahn BDhe 4/8"
            )
        case "WAB":
            return (
                Stock.rackTrain(railcar: 17.0, trailers: 1, trailerLength: 16.2, width: 2.66),
                "Wengernalpbahn BDhe 4/8"
            )
        case "GGB":
            return (
                Stock.rackTrain(railcar: 16.2, trailers: 1, trailerLength: 15.6, width: 2.70),
                "Gornergrat Bhe 4/8"
            )
        // 800 mm gauge and steam-hauled for most of the day: the shortest
        // train on the network.
        case "BRB":
            return (
                Stock.rackTrain(railcar: 7.6, trailers: 1, trailerLength: 7.2, width: 2.10),
                "Brienz Rothorn Bahn"
            )
        case "MVR", "TPC", "MGB", "AB":
            return (
                Stock.rackTrain(railcar: 15.8, trailers: 1, trailerLength: 14.8),
                "Rack railcar"
            )
        default:
            return (Stock.rackTrain(railcar: 15.5, trailers: 1), "Rack railcar")
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
            mode: mode, line: line, operatorName: operatorName, category: category,
            base: livery(
                operatorName: operatorName, mode: mode,
                modeColour: modeColour, variant: variant
            )
        )

        guard mode == .train else {
            let (units, name) = road(
                mode: mode, operatorName: operatorName, line: line, category: category,
                variant: variant
            )
            return VehicleLayout(units: units, livery: paint, name: name).resolvingStripes()
        }

        let lineKey = normalise(line)
        let categoryKey = normalise(category)
        let operatorKey = operatorName?.uppercased() ?? ""

        // A local service run by a company with a known fleet is that fleet,
        // whatever the category says. Applied only to the local categories: an
        // SBB *intercity* is not a four-car DTZ.
        let isLocal = ["S", "SN", "SP", "R", "RB", "RE", "IRE"].contains(categoryKey)

        let className = byOperatorLine["\(operatorKey)|\(lineKey)"]
            ?? byLine[lineKey]
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
