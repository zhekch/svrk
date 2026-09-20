import Foundation
import MapboxMaps
import TransitCore
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
        // Keep terrain tile selection on the SDK's default 512-pixel size.
        dem.tileSize = 512
        // Request the visible elevation level directly when terrain is enabled,
        // rather than first loading a coarse parent four zoom levels away.
        dem.prefetchZoomDelta = 0
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

    /// Keep distant terrain clear. Reapply after style loads and scene changes
    /// because a basemap may supply its own atmosphere.
    static func removeAtmosphere(_ style: MapboxMap) {
        do {
            try style.removeAtmosphere()
            for layer in style.allLayerIdentifiers where layer.type == .sky {
                try style.removeLayer(withId: layer.id)
            }
        } catch {
            Diagnostics.note("could not remove atmosphere: \(error)")
        }
    }

    /// Fog as a far clip, not as scenery.
    ///
    /// A 60° camera sees the horizon. Mapbox Standard then draws every building
    /// and tree in that frustum. Fully opaque fog at a short range hides that
    /// work *and* — per the style spec — stops those tiles being loaded.
    /// Opacity below 100% does the opposite, so the fade is in range, not in
    /// alpha. Flat cameras skip this: a plan view has no horizon to lid.
    static func applyHorizon(
        _ style: MapboxMap, pitch: Double, zoom: Double, dark: Bool
    ) {
        guard pitch >= Geo.tiltLookAheadPitch, zoom >= 12 else {
            removeAtmosphere(style)
            return
        }
        let t = min(1, max(0, (pitch - Geo.tiltLookAheadPitch) / 54))
        var fog = Atmosphere()
        fog.range = .constant([2.2 - t * 2.0, 8.0 - t * 6.6])
        fog.rangeTransition = StyleTransition(duration: 0.3, delay: 0)
        fog.horizonBlend = .constant(0.12 + t * 0.2)
        fog.starIntensity = .constant(0)
        if dark {
            fog.color = .constant(StyleColor(UIColor(
                red: 0.07, green: 0.09, blue: 0.14, alpha: 1
            )))
            fog.highColor = .constant(StyleColor(UIColor(
                red: 0.05, green: 0.08, blue: 0.16, alpha: 1
            )))
            fog.spaceColor = .constant(StyleColor(UIColor(
                red: 0.02, green: 0.03, blue: 0.06, alpha: 1
            )))
        } else {
            fog.color = .constant(StyleColor(UIColor(
                red: 0.78, green: 0.84, blue: 0.90, alpha: 1
            )))
            fog.highColor = .constant(StyleColor(UIColor(
                red: 0.62, green: 0.74, blue: 0.88, alpha: 1
            )))
            fog.spaceColor = .constant(StyleColor(UIColor(
                red: 0.45, green: 0.62, blue: 0.82, alpha: 1
            )))
        }
        do {
            try style.setAtmosphere(fog)
        } catch {
            Diagnostics.note("horizon fog refused: \(error)")
        }
    }

    /// 3D trees fill a steep frustum to the horizon. Buildings next to the
    /// train stay; trees and far landmarks do not.
    static let treePitchLimit = 12.0
    static let landmarkMinZoom = 15.2

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
    static func applyStandardConfig(
        _ style: MapboxMap, preset: LightPreset, buildings: Bool,
        trees: Bool, landmarks: Bool
    ) {
        guard let importId = style.styleImports.first?.id else { return }
        do {
            try style.setStyleImportConfigProperties(for: importId, configs: [
                "lightPreset": preset.mapboxValue,
                // Standard owns these inside its import, so this is also the
                // only route by which the app's 3D-buildings setting can avoid
                // their geometry and depth passes.
                "show3dObjects": buildings,
                "show3dBuildings": buildings,
                // The basemap's own transit labels, over an app whose entire
                // subject is transit. Two sets of station names at two sizes in
                // two fonts, and neither of them the one that can be tapped.
                "showTransitLabels": false,
                "showPointOfInterestLabels": false,
            ])
            // Separate from the rest: an older Standard import that does not
            // know these names must not take the lighting config down with it.
            try? style.setStyleImportConfigProperty(
                for: importId, config: "show3dTrees", value: trees
            )
            try? style.setStyleImportConfigProperty(
                for: importId, config: "show3dLandmarks", value: landmarks
            )
            try? style.setStyleImportConfigProperty(
                for: importId, config: "aerialways", value: false
            )
        } catch {
            Diagnostics.note("standard config rejected: \(error)")
        }
    }

    /// User-facing lighting choice. Resolve Auto before passing it to Mapbox;
    /// it follows the real sun at the map, not the timetable's simulated time.
    enum LightPreset: String, CaseIterable, Identifiable {
        case day, dawn, dusk, night, auto
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        /// What the lighting control shows. Dawn and dusk are Mapbox presets
        /// Auto picks; they are not extra segments on a three-choice dial.
        static var controlCases: [LightPreset] { [.day, .night, .auto] }

        var symbol: String {
            switch self {
            case .day: return "sun.max.fill"
            case .dawn: return "sunrise.fill"
            case .dusk: return "sunset.fill"
            case .night: return "moon.fill"
            case .auto: return "clock.arrow.circlepath"
            }
        }

        /// Mapbox Standard's `lightPreset` values. Auto is resolved first.
        var mapboxValue: String {
            switch self {
            case .auto: return LightPreset.day.rawValue
            default: return rawValue
            }
        }

        func resolved(
            at date: Date, latitude: Double, longitude: Double
        ) -> Self {
            guard self == .auto else { return self }
            let sun = Geo.sunPosition(at: date, latitude: latitude, longitude: longitude)
            // Civil twilight is about −6°. A few degrees of clear sky above
            // the horizon is already daytime lighting; between the two, the
            // sun is low enough for Mapbox's dawn and dusk.
            if sun.elevation >= 8 { return .day }
            if sun.elevation >= -6 { return sun.hourAngle < 0 ? .dawn : .dusk }
            return .night
        }

        var isDark: Bool {
            switch self {
            case .night, .dusk: return true
            case .day, .dawn, .auto: return false
            }
        }
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
    /// have to go behind anything standing on it. The selected route belongs
    /// here with the rails: it is a marking on the ground, and a path, a
    /// travelled dot or an arrow across a roof is the same decal the tracks
    /// used to be. Station dots — rail and bus alike — and the unlabelled
    /// kerb poles are the same kind of mark; their names and platform plates
    /// stay at `top` so they remain readable as controls.
    private static let groundPrefixes = [
        "orm-", "transit-tracks", "transit-route",
        "transit-stops-rail", "transit-stops-local", "transit-stops-selected",
        "transit-platforms-pole",
    ]

    static func placeOverlay(_ style: MapboxMap, ownLayers: Set<String>) {
        for layer in style.allLayerIdentifiers where ownLayers.contains(layer.id) {
            // Vehicle bodies used to join this set, behind the buildings, with
            // a ghost copy at `top` so a train the far side of a block was
            // still visible. Street names also sit above `middle`, so the
            // train went under every "Spiezstrasse" it crossed — the worse of
            // the two overlaps. Bodies now share `top` with the vehicle dots
            // and the models; the rails, the route and the station dots stay
            // in `middle`, because a mark across a roof is still a decal and
            // none of them needs to be read through a label.
            let ground = groundPrefixes.contains { layer.id.hasPrefix($0) }
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
