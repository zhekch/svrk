import Foundation

// What a vehicle is made of, as something drawn from above needs to know it.
//
// The panel's `Coach` is the wrong object for this and it is worth saying why.
// A `Coach` is one vehicle *as the formation service files it*: a class code, a
// reservation number, the sector it stands in at one particular stop. All of
// that is about a passenger finding a seat, and none of it is about a shape on
// a map — which needs three numbers the service never sends (how long, how
// wide, which end has a cab) and needs them for every bus and tram in the
// country, which the service does not carry at all.
//
// So this is the drawing's own vocabulary: a list of rigid bodies with real
// dimensions, in the direction of travel, front first. It is filled from the
// formation service where that can answer and from `LayoutLibrary` where it
// cannot, and the two produce the same type — so nothing downstream has to know
// which it got.

/// What kind of body one unit is, as far as the outline cares.
public enum UnitKind: String, Sendable, Codable, Hashable {
    /// Short, blunt, heavy, a cab at each end and a pantograph or two.
    case locomotive
    /// The end car of a multiple unit, or a driving trailer at the far end of a
    /// push-pull set: a cab on the outward end and a gangway on the other.
    case drivingCar
    /// An ordinary hauled coach, or an intermediate car of a unit.
    case coach
    /// A luggage or mail van. Shorter, and no windows to speak of.
    case van
    /// One module of a tram or an articulated bus: the joints between them are
    /// bellows rather than couplers, so there is no gap to draw.
    case module
    /// A rigid bus or coach.
    case bus
    /// A boat. Wide enough that the top view is the informative one.
    case hull
    /// A funicular or cable-car cabin.
    case cabin

    /// The kinds that produce the same outline, collapsed.
    ///
    /// A coach, an end car and a luggage van are drawn by the same code: what
    /// makes one of them look different is its cab flags and its length, and
    /// both of those are compared separately. Keeping them distinct here made
    /// `drawsAlike` answer no to every observation — the library builds a set
    /// with `.drivingCar` at each end and a formation only ever says "coach" —
    /// so a train that matched the guess perfectly was still filed as a
    /// correction, and the confirmation path was dead code.
    public var drawnAs: UnitKind {
        switch self {
        case .coach, .drivingCar, .van: return .coach
        default: return self
        }
    }
}

/// What holds this unit to the one in front of it.
///
/// A property of the *unit*, not of its kind, because the two ends of a tram
/// are ordinary driving cars and the joints either side of them are still
/// bellows. Read off the kind instead, a five-module Combino came out as three
/// modules articulated and two coupled, with a gap drawn at each end where the
/// real vehicle is continuous.
public enum Joint: String, Sendable, Codable, Hashable {
    /// A coupler: about a metre of daylight between two vehicles.
    case coupler
    /// A gangway or bellows: no gap at all, because it is one body.
    case bellows
    /// Nothing in front — this is the leading unit.
    case none
}

/// Which class the unit carries, which is the one piece of livery a passenger
/// on the platform is actually looking for.
public enum ClassBand: String, Sendable, Codable, Hashable {
    case none, first, second, mixed
    /// A dining or bistro car, which is neither and is marked differently.
    case dining
}

/// How much of a vehicle's side carries the class band, and at which end.
///
/// The service says a coach is `12` — first *and* second — and never says which
/// half is which. The train around it does: a half-and-half coach next to a
/// first-class one has its first-class half against that neighbour, because
/// the whole point of marshalling it that way is that the two make one
/// continuous first-class section for a passenger walking through. Drawn at the
/// wrong end it puts a gap in the middle of the first class and a stripe
/// against the second, which is exactly backwards. The same rule already
/// decides it for the side view in `FormationView.stripe(of:at:)`.
public enum Stripe: String, Sendable, Codable, Hashable {
    case none
    case full
    /// The half toward the front of the train.
    case leadingHalf
    /// The half toward the back.
    case trailingHalf
}

/// The shape of a body's driving end, where its kind does not already say it.
///
/// A driving car is a driving car whether it is the flat front of a Cobra, the
/// square-shouldered cab of an S-Bahn unit or the seven metres of taper on an
/// ICE — and from directly above that difference is the most recognisable thing
/// about any of them. The kind cannot carry it: all three are `.drivingCar`,
/// and a tram module and a high-speed end car are the same word.
///
/// `nil` means "whatever the kind implies", which is what nearly every unit
/// wants — and being optional is also what lets a layout written down by an
/// older build still decode.
public enum Nose: String, Sendable, Codable, Hashable {
    /// A high-speed nose: a long, smooth taper to a rounded point.
    case streamlined
    /// A tram's front: almost flat, with the corners taken well off. What a
    /// Cobra, a Flexity and a Bem 4/6 all look like from above.
    case blunt
    /// The long, low nose of a double-deck unit — a KISS, a DTZ, an FV-Dosto.
    ///
    /// Its signature is not the plan at all, it is the elevation: the driving
    /// end is a single storey and the body behind it is two, so the roof steps
    /// up a metre and a half a few metres back from the windscreen. From a
    /// tilted camera that step is the most recognisable thing about the
    /// commonest train in the country, and drawn with the flat `cab` a KISS was
    /// an IC2000 with a bevel on it. See `VehicleShape.rake`.
    case wedge
    /// The short, full, rounded nose Stadler puts on everything: a FLIRT, a
    /// NINA, a Domino, an Allegra. Wider at the tip than a cab and rounder in
    /// plan, which is exactly what a one-piece moulded front looks like from
    /// above.
    case bulb
    /// An upright front with the corners rounded off, and nothing else: a rack
    /// railcar, a funicular, an open trailer. These are vehicles built to climb
    /// rather than to run, and none of them has a metre of nose to spare.
    case slab
}

/// One rigid body in the vehicle.
///
/// Dimensions are metres of real vehicle, so a 26.4 m intercity coach is drawn
/// longer than an 18.7 m regional car and a 200 m train is drawn twice the
/// length of a 100 m one on the same map. That is most of what makes the
/// drawing worth doing: length is the thing a top view can say that a dot
/// cannot.
public struct VehicleUnit: Sendable, Codable, Hashable {
    public var kind: UnitKind
    /// Body length over couplers, in metres.
    public var length: Double
    /// Body width, in metres. Standard gauge stock is about 2.9; metre gauge is
    /// 2.65; a bus is 2.55; a lake boat is 8 to 16.
    public var width: Double
    /// A driving cab on the leading end, which is what makes the front of a
    /// train a nose rather than a wall.
    public var cabFront: Bool
    /// A driving cab on the trailing end. True at both ends of a locomotive and
    /// of a single railcar.
    public var cabBack: Bool
    /// How many pantographs sit on the roof. Nothing else on the drawing says
    /// "this one is the powered vehicle".
    public var pantographs: Int
    /// Whether the body is double-deck, which from above is a wider roof and no
    /// deep window recess.
    public var doubleDeck: Bool
    public var band: ClassBand
    /// Passenger doors per side. Drawn as ticks on the body edge at close zoom;
    /// a locomotive has none, a metro car has four.
    public var doors: Int
    /// Whether this vehicle is on the train but shut to passengers.
    public var closed: Bool
    /// How this unit is joined to the one in front of it.
    public var joint: Joint
    /// What the driving end looks like, where the kind does not decide it.
    public var nose: Nose?
    /// What shape family this vehicle belongs to.
    ///
    /// The one field that changes the geometry which the dimensions do not
    /// already say, and therefore the one that had to be added rather than
    /// derived at the point of drawing. `length`, `width` and `doubleDeck`
    /// describe a *box*; this says whether the box is a rack railcar, a
    /// gondola, a GTW power module or an intercity coach, all of which stand
    /// at different heights, are glazed differently and end differently.
    ///
    /// An archetype and not a class, deliberately — see `Silhouette`. It is
    /// read off `type` by `WagonCatalogue` for an observed formation and set
    /// outright by `LayoutLibrary` for a guessed one, so the two agree about
    /// what a FLIRT looks like whichever of them drew it.
    ///
    /// `.generic` for a vehicle nothing is known about, which is not a
    /// fallback shape but the *previous* shape: a record migrated from version
    /// 2 of the database has no class names in it at all, and every such wagon
    /// has to go on looking exactly as it did.
    public var silhouette: Silhouette = .generic
    /// What the rolling-stock register calls this vehicle — `RABe511`, `Bt`,
    /// `A(2E)`.
    ///
    /// The evidence behind every other field here, kept rather than discarded.
    /// The dimensions above are *read off* this name at the moment a formation
    /// arrives, so a database that stored only the dimensions remembered the
    /// conclusions and threw away what they were drawn from — and a better
    /// reading of the same names could never reach anything already on file.
    /// Nil for a vehicle the app is guessing at rather than one it was told
    /// about, which is every layout `LayoutLibrary` builds. See `WagonType`.
    public var type: WagonType?
    /// Where the class band runs, once the train around it has been read.
    /// Written by `VehicleLayout.resolvingStripes()`, not by the caller.
    public var stripe: Stripe = .none

    public init(
        kind: UnitKind, length: Double, width: Double = VehicleUnit.standardGaugeWidth,
        cabFront: Bool = false, cabBack: Bool = false, pantographs: Int = 0,
        doubleDeck: Bool = false, band: ClassBand = .none, doors: Int = 2,
        closed: Bool = false, joint: Joint = .coupler, nose: Nose? = nil,
        type: WagonType? = nil, silhouette: Silhouette = .generic
    ) {
        self.silhouette = silhouette
        self.kind = kind
        self.length = length
        self.width = width
        self.cabFront = cabFront
        self.cabBack = cabBack
        self.pantographs = pantographs
        self.doubleDeck = doubleDeck
        self.band = band
        self.doors = doors
        self.closed = closed
        self.joint = joint
        self.nose = nose
        self.type = type
    }

    /// The width of standard-gauge Swiss passenger stock, near enough.
    public static let standardGaugeWidth = 2.9
    /// Metre-gauge stock — RhB, MOB, the Zentralbahn — is noticeably narrower,
    /// and on a top view that is the only place the gauge shows.
    public static let metreGaugeWidth = 2.65
    public static let busWidth = 2.55
}

// MARK: - Writing a unit down

// A unit written out in full is 185 bytes of JSON, and 6,500 of them are most
// of a megabyte and a half. Nearly all of that is fields saying what a coach
// already is: 2.9 metres wide, two doors, no pantograph, coupled to the one in
// front, no cab, single-deck, no class band. The synthesised `Codable` has no
// way of knowing which of those are worth saying, so it says all of them, for
// every vehicle on every train in the country.
//
// So the encoding leaves out anything that already holds its default value and
// the decoding puts it back. The median unit goes from twelve fields to four,
// and the bundled database from 1.4 MB to about 640 kB, with not one fact lost:
// a field that is absent is a field that was ordinary.
//
// This is the same idea as dropping the livery. The file should carry what is
// true of *this* train and nothing that is true of trains in general.
extension VehicleUnit {
    enum CodingKeys: String, CodingKey {
        case kind, length, width, cabFront, cabBack, pantographs, doubleDeck
        case band, doors, closed, joint, nose, type, stripe, silhouette
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // The two that every unit has to state: nothing sensible to default a
        // kind or a length to, and both differ on nearly every vehicle anyway.
        try c.encode(kind, forKey: .kind)
        try c.encode(length, forKey: .length)

        if width != VehicleUnit.standardGaugeWidth { try c.encode(width, forKey: .width) }
        if cabFront { try c.encode(cabFront, forKey: .cabFront) }
        if cabBack { try c.encode(cabBack, forKey: .cabBack) }
        if pantographs != 0 { try c.encode(pantographs, forKey: .pantographs) }
        if doubleDeck { try c.encode(doubleDeck, forKey: .doubleDeck) }
        if band != .none { try c.encode(band, forKey: .band) }
        if doors != 2 { try c.encode(doors, forKey: .doors) }
        if closed { try c.encode(closed, forKey: .closed) }
        if joint != .coupler { try c.encode(joint, forKey: .joint) }
        if stripe != .none { try c.encode(stripe, forKey: .stripe) }
        if silhouette != .generic { try c.encode(silhouette, forKey: .silhouette) }
        try c.encodeIfPresent(nose, forKey: .nose)
        try c.encodeIfPresent(type, forKey: .type)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The defaults here must be the same defaults `encode(to:)` omits on,
        // and the same ones `init(kind:length:...)` applies. Three copies of one
        // list is how a format quietly starts losing things, so any change to a
        // default belongs in all three at once.
        kind = try c.decode(UnitKind.self, forKey: .kind)
        length = try c.decode(Double.self, forKey: .length)
        width = try c.decodeIfPresent(Double.self, forKey: .width)
            ?? VehicleUnit.standardGaugeWidth
        cabFront = try c.decodeIfPresent(Bool.self, forKey: .cabFront) ?? false
        cabBack = try c.decodeIfPresent(Bool.self, forKey: .cabBack) ?? false
        pantographs = try c.decodeIfPresent(Int.self, forKey: .pantographs) ?? 0
        doubleDeck = try c.decodeIfPresent(Bool.self, forKey: .doubleDeck) ?? false
        band = try c.decodeIfPresent(ClassBand.self, forKey: .band) ?? .none
        doors = try c.decodeIfPresent(Int.self, forKey: .doors) ?? 2
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        joint = try c.decodeIfPresent(Joint.self, forKey: .joint) ?? .coupler
        stripe = try c.decodeIfPresent(Stripe.self, forKey: .stripe) ?? .none
        // A record written before this vocabulary existed has no silhouette in
        // it, and `.generic` is exactly right for one: it says "nothing is
        // claimed about the shape", which is the truth about a unit whose class
        // was never stored.
        silhouette = try c.decodeIfPresent(Silhouette.self, forKey: .silhouette) ?? .generic
        nose = try c.decodeIfPresent(Nose.self, forKey: .nose)
        type = try c.decodeIfPresent(WagonType.self, forKey: .type)
    }
}

/// The colours a vehicle is painted in.
///
/// Held as CSS hex strings rather than as a colour type because the far end of
/// this is a Mapbox style expression, which takes exactly that — and because
/// `TransitCore` has no UIKit in it and is not about to acquire one for six
/// swatches.
public struct Livery: Sendable, Codable, Hashable {
    /// The body sides, which is what carries the operator's identity.
    public var body: String
    /// The roof. Real roofs are grey whoever owns them, which is why the body
    /// colour is drawn out to the edges and the roof only as a band down the
    /// middle — a purely truthful top view of a Swiss train is a grey stripe,
    /// and the whole point of the exercise is to be able to tell an SBB
    /// intercity from a BLS regional at a glance.
    public var roof: String
    /// Doors, stripes, and whatever else is picked out against the body.
    public var trim: String
    /// The band along the top of the side, at cant-rail height.
    ///
    /// The one colour that only the solid drawing can use, and the one that
    /// most decides what a Swiss train looks like. Nearly every modern fleet in
    /// the country is a pale body with a strong band above the windows — SBB's
    /// red on white, VBZ's white over blue, Basel's cream over green — and from
    /// directly above that band is a hairline along the very edge of the body,
    /// which is why the flat drawing has never had a use for it. From a tilted
    /// camera it is most of the vehicle's side.
    ///
    /// Defaults to the body, so an operator painted in one colour stays painted
    /// in one colour and nothing acquires a stripe it does not have.
    var beltOverride: String?
    public var belt: String { beltOverride ?? body }
    /// Windscreens.
    public var glass: String
    /// The outline. Dark against a dark basemap reads better than black.
    public var stroke: String
    /// The two ends, where the company paints them differently from the sides.
    ///
    /// Rarer than a belt and, on the fleets that have it, the first thing
    /// anybody names. The Stadler rack units on the Rigi are a cream train with
    /// *olive* driving ends — a photograph of one is a pale body between two
    /// dark caps, and painted in one colour it is a cream box and could be
    /// anybody's. A Wengernalp car's yellow front is the same fact.
    ///
    /// Only where somebody drives from, which is what makes it an end rather
    /// than a stripe: it is the moulding around the windscreen and the metre or
    /// two of body behind it, so a gangway or the flat end of an intermediate
    /// coach never wears it. See `VehicleShape.mesh`, which cuts the cap off
    /// each end that has a screen in it and paints only that.
    ///
    /// Defaults to the body, so nothing acquires ends it does not have.
    var endsOverride: String?
    public var ends: String { endsOverride ?? body }

    /// The colour of the vehicles that pull, where the company paints them
    /// differently from the ones that are pulled.
    ///
    /// SBB is the reason this exists: its coaches are light grey and its
    /// locomotives are red, and a top view that painted a Re 460 the colour of
    /// the IC2000 behind it lost the one unit on the train with a shape of its
    /// own. Nil where a company paints the whole train alike, which is most of
    /// them.
    var poweredOverride: String?

    /// What a locomotive or power car is painted.
    public var powered: String { poweredOverride ?? body }

    public init(
        body: String, roof: String, trim: String, glass: String, stroke: String,
        powered: String? = nil, belt: String? = nil, ends: String? = nil
    ) {
        self.body = body
        self.roof = roof
        self.trim = trim
        self.glass = glass
        self.stroke = stroke
        self.poweredOverride = powered
        self.beltOverride = belt
        self.endsOverride = ends
    }
}

/// Where a layout came from, which decides whether it is worth writing down.
public enum LayoutSource: String, Sendable, Codable, Equatable {
    /// Resolved from `LayoutLibrary`: what this line normally runs.
    case library
    /// Read off a real formation the service answered with.
    case observed
}

/// One vehicle's composition, front first.
public struct VehicleLayout: Sendable, Codable, Equatable {
    public var units: [VehicleUnit]
    /// What this one is painted, for as long as it is being drawn.
    ///
    /// Runtime only, and deliberately not written down — see `CodingKeys`.
    public var livery: Livery
    /// What this is, in words — "Re 460 + 8 IC2000", "FLIRT, 4 cars". Shown on
    /// the panel, and the thing that makes a wrong entry in the library
    /// noticeable rather than merely subtly wrong.
    public var name: String?
    public var source: LayoutSource

    public init(
        units: [VehicleUnit], livery: Livery, name: String? = nil,
        source: LayoutSource = .library
    ) {
        self.units = units
        self.livery = livery
        self.name = name
        self.source = source
    }

    /// What a stored layout is: the train, and not its paint.
    ///
    /// `livery` is absent, and its absence is the point. Paint is a fact about
    /// the *company*, which is known from the journey without asking anybody —
    /// and every layout read back out of the store has always been repainted on
    /// the way out (`VehicleLayoutStore.layout(for:modeColour:)` ends in
    /// `.painted(_:)`), so the six colour strings on disk were written, read,
    /// and then discarded unused. Worse than wasted: a fleet repainted between
    /// two builds left every record on file asserting a colour that was no
    /// longer true, in a field nothing would ever consult.
    ///
    /// What replaces it is on the units — each carries the register's name for
    /// the vehicle, and `WagonCatalogue` turns that into paint and into a mesh
    /// at the moment of drawing. So the file holds evidence and the app holds
    /// the reading of it, which is the right way round.
    enum CodingKeys: String, CodingKey {
        case units, name, source
    }

    /// Decoded layouts arrive unpainted.
    ///
    /// The placeholder is never seen. Every path that reads a layout out of the
    /// store repaints it from the operator before returning it, and the one
    /// that does not — a hand-written seed loaded for a train nobody is looking
    /// at — is not drawn either. It is grey rather than, say, red so that a
    /// leak of it into the drawing would look like a fault instead of like a
    /// plausible train.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        units = try container.decode([VehicleUnit].self, forKey: .units)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        source = try container.decode(LayoutSource.self, forKey: .source)
        livery = VehicleLayout.unpainted
    }

    /// The colour a layout has before anybody has said who runs it.
    public static let unpainted = Livery(
        body: "#8b929b", roof: "#767c85", trim: "#c9ced4",
        glass: "#2b3440", stroke: "rgba(0,0,0,0.75)"
    )

    /// Over buffers, including the couplings between units.
    public var length: Double {
        guard !units.isEmpty else { return 0 }
        let bodies = units.reduce(0) { $0 + $1.length }
        // A coupler between two vehicles is about a metre of nothing; a bellows
        // between two modules of a tram is part of the body and already counted.
        let joints = units.dropFirst().reduce(0.0) { total, unit in
            total + (unit.joint == .bellows ? 0 : VehicleLayout.couplerGap)
        }
        return bodies + joints
    }

    /// The visible gap between two coupled vehicles, in metres.
    public static let couplerGap = 0.9

    public var widestUnit: Double { units.map(\.width).max() ?? VehicleUnit.standardGaugeWidth }

    /// The same layout with each vehicle's class band placed.
    ///
    /// Run once, when the layout is built, because it is a fact about the train
    /// rather than about the frame: a coach's neighbours do not change between
    /// draws, and working it out fifteen times a second for every vehicle on
    /// screen would be the same answer at a real cost.
    public func resolvingStripes() -> VehicleLayout {
        var copy = self
        for index in copy.units.indices {
            copy.units[index].stripe = Self.stripe(of: units, at: index)
        }
        // The leading vehicle has nothing in front of it, whatever the builder
        // happened to leave in the field. Said once here rather than in each of
        // the places a layout is made, because two of them disagreed — and a
        // layout built one way never matched one built the other.
        if !copy.units.isEmpty { copy.units[0].joint = .none }
        return copy
    }

    /// Which way a half-and-half coach's band faces.
    static func stripe(of units: [VehicleUnit], at index: Int) -> Stripe {
        switch units[index].band {
        case .none, .second: return .none
        case .first, .dining: return .full
        case .mixed: break
        }

        /// Whether a vehicle carries any first class at all, and so whether it
        /// is something worth turning a half-and-half coach's band toward.
        ///
        /// Another half-and-half coach counts, and that is the whole of this.
        /// Looking only for a *wholly* first-class one meant a train that has
        /// none — a regional unit, which is most of them — fell through to the
        /// fallback below and gave every mixed coach the same end. Two of them
        /// coupled together then drew the second class of one against the first
        /// class of the other, splitting the first class in two with the length
        /// of two half-coaches between the halves: the exact fault this rule
        /// exists to prevent, in the one case it was not being applied to.
        ///
        /// The side view has always read it this way — see
        /// `FormationView.stripe(of:at:)`, where the test is "has a band at
        /// all" — so the two drawings of one train now agree.
        func carriesFirst(_ band: ClassBand) -> Bool {
            switch band {
            case .first, .mixed, .dining: return true
            case .none, .second: return false
            }
        }

        /// How many vehicles away the nearest one with first class in it is.
        func distanceToFirst(_ range: any Sequence<Int>) -> Int? {
            for i in range where carriesFirst(units[i].band) { return abs(i - index) }
            return nil
        }
        let ahead = distanceToFirst(stride(from: index - 1, through: 0, by: -1))
        let behind = distanceToFirst((index + 1)..<units.count)

        switch (ahead, behind) {
        case let (ahead?, behind?): return ahead <= behind ? .leadingHalf : .trailingHalf
        case (_?, nil): return .leadingHalf
        case (nil, _?): return .trailingHalf
        // The only coach on the train with any first class in it: nothing to
        // join up with, and either end is as good.
        case (nil, nil): return .leadingHalf
        }
    }

    /// The same layout with a different paint job.
    ///
    /// The library keys stock by what it *is* and liveries by who owns it, and
    /// the two do not line up: a FLIRT is a FLIRT whether it is green for
    /// Thurbo or red for TPF. So a layout is built once and painted after.
    public func painted(_ livery: Livery) -> VehicleLayout {
        var copy = self
        copy.livery = livery
        return copy
    }

    /// Whether two layouts would draw the same.
    ///
    /// Compared on the shapes rather than on the whole value, because a livery
    /// difference is not a formation difference — and the question this answers
    /// is "did the service tell us something the library did not already know",
    /// which is about the train and not about its paint.
    public func drawsAlike(_ other: VehicleLayout) -> Bool {
        guard units.count == other.units.count else { return false }
        for (a, b) in zip(units, other.units) {
            guard a.kind.drawnAs == b.kind.drawnAs,
                  a.cabFront == b.cabFront, a.cabBack == b.cabBack,
                  a.joint == b.joint,
                  a.band == b.band, a.doubleDeck == b.doubleDeck,
                  abs(a.length - b.length) < 0.75, abs(a.width - b.width) < 0.2
            else { return false }
        }
        return true
    }
}
