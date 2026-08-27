import Foundation

/// Which side of a vehicle its platform lies on at a call.
///
/// The one thing a passenger standing in a corridor wants to know and no feed
/// publishes: it is not in the timetable, not in SIRI, and not on the ticket.
/// It is, however, a fact about geometry — the platform is beside the track,
/// and the track has a direction of travel — so it can be worked out from the
/// line this app already draws.
public enum PlatformSide: String, Sendable, Equatable, Codable {
    case left, right
}

extension Positioning {
    /// How far back along the path to look for the direction of travel.
    ///
    /// Long enough to ignore the wobble of a single 2 m vertex and short enough
    /// that a curve into the station does not average the approach away.
    static let sideHeadingMetres = 25.0

    /// The smallest offset from the track worth calling a side at all.
    ///
    /// A platform edge stands about 1.7 m from the axis of the track it serves —
    /// that is the clearance, and it is what the register's platform points
    /// measure out at against the drawn rails: over the packed data their offset
    /// clusters at 1.8 m with a half-metre spread either side. A cluster that
    /// tight *is* the evidence that both coordinates are good, because random
    /// error of a metre in the rail geometry would smear it across zero. So the
    /// floor sits just under that cluster: below 1.2 m the offset is no longer
    /// distinguishable from the error in the two positions being subtracted, and
    /// a side is a coin toss printed as a fact.
    static let sideOffsetMetres = 1.2

    /// How much of that offset has to be *sideways*.
    ///
    /// The platform must be beside the track rather than ahead of it. At a
    /// terminus the stop coordinate sits past the buffer stops, roughly in line
    /// with the rail, and the sign of a cross product there is noise. Both tests
    /// have to pass — an absolute floor, because a few centimetres of
    /// perpendicular is not evidence at any angle, and a ratio, because a metre
    /// sideways out of three hundred ahead is not either.
    static let sidePerpendicularMetres = 1.0
    static let sideSquareness = 0.5

    /// Which side the platform at call `index` is on, from the vehicle's own
    /// direction of travel.
    ///
    /// `legs[index]` is where the vehicle physically stands: the point on the
    /// drawn line nearest the platform, and after the approach is bent onto the
    /// booked track, the foot of the perpendicular from it. So the vector from
    /// there to the platform's own coordinate is the width of the platform,
    /// square to the rails, and its sign against the heading is the answer.
    ///
    /// Declines rather than guesses. Only a call whose coordinate is the
    /// platform's own can be asked — a station centre is not a platform, and at
    /// Bern it sits a hundred metres from every track in use, so a side computed
    /// from one would be invented.
    public static func platformSide(
        path: [Coord], legs: [Int], stops: [Call], index: Int
    ) -> PlatformSide? {
        guard legs.count == stops.count, index >= 0, index < stops.count else { return nil }
        let stop = stops[index]
        guard stop.precise else { return nil }
        let at = legs[index]
        guard at >= 0, at < path.count else { return nil }
        let anchor = path[at]

        // Metres east and north, so a cross product means what it says. A degree
        // of longitude is shorter than one of latitude everywhere but the
        // equator, and without the scale a platform due east of the track reads
        // as further out than it is — which changes no sign, but does change
        // whether the squareness test passes.
        let scale = cos(Geo.toRad(anchor.lat))
        func vector(_ a: Coord, _ b: Coord) -> (x: Double, y: Double) {
            ((b.lon - a.lon) * scale * Geo.metresPerDegree, (b.lat - a.lat) * Geo.metresPerDegree)
        }

        // Which way the vehicle is facing here: back along the way it came, and
        // forward at the origin, which has nothing behind it.
        let heading: (x: Double, y: Double)
        if let behind = walk(path, from: at, step: -1, metres: sideHeadingMetres) {
            heading = vector(behind, anchor)
        } else if let ahead = walk(path, from: at, step: 1, metres: sideHeadingMetres) {
            heading = vector(anchor, ahead)
        } else {
            return nil
        }
        let length = hypot(heading.x, heading.y)
        guard length > 1 else { return nil }

        let offset = vector(anchor, stop.coord)
        let distance = hypot(offset.x, offset.y)
        guard distance >= sideOffsetMetres else { return nil }

        // Positive is counter-clockwise from the heading, and east-north is a
        // right-handed frame, so positive is to the left.
        let cross = (heading.x * offset.y - heading.y * offset.x) / length
        guard abs(cross) >= sidePerpendicularMetres,
              abs(cross) / distance >= sideSquareness
        else { return nil }
        return cross > 0 ? .left : .right
    }

    /// The point `metres` along the path from `index`, or as far as the path
    /// goes. Nil only where it cannot move at all.
    private static func walk(_ path: [Coord], from index: Int, step: Int, metres: Double) -> Coord? {
        var travelled = 0.0
        var i = index
        while travelled < metres {
            let next = i + step
            guard next >= 0, next < path.count else { break }
            travelled += Geo.metres(path[i], path[next])
            i = next
        }
        return i == index ? nil : path[i]
    }
}

extension VehicleSnapshot {
    /// The modes where the side is a real question with a checkable answer.
    ///
    /// A Swiss bus or tram has doors down one side and stops at the kerb, so the
    /// answer is "right" every time and saying so tells nobody anything. It is
    /// also, measurably, where the geometry stops holding up: over the packed
    /// data the rule calls 12% of bus calls and 26% of tram calls to the left,
    /// and a vehicle whose doors are on the right cannot be boarded from the
    /// left. That is the error rate, printed as confidence. A train is the case
    /// this is for — it runs on its own alignment, its platforms are genuinely
    /// on both sides (64% left over the same data, which is what left-hand
    /// running looks like), and the answer stands up against OpenStreetMap's
    /// own footprints.
    static let sidedModes: Set<Mode> = [.train, .metro]

    /// Which side of this vehicle the platform at call `index` is on.
    ///
    /// Guarded on the geometry still describing *this* stop list, the same test
    /// `Positioning.usableGeometry` makes: one index per stop, or the answer is
    /// about a journey that has since been replaced.
    public func platformSide(at index: Int) -> PlatformSide? {
        guard Self.sidedModes.contains(mode) else { return nil }
        guard let geometry, !geometry.path.isEmpty, geometry.legs.count == stops.count
        else { return nil }
        return Positioning.platformSide(
            path: geometry.path, legs: geometry.legs, stops: stops, index: index
        )
    }
}
