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

/// A whole route, from a mapped relation or a station-board service.
///
/// The counterpart of `ServingLine`, which says only that a line calls here.
/// This is the answer to the obvious next question — *where does it go?* — and
/// it can be given at any hour, because a relation describes the network rather
/// than what happens to be running on it.
public struct RouteLine: Sendable, Identifiable {
    public enum ID: Sendable, Hashable {
        case relation(Int32)
        case service(String, Timestamp)
    }
    public var id: ID
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

extension RouteLine {
    /// Keep station identity and repeated calls on loops while presenting a
    /// service as a route without its live timing or vehicle position.
    public init(entry: BoardEntry, calls: [Call], geometry: JourneyGeometry?) {
        let publicCalls = calls.filter { !StopNaming.isTechnical($0.name) }
        let stops = publicCalls.enumerated().map { index, call in
            RouteStop(id: index, name: StopNaming.display(call.name),
                      placeId: call.ref.map { StopRegister.stationOf($0) },
                      lon: call.lon, lat: call.lat, rail: entry.mode == .train || entry.mode == .metro)
        }
        self.init(id: .service(entry.id, entry.departure), ref: entry.line, mode: entry.mode,
                  headline: entry.to ?? "", operatorName: nil,
                  from: stops.first?.name ?? entry.from, to: stops.last?.name ?? entry.to,
                  stops: stops, geometry: geometry)
    }
}

extension RouteLine: Equatable {
    /// On route identity alone, including the occurrence for a board service.
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
        let raw = pathCoords(of: relation)
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
        if let place = stopPlaces.nearest(lon: point.lon, lat: point.lat, within: reach, matching: \.rail)
            ?? stopPlaces.nearest(lon: point.lon, lat: point.lat, within: Self.unregisteredRailReach) {
            return place
        }
        return register.nearestForeign(lon: point.lon, lat: point.lat, within: reach)
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

        let points = relations.stopCoords(of: relation)
        let overlayNames = relations.overlay(id: relation.id)?.stopNames ?? []
        var stops: [RouteStop] = []
        var calls: [Call] = []
        var previous: String?
        for (index, point) in points.enumerated() {
            let named = overlayNames.indices.contains(index) ? overlayNames[index] : nil
            let place = namePlace(point, mode: mode, within: reach)
            let name = StopNaming.display(place?.name ?? named ?? "")
            guard !name.isEmpty else { continue }
            let identity = place?.id ?? name
            // Consecutive only: a station mapped as several nodes is one call,
            // and a loop that comes back to where it started is two.
            if identity == previous { continue }
            previous = identity

            stops.append(RouteStop(
                id: stops.count, name: name, placeId: place?.id,
                lon: place?.lon ?? point.lon, lat: place?.lat ?? point.lat,
                rail: place?.rail ?? (mode == .train)
            ))
            calls.append(Call(
                key: "\(relation.id):\(calls.count)", name: name,
                lat: point.lat, lon: point.lon, arr: 0, dep: 0
            ))
        }

        return RouteLine(
            id: .relation(relation.id),
            ref: relation.ref ?? "",
            mode: mode,
            headline: RouteNaming.headline(
                name: relation.name, from: relation.from, to: relation.to
            ) ?? "",
            operatorName: relation.operatorName,
            from: relation.from.map(StopNaming.display),
            to: relation.to.map(StopNaming.display),
            stops: stops,
            geometry: relations.wholeRoute(of: relation, calls: calls)
        )
    }

    /// Prefer a timetable working of this line when the mapped relation only
    /// named a stub — ICE 60 clipped to Basel Bad and Müllheim.
    public func enrichRouteLine(_ line: RouteLine, at now: Timestamp) -> RouteLine {
        var line = line
        line.headline = StopNaming.displayRoute(line.headline)
        line.from = line.from.map(StopNaming.display)
        line.to = line.to.map(StopNaming.display)
        line.stops = line.stops.map { stop in
            var stop = stop
            stop.name = StopNaming.display(stop.name)
            return stop
        }
        guard line.mode == .train, line.stops.count < 4 else { return line }

        let wanted = RelationStore.normaliseRef(line.ref)
        guard !wanted.isEmpty else { return line }

        var extra: [Journey] = []
        for placeId in line.stops.prefix(2).compactMap(\.placeId) {
            var keys: Set<String> = [placeId]
            if let sloid = StopRegister.sloid(forDidok: placeId) { keys.insert(sloid) }
            if let didok = StopRegister.didok(forSloid: placeId) { keys.insert(didok) }
            extra.append(contentsOf: scheduled(at: keys, from: now, filling: 0, of: 80))
        }
        extra.append(contentsOf: callers(matchingAnyOf: [line.ref]))
        extra.append(contentsOf: boardFillJourneys().filter { Self.lineMatches($0, wanted: wanted) })

        let matching = extra.filter { Self.lineMatches($0, wanted: wanted) }
        guard let best = matching.max(by: { $0.stops.count < $1.stops.count }),
              best.stops.count > line.stops.count
        else { return line }

        var stops: [RouteStop] = []
        var previous: String?
        for call in best.stops {
            let name = StopNaming.display(call.name)
            guard !name.isEmpty else { continue }
            let placeId = call.ref.map {
                StopRegister.didok(forSloid: $0) ?? StopRegister.stationOf($0)
            }
            let identity = placeId ?? name
            if identity == previous { continue }
            previous = identity
            stops.append(RouteStop(
                id: stops.count, name: name, placeId: placeId,
                lon: call.lon, lat: call.lat, rail: true
            ))
        }
        if stops.count > line.stops.count { line.stops = stops }
        return line
    }

    static func lineMatches(_ journey: Journey, wanted: String) -> Bool {
        guard !wanted.isEmpty else { return false }
        let line = RelationStore.normaliseRef(journey.line)
        if line == wanted { return true }
        let cat = RelationStore.normaliseRef(journey.category)
        let num = RelationStore.normaliseRef(journey.number)
        if !cat.isEmpty, wanted.hasPrefix(cat) {
            let rest = String(wanted.dropFirst(cat.count))
            if rest == num || rest == line { return true }
        }
        let catNum = cat + num
        return !catNum.isEmpty && catNum == wanted
    }
}
