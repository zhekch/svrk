import Foundation
import MapboxMaps
import UIKit

// The ground, the sky, and the buildings — the three things that turn a map you
// are looking down at into a place you are standing in.
//
// This is the one part of the app where Switzerland is doing the work. A flat
// map of the Mittelland is a diagram of a railway; the same map with the
// terrain on and the camera tilted is the Lötschberg going into a mountain, the
// Gotthard axis climbing a valley wall, a lake steamer with the Rigi behind it.
// None of that is decoration: which side of a ridge a line runs on, and how far
// it has to climb to get there, is most of why the Swiss network looks the way
// it does, and it is invisible from directly above.
//
// **Everything here is optional and everything here degrades.** The DEM is
// Mapbox's own raster tiles and needs a network; the building extrusions come
// from whichever vector source the basemap happens to ship; the Standard style
// is a different style altogether with its own lighting model. Each is
// installed inside its own `do`/`catch` and each failure is a note rather than
// a throw, because a map with no hillshade is still a map and the alternative —
// one refused layer taking the whole style down with it — is a blank screen.
enum Terrain3D {
    /// Mapbox's global elevation tiles.
    static let demSource = "transit-dem"
    static let sky = "transit-sky"
    static let buildings = "transit-buildings"

    /// The vector source and layer the ordinary Mapbox styles keep their
    /// building footprints in.
    ///
    /// Dark and Light carry `composite`/`building` with a `height` in metres
    /// on each polygon. Satellite Streets carries the same source, but the
    /// extrusion is not asked for there: the photograph already shows the
    /// roofs, and translucent boxes over them are a haze rather than a city.
    /// Standard draws its own 3D buildings from an import, and asks for them
    /// through a config flag rather than through a layer — see
    /// `applyStandardConfig`.
    private static let vectorSource = "composite"
    private static let vectorLayer = "building"

    // MARK: - Elevation

    /// Put the elevation tiles in the style, without switching them on.
    ///
    /// Separated from `apply` because a source is expensive to add and cheap to
    /// leave sitting there: adding it costs a style validation pass, and the
    /// terrain toggle is a switch somebody flips back and forth while looking
    /// at the result. With the source already present, turning terrain on is
    /// one call that changes no geometry the renderer has not already got.
    static func installSource(_ style: MapboxMap) throws {
        guard !style.sourceExists(withId: demSource) else { return }
        var dem = RasterDemSource(id: demSource)
        dem.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
        // 514 rather than 512: the DEM tiles carry a one-pixel border on every
        // side so neighbouring tiles can be interpolated across their shared
        // edge without a seam. Set to 512 the terrain comes out quilted.
        dem.tileSize = 514
        // Above 14 there is no more elevation data, and asking for it produces
        // over-scaled parent tiles at full price.
        dem.maxzoom = 14
        try style.addSource(dem)
    }

    /// Switch the relief on or off, and say how much of it there is.
    ///
    /// The exaggeration is a dial rather than a constant for the same reason
    /// the track overlay is: what reads well depends entirely on where the
    /// camera is. At 1.0 the Alps are correct and the Mittelland is almost
    /// flat, which is true and also throws away the only cue that the line
    /// through Olten is on a slope at all. Past about 2 the country turns into
    /// a relief model and the vehicles start climbing walls.
    static func apply(_ style: MapboxMap, on: Bool, exaggeration: Double) {
        guard on else {
            style.removeTerrain()
            return
        }
        var terrain = Terrain(sourceId: demSource)
        terrain.exaggeration = .constant(max(0, min(3, exaggeration)))
        do { try style.setTerrain(terrain) } catch {
            Diagnostics.note("terrain unavailable: \(error)")
        }
    }

    // MARK: - Sky

    /// The sky over the horizon, once there is a horizon to put it over.
    ///
    /// A tilted map has one and a flat map does not, which is why this only
    /// appears with the pitch. Without it, tilting past about fifty degrees
    /// shows the basemap running out into the background colour along a hard
    /// straight line — the single thing that most makes a tilted map look like
    /// a texture on a table rather than a view of a country.
    static func installSky(_ style: MapboxMap, dark: Bool) throws {
        guard !style.layerExists(withId: sky) else { return }
        var layer = SkyLayer(id: sky)
        layer.skyType = .constant(.atmosphere)
        // Low in the sky and slightly to the north-east, which is roughly where
        // the sun is over Switzerland on a summer morning. It is not tracked
        // against the clock: a sun that moves while somebody watches a train is
        // a distraction, and one fixed direction means the shading on the
        // mountains is the same every time the app is opened, which is what
        // makes a familiar valley recognisable.
        layer.skyAtmosphereSun = .constant([50, 82])
        layer.skyAtmosphereSunIntensity = .constant(dark ? 4 : 12)
        layer.skyAtmosphereColor = .constant(StyleColor(
            dark ? UIColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1)
                 : UIColor(red: 0.52, green: 0.68, blue: 0.86, alpha: 1)
        ))
        layer.skyAtmosphereHaloColor = .constant(StyleColor(
            dark ? UIColor(red: 0.22, green: 0.26, blue: 0.36, alpha: 1)
                 : UIColor(red: 0.85, green: 0.90, blue: 0.97, alpha: 1)
        ))
        try style.addLayer(layer)
    }

    /// How far the ground fades into the sky at the horizon.
    ///
    /// The sky layer paints above the horizon; this is what stops the ground
    /// meeting it at a razor edge. Set on the style rather than on a layer
    /// because it is a property of the atmosphere the whole scene is in.
    static func applyAtmosphere(_ style: MapboxMap, dark: Bool) {
        var air = Atmosphere()
        air.horizonBlend = .constant(0.035)
        air.color = .constant(StyleColor(
            dark ? UIColor(red: 0.12, green: 0.15, blue: 0.21, alpha: 1)
                 : UIColor(red: 0.72, green: 0.80, blue: 0.90, alpha: 1)
        ))
        air.highColor = .constant(StyleColor(
            dark ? UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1)
                 : UIColor(red: 0.36, green: 0.55, blue: 0.82, alpha: 1)
        ))
        air.spaceColor = .constant(StyleColor(
            dark ? UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
                 : UIColor(red: 0.60, green: 0.73, blue: 0.89, alpha: 1)
        ))
        air.starIntensity = .constant(dark ? 0.12 : 0)
        do { try style.setAtmosphere(air) } catch {
            Diagnostics.note("atmosphere unavailable: \(error)")
        }
    }

    // MARK: - Buildings

    /// The buildings around the station, extruded.
    ///
    /// Not scenery. A tilted map with a flat basemap has nothing in it the same
    /// height as a train, so a train drawn three metres tall reads as a smear
    /// on the ground; put the station building next to it at twenty and the
    /// train is suddenly a train standing beside a building. The whole point of
    /// the solid vehicles is a sense of scale, and scale needs something to be
    /// scaled against.
    ///
    /// From zoom 14, which is a level below where the vehicles start standing
    /// up. Below that a city is a few hundred thousand polygons that resolve to
    /// a grey haze.
    static func installBuildings(_ style: MapboxMap, dark: Bool, below: String?) throws {
        guard !style.layerExists(withId: buildings) else { return }
        // Standard has no `composite`, and Standard does not need one — it
        // brings its own buildings and its own landmarks. Asking for a layer
        // over a source that is not there is an error the whole install would
        // otherwise be taken down by.
        guard style.sourceExists(withId: vectorSource) else { return }

        var layer = FillExtrusionLayer(id: buildings, source: vectorSource)
        layer.sourceLayer = vectorLayer
        layer.minZoom = 14
        // The tiles carry footprints that are not meant to be extruded — courtyards,
        // building parts with no height of their own — and drawn they come out as
        // slabs at ground level with hard edges.
        layer.filter = Exp(.eq) { Exp(.get) { "extrude" }; "true" }
        layer.fillExtrusionHeight = .expression(Exp(.get) { "height" })
        layer.fillExtrusionBase = .expression(Exp(.get) { "min_height" })
        layer.fillExtrusionColor = .constant(StyleColor(
            dark ? UIColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1)
                 : UIColor(red: 0.87, green: 0.87, blue: 0.86, alpha: 1)
        ))
        // Deliberately not solid. These are the *context*, and the thing being
        // looked at is on the ground between them — a station throat under an
        // opaque city block is a station throat nobody can see. Translucent,
        // the buildings say where the streets are without hiding the platform.
        layer.fillExtrusionOpacity = .constant(dark ? 0.72 : 0.78)
        layer.fillExtrusionVerticalGradient = .constant(true)
        // No shadows here either. A city's worth of them at zoom 16 is a mesh
        // of grey over the one thing the map is about, and the buildings are
        // the *context* — the moment they start explaining themselves they are
        // competing with the railway between them.
        layer.fillExtrusionAmbientOcclusionIntensity = .constant(0)
        layer.fillExtrusionCastShadows = .constant(false)
        // They rise as they come into view rather than appearing at full
        // height, which at zoom 14 is a whole city arriving at once.
        layer.fillExtrusionHeightTransition = StyleTransition(duration: 0.6, delay: 0)
        // Added, then told what the ground under it is. By default a fill
        // extrusion drapes its *base* over the terrain vertex by vertex while
        // its top stays flat, which on a building on a hillside stretches the
        // walls down the slope — the same tearing the vehicles had, on the one
        // other thing in this app that stands up off the ground. A building is
        // a rigid box too: one elevation for the whole footprint, level eaves.
        // See `VehicleModels.install`, which explains the pair at length.

        // Under everything this app draws. The railway, the platforms and the
        // vehicles are the subject; a building drawn over the train standing
        // beside it is the tail wagging the dog.
        if let below, style.layerExists(withId: below) {
            try style.addLayer(layer, layerPosition: .below(below))
        } else {
            try style.addLayer(layer)
        }
        VehicleModels.setFlatOnTerrain(style, layer: buildings)
    }

    static func setBuildings(_ style: MapboxMap, visible: Bool) {
        guard style.layerExists(withId: buildings) else { return }
        try? style.setLayerProperty(
            for: buildings, property: "visibility", value: visible ? "visible" : "none"
        )
    }

    // MARK: - The Standard style's own third dimension

    /// Standard's 3D objects, and which time of day it is lit for.
    ///
    /// Standard is not a style with layers this app can reach into — it is an
    /// *import*, a whole style nested inside the one being loaded, and what it
    /// draws is asked for through a handful of named configuration values
    /// rather than through the layer list. That is why the buildings above do
    /// nothing here and this does it instead.
    ///
    /// The import's id is read off the style rather than assumed. Mapbox names
    /// it `basemap` today and there is no promise that it always will, and a
    /// hard-coded name that stops matching fails silently — the config is
    /// simply ignored and the map looks subtly wrong with nothing in the log.
    static func applyStandardConfig(_ style: MapboxMap, preset: LightPreset) {
        guard let importId = style.styleImports.first?.id else { return }
        do {
            try style.setStyleImportConfigProperties(for: importId, configs: [
                "lightPreset": preset.rawValue,
                "show3dObjects": true,
                // The basemap's own transit labels, over an app whose entire
                // subject is transit. Two sets of station names at two sizes in
                // two fonts, and neither of them the one that can be tapped.
                "showTransitLabels": false,
                "showPointOfInterestLabels": false,
            ])
        } catch {
            Diagnostics.note("standard config rejected: \(error)")
        }
    }

    /// What time of day the Standard basemap is lit for.
    ///
    /// Mapbox's own four, exposed because the choice is not cosmetic on a map
    /// with terrain: `dusk` rakes the light across the Alps and every valley
    /// gets a shadow, `day` flattens them, and `night` is the only one that
    /// belongs under this app's dark chrome.
    enum LightPreset: String, CaseIterable, Identifiable {
        case dawn, day, dusk, night
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        /// Whether the ground under our layers comes out dark.
        ///
        /// What every halo, casing and overlay palette this app installs is
        /// chosen from — see `MapCoordinator.isDarkTheme`. Dusk counts: the
        /// preset that rakes the light across the Alps also puts most of the
        /// country in shadow, and white labels with a dark halo are what reads
        /// over it.
        var isDark: Bool { self == .night || self == .dusk }
    }
}

// MARK: - Sitting our layers inside somebody else's style

/// Where this app's own layers belong in a style that has opinions about depth.
///
/// Two problems, one answer, and both only appear once the map is tilted.
///
/// **The overlap.** Mapbox Standard draws buildings as real 3D volumes. A layer
/// added without a slot lands on top of the entire imported style, so the
/// tracks and the station areas were painted *over* the roofs of the buildings
/// they run between — at Bern, a station's worth of platforms lying across the
/// Bahnhofplatz like a decal. Slots are how a style says where a foreign layer
/// goes: `middle` is above the roads and *behind* the 3D buildings, which is
/// exactly where a railway on the ground belongs. Markers and labels stay at
/// `top`, because a train hidden behind an office block is a worse map than a
/// train drawn slightly too far forward.
///
/// **The desaturation.** Standard lights its scene, and at `night` that light
/// is dim and blue. Any layer with an emissive strength of zero is lit by it —
/// so the vehicle dots, the route line and the station names all went grey and
/// cold along with the ground, which is the opposite of what an overlay is for.
/// An overlay is not part of the scene and is not lit by it: everything this
/// app draws emits its own colour at full strength, and reads the same at
/// midnight as at noon.
///
/// Applied by walking the style rather than by setting a property on each layer
/// where it is built. There are four modules and about thirty layers between
/// them, several of them OpenRailwayMap's whole palette, and the rule is the
/// same for all of them — written once here it cannot be forgotten by the next
/// layer somebody adds.
extension Terrain3D {
    /// The prefixes of the layers that are painted flat on the ground, and so
    /// have to go behind anything standing on it.
    private static let groundPrefixes = ["orm-", "transit-tracks", "transit-route"]

    /// And the ones whose names do not say so.
    ///
    /// The flat drawing of a vehicle is painted on the ground exactly as the
    /// rails under it are, and belongs behind the buildings for the same
    /// reason: a train on the far side of a block is not on its roof. What
    /// keeps it visible anyway is a second copy of the same drawing left up at
    /// `top` at half strength — see `VehicleShapes.ghostOpacity` — so what a
    /// reader sees through a building is a ghost of the vehicle rather than
    /// nothing, and what they see in the open is the drawing itself.
    ///
    /// The casing comes down with it because it is the shadow *under* the body:
    /// left above the fill it would be painted over the vehicle it belongs to.
    private static let groundLayers: Set<String> = [
        VehicleShapes.casing, VehicleShapes.fill,
        VehicleShapes.followCasing, VehicleShapes.followFill,
    ]

    static func placeOverlay(_ style: MapboxMap, ownLayers: Set<String>) {
        for layer in style.allLayerIdentifiers where ownLayers.contains(layer.id) {
            let ground = groundLayers.contains(layer.id)
                || groundPrefixes.contains { layer.id.hasPrefix($0) }
            try? style.setLayerProperty(
                for: layer.id, property: "slot",
                // `Slot.middle` and `Slot.top` are declared through a failable
                // initialiser and so come out optional, though neither can
                // actually be nil. The strings are the style spec's own.
                value: ground ? "middle" : "top"
            )
            for property in emissiveProperties(of: layer.type) {
                try? style.setLayerProperty(for: layer.id, property: property, value: 1.0)
            }
        }
    }

    /// What "do not let the scene light this" is called, per layer type.
    ///
    /// The extrusions are left out on purpose. They are the one thing this app
    /// draws that genuinely *is* in the scene — a solid vehicle standing on the
    /// ground beside a lit building — and lighting it is what makes it look
    /// like it is standing there. It carries a little emission of its own so a
    /// red train at night does not go brown; that is set where it is built.
    private static func emissiveProperties(of type: LayerType) -> [String] {
        switch type {
        case .circle: return ["circle-emissive-strength"]
        case .line: return ["line-emissive-strength"]
        case .fill: return ["fill-emissive-strength"]
        case .symbol: return ["text-emissive-strength", "icon-emissive-strength"]
        default: return []
        }
    }
}
