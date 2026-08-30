import Foundation
import MapboxMaps
import TransitCore
import UIKit

// The layers that draw a vehicle as a vehicle, and the features that fill them.
//
// A dot says where something is. It cannot say that the thing at Bern is a
// four-hundred-metre intercity with a locomotive on the back and the one beside
// it is a three-car regional unit, and at the zoom somebody has gone to in
// order to look at a platform that is the difference they went in to see. So
// past a certain size each vehicle is drawn as its own footprint: real bodies,
// at their real length, laid along the track the train is actually on.
//
// The change is per vehicle rather than per zoom — see `VehicleShape.emergeAt`
// — so an intercity has become a train while a minibus is still a dot, which is
// exactly right: they are recognisable at very different scales. The dot does
// not simply cut out underneath it. It shrinks and fades as its vehicle grows
// in, so the handover reads as one marker changing rather than as two markers
// swapping.
//
// **Colour carries the alpha.** Mapbox will take `rgba(…)` anywhere it takes a
// colour, and the fade is baked into the string rather than driven through
// `fill-opacity`. That is not a shortcut: a fill layer blends its own
// overlapping features, so a roof at half opacity over a body at half opacity
// comes out darker than either and the whole train discolours halfway through
// the transition. Alpha in the colour has the same problem in principle, which
// is why nothing but bodies is emitted until the fade is over — and bodies do
// not overlap.
enum VehicleShapes {
    static let source = "transit-vehicle-shapes"
    static let casing = "transit-vehicle-shapes-casing"
    static let fill = "transit-vehicle-shapes-fill"
    static let ghost = "transit-vehicle-shapes-ghost"
    /// The silhouette that shows only where a building is in front of the
    /// vehicle. See `installXray`.
    static let xray = "transit-vehicle-shapes-xray"
    static let outline = "transit-vehicle-shapes-outline"

    /// The vehicle the camera is following, drawn on its own.
    ///
    /// Not a cosmetic split. Everything else on the map is rebuilt on the model
    /// tick, which is thirty a second and costs a viewport query and every
    /// vehicle in it; the followed vehicle has to keep up with the *display*,
    /// because the camera is locked to it and so the whole map moves at its
    /// rate. Giving it a source of its own is what lets it be redrawn per
    /// refresh — half a dozen polygons — without touching the several hundred
    /// belonging to everything else. See `MapCoordinator.followFrame`.
    static let followSource = "transit-vehicle-shapes-followed"
    static let followCasing = "transit-vehicle-shapes-followed-casing"
    static let followFill = "transit-vehicle-shapes-followed-fill"
    static let followGhost = "transit-vehicle-shapes-followed-ghost"
    static let followXray = "transit-vehicle-shapes-followed-xray"
    static let followOutline = "transit-vehicle-shapes-followed-outline"

    /// Which of the three drawings a feature belongs to.
    ///
    /// One source now holds all of them — the flat footprint, the solid it
    /// stands up into, and the lamps on its ends — and each layer filters for
    /// its own. That is not tidiness, it is the only way to keep them in step.
    /// `updateGeoJSONSource` hands its work to one serial parsing queue inside
    /// the SDK and lands on whatever frame it lands on, so three sources
    /// written in a row for the same vehicle arrive on up to three different
    /// frames — and at line speed a frame is most of a metre. What that looked
    /// like was head lamps trailing the nose that was supposed to be carrying
    /// them, worst in plain 2D where there is nothing else to look at.
    ///
    /// Written once, the whole vehicle is one parse and one frame. It cannot
    /// come apart, because there is no longer anything to come apart *from*.
    enum Kind {
        static let key = "k"
        /// The flat footprint: bodies, roof bands, doors, class stripes.
        static let flat = "f"
        /// A slab of the solid. See `VehicleModels`.
        static let solid = "s"
        /// A head or tail lamp. See `VehicleLamps`.
        static let lamp = "l"
        /// A placed wagon: one point carrying the name of a baked mesh, a
        /// heading and a tilt. See `VehicleModels`.
        static let model = "m"
        /// A debug hitbox: the wagon's outline, its nose, and a label.
        static let hitbox = "h"
    }

    /// Feature properties, short because there is one set per polygon and there
    /// are thousands of polygons a second.
    private enum Key {
        static let colour = "c"
        static let stroke = "s"
        static let body = "b"
        static let selected = "sel"
        static let above = "up"
        static let shade = "sh"
        /// Width of the street-level casing in screen points. This must follow
        /// the body width: a fixed casing turns a small bus into a black blob.
        static let casing = "cw"
        /// Whether this vehicle is also being drawn as a solid right now.
        ///
        /// The flat drawing of a vehicle that is standing up as a model is
        /// still *built* — the silhouette a building takes out of it is traced
        /// from these same polygons, and that is the only thing on a tilted map
        /// that says where a train behind a block of flats is. What it is not
        /// is *painted*: a plan of the train lying on the ground around the
        /// base of the train is two trains. So the layers that paint it on the
        /// ground ask for this, and the x-ray line does not. See
        /// `MapCoordinator.vehicleDrawing`, which decides it per vehicle rather
        /// than for the map: a vehicle still fading in has no model yet, and
        /// its flat drawing is all there is of it.
        static let stood = "st"
        /// Metres above the ground this body's outline sits, for the x-ray
        /// line. Zero on the surface. See `install`.
        static let lift = "z"
        /// How much of this drawing is left, 1 in the open, 0 in a tunnel.
        static let opacity = "op"
    }

    /// Install the two layers, on top of whatever has been installed so far.
    ///
    /// Ordering is by call site rather than by name: the caller adds these
    /// after the vehicle dots they replace and before the line labels, which
    /// have to stay legible over anything drawn under them.
    static func install(_ style: MapboxMap) throws {
        // A second `onStyleLoaded` for the same style must not try to add
        // these again — that throw used to look like the shapes were missing
        // when they were already on the map.
        if style.sourceExists(withId: source) { return }
        try install(style, source: Self.source, casing: Self.casing,
                    fill: Self.fill, ghost: Self.ghost, outline: Self.outline,
                    xray: Self.xray)
        // Above the rest, and drawn last: the followed vehicle is the one being
        // looked at, and it is the only one whose position is a prediction —
        // so if it ever overlaps a neighbour, it is the one that should be on
        // top rather than half under.
        try install(style, source: Self.followSource, casing: Self.followCasing,
                    fill: Self.followFill, ghost: Self.followGhost,
                    outline: Self.followOutline, xray: Self.followXray)
    }

    private static func install(
        _ style: MapboxMap, source sourceId: String,
        casing: String, fill: String, ghost: String, outline: String,
        xray: String
    ) throws {
        var source = GeoJSONSource(id: sourceId)
        source.data = .featureCollection(FeatureCollection(features: []))
        // The shapes are rebuilt whole on every frame and none of them is ever
        // large enough to be worth simplifying. Both of those are the opposite
        // of what tiling a GeoJSON source is for.
        source.tolerance = 0
        if !style.sourceExists(withId: sourceId) {
            try style.addSource(source)
        }

        // Everything in this source that is a flat drawing rather than a slab
        // of a solid or a lamp.
        let flat = Exp(.eq) { Exp(.get) { Kind.key }; Kind.flat }
        // The same, and not standing up as a solid somewhere above it. Every
        // layer that paints the flat drawing *on the ground* asks for this
        // instead; the x-ray silhouette, which is only ever seen through a
        // building, asks for `flat`. See `Key.stood`.
        let lying = Exp(.all) { flat; Exp(.not) { Exp(.get) { Key.stood } } }

        // A shadow under whatever is at street level, so a bus crossing the
        // station throat reads as a bus on a bridge rather than as a bus in a
        // train. The map is flat; the country is not; and this is the only cue
        // available that costs nothing and is true nearly everywhere.
        var shadow = LineLayer(id: casing, source: sourceId)
        shadow.filter = Exp(.all) {
            lying
            Exp(.get) { Key.body }
            Exp(.get) { Key.above }
        }
        // Faded with the vehicle it belongs to: a solid black casing under a
        // body that is a third of the way in is a dark smear arriving before
        // the thing that casts it.
        shadow.lineColor = .expression(Exp(.get) { Key.shade })
        shadow.lineWidth = .expression(Exp(.get) { Key.casing })
        shadow.lineJoin = .constant(.round)
        shadow.lineCap = .constant(.round)
        try style.addLayer(shadow)

        // The same drawing twice, and the second one is what a building can
        // hide. See `ghostOpacity`: this copy sits on the ground behind the
        // buildings, the other is painted over them at half strength, and
        // between them a vehicle behind a block of flats is a vehicle you can
        // still see and still tell from one in the open.

        var bodies = FillLayer(id: fill, source: sourceId)
        // Everything in this source that is not a flat polygon — every slab of
        // every solid — would otherwise be filled here as well, flat on the
        // ground under the vehicle it belongs to.
        bodies.filter = lying
        bodies.fillColor = .expression(Exp(.get) { Key.colour })
        // On. Everything here is a small polygon at an arbitrary angle — a
        // coach on a curve is never axis-aligned — and an aliased edge on a
        // seven-point-wide body is a visible staircase.
        bodies.fillAntialias = .constant(true)
        try style.addLayer(bodies)

        // Through `fill-opacity`, which the note at the top of this file says
        // not to do — and here it is the right instrument rather than the wrong
        // one. The objection to it is that a layer blends its own overlapping
        // features, so a door drawn at half strength over a body drawn at half
        // strength comes out as neither colour. That is exactly what this copy
        // wants where it is the only thing on the screen, and where it is not,
        // the opaque copy underneath is already showing the right answer and
        // this one lands on top of it in its own colour: a body over a body is
        // the body, and the only pixels that shift are the door marks, by a
        // quarter of the difference between a door and the panel behind it,
        // which is about a pixel of a slightly paler red.
        var seen = FillLayer(id: ghost, source: sourceId)
        seen.filter = lying
        seen.fillColor = .expression(Exp(.get) { Key.colour })
        seen.fillOpacity = .constant(ghostOpacity)
        seen.fillAntialias = .constant(true)
        try style.addLayer(seen)

        var edges = LineLayer(id: outline, source: sourceId)
        edges.filter = Exp(.all) {
            lying
            Exp(.get) { Key.body }
        }
        // The colour is resolved per feature rather than chosen here, because it
        // has to carry the fade — a selection ring at full strength around a
        // body that is a third of the way in is a bright yellow outline drawn
        // around almost nothing.
        edges.lineColor = .expression(Exp(.get) { Key.stroke })
        edges.lineWidth = .expression(
            Exp(.switchCase) { Exp(.get) { Key.selected }; 2.2; 0.7 }
        )
        edges.lineJoin = .constant(.round)
        // The outline stays over the buildings with the ghost it belongs to,
        // and at the same strength. A line is the one flat thing on this map
        // that can be depth-tested on its own — the property is a per-pixel
        // test against the depth buffer, with none of the placement machinery
        // that made symbols unusable for the lamps — so it needs no second
        // copy the way the fill does. Named, because the spec's default is
        // nought: an outline left alone is one that disagrees with the ghost
        // it is drawn around.
        edges.lineOcclusionOpacity = .constant(ghostOpacity)
        try style.addLayer(edges)

        // And the silhouette that is drawn *only* where something is in front
        // of the vehicle.
        //
        // This is what a tilted map wants and what the ghost fill above cannot
        // give it. A fill is not depth-tested — see `Terrain3D.placeOverlay` —
        // so the ghost is drawn over the whole city whether or not there is
        // anything between the reader and the train, and once the solids are
        // standing that is a flat plan painted around the base of every one of
        // them. What is wanted is the opposite: nothing at all in the open,
        // where the solid is the drawing, and a translucent shape where a
        // building has swallowed it.
        //
        // A line can say that and nothing else can. `line-occlusion-opacity` is
        // a per-pixel test against the depth buffer, and it is *independent* of
        // `line-opacity` rather than a multiplier on it: at zero opacity and a
        // half occlusion opacity, the visible part of the line is not drawn and
        // the hidden part is. Traced round the body's own outline at about the
        // width of the body, so what comes through a wall is the shape of the
        // vehicle rather than a hairline round it.
        //
        // The model itself cannot be made to do this. `model-opacity` is one
        // number for a whole layer, there is no `model-occlusion-opacity` in
        // the style spec — only lines and symbols have one — and the SDK
        // exposes no shader of its own to hook. See `MapCoordinator.applySolidity`,
        // which trades this against the ghost as the solids come and go.
        var through = LineLayer(id: xray, source: sourceId)
        // `flat`, not `lying`: this is the one part of the flat drawing a
        // vehicle keeps once it is standing up as a solid, because it is the
        // only thing that can say "that train is behind this building".
        through.filter = Exp(.all) {
            flat
            Exp(.get) { Key.body }
            // Not through a mountain: a train in a tunnel is gone, and the
            // line number is what is left to follow. The x-ray is for
            // buildings in front of a train that is still in the open.
            Exp(.gt) { Exp(.get) { Key.opacity }; 0.5 }
        }
        through.lineColor = .expression(Exp(.get) { Key.colour })
        // Not drawn where it can be through. The whole of the trick.
        through.lineOpacity = .constant(0)
        through.lineOcclusionOpacity = .constant(xrayOpacity)
        // About the width of the body it is tracing, so the ring reads as the
        // vehicle rather than as an outline of one.
        through.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear); Exp(.zoom)
                15; 2.5; 17; 7.0; 19; 18.0
            }
        )
        through.lineJoin = .constant(.round)
        through.lineCap = .constant(.round)
        through.lineEmissiveStrength = .constant(1)
        // Off until the solids are up; the ghost fill is the right answer while
        // the map is still looking straight down.
        through.visibility = .constant(.none)
        try style.addLayer(through)
        // Lifted to the wagon, not draped on the mountain over it. A line on
        // the ground is *on* the terrain, so the terrain cannot occlude it and
        // `line-occlusion-opacity` has nothing to show through a hill. At the
        // bore the mountain is in front, the occluded part of the line is the
        // train, and that is the only way through terrain the style spec
        // offers — there is no `model-occlusion-opacity`. Set afterwards so a
        // refusal leaves the x-ray on the ground (through buildings still
        // works) rather than taking the layer down.
        do {
            try style.setLayerProperty(
                for: xray, property: "line-elevation-reference", value: "ground"
            )
            try style.setLayerProperty(
                for: xray, property: "line-z-offset", value: ["get", Key.lift]
            )
        } catch {
            Diagnostics.note("\(xray) stayed on the ground: \(error)")
        }
    }

    /// How much of a vehicle a building lets through.
    ///
    /// Half. The complaint the whole arrangement answers is that a flat drawing
    /// painted over the top of a city is a vehicle with no idea what is in
    /// front of it — a train on the far side of a block reads as a train on the
    /// roof. Hiding it outright is worse: the map is a live picture of where
    /// things are, and a train that vanishes behind every building is one you
    /// cannot follow across a town. Half is the reading that says both: it is
    /// there, and it is behind something.
    static let ghostOpacity = 0.5

    /// How much of a vehicle a building lets through once it is a solid.
    ///
    /// Lower than the flat map's half, because it is doing a different job. On
    /// a flat map the ghost *is* the vehicle and has to be read as one; here
    /// the vehicle is the solid standing next to it, and this is only the part
    /// a wall has taken away. Enough to follow a train across a town, not
    /// enough to be mistaken for a train in front of the building.
    static let xrayOpacity = 0.4

    /// Which of the two ways through an occluder is in use.
    ///
    /// The ghost fill while the map is flat, the occluded silhouette once the
    /// solids are up, and never both: the fill is drawn over everything and
    /// would paint a plan around the base of every standing train. See the note
    /// on the x-ray layer in `install`.
    static func setXray(_ style: MapboxMap, solids: Bool, occluders: Bool) {
        let ghostVisible = occluders && !solids
        for layer in [ghost, followGhost] where style.layerExists(withId: layer) {
            try? style.setLayerProperty(
                for: layer, property: "visibility", value: ghostVisible ? "visible" : "none"
            )
        }
        let xrayVisible = occluders && solids
        for layer in [xray, followXray] where style.layerExists(withId: layer) {
            try? style.setLayerProperty(
                for: layer, property: "visibility", value: xrayVisible ? "visible" : "none"
            )
        }
    }


    /// The same yellow the selected station and platform are ringed in.
    static let selectionColour = "#ffd60a"

    /// Every drawn vehicle, as features.
    ///
    /// Bodies first and detail after, because a fill layer draws its features
    /// in source order and the roof has to land on top of the body it belongs
    /// to. `VehicleShape` already returns them that way per vehicle; this keeps
    /// the two groups apart across vehicles as well, so one train's coach can
    /// never be painted over the roof of the train beside it.
    ///
    /// And within each group, the railway before the street. The dots are
    /// ordered the other way round on purpose — a train is the thing worth
    /// picking out of a city full of buses — but a *drawing* of a bus crossing
    /// a drawing of a train is a picture of a real place, and at that place the
    /// road is on top.
    /// `flatness` is how much of the flat drawing is left once the camera has
    /// begun tilting the vehicles up into solids: 1 on a map looking straight
    /// down, 0 once `VehicleModels` has taken over completely. It multiplies
    /// the same alpha the dot-to-vehicle change already rides on, which is not
    /// a coincidence — both are the same question ("how much of this drawing is
    /// the right drawing right now") and answering them through one channel is
    /// what keeps a vehicle that is both half-emerged and half-tilted from
    /// being painted twice at full strength.
    ///
    /// The selection ring is exempt. It answers "which one did I tap", and
    /// that question does not stop mattering because the map has been tilted —
    /// so the yellow outline stays on the ground under a vehicle that has
    /// otherwise handed over entirely, which is also the only thing left
    /// marking the spot once the solid has risen off its own footprint.
    static func features(
        _ footprints: [VehicleFootprint], excluding excluded: String? = nil,
        flatness: Double = 1, stood: Set<String> = [],
        lifts: [String: [Double]] = [:],
        opacities: [String: [Double]] = [:]
    ) -> [Feature] {
        var bodies: [Feature] = []
        var detail: [Feature] = []
        bodies.reserveCapacity(footprints.count * 6)

        // A partition rather than a sort. `sorted(by:)` is not stable, so two
        // vehicles at the same level could swap places from one frame to the
        // next — which where they overlap is a flicker, fifteen times a second.
        let solid = min(1, max(0, flatness))
        let drawn = excluded == nil ? footprints : footprints.filter { $0.id != excluded }
        let ordered = drawn.filter { !$0.aboveGround } + drawn.filter(\.aboveGround)
        for print in ordered {
            // A gondola is either its elevated solid or its point fallback.
            // Its rings are retained in `VehicleFootprint` to build and place
            // that solid, but a fill layer would paint them on the terrain as
            // a second cabin directly underneath the real one.
            guard !print.hanging else { continue }
            let standing = stood.contains(print.id)
            let fade = print.emergence * solid
            // The fill is painted over the inner half of this line, so this is
            // also the total amount the dark casing adds to the silhouette.
            // Scale it with the rendered body rather than with the real-world
            // vehicle: at the zoom where a single bus first becomes a shape it
            // can be under two points wide, and the former fixed 4.5-point line
            // buried it under more than twice its own width. The clamps retain
            // a crisp one-pixel edge on a Retina display and keep long trains
            // from regaining the oversized halo.
            let casingWidth = min(1.6, max(0.8, print.widthPoints * 0.4))
            let wagonLifts = lifts[print.id] ?? []
            let wagonOp = opacities[print.id] ?? []
            let vehicleOp = wagonOp.min() ?? 1
            var bodyIndex = 0
            for part in print.parts {
                guard part.ring.count >= 3 else { continue }
                // Nothing but the bodies once this vehicle is standing up.
                //
                // Every layer that paints the flat drawing on the ground —
                // the casing, the fill, the ghost, the outline — filters on
                // `lying`, which is `flat` *and not* `stood`; the one layer
                // that still asks for a standing vehicle is the x-ray, and it
                // asks for `Key.body` as well. So the roof band, the screens,
                // the class stripes, the wheels and the doors of a wagon that
                // has handed over to its mesh cannot be painted by anything.
                //
                // They were still being built into features, serialised,
                // parsed by the SDK, tiled, and filtered out again by five
                // layers apiece — and, with the relief on, re-draped onto the
                // terrain every frame, because `VehicleShapes.fill` sits in
                // the `middle` slot and a source that changes thirty times a
                // second invalidates the drape with it. See
                // `Terrain3D.groundLayers`. Eighteen invisible polygons per
                // wagon is most of the source, and on a tilted map it is most
                // of the work of drawing one.
                if standing, part.role != .body { continue }
                var ring = part.ring.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }
                // Turf wants a closed ring, and a polygon that does not close
                // is dropped without a word.
                if let first = ring.first { ring.append(first) }

                var feature = Feature(geometry: .polygon(Polygon([ring])))
                let isBody = part.role == .body
                let op = isBody && bodyIndex < wagonOp.count
                    ? wagonOp[bodyIndex] : vehicleOp
                // Sit in the body, not on the rails: two metres is about the
                // window band, so a line through a building reads as the train
                // rather than as a shadow under it.
                let lift = isBody && bodyIndex < wagonLifts.count
                    ? wagonLifts[bodyIndex] + 2 : 0
                if isBody { bodyIndex += 1 }
                let drawn = fade * op
                let edge = Palette.rgba(
                    print.ringed ? selectionColour : print.stroke,
                    alpha: (print.ringed ? print.emergence : fade) * op
                )
                feature.properties = [
                    Kind.key: .string(Kind.flat),
                    Key.colour: .string(Palette.rgba(part.fill, alpha: drawn)),
                    Key.body: .boolean(isBody),
                    Key.stroke: .string(edge),
                    Key.selected: .boolean(print.ringed),
                    Key.above: .boolean(print.aboveGround),
                    Key.shade: .string(shade(drawn)),
                    Key.casing: .number(casingWidth),
                    Key.lift: .number(lift),
                    Key.opacity: .number(op),
                    // Written on every one of them, never left off. A property
                    // that is absent reads as null rather than as false, and a
                    // filter asking `!null` is a filter that has stopped
                    // answering.
                    Key.stood: .boolean(standing),
                ]
                if isBody { bodies.append(feature) } else { detail.append(feature) }
            }
        }
        return bodies + detail
    }

    /// The casing under a vehicle at street level, faded with it.
    ///
    /// One fixed black at one fixed strength, so there is nothing here to parse.
    /// It used to go through `Palette.rgba` with the literal `rgba(0,0,0,0.55)`
    /// — which is the one shape of input that misses that function's fast path,
    /// so every polygon of every vehicle on every frame split a string, parsed
    /// four numbers out of it and formatted a fifth back in, to arrive at a
    /// value with exactly one degree of freedom.
    private static func shade(_ fade: Double) -> String {
        "rgba(0,0,0,\(Palette.alphaText(0.55 * fade)))"
    }
}

/// Colours in, colours out, with an alpha applied.
///
/// The layouts carry their liveries as CSS strings because `TransitCore` has no
/// business owning a `UIColor`. Here is where they meet a renderer, and the one
/// thing that has to happen on the way is the fade.
enum Palette {
    /// `#rrggbb`, `#rgb` and `rgba(r,g,b,a)` in; `rgba(r,g,b,a)` out.
    ///
    /// Anything unrecognised is passed through untouched rather than replaced
    /// with a default: a colour this cannot parse is still a colour Mapbox
    /// might understand, and swallowing it would paint a train in a fallback
    /// nobody chose for a reason nobody could see.
    static func rgba(_ colour: String, alpha: Double) -> String {
        let clamped = min(1, max(0, alpha))
        if clamped >= 0.999, !colour.hasPrefix("rgba") { return colour }
        guard let parts = components(of: colour) else { return colour }
        let combined = parts.a * clamped
        return "rgba(\(parts.r),\(parts.g),\(parts.b),\(alphaText(combined)))"
    }

    /// An alpha as Mapbox wants to read it, to three places.
    ///
    /// A table rather than `String(format:)`, and the reason is the rate. This
    /// is called once per polygon per frame — a long train is fifty of them,
    /// and a stationful of trains at thirty frames a second is tens of
    /// thousands of calls a second. `String(format:)` goes through `NSString`
    /// and a varargs parse for each one, which measurably showed up in the
    /// draw; a thousand-and-one entry table is built once, is a few tens of
    /// kilobytes, and turns the call into an index.
    static func alphaText(_ value: Double) -> String {
        alphas[Int((min(1, max(0, value)) * 1000).rounded())]
    }

    private static let alphas: [String] = (0...1000).map {
        switch $0 {
        case 0: return "0"
        case 1000: return "1"
        default:
            let text = String($0)
            return "0." + String(repeating: "0", count: 3 - text.count) + text
        }
    }

    static func components(of colour: String) -> (r: Int, g: Int, b: Int, a: Double)? {
        if colour.hasPrefix("#") {
            var digits = Array(colour.dropFirst())
            if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
            guard digits.count == 6, let value = Int(String(digits), radix: 16) else { return nil }
            return ((value >> 16) & 255, (value >> 8) & 255, value & 255, 1)
        }
        guard colour.hasPrefix("rgba(") || colour.hasPrefix("rgb(") else { return nil }
        let inside = colour.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
        let fields = inside.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard fields.count >= 3 else { return nil }
        return (Int(fields[0]), Int(fields[1]), Int(fields[2]), fields.count > 3 ? fields[3] : 1)
    }
}
