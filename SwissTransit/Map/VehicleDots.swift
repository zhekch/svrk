import Foundation
import MapboxMaps

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
    /// else, so one behind another says nothing that is not already on the map;
    /// from here up it carries a number, and a number behind a dot is a service
    /// missing from the map.
    static let labelMinZoom = 11.0

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
}
