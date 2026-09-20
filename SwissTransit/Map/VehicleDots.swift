import Foundation
import MapboxMaps
import UIKit
import TransitCore

// The dot a vehicle is until it is large enough to be drawn as itself.
//
// One table, read from two sides. The halo layer interpolates its
// `circle-radius` out of it, and the model measures the same curve against the
// ground to work out which vehicles are worth handing to the renderer at all —
// see `AppModel.dotSpacing`. Kept together because the second reading is only
// as safe as the first is true: a radius the layer grew and the model did not
// would be a map dropping dots that were never covered.
enum VehicleDot {
    /// The radius in points, at the zooms it is stated for. Between them it is
    /// a straight line and outside them it is flat, which is what
    /// `["interpolate", ["linear"], ["zoom"], …]` does.
    static let radii: [(zoom: Double, points: Double)] = [
        (6, 3), (11, 6), (16, 11),
    ]

    /// The zoom a vehicle's line number appears at.
    ///
    /// Also where the thinning stops: below it a vehicle is a dot and nothing
    /// else, so one behind another says nothing that is not already on the map.
    /// From here up every vehicle is handed to the renderer, which keeps all of
    /// the dots but only places the line numbers for which there is room. That
    /// lets a hidden number take the next available position as the map moves,
    /// rather than permanently choosing one service in the feed.
    static let labelMinZoom = 11.0

    /// Past this zoom, the line number comes off the vehicle that is open on
    /// the panel.
    ///
    /// **The one the reader has picked, not only the one the camera is locked
    /// to.** This began as "the followed vehicle", meaning the follow-lock the
    /// camera enters on a second tap — and that is not what it feels like to be
    /// following a train. Tapping one opens its panel and brings the camera to
    /// it, and from then on the reader is watching that vehicle whether or not
    /// the lock was ever engaged. Keyed on the lock, the label stayed put
    /// through the whole of the case it was written for.
    ///
    /// A line number is what you follow a vehicle by when it is a dot among
    /// fifty: it is the only thing on the map that says which of them is the 8.
    /// Open on the panel and zoomed to the length of the train, that question
    /// has been answered — the vehicle in the middle of the screen, named at
    /// the top of the sheet, is plainly the one — and the label is left sitting
    /// on the roof of the thing it names, in the way of the only view that
    /// shows it. Every other vehicle keeps its number at every zoom; those are
    /// the ones still worth telling apart.
    static let labelHideZoom = 16.0

    /// How long the number takes to go, in seconds.
    ///
    /// A threshold crossed on a clock rather than a ramp spread over a zoom
    /// band. The band was the first answer and it is the worse one: it ties how
    /// fast the label goes to how fast the reader happens to be pinching, so a
    /// slow zoom leaves a half-strength number hanging over the train for as
    /// long as the gesture lasts. Crossing the zoom starts a fade of its own
    /// length, and the label is gone half a second later however the crossing
    /// was made.
    static let labelFadeSeconds = 0.5

    /// The layer's own `circle-radius`, with the handover to the drawn vehicle
    /// folded in.
    ///
    /// The shrink multiplies each *stop* rather than the curve as a whole,
    /// which reads worse and is the only form a style accepts: a `zoom`
    /// expression may only be the input to a top-level `step` or `interpolate`,
    /// so wrapping the interpolate in a `*` puts zoom one level down and the
    /// whole style is refused — every layer in it, including the ones already
    /// added. The stops say the same thing.
    static func radiusExpression(shrunkBy shrink: String) -> Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            for stop in radii {
                stop.zoom
                Exp(.product) { stop.points; Exp(.get) { shrink } }
            }
        }
    }

    /// The same curve, evaluated here rather than by the renderer.
    static func radius(atZoom zoom: Double) -> Double {
        guard let first = radii.first, let last = radii.last else { return 0 }
        if zoom <= first.zoom { return first.points }
        if zoom >= last.zoom { return last.points }
        for i in 1..<radii.count where zoom <= radii[i].zoom {
            let low = radii[i - 1], high = radii[i]
            let across = high.zoom - low.zoom
            guard across > 0 else { return high.points }
            return low.points + (high.points - low.points) * (zoom - low.zoom) / across
        }
        return last.points
    }

    /// Yellow fallback markers must read through the cableway structures. A
    /// screen-facing icon supports explicit depth-occlusion visibility, unlike
    /// a ground circle. Only cable traffic uses this lane; the rest of the
    /// nationwide fleet keeps the inexpensive circle layer.
    @MainActor
    static func installCableOverlay(_ style: MapboxMap, source: String) throws {
        let layerID = "\(source)-cable-dot"
        guard !style.layerExists(withId: layerID) else { return }
        let normal = "cable-dot", selected = "cable-dot-selected"
        for (name, active) in [(normal, false), (selected, true)] {
            if !style.imageExists(withId: name) {
                try style.addImage(cableDotImage(selected: active), id: name)
            }
        }
        var layer = SymbolLayer(id: layerID, source: source)
        layer.filter = Exp(.get) { "cableDot" }
        layer.iconImage = .expression(Exp(.switchCase) {
            Exp(.get) { "selected" }; selected; normal
        })
        layer.iconSize = .expression(Exp(.interpolate) {
            Exp(.linear); Exp(.zoom)
            for stop in radii {
                stop.zoom
                Exp(.product) { stop.points / 11; Exp(.get) { "shrink" } }
            }
        })
        layer.iconAllowOverlap = .constant(true)
        layer.iconIgnorePlacement = .constant(true)
        layer.iconPitchAlignment = .constant(.viewport)
        layer.iconRotationAlignment = .constant(.viewport)
        layer.iconOcclusionOpacity = .constant(1)
        layer.iconOpacity = .expression(Exp(.product) {
            Exp(.get) { "fade" }
            Exp(.switchCase) { Exp(.get) { "cancelled" }; 0.35; 1.0 }
        })
        layer.iconOpacityTransition = .zero
        try style.addLayer(layer)
    }

    static func tunnelImageName(_ mode: Mode, selected: Bool) -> String {
        "transit-tunnel-dot-\(mode.rawValue)\(selected ? "-selected" : "")"
    }

    static func tunnelLayers(source: String) -> [String] {
        let base = ["\(source)-tunnel-dot", "\(source)-tunnel-dot-elevated"]
        return base + base.map { $0 + "-selected" }
    }

    /// Only the route owner belongs above the route decorations. Split the
    /// existing surface, cable and tunnel layers without another source upload.
    @MainActor
    static func raiseSelectedOverlays(_ style: MapboxMap, source: String, above anchor: String) throws -> String {
        var topmost = anchor
        for base in ["\(source)-halo", "\(source)-cable-dot"] + Array(tunnelLayers(source: source).prefix(2)) where style.layerExists(withId: base) {
            let id = base + "-selected"
            if !style.layerExists(withId: id) {
                var properties = try style.layerProperties(for: base)
                let filter = properties["filter"] ?? ["literal", true]
                properties["id"] = id
                properties["slot"] = "top"
                properties["filter"] = ["all", filter, ["get", "selected"]]
                try style.addLayer(with: properties, layerPosition: .above(topmost))
                try style.setLayerProperty(for: base, property: "filter",
                                           value: ["all", filter, ["!", ["get", "selected"]]])
            }
            topmost = id
        }
        return topmost
    }

    /// A small, screen-facing marker stays readable through terrain after the
    /// train body disappears. A separate sea-level layer carries known bore
    /// heights; missing terrain data leaves the surface marker in place.
    @MainActor
    static func installTunnelOverlay(_ style: MapboxMap, source: String) throws {
        let id = "\(source)-tunnel-dot"
        guard !style.layerExists(withId: id) else { return }
        for mode in Mode.allCases {
            for selected in [false, true] {
                let name = tunnelImageName(mode, selected: selected)
                if !style.imageExists(withId: name) {
                    try style.addImage(tunnelDotImage(mode, selected: selected), id: name)
                }
            }
        }
        let visible = Exp(.gt) { Exp(.get) { "tunnelFade" }; 0 }
        var dot = SymbolLayer(id: id, source: source)
        dot.filter = visible
        dot.iconImage = .expression(Exp(.get) { "tunnelIcon" })
        dot.iconSize = .constant(1)
        dot.iconAllowOverlap = .constant(true)
        dot.iconIgnorePlacement = .constant(true)
        dot.iconPitchAlignment = .constant(.viewport)
        dot.iconRotationAlignment = .constant(.viewport)
        dot.iconOcclusionOpacity = .constant(1)
        dot.iconOpacity = .expression(Exp(.product) {
            Exp(.get) { "tunnelFade" }
            Exp(.switchCase) { Exp(.get) { "cancelled" }; 0.35; 1.0 }
        })
        dot.iconOpacityTransition = .zero
        try style.addLayer(dot)

        var elevated = dot
        elevated.id = "\(id)-elevated"
        elevated.filter = Exp(.all) { visible; Exp(.get) { "tunnelElevationKnown" } }
        elevated.symbolZElevate = .constant(true)
        do {
            try style.addLayer(elevated)
            try style.setLayerProperty(
                for: elevated.id, property: "symbol-elevation-reference", value: "sea"
            )
            try style.setLayerProperty(
                for: elevated.id, property: "symbol-z-offset", value: ["get", "tunnelAltitude"]
            )
            try style.setLayerProperty(
                for: elevated.id, property: "symbol-z-offset-transition",
                value: ["duration": 0, "delay": 0]
            )
            try style.updateLayer(withId: id, type: SymbolLayer.self) {
                $0.filter = Exp(.all) {
                    visible; Exp(.not) { Exp(.get) { "tunnelElevationKnown" } }
                }
            }
        } catch {
            // Keep the surface layer usable on renderers without elevated symbols.
            if style.layerExists(withId: elevated.id) { try? style.removeLayer(withId: elevated.id) }
            Diagnostics.note("tunnel marker elevation unavailable: \(error)")
        }
    }

    @MainActor
    private static func tunnelDotImage(_ mode: Mode, selected: Bool) -> UIImage {
        let rgb = Palette.components(of: mode.hex) ?? (r: 255, g: 255, b: 255, a: 1)
        let colour = UIColor(
            red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
            blue: CGFloat(rgb.b) / 255, alpha: 1
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18), format: format)
            .image { canvas in
                let context = canvas.cgContext
                context.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
                context.fillEllipse(in: CGRect(x: 1, y: 1, width: 16, height: 16))
                context.setFillColor((selected ? UIColor.systemYellow : UIColor.white).cgColor)
                context.fillEllipse(in: CGRect(x: 2, y: 2, width: 14, height: 14))
                context.setFillColor(colour.cgColor)
                context.fillEllipse(in: CGRect(x: 4, y: 4, width: 10, height: 10))
            }
    }

    @MainActor
    private static func cableDotImage(selected: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format)
            .image { canvas in
                let context = canvas.cgContext
                let radius: CGFloat = 11
                let stroke: CGFloat = selected ? 3 : 1.2
                let outline = selected ? UIColor.white : UIColor.black.withAlphaComponent(0.6)
                context.setFillColor(outline.cgColor)
                context.fillEllipse(in: CGRect(
                    x: 16 - radius - stroke, y: 16 - radius - stroke,
                    width: 2 * (radius + stroke), height: 2 * (radius + stroke)
                ))
                context.setFillColor(UIColor(red: 1, green: 159.0 / 255, blue: 10.0 / 255, alpha: 1).cgColor)
                context.fillEllipse(in: CGRect(x: 5, y: 5, width: 22, height: 22))
            }
    }
}
