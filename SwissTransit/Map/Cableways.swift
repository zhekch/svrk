import Foundation
import MapboxMaps
import TransitCore

// The things a gondola hangs from: the station at each end, the rope between
// them, and the towers carrying it over the ground in between.
//
// **Why this is not part of the vehicle.** Everything else the map draws in
// three dimensions is a vehicle, and a vehicle is a rigid body that is
// somewhere else a second later. A cableway is the opposite of that in every
// respect: it does not move, it belongs to the line rather than to any cabin on
// it, and it is there when nothing is running. So it is built where it belongs —
// from `Cableway.plan`, out of the journeys' own alignments — and written to a
// source of its own that is only rewritten when the set of lines on screen
// actually changes, which is once a pan rather than thirty times a second.
//
// **Two kinds of thing, and they are drawn by two different mechanisms because
// they are two different kinds of thing.** A station and a tower are structures:
// they have volume, they stand on the ground, and their size is a fact about
// them measured in metres. Those are extrusions, on `flat` terrain alignment —
// one elevation for the whole prism, exactly as a wagon is, so a shed on a
// hillside has walls cut nowhere and the same shape it would have with the
// relief switched off.
//
// A rope is not a structure and drawing it as one was the first attempt. A haul
// rope is five centimetres across. Extruded honestly it is invisible; extruded
// at a size that can be seen it is a girder, and it is a girder that has to be
// widened again every time somebody zooms out. What a rope actually is, on a
// map, is a *line* — a mark of constant weight on the screen whatever the scale
// — and the renderer has a way to say exactly that: `line-elevation-reference:
// ground` with a `line-z-offset` carries a line at a fixed height over whatever
// ground is under it, at a width measured in points. So the rope is a line, one
// pixel or two of it, at every zoom this draws at.
//
// **The height that line is carried at is the whole feature.** A real haul rope
// is not level over the ground: it spans from tower to tower, sags between them,
// and over a gorge it is two hundred metres up. What it *is* over the length of
// an ordinary line is a profile following the mountain a fixed clearance above
// it — which is what the towers are for, and what a reader looking at a hillside
// sees. Drawn at a constant height over the ground the rope reads correctly
// along nearly every line in the country, and it has the one property no chord
// could offer: the cabins hanging from it are at that height too, because
// `Silhouette.hover` is derived from the same number. A rope and a cabin drawn
// by two different rules would meet nowhere.
enum Cableways {
    static let source = "transit-cableway"
    /// The stations and the towers: rigid, one elevation each.
    static let structures = "transit-cableway-structures"
    /// The rope: draped, and drawn after the structures so a span meeting a
    /// station is not painted over by the shed it runs into.
    static let ropes = "transit-cableway-ropes"

    /// Which of the two layers a feature belongs to, and what colour it is.
    private enum Key {
        static let kind = "k"
        static let rope = "r"
        static let structure = "s"
        static let colour = "c"
        static let base = "b"
        static let height = "h"
    }

    // MARK: - Paint
    //
    // Concrete, and it is the one thing the reader is told about the material.
    // A cableway station is a poured box with a bullwheel in it and nothing on
    // this map should mistake it for a building with people living in it, so it
    // is deliberately colourless — the operator's paint is on the cabins, where
    // it belongs and where it is the thing being looked for.

    private struct Palette {
        var wall: String
        var roof: String
        var tower: String
        var rope: String
    }

    private static func palette(dark: Bool) -> Palette {
        dark
            ? Palette(wall: "#5b5852", roof: "#403e3a", tower: "#6b675f", rope: "#9b9a97")
            // Light and dark are not the same colour at two brightnesses, and
            // the rope is why. Against a pale basemap a rope has to be dark to
            // be a line at all; against a night one the same dark grey is
            // invisible, and what reads is a pale wire lit by the moon. The
            // concrete goes the ordinary way round.
            : Palette(wall: "#bdb8ae", roof: "#8d8880", tower: "#a8a49c", rope: "#4a4a4d")
    }

    // MARK: - Heights, in the metres the ground is measured in

    /// Where a tower's mast stops and its crosshead begins.
    ///
    /// The underside of the rope, which is the underside of a cabin's grip: a
    /// sheave assembly hangs *below* the crosshead and the rope runs over it, so
    /// a mast drawn all the way up to rope height would be a post with the rope
    /// buried in its top.
    private static var sheaves: Double {
        (Cableway.ropeHeight - Cableway.gripDepth) * VehicleShape.modelExaggeration
    }

    /// The top of a station building: over the running line, as a shed is.
    private static var stationTop: Double {
        Cableway.drawnRopeHeight + Cableway.stationRoof
    }

    // MARK: - Installing

    /// Add the source and the two layers, over whatever is already in the
    /// style.
    ///
    /// Idempotent, because `onStyleLoaded` fires more than once for the same
    /// style and adding a source that exists throws — which, uncaught, is a
    /// blank map.
    static func install(_ style: MapboxMap) throws {
        if !style.sourceExists(withId: source) {
            var geojson = GeoJSONSource(id: source)
            geojson.data = .featureCollection(FeatureCollection(features: []))
            try style.addSource(geojson)
        }

        if !style.layerExists(withId: structures) {
            var solids = FillExtrusionLayer(id: structures, source: source)
            solids.filter = Exp(.eq) { Exp(.get) { Key.kind }; Key.structure }
            try style.addLayer(shaded(solids))
            // A station is a box and a tower is a mast. Neither bends to the
            // hill it stands on, and the default alignment — base draped over
            // the terrain, top left flat — is what tore the wagons apart before
            // they were told the same thing. See `VehicleModels.setFlatOnTerrain`.
            VehicleModels.setFlatOnTerrain(style, layer: structures)
        }

        if !style.layerExists(withId: ropes) {
            var rope = LineLayer(id: ropes, source: source)
            rope.filter = Exp(.eq) { Exp(.get) { Key.kind }; Key.rope }
            rope.lineColor = .expression(Exp(.get) { Key.colour })
            // Over the ground under it rather than over sea level, which is the
            // only one of the two a line strung along a mountain can use: the
            // rope climbs eight hundred metres between its two stations, and an
            // offset from sea level would put the top half of it underground and
            // the bottom half in the sky.
            rope.lineElevationReference = .constant(.ground)
            rope.lineZOffset = .constant(Cableway.drawnRopeHeight)
            // In points, and that is the reason this is a line at all. A rope
            // is a mark of constant weight whatever the scale — heavy enough to
            // follow across a valley at zoom 13, and never thickening into a
            // girder at zoom 19.
            rope.lineWidth = .expression(
                Exp(.interpolate) {
                    Exp(.linear); Exp(.zoom)
                    13; 0.9
                    16; 1.6
                    19; 2.6
                }
            )
            rope.lineCap = .constant(.round)
            rope.lineJoin = .constant(.round)
            rope.minZoom = minZoom
            try style.addLayer(rope)
        }
    }

    /// How the structures are painted and lit. The rope is a line and shares
    /// none of it.
    private static func shaded(_ layer: FillExtrusionLayer) -> FillExtrusionLayer {
        var out = layer
        out.fillExtrusionColor = .expression(Exp(.get) { Key.colour })
        out.fillExtrusionBase = .expression(Exp(.get) { Key.base })
        out.fillExtrusionHeight = .expression(Exp(.get) { Key.height })
        out.fillExtrusionBaseTransition = .zero
        out.fillExtrusionHeightTransition = .zero
        out.fillExtrusionOpacityTransition = .zero
        // The same setting that makes a stack of prisms read as a vehicle: the
        // walls shade from the ground up, so a station reads as a box standing
        // on the hillside rather than as a grey rectangle laid over it.
        out.fillExtrusionVerticalGradient = .constant(true)
        out.fillExtrusionAmbientOcclusionIntensity = .constant(0)
        out.fillExtrusionCastShadows = .constant(false)
        // Lit by the basemap's own sun, like the vehicles and unlike the flat
        // overlay: this is scenery, and scenery that emits its own colour at
        // night is a concrete shed glowing on a dark mountain.
        out.fillExtrusionEmissiveStrength = .constant(0.10)
        out.minZoom = minZoom
        return out
    }

    /// Below this a cableway is a smudge.
    ///
    /// The same floor the drawn vehicles use. A gondola span is a kilometre or
    /// two and its station is twenty metres long: at the zoom where an
    /// intercity is still a dot, a station is a tenth of a pixel and the rope is
    /// a line drawn beside the line the route overlay already draws.
    static let minZoom = VehicleShape.minZoom

    // MARK: - Building the features

    /// How finely a rope is sampled along its own span, in metres.
    ///
    /// An elevated line is lifted *at its vertices*, so this is the whole of how
    /// closely the rope follows the ground. A span is usually two points a
    /// kilometre or two apart — the chord an aerial leg falls through to — and
    /// left at two points the renderer has only the two ends to raise: the rope
    /// would leave the valley station at the right height, arrive at the top one
    /// at the right height, and pass through eight hundred metres of mountain in
    /// between. Twenty-five metres is finer than the elevation tiles themselves
    /// at any zoom this draws at, so what limits the shape is the terrain's own
    /// resolution rather than this.
    private static let ropeStep = 25.0

    /// Everything the plan implies, as features.
    static func features(_ plan: Cableway.Plan, dark: Bool) -> [Feature] {
        let paint = palette(dark: dark)
        var out: [Feature] = []
        out.reserveCapacity(plan.spans.count * 2 + plan.stations.count * 4)

        for span in plan.spans {
            let walked = resampled(span.points, every: ropeStep)
            if walked.count >= 2 {
                var rope = Feature(geometry: .lineString(LineString(
                    walked.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                )))
                rope.properties = [
                    Key.kind: .string(Key.rope),
                    Key.colour: .string(paint.rope),
                ]
                out.append(rope)
            }
            for tower in Cableway.towers(along: span.points) {
                // The mast, from the ground to the sheaves under the rope.
                out.append(prism(
                    box(
                        at: tower.at, bearing: tower.bearing,
                        length: Cableway.towerWidth, width: Cableway.towerWidth
                    ),
                    kind: Key.structure, colour: paint.tower,
                    base: 0, height: sheaves
                ))
                // And the crosshead the sheaves hang from, which is what turns a
                // post into a pylon: it lies *across* the line, so the one thing
                // a reader can tell about a tower from above is which way the
                // rope runs over it.
                out.append(prism(
                    box(
                        at: tower.at, bearing: tower.bearing,
                        length: Cableway.towerHeadDepth, width: Cableway.towerHead
                    ),
                    kind: Key.structure, colour: paint.tower,
                    base: sheaves, height: Cableway.drawnRopeHeight
                ))
            }
        }

        for station in plan.stations {
            // The plinth: a solid concrete block from the ground up to the deck
            // the cabins arrive at, which is the height they fly at. This is the
            // part a reader sees from the valley floor, and the only part of a
            // real station that is a block at all.
            out.append(prism(
                box(
                    at: station.at, bearing: station.bearing,
                    length: Cableway.stationLength, width: Cableway.stationWidth
                ),
                kind: Key.structure, colour: paint.wall,
                base: 0, height: Cableway.drawnDeckHeight
            ))
            // The two piers at the ends of it, carrying the roof over a middle
            // that is left open. Everything between them is where the cabin
            // stands, and leaving it empty is the whole point — see
            // `Cableway.stationPier`.
            let pier = Cableway.stationLength * Cableway.stationPier
            for end in [-1.0, 1.0] {
                out.append(prism(
                    box(
                        at: Geo.moved(
                            station.at, bearing: station.bearing,
                            metres: end * (Cableway.stationLength - pier) / 2
                        ),
                        bearing: station.bearing,
                        length: pier, width: Cableway.stationWidth
                    ),
                    kind: Key.structure, colour: paint.wall,
                    base: Cableway.drawnDeckHeight, height: Cableway.drawnRopeHeight
                ))
            }
            // And the roof over the running line, standing out past the piers on
            // an eaves. A station whose top is level with its rope is a box the
            // cabins land on; this slab is the whole of what says the rope goes
            // *through*.
            out.append(prism(
                box(
                    at: station.at, bearing: station.bearing,
                    length: Cableway.stationLength + 1.8,
                    width: Cableway.stationWidth + 1.8
                ),
                kind: Key.structure, colour: paint.roof,
                base: Cableway.drawnRopeHeight, height: stationTop
            ))
        }
        return out
    }

    // MARK: - Turning metres into a polygon

    /// One extruded piece.
    private static func prism(
        _ ring: [CLLocationCoordinate2D], kind: String, colour: String,
        base: Double, height: Double
    ) -> Feature {
        var closed = ring
        if let first = ring.first { closed.append(first) }
        var feature = Feature(geometry: .polygon(Polygon([closed])))
        feature.properties = [
            Key.kind: .string(kind),
            Key.colour: .string(colour),
            Key.base: .number(base),
            Key.height: .number(height),
        ]
        return feature
    }

    /// A rectangle of `length` along `bearing` and `width` across it, centred
    /// on `at`.
    private static func box(
        at: Coord, bearing: Double, length: Double, width: Double
    ) -> [CLLocationCoordinate2D] {
        let half = length / 2
        let side = width / 2
        return [(half, side), (half, -side), (-half, -side), (-half, side)].map {
            let along = Geo.moved(at, bearing: bearing, metres: $0.0)
            let corner = Geo.moved(along, bearing: bearing + 90, metres: $0.1)
            return CLLocationCoordinate2D(latitude: corner.lat, longitude: corner.lon)
        }
    }

    /// The same line with a vertex at least every `every` metres.
    private static func resampled(_ points: [Coord], every step: Double) -> [Coord] {
        guard points.count >= 2, step > 0 else { return points }
        var out: [Coord] = [points[0]]
        for i in 1..<points.count {
            let from = points[i - 1]
            let to = points[i]
            let length = Geo.metres(from, to)
            let pieces = max(1, Int((length / step).rounded(.up)))
            if pieces > 1 {
                for k in 1..<pieces {
                    out.append(Geo.interpolate(from, to, Double(k) / Double(pieces)))
                }
            }
            out.append(to)
        }
        return out
    }
}
