import Foundation

// A vehicle as a solid, in real coordinates and real metres of height.
//
// `VehicleFootprint` draws a vehicle from directly above, which is the only
// honest thing to draw on a map that is looking straight down. Tilt the camera
// and that stops being true: a flat red rectangle lying on the ground at sixty
// degrees of pitch is a red rectangle lying on the ground, and the station it
// is standing in has buildings with height and a terrain with relief around it.
// The train is then the one thing in the scene with no thickness.
//
// So past a certain pitch and a certain zoom the same vehicle is built again as
// a solid. Not a different drawing — the *same* geometry, sliced. Every slab
// here is a plan outline produced by the same `outline` that draws the flat
// shape, narrowed and shortened by a little at each level up, and given the two
// heights it spans. A renderer that can extrude a polygon between two heights
// then has a low-poly vehicle: a chassis under an overhanging body, a window
// band, shoulders drawn in, a roof narrower again, and a nose that rakes back
// as it rises because each level up is held further off the tip than the one
// below it.
//
// **Slabs, and then a mesh made out of them.** The slabs are what this file
// produces and they are no longer what the map draws: `VehicleGLB` turns them
// into a `.glb` and the renderer is handed that once, by name. The reason the
// geometry still starts here is the one that mattered from the beginning — the
// silhouette of the solid from above is *exactly* the flat drawing, because it
// is the same `outline`, and that is the entire reason tilting the map reads as
// one object standing up rather than as two objects being swapped. A mesh
// drawn by hand could not promise that, and would have wanted an asset pipeline
// and a binary per livery to fail to promise it.
//
// Faceting is the price and it is not really a price: the whole look is
// low-poly on purpose, and at the size a vehicle occupies on a phone nothing
// finer would survive the rasteriser anyway.
//
// **Everything here is in the vehicle's own metres**, and that is what changed
// when the models arrived. A shape that has already been turned into longitudes
// belongs to one position and one heading and can be reused for neither; built
// in its own frame, one mesh serves every wagon in the country that looks like
// it. `UnitMesh.projected(by:)` puts one on the earth for the renderer that
// still wants polygons.

/// A point in a vehicle's own frame: metres forward from its back end, metres
/// to the right of the way it faces.
public struct MeshPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One horizontal slice of a vehicle, in the vehicle's own metres.
///
/// The same slice `MeshSlab` describes, before anything has decided where on
/// the earth the vehicle is. This is the form the mesh is *built* in and the
/// only form it can be baked from: a model is a shape, and a shape that has
/// already been turned into longitudes is a shape that belongs to one position
/// and one heading and can never be reused for another. See `VehicleGLB`.
public struct LocalSlab: Sendable, Equatable {
    public var role: MeshSlab.Role
    public var rings: [[MeshPoint]]
    public var base: Double
    public var top: Double
    public var fill: String

    public init(
        role: MeshSlab.Role, rings: [[MeshPoint]],
        base: Double, top: Double, fill: String
    ) {
        self.role = role
        self.rings = rings
        self.base = base
        self.top = top
        self.fill = fill
    }
}

/// One wagon, as a shape: every slice of it, in its own metres.
///
/// What gets baked. Two vehicles with the same mesh are the same model however
/// far apart they are and whichever way they are pointing, which is the whole
/// economy of the thing: a sixteen-coach train is two models and fourteen
/// copies of one of them.
public struct UnitMesh: Sendable, Equatable {
    public var slabs: [LocalSlab]
    /// The extent the mesh actually occupies, in its own metres. Carried
    /// because whoever places it needs to know where its middle is without
    /// walking every vertex again.
    public var length: Double
    public var width: Double
    public var height: Double

    public init(slabs: [LocalSlab], length: Double, width: Double, height: Double) {
        self.slabs = slabs
        self.length = length
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { slabs.isEmpty }
}

extension UnitMesh {
    /// The same slices, put on the earth at a heading.
    ///
    /// For the renderer that cannot be handed a mesh and has to be handed
    /// polygons instead. Derived from the model's own geometry rather than
    /// built separately, so the two drawings of a wagon cannot drift apart:
    /// there is one shape and this is it, projected.
    public func projected(by frame: VehicleShape.Frame) -> [MeshSlab] {
        slabs.map { slab in
            MeshSlab(
                role: slab.role,
                rings: slab.rings.map { frame.project($0) },
                base: slab.base, top: slab.top, fill: slab.fill
            )
        }
    }
}

/// One horizontal slice of a vehicle: a plan outline, and the two heights it
/// spans above the ground the vehicle is standing on.
public struct MeshSlab: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        /// Under the floor — bogies, the underframe, a bus's tyres. Narrower
        /// than the body, so the body overhangs it and the vehicle has a
        /// shadow line down its side instead of being one flat-sided brick.
        case chassis
        /// The lower side, in the operator's colour: the part of a vehicle
        /// somebody recognises it by.
        case body
        /// The window band, which is where most of a train's side actually is
        /// and the single clearest cue that the block is a vehicle at all.
        case glazing
        /// Where the side turns over into the roof, drawn in a little.
        case shoulder
        case roof
        /// What stands on the roof and is not a pantograph: a tram's equipment
        /// boxes, a bus's air conditioning.
        case dome
        case pantograph
        /// A bogie, or a road vehicle's wheels: the dark blocks the body
        /// actually stands on, with daylight between them.
        case bogie
        /// A door, standing a hair proud of the side it is set into.
        case door
        /// The class band, standing very slightly proud of the side it is on.
        case stripe
        /// The class number on the side: `1`, `2`, the same plate the
        /// formation drawing writes inside each coach.
        case lettering
        /// A head or tail lamp, on the front of the wagon that carries one.
        ///
        /// Part of the mesh rather than a marker beside it, which is the whole
        /// difference. A lamp drawn separately has to be told where the nose is
        /// on every frame, and it is only ever as right as that telling; a lamp
        /// that *is* the nose cannot be anywhere else. It is also the only way
        /// a lamp gets hidden by the vehicle carrying it, which is what stops a
        /// train wearing its own tail lights on its face.
        case lamp
    }

    public var role: Role
    /// The plan outlines this slab is extruded from — usually one, sometimes
    /// several.
    ///
    /// Several is the whole of how a vehicle is held together on terrain, and
    /// it is worth spelling out why. A renderer standing a polygon up over a
    /// hillside has to decide what "the ground" under it is, and there is only
    /// one answer that does not shear the polygon: pick a single elevation for
    /// the whole thing. Mapbox picks it from the geometry's own centre — which
    /// means two features that belong to the same wagon but sit at different
    /// places along it are grounded at *different* elevations, and on a slope
    /// they slide apart.
    ///
    /// So everything that would have been several features is one. The two
    /// bogies under a coach are one slab of two rings; the five doors down a
    /// tram are one slab of five. Each of those sets is symmetric about the
    /// middle of the body it belongs to, so its centre — and therefore the
    /// ground it is standing on — is the body's own. The wagon cannot come
    /// apart, because there is no longer anything to come apart *from*.
    public var rings: [[Coord]]
    /// Metres above the ground, at the bottom and the top of the slice.
    public var base: Double
    public var top: Double
    public var fill: String

    public init(role: Role, rings: [[Coord]], base: Double, top: Double, fill: String) {
        self.role = role
        self.rings = rings
        self.base = base
        self.top = top
        self.fill = fill
    }

    public init(role: Role, ring: [Coord], base: Double, top: Double, fill: String) {
        self.init(role: role, rings: [ring], base: base, top: top, fill: fill)
    }

    /// The first outline, for the things that only ever have one.
    public var ring: [Coord] { rings.first ?? [] }
}

extension VehicleShape {

    // MARK: - The stack

    /// One level of the stack, in the unit's own terms.
    ///
    /// Heights are real metres above the rail or the road. Width is a fraction
    /// of the width the body is *drawn* at, so a level keeps its proportion to
    /// the body whether or not the width has been exaggerated to stay visible.
    /// `rake` is how far up the vehicle this level is as a fraction — 0 at the
    /// floor, 1 at the roof — and it is what decides how far back off a nose
    /// the level is held. That single number is the whole of the third
    /// dimension's shape: a cab's windscreen slopes because the glass is held
    /// back a third of the nose and the roof the whole of it.
    struct Level {
        var role: MeshSlab.Role
        var base: Double
        var top: Double
        var width: Double
        var rake: Double
        var fill: Fill
        /// Whether this level ignores the body's end profiles and is drawn as a
        /// box with the corners knocked off.
        ///
        /// For the things that sit *on* a vehicle rather than being part of its
        /// shape: a boat's deckhouse, a roof equipment box. A superstructure
        /// drawn with the hull's own bow came out through the front of the
        /// boat, because a fine ten-metre bow taper narrows far faster than the
        /// six-metre one a deckhouse two-thirds the width gets — so at the same
        /// distance back the house was wider than the hull carrying it.
        var squareEnds: Bool = false
    }

    /// Where a level's colour comes from, resolved against the unit and the
    /// livery rather than written down per family.
    enum Fill {
        case livery
        /// The band above the windows, which on most Swiss stock is not the
        /// body colour. See `Livery.belt`.
        case belt
        case glass
        case roof
        case underframe
        case equipment
        /// Bogies, axleboxes, tyres — everything below the solebar.
        case running
        /// Doors and whatever else is picked out against the body.
        case trim
    }

    /// How tall the families are, and where each band sits.
    ///
    /// Real dimensions, and they matter more than they look. A tram is a metre
    /// shorter than a coach and a double-decker half a metre taller than
    /// either, and at sixty degrees of pitch, standing next to each other in
    /// the same station square, that difference is the first thing a reader
    /// sees. Put them all at one height and the fleet turns back into one shape
    /// at several lengths, which is what the flat drawing already spent a great
    /// deal of effort not being.
    ///
    /// The bands are where they are on the real vehicle, and the proportion
    /// between them is the part that had to be got right twice. A Swiss coach
    /// floor is about a metre over the rail, its waist rail is at 2.2 m and its
    /// cant rail at 3.1 — so the glass is under a quarter of the side and the
    /// operator's colour is most of the rest. Drawn first with the window band
    /// running from the floor to the shoulder, every vehicle in the country
    /// came out as a black slab with a thin coloured rim: a PostAuto that is
    /// not yellow, a VBZ tram that is not blue. That is the same mistake the
    /// roof band made on the flat drawing, made again on a bigger surface.
    struct Stack {
        var levels: [Level]
        /// Where the class band is painted: the top of the highest window band,
        /// which on a real coach is the cant rail the stripe runs along.
        var beltTop: Double
        var roofTop: Double

        /// How far off the ground the head and tail lamps are, in metres.
        ///
        /// Derived rather than written down per family, because across
        /// everything that runs in this country there is one rule and it holds:
        /// a lamp sits about a third of the way up the front, clear of the
        /// floor it is set into. A Re 460's are at 1.4 m, a Cobra tram's at 1.1,
        /// a PostAuto's at 1.0, a lake steamer's at 2.2 — which is very close to
        /// where each of those actually carries them, and much more to the point
        /// is *different for each*, so a tram is not lit like the train standing
        /// beside it.
        ///
        /// The first rule tried was "just under the windscreen", off the bottom
        /// of the glazing, and it broke on the one family that most needed it:
        /// a double-decker's lower deck starts its windows at 1.25 m, so an
        /// IC 2000 — the tallest thing on the network — got the lowest lamps on
        /// it, at knee height under a body four and a half metres tall.
        /// Measured off the roof instead, height and lamp go up together.
        ///
        /// It matters more than a decoration should, because a lamp drawn at
        /// the wrong height is not drawn slightly wrong — it is drawn in the
        /// wrong *place*. On a tilted map the height of a thing is most of
        /// where it lands on the screen, and a lamp given no height at all
        /// lands on the ground several metres in front of the nose that is
        /// supposed to be carrying it. See `VehicleLamps`.
        var lampHeight: Double {
            max((levels.first?.top ?? 0.4) + 0.3, roofTop * 0.32)
        }
    }

    /// A window band's colour.
    ///
    /// Not the livery's own `glass`, which is a windscreen seen from directly
    /// above — nearly black, because that is what a windscreen looks like from
    /// up there. A window seen from the side at twenty degrees above the
    /// horizon is looking back at the sky, and it is pale. Using the top view's
    /// black down the whole side of a vehicle is what turned every tram into a
    /// slab of coal. The operator's own tint is kept and lifted rather than
    /// replaced, so a BLS window band stays faintly green and an MOB one blue.
    static func glazing(_ livery: Livery) -> String {
        guard let glass = rgb(livery.glass), let sky = rgb(skyOnGlass) else { return skyOnGlass }
        // Weighted hard toward the sky, and it took two goes. A wall in this
        // renderer is shaded by its own normal *and* by a vertical gradient
        // from the ground up, so whatever colour goes in comes out a third
        // darker down the side of the vehicle. Mixed half and half, the window
        // band landed at near-navy and a light grey SBB rake read as "white
        // with black stripes" — the glass, not the paint, was what was dark.
        // Two-thirds sky survives the shading and still reads as glass.
        func mix(_ a: Int, _ b: Int) -> Int { Int((Double(a) * 0.32 + Double(b) * 0.68).rounded()) }
        return String(
            format: "#%02x%02x%02x",
            mix(glass.r, sky.r), mix(glass.g, sky.g), mix(glass.b, sky.b)
        )
    }

    /// `#rrggbb` or `#rgb` in, channels out.
    ///
    /// The app has a fuller parser — see `Palette` — and this is deliberately
    /// not it. `TransitCore` has no renderer and no business owning one; all
    /// that is needed here is to lift one hex colour toward another, and the
    /// liveries are all written as hex. Anything else falls back to the sky.
    static func rgb(_ colour: String) -> (r: Int, g: Int, b: Int)? {
        guard colour.hasPrefix("#") else { return nil }
        var digits = Array(colour.dropFirst())
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        guard digits.count == 6, let value = Int(String(digits), radix: 16) else { return nil }
        return ((value >> 16) & 255, (value >> 8) & 255, value & 255)
    }

    /// What a window reflects: an overcast Swiss sky, which is most of them.
    static let skyOnGlass = "#9db2c6"

    /// A level, spelled out. Saves repeating the label list eight times below.
    static func level(
        _ role: MeshSlab.Role, _ base: Double, _ top: Double,
        width: Double, rake: Double, fill: Fill, squareEnds: Bool = false
    ) -> Level {
        Level(
            role: role, base: base, top: top, width: width, rake: rake,
            fill: fill, squareEnds: squareEnds
        )
    }

    /// The stack for one unit, bottom to top.
    static func stack(for unit: VehicleUnit, mode: Mode) -> Stack {
        // A tyre stands proud of a bus's body; a bogie hides under a coach's.
        // Same level, opposite sign, and it is the same distinction the flat
        // drawing makes with its wheel rectangles.
        // Narrower than it was, and less black than it was. Drawn at 0.80 in
        // near-black, a coach's underframe came out as a solid bar a quarter of
        // the vehicle's height — from a tilted camera the single loudest thing
        // on a train, and the reason a light grey SBB rake read as "white with
        // black stripes". What is actually under a coach is bogies and air
        // tanks in shadow: a dark *gap* the body overhangs, not a plinth the
        // body sits on. Pulled in and lightened, it reads as the gap.
        let underWidth = unit.kind == .bus ? 0.92 : 0.70
        // The step from the belt to the roof is narrow on purpose.
        //
        // Drawn at 0.76 against a shoulder of 0.93, the top face of the belt
        // showed as a band of colour all the way round the roof — so an SBB
        // coach came out with its red painted over the gutter and along the
        // cant rail on both sides at once, which is a red-roofed train rather
        // than a red-banded one. A real roof does start narrower than the body,
        // but by a gutter's width, not a foot.
        let roofWidth = unit.doubleDeck ? 0.92 : 0.87

        /// The ordinary five-band vehicle: under the floor, the lower side, the
        /// windows, the turn of the shoulder, the roof.
        func banded(
            floor: Double, waist: Double, cant: Double, shoulder: Double, roof: Double,
            glazed: Bool = true
        ) -> Stack {
            Stack(levels: [
                level(.chassis, 0, floor, width: underWidth, rake: 0.12, fill: .underframe),
                level(.body, floor, waist, width: 1.0, rake: 0.04, fill: .livery),
                level(.glazing, waist, cant, width: glazed ? 0.99 : 1.0, rake: 0.30,
                      fill: glazed ? .glass : .livery),
                level(.shoulder, cant, shoulder, width: 0.965, rake: 0.62, fill: .belt),
                level(.roof, shoulder, roof, width: roofWidth, rake: 1.0, fill: .roof),
            ], beltTop: cant, roofTop: roof)
        }

        /// Two decks, which means two window bands with a solid belt between
        /// them. That belt is the whole of how a double-decker is recognised
        /// from the side, and it is worth the extra slab: an IC2000 and an
        /// EW IV rake are otherwise one shape at one height.
        func doubleDecked(
            floor: Double, lowerWaist: Double, lowerCant: Double,
            upperWaist: Double, upperCant: Double, shoulder: Double, roof: Double
        ) -> Stack {
            Stack(levels: [
                level(.chassis, 0, floor, width: underWidth, rake: 0.12, fill: .underframe),
                level(.body, floor, lowerWaist, width: 1.0, rake: 0.04, fill: .livery),
                level(.glazing, lowerWaist, lowerCant, width: 0.99, rake: 0.16, fill: .glass),
                level(.body, lowerCant, upperWaist, width: 1.0, rake: 0.26, fill: .livery),
                level(.glazing, upperWaist, upperCant, width: 0.99, rake: 0.40, fill: .glass),
                level(.shoulder, upperCant, shoulder, width: 0.965, rake: 0.68, fill: .belt),
                level(.roof, shoulder, roof, width: roofWidth, rake: 1.0, fill: .roof),
            ], beltTop: upperCant, roofTop: roof)
        }

        switch unit.kind {
        case .hull:
            // A boat is not a stack of bands, it is a hull with a house on it,
            // and the house is most of what is visible. The rakes are large
            // because a lake steamer's decks step in hard, and that stepping is
            // how one is recognised from the shore.
            return Stack(levels: [
                level(.body, 0, 1.9, width: 1.0, rake: 0, fill: .livery),
                level(.glazing, 1.9, 3.7, width: 0.80, rake: 1.15, fill: .glass, squareEnds: true),
                level(.roof, 3.7, 4.3, width: 0.76, rake: 1.30, fill: .roof, squareEnds: true),
                level(.dome, 4.3, 5.4, width: 0.34, rake: 2.60, fill: .roof, squareEnds: true),
            ], beltTop: 3.7, roofTop: 5.4)

        case .cabin:
            return banded(floor: 0.30, waist: 1.25, cant: 2.32, shoulder: 2.78, roof: 3.05)

        case .bus:
            return unit.doubleDeck
                ? doubleDecked(
                    floor: 0.42, lowerWaist: 1.40, lowerCant: 2.06,
                    upperWaist: 2.62, upperCant: 3.52, shoulder: 3.98, roof: 4.25)
                : banded(floor: 0.42, waist: 1.75, cant: 2.58, shoulder: 2.98, roof: 3.20)

        case .locomotive:
            // Unglazed. A locomotive is a machine with two small cab windows in
            // it, and a band of glass down its whole length turns a Re 460 into
            // a coach — which is exactly the unit on the train the flat drawing
            // works hardest to keep distinct.
            return banded(
                floor: 1.05, waist: 2.50, cant: 3.22, shoulder: 3.78, roof: 4.28,
                glazed: false
            )

        case .van:
            return banded(
                floor: 1.00, waist: 2.25, cant: 3.05, shoulder: 3.62, roof: 4.05,
                glazed: false
            )

        case .module, .drivingCar, .coach:
            if mode == .tram {
                // A low-floor tram really is a greenhouse: the floor is 35 cm
                // over the road and the glass starts at knee height, which is
                // most of why one does not look like anything else.
                return banded(floor: 0.35, waist: 1.50, cant: 2.52, shoulder: 3.05, roof: 3.42)
            }
            if mode == .metro {
                return banded(floor: 0.60, waist: 1.70, cant: 2.70, shoulder: 3.14, roof: 3.45)
            }
            return unit.doubleDeck
                ? doubleDecked(
                    floor: 0.60, lowerWaist: 1.25, lowerCant: 2.05,
                    upperWaist: 2.75, upperCant: 3.55, shoulder: 4.22, roof: 4.62)
                : banded(floor: 1.00, waist: 2.25, cant: 3.05, shoulder: 3.62, roof: 4.05)
        }
    }

    // MARK: - How far back a level is held off the ends

    /// How much of a nose a level at the top of the vehicle gives up, in metres.
    ///
    /// This is the one number that turns a stack of prisms into a shape. Every
    /// end profile already narrows in plan — see `end` — and this says how much
    /// it also *shortens* as it rises. A driving cab loses a couple of metres
    /// between the floor and the roof, which is a windscreen; an ICE nose loses
    /// five, which is the long slope somebody would recognise from a
    /// photograph; the flat end of a coach loses ten centimetres, which is the
    /// radius on the cant rail and nothing more.
    static func rake(of profile: EndProfile, length: Double) -> Double {
        switch profile {
        case .gangway: return 0
        case .square: return min(0.35, length * 0.02)
        case .cab: return min(2.4, length * 0.17)
        case .streamlined: return min(5.2, length * 0.23)
        case .locomotive: return min(1.5, length * 0.11)
        case .tramFront: return min(1.2, length * 0.21)
        case .busFront: return min(1.4, length * 0.13)
        case .busRear: return min(0.55, length * 0.06)
        case .bow: return min(6.0, length * 0.26)
        }
    }

    /// One level's plan outline, in the unit's own metres.
    ///
    /// The ring comes back shifted forward by the back inset, so the levels
    /// stay concentric on the body they belong to rather than all starting at
    /// the same tail.
    static func plan(
        _ level: Level, unit: VehicleUnit,
        ends: (front: EndProfile, back: EndProfile), width: Double, steps: Int
    ) -> [(x: Double, y: Double)] {
        let front = rake(of: ends.front, length: unit.length) * level.rake
        let back = rake(of: ends.back, length: unit.length) * level.rake
        let length = unit.length - front - back
        // A level raked past its own body is not a level. It happens on a short
        // module with a deep nose at both ends, and the honest answer is a
        // sliver rather than a ring inside out.
        guard length > 0.5 else { return [] }
        let levelWidth = width * level.width
        let squared = EndProfile.square(chamfer: levelWidth * 0.22)
        let ring = outline(
            length: length, width: levelWidth,
            front: level.squareEnds ? squared : ends.front,
            back: level.squareEnds ? squared : ends.back,
            steps: steps
        )
        return ring.map { (x: $0.x + back, y: $0.y) }
    }

    // MARK: - Building one unit

    /// Every slab of one unit, bottom to top.
    ///
    /// `heightScale` matches the width exaggeration the flat drawing already
    /// applies. Applying it to height as well is what keeps the *cross-section*
    /// honest: widen a train to seven points across and leave it three metres
    /// tall and it comes out as a flat plank, which reads worse from a tilted
    /// camera than the flat drawing it replaced.
    static func mesh(
        unit: VehicleUnit, index: Int, in layout: VehicleLayout, mode: Mode,
        ends: (front: EndProfile, back: EndProfile),
        width: Double, heightScale: Double, detail: Detail,
        lamps: (head: Bool, tail: Bool) = (false, false)
    ) -> UnitMesh {
        let steps = max(2, smoothness(lengthPoints: 40))
        let half = width / 2
        // The plan helpers all speak in labelled tuples, which cannot be stored
        // in a `Sendable` value; these two carry their answers into one.
        func local(_ ring: [(x: Double, y: Double)]) -> [MeshPoint] {
            ring.map { MeshPoint(x: $0.x, y: $0.y) }
        }
        func box(x0: Double, x1: Double, y0: Double, y1: Double) -> [MeshPoint] {
            local(rectangle(x0: x0, x1: x1, y0: y0, y1: y1))
        }
        var out: [LocalSlab] = []
        out.reserveCapacity(12)

        let stack = stack(for: unit, mode: mode)
        func finish() -> UnitMesh {
            UnitMesh(
                slabs: out, length: unit.length, width: width,
                height: out.map(\.top).max() ?? (stack.roofTop * heightScale)
            )
        }

        for level in stack.levels {
            let ring = local(plan(level, unit: unit, ends: ends, width: width, steps: steps))
            guard ring.count >= 3 else { continue }
            out.append(LocalSlab(
                role: level.role, rings: [ring],
                base: level.base * heightScale, top: level.top * heightScale,
                fill: colour(level.fill, of: unit, in: layout)
            ))
        }
        // The lamps, set into the two ends, and part of the wagon rather than
        // beside it.
        //
        // Where exactly is the fiddly bit and it is worth being careful about,
        // because the two failure modes are both ugly: a lamp inside the body
        // is a lamp nobody can see, and a lamp beside the body is a wart. So
        // the tip of the *body* is measured — the level whose band the lamp
        // sits in — and the block is stood on it, reaching a hand's breadth
        // back into the nose and poking a few centimetres out of the front.
        // That works for a flat coach end and for an ICE's seven-metre point
        // alike, because both are being asked the same question: where does
        // this body actually stop.
        // Only on the ends of the *train*, which the caller has to say, because
        // a wagon cannot know.
        //
        // The tempting rule was "any end that is not a gangway", and it is
        // wrong in a way that is obvious the moment it is drawn: a coach in the
        // middle of a locomotive-hauled rake has square ends, not gangways —
        // there really is a gap between two coaches — so an IC came out with
        // every one of its nine bodies wearing headlights at the front and tail
        // lamps at the back, a train of nine trains. Where the lamps go is a
        // fact about the formation and only the formation knows it.
        if lamps.head || lamps.tail,
           let body = out.first(where: { $0.role == .body }) ?? out.first {
            let z = stack.lampHeight * heightScale
            for front in [true, false] where front ? lamps.head : lamps.tail {
                guard let lamp = lampPair(
                    on: body, front: front, half: half, height: z
                ) else { continue }
                out.append(lamp)
            }
        }
        guard detail > .outline else { return finish() }

        let length = unit.length
        let onRoad = unit.kind == .bus

        // The running gear, and the daylight between it.
        //
        // This is the first answer to a fleet that looked like a stack of
        // coloured bands. Every cue in the stack runs *along* the vehicle, so
        // there was nothing anywhere on it to say where one body stopped and
        // the next began — a sixteen-coach train and a single railcar were the
        // same striped extrusion at two lengths. A bogie is the cheapest thing
        // that runs the other way: two dark blocks under the ends with a gap
        // between them, which is both a real feature of every rail vehicle ever
        // built and, from a tilted camera, the shadow line that makes a body
        // look carried rather than extruded.
        //
        // Emitted from `.trim` rather than from `.full`, because it is doing
        // structural work and has to arrive before any decoration does.
        let solebar = stack.levels.first?.top ?? 0.9
        if solebar > 0.12, unit.kind != .hull {
            let along = onRoad ? min(2.0, length * 0.16) : min(3.4, length * 0.15)
            let inset = onRoad ? 0.18 : 0.21
            // Both of them in one slab, at the two ends of the same body, so
            // the pair is symmetric about the middle of the wagon carrying it
            // and stands on the same ground the wagon does. Emitted separately
            // they were two features a wagon-length apart, and on a slope the
            // renderer grounded them at two different elevations — one bogie
            // buried and the other hanging in the air under the same coach.
            let blocks = [length * inset, length * (1 - inset)].map { x in
                box(
                    x0: x - along / 2, x1: x + along / 2,
                    // A tyre stands proud of the body; a bogie hides under
                    // it. The same block with the sign flipped, and at the
                    // zoom where a tram and an articulated bus are the same
                    // blue worm it is the only thing separating them.
                    y0: -half * (onRoad ? 1.06 : 0.74),
                    y1: half * (onRoad ? 1.06 : 0.74)
                )
            }
            out.append(LocalSlab(
                role: .bogie, rings: blocks,
                base: 0,
                top: solebar * heightScale * (onRoad ? 1.0 : 0.94),
                fill: runningGearColour
            ))
        }

        // The class band, as a band. On the flat drawing it is a stripe along
        // each edge because from above the top of the side *is* the edge; on
        // the solid it can be the thing it actually is, which is a painted line
        // round the vehicle at cant-rail height. Held a hair proud of the side
        // it is on so the two prisms do not share a face and flicker.
        let frontDepth = depth(of: ends.front, length: length, width: width)
        let backDepth = depth(of: ends.back, length: length, width: width)
        let straightFrom = backDepth + 0.4
        let straightTo = length - frontDepth - 0.4
        if let band = stripeColour(unit.band, livery: layout.livery),
           let span = stripeSpan(
               unit.stripe, length: length, from: straightFrom, to: straightTo
           ), span.to > span.from {
            out.append(LocalSlab(
                role: .stripe,
                rings: [box(
                    x0: span.from, x1: span.to,
                    y0: -half * 1.015, y1: half * 1.015
                )],
                base: (stack.beltTop - 0.26) * heightScale,
                top: stack.beltTop * heightScale,
                fill: band
            ))
        }

        // Class numbers, proud of both sides. The formation drawing has
        // always written them; the solid did not, so a rake at this zoom
        // was a row of anonymous boxes.
        if detail == .full, let sill = stack.levels.first(where: { $0.role == .body })?.base {
            out.append(contentsOf: lettering(
                unit: unit, half: half, heightScale: heightScale,
                from: straightFrom, to: straightTo,
                sill: sill, beltTop: stack.beltTop
            ))
        }

        // Doors, once a body is big enough that they would land more than a
        // couple of points apart.
        //
        // The other half of the answer to the banding, and the half that
        // carries information: a coach has two, a low-floor tram has five and
        // an articulated bus has three, and counting them across a body is how
        // somebody tells those apart at a glance. Drawn as a band from the
        // solebar to the cant rail — the full height of the side, the way a
        // door is — and a centimetre proud of it, so the two prisms do not
        // share a face and flicker against each other.
        //
        // Placed by the same rule as the flat drawing's door ticks: evenly
        // spaced over the straight part of the body, because where the doors of
        // a given class actually sit is not in any feed this app reads, and
        // because for a moment in the middle of the change from one drawing to
        // the other both are on the screen and they have to agree.
        if detail == .full, unit.doors > 0, straightTo > straightFrom,
           let sill = stack.levels.first(where: { $0.role == .body })?.base {
            let span = straightTo - straightFrom
            let step = span / Double(unit.doors + 1)
            let leaf = min(1.35, step * 0.42)
            // Every leaf on the wagon in one slab, for the reason the bogies
            // are: evenly spaced over the straight part of the body, the set is
            // symmetric about the middle of it, so one ground answers for all
            // of them and a tram cannot end up with its front doors half a
            // metre lower than its back ones.
            var leaves: [[MeshPoint]] = []
            leaves.reserveCapacity(unit.doors * 2)
            for k in 1...unit.doors {
                let x = straightFrom + step * Double(k)
                // One slab per side, not one across the vehicle.
                //
                // A full-width block was the obvious thing and it was wrong in
                // a way only a picture shows: a door is two metres tall and
                // three wide, so a box spanning the whole body at cant-rail
                // height is *wider* than the roof above it — and its far top
                // corner projects higher on screen than the roofline does. The
                // trains came out with red flags standing up through their
                // roofs. A door is on the side of a vehicle; drawn on the side,
                // it cannot break a silhouette it is inside.
                for side in [-1.0, 1.0] {
                    leaves.append(box(
                        x0: x - leaf / 2, x1: x + leaf / 2,
                        y0: side * half * 0.80, y1: side * half * 1.012
                    ))
                }
            }
            out.append(LocalSlab(
                role: .door, rings: leaves,
                base: sill * heightScale,
                top: stack.beltTop * heightScale,
                fill: layout.livery.trim
            ))
        }

        // Pantographs, in the same places the flat drawing puts them — the two
        // have to agree, because for a second in the middle of the change from
        // one to the other both are on the screen.
        if unit.pantographs > 0, unit.kind != .hull {
            let positions: [Double] = unit.pantographs == 1
                ? [unit.length * 0.5]
                : (0..<unit.pantographs).map {
                    unit.length * (Double($0) + 0.5) / Double(unit.pantographs)
                }
            let arms = positions.map { x in
                box(
                    x0: x - min(1.1, unit.length * 0.08),
                    x1: x + min(1.1, unit.length * 0.08),
                    y0: -half * 0.52, y1: half * 0.52
                )
            }
            out.append(LocalSlab(
                role: .pantograph, rings: arms,
                base: stack.roofTop * heightScale,
                top: (stack.roofTop + 0.62) * heightScale,
                fill: pantographColour
            ))
        } else if unit.kind != .hull, mode == .tram || mode == .metro || unit.kind == .bus {
            // Roof equipment on everything that carries it and has no
            // pantograph on this body: the air conditioning and the converter
            // boxes, which on a low tram or a bus are a third of what stands
            // above the waist and the reason the roof does not read as flat.
            let from = unit.length * 0.30, to = unit.length * 0.72
            guard to > from else { return finish() }
            out.append(LocalSlab(
                role: .dome,
                rings: [box(
                    x0: from, x1: to, y0: -half * 0.44, y1: half * 0.44
                )],
                base: stack.roofTop * heightScale,
                top: (stack.roofTop + 0.26) * heightScale,
                fill: equipmentColour
            ))
        }
        return finish()
    }

    /// The pair of lamps on one end of a wagon, as one slab of two blocks.
    ///
    /// One slab, because they are one pair: whatever a renderer decides about
    /// where a lamp stands, it must decide the same thing for the other one.
    /// How big a lamp is, and how far it reaches into and out of the nose.
    static let lampReach = 0.5, lampProud = 0.09, lampWide = 0.21, lampTall = 0.19

    /// Where the pair of lamps on one end of a body goes, in the body's own
    /// metres: how far along, and how far out to each side.
    ///
    /// Shared, because two things place lamps and they have to agree. The mesh
    /// puts a block here, and the halo drawn over the top of it is a separate
    /// feature in a separate layer that has to land on the same spot — and for
    /// a moment during the change from the flat drawing to the solid, both are
    /// on the screen at once. Computed twice from one function they cannot
    /// drift; written out twice they would, and the first place to show it
    /// would be an ICE, whose nose is seven metres long and whose lamps would
    /// have ended up at opposite ends of it.
    public static func lampAnchor(
        on ring: [MeshPoint], front: Bool, half: Double
    ) -> (along: Double, across: Double)? {
        guard ring.count >= 3 else { return nil }
        let tip = front
            ? ring.map(\.x).max() ?? 0
            : ring.map(\.x).min() ?? 0
        // How wide the body still is where it ends. A coach ends at nearly its
        // full width and an ICE at a hand's breadth, and the lamps belong at
        // the same fraction of whichever it is — which is what stops a pair of
        // lamps hanging in the air on either side of a fine nose.
        let atTip = ring
            .filter { abs($0.x - tip) < 0.35 }
            .map { abs($0.y) }
            .max() ?? half
        return (
            along: tip + (front ? -1 : 1) * (lampReach - lampProud) / 2,
            across: min(half * 0.45, max(0.3, atTip) * 0.62)
        )
    }

    static func lampPair(
        on body: LocalSlab, front: Bool, half: Double, height: Double
    ) -> LocalSlab? {
        guard let ring = body.rings.first,
              let anchor = lampAnchor(on: ring, front: front, half: half)
        else { return nil }
        let across = anchor.across
        let reach = lampReach, wide = lampWide, tall = lampTall
        guard height > tall else { return nil }

        let x0 = anchor.along - reach / 2
        let x1 = anchor.along + reach / 2
        let blocks = [-1.0, 1.0].map { side in
            [
                MeshPoint(x: x0, y: side * across - wide),
                MeshPoint(x: x1, y: side * across - wide),
                MeshPoint(x: x1, y: side * across + wide),
                MeshPoint(x: x0, y: side * across + wide),
            ]
        }
        return LocalSlab(
            role: .lamp, rings: blocks,
            base: height - tall, top: height + tall,
            fill: front ? headLampColour : tailLampColour
        )
    }

    /// The class plate painted on a real coach, as a few boxes proud of the
    /// side. Seven-segment, because a TrueType outline is a thousand triangles
    /// for a number that occupies a handful of pixels.
    static let letteringColour = "#f4f4f2"

    static func lettering(
        unit: VehicleUnit, half: Double, heightScale: Double,
        from: Double, to: Double, sill: Double, beltTop: Double
    ) -> [LocalSlab] {
        let glyphs: [Character]
        switch unit.band {
        case .first: glyphs = ["1"]
        case .second: glyphs = ["2"]
        case .mixed: glyphs = ["1", "2"]
        default: return []
        }
        let span = to - from
        guard span > 3 else { return [] }
        let tall = min(0.95, max(0.55, (beltTop - sill) * 0.42)) * heightScale
        let wide = tall * 0.55
        let thick = half * 0.03
        let base = (sill + (beltTop - sill) * 0.22) * heightScale
        // Forward of centre, clear of the doors that sit on even spacing.
        let origin = from + span * (unit.cabFront ? 0.38 : 0.32)
        let gap = wide * 0.28
        let total = Double(glyphs.count) * wide + Double(max(0, glyphs.count - 1)) * gap
        var x = origin - total / 2
        var out: [LocalSlab] = []
        for glyph in glyphs {
            for bar in digit(glyph) {
                let x0 = x + bar.x0 * wide
                let x1 = x + bar.x1 * wide
                let z0 = base + bar.y0 * tall
                let z1 = base + bar.y1 * tall
                let rings = [-1.0, 1.0].map { side -> [MeshPoint] in
                    let y0 = side * half - (side > 0 ? 0 : thick)
                    let y1 = side * half + (side > 0 ? thick : 0)
                    return [
                        MeshPoint(x: x0, y: y0), MeshPoint(x: x1, y: y0),
                        MeshPoint(x: x1, y: y1), MeshPoint(x: x0, y: y1),
                    ]
                }
                out.append(LocalSlab(
                    role: .lettering, rings: rings,
                    base: z0, top: z1, fill: letteringColour
                ))
            }
            x += wide + gap
        }
        return out
    }

    /// One glyph as axis-aligned bars in the unit square: `x` along, `y` up.
    static func digit(_ glyph: Character) -> [(x0: Double, x1: Double, y0: Double, y1: Double)] {
        let t = 0.18
        switch glyph {
        case "1":
            return [(0.42, 0.42 + t, 0.00, 1.00)]
        case "2":
            return [
                (0.00, 1.00, 1.00 - t, 1.00),
                (1.00 - t, 1.00, 0.50, 1.00),
                (0.00, 1.00, 0.50 - t / 2, 0.50 + t / 2),
                (0.00, t, 0.00, 0.50),
                (0.00, 1.00, 0.00, t),
            ]
        default:
            return []
        }
    }

    /// A level's colour.
    static func colour(_ fill: Fill, of unit: VehicleUnit, in layout: VehicleLayout) -> String {
        switch fill {
        case .livery: return colour(of: unit, in: layout)
        case .belt:
            // A closed van and a restaurant car are painted as what they are
            // rather than as the class of train they are in, and both of those
            // are decided by `colour(of:)`. A band over the top of either would
            // be a stripe on a vehicle that does not have one.
            return unit.closed || unit.band == .dining
                ? colour(of: unit, in: layout)
                : layout.livery.belt
        case .glass: return glazing(layout.livery)
        case .roof:
            return unit.band == .dining ? diningRoofColour : roofColour(of: unit, livery: layout.livery)
        case .underframe: return underframeColour
        case .equipment: return equipmentColour
        case .running: return runningGearColour
        case .trim: return layout.livery.trim
        }
    }

    /// What is under the floor: bogies, tanks, the tyres of a bus. One colour
    /// for all of it, because at this size it is one shaded gap — and a grey
    /// one, because the vertical gradient the renderer applies darkens the
    /// bottom of every wall on its own. Set to the near-black a bogie actually
    /// is, the two compounded and the result was a hole under the train.
    /// Warm rather than white, because every headlamp lens ever fitted to a
    /// train is, and a pure white dot on a dark map reads as interface rather
    /// than as a light.
    public static let headLampColour = "#fff4dc"
    public static let tailLampColour = "#ff3320"

    static let underframeColour = "#3b4249"
    /// Roof gear — the grey of an air-conditioning pack, lighter than the roof
    /// it stands on so it reads as a thing on the roof rather than a hole in it.
    static let equipmentColour = "#7b838d"
    /// Bogies and tyres. Darker than the underframe they hang under, because
    /// the whole job of the gap between them is to be a gap.
    static let runningGearColour = "#22272d"

    // MARK: - How tall a vehicle may be drawn

    /// How much the height is exaggerated, given the width exaggeration.
    ///
    /// The same factor, up to a point. The width floor exists because a
    /// three-metre body against a two-hundred-metre train is a hairline, and it
    /// grows without limit as the map zooms out; height copied from it without
    /// a ceiling would put twenty-metre buses on the Bahnhofplatz. Two is where
    /// it stops: at the zooms solids are drawn at all the width factor is
    /// rarely above that, so the ceiling is a guard rather than a look.
    public static let maxHeightScale = 2.0

    /// How much a *baked model's* cross-section is exaggerated — at every zoom.
    ///
    /// A constant, and that is the whole of the point. The exaggeration the
    /// flat drawing uses is a screen-space floor: a body is drawn at least
    /// `minWidthPoints` across, so the factor grows as the camera pulls back.
    /// Between zoom 17 and 16 it doubles, and from 16 down it sits pinned at
    /// `maxHeightScale`. On a hairline polygon nobody can see that happen. On
    /// a rigid body with a roof, a cab and a pantograph it is the wagon
    /// inflating as the map zooms out and deflating as it zooms in — which is
    /// not a vehicle getting nearer, it is a mesh being stretched.
    ///
    /// A model is a thing rather than a mark, so its proportions are a fact
    /// about the vehicle and not about the camera. Length was always true;
    /// width and height are now exaggerated by this same fixed amount
    /// whatever the zoom, so the only thing that changes as the map moves is
    /// how large the wagon is on screen. Which is what zooming means.
    ///
    /// Not 1.0, because solids stand up from `solidMinZoom`, where a truthful
    /// 2.9 m body is under a point across and the flat drawing that used to
    /// cover for it is hidden the moment the model stands — see
    /// `VehicleShapes.Key.stood`. Not 2.0 either: close in, a body drawn at
    /// twice its width is plainly a body drawn at twice its width.
    ///
    /// The extruded fallback keeps the zoom-dependent factor, and has to: its
    /// width is baked into the same polygons the flat drawing is built from,
    /// and the two are drawn together. Only the baked models are free of it.
    public static let modelExaggeration = 1.45

    /// Where a vehicle stops being a flat drawing and becomes a solid.
    ///
    /// Two conditions, and both have to hold, because either alone is wrong.
    /// **Pitch**, because a solid seen from directly overhead is a flat drawing
    /// with worse edges — everything the height buys is bought by looking along
    /// it. **Zoom**, because at any distance the third dimension is smaller
    /// than a pixel and all it can do is thicken the vehicle into a blob.
    ///
    /// Returned as a fraction rather than a switch so the two drawings can
    /// cross-fade: the flat shape carries `1 - solidity` of its own alpha and
    /// the solid carries `solidity` of the layer's, so tilting the map lifts
    /// the vehicles up out of their own footprints instead of swapping one
    /// picture for another.
    public static func solidity(pitch: Double, zoom: Double) -> Double {
        let tilted = min(1, max(0, (pitch - solidMinPitch) / solidFullPitch))
        let near = min(1, max(0, (zoom - solidMinZoom) / solidFullZoom))
        return tilted * near
    }

    /// Where the change begins, and how much further it takes to finish.
    ///
    /// **Any tilt at all.** This used to wait for twenty-two degrees, on the
    /// reasoning that below it a map still reads as a plan and the height buys
    /// nothing. What that missed is that the reader tilting the map *at all* is
    /// the reader asking to see the third dimension, and answering with the
    /// flat drawing for the first twenty-two degrees of the gesture is
    /// answering a different question — the vehicles were the last thing on the
    /// map to stand up, after the buildings and after the ground. So the ramp
    /// starts at nothing and is over in two degrees: a map lying exactly flat
    /// keeps the plan, and a map that has been tilted has solids.
    ///
    /// Zoom 14 because the width floor already keeps a body seven points
    /// across, and two metres of exaggerated height is still a couple of
    /// points at that scale — far enough out that a valley of trains is
    /// trains, not a field of dots waiting for one more pinch. Further than
    /// that a three-metre body is under a pixel tall even doubled, and a
    /// solid can only thicken the vehicle into a blob.
    public static let solidMinPitch = 0.0
    public static let solidFullPitch = 2.0
    public static let solidMinZoom = 14.0
    public static let solidFullZoom = 1.2
}
