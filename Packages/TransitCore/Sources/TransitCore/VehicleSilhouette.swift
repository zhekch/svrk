import Foundation

// What a class of vehicle actually looks like, as a small closed vocabulary.
//
// Every wagon in the country used to be one extruded box. `VehicleShape.mesh`
// built a body out of length, width and `doubleDeck`, capped it with one of six
// end profiles, and that was the entire shape vocabulary — so a Rigi rack
// railcar, a Giruno, a GTW and an IC2000 differed by their dimensions and by
// nothing else. Which is to say: on a map, a row of boxes at four lengths.
//
// The missing fact is not the class *name*. The name is already stored, already
// read, and `WagonCatalogue` already turns it into a length and a width. What
// was missing is a place to put the answer to "and what shape is that", so this
// is that place: one enum, one case per silhouette worth telling apart, and a
// table of real proportions behind it.
//
// **An archetype rather than a class.** This is deliberately *not* one case per
// register entry. A mesh is baked once per distinct `VehicleModelKey` and kept
// for the life of the process, so anything in the key that does not change the
// geometry multiplies the meshes for nothing — and a `RABe 511` and a `RABe
// 515` are, from three hundred metres up on a tilted map, the same double-deck
// unit with a low nose. Four hundred class names collapse onto twenty-five
// shapes, and twenty-five is what the renderer is asked to hold.
//
// **The generic case has to stay good.** Records migrated from version 2 of the
// database carry no class names at all — they never stored them — so a great
// many wagons arrive with nothing to look up and must come out looking exactly
// as they did before this file existed. That is what `.generic` is: not a
// fallback shape, but the *previous* shape, unchanged, kept honest by having no
// entry in the table below.

/// The shape family a vehicle belongs to.
///
/// Carried on `VehicleUnit`, and therefore inside the mesh key, because it is
/// the one thing that changes the geometry which length and width do not
/// already say. Two vehicles with the same silhouette and the same dimensions
/// are the same mesh however differently the register names them.
public enum Silhouette: String, Sendable, Codable, Hashable, CaseIterable {
    /// Nothing is known about the class, so nothing is claimed about the shape.
    /// Drawn exactly as everything was drawn before this vocabulary existed.
    case generic

    // MARK: Main line, hauled

    /// An EW IV, a Bpm, a Eurocity coach: a plain box on two bogies.
    case intercityCoach
    /// An IC2000 or a hauled Dosto: two window bands with a belt between them.
    case doubleDeckCoach
    /// A Glacier Express, GoldenPass or Bernina panorama car — glass to the
    /// centre line, which is the only vehicle on the network whose *roof* is
    /// the recognisable part.
    case panoramaCoach
    /// A couchette or sleeper: a high sill and small windows, because the beds
    /// are behind them.
    case sleeperCoach
    /// A luggage or mail van. No glass at all.
    case luggageVan

    // MARK: Main line, powered

    /// A Re 460, a Re 620, an Ae 6/6: a machine with a cab at each end.
    case electricLoco
    /// A shunter or a depot tractor — low, short, and mostly hood.
    case shunter
    /// The power car of an ICE 1 or a TGV: a long nose and no windows behind it.
    case highSpeedPower
    /// The body of a high-speed or tilting set — an ICE 4, a Giruno, an Astoro,
    /// an ICN. Lower-roofed than a coach, because they are.
    case highSpeedCar

    // MARK: Multiple units

    /// A KISS, a DTZ, a MUTZ, an FV-Dosto. Two decks, and — the thing that
    /// actually identifies one from a distance — a driving end whose roof is a
    /// storey lower than the body behind it.
    case doubleDeckUnit
    /// A FLIRT, a NINA, a Domino: single deck, low floor, a deep window band
    /// and a short rounded nose.
    case suburbanUnit
    /// The passenger module of a GTW or a Traverso — floor at platform height,
    /// glass from the knee up.
    case lowFloorUnit
    /// The traction container in the middle of a GTW, which is the whole reason
    /// a GTW is recognisable: four metres of blank, full-height machinery
    /// between two long low cars.
    case gtwPower
    /// An Allegra, a Capricorn, a zb Fink: metre-gauge, and shorter and lower
    /// in every dimension than the standard-gauge stock beside it.
    case narrowGaugeUnit

    // MARK: The mountain

    /// A rack railcar: a Rigi BDhe, a Pilatus Bhe, a Jungfrau or Wengernalp
    /// car, a Gornergrat Bhe. Short, tall, upright at the front, and wearing a
    /// deep roof that overhangs it.
    case rackTrainCar
    /// The open-sided trailer a rack railcar pushes: almost all window, and a
    /// roof that reads as a canopy rather than as the top of a box.
    case rackTrailer
    /// A modern articulated rack unit: the Stadler sets that have worked
    /// Vitznau–Rigi Kulm since 2021, and the ones on order for Arth-Goldau.
    /// Not a railcar pushing a trailer — one 35 m vehicle in two sections over
    /// a centre joint, panoramic glass most of the way up the side, and a flat
    /// upright cab at each end.
    case rackUnit
    /// A funicular car, which is a staircase with walls: the body steps down
    /// the slope rather than lying along it.
    case funicularCar
    /// A gondola or aerial tramway cabin — narrow, rounded, and hanging.
    case aerialCabin

    // MARK: Urban

    /// A low-floor tram: floor at the kerb, glass at the knee, roof full of
    /// equipment.
    case tramCar
    /// A metro car — higher floor than a tram, flat front, no nose.
    case metroCar
    /// A city bus or trolleybus body.
    case cityBus
    /// A trolleybus: the same body, a little taller, because the roof carries
    /// the traction gear a diesel bus keeps at the back.
    case trolleybus
    /// A regional or long-distance coach: high floor, luggage under it.
    case coachBus

    // MARK: Water

    /// A lake boat.
    case boatHull
}

extension Silhouette {
    /// The end this silhouette implies, where nothing more specific is said.
    ///
    /// A fallback rather than an override: `VehicleUnit.nose` still wins where
    /// a caller has set one, which is what lets a library entry state a shape
    /// the class table has no opinion about. Nil means "whatever the kind
    /// implies", which is the right answer for every hauled coach — a coach
    /// does not have a nose.
    public var nose: Nose? {
        switch self {
        case .highSpeedPower, .highSpeedCar: return .streamlined
        case .doubleDeckUnit: return .wedge
        case .suburbanUnit, .lowFloorUnit, .narrowGaugeUnit: return .bulb
        case .rackTrainCar, .rackTrailer, .rackUnit, .funicularCar: return .slab
        case .tramCar, .metroCar, .aerialCabin: return .blunt
        case .generic, .intercityCoach, .doubleDeckCoach, .panoramaCoach,
             .sleeperCoach, .luggageVan, .electricLoco, .shunter, .gtwPower,
             .cityBus, .trolleybus, .coachBus, .boatHull:
            return nil
        }
    }

    /// Whether the body has two passenger decks in it.
    ///
    /// Asked by the mesh rather than read off `VehicleUnit.doubleDeck`, because
    /// the two can disagree honestly: a `Bt(2E)` driving trailer is a
    /// double-decker whose *cab end* is single-storey, and the deck flag is
    /// about the body while this is about the stack of bands drawn for it.
    public var isDoubleDeck: Bool {
        self == .doubleDeckCoach || self == .doubleDeckUnit
    }

    /// Whether the sides carry windows worth drawing as glass.
    public var isGlazed: Bool {
        switch self {
        case .luggageVan, .electricLoco, .shunter, .highSpeedPower, .gtwPower:
            return false
        default:
            return true
        }
    }

    /// How far above the ground this body is carried, in metres.
    ///
    /// One case, and it is the only honest way to draw it. A gondola or an
    /// aerial tramway cabin does not stand on anything: it hangs from a rope
    /// strung between pylons, forty metres over a hillside nobody has built a
    /// track on. The map was drawing them as trains sitting on the mountain —
    /// which is not a small error of style, it is the wrong claim about where
    /// the vehicle is, and on a slope it put a cabin *inside* the rock the rope
    /// spans.
    ///
    /// Baked into the mesh rather than carried on the placement, and that is
    /// deliberate: the height a cabin flies at is a fact about the vehicle, not
    /// about where it happens to be, so it belongs in the shape that is built
    /// once. It costs nothing per frame and it means the hanger above the cabin
    /// — see `VehicleShape.mesh` — is part of the same rigid body as the cabin
    /// under it, which is what stops the two drifting apart over a ridge.
    ///
    /// Modest, because it is multiplied. Every model's cross-section is drawn
    /// at `VehicleShape.modelExaggeration`, so eight metres here is nearer
    /// twelve on screen — which is about where a gondola actually is over a
    /// mid-span meadow, and low enough that one at a station is not floating
    /// over the roof.
    public var hover: Double { self == .aerialCabin ? 8.0 : 0 }

    /// Whether anything holds this body up from below.
    ///
    /// False for the one that hangs. A bogie block drawn under a gondola is a
    /// dark bar running from the meadow up to the cabin, which reads as a
    /// pylon in the wrong place on every frame it is not standing at one.
    public var hasRunningGear: Bool { self != .aerialCabin }

    /// Whether the roof itself is glass.
    ///
    /// One case, and it earns the field: a panorama car is a vehicle whose
    /// entire claim on a tourist's attention is that the roof is a window, and
    /// from a tilted camera the roof is the largest surface on it. Painted the
    /// grey every other roof gets, a Glacier Express is a rake of grey boxes
    /// with a red stripe — which is what it was.
    public var hasGlassRoof: Bool { self == .panoramaCoach }
}

// MARK: - How tall each band is

/// The horizontal bands one silhouette is built from, in real metres above
/// rail level.
///
/// Nothing here is invented for effect. A low-floor tram really does have its
/// floor 35 cm over the road and its glass starting at the knee; a rack railcar
/// really is short and tall and wearing a deep roof; a GTW's power module
/// really is a blank tower between two long low cars. The proportions are what
/// make one recognisable, so they are what is written down.
public struct BodyBands: Sendable, Hashable {
    /// The top of the underframe — where the body starts.
    public var floor: Double
    /// The window sill.
    public var waist: Double
    /// The cant rail: the top of the glass, and where a class band is painted.
    public var cant: Double
    /// Where the sides turn in toward the roof.
    public var shoulder: Double
    /// The top of the roof.
    public var roof: Double
    /// How wide the roof is as a share of the body, at the gutter.
    public var roofWidth: Double
    /// How wide what hangs under the floor is, as a share of the body. A bus's
    /// tyres stand nearly at the body's edge; a coach's bogies hide well inside
    /// it.
    public var underWidth: Double

    /// Only on a double-decker: the sill and cant of the *upper* saloon. The
    /// belt between the two window bands is the whole of how one is recognised
    /// from the side.
    public var upperWaist: Double?
    public var upperCant: Double?

    public init(
        floor: Double, waist: Double, cant: Double, shoulder: Double, roof: Double,
        roofWidth: Double = 0.87, underWidth: Double = 0.70,
        upperWaist: Double? = nil, upperCant: Double? = nil
    ) {
        self.floor = floor
        self.waist = waist
        self.cant = cant
        self.shoulder = shoulder
        self.roof = roof
        self.roofWidth = roofWidth
        self.underWidth = underWidth
        self.upperWaist = upperWaist
        self.upperCant = upperCant
    }
}

extension Silhouette {
    /// The bands this silhouette is drawn from, or nil for `.generic`, which is
    /// drawn the way everything was drawn before this table existed.
    ///
    /// Nil rather than a copy of the old numbers on purpose. The old stack is
    /// chosen by `UnitKind` and `Mode` together — a coach in tram mode is a
    /// tram — and reproducing that here would be a second copy of a rule that
    /// is already written down once. `VehicleShape.stack` asks this first and
    /// falls through to the kind when the answer is nil, so there is exactly
    /// one description of the ordinary case and it is the one that was always
    /// there.
    public var bands: BodyBands? {
        switch self {
        case .generic:
            return nil

        case .intercityCoach:
            return BodyBands(floor: 1.00, waist: 2.25, cant: 3.05, shoulder: 3.62, roof: 4.05)
        case .sleeperCoach:
            // A higher sill and a shallower window, because there are berths
            // behind them rather than seats.
            return BodyBands(floor: 1.05, waist: 2.42, cant: 3.02, shoulder: 3.62, roof: 4.05)
        case .panoramaCoach:
            // Glass from below the shoulder to the centre line. The sill is low
            // and the cant rail is high, which is the whole design.
            return BodyBands(
                floor: 1.00, waist: 1.92, cant: 3.32, shoulder: 3.74, roof: 4.05,
                roofWidth: 0.78
            )
        case .luggageVan:
            return BodyBands(floor: 1.00, waist: 2.25, cant: 3.05, shoulder: 3.62, roof: 4.05)
        case .doubleDeckCoach:
            return BodyBands(
                floor: 0.60, waist: 1.25, cant: 2.05, shoulder: 4.22, roof: 4.62,
                roofWidth: 0.92,
                upperWaist: 2.75, upperCant: 3.55
            )
        case .doubleDeckUnit:
            // A shade lower on its springs than the hauled stock, and a shade
            // taller overall: a KISS stands 4.60 m to the roof over a 0.52 m
            // floor, which is most of the height difference a platform shows.
            return BodyBands(
                floor: 0.52, waist: 1.18, cant: 1.98, shoulder: 4.24, roof: 4.60,
                roofWidth: 0.92,
                upperWaist: 2.72, upperCant: 3.60
            )

        case .electricLoco:
            return BodyBands(
                floor: 1.05, waist: 2.50, cant: 3.22, shoulder: 3.78, roof: 4.28,
                roofWidth: 0.80
            )
        case .shunter:
            // Short and low, and mostly bonnet. A Tm is two metres shorter in
            // the roof than the coaches it is moving.
            return BodyBands(
                floor: 0.95, waist: 2.05, cant: 2.72, shoulder: 3.10, roof: 3.48,
                roofWidth: 0.62
            )
        case .highSpeedPower:
            return BodyBands(
                floor: 1.00, waist: 2.35, cant: 3.02, shoulder: 3.52, roof: 3.90,
                roofWidth: 0.74
            )
        case .highSpeedCar:
            // Lower than a coach on purpose: everything built for 200 km/h and
            // up is, and next to an EW IV rake it shows.
            return BodyBands(
                floor: 0.95, waist: 2.12, cant: 2.96, shoulder: 3.56, roof: 3.92,
                roofWidth: 0.82
            )

        case .suburbanUnit:
            // The low floor is the point. A FLIRT's sill is 60 cm over the
            // rail and its glass runs from there to the shoulder, which is why
            // one reads as a greenhouse next to an intercity coach.
            return BodyBands(
                floor: 0.62, waist: 1.86, cant: 2.96, shoulder: 3.56, roof: 4.03,
                underWidth: 0.66
            )
        case .lowFloorUnit:
            return BodyBands(
                floor: 0.44, waist: 1.62, cant: 2.86, shoulder: 3.42, roof: 3.88,
                underWidth: 0.64
            )
        case .gtwPower:
            // No glass anywhere and full height throughout. The module is all
            // machinery, and drawn with a window band it stops being the thing
            // that makes a GTW a GTW — it becomes a very short coach. Taller
            // than the cars either side of it, which is the other half of the
            // silhouette: the roofline steps up in the middle and back down.
            return BodyBands(
                floor: 0.55, waist: 3.16, cant: 3.22, shoulder: 3.84, roof: 4.32,
                roofWidth: 0.70, underWidth: 0.74
            )
        case .narrowGaugeUnit:
            return BodyBands(
                floor: 0.78, waist: 1.98, cant: 2.94, shoulder: 3.40, roof: 3.78,
                roofWidth: 0.84, underWidth: 0.68
            )

        case .rackTrainCar:
            // Short, upright and deep-roofed. The roof is 44 cm of the 3.72 m —
            // a proportion no main-line vehicle has — and it is what somebody
            // recognises in a photograph of a Rigi or a Pilatus car.
            return BodyBands(
                floor: 0.92, waist: 1.86, cant: 2.94, shoulder: 3.28, roof: 3.72,
                roofWidth: 0.80, underWidth: 0.72
            )
        case .rackTrailer:
            // Glass from the elbow up and no solid side to speak of: the
            // open-sided trailers behind a Rigi railcar are a roof, a floor and
            // a row of posts.
            return BodyBands(
                floor: 0.90, waist: 1.42, cant: 2.86, shoulder: 3.12, roof: 3.55,
                roofWidth: 0.78, underWidth: 0.72
            )
        case .rackUnit:
            // Taller and glassier than the car it replaces, and without the
            // deep overhanging roof: the whole selling point of the Stadler
            // sets is the window, so the sill is low, the cant rail is high
            // and what is left over the top of it is a gutter.
            return BodyBands(
                floor: 0.88, waist: 1.96, cant: 2.98, shoulder: 3.42, roof: 3.80,
                roofWidth: 0.82, underWidth: 0.74
            )
        case .funicularCar:
            return BodyBands(
                floor: 0.30, waist: 1.25, cant: 2.32, shoulder: 2.78, roof: 3.05,
                roofWidth: 0.80, underWidth: 0.78
            )
        case .aerialCabin:
            // A gondola is a pod: nearly all glass, very narrow, and with a
            // roof drawn in hard because the hanger sits on it.
            return BodyBands(
                floor: 0.28, waist: 0.92, cant: 2.28, shoulder: 2.58, roof: 2.86,
                roofWidth: 0.55, underWidth: 0.60
            )

        case .tramCar:
            return BodyBands(
                floor: 0.35, waist: 1.50, cant: 2.52, shoulder: 3.05, roof: 3.42,
                underWidth: 0.62
            )
        case .metroCar:
            return BodyBands(floor: 0.60, waist: 1.70, cant: 2.70, shoulder: 3.14, roof: 3.45)
        case .cityBus:
            return BodyBands(
                floor: 0.42, waist: 1.75, cant: 2.58, shoulder: 2.98, roof: 3.20,
                underWidth: 0.92
            )
        case .trolleybus:
            // A hand taller than a diesel bus, because the traction gear a
            // diesel keeps in the tail is on the roof of a trolleybus — and on
            // a street where both run, the roofline is what separates them.
            return BodyBands(
                floor: 0.38, waist: 1.72, cant: 2.62, shoulder: 3.06, roof: 3.42,
                underWidth: 0.92
            )
        case .coachBus:
            // A high floor with the luggage under it, which is the difference
            // between a PostAuto on a pass and a city bus in a suburb.
            return BodyBands(
                floor: 0.82, waist: 2.05, cant: 2.98, shoulder: 3.32, roof: 3.62,
                roofWidth: 0.84, underWidth: 0.94
            )

        case .boatHull:
            return nil
        }
    }
}
