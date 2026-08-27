import Foundation

/// One call on a line's own route, as the mapped relation lists it.
///
/// The packed relations carry coordinates and nothing else — no names, no
/// identifiers — so the name here is resolved rather than read: the stop place
/// nearest the mapped node, within a distance that depends on what is running.
/// See `Fleet.routeLine(relationId:)`.
public struct RouteStop: Sendable, Equatable, Identifiable {
    /// Where it comes in the route rather than which stop it is. A route that
    /// loops calls at the same place twice, and those are two rows to read and
    /// two beads to draw, not one listed twice.
    public var id: Int
    public var name: String
    /// The stop place it was resolved to, so opening its board is a lookup by
    /// identity rather than a second search for whatever is nearest.
    public var placeId: String?
    public var lon: Double
    public var lat: Double
    public var rail: Bool

    public init(
        id: Int, name: String, placeId: String?, lon: Double, lat: Double, rail: Bool
    ) {
        self.id = id
        self.name = name
        self.placeId = placeId
        self.lon = lon
        self.lat = lat
        self.rail = rail
    }
}

/// A whole line, from the mapped routes rather than from the feed.
///
/// The counterpart of `ServingLine`, which says only that a line calls here.
/// This is the answer to the obvious next question — *where does it go?* — and
/// it can be given at any hour, because a relation describes the network rather
/// than what happens to be running on it.
public struct RouteLine: Sendable, Identifiable {
    /// The OSM relation, which is one *direction* of a line — and often one
    /// working of it. See the note on `ServingLine`.
    public var id: Int32
    public var ref: String
    public var mode: Mode
    /// The line's name, or where it runs between.
    public var headline: String
    public var operatorName: String?
    public var from: String?
    public var to: String?
    /// In running order, and only those that could be named.
    public var stops: [RouteStop]
    /// The whole line, cut at its own stops, ready for the map's route layer.
    public var geometry: JourneyGeometry?
}

extension RouteLine: Equatable {
    /// On the relation alone.
    ///
    /// For the same reason `TapChoice` compares on its id: this travels as a
    /// `Selection`, which is compared on every write several times a second,
    /// and it carries a polyline of thousands of coordinates. Two values with
    /// the same relation id were built from the same bytes and describe the
    /// same line; walking the coordinates to prove it is work for nothing.
    public static func == (a: RouteLine, b: RouteLine) -> Bool { a.id == b.id }
}

extension RelationStore {
    /// A relation drawn whole: its own path, cut at its own stops.
    ///
    /// The journey builder asks the opposite question — *which relation
    /// describes this run* — and answers it leg by leg, recursing into whatever
    /// a match fails to cover. Here the relation is the question, so there is
    /// nothing to match and nothing to recurse into: project the calls it lists
    /// onto the path it lists, and that is the line.
    ///
    /// `legs[i]` is `-1` for a stop the polyline does not actually reach, which
    /// is a gap in the mapping rather than a reason to draw nothing. The map
    /// skips those beads and draws the line either way.
    public func wholeRoute(of relation: RouteRelation, calls: [Call]) -> JourneyGeometry? {
        let raw = path(of: relation).toArray()
        guard raw.count > 1 else { return nil }
        let (path, cuts) = calls.isEmpty
            ? (raw, [Int?]())
            : projectStops(raw, calls, Mode(osmRoute: relation.route))
        return JourneyGeometry(
            path: path,
            legs: cuts.map { $0 ?? -1 },
            source: .osmRoute,
            mixed: false,
            // Left empty deliberately. Per-leg confidence is a thing a
            // *journey* has, because a journey is stitched from several
            // relations and bare chords between them; a relation is one mapped
            // line throughout, and the map draws it solid on that basis.
            legSources: [],
            relation: relation.id,
            ways: ways(of: relation),
            routeName: relation.name
        )
    }
}

extension Fleet {
    /// How far a mapped stop node may sit from the stop place it belongs to.
    ///
    /// Wider than `servingSpread`, and for a different job. That figure decides
    /// whether a line calls at *this kerb*, where being wrong puts a bus on the
    /// wrong side of the street. This one only puts a name to a node the
    /// relation has already claimed as a call, and the published coordinate of
    /// a station is the centre of the whole thing — several hundred metres from
    /// the platform node at somewhere the size of Bern — so the tight figure
    /// would leave the biggest stations on the route unnamed.
    static func nameReach(for mode: Mode) -> Double {
        RelationStore.projection(for: mode).reject
    }

    /// Which stop place a mapped call belongs to.
    ///
    /// A railway station is asked for as a railway station first, and that is
    /// what the wide radius costs. Nine hundred metres from a platform node in
    /// a city centre reaches a dozen bus kerbs and tram stops with their own
    /// names, and the nearest of them is routinely nearer than the station's
    /// own published point — so an IC's stop list would read out the names of
    /// the streets outside the stations it calls at. Rail first fixes that
    /// wherever the station is registered as one; the short second pass is for
    /// the handful of railway calls that are not, and it is short because
    /// beyond a couple of hundred metres the nearest *anything* is a guess.
    private func namePlace(_ point: Coord, mode: Mode, within reach: Double) -> StopPlace? {
        guard mode == .train else {
            return stopPlaces.nearest(lon: point.lon, lat: point.lat, within: reach)
        }
        return stopPlaces.nearest(lon: point.lon, lat: point.lat, within: reach, matching: \.rail)
            ?? stopPlaces.nearest(lon: point.lon, lat: point.lat, within: Self.unregisteredRailReach)
    }

    /// How far a railway call may be from a stop place that is not marked as a
    /// station and still be it.
    static let unregisteredRailReach = 200.0

    /// One line's whole route: where it goes, in order, and how it is drawn.
    ///
    /// Stops the register cannot name are left out of the list rather than
    /// shown as a blank row — but never out of the *drawing*, which is the
    /// relation's own path from end to end regardless of how much of it could
    /// be labelled.
    public func routeLine(relationId: Int32) -> RouteLine? {
        guard relations.isReady, let relation = relations.relation(id: relationId)
        else { return nil }

        let mode = Mode(osmRoute: relation.route)
        let reach = Self.nameReach(for: mode)

        var stops: [RouteStop] = []
        var calls: [Call] = []
        var previous: String?
        for point in relations.stops(of: relation) {
            guard let place = namePlace(point, mode: mode, within: reach) else { continue }
            // Consecutive only: a station mapped as several nodes is one call,
            // and a loop that comes back to where it started is two.
            if place.id == previous { continue }
            previous = place.id

            stops.append(RouteStop(
                id: stops.count, name: place.name, placeId: place.id,
                // The stop place's own point, because this is what the camera
                // is sent to and what a board is opened at.
                lon: place.lon, lat: place.lat, rail: place.rail
            ))
            // The mapped node, because this is what the path is cut at. A
            // station centre is not on the tracks and would land the cut in a
            // car park.
            calls.append(Call(
                key: "\(relation.id):\(calls.count)", name: place.name,
                lat: point.lat, lon: point.lon, arr: 0, dep: 0
            ))
        }

        return RouteLine(
            id: relation.id,
            ref: relation.ref ?? "",
            mode: mode,
            headline: relation.name ?? "\(relation.from ?? "?") → \(relation.to ?? "?")",
            operatorName: relation.operatorName,
            from: relation.from,
            to: relation.to,
            stops: stops,
            geometry: relations.wholeRoute(of: relation, calls: calls)
        )
    }
}
