import Foundation
import MapboxMaps
import TransitCore
import UIKit

// The layers that stand a vehicle up, and the features that fill them.
//
// **There are two ways to do this and the app can do both.** A wagon is drawn
// as a *model* — a mesh baked once by `VehicleGLB`, registered with the style,
// and thereafter named by a point feature carrying a heading and a tilt. That
// is what the map uses, and it is the only one of the two that can be rotated
// into a gradient, put at an altitude of its own inside a mountain, or trusted
// not to come apart over a hillside.
//
// The older way is still here and still works: the same wagon as a stack of
// extruded prisms, one feature per slab. It is what draws if registering a
// model is ever refused — an experimental corner of the SDK, on a device
// somebody has a train to catch on — and going back to prisms is a much better
// failure than going back to nothing. See `MapCoordinator.applySolidity`, which
// fades whichever of the two is in use and leaves the other at zero.
//
// What follows is the prism half. The model half is below it.
//
// `VehicleShapes` draws a vehicle from above, which is the whole truth about it
// while the camera is looking straight down. Tilt the map and it stops being
// the truth: the buildings around the station have height, the ground under it
// has relief, and the one thing in the picture still lying flat on the floor is
// the train. So past a certain pitch — and only when the map is close enough
// for the difference to be more than a pixel — the same vehicle is drawn again
// as a solid, out of the slabs `VehicleMesh` slices for it.
//
// **One layer, not one per level.** `fill-extrusion-base` and
// `fill-extrusion-height` are both data-driven, so every slab of every vehicle
// — chassis, sides, window band, shoulder, roof, pantograph — is a feature in
// one source carrying its own two heights and its own colour. That matters at
// this rate: the alternative is eight layers whose sources all have to be
// rewritten in step fifteen times a second, and eight chances for them to be
// one frame out of step with each other, which on a moving train is eight
// pieces of it sliding apart.
//
// **Opacity is the layer's, not the feature's.** Unlike a fill, a fill
// extrusion ignores the alpha channel of its colour and takes its transparency
// from `fill-extrusion-opacity` alone — one number for everything the layer
// draws. That turns out to be exactly the right shape for what this is for:
// the fade is driven by the *camera*, which is one thing for the whole map, so
// there is nothing per-vehicle to say. See `MapCoordinator.applySolidity`.
enum VehicleModels {
    static let fill = "transit-vehicle-solids-fill"
    static let followFill = "transit-vehicle-solids-followed-fill"
    /// The baked wagons, which is what actually draws unless the models could
    /// not be registered. See `VehicleModelStore`.
    static let models = "transit-vehicle-models"
    static let followModels = "transit-vehicle-models-followed"
    /// Wagons that have finished fading into a tunnel. Always at opacity
    /// zero: the hard hide once a wagon is all the way in.
    static let buried = "transit-vehicle-models-tunnel"
    static let followBuried = "transit-vehicle-models-followed-tunnel"

    /// Tunnel fade, as stacked layers rather than as `model-opacity` on one.
    ///
    /// `model-opacity` is documented as not data-driven over GeoJSON, and a
    /// refused or ignored `["get", "op"]` left every wagon at full strength
    /// until the buried layer snapped it off. Each band here is a constant
    /// opacity — which the renderer will take — and a filter on the same `op`
    /// the features already carry, so a rake walking into a portal steps
    /// down coach by coach instead of vanishing.
    private struct FadeBand {
        var suffix: String
        var from: Double
        var to: Double
        var opacity: Double
    }

    private static let fadeBands: [FadeBand] = [
        FadeBand(suffix: "", from: 0.80, to: 1.01, opacity: 1),
        FadeBand(suffix: "-f70", from: 0.55, to: 0.80, opacity: 0.70),
        FadeBand(suffix: "-f40", from: 0.28, to: 0.55, opacity: 0.40),
        FadeBand(suffix: "-f12", from: 0.06, to: 0.28, opacity: 0.14),
    ]
    /// Debug outlines and labels, one per wagon. See `hitboxes`.
    static let hitboxes = "transit-vehicle-hitboxes"
    static let hitboxLabels = "transit-vehicle-hitbox-labels"
    static let followHitboxes = "transit-vehicle-hitboxes-followed"
    static let followHitboxLabels = "transit-vehicle-hitbox-labels-followed"

    /// How every wagon of one vehicle lies on the ground under it.
    ///
    /// **Per wagon, because a wagon is what lies on the ground.** A train is
    /// not a rigid body — it is a string of them, each free to take the angle
    /// of the few metres of hillside it happens to be standing on. What is
    /// rigid is the wagon: whatever the ground does between its nose and its
    /// tail, the wagon between them is a straight line at one angle. So the
    /// ground is measured under a wagon's two ends and it is turned by the
    /// difference — see `MapCoordinator.rest`, which does the measuring.
    ///
    /// **What this replaced.** One angle for the whole train, least-squares
    /// fitted down the rake and clamped at twelve degrees, with every wagon
    /// lifted off the ground to meet the fitted line. Where the drawn hillside
    /// was steeper than the clamp — a rack railway, an alpine ledge under a
    /// relief dial past one — the line could not follow the ground, and the
    /// gradient it could not express came out as *lift*: the leading coach on
    /// the rails and the rest of the train hanging level in the air behind it,
    /// climbing away from a track it was supposed to be standing on. Angles
    /// per wagon have no such spare dimension to leak into.
    struct Rest {
        /// The angle each wagon lies at, in degrees, nose-up positive, in the
        /// order the vehicle's own placements are in.
        var grades: [Double]
        /// How far each wagon is raised off the ground under its middle, in
        /// metres, in the same order. Nearly always nothing: it is what puts
        /// the ends of a wagon spanning a dip back on the surface, and there
        /// are not many dips a wagon's length wide. Never negative — a wagon
        /// over a hump rests on the hump.
        var lifts: [Double]
        /// How far the nose of the leading wagon and the tail of the last one
        /// stand above the ground directly under them, in metres.
        ///
        /// For the lamps, which are the one part of a vehicle that is not the
        /// vehicle: they are drawn by a layer of their own, at a height above
        /// whatever ground is under them — so a train tilted nose-up left its
        /// headlights hanging in the air where the nose used to be. A lamp is
        /// bolted to a body, and this is how far that body's end has moved.
        /// See `VehicleLamps.features`.
        var headEnd: Double = 0
        var tailEnd: Double = 0
        /// Ground under each wagon's middle, in metres, same order. `.nan`
        /// where the tile has not arrived. Used to drop a tunnelled wagon
        /// from the mountain down onto the bore: the translation is the
        /// bore altitude minus this.
        var surfaces: [Double] = []
    }


    /// What a placed wagon carries, and it is four things because a rigid body
    /// has four things to say about itself.
    enum Placed {
        /// Which mesh, by the name the style knows it under.
        static let model = "mid"
        /// `[about east, about north, heading]`, in degrees — the nose-up
        /// grade resolved onto the world axes the renderer turns about, and
        /// the yaw. See `placements`.
        static let rotation = "rot"
        /// `[across, up, along]` — the exaggeration, spent here rather than
        /// baked into a mesh per zoom level.
        static let scale = "scl"
        /// Whether this wagon has rock over it, and so is drawn ghosted.
        static let underground = "ug"
        /// How much of this wagon is drawn, 1 in the open, 0 once it has
        /// vanished into a tunnel. See `TunnelIndex.fade`.
        static let opacity = "op"
        /// `[0, 0, metres above the ground under this wagon]` — nearly always
        /// zero. The renderer stands a wagon on the ground under its own
        /// middle, which is where a wagon goes; this is the correction for the
        /// one case where that is not enough, a wagon spanning a dip with both
        /// its ends underground. See `Rest.lifts`.
        static let translation = "alt"

        // Spelled out rather than shortened to a letter each, unlike everything
        // in `VehicleShapes.Key` beside them. The saving would be real — these
        // are written per wagon per frame — and it is not worth the hazard: the
        // lamps in this same source already use `r` for "is this a tail lamp",
        // and a rotation fetched off a lamp by an expression expecting three
        // numbers aborts rather than answering wrongly. There are four wagon
        // properties and there are forty polygons; the letters belong on the
        // polygons.
    }

    /// Short, because there is one set per slab and a long train has fifty.
    private enum Key {
        static let colour = "c"
        static let base = "b"
        static let height = "h"
    }

    /// Over the source `VehicleShapes` owns, not one of its own.
    ///
    /// The solid and the flat drawing are the same vehicle at two attitudes and
    /// they cross-fade into each other, so a frame where one has moved and the
    /// other has not is a frame where a train is standing next to its own
    /// footprint. One source is one parse and one frame. See `VehicleShapes.Kind`.
    static func install(_ style: MapboxMap) throws {
        try install(style, source: VehicleShapes.source, fill: Self.fill)
        try install(style, source: VehicleShapes.followSource, fill: Self.followFill)
        for band in fadeBands {
            try installModels(
                style, source: VehicleShapes.source, layer: Self.models + band.suffix,
                from: band.from, to: band.to
            )
            try installModels(
                style, source: VehicleShapes.followSource,
                layer: Self.followModels + band.suffix,
                from: band.from, to: band.to
            )
        }
        try installModels(
            style, source: VehicleShapes.source, layer: Self.buried, from: nil, to: 0.06
        )
        try installModels(
            style, source: VehicleShapes.followSource, layer: Self.followBuried,
            from: nil, to: 0.06
        )
        try installHitboxes(
            style, source: VehicleShapes.source, boxes: Self.hitboxes,
            labels: Self.hitboxLabels
        )
        try installHitboxes(
            style, source: VehicleShapes.followSource, boxes: Self.followHitboxes,
            labels: Self.followHitboxLabels
        )
    }

    /// The layer that draws the baked wagons.
    ///
    /// Over the same source everything else is in, and for the same reason: a
    /// wagon's model, its flat footprint and its lamps are one vehicle told
    /// three ways, and three sources written in a row land on up to three
    /// different frames. On a train at line speed a frame is most of a metre.
    ///
    /// **Everything about a wagon is a property of its one feature.** The mesh
    /// is named, not sent; the heading and the grade are a three-number
    /// rotation; the exaggeration is a three-number scale. That is the whole
    /// of what crosses per frame — about sixty bytes against the two kilobytes
    /// of polygons the same wagon cost as extrusions, and, far more to the
    /// point, nothing a renderer could interpret one piece at a time.
    private static func installModels(
        _ style: MapboxMap, source sourceId: String, layer id: String,
        from: Double?, to: Double
    ) throws {
        var wagons = ModelLayer(id: id, source: sourceId)
        // One band of the tunnel fade, or the buried layer (`from` nil). The
        // property is asserted as a number: an untyped `get` is refused where
        // a comparison is required, and a refused filter is a layer that
        // draws nothing.
        if let from {
            wagons.filter = Exp(.all) {
                Exp(.eq) { Exp(.get) { VehicleShapes.Kind.key }; VehicleShapes.Kind.model }
                Exp(.gte) {
                    Exp(.toNumber) { Exp(.get) { Placed.opacity } }
                    from
                }
                Exp(.lt) {
                    Exp(.toNumber) { Exp(.get) { Placed.opacity } }
                    to
                }
            }
        } else {
            wagons.filter = Exp(.all) {
                Exp(.eq) { Exp(.get) { VehicleShapes.Kind.key }; VehicleShapes.Kind.model }
                Exp(.lt) {
                    Exp(.toNumber) { Exp(.get) { Placed.opacity } }
                    to
                }
            }
        }
        wagons.modelId = .expression(Exp(.get) { Placed.model })
        // On the rails, map-scaled. `location-indicator` is still occluded
        // by terrain and its default scale mode is viewport, which kept
        // wagons the same screen size as the map zoomed out.
        wagons.modelType = .constant(.common3d)
        wagons.modelScaleMode = .constant(.map)
        // `["array", "number", 3, ["get", …]]` rather than a bare `get`: the
        // expression language is typed, and a property fetched without an
        // assertion is of unknown type where an array of three numbers is
        // required.
        wagons.modelRotation = .expression(
            Exp(.array) { "number"; 3; Exp(.get) { Placed.rotation } }
        )
        wagons.modelScale = .expression(
            Exp(.array) { "number"; 3; Exp(.get) { Placed.scale } }
        )
        // Rotation eases; scale does not. Each wagon carries a stable feature
        // id, so the renderer interpolates from the heading it already has
        // rather than from identity — without the id, a 300 ms ease from
        // `[0, 0, 0]` left every coach at a fraction of its yaw and the rake
        // read as a staircase. With the id, the same ease is the short arc
        // from the last heading to this one, which is what hides the snap
        // when a coach crosses a vertex of its path. Scale must not join in:
        // eased from `[1, 1, 1]` a body inflates as the camera turns.
        wagons.modelRotationTransition = StyleTransition(duration: 0.35, delay: 0)
        wagons.modelScaleTransition = .zero
        wagons.modelTranslationTransition = .zero
        wagons.modelOpacityTransition = .zero
        // The default fade-out on a pitched view scales models down before
        // dropping them, which on a wagon is a body stretching and shrinking
        // as the camera turns rather than a tree thinning out of a forest.
        wagons.modelCutoffFadeRange = .constant(0)
        // `sea`, and the height per wagon as an offset from the ground.
        //
        // Neither setting means what its name says, and the difference between
        // them is only whether the app is allowed a say. Under *both* the
        // renderer stands the model on the terrain under its own anchor —
        // which is the right height for a wagon, and the one number the app
        // cannot get wrong by disagreeing with the terrain the reader is
        // looking at. What `ground` also does is *ignore `model-translation`
        // entirely*; under `sea` the translation is honoured, and it is still
        // measured from the ground rather than from sea level. Probed rather
        // than assumed: sixty metres under `ground` moves a tram not at all,
        // and sixty metres under `sea` puts it in the air above the roofs.
        //
        // So `sea` is the setting that means "on the ground, and the app may
        // add to it", which is what this needs — the addition being small and
        // rare. See `Rest.lifts` and `MapCoordinator.rest`.
        wagons.modelElevationReference = .constant(.sea)
        // How far this wagon stands above the ground under its own middle,
        // which is nearly always nothing: the correction for a wagon spanning
        // a dip, whose two ends would otherwise be under the surface. See
        // `Rest.lifts`, and `MapCoordinator.rest` for the measuring.
        wagons.modelTranslation = .expression(
            Exp(.array) { "number"; 3; Exp(.get) { Placed.translation } }
        )
        wagons.modelOpacity = .constant(0)
        // The same reasoning as the extrusions had: a vehicle is the one thing
        // this app draws that is genuinely in the scene, so it takes the
        // basemap's light and keeps just enough of its own that a red train at
        // midnight is a dark red train rather than a brown one.
        wagons.modelEmissiveStrength = .constant(0.14)
        wagons.modelRoughness = .constant(0.62)
        // No shadows, for the reason the extrusions had none: a moving contact
        // shadow on a body a few points wide is a smear that swims along the
        // platform behind the train casting it.
        wagons.modelCastShadows = .constant(false)
        wagons.modelReceiveShadows = .constant(false)
        wagons.modelAmbientOcclusionIntensity = .constant(0)
        try style.addLayer(wagons)
        // Off. Default true, and it is meant for forests: at a distance the
        // renderer drops instances so a million trees stay a texture. On a
        // wagon it is not fewer wagons, it is a mesh with faces missing —
        // a glitchy flank that comes and goes as the map is turned. Set as
        // a raw property because the typed accessor is still experimental
        // SPI and a refusal here must not take the layer down with it.
        do {
            try style.setLayerProperty(
                for: id, property: "model-allow-density-reduction", value: false
            )
        } catch {
            Diagnostics.note("\(id) kept density reduction: \(error)")
        }
    }

    /// Whether the baked wagons are drawn at all, and it is a switch rather
    /// than a dimmer.
    ///
    /// The fade between the flat drawing and the solid one used to run through
    /// this: a wagon halfway through a tilt was a wagon painted at half
    /// strength, and half a train is a train you can see the rails through.
    /// The camera moving is not a reason for a train to become transparent —
    /// a solid is either the right drawing for this camera or it is not. What
    /// carries the change instead is the flat drawing underneath, which is not
    /// faded by the tilt at all any more and is already there when the solid
    /// arrives. See `MapCoordinator.drawVehicleShapes`.
    ///
    /// **Underground is the exception.** A wagon in a tunnel fades to nothing
    /// on the rails it is standing on; the line number is what is left to
    /// follow. See `fadeBands`.
    static func setModelSolidity(_ style: MapboxMap, _ shown: Bool) {
        for band in fadeBands {
            for base in [models, followModels] {
                let layer = base + band.suffix
                guard style.layerExists(withId: layer) else { continue }
                try? style.setLayerProperty(
                    for: layer, property: "model-opacity",
                    value: shown ? band.opacity : 0
                )
            }
        }
        for layer in [buried, followBuried] where style.layerExists(withId: layer) {
            try? style.setLayerProperty(
                for: layer, property: "model-opacity", value: 0
            )
        }
    }

    /// Every placed wagon, as one point feature each.
    ///
    /// `names` is what the style calls each mesh; a placement whose mesh has
    /// not been registered yet is simply left out, and its vehicle keeps its
    /// flat drawing for another frame or two while the mesh is built on a
    /// background thread. See `VehicleModelStore.inFlight`.
    /// The second half of the answer is *which vehicles these are*, and the
    /// flat drawing needs it: a vehicle standing up as a model is not painted
    /// on the ground as well. It cannot be asked for in advance — a wagon whose
    /// mesh has not been baked yet is left out here, and a vehicle still fading
    /// in has no wagons at all — so what comes back is what was actually drawn.
    /// See `VehicleShapes.Key.stood`.
    /// How long a wagon takes to vanish into a tunnel, or to reappear.
    static let fadeSeconds = 0.5

    static func placements(
        _ footprints: [VehicleFootprint], excluding excluded: String? = nil,
        names: [VehicleModelKey: String], resting: [String: Rest] = [:],
        tunnels: TunnelIndex = TunnelIndex([]),
        ghostTunnels: Bool = true,
        yaws: inout [String: [Double]],
        fades: inout [String: [Double]],
        dt: Double = 1 / 30
    ) -> (features: [Feature], stood: Set<String>, lifts: [String: [Double]],
          opacities: [String: [Double]]) {
        var features: [Feature] = []
        var stood: Set<String> = []
        var allLifts: [String: [Double]] = [:]
        var allOpacities: [String: [Double]] = [:]
        features.reserveCapacity(footprints.count * 4)
        for print in footprints {
            if let excluded, print.id == excluded { continue }
            // No answer about the ground yet — the elevation tiles under this
            // vehicle have not arrived — so its wagons are drawn level, which
            // is where the renderer stands them anyway and is what they will go
            // on looking like until the tile lands. Drawn rather than held
            // back: the height is the renderer's answer now, not the app's, so
            // an unknown gradient is a train lying flat on the right hill and
            // not a train at a height nobody knows. See `MapCoordinator.rest`,
            // which holds the last good angle so this is a first-frame case.
            let rest = resting[print.id]
            let angles = rest?.grades ?? []
            let raised = rest?.lifts ?? []
            // Every wagon of it, or it is not standing up: a train with two of
            // its four coaches baked is a train that still needs its footprint
            // painted, or the two that are missing are missing from the map.
            var whole = !print.placements.isEmpty
            var wagonLifts = [Double](repeating: 0, count: print.placements.count)
            var wagonOp = [Double](repeating: 1, count: print.placements.count)
            for (index, placement) in print.placements.enumerated() {
                guard let name = names[placement.model] else { whole = false; continue }
                // On the rails, gone in half a second. Each wagon eases on
                // its own clock so a rake is swallowed coach by coach as
                // each one crosses the arch, not as a 36 m gradient that
                // left half a train hanging around the portal. Off, the
                // body ignores the bore — see `AppModel.ghostTunnels`.
                let inside = ghostTunnels && tunnels.onTrack(
                    print.rails(at: placement.alongTrain),
                    heading: placement.heading
                ) != nil
                let opacity: Double
                if ghostTunnels {
                    opacity = ease(
                        toward: inside ? 0 : 1, id: print.id, index: index,
                        dt: dt, into: &fades
                    )
                } else {
                    opacity = 1
                    var row = fades[print.id] ?? []
                    while row.count <= index { row.append(1) }
                    row[index] = 1
                    fades[print.id] = row
                }
                let underground = opacity < 0.06
                var feature = Feature(geometry: .point(Point(
                    CLLocationCoordinate2D(
                        latitude: placement.at.lat, longitude: placement.at.lon
                    )
                )))
                // Stable across source rewrites, so a coach that has not
                // moved is the same feature the renderer already has rather
                // than a new one interpolating from identity. Unique in this
                // source: the footprints and lamps beside it do not carry
                // an id.
                feature.identifier = .string("m:\(print.id):\(index)")
                // Nose-up by the slope of the ground under this wagon. See
                // `VehicleAttitude.euler` for how that becomes the three
                // world-axis turns the renderer takes.
                //
                // Heading is unwrapped against the last frame so a turn through
                // north is 359 → 361, not 359 → 1. The rotation transition
                // interpolates the three numbers linearly, and the wrapped pair
                // would spin the coach the long way once a second.
                let heading = unwrap(placement.heading, id: print.id, index: index, into: &yaws)
                let grade = index < angles.count ? angles[index] : 0
                let lift = index < raised.count ? raised[index] : 0
                wagonLifts[index] = lift
                wagonOp[index] = opacity
                let euler = VehicleAttitude.euler(heading: heading, grade: grade)
                // Both already fixed, and deliberately: the flat drawing's
                // width factor is a screen-space floor, which spent on a rigid
                // body is a wagon that inflates as the map zooms out. The
                // placement carries `VehicleShape.modelExaggeration` on both
                // axes instead, so the mesh keeps one shape at every zoom.
                // Clamped all the same — a placement is data, and a layer that
                // trusts its input is a layer one bad number takes down.
                let widthScale = min(placement.widthScale, VehicleShape.maxHeightScale)
                let heightScale = min(placement.heightScale, VehicleShape.maxHeightScale)
                feature.properties = [
                    VehicleShapes.Kind.key: .string(VehicleShapes.Kind.model),
                    Placed.model: .string(name),
                    Placed.rotation: .array(euler.map { .number($0) }),
                    // **`[across, along, up]`, and the middle one is the whole
                    // story.** The mesh is written in glTF's axes — X across,
                    // Y up, Z along — and this used to be handed over in that
                    // order, on the reasonable assumption that a scale applied
                    // to a model is applied in the model's own frame. It is
                    // not. The renderer converts the glTF into its own Z-up
                    // world on import, and every per-feature transform is in
                    // *that* frame: the SDK says as much about the property
                    // next door, whose euler angles are documented as
                    // `[lon, lat, z]` — which is why `VehicleAttitude.euler`
                    // puts the heading in the third slot and gets a yaw.
                    //
                    // So the number meant for the roof was landing on the
                    // couplers. Every wagon was drawn `min(scale, 2)` times
                    // its true length while the spacing between them stayed
                    // honest, which zoomed out is a rake telescoping into
                    // itself, and the height it was meant for was never
                    // exaggerated at all.
                    //
                    // Length stays at exactly 1. It is the fact the whole
                    // drawing exists to show, and it is what holds a coach
                    // between its own couplers.
                    Placed.scale: .array([
                        .number(widthScale), .number(1),
                        .number(heightScale),
                    ]),
                    Placed.underground: .boolean(underground),
                    Placed.opacity: .number(opacity),
                    // Off the ground under its own middle. Nearly always
                    // nothing: a dip a wagon spans. A tunnelled wagon stays
                    // on that ground and fades, rather than dropping into
                    // the mountain.
                    Placed.translation: .array([
                        .number(0), .number(0), .number(lift),
                    ]),
                ]
                features.append(feature)
            }
            allLifts[print.id] = wagonLifts
            allOpacities[print.id] = wagonOp
            if whole { stood.insert(print.id) }
        }
        return (features, stood, allLifts, allOpacities)
    }

    /// Move one wagon's displayed opacity toward `toward` over `fadeSeconds`.
    ///
    /// A first sample snaps: a train that spawned already in a tunnel must
    /// not fade in from solid, and a train that has been on screen in the
    /// open must not start from nothing.
    private static func ease(
        toward: Double, id: String, index: Int, dt: Double,
        into fades: inout [String: [Double]]
    ) -> Double {
        var row = fades[id] ?? []
        if index < row.count {
            let current = row[index]
            let delta = toward - current
            let step = dt / fadeSeconds
            let next: Double
            if abs(delta) <= step {
                next = toward
            } else {
                next = current + (delta < 0 ? -step : step)
            }
            row[index] = next
            fades[id] = row
            return next
        }
        while row.count < index { row.append(toward) }
        row.append(toward)
        fades[id] = row
        return toward
    }

    /// Keep one running heading per wagon so the rotation transition always
    /// takes the short arc. See `Geo.unwrapHeading`.
    private static func unwrap(
        _ heading: Double, id: String, index: Int, into yaws: inout [String: [Double]]
    ) -> Double {
        var row = yaws[id] ?? []
        if index < row.count {
            let heading = Geo.unwrapHeading(heading, previous: row[index])
            row[index] = heading
            yaws[id] = row
            return heading
        }
        while row.count < index { row.append(heading) }
        row.append(heading)
        yaws[id] = row
        return heading
    }

    /// The wagon as a box on the ground, a tick at its nose, and a label of
    /// the heading, grade and euler it was given.
    ///
    /// Off until asked. The features sit in the same source as the models, so
    /// a frame where the box has moved and the wagon has not cannot happen.
    private static func installHitboxes(
        _ style: MapboxMap, source sourceId: String, boxes: String, labels: String
    ) throws {
        let only = Exp(.eq) {
            Exp(.get) { VehicleShapes.Kind.key }; VehicleShapes.Kind.hitbox
        }
        var box = LineLayer(id: boxes, source: sourceId)
        box.filter = Exp(.all) {
            only
            Exp(.eq) { Exp(.get) { Hitbox.role }; Hitbox.box }
        }
        box.lineColor = .constant(StyleColor(UIColor(red: 0.2, green: 1, blue: 0.85, alpha: 1)))
        box.lineWidth = .constant(1.6)
        box.lineJoin = .constant(.round)
        box.lineCap = .constant(.round)
        box.lineEmissiveStrength = .constant(1)
        box.visibility = .constant(.none)
        try style.addLayer(box)

        var nose = LineLayer(id: boxes + "-nose", source: sourceId)
        nose.filter = Exp(.all) {
            only
            Exp(.eq) { Exp(.get) { Hitbox.role }; Hitbox.nose }
        }
        nose.lineColor = .constant(StyleColor(UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)))
        nose.lineWidth = .constant(2.2)
        nose.lineCap = .constant(.round)
        nose.lineEmissiveStrength = .constant(1)
        nose.visibility = .constant(.none)
        try style.addLayer(nose)

        var label = SymbolLayer(id: labels, source: sourceId)
        label.filter = Exp(.all) {
            only
            Exp(.eq) { Exp(.get) { Hitbox.role }; Hitbox.label }
        }
        label.textField = .expression(Exp(.get) { Hitbox.text })
        label.textSize = .constant(10)
        label.textColor = .constant(StyleColor(.white))
        label.textHaloColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.85)))
        label.textHaloWidth = .constant(1.2)
        label.textAllowOverlap = .constant(true)
        label.textIgnorePlacement = .constant(true)
        label.textOptional = .constant(false)
        label.visibility = .constant(.none)
        try style.addLayer(label)
    }

    private enum Hitbox {
        static let role = "r"
        static let box = "b"
        static let nose = "n"
        static let label = "l"
        static let text = "t"
    }

    /// Show or hide the debug boxes.
    /// Turn the part-way tunnel bands on and off.
    ///
    /// The fade is stacked layers because `model-opacity` is not data-driven —
    /// see `fadeBands` — and stacked layers are not free. A `ModelLayer` is one
    /// of the more expensive things in the style: it walks the whole source,
    /// evaluates its filter over every feature in it, and does that again for
    /// each of the four bands and the buried layer, in both lanes. Ten model
    /// layers over a source that is rewritten thirty times a second is ten
    /// passes over the same wagons to find that nine of them have nothing to
    /// draw.
    ///
    /// And nine of them nearly always have nothing to draw. A wagon is at full
    /// strength everywhere except the few seconds it spends in a portal, so the
    /// three part-way bands and the buried layer are dead weight on almost
    /// every frame of every session. Hidden, the renderer skips them entirely
    /// rather than filtering its way to an empty bucket; shown the moment a
    /// wagon starts to go under, which the caller already knows because it just
    /// worked the opacities out. See `MapCoordinator.vehicleDrawing`.
    ///
    /// The full-strength band is never touched: it is the one that draws the
    /// train.
    static func setTunnelFades(_ style: MapboxMap, _ shown: Bool) {
        var layers: [String] = [buried, followBuried]
        for band in fadeBands where band.suffix != "" {
            layers.append(models + band.suffix)
            layers.append(followModels + band.suffix)
        }
        for layer in layers where style.layerExists(withId: layer) {
            try? style.setLayerProperty(
                for: layer, property: "visibility",
                value: shown ? "visible" : "none"
            )
        }
    }

    static func setHitboxes(_ style: MapboxMap, _ shown: Bool) {
        let layers = [
            hitboxes, hitboxes + "-nose", hitboxLabels,
            followHitboxes, followHitboxes + "-nose", followHitboxLabels,
        ]
        for layer in layers where style.layerExists(withId: layer) {
            try? style.setLayerProperty(
                for: layer, property: "visibility",
                value: shown ? "visible" : "none"
            )
        }
    }

    /// One box, one nose tick and one label per placed wagon.
    static func hitboxes(
        _ footprints: [VehicleFootprint], excluding excluded: String? = nil,
        resting: [String: Rest] = [:]
    ) -> [Feature] {
        var features: [Feature] = []
        for print in footprints {
            if let excluded, print.id == excluded { continue }
            let bodies = print.parts.filter { $0.role == .body }
            let rest = resting[print.id]
            let grades = rest?.grades ?? []
            for (index, placement) in print.placements.enumerated() {
                let grade = index < grades.count ? grades[index] : 0
                let heading = placement.heading
                let euler = VehicleAttitude.euler(heading: heading, grade: grade)
                if index < bodies.count, bodies[index].ring.count >= 3 {
                    var ring = bodies[index].ring.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }
                    if let first = ring.first { ring.append(first) }
                    var box = Feature(geometry: .lineString(LineString(ring)))
                    box.properties = [
                        VehicleShapes.Kind.key: .string(VehicleShapes.Kind.hitbox),
                        Hitbox.role: .string(Hitbox.box),
                    ]
                    features.append(box)
                }
                let nose = Geo.moved(
                    placement.at, bearing: heading, metres: max(2, placement.length / 2)
                )
                var arrow = Feature(geometry: .lineString(LineString([
                    CLLocationCoordinate2D(
                        latitude: placement.at.lat, longitude: placement.at.lon
                    ),
                    CLLocationCoordinate2D(latitude: nose.lat, longitude: nose.lon),
                ])))
                arrow.properties = [
                    VehicleShapes.Kind.key: .string(VehicleShapes.Kind.hitbox),
                    Hitbox.role: .string(Hitbox.nose),
                ]
                features.append(arrow)

                var tag = Feature(geometry: .point(Point(
                    CLLocationCoordinate2D(
                        latitude: placement.at.lat, longitude: placement.at.lon
                    )
                )))
                let wrapped = (heading.truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                let text = String(
                    format: "#%d  h%.0f  g%+.1f  e[%+.1f,%+.1f,%.0f]",
                    index, wrapped, grade, euler[0], euler[1], euler[2]
                )
                tag.properties = [
                    VehicleShapes.Kind.key: .string(VehicleShapes.Kind.hitbox),
                    Hitbox.role: .string(Hitbox.label),
                    Hitbox.text: .string(text),
                ]
                features.append(tag)
            }
        }
        return features
    }

    private static func install(
        _ style: MapboxMap, source sourceId: String, fill: String
    ) throws {
        var solids = FillExtrusionLayer(id: fill, source: sourceId)
        solids.filter = Exp(.eq) {
            Exp(.get) { VehicleShapes.Kind.key }; VehicleShapes.Kind.solid
        }
        solids.fillExtrusionColor = .expression(Exp(.get) { Key.colour })
        solids.fillExtrusionBase = .expression(Exp(.get) { Key.base })
        solids.fillExtrusionHeight = .expression(Exp(.get) { Key.height })
        // Off until the camera asks for it. Installed at zero rather than left
        // to be added later, because adding a layer costs a style validation
        // pass and this one would be added and removed on every tilt.
        solids.fillExtrusionOpacity = .constant(0)
        solids.fillExtrusionOpacityTransition = .zero
        solids.fillExtrusionHeightTransition = .zero
        solids.fillExtrusionBaseTransition = .zero
        // The one setting that makes a stack of prisms read as a vehicle rather
        // than as a stack of prisms: the walls shade from the ground up, so the
        // chassis under the body is darker than the body and the edge between
        // the two is visible without an outline.
        solids.fillExtrusionVerticalGradient = .constant(true)
        // No ambient occlusion and no cast shadow, and both were tried.
        //
        // A contact shadow is the right idea on a building, which is large,
        // stationary and genuinely part of the scene. On a vehicle it is none
        // of those: the dark pool spreads across a body seven points wide, so
        // an intercity comes out with a black smear down one side and a bus
        // comes out black — and it *moves*, so the smear swims along the
        // platform half a second behind the train casting it. What it was
        // there to buy — the sense that the thing is standing on the ground —
        // the vertical gradient above already buys, for nothing.
        solids.fillExtrusionAmbientOcclusionIntensity = .constant(0)
        solids.fillExtrusionCastShadows = .constant(false)
        // Barely any. The flat overlay — the dots, the tracks, the labels —
        // emits its own colour at full strength, because an overlay is not part
        // of the scene and must not be dimmed by it. A solid vehicle is the
        // opposite case and is the one thing this app draws that genuinely *is*
        // in the scene: it stands on the ground beside a lit building, and
        // being lit by the same sun is what makes it look like it is standing
        // there rather than pasted over the top. So it takes the basemap's
        // light, and keeps just enough of its own that a red train at midnight
        // is a dark red train rather than a brown one.
        solids.fillExtrusionEmissiveStrength = .constant(0.14)
        try style.addLayer(solids)

        // What "the ground" is under a solid, and the whole of why turning the
        // terrain on used to tear the fleet apart.
        //
        // A fill extrusion standing on a relief has to be told what to do about
        // the fact that the ground under it is not level, and by default it is
        // told the two different things that between them make a vehicle
        // explode: the *base* is draped over the terrain vertex by vertex,
        // while the *top* stays flat. On a building that is nearly right — a
        // house on a slope really does have its walls cut to the ground and a
        // level eaves line. On a wagon it is a catastrophe, because a wagon is
        // long and thin and the two ends of it are at different heights: the
        // floor followed the hillside down while the roof stayed where it was,
        // so the body stretched, the windows sheared away from the doors, and a
        // train coming down a valley came apart along its whole length. That is
        // the "everything stretches out" of it, and it got worse with the
        // exaggeration slider, because the slider is a multiplier on exactly
        // the difference doing the stretching.
        //
        // Flat at both ends is the answer, and it is the *right* answer rather
        // than a suppression. A wagon is a rigid steel box. It does not bend to
        // the hill it is on; it stands on it, at one height, on its own bogies.
        // Told this, the renderer picks a single elevation for the whole prism
        // and puts it there unchanged — which is the same shape it had with the
        // terrain switched off, which is the shape that was right all along.
        //
        // Set as raw style properties rather than through `FillExtrusionLayer`,
        // whose two typed accessors are behind an experimental SPI. The strings
        // are the style spec's own and the SDK forwards them straight to the
        // renderer; going through the property avoids annotating this whole
        // file — and every file that imports it — with an SPI attribute for two
        // constants that have not changed since they were added.
        setFlatOnTerrain(style, layer: fill)
    }

    /// Tell an extrusion layer to stand its prisms on one elevation each.
    ///
    /// Noted rather than swallowed if it is refused. Both properties are recent
    /// additions to the style spec, and the failure mode if a future SDK drops
    /// or renames one is the exact bug this is here to fix — silently, on the
    /// one setting somebody has to turn on to see it.
    static func setFlatOnTerrain(_ style: MapboxMap, layer: String) {
        for property in ["fill-extrusion-base-alignment", "fill-extrusion-height-alignment"] {
            do {
                try style.setLayerProperty(for: layer, property: property, value: "flat")
            } catch {
                Diagnostics.note("\(layer) kept its terrain alignment: \(error)")
            }
        }
    }

    /// How solid the vehicles are drawn, 0 to 1.
    ///
    /// Written straight onto the layer rather than routed through the model,
    /// because it is a function of the camera and the camera moves at the
    /// display's rate while the model ticks at a fraction of it. A fade driven
    /// off the model would step visibly during a two-finger tilt, which is the
    /// one gesture this whole thing exists to answer.
    static func setSolidity(_ style: MapboxMap, _ value: Double) {
        for layer in [fill, followFill] {
            try? style.setLayerProperty(
                for: layer, property: "fill-extrusion-opacity", value: value
            )
        }
    }

    /// Every slab of every drawn vehicle, as features.
    ///
    /// No ordering to preserve, and that is the one way this is simpler than
    /// the flat drawing. Fill extrusions are depth-tested rather than painted,
    /// so a roof cannot be drawn under the body it belongs to and a bus cannot
    /// be drawn through a train — whichever is physically nearer the camera
    /// wins, which is the answer `VehicleFootprint.aboveGround` spends a
    /// paragraph approximating for the flat case.
    static func features(
        _ footprints: [VehicleFootprint], excluding excluded: String? = nil
    ) -> [Feature] {
        var features: [Feature] = []
        features.reserveCapacity(footprints.count * 7)
        for print in footprints {
            if let excluded, print.id == excluded { continue }
            for slab in print.slabs {
                guard slab.top > slab.base else { continue }
                var rings: [[CLLocationCoordinate2D]] = []
                rings.reserveCapacity(slab.rings.count)
                for ring in slab.rings where ring.count >= 3 {
                    var closed = ring.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }
                    // Turf wants a closed ring, and one that does not close is
                    // dropped without a word.
                    if let first = closed.first { closed.append(first) }
                    rings.append(closed)
                }
                guard let only = rings.first else { continue }

                // One feature, however many outlines are in it. A slab that
                // carries several — the pair of bogies under a coach, the run
                // of doors down a tram — has to arrive as *one* geometry or the
                // renderer grounds each piece on its own patch of hillside and
                // the wagon comes apart into its parts. See `MeshSlab.rings`.
                let geometry: Geometry = rings.count == 1
                    ? .polygon(Polygon([only]))
                    : .multiPolygon(MultiPolygon(rings.map { [$0] }))

                // A marked vehicle is marked on its roof, not painted yellow
                // all over. The flat drawing answers "which one did I tap" with
                // a ring round the outside, and from a tilted camera the
                // equivalent surface is the one the reader is looking down at —
                // so the roof and the turn of the shoulder take the colour and
                // the sides keep their livery. Painting the whole solid was the
                // first attempt and it threw away the operator entirely, which
                // is the thing the drawing exists to show.
                let marked = print.ringed && (slab.role == .roof || slab.role == .shoulder)

                var feature = Feature(geometry: geometry)
                feature.properties = [
                    VehicleShapes.Kind.key: .string(VehicleShapes.Kind.solid),
                    Key.colour: .string(marked ? VehicleShapes.selectionColour : slab.fill),
                    Key.base: .number(slab.base),
                    Key.height: .number(slab.top),
                ]
                features.append(feature)
            }
        }
        return features
    }
}

// The lights on the ends of a vehicle, for a tilted map drawn after dark.
//
// Two white ahead and two red behind, on everything drawn as a solid. It is the
// one piece of this whole feature that is purely for the look of the thing —
// and it turns out not to be, because it is also the only cue on the map that
// says which way a vehicle is *facing* rather than which way it is pointing. A
// train standing at a terminus with its tail lamps toward you has not turned
// round yet; the bearing cannot say that and two red dots can.
//
// **They are drawn at the height they are, and the map is told so.**
//
// A lamp is a point, and a point on a tilted map lands somewhere that depends
// entirely on how far off the ground it is: raise it by a metre and it moves up
// the screen, and the further the camera is tilted the further it moves. Given
// no height at all — which is what a circle layer has, because a circle is
// painted on the ground — four lamps that belong on the nose and the tail of a
// train were painted on the *ground* in front of it and behind it, several
// metres out at any real pitch.
//
// That was first fixed by spending the height as distance: a lamp `h` metres up
// is drawn where the ground `h·tan(pitch)` further from the camera is drawn, so
// moving its ground point that far along the view direction puts it on the nose
// from every angle. It is an orthographic identity used on a perspective view
// and it draws the right *picture* — but the point it draws is still on the
// floor, and a renderer that is asked which of two things is in front can only
// answer from where they really are. A lamp faked onto the nose this way is,
// as far as the depth buffer is concerned, on the ground several metres beyond
// the train, behind everything: behind its own body, and behind any building
// between it and the camera.
//
// So the height is given to the map instead. `line-elevation-reference` with a
// `line-z-offset` lifts the geometry itself, and the lamp is then where it says
// it is — which is what buys the occlusion below, and what lets the position be
// the lamp's own position again rather than a function of the camera.
//
// **Lines, because a line is the only round dot that is depth tested.**
//
// A circle is drawn in screen space and is never depth tested, so all four
// lamps show through the solid carrying them and through every building in
// front of them; the red tail lamp of a train behind a block of flats was
// painted on the wall. The obvious fix is a symbol layer, which *can* be depth
// tested — `icon-occlusion-opacity` at zero means "do not draw me when
// something is in front of me" — and it was tried and it was much worse. A
// symbol layer runs the collision-placement engine over its whole source every
// time that source changes, and this source changes fifteen to thirty times a
// second: the lamps flickered constantly, and under sustained pressure the
// placement never settled and they stopped appearing at all. Symbols are for
// labels on data that holds still. These are neither.
//
// A line has neither problem. `line-occlusion-opacity` is a per-pixel test
// against the depth buffer with no placement pass behind it, and a two-point
// line half a metre long with round caps *is* a dot — one whose width and blur
// are in pixels, which is what the circle's radius and blur were. At zero the
// lamp is simply not drawn where something is in front of it, which is now the
// right answer in all three cases: a building, a hillside, and the vehicle's
// own body.
//
// One consequence of being honest about the position: the lamp has to stand
// clear of the nose, or the nose occludes it. `proud` is how far in front of
// the mesh's own lamp block the halo sits — far enough that the depth test
// never argues, near enough to be under a pixel apart at the zooms this is
// drawn at.
//
// The facing fade stays. It is no longer doing the occluding — the depth
// buffer is — but it is still the thing that keeps a train coming round a curve
// from popping its lights on and off, because a fade is smoother than a test at
// the pixel where the nose crosses in front of the lamp behind it.
//
// **The fade rides in the colour, not in the opacity.** `line-occlusion-opacity`
// is refused outright on a layer whose `line-opacity` is data-driven, and how
// much of a lamp is pointing at the camera is the one number that varies per
// lamp. So it goes into the alpha of an `rgba` expression instead, which is the
// same trick `VehicleShapes` uses on the bodies and for the same reason.
enum VehicleLamps {
    static let glow = "transit-vehicle-lamps-glow"
    static let core = "transit-vehicle-lamps-core"
    static let followGlow = "transit-vehicle-lamps-followed-glow"
    static let followCore = "transit-vehicle-lamps-followed-core"

    private static let red = "r"
    /// How much of this lamp is pointing at the camera, 0 to 1.
    private static let facing = "o"
    /// How far off the ground this lamp is, in metres.
    private static let lift = "z"

    /// The colours the mesh paints its own lamps, so the halo drawn over a lamp
    /// is the colour of the lamp it is drawn over.
    private static let headColour = VehicleShape.headLampColour
    private static let tailColour = VehicleShape.tailLampColour

    /// How far in front of its own lamp block the halo sits, and how long the
    /// segment that draws it is, both in metres.
    ///
    /// The mesh's lamp is flush with the nose — see `VehicleMesh.lampAnchor` —
    /// so a halo drawn at exactly the same place is inside the body and the
    /// depth test throws it away. Half a metre clear settles that at every
    /// zoom this is drawn at and is a pixel and a half of offset at the closest
    /// of them, which against a halo twenty pixels across is nothing.
    ///
    /// The length is not decoration either: a two-point line whose ends quantise
    /// to the same tile coordinate has no direction and is dropped without a
    /// word, so the segment has to be long enough to survive the source's own
    /// grid and short enough to still read as a dot. Half a metre is both, and
    /// it points the way the lamp shines.
    private static let proud = 0.55, reach = 0.44

    /// Metres in a degree of latitude.
    private static let metresPerDegree = 111_320.0

    static func install(_ style: MapboxMap) throws {
        try install(
            style, source: VehicleShapes.source, glow: Self.glow, core: Self.core
        )
        try install(
            style, source: VehicleShapes.followSource,
            glow: Self.followGlow, core: Self.followCore
        )
    }

    private static func install(
        _ style: MapboxMap, source sourceId: String, glow: String, core: String
    ) throws {
        let only = Exp(.eq) {
            Exp(.get) { VehicleShapes.Kind.key }; VehicleShapes.Kind.lamp
        }

        // Twice the old radii, because a line is measured across and a circle
        // out from the middle. The blur is in pixels rather than in radii: the
        // circle's 1.1 meant "fade over the whole of me and a little more",
        // which is what these numbers are.
        try style.addLayer(lamp(
            id: glow, source: sourceId, only: only, strength: 0.42,
            width: (4.8, 12.0, 20.0), blur: (5.3, 13.2, 22.0)
        ))
        try style.addLayer(lamp(
            id: core, source: sourceId, only: only, strength: 0.95,
            width: (2.0, 4.2, 6.8), blur: (0.6, 1.3, 2.0)
        ))
        for layer in [glow, core] { setElevated(style, layer: layer) }
    }

    /// Lift a lamp layer off the ground, and say so if it will not go.
    ///
    /// Set afterwards rather than on the layer itself, and that is the whole
    /// point of the split: a layer carrying a property the renderer will not
    /// take is refused *whole*, and a refusal here is caught two frames up as
    /// "vehicle shapes unavailable" — four lamps traded for a silent nothing.
    /// Set separately, the worst a refusal can do is leave the lamps where they
    /// were before any of this: on the ground, just in front of the nose, which
    /// is a wrong picture rather than no picture.
    private static func setElevated(_ style: MapboxMap, layer: String) {
        do {
            try style.setLayerProperty(
                for: layer, property: "line-elevation-reference", value: "ground"
            )
            try style.setLayerProperty(
                for: layer, property: "line-z-offset", value: ["get", lift]
            )
        } catch {
            Diagnostics.note("\(layer) stayed on the ground: \(error)")
        }
    }

    /// One of the two discs a lamp is drawn as.
    ///
    /// `width` and `blur` are their values at zoom 15, 17 and 19, which are the
    /// three stops the circles were built on.
    private static func lamp(
        id: String, source: String, only: Exp, strength: Double,
        width: (Double, Double, Double), blur: (Double, Double, Double)
    ) -> LineLayer {
        var layer = LineLayer(id: id, source: source)
        layer.filter = only
        // A dot, which is what a round cap on a segment shorter than a pixel is.
        layer.lineCap = .constant(.round)
        layer.lineJoin = .constant(.round)
        // The height is not set here. See `setElevated`.
        layer.lineColor = .expression(colour(strength))
        layer.lineWidth = .expression(
            Exp(.interpolate) {
                Exp(.linear); Exp(.zoom)
                15; width.0; 17; width.1; 19; width.2
            }
        )
        layer.lineBlur = .expression(
            Exp(.interpolate) {
                Exp(.linear); Exp(.zoom)
                15; blur.0; 17; blur.1; 19; blur.2
            }
        )
        // Not drawn at all where something is in front of it — a building, a
        // hillside, or the train's own flank on a curve.
        layer.lineOcclusionOpacity = .constant(0)
        // Lit by nothing. A lamp is a light source; letting the basemap's night
        // shade it is letting the dark decide how bright a headlight is.
        layer.lineEmissiveStrength = .constant(1)
        layer.visibility = .constant(.none)
        return layer
    }

    /// A lamp's colour with its own fade already in the alpha.
    ///
    /// Built as an `rgba` expression rather than formatted per feature, which
    /// saves a string per lamp per frame and, more to the point, is the only
    /// place the fade can live: see the note at the top of this file.
    private static func colour(_ strength: Double) -> Exp {
        func rgba(_ text: String, fallback: (r: Int, g: Int, b: Int, a: Double)) -> Exp {
            let parts = Palette.components(of: text) ?? fallback
            return Exp(.rgba) {
                Double(parts.r); Double(parts.g); Double(parts.b)
                Exp(.product) { strength * parts.a; Exp(.get) { facing } }
            }
        }
        return Exp(.switchCase) {
            Exp(.get) { red }
            rgba(tailColour, fallback: (255, 51, 32, 1))
            rgba(headColour, fallback: (255, 244, 220, 1))
        }
    }

    /// Lights on, or lights off.
    ///
    /// Two conditions. **Dark**, because what a headlight is *for* is being
    /// brighter than its surroundings, and in daylight nothing is — a pale
    /// glowing disc on a white ground is a smudge, and four per vehicle over a
    /// city is a map with dirt on it. And **tilted**, because on a map looking
    /// straight down a lamp is a dot beside a dot: there is no third dimension
    /// for it to sit in front of, nothing it could be hidden behind, and
    /// nothing it adds to a drawing that is already showing the whole vehicle
    /// from above. Lights belong to the view that has a horizon in it.
    static func setVisible(_ style: MapboxMap, _ on: Bool) {
        for layer in [glow, core, followGlow, followCore]
        where style.layerExists(withId: layer) {
            try? style.setLayerProperty(
                for: layer, property: "visibility", value: on ? "visible" : "none"
            )
        }
    }

    /// The lamps, with the ones pointing away from the camera faded out.
    ///
    /// `viewBearing` is the compass direction the camera is looking. A lamp
    /// shines along `facing`, so it is aimed at the camera when those two are
    /// opposite — and the cosine between them, rescaled, is how much of it to
    /// draw. The band is deliberately generous: everything except roughly the
    /// rear sixty degrees is drawn in full, because from the side of a train
    /// both ends are genuinely visible and dimming them there would be a
    /// correction to something that was never wrong.
    ///
    /// The tilt is not asked for any more. It used to be, because the height
    /// was being spent as ground distance and that distance is a function of
    /// the camera; the geometry now carries its own height, so a lamp sits
    /// where it sits whatever the map is doing.
    static func features(
        _ footprints: [VehicleFootprint], excluding excluded: String? = nil,
        viewBearing: Double, buried: [String: Double] = [:],
        resting: [String: VehicleModels.Rest] = [:]
    ) -> [Feature] {
        var features: [Feature] = []
        features.reserveCapacity(footprints.count * 4)
        for print in footprints {
            if let excluded, print.id == excluded { continue }
            // A vehicle still growing out of its dot has no lights yet. Four
            // bright points arriving before the thing carrying them is the same
            // complaint the casing under a half-faded body was.
            guard print.emergence >= 0.999 else { continue }
            // Not through a mountain. The depth test would now do this on its
            // own where there is relief switched on to do it with — but a
            // buried wagon is drawn on the ground *above* its bore rather than
            // at the depth it runs at, so nothing is in front of its lamps to
            // occlude them and the cull is still the only thing that knows.
            guard (buried[print.id] ?? 0) < 0.5 else { continue }
            // One cosine for the whole vehicle: four lamps on one train are
            // never far enough apart in latitude for it to differ.
            let mLon = max(1, metresPerDegree * cos(
                (print.lamps.first?.at.lat ?? 0) * .pi / 180
            ))
            // How far each end of the vehicle has risen off the ground under
            // it, and which end this lamp is on. Asked by position rather than
            // by colour: a train shows white at the end it is going and red at
            // the other, but a lamp does not know which of those it is and both
            // ends carry both.
            let rest = resting[print.id]
            let head = print.centreline.first
            let tail = print.centreline.last
            for lamp in print.lamps {
                let toward = -cos((lamp.facing - viewBearing) * .pi / 180)
                let shown = min(1, max(0, (toward + 0.55) / 0.35))
                // Dropped rather than drawn at nothing: a lamp on the far end
                // of every vehicle on screen is a feature per vehicle per frame
                // for something with no pixels in it.
                guard shown > 0.02 else { continue }
                // Out along the way it shines, clear of the nose behind it.
                let ahead = lamp.facing * .pi / 180
                let north = cos(ahead), east = sin(ahead)
                func point(_ metres: Double) -> CLLocationCoordinate2D {
                    CLLocationCoordinate2D(
                        latitude: lamp.at.lat + north * metres / metresPerDegree,
                        longitude: lamp.at.lon + east * metres / mLon
                    )
                }
                var feature = Feature(geometry: .lineString(LineString([
                    point(proud - reach / 2), point(proud + reach / 2),
                ])))
                // On the body, not above the ground the body has left. The
                // wagon carrying this lamp is tilted into the hill and stood
                // where the hill puts it; its nose is metres off the ground
                // under the nose, and the lamp bolted to that nose is with it.
                var risen = 0.0
                if let rest {
                    let atHead = head.map { Geo.metres($0, lamp.at) } ?? .infinity
                    let atTail = tail.map { Geo.metres($0, lamp.at) } ?? .infinity
                    risen = atHead <= atTail ? rest.headEnd : rest.tailEnd
                }
                feature.properties = [
                    VehicleShapes.Kind.key: .string(VehicleShapes.Kind.lamp),
                    red: .boolean(lamp.red),
                    facing: .number(shown),
                    lift: .number(lamp.height + risen),
                ]
                features.append(feature)
            }
        }
        return features
    }
}
