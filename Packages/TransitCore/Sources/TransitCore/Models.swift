import Foundation

/// Unix seconds. The whole app works in these; only the formatters care about
/// calendars.
public typealias Timestamp = Int

/// One call at one stop, with the best time known for each half of it.
///
/// Switzerland does not publish live GPS positions, so a journey is a *timed
/// polyline*: this list, plus interpolation between consecutive entries. Every
/// position the map draws comes from here.
public struct Call: Sendable, Codable, Equatable {
    /// A repeat visit on a looping route is a different call at the same stop,
    /// so the visit number is part of a call's identity — not just the ref.
    public var key: String
    /// The SLOID. Identifies the *platform*, not just the station, which is
    /// what lets a click on one platform be answered with the services that
    /// actually call there rather than everything at the station.
    public var ref: String?
    public var name: String
    public var lat: Double
    public var lon: Double
    public var platform: String?
    /// Whether `lat`/`lon` is the platform's own coordinate rather than the
    /// station's. A vehicle may be stood on a platform we can place; standing
    /// it on a station centre is what put a train booked for Bern 12 on Bern 4.
    public var precise: Bool
    /// A terminus has no departure and an origin no arrival; both are filled so
    /// the interpolator never has to special-case the ends.
    public var arr: Timestamp
    public var dep: Timestamp
    public var delay: Int?
    /// Whether this call is a measurement or a forecast — the honest
    /// distinction SIRI-ET lets the app draw for the first time.
    public var observed: Bool
    public var note: String?
    /// The printed time, before any delay is applied. Never drawn: it is what
    /// tells two runs of a reused trip number apart, which a delayed live time
    /// cannot do because it moves between one poll and the next.
    public var sched: Timestamp?
    /// The letter this app assigned to an unsigned kerb. Kept apart from
    /// `platform` so nothing that matches a reported platform against the
    /// register can ever match against a letter we invented.
    public var assigned: String?
    /// Whether the operator has withdrawn *this call* from a journey that is
    /// otherwise running — the vehicle passes the stop without serving it.
    ///
    /// Distinct from `Journey.cancelled`, which is the whole run called off. A
    /// national snapshot carries about 220 of these against 90 of those, and
    /// conflating them deletes 167 running vehicles from the map.
    ///
    /// The call is kept in the list rather than removed. The vehicle really
    /// does pass this point, so it is still a waypoint the geometry is built
    /// from and still the thing `legs` is indexed against; what it is not is a
    /// stop anybody can board at.
    public var cancelled: Bool
    /// Whether this call is not in the printed timetable — a stop added to the
    /// run today, which is how a diversion or a replacement routing is filed.
    ///
    /// Rarely one stop on its own: of the 147 journeys carrying any, most are
    /// diversions in which nearly every call is added.
    public var extra: Bool

    public init(
        key: String,
        ref: String? = nil,
        name: String,
        lat: Double,
        lon: Double,
        platform: String? = nil,
        precise: Bool = false,
        arr: Timestamp,
        dep: Timestamp,
        delay: Int? = nil,
        observed: Bool = false,
        note: String? = nil,
        sched: Timestamp? = nil,
        assigned: String? = nil,
        cancelled: Bool = false,
        extra: Bool = false
    ) {
        self.key = key
        self.ref = ref
        self.name = name
        self.lat = lat
        self.lon = lon
        self.platform = platform
        self.precise = precise
        self.arr = arr
        self.dep = dep
        self.delay = delay
        self.observed = observed
        self.note = note
        self.sched = sched
        self.assigned = assigned
        self.cancelled = cancelled
        self.extra = extra
    }

    public var coord: Coord { Coord(lon: lon, lat: lat) }
}

/// Where a leg's drawn geometry came from, per leg.
///
/// Kept per leg rather than per journey because a night train has real mapped
/// track through Switzerland and nothing at all across Germany — drawn as one
/// confident white line, the 300 km guess between Bonn and Offenburg looked
/// exactly like the rails it really follows.
public enum LegSource: String, Sendable, Codable {
    /// An OSM route relation states the ways this line uses.
    case route
    /// Routed over the OSM railway graph. Inference, and the panel says so.
    case graph
    /// The straight line between two stops. A guess, drawn dashed.
    case chord
}

/// How a journey's geometry was chiefly obtained.
public enum GeometrySource: String, Sendable, Codable {
    case osmRoute = "osm-route"
    case railGraph = "rail-graph"
    case straight
}

/// One numbered leg of a physically-continuous run.
///
/// A Swiss service often changes trip number partway — an S1 is renumbered at
/// Gümligen — and the feed files each number as its own journey. Chaining joins
/// them; this records where the seams were, so the panel can show the
/// renumbering rather than hide it, and so each leg can be matched to its own
/// route relation.
public struct JourneyPart: Sendable, Codable, Equatable {
    public var id: String
    /// The constituent run's `Journey.journeyRef`, carried for the same reason
    /// the snapshot carries one: a leg is what the formation service is asked
    /// about, and `id` is a row number for anything the timetable produced.
    public var journeyRef: String?
    public var line: String
    public var number: String?
    public var category: String?
    public var operatorName: String?
    public var mode: Mode
    public var to: String?
    public var from: String
    public var start: Int
    public var end: Int

    public init(
        id: String, line: String, number: String?, category: String?,
        operatorName: String?, mode: Mode, to: String?, from: String,
        start: Int, end: Int, journeyRef: String? = nil
    ) {
        self.id = id
        self.journeyRef = journeyRef
        self.line = line
        self.number = number
        self.category = category
        self.operatorName = operatorName
        self.mode = mode
        self.to = to
        self.from = from
        self.start = start
        self.end = end
    }
}

/// The geometry attached to a journey once it has been routed.
public struct JourneyGeometry: Sendable, Codable, Equatable {
    /// One flat polyline for the whole run.
    public var path: [Coord]
    /// `legs[i]` is the index in `path` where stop `i` sits. One entry per
    /// stop, which is also what makes a stale geometry detectable: a length
    /// mismatch is proof it was built for an earlier, shorter stop list.
    public var legs: [Int]
    public var source: GeometrySource
    public var mixed: Bool
    public var legSources: [LegSource]
    public var relation: Int32?
    public var ways: [Int64]
    public var routeName: String?
    /// Track leading *into* the first stop, nearest-first, and nothing to do
    /// with where the vehicle goes.
    ///
    /// `path` starts at stop 0, so a vehicle standing there has no line behind
    /// it to lay its body along — and a two-hundred-metre train has to be
    /// somewhere. Drawn without this, the whole body ran out along the bearing
    /// of the route's first segment: straight through the trackwork at a
    /// curved platform, and out across the pavement at a tram terminus whose
    /// first two vertices happen to point somewhere the tram has never been.
    ///
    /// Kept apart from `path` deliberately. The path is the journey, and it is
    /// what the panel highlights and what positions are interpolated along;
    /// splicing a run-up onto the front of it would draw four hundred metres of
    /// route the service does not run and shift every index in `legs`.
    public var approach: [Coord]
    /// Whether the path has been bent onto booked platforms and had its gaps
    /// filled from the rail graph.
    ///
    /// A first attach from the OSM relation alone puts a train on its corridor
    /// — off the chord, on the rails — and is cheap enough to do for every
    /// train in view. The slower pass then walks the throats. False until that
    /// pass has run, so the draw loop can tell a corridor path from a finished
    /// one without rebuilding it to find out.
    public var refined: Bool

    public init(
        path: [Coord], legs: [Int], source: GeometrySource, mixed: Bool,
        legSources: [LegSource], relation: Int32?, ways: [Int64], routeName: String?,
        approach: [Coord] = [], refined: Bool = true
    ) {
        self.path = path
        self.legs = legs
        self.source = source
        self.mixed = mixed
        self.legSources = legSources
        self.relation = relation
        self.ways = ways
        self.routeName = routeName
        self.approach = approach
        self.refined = refined
    }
}

/// A vehicle that has arrived and is not leaving yet.
///
/// The feed files a turnback as two journeys — an IR35 reaches Bern at 13:21
/// and an IR35 leaves Bern at 13:39 — and nothing in it says they are one
/// train. Chaining will not join them, and should not: their stop lists run
/// out and back, so a joined run would draw the whole line twice. But the
/// train is still standing on platform 50 for those eighteen minutes, and a
/// map that removes it the moment it arrives is wrong about the one thing
/// anybody standing on that platform can see.
public struct Layover: Sendable, Codable, Equatable {
    /// The last moment this vehicle is still on its platform.
    public var until: Timestamp
    /// The working that takes the platform next, which is this train under a
    /// new number as far as the evidence goes.
    public var line: String?
    public var to: String?
    public var id: String?

    public init(until: Timestamp, line: String? = nil, to: String? = nil, id: String? = nil) {
        self.until = until
        self.line = line
        self.to = to
        self.id = id
    }
}

/// One vehicle's run: a timed stop list, plus whatever geometry has been
/// attached to it.
///
/// A reference type, as in the original. The fleet mutates journeys in place —
/// splicing a fresh sighting into a stored one, attaching geometry lazily on
/// first use — and every one of those operations is "the thing already in the
/// store, now knowing more". Copying instead would mean writing the copy back
/// everywhere, which is exactly the bug class the original avoided by never
/// having two of them.
public final class Journey: @unchecked Sendable {
    public var id: String
    public var mode: Mode
    public var category: String?
    public var line: String
    public var number: String?
    public var operatorName: String?
    public var operatorFull: String?
    public var to: String?
    public var from: String
    public var delay: Int?
    public var start: Timestamp
    public var end: Timestamp
    /// Whether the source states this really is the whole run. SIRI-ET almost
    /// always does, and saying so is what lets the panel stop hedging about
    /// where a vehicle started.
    public var complete: Bool
    public var monitored: Bool
    /// The whole run called off. Distinct from a cancelled *call*; see
    /// `Call.cancelled`.
    public var cancelled: Bool
    /// A run that is not in the timetable at all — a relief working, or a
    /// replacement filed for one that was cancelled. 184 in a national
    /// snapshot, and worth saying out loud: a train nobody can look up is
    /// exactly the one a passenger doubts.
    public var extra: Bool
    public var source: String
    /// The reference OJP will answer to for this run, where there is one.
    ///
    /// Deliberately not `id`. A journey needs two different things from an
    /// identifier and the feeds do not supply one value that is both: `id` has
    /// to be unique so the fleet can key a store on it, and this has to be the
    /// string the *upstream* system knows the run by so a delay can be asked
    /// for. For a SIRI journey they coincide and this stays nil. For a
    /// timetabled one they cannot: measured on a single weekday, 20.7% of the
    /// day's 215,943 trips carry no journey reference at all, and 161 of the
    /// references that do exist are used by more than one trip on that same day
    /// — so a store keyed on them would silently lose 25,514 runs.
    ///
    /// Nil means "there is no way to ask about this one", which is a fact worth
    /// carrying: the tap-for-delays path has to omit itself rather than send a
    /// reference that will come back empty.
    public var journeyRef: String?
    public var stops: [Call]
    public var parts: [JourneyPart]?

    /// Set by `Chains.build` where a terminating vehicle is still holding its
    /// platform for a later departure. Nil for a run that simply ends.
    public var layover: Layover?

    /// The last moment some *other* vehicle is standing on the platform this
    /// one starts from — the mirror of `layover`, written onto the working that
    /// takes the track next.
    ///
    /// It exists so a departure can be drawn a few minutes before it leaves
    /// without ever putting two dots on one platform: where the train is
    /// already on the map as the working that brought it in, the early
    /// appearance is simply skipped. See `Positioning.preDepartureLead`.
    public var heldUntil: Timestamp?

    /// Where the last position query found this vehicle.
    ///
    /// Not state, a hint. `Positioning.position` used to scan a journey's whole
    /// call list from the beginning on every frame, which for a national fleet
    /// is a hundred thousand iterations and — because each one copied a `Call`,
    /// six reference-counted strings and all — a great deal more retain traffic
    /// than arithmetic. Time only ever moves a little between frames, so the
    /// answer is almost always the same call as last time or the one after it.
    /// Checked before the scan and discarded when wrong, so scrubbing the clock
    /// across an hour is exactly as correct as it was, just no faster.
    public var searchHint: Int = 0

    /// A re-time still being walked off, so live times land as a glide rather
    /// than as a jump.
    ///
    /// The reason this exists: the map draws a vehicle where the *timetable*
    /// puts it, and the live times that say where it really is arrive later —
    /// from a GTFS-RT tick, from the OJP sweep, or from opening the vehicle.
    /// A run a minute down is a minute of track behind the plan, so the fold
    /// that corrects it moved the vehicle up to a couple of kilometres in one
    /// frame. That is the "it teleports back the moment you tap it" the reader
    /// sees, and it is the correction being right rather than anything being
    /// wrong.
    ///
    /// So the correction is kept and spent over the next fraction of a second
    /// instead of all at once. Held in *seconds of this journey's own
    /// schedule* rather than in metres: a shift in the timetable is exactly
    /// what a re-time is, so winding the clock forward by it reproduces the
    /// old position precisely, and letting that wind-forward decay to zero
    /// walks the vehicle along its own path to the new one. It cannot leave
    /// the rails, cannot overshoot, and needs nothing from the geometry.
    public var settle: Settle?

    /// A correction in flight. See `Journey.settle`.
    public struct Settle: Sendable, Equatable {
        /// How far the fold moved this journey's times, in seconds. Positive
        /// where the run got later, which is the ordinary case and the one
        /// that moves the vehicle backwards.
        public var seconds: Double
        /// Unix time the correction landed.
        public var from: Double
        /// How long the glide lasts.
        public var over: Double

        public init(seconds: Double, from: Double, over: Double) {
            self.seconds = seconds
            self.from = from
            self.over = over
        }
    }

    /// Set by `GeometryBuilder.attach`. Nil until the first time anything asks
    /// where this journey physically goes.
    public var geometry: JourneyGeometry? { didSet { drawnBox = nil } }
    public var legsFromRoute: Int = 0
    public var legsFromGraph: Int = 0

    public init(
        id: String, mode: Mode, category: String?, line: String, number: String?,
        operatorName: String?, operatorFull: String?, to: String?, from: String,
        delay: Int?, start: Timestamp, end: Timestamp, complete: Bool,
        monitored: Bool, cancelled: Bool, source: String, stops: [Call],
        parts: [JourneyPart]? = nil, extra: Bool = false, journeyRef: String? = nil
    ) {
        self.journeyRef = journeyRef
        self.id = id
        self.mode = mode
        self.category = category
        self.line = line
        self.number = number
        self.operatorName = operatorName
        self.operatorFull = operatorFull
        self.to = to
        self.from = from
        self.delay = delay
        self.start = start
        self.end = end
        self.complete = complete
        self.monitored = monitored
        self.cancelled = cancelled
        self.extra = extra
        self.source = source
        self.stops = stops
        self.parts = parts
    }

    // MARK: - Where this journey can be drawn

    /// The box holding every point this journey's vehicle can be drawn at.
    ///
    /// **This is what keeps a close-in frame from costing what the country
    /// costs.** `Fleet.vehicles` used to answer "who is in this viewport" by
    /// asking every running journey where it was — a walk into a call list and,
    /// for a train, an interpolation along an attached path — and then throwing
    /// away all but the forty on screen. At zoom 18 that is the national
    /// timetable evaluated thirty times a second to move four dozen trams a few
    /// centimetres.
    ///
    /// **Exact, with no margin to argue about.** A vehicle with no path is
    /// drawn by interpolating between two consecutive call coordinates, so the
    /// calls' own box holds it and holds it precisely. A vehicle *with* a path
    /// is drawn on that path, which can leave its calls by a very long way —
    /// measured at 38 km on the Hamburg night train, whose Swiss calls are the
    /// last few of an international run — so the path is taken in too. Between
    /// them there is no case left where a fixed slack would have to be guessed
    /// at, and none where the filter can drop somebody.
    ///
    /// **Two caches, because the halves go stale at completely different
    /// rates.** The calls' box is settled the moment a journey is built: the
    /// live feeds re-time a call, cancel it and re-platform it, and none of
    /// that touches where it is, so that half is worked out once and kept for
    /// the life of the object. The path arrives later and is refined later
    /// still, so the union is dropped whenever it changes — but only the union,
    /// and only for the one journey whose path moved.
    ///
    /// Getting that split wrong is what made the first version of this *worse*
    /// than what it replaced: one box over both halves, rebuilt from every
    /// vertex of every route each time any path was attached, and worked out
    /// before the cheap "is it even running" test rather than after it. On a
    /// national fleet that is a stall of a few hundred milliseconds arriving
    /// several times a minute, which is a map at one frame a second.
    private var callHull: BBox?
    private var drawnBox: BBox?

    /// Everywhere this journey's vehicle can be drawn.
    ///
    /// `nil` where there is nothing to draw — a journey needs two calls to have
    /// a position between them. Ask it *after* deciding the journey is running;
    /// there is no reason to box one that is not.
    public func drawnWithin() -> BBox? {
        if let drawnBox { return drawnBox }
        guard let hull = callHull ?? measuredHull() else { return nil }
        var west = hull.west, south = hull.south, east = hull.east, north = hull.north
        if let geometry {
            @inline(__always) func take(_ point: Coord) {
                if point.lon < west { west = point.lon }
                if point.lon > east { east = point.lon }
                if point.lat < south { south = point.lat }
                if point.lat > north { north = point.lat }
            }
            for point in geometry.path { take(point) }
            for point in geometry.approach { take(point) }
        }
        // A metre, for arithmetic rather than for doubt: every way a position
        // can be produced lands on one of the points just taken in.
        let box = BBox(west: west, south: south, east: east, north: north)
            .padded(byMetres: 1)
        drawnBox = box
        return box
    }

    /// The box the calls alone describe, worked out once and kept.
    private func measuredHull() -> BBox? {
        guard stops.count >= 2 else { return nil }
        var west = Double.greatestFiniteMagnitude
        var south = Double.greatestFiniteMagnitude
        var east = -Double.greatestFiniteMagnitude
        var north = -Double.greatestFiniteMagnitude
        // Read a field at a time rather than binding `let stop = stops[i]`,
        // for the reason `Positioning.answer` gives: the binding copies the
        // whole `Call`, which is six reference-counted strings, and this walks
        // every call of every running journey.
        for index in stops.indices {
            let lon = stops[index].lon, lat = stops[index].lat
            if lon < west { west = lon }
            if lon > east { east = lon }
            if lat < south { south = lat }
            if lat > north { north = lat }
        }
        guard west <= east, south <= north else { return nil }
        let hull = BBox(west: west, south: south, east: east, north: north)
        callHull = hull
        return hull
    }

    /// Discard geometry built for a stop list this journey no longer has.
    public func invalidateGeometry() {
        geometry = nil
        legsFromRoute = 0
        legsFromGraph = 0
    }
}
