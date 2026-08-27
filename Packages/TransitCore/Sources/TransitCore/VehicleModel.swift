import Foundation

// What a baked wagon is, and where one stands.
//
// The rest of this module draws a vehicle by handing a renderer its geometry,
// rebuilt from scratch on every frame. That is the right shape for a *flat*
// drawing, which is a few polygons and changes completely every time the map
// moves. It is the wrong shape for a solid, and the map made the case itself:
// as soon as the ground under a vehicle stopped being flat, every piece of it
// had to be told separately what "the ground" meant, and the pieces disagreed.
//
// A wagon is not a pile of pieces. It is one rigid object that a hillside
// cannot bend, a box on bogies that stands on the ground at one height and
// tilts into a climb as a whole. The way to draw that is to say it: bake the
// shape once, and afterwards send only *where it is* — a point, a heading, a
// grade. Nothing inside it can move because nothing inside it is being sent.
//
// So this file carries the two halves of that idea. `VehicleModelKey` is what
// a wagon *is*, which is small, hashable, and shared by every wagon in the
// country that looks the same; a sixteen-coach train is two keys. `UnitPlacement`
// is where one stands, which is four numbers and a coordinate. The mesh behind
// a key is built on demand and kept — see `VehicleGLB` for what it is turned
// into, and `VehicleModelStore` in the app for the keeping.

/// What a wagon is made of — everything that decides its shape and its paint,
/// and nothing that decides where it is.
///
/// The separation is the whole point. Two RABe 511 intermediate coaches in SBB
/// livery are the same key whether one is at Bern and the other at Chur, so
/// they are one mesh, built once and drawn twice. Anything that varied per
/// *position* in here — a heading, a width exaggeration, a level of detail
/// that follows the zoom — would multiply the models without changing what any
/// of them look like, which is the trap this is shaped to avoid.
public struct VehicleModelKey: Hashable, Sendable {
    public var unit: VehicleUnit
    public var mode: Mode
    /// The two ends, which depend on the wagon's neighbours as much as on
    /// itself: the same coach has a gangway where it is coupled and a rounded
    /// end where it is not.
    public var front: VehicleShape.EndProfile
    public var back: VehicleShape.EndProfile
    public var livery: Livery
    /// Whether this wagon carries the lamps on the front of the train, and
    /// whether it carries the ones on the back.
    ///
    /// A property of the wagon's *place in the formation* rather than of the
    /// wagon, which is why it is here at all: the mesh is baked once and shared
    /// by every wagon that matches, so the leading coach of a rake and the
    /// fourth coach of the same rake have to be different keys or the whole
    /// train lights up. Two bools rather than a position, because the position
    /// is not what differs — a wagon in the middle is the same shape wherever
    /// in the middle it is, and there should be one mesh for all of them.
    public var headLamps: Bool
    public var tailLamps: Bool

    public init(
        unit: VehicleUnit, mode: Mode,
        front: VehicleShape.EndProfile, back: VehicleShape.EndProfile,
        livery: Livery, headLamps: Bool = false, tailLamps: Bool = false
    ) {
        self.unit = unit
        self.mode = mode
        self.front = front
        self.back = back
        self.livery = livery
        self.headLamps = headLamps
        self.tailLamps = tailLamps
    }

    /// The mesh this key names, in true metres.
    ///
    /// True metres, and not the exaggerated ones the flat drawing uses. A model
    /// is scaled where it is placed, so baking the exaggeration in would make a
    /// separate mesh for every zoom level a vehicle is ever drawn at — hundreds
    /// of copies of one coach, differing by nothing a reader could name. See
    /// `UnitPlacement.scale`.
    ///
    /// Always at full detail, for the same reason and one more. The detail
    /// levels exist to keep vertex counts down on a source that is rewritten
    /// thirty times a second, and a model is uploaded once and then referred
    /// to; there is nothing left for them to save. What they would cost is a
    /// second mesh for the same wagon at every threshold the zoom crosses.
    public func mesh() -> UnitMesh {
        VehicleShape.mesh(
            unit: unit, index: 0,
            in: VehicleLayout(units: [unit], livery: livery, source: .library),
            mode: mode, ends: (front: front, back: back),
            width: unit.width, heightScale: 1, detail: .full,
            lamps: (head: headLamps, tail: tailLamps)
        )
    }
}

/// Where one baked wagon stands, and how it is turned.
public struct UnitPlacement: Sendable, Equatable {
    public var model: VehicleModelKey
    /// The middle of the wagon, on the ground.
    ///
    /// The middle rather than an end, because a model turns about its own
    /// origin and a wagon turns about its middle. Anchored at the tail, a coach
    /// swinging through a station throat would scythe its nose across the
    /// platform.
    public var at: Coord
    /// The compass bearing the nose points along.
    public var heading: Double
    /// How far back from the head of the vehicle this wagon's middle is, in
    /// metres.
    ///
    /// Carried so a train in a tunnel can be placed without asking the tunnel
    /// about every coach. The bore is looked up twice — once for the head, once
    /// for the tail — and every wagon between them is interpolated on this.
    /// Sixteen coaches would otherwise be sixteen walks down the length of the
    /// Lötschberg, thirty times a second.
    public var alongTrain: Double
    /// How long the wagon's body is, in metres.
    ///
    /// Carried because the ground under a wagon is measured at its two *ends*,
    /// and a point and a heading do not say where those are. The gradient a
    /// wagon lies at is the difference between the ground under its nose and
    /// the ground under its tail over the distance between them — see
    /// `MapCoordinator.rest` — so this is the base of that triangle.
    public var length: Double
    /// How steeply the wagon is climbing, in degrees, positive nose-up.
    ///
    /// The one thing a stack of vertical prisms could never do. A prism is
    /// extruded straight up by definition, so a train on the Gotthard ramp was
    /// drawn as a run of level boxes stepping up the hillside; a model can be
    /// turned, and a wagon on a 26 ‰ grade is tilted 1.5 degrees into it.
    /// Small, and the difference between a train on a mountain railway and a
    /// train standing on a staircase.
    public var grade: Double
    /// How much the body is drawn wider and taller than it is.
    ///
    /// The same exaggeration the flat drawing applies, for the same reason: a
    /// 2.9 m body against a 200 m train is a hairline at the zoom the solids
    /// first appear at. Length is never exaggerated — it is the fact the
    /// drawing exists to show.
    public var widthScale: Double
    public var heightScale: Double
    /// How far off the ground the wagon is drawn, in metres, or nil to stand it
    /// on whatever the ground under it turns out to be.
    ///
    /// Almost always nil. It is set for a wagon inside a tunnel, where the
    /// ground over it is a mountain and standing on it would put an intercity
    /// on a summit. See `TunnelProfile`.
    public var altitude: Double?
    /// How solidly it is drawn, 0 to 1 — 1 out in the open, less underground.
    public var ghost: Double

    public init(
        model: VehicleModelKey, at: Coord, heading: Double, grade: Double,
        length: Double, alongTrain: Double = 0,
        widthScale: Double, heightScale: Double,
        altitude: Double? = nil, ghost: Double = 1
    ) {
        self.model = model
        self.at = at
        self.heading = heading
        self.grade = grade
        self.length = length
        self.alongTrain = alongTrain
        self.widthScale = widthScale
        self.heightScale = heightScale
        self.altitude = altitude
        self.ghost = ghost
    }

    /// The same placement moved bodily by a lon/lat offset. See
    /// `VehicleFootprint.shifted`.
    public func shifted(byLon lon: Double, lat: Double) -> UnitPlacement {
        var moved = self
        moved.at = Coord(lon: at.lon + lon, lat: at.lat + lat)
        return moved
    }
}

/// How a wagon is turned for a renderer that takes euler `[lon, lat, z]`.
///
/// Mapbox applies those as rotations about the model's own axes, not about
/// east and north. `lon` is pitch about the right-hand axis (glTF +X), `lat`
/// is unused, `z` is yaw. A positive (nose-up) grade is `[-grade, 0, heading]`:
/// Mapbox's +X is the opposite of ours, and that is true on every heading.
/// See `VehicleModels.placements`.
public enum VehicleAttitude {
    /// `[pitch, 0, yaw]`, in degrees. Nose-up grade is positive.
    public static func euler(heading: Double, grade: Double) -> [Double] {
        [-grade, 0, heading]
    }
}
