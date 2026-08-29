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
}
