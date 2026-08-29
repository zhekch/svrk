import Foundation

// A vehicle seen from above, in real coordinates.
//
// The map already knows where a vehicle is and which way it points, and a dot
// is all either fact supports. What a *shape* needs is the third one: how long
// the thing is, which is where `VehicleLayout` comes in — and then somewhere to
// put it, because a two-hundred-metre train laid along the bearing of its head
// is straight through the outside of every curve it is on.
//
// So the train is laid along its own track. The journey's geometry is the line
// it physically runs on, already built and already on the vehicle for anything
// the map is zoomed in on; the head sits at a known distance along it, and each
// vehicle behind the head takes the next slice going backwards. On a curve the
// coaches then follow the curve, which is the single thing that makes the
// drawing read as a train rather than as a stack of rectangles.
//
// Each unit is drawn *rigid*, between the two points where its own ends fall on
// that line, rather than bent along it. A real coach is a rigid box on two
// bogies and does exactly this: it cuts the inside of a curve and overhangs the
// outside, and neighbouring coaches scissor slightly at the couplers. Bending
// each body to the alignment would look smoother and be wrong.
//
// Everything here is metres and degrees, and none of it knows what a pixel is
// except through `metresPerPoint` — which decides only how wide a body may be
// drawn (a real train is three metres across, which is a hairline on a map) and
// how much detail is worth emitting.

/// One piece of the drawing: a closed ring, and what colour it is.
public struct FootprintPart: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        /// The body outline. The only role that gets a stroke.
        case body
        /// The roof, drawn as a band down the middle so the operator's colour
        /// still shows along the sides.
        case roof
        case glass
        case pantograph
        case door
        /// A road vehicle's tyres, standing proud of the body.
        case wheel
        /// The bellows between two modules of an articulated vehicle. How many
        /// of them there are is most of what separates a tram from a bus.
        case joint
        /// The band that says which class, which is what somebody on a
        /// platform is actually looking for.
        case stripe
    }

    public var role: Role
    public var ring: [Coord]
    public var fill: String

    public init(role: Role, ring: [Coord], fill: String) {
        self.role = role
        self.ring = ring
        self.fill = fill
    }
}

/// A lamp on the end of a vehicle.
///
/// White at the front, red at the back, two of each, in the places a real one
/// carries them. There is nothing else in this file that exists only after
/// dark, and nothing else that says which way a vehicle is *facing* rather than
/// which way it is pointing — a train standing at a terminus with its tail
/// lights toward you has not turned round, and the drawing now says so.
public struct VehicleLamp: Sendable, Equatable {
    public var at: Coord
    /// How far off the ground the lamp is, in metres — already carrying
    /// whatever exaggeration the rest of the vehicle was drawn with.
    ///
    /// The one thing this used not to have, and the reason the lights looked
    /// wrong. A map with a horizon in it draws a thing at height *h* several
    /// metres from where it draws the same thing on the floor; given no height,
    /// four lamps that belong on the nose and the tail of a train were drawn on
    /// the ground in front of it and behind it, which is exactly what they
    /// looked like. See `VehicleLamps.features`, which is where the height is
    /// finally turned back into a position.
    public var height: Double
    /// A tail lamp rather than a head lamp.
    public var red: Bool
    /// The compass bearing the lamp points along.
    ///
    /// Carried so the map can work out whether it is pointing anywhere near the
    /// camera — see `VehicleLamps.features`. A lamp is a directional thing and
    /// this is the only property that says which way it shines; without it the
    /// four lamps of a vehicle are four identical dots and the two on the far
    /// end have to be drawn as well, through the body carrying them.
    public var facing: Double

    public init(at: Coord, height: Double, red: Bool, facing: Double) {
        self.at = at
        self.height = height
        self.red = red
        self.facing = facing
    }
}

/// One vehicle, drawn.
public struct VehicleFootprint: Sendable, Equatable {
    public var id: String
    /// In draw order: every body first, then the detail that sits on top of it.
    public var parts: [FootprintPart]
    /// The same vehicle as a solid, sliced into horizontal slabs — empty
    /// unless the camera is tilted far enough in to be looking *along* the
    /// vehicle rather than down at it. See `VehicleMesh` for what the slices
    /// are, and `VehicleShape.solidity` for when they are worth building.
    public var slabs: [MeshSlab] = []
    /// The same vehicle as baked models: one entry per wagon, saying which
    /// mesh it is and where that mesh stands.
    ///
    /// Built alongside `slabs` and from the same geometry, because the two are
    /// the same wagon told two ways — a renderer that can be handed a mesh once
    /// takes these, and one that can only be handed polygons takes those.
    public var placements: [UnitPlacement] = []
    /// The head and tail lamps, for a map drawn after dark.
    public var lamps: [VehicleLamp] = []
    /// The line the vehicle occupies, head first. Kept because it is also the
    /// answer to "did the finger land on this train" — a tap on the eighth
    /// coach of an IC is a tap on the IC, and measuring to the head alone put
    /// four hundred metres between the two.
    public var centreline: [Coord]

    /// A point on the rails this vehicle occupies, `metres` back from the head.
    ///
    /// The wagons themselves are chords: each body is a straight line between
    /// its two ends, which on a curve sits *inside* the rails. Asking the
    /// ground under a chord is asking the ground beside the track — a pool, a
    /// cutting, the valley the embankment is holding the railway above — and
    /// that is what stood one coach on its nose while the next sat level.
    /// The rails are the ground the bogies actually stand on.
    public func rails(at metres: Double) -> Coord {
        VehicleShape.Walk(centreline).point(at: metres)
    }
    /// How long the vehicle is on screen right now, in points. What decides
    /// whether it is worth drawing as a shape at all.
    public var lengthPoints: Double
    /// How far through the change from dot to vehicle this one is: 0 is a dot,
    /// 1 is fully drawn.
    public var emergence: Double
    public var stroke: String
    public var selected: Bool
    /// Whether to draw the selection ring round it.
    ///
    /// Not the same question as `selected`, and separating them is the point.
    /// `selected` also decides that a vehicle turns from a dot into a drawing
    /// sooner than its neighbours — somebody who has tapped a train is looking
    /// at *that* train — and that must hold for as long as it is the selection.
    /// The ring is a different job: it answers "which one did I tap", and once
    /// the map is holding the vehicle in the middle of the screen and moving
    /// with it, the answer is obvious and the ring is just a yellow line
    /// between the reader and the train. See `AppModel.rebuildShapes`.
    public var ringed: Bool
    /// Whether this vehicle is at street level rather than on the railway.
    ///
    /// The map is flat and the country is not. At Bern the buses stand on the
    /// Bahnhofplatz deck and the trains are in the station underneath it, so
    /// their drawings cross — and drawn in an arbitrary order the crossing
    /// reads as a collision rather than as a bridge. Which is over which is
    /// something this *can* say: a road vehicle passes over a railway far more
    /// often than under one, everywhere in the country. So road vehicles are
    /// drawn last, over a dark casing, and the pair reads the way it looks from
    /// the platform.
    public var aboveGround: Bool

    /// The same footprint moved bodily by a lon/lat offset.
    ///
    /// For the vehicle the camera is following, which is redrawn once per
    /// display refresh while the model produces a new one only thirty times a
    /// second. Translating what the model last built — rather than deriving a
    /// fresh footprint from a predicted position — is what guarantees the body
    /// and the camera move by *identical* amounts, so the vehicle cannot swim
    /// against the view that is holding it centred. See
    /// `MapCoordinator.followFrame`.
    public func shifted(byLon lon: Double, lat: Double) -> VehicleFootprint {
        guard lon != 0 || lat != 0 else { return self }
        var moved = self
        moved.parts = parts.map { part in
            var part = part
            part.ring = part.ring.map { Coord(lon: $0.lon + lon, lat: $0.lat + lat) }
            return part
        }
        moved.lamps = lamps.map {
            VehicleLamp(
                at: Coord(lon: $0.at.lon + lon, lat: $0.at.lat + lat),
                height: $0.height, red: $0.red, facing: $0.facing
            )
        }
        moved.placements = placements.map { $0.shifted(byLon: lon, lat: lat) }
        moved.slabs = slabs.map { slab in
            var slab = slab
            slab.rings = slab.rings.map { ring in
                ring.map { Coord(lon: $0.lon + lon, lat: $0.lat + lat) }
            }
            return slab
        }
        moved.centreline = centreline.map { Coord(lon: $0.lon + lon, lat: $0.lat + lat) }
        return moved
    }

    public var isEmpty: Bool { parts.isEmpty }

    /// How far a point is from the vehicle, in metres.
    ///
    /// Measured to the line the vehicle occupies rather than to its head, which
    /// is the whole reason the centreline is carried out of the builder. A tap
    /// on the eighth coach of an intercity is a tap on that intercity, and to a
    /// distance measured from the front of the train it is four hundred metres
    /// away — further than the bus stop it is passing, which is what used to
    /// answer instead.
    public func distance(lon: Double, lat: Double) -> Double {
        guard centreline.count >= 2 else {
            guard let only = centreline.first else { return .infinity }
            return Geo.flatMetres(only.lon, only.lat, lon, lat)
        }
        var best = Double.infinity
        // In metres on a local tangent plane. Over the length of a train the
        // curvature of the earth is a few millimetres.
        let scale = cos(Geo.toRad(centreline[0].lat)) * Geo.metresPerDegree
        let px = lon * scale, py = lat * Geo.metresPerDegree
        for i in 1..<centreline.count {
            let a = centreline[i - 1], b = centreline[i]
            let ax = a.lon * scale, ay = a.lat * Geo.metresPerDegree
            let bx = b.lon * scale, by = b.lat * Geo.metresPerDegree
            let dx = bx - ax, dy = by - ay
            let squared = dx * dx + dy * dy
            let t = squared > 0
                ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / squared))
                : 0
            let cx = ax + dx * t, cy = ay + dy * t
            best = min(best, ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot())
        }
        return best
    }
}

public enum VehicleShape {

    // MARK: - When a dot becomes a vehicle

    /// The shortest a vehicle may be drawn on screen before it is worth
    /// drawing as a shape, in points, and the length at which it is fully
    /// drawn.
    ///
    /// Measured on the vehicle rather than on the zoom, and that is the whole
    /// idea. A single zoom threshold has to be set for the average vehicle,
    /// which means either a four-hundred-metre ICE stays a dot long after it
    /// would have read perfectly well, or a twelve-metre bus turns into an
    /// unreadable smear two zoom levels early. Sized in points, each vehicle
    /// arrives when it is big enough to be recognised: an intercity at about
    /// zoom 13, a tram around 16, a minibus not until 17. Nothing is ever drawn
    /// as a shape too small to read, and nothing is held back as a dot once it
    /// is not.
    /// The shortest a *whole vehicle* may be on screen before it is drawn as
    /// one, and the least each of its bodies needs on top of that.
    ///
    /// Two numbers rather than one, because "long enough to read" means
    /// different things for a bus and for an intercity. A bus is a single
    /// oriented blob and there is nothing inside it to resolve — eight points
    /// is plenty, and holding it back to the length a nine-coach train needs
    /// kept every bus in the country a dot until zoom 16. A train has to show
    /// that it is made of coaches, so it needs a couple of points per body
    /// before the drawing says anything the dot did not.
    public static let shortestVehiclePoints = 8.0
    public static let perBodyPoints = 2.2

    /// Where the change from dot to vehicle begins for a given layout.
    public static func emergeAt(bodies: Int) -> Double {
        max(shortestVehiclePoints, perBodyPoints * Double(max(1, bodies)))
    }

    /// Below this there is no point looking: at national zoom every vehicle in
    /// the country is one pixel and there are thousands of them.
    ///
    /// It is a floor under the rule above rather than the rule itself. A
    /// four-hundred-metre train passes `emergeAt` at about zoom 11, where the
    /// screen holds most of the Mittelland and a couple of thousand vehicles —
    /// and where a shape twenty points long carries no information a dot does
    /// not, because at that scale the *fleet* is the picture and no individual
    /// train is being looked at.
    public static let minZoom = 12.5

    /// Longer than anything this can draw, in metres.
    ///
    /// A doubled sixteen-coach intercity is about 440 m and an ICE 1 about 410.
    /// Used to widen the viewport query, where being generous costs a handful
    /// of extra vehicles and being tight costs a whole train disappearing.
    public static let longestVehicleMetres = 600.0

    /// The narrowest a body may be drawn, in points.
    ///
    /// Length is at true ground scale and always will be — it is the fact the
    /// drawing exists to show. Width cannot be: standard-gauge stock is 2.9 m
    /// against a 200 m train, so a truthful top view of an intercity at zoom 14
    /// is 51 points long and less than one point wide, which is a hairline and
    /// not a train. So the body is drawn at its real width or this, whichever
    /// is more — which means the exaggeration shrinks as the map is zoomed in
    /// and disappears entirely around zoom 18, where the real width finally
    /// wins on its own.
    ///
    /// Four and a half rather than seven, which is what it was. Seven points is
    /// a comfortable width for a two-hundred-metre train and an absurd one for
    /// a tram: at zoom 14.6 a 36 m Cobra is 16.7 points long, so seven across
    /// drew it at 2.4:1 — and an 18 m articulated bus at 1.2:1, which is a
    /// square. See `maxWidthShare`, which is the other half of the fix.
    public static let minWidthPoints = 4.5

    /// The widest a vehicle may be drawn as a share of its own drawn length.
    ///
    /// **A minimum width alone cannot be right, because it says nothing about
    /// the vehicle it is applied to.** The floor exists so a long train is not
    /// a hairline; applied to a short one it is the opposite problem, and the
    /// two need one rule between them. So the floor is itself bounded: nothing
    /// is ever drawn fatter than this share of its length, however few points
    /// that leaves.
    ///
    /// A quarter is about the proportion of a real city bus seen from above,
    /// which is the stubbiest thing on this map. Everything longer than a bus
    /// is drawn longer than a bus in proportion, which is the whole claim the
    /// drawing makes.
    public static let maxWidthShare = 0.25

    /// How wide one vehicle's widest body is drawn, in metres of the ground.
    ///
    /// The floor is applied to the widest unit and every other body keeps its
    /// proportion to it, so a locomotive stays wider than the coaches behind it
    /// and a train and a bus are not made the same width merely because both
    /// were too narrow to draw honestly.
    public static func drawnWidth(
        of layout: VehicleLayout, metresPerPoint: Double
    ) -> (metres: Double, scale: Double) {
        let widest = layout.widestUnit
        guard widest > 0, metresPerPoint > 0 else { return (widest, 1) }
        let lengthPoints = layout.length / metresPerPoint
        let wanted = min(minWidthPoints, lengthPoints * maxWidthShare)
        let scale = max(1, (wanted * metresPerPoint) / widest)
        return (widest * scale, scale)
    }

    /// How much detail to emit, which is a question about how many pixels one
    /// body has to spend rather than about zoom.
    public enum Detail: Int, Sendable, Comparable {
        /// Bodies only.
        case outline = 0
        /// The roof band, the windscreens and the class stripes.
        case trim = 1
        /// Doors and pantographs as well.
        case full = 2

        public static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }

        /// Chosen from how long one unit comes out on screen, in points.
        ///
        /// Length rather than width, and per unit rather than per vehicle, and
        /// both of those were got wrong first. Width cannot decide it: every
        /// body on this map is drawn at least `minWidthPoints` across, so a
        /// rule written against width answers the same thing at every zoom
        /// until the exaggeration runs out around zoom 18 — which is to say it
        /// never fires. And a rule written against the whole vehicle puts doors
        /// on a four-hundred-metre train whose individual coaches are four
        /// points long, because the train is plenty long enough and the coach
        /// is not.
        public static func forUnit(lengthPoints: Double) -> Detail {
            if lengthPoints >= 22 { return .full }
            if lengthPoints >= 8 { return .trim }
            return .outline
        }
    }

    // MARK: - Building one

    /// Draw a vehicle, or return nil where it is still better as a dot.
    ///
    /// `metresPerPoint` is the map's own scale — see `MapCoordinator`, which
    /// has the only camera that knows it.
    /// The distance between the centres of two adjacent tracks, in metres.
    ///
    /// Swiss main-line practice is between 4.0 and 4.8 depending on speed;
    /// through a station throat it is nearer the bottom of that. It is used to
    /// place trains that share one alignment onto plausible parallel ones —
    /// see `lateralOffset`.
    public static let trackSpacing = 4.6

    /// How long the change from dot to drawing takes, in seconds.
    ///
    /// It used to take however long the reader spent crossing a zoom band,
    /// which is to say anywhere between one frame and forever. `emergence` was
    /// a ramp across the zooms either side of the threshold, so a map parked
    /// halfway through it held every vehicle in the country at half opacity —
    /// a permanent state of neither-one-nor-the-other — and a slow pinch was a
    /// fleet of ghosts sliding in and out for as long as the finger moved.
    ///
    /// The threshold is a decision, not a gradient. Crossing it starts a
    /// change of this length and the change finishes whatever the camera does
    /// next; a map held still halfway through a pinch settles on one drawing
    /// or the other. See `AppModel.rebuildShapes`, which owns the clock.
    public static let emergeSeconds = 0.22

    public static func footprint(
        of vehicle: VehicleSnapshot, layout: VehicleLayout,
        metresPerPoint: Double, selected: Bool = false, ringed: Bool? = nil,
        lateralOffset: Double = 0, solid: Bool = false, extruded: Bool = true,
        emerged: Double? = nil, bodiesOnly: Bool = false
    ) -> VehicleFootprint? {
        guard metresPerPoint > 0 else { return nil }
        let total = layout.length
        guard total > 0 else { return nil }

        let lengthPoints = total / metresPerPoint
        // The selected vehicle is drawn as a shape a little sooner than the
        // rest of them. Somebody who has tapped a train is looking at *that*
        // train, and the formation panel beside the map is already describing
        // the thing the dot is refusing to show.
        let threshold = emergeAt(bodies: layout.units.count)
        let floor = selected ? threshold * 0.6 : threshold
        // Told, or worked out here. Told is the normal case and the one that
        // animates: the caller keeps a per-vehicle clock and hands in where
        // this vehicle has got to, which is also what lets a vehicle that has
        // just dropped below the threshold go on being drawn for the fifth of
        // a second it takes to leave. Worked out is the fallback for callers
        // with no clock — the tests, and the single-shape rewrite the followed
        // vehicle gets — and there it is the plain answer, in or out.
        let emergence = emerged ?? (lengthPoints >= floor ? 1 : 0)
        guard emergence > 0 else { return nil }

        // Hung behind the position, not centred on it.
        //
        // Centring was an attempt to put the middle of the train against the
        // middle of the platform, and the premise was wrong: Swiss platforms
        // are mostly served at one end, so the train's *front* is what stands
        // where the feed says the vehicle is. It also cost the drawing dearly.
        // Half the body was laid out along the leg the vehicle has not run yet,
        // and wherever that walk ran out — a train standing at a terminus, a
        // vehicle at its last call — the front half was extrapolated along a
        // single bearing instead of along the rails. On a curve that is a
        // hundred metres of train drawn dead straight through the platform it
        // is standing at, which is what "the parked trains don't follow the
        // track" was.
        //
        // Anchored at the nose, every metre of the body comes off vertices the
        // vehicle has actually covered, so it bends with the track it is on.
        let raw = centreline(of: vehicle, length: total + 2, lead: 0)
        guard raw.count >= 2 else { return nil }
        // Shifted sideways where something has decided this vehicle is not on
        // the alignment it was matched to — see `AppModel.spread`. The shifted
        // line is what is kept, so a tap is answered against the body that was
        // actually drawn rather than the one it was derived from.
        let line = lateralOffset == 0 ? raw : Self.shifted(raw, by: lateralOffset)
        let walk = Walk(line)

        var parts: [FootprintPart] = []
        var details: [FootprintPart] = []
        // Only where something is going to look at them. Slicing costs about
        // as much again as the flat drawing does, and the flat drawing is the
        // thing this runs thirty times a second for several hundred vehicles.
        var slabs: [MeshSlab] = []
        // And the same wagons named rather than drawn: one key and one point
        // each, for a renderer that has been handed the shapes already. See
        // `UnitPlacement`.
        var placements: [UnitPlacement] = []
        // Four points a vehicle, so they are built whether or not anything is
        // going to draw them — the alternative is threading the basemap's
        // colour scheme down into a geometry builder that has no other reason
        // to know about it, to save four coordinates against several hundred
        // polygons.
        var lamps: [VehicleLamp] = []
        // How much the bodies are widened past the truth so that they read as
        // bodies. See `drawnWidth`.
        let scale = drawnWidth(of: layout, metresPerPoint: metresPerPoint).scale

        var offset = 0.0
        var lastHeading: Double?
        for (index, unit) in layout.units.enumerated() {
            if index > 0, unit.joint != .bellows { offset += VehicleLayout.couplerGap }
            let front = walk.point(at: offset)
            let back = walk.point(at: offset + unit.length)
            offset += unit.length

            // A body is drawn along the line between its own two ends, and that
            // line has to be long enough to have a direction. Where a path
            // doubles back on itself — a station throat, a reversal, a stub
            // both ends of the coach land near — the two points come out almost
            // on top of each other and the bearing between them is whatever the
            // last few centimetres of noise happened to say, which draws one
            // coach across the middle of the train at a random angle. Carrying
            // the previous body's heading is right in every one of those cases:
            // it is a rigid vehicle coupled to the one in front of it.
            let separation = Geo.metres(back, front)
            let heading = separation > max(0.5, unit.length * 0.2)
                ? Geo.bearing(back, front)
                : (lastHeading ?? vehicle.bearing)
            lastHeading = heading
            // With a degenerate span the origin is meaningless too: place the
            // body behind the point it should have started from instead.
            let origin = separation > max(0.5, unit.length * 0.2)
                ? back
                : offsetPoint(front, bearing: heading + 180, metres: unit.length)
            let frame = Frame(origin: origin, heading: heading)
            let width = unit.width * scale

            let ends = profiles(for: unit, at: index, in: layout)
            let unitPoints = unit.length / metresPerPoint
            let ring = outline(
                length: unit.length, width: width, front: ends.front, back: ends.back,
                steps: smoothness(lengthPoints: unitPoints, widthPoints: width / metresPerPoint)
            )
            parts.append(FootprintPart(
                role: .body, ring: frame.project(ring), fill: colour(of: unit, in: layout)
            ))

            // Nothing but bodies until the vehicle has finished arriving.
            //
            // Two reasons, and the second is the one that would have been found
            // late. A half-faded shape is a stack of semi-transparent polygons
            // and they blend with each other, so a roof drawn at 50% over a
            // body drawn at 50% is darker than either — the train browns off in
            // the middle of the transition and comes right again at the end.
            // And a vehicle still growing is small: whatever is painted on it
            // is a smear of subpixel rectangles that costs a feature each.
            let detail = emergence < 1
                ? Detail.outline
                : Detail.forUnit(lengthPoints: unitPoints)

            // The solid, from the same frame, the same ends and the same width
            // the flat body was just built from. Sharing those four is what
            // guarantees the solid's silhouette from directly above is the flat
            // drawing exactly — which is the whole reason tilting the map reads
            // as one vehicle standing up rather than as two vehicles swapping.
            if solid, emergence >= 0.999 {
                let heightScale = min(scale, maxHeightScale)
                // Named, not sent. The mesh behind this key is built once and
                // kept; what crosses per frame is where the wagon is and which
                // way it is turned, which is all anybody is allowed to say
                // about a rigid body. The grade is left at zero because it is
                // not knowable here — it comes off the terrain, which lives in
                // the renderer. See `MapCoordinator.grade`.
                placements.append(UnitPlacement(
                    model: VehicleModelKey(
                        unit: unit, mode: vehicle.mode,
                        front: ends.front, back: ends.back, livery: layout.livery,
                        // The outermost ends of the outermost bodies, which is
                        // the same rule the halo over each lamp is placed by —
                        // and it has to be, because for a moment during the
                        // change from one drawing to the other both are on
                        // screen and they have to agree.
                        headLamps: index == 0,
                        tailLamps: index == layout.units.count - 1
                    ),
                    at: frame.project(unit.length / 2, 0),
                    heading: heading,
                    grade: 0,
                    // The body's own length, which is what the two ends the
                    // grade is measured between are half of. Not the length
                    // with the coupler gap: the gap is between wagons and the
                    // ground is measured under one.
                    length: unit.length,
                    // `offset` has already had this unit's length added to it,
                    // so the head of the train to the middle of this wagon is
                    // what is left when half of it is taken back off.
                    alongTrain: offset - unit.length / 2,
                    // The mesh is baked at the wagon's true width, so the
                    // exaggeration is carried here and spent on the model when
                    // it is placed. Baked in, it would be a separate mesh of
                    // the same coach for every zoom the map is ever at.
                    //
                    // Fixed, rather than the flat drawing's factor. That one is
                    // a screen-space floor and therefore a function of the
                    // camera, and spending a camera-dependent number on a rigid
                    // body is the body inflating as the map zooms out. See
                    // `VehicleShape.modelExaggeration`.
                    widthScale: modelExaggeration,
                    heightScale: modelExaggeration
                ))
                if extruded {
                    slabs.append(contentsOf: VehicleShape.mesh(
                        unit: unit, index: index, in: layout, mode: vehicle.mode,
                        ends: ends, width: width,
                        heightScale: heightScale, detail: detail,
                        lamps: (
                            head: index == 0, tail: index == layout.units.count - 1
                        )
                    ).projected(by: frame))
                }
            }

            // The lamps, on the outermost ends of the outermost bodies.
            //
            // *On* the front, at the height a front carries them, and both
            // halves of that are a correction.
            //
            // They used to be flat on the ground half a metre clear of each
            // end. Clear of it, because a lamp is culled when it points away
            // from the camera and one sitting under four metres of train read
            // as pointing nowhere; on the ground, because nothing here had a
            // height to give it. Together those put every light several metres
            // in front of and below the nose supposed to be carrying it — the
            // ground in front of a train is exactly where a point at zero
            // height lands once the map has a horizon in it, and the further
            // the camera is tilted the further out it slides.
            //
            // Carrying the height fixes both at once, because the height is
            // what the drawing was missing rather than the position. A lamp at
            // 1.9 m is drawn where 1.9 m is, which is on the front of the
            // train; and having somewhere to stand it no longer has to be held
            // out in front to be seen. So it comes back onto the nose — a third
            // of the way into whatever end profile this body has, which is
            // where the taper is still wide enough for two lamps to sit on it
            // rather than beside it.
            // Nothing that hangs is lit. A gondola has no headlights, and the
            // halo is placed off the ground under the vehicle rather than off
            // the body — so on a cabin flying eight metres up it would be a
            // pair of lights in the meadow underneath. The mesh makes the same
            // exclusion; see `VehicleShape.mesh`.
            if index == 0 || index == layout.units.count - 1, unit.silhouette.hover == 0 {
                let half = width / 2
                // The same exaggeration the solid is built with, so the lamps
                // rise with the vehicle rather than sinking into a body that
                // has been drawn twice as tall as they are. Which of the two
                // that is depends on which solid is being drawn: a baked model
                // keeps a fixed cross-section, the extruded fallback keeps the
                // flat drawing's. See `VehicleShape.modelExaggeration`.
                let height = stack(for: unit, mode: vehicle.mode).lampHeight
                    * (solid && !extruded ? modelExaggeration : min(scale, maxHeightScale))
                // The same outline the body was just drawn from, so the halo
                // lands on the lamp the mesh puts there rather than near it.
                let plan = ring.map { MeshPoint(x: $0.x, y: $0.y) }
                for front in [true, false]
                where front ? index == 0 : index == layout.units.count - 1 {
                    guard let anchor = lampAnchor(
                        on: plan, front: front, half: half
                    ) else { continue }
                    for side in [-1.0, 1.0] {
                        lamps.append(VehicleLamp(
                            at: frame.project(anchor.along, side * anchor.across),
                            height: height, red: !front,
                            facing: front ? heading : heading + 180
                        ))
                    }
                }
            }

            // The doors, the windows, the class stripes and the roof band —
            // and only where something can paint them.
            //
            // A vehicle standing up as a baked mesh is drawn by the mesh. Its
            // flat drawing is still *built*, because the silhouette a building
            // takes out of it is traced from these same polygons and that is
            // the only thing on a tilted map saying where a train behind a
            // block of flats is — but every layer that could paint the trim is
            // filtered on `lying`, which such a vehicle is not, and the one
            // layer that still asks for it wants `Key.body` as well. See
            // `VehicleShapes.features`, which has skipped emitting them for
            // some time and still had them handed over: eighteen polygons per
            // wagon built, projected, turned into features and dropped again,
            // thirty times a second, for a picture nothing was going to draw.
            guard !bodiesOnly, detail > .outline else { continue }
            details.append(contentsOf: trim(
                unit: unit, ends: ends, width: width, frame: frame,
                livery: layout.livery, detail: detail
            ))
        }

        parts.append(contentsOf: details)
        // The morph. A vehicle part-way through arriving is drawn smaller,
        // about its own nose, so what the reader sees is the dot growing into
        // a train rather than two unrelated pictures overlapping at half
        // opacity each. The nose is the anchor because it is where the feed
        // says the vehicle *is* — the dot and the head of the drawing are the
        // same point, so nothing slides sideways on the way in or out. Eased,
        // so it leaves and arrives without a corner. See `grown`.
        if emergence < 1 {
            let e = min(1, max(0, emergence))
            parts = Self.grown(parts, about: line[0], by: 0.42 + 0.58 * (e * e * (3 - 2 * e)))
        }
        return VehicleFootprint(
            id: vehicle.id, parts: parts, slabs: slabs, placements: placements,
            lamps: lamps, centreline: line,
            lengthPoints: lengthPoints, emergence: emergence,
            stroke: layout.livery.stroke, selected: selected, ringed: ringed ?? selected,
            aboveGround: Self.isAboveGround(vehicle.mode)
        )
    }

    /// Every ring of a footprint drawn towards or away from one point.
    ///
    /// A similarity in the local tangent plane: scaling the longitude and the
    /// latitude offsets by the same factor is the same shape, smaller. Over
    /// four hundred metres the difference between that and doing it properly
    /// in metres is far below the width of the line it is drawn with.
    ///
    /// The centreline is deliberately *not* scaled. It is what a tap is
    /// answered against, and a train that could only be hit at 42% of its
    /// length for a fifth of a second would be a train that swallowed taps.
    private static func grown(
        _ parts: [FootprintPart], about anchor: Coord, by factor: Double
    ) -> [FootprintPart] {
        parts.map { part in
            var part = part
            part.ring = part.ring.map {
                Coord(
                    lon: anchor.lon + ($0.lon - anchor.lon) * factor,
                    lat: anchor.lat + ($0.lat - anchor.lat) * factor
                )
            }
            return part
        }
    }

    /// Whether a mode runs at street level.
    ///
    /// A tram counts: it runs in the road, over the same bridges the buses use.
    /// A metro does not — Lausanne's M2 is in a tunnel under everything.
    public static func isAboveGround(_ mode: Mode) -> Bool {
        switch mode {
        case .train, .metro: return false
        case .tram, .bus, .cable, .boat, .other: return true
        }
    }

    // MARK: - Where the vehicle lies

    /// The line the vehicle occupies, head first, `length` metres of it.
    ///
    /// Off the journey's own geometry where there is any, because that is the
    /// track the train is physically on. Where there is not — a bus, or a
    /// vehicle whose position came off the straight line between two stops —
    /// it is a straight line back along the bearing, which is exactly as much
    /// as is known.
    /// `lead` is how far ahead of the vehicle's own position the front of it
    /// sits — half the length, to centre the thing on the point the feed gave.
    public static func centreline(
        of vehicle: VehicleSnapshot, length: Double, lead: Double = 0
    ) -> [Coord] {
        // Walked from where the vehicle honestly is, then moved bodily to where
        // it is being drawn. While a correction is being walked off, those are
        // not the same point — `lon`/`lat` carries the displacement and the path
        // does not — and starting the walk from the drawn nose would put a kink
        // in the middle of the train: the front off the line and the coaches
        // snapping back onto it. A rigid thing slides in one piece. See
        // `VehicleSnapshot.drift`.
        let drift = vehicle.drift
        let point = Coord(
            lon: vehicle.lon - (drift?.lon ?? 0), lat: vehicle.lat - (drift?.lat ?? 0)
        )
        // Only the part of the correction that runs *along* the track, and
        // handed to the walk rather than added to what it returns.
        //
        // `Fleet.keepContinuous` holds its correction in degrees, and it has to:
        // half of what it is correcting for is a vehicle stepping sideways off
        // a chord and onto the rails, and no amount of winding a clock walks a
        // vehicle sideways. But a *body* is not a dot. Moved bodily by that
        // correction, a two-hundred-metre train is drawn as a faithful copy of
        // its own rails standing parallel to them, a track or more away — which
        // is the report that the train "comes off the rails", and it is this
        // translation and nothing else.
        //
        // Dropping the sideways half is only half the answer, because the
        // along-track half cannot be added as a vector either: a straight step
        // of a couple of hundred metres across a curve is a step off the curve,
        // and a body translated down the chord of a bend stands outside it.
        // So the correction is spent as extra `lead` — walked along the rails
        // the same way the vehicle's own length is — and what comes back needs
        // no moving at all.
        //
        // The dot therefore keeps its smooth diagonal correction and the body
        // does not: the coaches are laid along the rails they are on and eased
        // only forwards and backwards over them. What that costs is the
        // sideways half arriving in one frame instead of over half a second,
        // and at the zooms a body is drawn at all that half is metres —
        // against a train beside its own track, which is wrong at any width.
        let shift = drift.map {
            alongTrackMetres(of: $0, heading: vehicle.bearing, at: point.lat)
        } ?? 0
        guard let tail = alongTrack(
            vehicle, head: point, length: length, lead: lead + shift
        ) else {
            let nose = Coord(lon: vehicle.lon, lat: vehicle.lat)
            let front = lead > 0
                ? offsetPoint(nose, bearing: vehicle.bearing, metres: lead)
                : nose
            return [front, offsetPoint(front, bearing: vehicle.bearing + 180, metres: length)]
        }
        return tail
    }

    /// How much of a displacement lies along `heading`, in metres, signed
    /// forward. The part lying across it is dropped, which is the whole point.
    static func alongTrackMetres(
        of drift: Coord, heading: Double, at latitude: Double
    ) -> Double {
        let x = drift.lon * cos(latitude * .pi / 180) * Geo.metresPerDegree
        let y = drift.lat * Geo.metresPerDegree
        let radians = heading * .pi / 180
        return x * sin(radians) + y * cos(radians)
    }

    /// Walk backwards down the journey's path from the head.
    private static func alongTrack(
        _ vehicle: VehicleSnapshot, head: Coord, length: Double, lead: Double
    ) -> [Coord]? {
        // Only where the position itself came off the track. A vehicle on the
        // chord is not on its geometry, and hanging its coaches off a line it
        // is not standing on would draw a train beside itself.
        guard vehicle.onTrack, let geometry = vehicle.geometry,
              geometry.legs.count == vehicle.stops.count,
              !geometry.path.isEmpty
        else { return nil }

        let path = geometry.path
        let leg = min(max(0, vehicle.index), geometry.legs.count - 1)
        let start = geometry.legs[leg]
        guard start >= 0, start < path.count else { return nil }

        // Which vertex the head has just passed. The position was computed as a
        // fraction of this leg's length, so the same walk finds the same point.
        var vertex = start
        if leg + 1 < geometry.legs.count {
            let end = geometry.legs[leg + 1]
            if end > start, end < path.count {
                var run = 0.0
                var lengths: [Double] = []
                lengths.reserveCapacity(end - start)
                for i in (start + 1)...end {
                    let step = Geo.metres(path[i - 1], path[i])
                    lengths.append(step)
                    run += step
                }
                let target = max(0, min(1, vehicle.progress)) * run
                var walked = 0.0
                for (i, step) in lengths.enumerated() {
                    if walked + step >= target { vertex = start + i; break }
                    walked += step
                    vertex = start + i + 1
                }
            }
        }

        // Walk along the path first, to put the front of the vehicle `lead`
        // metres from where the feed says it is. The backward walk then starts
        // from there and passes back through the real position on its way.
        //
        // Signed, because `lead` carries a correction in flight as well as half
        // the vehicle's length, and a correction can run either way — see
        // `centreline`. Walked over the vertices in both directions so that a
        // body on a curve stays on the curve.
        var anchor = head
        if lead >= 0 {
            var ahead = 0.0
            while ahead < lead, vertex + 1 < path.count {
                let next = path[vertex + 1]
                let step = Geo.metres(anchor, next)
                if step <= 0.01 { vertex += 1; continue }
                if ahead + step >= lead {
                    let share = (lead - ahead) / step
                    anchor = Coord(
                        lon: anchor.lon + (next.lon - anchor.lon) * share,
                        lat: anchor.lat + (next.lat - anchor.lat) * share
                    )
                    ahead = lead
                    break
                }
                ahead += step
                anchor = next
                vertex += 1
            }
            // Off the end of its own geometry — a train about to terminate,
            // whose front is past the last vertex the route describes.
            //
            // Carried on along the *track's* own direction rather than the
            // vehicle's reported bearing. They usually agree, and where they do
            // not the bearing wins on a straight line while the track is still
            // turning — which puts a kink in the middle of the centreline, and
            // a rigid coach spanning a kink stands several metres off the line
            // it is supposed to be on.
            if ahead < lead {
                let heading = vertex >= 1
                    ? Geo.bearing(path[vertex - 1], path[vertex])
                    : vehicle.bearing
                anchor = offsetPoint(anchor, bearing: heading, metres: lead - ahead)
            }
        } else {
            // A correction that puts the vehicle further back than its own nose
            // would be. The walk runs the other way over the same vertices, so
            // the whole body is still laid on the rails rather than swung
            // across the inside of a bend.
            let want = -lead
            var behind = 0.0
            while behind < want, vertex >= 0 {
                let previous = path[vertex]
                let step = Geo.metres(anchor, previous)
                if step <= 0.01 { vertex -= 1; continue }
                if behind + step >= want {
                    let share = (want - behind) / step
                    anchor = Coord(
                        lon: anchor.lon + (previous.lon - anchor.lon) * share,
                        lat: anchor.lat + (previous.lat - anchor.lat) * share
                    )
                    behind = want
                    break
                }
                behind += step
                anchor = previous
                vertex -= 1
            }
            // Off the back of the path entirely. `approach` and the straight
            // carry-on below are already the answer for that, so the backward
            // walk is simply left with nothing of `path` to eat.
            if behind < want {
                let heading = vertex + 2 < path.count && vertex >= -1
                    ? Geo.bearing(path[vertex + 2], path[vertex + 1])
                    : vehicle.bearing + 180
                anchor = offsetPoint(anchor, bearing: heading, metres: want - behind)
            }
        }

        var out: [Coord] = [anchor]
        var covered = 0.0
        var index = vertex
        while covered < length, index >= 0 {
            let point = path[index]
            let step = Geo.metres(out[out.count - 1], point)
            // A path can hold repeated vertices where two ways were joined;
            // adding them makes a zero-length segment the walk below divides by.
            if step > 0.01 {
                out.append(point)
                covered += step
            }
            index -= 1
        }

        // Off the back of the journey's own geometry, which begins at the first
        // stop: a vehicle standing there, or just leaving it, is longer than the
        // line behind it. `approach` is the track that is really there, walked
        // out of the railway graph when the geometry was built, so the body
        // carries on round the curve it is standing on instead of leaving it.
        if covered < length {
            for point in geometry.approach {
                let step = Geo.metres(out[out.count - 1], point)
                if step <= 0.01 { continue }
                out.append(point)
                covered += step
                if covered >= length { break }
            }
        }

        // And where even that runs out — a bus, a vehicle on a chord, a stub of
        // track that simply ends — carry on in a straight line rather than
        // drawing a train with its back cut off.
        if covered < length, out.count >= 2 {
            let last = out[out.count - 1]
            let heading = Geo.bearing(out[out.count - 2], last)
            out.append(offsetPoint(last, bearing: heading, metres: length - covered + 1))
        }
        return out.count >= 2 ? out : nil
    }

    /// The same line, moved sideways.
    ///
    /// Each point is pushed perpendicular to the direction the line is going
    /// *through* it — the mean of the segment either side — so a curve offsets
    /// into a parallel curve rather than being sheared. At the few metres this
    /// is used for, the difference from a true offset curve is far below the
    /// width of the thing being drawn.
    public static func shifted(_ line: [Coord], by metres: Double) -> [Coord] {
        guard line.count >= 2, metres != 0 else { return line }
        var out: [Coord] = []
        out.reserveCapacity(line.count)
        for index in line.indices {
            let before = index > 0 ? line[index - 1] : line[index]
            let after = index + 1 < line.count ? line[index + 1] : line[index]
            let heading = Geo.bearing(before, after)
            out.append(offsetPoint(line[index], bearing: heading + 90, metres: metres))
        }
        return out
    }

    /// A point `metres` away on a bearing, flat-earth, which at these distances
    /// is exact to well under the width of the vehicle being drawn.
    static func offsetPoint(_ from: Coord, bearing: Double, metres: Double) -> Coord {
        Geo.moved(from, bearing: bearing, metres: metres)
    }

    /// A polyline with its cumulative lengths, so a distance from the head is a
    /// lookup rather than a walk from the beginning every time.
    struct Walk {
        let points: [Coord]
        let cumulative: [Double]

        init(_ points: [Coord]) {
            self.points = points
            var running: [Double] = [0]
            running.reserveCapacity(points.count)
            for i in 1..<max(1, points.count) {
                running.append(running[i - 1] + Geo.metres(points[i - 1], points[i]))
            }
            cumulative = running
        }

        /// The point `distance` metres back from the head.
        func point(at distance: Double) -> Coord {
            guard points.count >= 2 else { return points.first ?? Coord(lon: 0, lat: 0) }
            let total = cumulative[cumulative.count - 1]
            if distance <= 0 { return points[0] }
            if distance >= total {
                // Past the end of what is known: carry on along the last
                // bearing rather than piling every remaining coach on the last
                // vertex.
                let last = points[points.count - 1]
                let heading = Geo.bearing(points[points.count - 2], last)
                return VehicleShape.offsetPoint(last, bearing: heading, metres: distance - total)
            }
            var i = 1
            while i < cumulative.count && cumulative[i] < distance { i += 1 }
            let span = cumulative[i] - cumulative[i - 1]
            let f = span > 0 ? (distance - cumulative[i - 1]) / span : 0
            let a = points[i - 1], b = points[i]
            return Coord(lon: a.lon + (b.lon - a.lon) * f, lat: a.lat + (b.lat - a.lat) * f)
        }
    }

    // MARK: - From metres of vehicle to degrees of map

    /// One unit's own coordinate space: metres forward from its back end, and
    /// metres to the right of the direction it faces.
    public struct Frame {
        let origin: Coord
        let sin: Double
        let cos: Double
        let lonScale: Double

        init(origin: Coord, heading: Double) {
            self.origin = origin
            let radians = Geo.toRad(heading)
            sin = Foundation.sin(radians)
            cos = Foundation.cos(radians)
            lonScale = Geo.metresPerDegree * Foundation.cos(Geo.toRad(origin.lat))
        }

        func project(_ x: Double, _ y: Double) -> Coord {
            let east = x * sin + y * cos
            let north = x * cos - y * sin
            return Coord(
                lon: origin.lon + east / max(1, lonScale),
                lat: origin.lat + north / Geo.metresPerDegree
            )
        }

        func project(_ ring: [(x: Double, y: Double)]) -> [Coord] {
            ring.map { project($0.x, $0.y) }
        }

        public func project(_ ring: [MeshPoint]) -> [Coord] {
            ring.map { project($0.x, $0.y) }
        }
    }

    // MARK: - The outlines

    /// What one end of a body looks like from above.
    public enum EndProfile: Sendable, Hashable {
        /// A flat end with the corners rounded off: the ordinary end of a coach.
        case square(chamfer: Double)
        /// The nose of a multiple unit or a driving trailer: a taper to a blunt
        /// point, which is what a windscreen raked back over three metres looks
        /// like from directly above.
        case cab
        /// A high-speed nose: six or seven metres of unbroken curve to a narrow
        /// rounded tip. An ICE, a TGV, a Giruno, an ICN.
        case streamlined
        /// A locomotive: the same idea as a cab over a much shorter distance,
        /// so the end is nearly flat and the corners are strongly cut.
        case locomotive
        /// The nose of a double-deck unit: long in plan and, more to the point,
        /// a storey lower than the body behind it. See `VehicleShape.rake`,
        /// which is where the step in the roofline actually comes from.
        case wedge
        /// The full rounded front Stadler moulds onto a FLIRT, an Allegra or a
        /// NINA: half as deep again as a cab and much blunter at the tip.
        case bulb
        /// An upright front with the corners rounded: a rack railcar, a
        /// funicular car, an open-sided trailer.
        case slab
        /// A tram's front: all but flat, with the corners well rounded. A
        /// Cobra, a Flexity, a Bem 4/6 — none of them has a nose.
        case tramFront
        /// The front of a bus, which is wider and blunter than a cab.
        case busFront
        /// The back of a bus, which is flat and has no windscreen. The one
        /// thing on the drawing that says a vehicle is driven from one end
        /// only, and so is not a tram.
        case busRear
        /// A gangway. No taper, no chamfer: the body is continuous through it,
        /// and any corner drawn here shows up as a notch in the middle of a
        /// tram.
        case gangway
        /// The bow of a boat.
        case bow
    }

    /// Which profile each end of a unit gets.
    public static func profiles(
        for unit: VehicleUnit, at index: Int, in layout: VehicleLayout
    ) -> (front: EndProfile, back: EndProfile) {
        let joinedAhead = unit.joint == .bellows
        let joinedBehind = index + 1 < layout.units.count
            && layout.units[index + 1].joint == .bellows

        // Which end of the body this is, and not merely whether it has a cab.
        //
        // A bus is driven from the front and has a wall at the back, and until
        // the two ends were told apart the last section of an articulated bus
        // was given a windscreen and a rounded nose — so a double-articulated
        // trolleybus was a symmetrical, double-ended, bending vehicle, which is
        // the definition of a tram. Asymmetry is the strongest thing a top view
        // can say about a road vehicle, and it was being thrown away.
        func end(cab: Bool, joined: Bool, leading: Bool) -> EndProfile {
            if joined { return .gangway }
            guard cab else {
                if unit.kind == .bus { return .busRear }
                return .square(chamfer: min(0.55, unit.width * 0.22))
            }
            // The unit's own nose where it has one; failing that, the one its
            // shape family implies. The fallback is what lets a class table
            // state a silhouette once and have both ends of every unit of that
            // class follow, without every builder in the library having to
            // repeat the nose beside it.
            if let nose = unit.nose ?? unit.silhouette.nose {
                switch nose {
                case .streamlined: return .streamlined
                case .blunt: return .tramFront
                case .wedge: return .wedge
                case .bulb: return .bulb
                case .slab: return .slab
                }
            }
            switch unit.kind {
            case .locomotive: return .locomotive
            case .bus: return leading ? .busFront : .busRear
            case .cabin: return .busFront
            case .hull: return .bow
            default: return .cab
            }
        }

        if unit.kind == .hull {
            return (.bow, .square(chamfer: unit.width * 0.18))
        }
        return (
            end(cab: unit.cabFront, joined: joinedAhead, leading: true),
            end(cab: unit.cabBack, joined: joinedBehind, leading: false)
        )
    }

    /// How far back from the tip a profile reaches.
    ///
    /// **`width` is the width the body is *drawn* at, not the width it is**, and
    /// the ends that are corner-rounding rather than nose are measured against
    /// it. That is the fix for "the vehicles look low resolution". A tram front
    /// is 1.3 m deep on a 2.4 m body — a semicircular end — and the widening
    /// that makes a tram visible at all was drawing that same 1.3 m across a
    /// body six times wider, which is a flat wall with a scratch on it. The
    /// coach chamfer had it worse: half a metre of radius on a fifteen-metre
    /// body is a hard right angle, so a train came out as a row of rectangles
    /// with one 45° cut at the front. Written as shares of the drawn width they
    /// are the same shapes at every exaggeration, and they are the honest
    /// proportions of the real vehicle as well — a coach corner really is about
    /// a fifth of the body's width, and a tram's front really is half of it.
    ///
    /// The noses are not. A cab, a high-speed nose, a locomotive end and a bow
    /// are lengthwise facts about the vehicle — an ICE 4's nose is seven metres
    /// whatever the map is doing — so they stay measured against length, with a
    /// floor at the corner rounding they would otherwise fall below.
    public static func depth(of profile: EndProfile, length: Double, width: Double) -> Double {
        /// What a plain rounded corner comes to on a body this wide, which is
        /// the least any end can be shaped by.
        let corner = min(width * 0.2, length * 0.35)
        switch profile {
        // The chamfer the caller worked out is the real vehicle's, and it is
        // kept as a floor: it is the one that wins at the zooms where the
        // widening has run out and the body is drawn at its true width.
        case let .square(chamfer): return min(max(chamfer, corner), length * 0.35)
        case .cab: return min(max(3.6, corner), length * 0.32)
        // Long, because it really is. An ICE 4 end car is 28.8 m and the nose
        // is a quarter of it; drawn at the 3.6 m a cab gets, the front of a
        // three-hundred-metre train was a bevel four points deep and the whole
        // train read as a run of identical boxes.
        case .streamlined: return min(max(7.6, corner), length * 0.42)
        case .locomotive: return min(max(2.2, corner), length * 0.28)
        // Longer than a cab and shorter than a high-speed nose, which is what
        // an FV-Dosto's front is: about five metres from the windscreen's foot
        // to the step in the roof behind it.
        case .wedge: return min(max(4.6, corner), length * 0.26)
        // A hand deeper than a cab. A FLIRT's front is one moulding and it is
        // *full* — the width is still most of the body a metre back from the
        // tip, which is why the tip fraction below matters more than this does.
        case .bulb: return min(max(3.0, corner), length * 0.24)
        // Measured against the width, like the tram front it is a cousin of: a
        // rack railcar's front is a wall with the corners taken off, and it
        // stays that shape however wide the body is drawn.
        case .slab: return min(width * 0.20, length * 0.14)
        // Half the width and a bit: the end of a tram is very nearly a
        // semicircle, and that is what it should stay however wide it is drawn.
        case .tramFront: return min(width * 0.5, length * 0.4)
        case .busFront: return min(width * 0.42, length * 0.34)
        case .busRear: return min(width * 0.24, length * 0.2)
        case .gangway: return 0
        case .bow: return min(length * 0.30, width * 2.1)
        }
    }

    /// How many segments a curved end is drawn with.
    ///
    /// A number rather than a constant because the same nose is four points
    /// across at zoom 13 and two hundred at zoom 18, and the vertex that is
    /// invisible in the first case is the difference between a curve and a
    /// bevel in the second. Vertices are the currency here: every one of them
    /// is emitted, projected, serialised and uploaded fifteen times a second
    /// for every vehicle on screen.
    ///
    /// **From how big the body is on screen, and not from how long it is.** An
    /// end is an arc across the body's *width*, so a body eleven points long
    /// and seven wide was being given the two segments an eleven-point feature
    /// deserves and spending them on a seven-point curve — which is a bevel,
    /// and is most of why the coaches read as boxes with a corner cut off. The
    /// larger of the two dimensions is what the eye is resolving.
    public static func smoothness(lengthPoints: Double, widthPoints: Double = 0) -> Int {
        let points = max(lengthPoints, widthPoints)
        if points >= 120 { return 8 }
        if points >= 45 { return 5 }
        if points >= 16 { return 3 }
        if points >= 5 { return 2 }
        return 1
    }

    /// A nose as a curve rather than as a list of corners.
    ///
    /// `tip` is how wide the very end is as a fraction of the half width — zero
    /// would be a knife edge and nothing real is one — and `power` is how the
    /// body closes in on it. Below 1 the sides leave the full width quickly and
    /// creep in at the tip, which is the shape of every streamlined nose ever
    /// built; at 1 it is a straight bevel.
    static func taper(
        depth: Double, half: Double, tip: Double, power: Double, steps: Int
    ) -> [(x: Double, y: Double)] {
        let steps = max(1, steps)
        var side: [(x: Double, y: Double)] = []
        side.reserveCapacity(steps + 1)
        for i in stride(from: steps, through: 0, by: -1) {
            // 1 at the root of the nose, 0 at the tip.
            let t = Double(i) / Double(steps)
            let y = half * (tip + (1 - tip) * pow(t, power))
            side.append((x: -depth * t, y: -y))
        }
        return side + side.reversed().map { (x: $0.x, y: -$0.y) }
    }

    /// One end, as points running from the left side of the body to the right,
    /// measured back from the tip: `x` is zero at the tip and negative inside.
    public static func end(
        _ profile: EndProfile, length: Double, width: Double, steps: Int = 3
    ) -> [(x: Double, y: Double)] {
        let half = width / 2
        let n = depth(of: profile, length: length, width: width)
        switch profile {
        case .gangway:
            return [(x: 0, y: -half), (x: 0, y: half)]
        case let .square(chamfer):
            // A real coach end is a flat wall with a radius on each corner, and
            // for years this drew the radius as one straight bevel. At the zoom
            // somebody goes to in order to look at a platform, a two-hundred-
            // metre train is a row of octagons — which is what "the coaches are
            // just rectangles" was: not that they are boxes, but that the four
            // places they are not are each one hard corner.
            let c = min(chamfer, half * 0.7)
            let arc = max(1, steps)
            var corner: [(x: Double, y: Double)] = []
            corner.reserveCapacity(arc + 1)
            for i in 0...arc {
                let a = Double(i) / Double(arc) * .pi / 2
                corner.append((x: -c + c * sin(a), y: -half + c * (1 - cos(a))))
            }
            return corner + corner.reversed().map { (x: $0.x, y: -$0.y) }
        case .cab:
            return taper(depth: n, half: half, tip: 0.34, power: 0.78, steps: steps)
        case .streamlined:
            return taper(depth: n, half: half, tip: 0.15, power: 0.58, steps: max(4, steps * 2))
        case .locomotive:
            return taper(depth: n, half: half, tip: 0.50, power: 0.85, steps: steps)
        case .wedge:
            // Wide at the tip because it is: the plan of a double-deck unit's
            // nose is nearly a coach end. What makes it a wedge happens in
            // elevation, not here — the roof steps down a storey over six
            // metres, and *that* is what a KISS's front is.
            //
            // Written first at 0.44, which is the opposite of what the sentence
            // above says: a body drawn to under half its width over four and a
            // half metres is a cone, and a MUTZ standing in a station came out
            // pointed like something built for 250 km/h. The real front is a
            // flat screen nearly the full width of the vehicle with the corners
            // pulled in, so the tip is most of the body and the taper is a
            // shoulder rather than a point.
            return taper(depth: n, half: half, tip: 0.74, power: 0.52, steps: steps)
        case .bulb:
            // Full, and closing late. Below 0.6 the sides run at nearly the
            // body's width and then turn in hard at the very end, which is
            // exactly the one-piece moulding on the front of every Stadler
            // product in the country.
            return taper(depth: n, half: half, tip: 0.52, power: 0.52, steps: max(3, steps))
        case .slab:
            // The flattest end in the vocabulary, and it has to be: everything
            // that wears one — a rack railcar, a funicular car, the Stadler
            // sets on the Rigi — has a *wall* at the front with a windscreen in
            // it and the corners rounded off. Drawn at 0.80 over a third of the
            // body's width it still came out as a curve, because the width is
            // exaggerated on the map and the depth grew with it: at the zoom
            // the models appear at, a third of a drawn width is two metres of
            // taper on a vehicle whose real front is a single sheet of glass.
            // Shallower and blunter, and it reads as the wall it is.
            return taper(depth: n, half: half, tip: 0.88, power: 0.45, steps: max(2, steps))
        case .tramFront:
            return taper(depth: n, half: half, tip: 0.74, power: 0.55, steps: max(2, steps))
        case .busFront:
            return taper(depth: n, half: half, tip: 0.62, power: 0.66, steps: max(2, steps))
        case .busRear:
            return taper(depth: n, half: half, tip: 0.82, power: 0.55, steps: max(2, steps))
        case .bow:
            return taper(depth: n, half: half, tip: 0.09, power: 0.72, steps: max(4, steps * 2))
        }
    }

    /// A closed body outline in unit-local metres.
    ///
    /// The two ends carry all the shape; the sides are the straight lines
    /// between them, which fall out of the point order and never have to be
    /// written down. `x` runs from 0 at the back to `length` at the front.
    public static func outline(
        length: Double, width: Double, front: EndProfile, back: EndProfile,
        steps: Int = 3
    ) -> [(x: Double, y: Double)] {
        let head = end(front, length: length, width: width, steps: steps)
            .map { (x: length + $0.x, y: $0.y) }
        let tail = end(back, length: length, width: width, steps: steps)
            .map { (x: -$0.x, y: $0.y) }.reversed()
        return head + Array(tail)
    }

    /// How deep the painted cap on one end of a body is, in metres.
    ///
    /// The moulding around a windscreen and the hand of body behind it, which
    /// is what a company that paints its ends paints. Measured off the nose it
    /// is drawn on, so an upright rack front gets a shallow cap and a raked cab
    /// a deeper one — and floored, because a slab front is barely a metre deep
    /// in plan and the paint on the real vehicle carries on past it.
    static func capDepth(
        of profile: EndProfile, length: Double, width: Double
    ) -> Double {
        guard hasScreen(profile) else { return 0 }
        let nose = depth(of: profile, length: length, width: width)
        return min(max(nose, width * 0.55), length * 0.32)
    }

    /// One side of a body outline, cut off at a station along its length.
    ///
    /// Sutherland–Hodgman against a single vertical line, which is all that is
    /// needed here and is exact: every outline in this file is convex — two
    /// tapers with straight sides between them — so one pass either keeps a
    /// piece or returns nothing, and there is no case where a clip has to come
    /// back as two rings.
    static func clipped(
        _ ring: [(x: Double, y: Double)], at station: Double, keepingAhead: Bool
    ) -> [(x: Double, y: Double)] {
        guard ring.count >= 3 else { return [] }
        func inside(_ point: (x: Double, y: Double)) -> Bool {
            keepingAhead ? point.x >= station : point.x <= station
        }
        var out: [(x: Double, y: Double)] = []
        out.reserveCapacity(ring.count + 2)
        for (index, current) in ring.enumerated() {
            let previous = ring[(index + ring.count - 1) % ring.count]
            if inside(current) != inside(previous) {
                // The two are on opposite sides, so they cannot share an `x`
                // and the division is safe.
                let t = (station - previous.x) / (current.x - previous.x)
                out.append((x: station, y: previous.y + (current.y - previous.y) * t))
            }
            if inside(current) { out.append(current) }
        }
        return out.count >= 3 ? out : []
    }

    // MARK: - What is painted on it

    static func colour(of unit: VehicleUnit, in layout: VehicleLayout) -> String {
        // A coach the train is carrying but nobody may board reads as part of
        // the train and not as part of the service, which is exactly what the
        // grey says.
        if unit.closed { return layout.livery.roof }
        // The kind first, because it is the formation service's own word and it
        // is right about every locomotive the service files as one. The class
        // name second, for the vehicles it is silent about: a power car at the
        // end of a high-speed set is filed by what a passenger finds inside it,
        // which is a luggage compartment or nothing, and it is nonetheless the
        // vehicle that pulls and is painted like one. See `WagonCatalogue`.
        if unit.kind == .locomotive { return layout.livery.powered }
        if let type = unit.type, WagonCatalogue.traits(of: type).powered {
            return layout.livery.powered
        }
        return layout.livery.body
    }

    /// The roof band, the windscreens, the class stripes, and — where there is
    /// room for them — the doors and pantographs.
    static func trim(
        unit: VehicleUnit, ends: (front: EndProfile, back: EndProfile),
        width: Double, frame: Frame, livery: Livery, detail: Detail
    ) -> [FootprintPart] {
        // How much the body has been fattened past its true width, so anything
        // measured in real metres — a door, a tyre, the depth of a class band —
        // keeps its proportion to the body it is drawn on.
        let scale = width / max(0.5, unit.width)
        var out: [FootprintPart] = []
        let length = unit.length
        let half = width / 2
        let frontDepth = depth(of: ends.front, length: length, width: width)
        let backDepth = depth(of: ends.back, length: length, width: width)

        // The roof. Inset from both sides so the body colour survives along the
        // edges, and held back from the noses so a windscreen is not roofed
        // over. A double-decker's roof is the full width of the vehicle and
        // reaches nearly to the ends, which is most of how one is recognised.
        // How much body colour is left showing on each side of the roof.
        //
        // Set generously, because the roof is the least informative thing on
        // the drawing and it was drawn widest. A real roof is grey whoever owns
        // the train, so a band covering five-sixths of the body turned every
        // company's stock into the same grey stripe and threw away the one
        // thing the colours were there to say. A double-decker still gets a
        // wider one — its roof really does run out to the gutters, and that is
        // part of how one is recognised from above.
        // A bus keeps more of its colour than anything else does, and for the
        // opposite reason to the rule above: its roof is *white*, so a band as
        // wide as a train's turned a PostAuto into a white vehicle with a
        // yellow rim — which threw away the single most recognisable livery in
        // the country to say something the tyres had already said.
        let inset = unit.doubleDeck ? half * 0.30 : (unit.kind == .bus ? half * 0.60 : half * 0.42)
        let roofFrom = backDepth + (unit.doubleDeck ? 0.3 : 0.5)
        let roofTo = length - frontDepth - (unit.doubleDeck ? 0.3 : 0.5)
        if roofTo > roofFrom {
            // The restaurant car gets the roof rather than a stripe, because
            // the roof is the largest thing on the drawing and finding the
            // restaurant on a sixteen-coach train is exactly the sort of
            // question a top view should answer in one glance. An edge band
            // alone is a few points on a body a hundred points long, and on a
            // train whose operator is unknown it is drawn in a colour the
            // livery is already using.
            out.append(FootprintPart(
                role: .roof,
                ring: frame.project(
                    rectangle(x0: roofFrom, x1: roofTo, y0: -half + inset, y1: half - inset)
                ),
                fill: unit.band == .dining ? diningRoofColour : roofColour(of: unit, livery: livery)
            ))
        }

        // The ends, where the company paints them differently from the sides.
        //
        // Filed as a marking rather than as a body, and that is not a label
        // quibble: the app counts `.body` parts to know how many wagons a
        // footprint has and matches them to the placements one for one — see
        // `VehicleModels` — so a second body-coloured polygon on the same
        // wagon would put every lift and every opacity after it on the wrong
        // vehicle. It is paint on a body that has already been drawn.
        if livery.ends != livery.body {
            let body = outline(
                length: length, width: width, front: ends.front, back: ends.back
            )
            for front in [true, false] {
                let end = front ? ends.front : ends.back
                let cap = capDepth(of: end, length: length, width: width)
                guard cap > 0, length > cap * 2.4 else { continue }
                let ring = clipped(
                    body, at: front ? length - cap : cap, keepingAhead: front
                )
                guard ring.count >= 3 else { continue }
                out.append(FootprintPart(
                    role: .stripe, ring: frame.project(ring), fill: livery.ends
                ))
            }
        }

        // The windscreen, on whichever ends have one.
        //
        // Held to about a body's width whatever the nose is, because a screen
        // is a screen. Drawn as a fraction of the taper it sits in, a
        // streamlined nose seven metres deep came out with five metres of glass
        // in it — a black arrowhead where the front of the train should be, and
        // the one place on an ICE the shape had just been fixed.
        let screenReach = max(1.0, min(width * 0.95, 2.8))
        if hasScreen(ends.front) {
            out.append(screen(
                at: length, into: -1, depth: min(frontDepth, screenReach),
                half: half, frame: frame, livery: livery
            ))
        }
        if hasScreen(ends.back) {
            out.append(screen(
                at: 0, into: 1, depth: min(backDepth, screenReach),
                half: half, frame: frame, livery: livery
            ))
        }

        // The class band. On a real coach it runs along the top of the side,
        // which from directly above is the very edge of the body — so it is
        // drawn on both edges, and it is the one marking on this whole drawing
        // that answers a question somebody standing on a platform is actually
        // asking.
        // Held clear of both ends, and that is not tidiness: a stripe is a
        // straight rectangle at a fixed distance from the centreline, and the
        // body is not straight where it tapers — so one run to the full length
        // of a driving car sticks out through the side of its own nose.
        let straightFrom = backDepth + 0.4
        let straightTo = length - frontDepth - 0.4
        if let band = stripeColour(unit.band, livery: livery), straightTo > straightFrom,
           let span = stripeSpan(unit.stripe, length: length, from: straightFrom, to: straightTo) {
            let from = span.from
            let to = span.to
            if to > from {
                // Inside the body edge rather than on it, and that is not a
                // detail. The band was drawn a fixed 0.3 m thick, which at the
                // width the roof leaves is exactly the strip of body colour
                // showing along the side — so a first-class coach lost its
                // operator's colour completely and came out yellow-rimmed
                // among red-rimmed ones, which reads as a fault rather than as
                // a class. Proportions rather than metres, so the band survives
                // being drawn on a body that has been widened to stay visible.
                for side in [-1.0, 1.0] {
                    out.append(FootprintPart(role: .stripe, ring: frame.project(rectangle(
                        x0: from, x1: to,
                        y0: side * half * 0.66, y1: side * half * 0.93
                    )), fill: band))
                }
            }
        }

        // The articulation, drawn rather than left to be inferred.
        //
        // This is the other half of the tram-and-bus problem, and the half that
        // does the work at the zooms where the tyres are still too small to
        // read. A bellows is continuous body — no gap, no corner — so an
        // articulated vehicle came out as one smooth worm however many times it
        // bent, and the only difference between a five-module Combino and a
        // two-section artic was length. Put the joints on the drawing and the
        // count is the answer: a tram is segmented four or six times over, a
        // bus once or twice, and neither can be mistaken for the other at a
        // glance.
        //
        // Drawn at the *front* joint only. Every joint is the front of one unit
        // and the back of the next, so drawing both ends drew each one twice —
        // and a black band at double strength on a body that is fading in is a
        // dark bar arriving before the vehicle it belongs to.
        if ends.front == .gangway {
            // Floored as well as capped. Proportional alone, a tram module six
            // metres long got a band a metre wide — under two points at the
            // zoom a city is read at, which is to say invisible exactly where
            // the count is doing the work.
            let reach = min(0.75, max(0.42, length * 0.06))
            out.append(FootprintPart(role: .joint, ring: frame.project(rectangle(
                x0: length - reach, x1: length + reach,
                y0: -half * 0.97, y1: half * 0.97
            )), fill: bellowsColour))
        }

        // Wheels, on anything that runs on a road.
        //
        // This is the whole answer to a tram and an articulated bus looking
        // alike. They are the same width, they bend in the same places and in
        // half the country they are painted by the same municipal operator, so
        // length and colour do not separate them — a Bernmobil Combino and a
        // Bernmobil artic were one drawing at two lengths. Tyres do: they are
        // the one thing on a road vehicle that is visible from directly above
        // and has no counterpart on a rail vehicle, whose wheels are under the
        // body and between the rails.
        //
        // Drawn from `.trim` rather than from `.full`, and that was the bug in
        // the answer. A 12 m bus only passes the door-and-pantograph threshold
        // at about zoom 17 — so through the whole band of zooms where a city is
        // legible and its buses and trams are drawn side by side, the one thing
        // separating them was not being drawn at all.
        if unit.kind == .bus {
            // Bigger than life, deliberately. A real tyre stands about ten
            // centimetres proud of a bus body — which on a map is nothing at
            // all, and drawn to scale the wheels were invisible and the bus
            // went on looking like a tram. Proportions of the body rather than
            // metres, so they stay the same fraction of whatever width the
            // vehicle ends up drawn at.
            let along = min(1.9, length * 0.15)
            for x in [length * 0.17, length * 0.79] {
                for side in [-1.0, 1.0] {
                    out.append(FootprintPart(role: .wheel, ring: frame.project(rectangle(
                        x0: x - along / 2, x1: x + along / 2,
                        y0: side * half * 0.70, y1: side * half * 1.13
                    )), fill: wheelColour))
                }
            }
        }

        guard detail == .full else { return out }

        // Doors, as ticks on the body edge. Evenly spaced rather than placed:
        // where the doors of a given class actually sit is not in any feed this
        // app reads, and evenly spaced is right for a low-floor unit and close
        // enough for everything else.
        if unit.doors > 0, straightTo > straightFrom {
            // Spread over the straight part of the body for the same reason the
            // stripe is: a door drawn on the windscreen is not a door.
            let span = straightTo - straightFrom
            let step = span / Double(unit.doors + 1)
            let widthOfDoor = min(1.4, step * 0.5)
            for k in 1...unit.doors {
                let x = straightFrom + step * Double(k)
                for side in [-1.0, 1.0] {
                    out.append(FootprintPart(role: .door, ring: frame.project(rectangle(
                        x0: x - widthOfDoor / 2, x1: x + widthOfDoor / 2,
                        y0: side * (half - 0.36 * scale), y1: side * half
                    )), fill: livery.trim))
                }
            }
        }

        // Pantographs. Nothing else on the drawing says which vehicle is the
        // one doing the work.
        if unit.pantographs > 0 {
            let positions: [Double] = unit.pantographs == 1
                ? [length * 0.5]
                : (0..<unit.pantographs).map { length * (Double($0) + 0.5) / Double(unit.pantographs) }
            for x in positions {
                out.append(FootprintPart(role: .pantograph, ring: frame.project(rectangle(
                    x0: x - 0.22, x1: x + 0.22, y0: -half * 0.66, y1: half * 0.66
                )), fill: pantographColour))
                out.append(FootprintPart(role: .pantograph, ring: frame.project(rectangle(
                    x0: x - min(1.4, length * 0.1), x1: x + min(1.4, length * 0.1),
                    y0: -half * 0.12, y1: half * 0.12
                )), fill: pantographColour))
            }
        }
        return out
    }

    /// Which run of the body the class band covers.
    ///
    /// `x` is measured from the back of the body, so the leading half — the one
    /// toward the front of the train — is the far end of the range.
    static func stripeSpan(
        _ stripe: Stripe, length: Double, from: Double, to: Double
    ) -> (from: Double, to: Double)? {
        switch stripe {
        case .none: return nil
        case .full: return (from, to)
        case .leadingHalf:
            let start = max(from, length * 0.5)
            return start < to ? (start, to) : nil
        case .trailingHalf:
            let end = min(to, length * 0.5)
            return from < end ? (from, end) : nil
        }
    }

    /// Whether this end of the body is one somebody drives from.
    ///
    /// A bus's back is not, and that is the point of it having its own profile:
    /// two windscreens on an articulated bus made it a double-ended vehicle,
    /// which is a tram.
    static func hasScreen(_ profile: EndProfile) -> Bool {
        switch profile {
        case .cab, .streamlined, .locomotive, .tramFront, .busFront: return true
        // All three of the new ends are driving ends and nothing else is
        // shaped like them: a wedge is the front of a double-deck unit, a bulb
        // is a moulded railcar front, a slab is the upright face of something
        // built to climb. None of them is ever drawn on a trailing end.
        case .wedge, .bulb, .slab: return true
        case .busRear, .square, .gangway, .bow: return false
        }
    }

    static let pantographColour = "#2f343a"
    static let wheelColour = "#15181b"
    /// The rubber concertina between two modules. Black, because it is.
    static let bellowsColour = "#23272c"
    /// A bus roof. Every bus in the country has a white one, and every tram
    /// roof is dark grey under a load of equipment — which makes the roof, of
    /// all things, one of the plainest ways a top view can tell the two apart.
    static let busRoofColour = "#dde3e9"
    /// A tram roof: the resistors, the air conditioning and the pantograph
    /// well, which from above is much darker than a railway coach's.
    static let tramRoofColour = "#565c64"

    /// What this body's roof is painted, where it is not simply the operator's.
    static func roofColour(of unit: VehicleUnit, livery: Livery) -> String {
        if unit.kind == .bus { return busRoofColour }
        if unit.kind == .module || unit.nose == .blunt { return tramRoofColour }
        return livery.roof
    }
    /// The restaurant car. Its own colour rather than the operator's trim: on a
    /// train drawn in a livery this module does not know, the trim is the same
    /// white every second-class door is drawn in, so the one coach a reader is
    /// hunting for was marked in the commonest colour on the train.
    static let diningColour = "#e08a2e"
    static let diningRoofColour = "#6b4a25"
    /// The yellow band Swiss first class has carried since long before anybody
    /// drew it on a phone.
    static let firstClassColour = "#f2c31a"

    static func stripeColour(_ band: ClassBand, livery: Livery) -> String? {
        switch band {
        case .none, .second: return nil
        case .first, .mixed: return firstClassColour
        case .dining: return diningColour
        }
    }

    private static func screen(
        at x: Double, into direction: Double, depth: Double, half: Double,
        frame: Frame, livery: Livery
    ) -> FootprintPart {
        // A trapezoid narrowing towards the tip, which is what a raked screen
        // in a tapering nose projects to.
        let near = x + direction * depth * 0.85
        let far = x + direction * depth * 0.14
        return FootprintPart(role: .glass, ring: frame.project([
            (x: near, y: -half * 0.66), (x: far, y: -half * 0.30),
            (x: far, y: half * 0.30), (x: near, y: half * 0.66),
        ]), fill: livery.glass)
    }

    static func rectangle(
        x0: Double, x1: Double, y0: Double, y1: Double
    ) -> [(x: Double, y: Double)] {
        [(x: x0, y: y0), (x: x1, y: y0), (x: x1, y: y1), (x: x0, y: y1)]
    }
}
