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
    /// Immutable booked arrival, used when a later feed reports only a delay.
    public var scheduledArrival: Timestamp?
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
        extra: Bool = false,
        scheduledArrival: Timestamp? = nil
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
        self.scheduledArrival = scheduledArrival ?? (delay == nil || delay == 0 ? arr : nil)
        self.assigned = assigned
        self.cancelled = cancelled
        self.extra = extra
    }

    public var coord: Coord { Coord(lon: lon, lat: lat) }

    /// `(0, 0)` is how an unplaced call is written. It is not a stop.
    public var isPlaced: Bool { lat != 0 || lon != 0 }

    /// Departure the passenger should plan for. `dep` is already the live time
    /// when a stop-time update has been folded in.
    public var expectedDeparture: Timestamp { dep }

    /// Arrival has already been normalised at ingestion. Guessing another
    /// delay here makes the card disagree with the map, especially at dwells.
    public var expectedArrival: Timestamp { min(arr, dep) }

    /// Clock time the next-stop line should share with the call list.
    ///
    /// A halt of two minutes or less is printed as one time down the list —
    /// the departure. Naming a different arrival beside it reads as if the
    /// delay was ignored.
    public var displayedArrival: Timestamp {
        dep - arr <= 120 ? expectedDeparture : expectedArrival
    }
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

    /// Nothing on the packed Swiss network described this run, so the path is
    /// still the chord between stops. That is the case worth asking Overpass
    /// about — see `OSMRouteClient`.
    public var isUnmapped: Bool {
        source == .straight
            || (!legSources.isEmpty && legSources.allSatisfy { $0 == .chord })
    }

    /// At least one stop-to-stop hop is still a chord, so a selected vehicle
    /// is worth an Overpass lookup even when the Swiss legs already routed.
    public var hasUnmappedLeg: Bool {
        source == .straight || legSources.contains(.chord)
    }

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
    /// A detached portion is already present when its sibling departs, even
    /// if its own departure is later than the normal pre-departure window.
    public var splitAppearance: Timestamp?
    /// Published departing portions of a split; rebuilt with the physical fleet.
    public var splitContinuations: [String] = []

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
    /// Small backward corrections are absorbed by slowing progress until the
    /// updated timetable catches up. Substantial changes still settle briefly
    /// so the marker does not conceal a real delay. The correction is held in
    /// seconds of this journey's schedule: winding its clock reproduces the
    /// previously drawn position without moving the vehicle off its rails.
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
        /// Near the next arrival, a linear clock correction can finish on
        /// time without briefly running the displayed clock backwards.
        public var linear: Bool

        public init(seconds: Double, from: Double, over: Double, linear: Bool = false) {
            self.seconds = seconds
            self.from = from
            self.over = over
            self.linear = linear
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
            guard stops[index].isPlaced else { continue }
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
        callHull = nil
        drawnBox = nil
    }

    /// Fold calls the packed timetable omitted onto either end of the run.
    ///
    /// Swiss GTFS cuts international trains at the border. OJP still publishes
    /// the rest: Milano *before* Domodossola on a northbound EC, Stresa and
    /// Milano *after* it on a southbound one. The old join only adopted a
    /// tail, so opening EC 66 never showed where it had come from.
    @discardableResult
    public func absorb(extras: [Call], resolve: (String, String?) -> Place?) -> Bool {
        guard !extras.isEmpty, !stops.isEmpty else { return false }

        var unique: [Call] = []
        for extra in extras {
            if unique.contains(where: {
                Self.sameListedStop($0, extra) && abs($0.dep - extra.dep) < 180
            }) { continue }
            unique.append(extra)
        }
        guard !unique.isEmpty else { return false }

        func placed(_ extra: Call) -> Call? {
            var call = extra
            call.name = StopNaming.display(extra.name)
            if let ref = extra.ref, let place = resolve(ref, extra.platform),
               place.lat != 0 || place.lon != 0 {
                call.lat = place.lat
                call.lon = place.lon
                if call.name.isEmpty || call.name == ref {
                    call.name = StopNaming.display(place.name)
                }
                call.platform = extra.platform ?? place.platform
                call.precise = place.precise
                call.assigned = place.assigned
            }
            // OJP TripInfo and formation lists mint extras at `(0, 0)` and
            // ask the register to fill them in. A miss used to keep the
            // sentinel, and GeometryBuilder then drew a chord through the
            // Gulf of Guinea — the 40,000 km/h meridian on a selected IC.
            guard call.isPlaced else { return nil }
            return call
        }

        var grew = false
        if let first = stops.first,
           let at = unique.firstIndex(where: { Self.sameListedStop(first, $0) }),
           at > unique.startIndex {
            let head = unique[unique.startIndex..<at].compactMap(placed)
            if !head.isEmpty {
                stops.insert(contentsOf: head, at: 0)
                if let newFirst = stops.first {
                    from = newFirst.name
                    start = newFirst.dep
                }
                if var parts {
                    let n = head.count
                    for i in parts.indices {
                        parts[i].start += n
                        parts[i].end += n
                    }
                    parts[0].start = 0
                    parts[0].from = stops.first?.name ?? parts[0].from
                    self.parts = parts
                }
                grew = true
            }
        }

        if let last = stops.last,
           let at = unique.lastIndex(where: { Self.sameListedStop(last, $0) }),
           unique.index(after: at) < unique.endIndex {
            let tail = unique[unique.index(after: at)...].compactMap(placed)
            if !tail.isEmpty {
                stops.append(contentsOf: tail)
                if let newLast = stops.last {
                    to = newLast.name
                    end = newLast.arr
                }
                if var parts, let index = parts.indices.last {
                    parts[index].end = stops.count - 1
                    parts[index].to = stops.last?.name ?? parts[index].to
                    self.parts = parts
                }
                grew = true
            }
        }

        // Extra calls in the *middle* of a printed run — SBB's "exceptional
        // stop" — only when the source marked the call extra. Head and tail
        // above are the rest of an international train GTFS cut at the
        // border; those are scheduled, just not packed. A richer feed also
        // lists passing times, empty formation stations and GTFS-RT
        // Durchfahrt: sitting between two timetable calls is not enough.
        if let first = stops.first, let last = stops.last {
            let lo = min(first.dep, first.arr)
            let hi = max(last.dep, last.arr)
            for extra in unique.compactMap(placed) {
                if StopNaming.isTechnical(extra.name) { continue }
                if extra.cancelled || !extra.extra { continue }
                if stops.contains(where: { Self.sameListedStop($0, extra) }) { continue }
                let at = extra.dep
                guard at > lo, at < hi else { continue }
                var call = extra
                call.extra = true
                let index = stops.firstIndex(where: { $0.dep > at }) ?? stops.count
                if var parts {
                    for i in parts.indices {
                        if parts[i].start >= index { parts[i].start += 1 }
                        if parts[i].end >= index { parts[i].end += 1 }
                    }
                    self.parts = parts
                }
                stops.insert(call, at: index)
                grew = true
            }
        }

        if grew { invalidateGeometry() }
        return grew
    }

    /// Names and identifiers the two sources use for one foreign station.
    /// "Domodossola (I)" is the register; OJP and formation say "Domodossola".
    private static func sameListedStop(_ a: Call, _ b: Call) -> Bool {
        if Self.sameStopName(a.name, b.name) { return true }
        guard let ar = a.ref, let br = b.ref else { return false }
        let ac = StopRegister.scheduledStopPointCode(ar)
            ?? (ar.allSatisfy(\.isNumber) ? ar : nil)
            ?? StopRegister.didok(forSloid: ar)
        let bc = StopRegister.scheduledStopPointCode(br)
            ?? (br.allSatisfy(\.isNumber) ? br : nil)
            ?? StopRegister.didok(forSloid: br)
        if let ac, let bc { return ac == bc }
        return StopRegister.stationOf(ar) == StopRegister.stationOf(br)
            && !StopRegister.stationOf(ar).isEmpty
    }

    private static func sameStopName(_ a: String, _ b: String) -> Bool {
        func squash(_ name: String) -> String {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                         locale: Locale(identifier: "en_US"))
                .filter { $0.isLetter || $0.isNumber }
        }
        if squash(a) == squash(b) { return true }
        func core(_ name: String) -> String {
            var text = name
            if let paren = text.lastIndex(of: "(") { text = String(text[..<paren]) }
            return squash(text)
        }
        return core(a) == core(b)
    }

    /// The line as a passenger reads it.
    ///
    /// Three independent feed habits have to be undone here, or a board lists
    /// the same vehicle twice:
    ///
    /// - GTFS pads long-distance numbers (`EC000066`); the live feed and the
    ///   plate say `EC66`.
    /// - The stationboard mirror and OJP glue the product letter onto a local
    ///   service (`T` + `3` → `T3`, `B` + `17` → `B17`) while GTFS files the
    ///   number the vehicle actually wears. Tram 3 is `3`. S12 stays `S12`:
    ///   on rail the letter *is* the published name.
    /// - Panorama-express feeds glue `PE` onto the named train (`PE` + `GEX`
    ///   → `PEGEX`, `PE` + `GPX` → `PEGPX`) and sometimes the train number
    ///   onto that (`GPX4068`). The plate is `GEX` / `GPX`.
    public static func publishedLine(_ raw: String?, mode: Mode? = nil) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let compact = trimmed.uppercased().filter { $0.isLetter || $0.isNumber }
        if let panorama = panoramaProduct(compact) { return panorama }
        guard let firstDigit = compact.firstIndex(where: \.isNumber) else { return trimmed }
        let digits = String(compact[firstDigit...])
        guard digits.allSatisfy(\.isNumber) else { return trimmed }
        let letters = String(compact[..<firstDigit])
        let number = trimZeros(digits)
        if let mode, let stripped = stripLocalPrefix(letters, number: number, mode: mode) {
            return stripped
        }
        return letters + number
    }

    /// Named through-trains jointly filed by more than one company. `PE` is
    /// the quality prefix, not a second line.
    private static let panoramaProducts = ["GEX", "GPX", "BEX", "VAE"]

    static func panoramaProduct(_ compact: String) -> String? {
        var s = compact
        if s.hasPrefix("PE"), s.count > 2 {
            let rest = String(s.dropFirst(2))
            if panoramaProducts.contains(where: { rest.hasPrefix($0) }) { s = rest }
        }
        for mark in panoramaProducts
        where s == mark || (s.hasPrefix(mark) && s.dropFirst(mark.count).allSatisfy(\.isNumber)) {
            return mark
        }
        return nil
    }

    public static func isPanoramaProduct(_ product: String) -> Bool {
        let key = publishedLine(product)
        return key == "PE" || panoramaProducts.contains(key)
    }

    /// Where this working actually terminates. A through-headsign past the
    /// last booked call (GEX `Brig Bahnhofplatz` on a trip that ends at Chur)
    /// is not a destination this vehicle reaches. A *short* headsign naming a
    /// junction the train still has to pass (RE1 `Spiez` on a run that
    /// continues to Brig) is not either — that is the last remaining call.
    public static func reachedDestination(_ journey: Journey, from index: Int = 0) -> String? {
        guard journey.stops.indices.contains(index) else {
            return journey.to.map(StopNaming.display)
        }
        let remaining = journey.stops[index...]
        let last = remaining.last.map { StopNaming.display($0.name) }
        guard let advertised = journey.to.map(StopNaming.display), !advertised.isEmpty else {
            return last
        }
        if let last, StopNaming.sameBoardDestination(last, advertised) {
            return advertised
        }
        // Packed RE1 trips end at Spiez and still advertise the split:
        // "Brig | Zweisimmen". That is the passenger destination, not a
        // through-headsign past this working (GEX "Brig Bahnhofplatz" on a
        // trip that ends at Chur has no pipe and does not reach Brig).
        if advertised.contains("|") {
            return advertised
        }
        return last
    }

    /// Product letters that are the mode, not the line. Longest first so
    /// `TRAM3` loses `TRAM` rather than stopping at `T`.
    private static let localLinePrefixes: [Mode: [String]] = [
        .tram: ["TRAM", "STR", "NFT", "TN", "T"],
        .bus: ["BUS", "NFB", "NFO", "EXB", "RUB", "CAR", "RUF", "KB", "TX", "B"],
        .boat: ["SCH", "FAE", "KAT", "BAT"],
    ]

    private static func stripLocalPrefix(
        _ letters: String, number: String, mode: Mode
    ) -> String? {
        guard let prefixes = localLinePrefixes[mode] else { return nil }
        for prefix in prefixes where letters == prefix {
            return number
        }
        return nil
    }

    /// What a line plate shows. An extra with no published number still needs a
    /// word on the chip; an empty plate reads as a missing badge, not a service.
    public static func badgeLine(_ raw: String?, extra: Bool = false, mode: Mode? = nil) -> String {
        let published = publishedLine(raw, mode: mode)
        if !published.isEmpty { return published }
        return extra ? "ext" : published
    }

    static func trimZeros(_ text: String) -> String {
        let trimmed = text.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
