import Foundation

/// One vehicle as the map draws it. A value type, so it can cross out of the
/// actor without carrying the mutable journey with it.
public struct VehicleSnapshot: Sendable, Identifiable, Equatable {
    public var id: String
    /// What the upstream systems know this run by, where `id` is not it.
    ///
    /// `id` is the fleet's key and for a timetabled run that is a row number —
    /// `tt:41903`, which no service has heard of. The formation lookup needs
    /// the Swiss Journey ID, because that is where the operator and the train
    /// number are written, so it has to travel with the snapshot. Nil for a
    /// SIRI journey, whose own `id` already is the reference. See
    /// `Journey.journeyRef`.
    public var journeyRef: String?
    public var mode: Mode
    public var category: String?
    /// Which of the four things `.cable` means, resolved rather than stated.
    ///
    /// Nil for everything that is not a cable service. See
    /// `Fleet.cableKind(of:)`, which works it out, and
    /// `LayoutLibrary.CableKind`, which says why the question exists.
    public var cable: LayoutLibrary.CableKind?
    public var line: String
    public var operatorName: String?
    public var operatorFull: String?
    public var to: String?
    public var from: String
    public var delay: Int?
    public var lon: Double
    public var lat: Double
    public var bearing: Double
    public var moving: Bool
    public var speed: Double
    /// The call being stood at, or the leg being run.
    public var index: Int
    /// How far through that leg it is, from 0 to 1.
    ///
    /// Carried so the drawing can put the vehicle back on its own track without
    /// searching for it. A dot needs only `lon`/`lat`; a two-hundred-metre
    /// train needs to know *where along the path* that point is, so the coaches
    /// behind it can be laid out along the same line — and looking that up by
    /// nearest vertex is both slower and ambiguous exactly where it matters, on
    /// a line that doubles back on itself through a station throat.
    public var progress: Double
    public var complete: Bool
    public var cancelled: Bool
    public var stops: [Call]
    public var parts: [JourneyPart]?
    public var geometry: JourneyGeometry?
    /// Set while the vehicle has arrived and is still holding its platform.
    public var layover: Layover?
    /// Whether `lon`/`lat` was read off mapped track geometry rather than off
    /// the straight line between two stops.
    ///
    /// Carried so a draw can be *counted* rather than eyeballed: a vehicle on
    /// the chord is drawn beside its rails, and the only way to know how often
    /// that happens on a real screen is for the thing being drawn to say.
    public var onTrack: Bool
    /// Whether this run is not in the timetable at all — see `Journey.extra`.
    public var extra: Bool
    /// How far `lon`/`lat` has been displaced from where the vehicle honestly
    /// is, to keep it from jumping. In degrees, and nil the moment there is
    /// nothing left to walk off — which is nearly always.
    ///
    /// The drawn position is the true one *plus* this. Anything laying a
    /// vehicle out along its own path has to subtract it to find the point the
    /// path was walked from and then move the whole thing back, or the coaches
    /// are drawn from a nose that is no longer on the line they follow. See
    /// `VehicleFootprint.centreline` and `Fleet.keepContinuous`.
    public var drift: Coord?

    /// A complete snapshot for clients that render a vehicle without querying
    /// the fleet actor, including SwiftUI previews.
    public init(
        id: String, mode: Mode, category: String? = nil,
        cable: LayoutLibrary.CableKind? = nil, line: String,
        operatorName: String? = nil, operatorFull: String? = nil,
        to: String? = nil, from: String, delay: Int? = nil,
        lon: Double, lat: Double, bearing: Double = 0, moving: Bool = false,
        speed: Double = 0, index: Int = 0, progress: Double = 0, complete: Bool = true,
        cancelled: Bool = false, stops: [Call], parts: [JourneyPart]? = nil,
        geometry: JourneyGeometry? = nil, layover: Layover? = nil,
        onTrack: Bool = false, extra: Bool = false, journeyRef: String? = nil,
        drift: Coord? = nil
    ) {
        self.id = id
        self.journeyRef = journeyRef
        self.mode = mode
        self.category = category
        self.cable = cable
        self.line = line
        self.operatorName = operatorName
        self.operatorFull = operatorFull
        self.to = to
        self.from = from
        self.delay = delay
        self.lon = lon
        self.lat = lat
        self.bearing = bearing
        self.moving = moving
        self.speed = speed
        self.index = index
        self.progress = progress
        self.complete = complete
        self.cancelled = cancelled
        self.stops = stops
        self.parts = parts
        self.geometry = geometry
        self.layover = layover
        self.onTrack = onTrack
        self.extra = extra
        self.drift = drift
    }
}

/// One row on a departure board.
public struct BoardEntry: Sendable, Identifiable, Equatable {
    public var id: String
    public var mode: Mode
    public var line: String
    public var to: String?
    public var from: String
    public var departure: Timestamp
    public var arrival: Timestamp
    public var platform: String?
    public var delay: Int?
    public var observed: Bool
    /// Which of the station's stops this leaves from — "Bern, Bollwerk" is a
    /// five-minute walk from platform 7.
    public var stop: String?
    public var terminates: Bool
    public var originates: Bool
    public var running: Bool

    public init(
        id: String, mode: Mode, line: String, to: String? = nil, from: String,
        departure: Timestamp, arrival: Timestamp, platform: String? = nil,
        delay: Int? = nil, observed: Bool = false, stop: String? = nil,
        terminates: Bool = false, originates: Bool = false, running: Bool = true
    ) {
        self.id = id
        self.mode = mode
        self.line = line
        self.to = to
        self.from = from
        self.departure = departure
        self.arrival = arrival
        self.platform = platform
        self.delay = delay
        self.observed = observed
        self.stop = stop
        self.terminates = terminates
        self.originates = originates
        self.running = running
    }
}

public struct StationBoard: Sendable, Equatable {
    public var id: String
    public var name: String
    public var lon: Double
    public var lat: Double
    public var now: Timestamp
    public var departures: [BoardEntry]
    /// Lines the mapped routes say call here that have nothing on the board.
    ///
    /// Carried on the board rather than fetched by the panel so the two halves
    /// of the answer — what is running, and what else serves this place —
    /// arrive together and cannot disagree about which stop they describe, or
    /// list the same line twice between them.
    public var serving: [ServingLine] = []
}

public struct PlatformBoard: Sendable, Equatable {
    public var id: String
    public var name: String
    public var code: String?
    public var assigned: String?
    public var lon: Double
    public var lat: Double
    public var now: Timestamp
    public var departures: [BoardEntry]
    /// True where the timetable does not split this station into platforms, so
    /// these are the station's departures. Said plainly rather than passed off
    /// as a platform board.
    public var stationOnly: Bool
    /// Lines the mapped routes say call here that have nothing on the board.
    public var serving: [ServingLine] = []
    /// The OpenStreetMap element this board was opened from, where it was
    /// opened by tapping a drawn platform rather than a plate.
    ///
    /// Carried on the board rather than held beside it, so the map can outline
    /// the shape that is selected and cannot end up outlining one that is not:
    /// the highlight is a function of the selection, not a second copy of it.
    public var shape: String?
}

/// How the fleet last refreshed, for the status panel.
public struct FleetStatus: Sendable, Equatable {
    public var journeys: Int
    public var vehicles: Int
    public var seen: Int
    public var unresolved: Int
    /// When the fleet being drawn was current — the moment the feed answered,
    /// or, for a replayed snapshot, when that snapshot was written.
    ///
    /// It used to be `Date()` in both cases, which made an eight-hour-old
    /// stored fleet claim to be seconds old and left "no fleet" as the only
    /// honest-looking state the app could reach.
    public var refreshedAt: Date?
    public var parseSeconds: Double
    public var bytes: Int
    public var source: String
    public var failures: Int
    public var lastError: String?
    /// How long the last live refresh took, end to end. Worth keeping beside
    /// the cadence: when this exceeds it, the app is refreshing continuously
    /// and the interval the user chose means nothing.
    public var refreshSeconds: Double = 0
    /// Journeys kept on after the feed stopped sending them, so the clock can
    /// be moved back over ground the app has seen. Nothing to do with what is
    /// running; see `Fleet.retention`.
    public var retained: Int

    /// Before anything has loaded. A named value rather than an exposed
    /// memberwise initialiser: every field here is set by the fleet, and a
    /// caller filling them in by hand would be describing a refresh that never
    /// happened.
    public static let empty = FleetStatus(
        journeys: 0, vehicles: 0, seen: 0, unresolved: 0, refreshedAt: nil,
        parseSeconds: 0, bytes: 0, source: "none", failures: 0, lastError: nil,
        retained: 0
    )
}

/// The fleet: everything the app knows about what is running.
///
/// An actor, because a refresh replaces the whole store while the map is
/// reading it. On the server this was a single-threaded process and needed no
/// such care; here a 150 MB parse runs off the main thread for a second or two
/// while the map keeps drawing at 60 fps from the previous snapshot.
public actor Fleet {
    public let register = StopRegister()
    public let operators = OperatorRegister()

    /// The operator register as a closure, for whoever needs to name an
    /// `sboid` without holding the fleet actor to do it.
    ///
    /// `SituationService` is the caller: a disruption notice names its operator
    /// by reference and a journey knows only the name, so one of the two has to
    /// be converted, and the register that named the journey is the only thing
    /// that can do it consistently.
    public func operatorNamer() -> @Sendable (String?) -> String? {
        let register = operators
        return { register.name(for: $0) }
    }
    public let relations = RelationStore()
    public let railnet = RailNet()
    public let platforms = OSMPlatformIndex()
    public let platformAccess = PlatformAccessIndex()
    public let stopPlaces = StopPlaceStore()
    /// The printed timetable, mapped from the bundle.
    ///
    /// Optional because the app is still whole without it — a build with no
    /// `timetable.bin` falls back to the feed and behaves exactly as it used
    /// to, which is what makes this safe to land before the file ships.
    private var timetable: TimetableStore?
    private var builder: GeometryBuilder!

    private var journeys: [String: Journey] = [:]
    private(set) var revision = 0
    private var chainedRevision = -1
    private var chained: [String: Journey] = [:]

    /// Geometry already built, kept by journey id across refreshes.
    ///
    /// Every `Journey` in the store is a new object after a refresh — the
    /// parser makes them, and `Chains.build` makes another for every chained
    /// vehicle — so the geometry of everything on screen was thrown away five
    /// minutes at a time and rebuilt a vehicle or two per frame. In between,
    /// those vehicles were drawn on the chord between their stops: the train
    /// that runs across country in a straight line, and jumps onto its rails
    /// the moment a tap asks for it in full.
    ///
    /// A `JourneyGeometry` is a struct of arrays and nothing mutates one after
    /// it is built, so while the journey it belongs to is still in the store
    /// the memo shares its storage and costs nothing. It only holds paths of
    /// its own for journeys the app has drawn and moved away from.
    var builtGeometry: [String: BuiltGeometry] = [:]
    /// Orders the memo for eviction. A counter rather than a `Date`: this is
    /// touched once per attached vehicle per frame.
    private var geometryUse = 0

    struct BuiltGeometry {
        /// The call list this path was built for. Same id, different calls, is
        /// a different run of the number and not this one's path.
        var fingerprint: Int
        var geometry: JourneyGeometry
        var fromRoute: Int
        var fromGraph: Int
        var usedAt: Int
    }

    /// How many calls the loaded feed has at each stop place, which is what the
    /// search box means by "the busiest one". Rebuilt with the snapshot rather
    /// than with the query — see `stationTraffic()`.
    var traffic: [String: Int] = [:]
    var trafficRevision = -1

    private var status = FleetStatus.empty

    /// What the refresh in progress is doing, readable without an actor hop.
    ///
    /// Outside the actor on purpose: the thing that wants to read this is a
    /// view, several times a second, while the actor is busy with the very work
    /// being reported on. An `await` for it would be answered only once the
    /// refresh let go — which is to say, only once there was nothing left to
    /// report. See `RefreshMonitor`.
    public nonisolated let monitor = RefreshMonitor()

    private var client: OTDClient?
    private let mirror = MirrorClient()
    private let snapshotURL: URL

    /// Journeys the national feed does not carry, fetched one stop at a time.
    ///
    /// Kept apart from `journeys` rather than merged into it, because they are a
    /// different kind of thing: a handful of sightings around one stop, not a
    /// view of the whole country. They are only ever consulted for a board the
    /// feed answered with nothing, so a service cannot appear twice, and they
    /// are dropped whenever a real refresh lands.
    private var mirrored: [String: Journey] = [:]
    /// Stops already asked about, so a repeated tap on a quiet stop does not
    /// repeat the request.
    private var mirrorAsked: [String: Date] = [:]
    static let mirrorTTL: TimeInterval = 120

    /// Journeys the feed has stopped sending, kept so the clock can be moved
    /// back over ground the app has actually seen.
    ///
    /// SIRI-ET is an *estimated timetable*: a journey drops out of it once it
    /// has run, and `apply` replaces the store wholesale. Between the two, the
    /// past was being thrown away a minute at a time — a snapshot holds about
    /// 7% of its fleet fifteen minutes back and 1% an hour back, so stepping
    /// backwards emptied the map even though every one of those journeys had
    /// been in hand moments earlier. Each one carries its whole call list, so
    /// keeping it costs nothing but memory and buys a real hour behind now.
    private var retired: [String: Journey] = [:]

    /// How far back a journey the feed has let go of is still kept.
    public static let retention: TimeInterval = 90 * 60

    /// A ceiling on the retained set, so a long session on a fast cadence
    /// cannot grow it without bound. Reached only in the busiest hours; the
    /// oldest go first, which is also the least useful.
    public static let retentionLimit = 14_000

    /// Where the routed legs are written back to, once opened.
    private var legCacheURL: URL?
    /// How many legs were in the cache when it was last written, so an idle
    /// session does not rewrite an unchanged file.
    private var legsAtLastSave = -1

    public init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
    }

    // MARK: - Loading

    /// Load every bundled store. Reports what arrived, so the UI can say what
    /// is missing rather than silently degrading.
    public struct Loaded: Sendable {
        public var stops = 0
        public var relations = 0
        public var railnetNodes = 0
        public var stopPlaces = 0
        public var platformShapes = 0
        public var problems: [String] = []
    }

    public func load(from directory: URL) -> Loaded {
        var result = Loaded()

        func attempt(_ name: String, _ body: () throws -> Void) {
            do { try body() } catch { result.problems.append("\(name): \(error)") }
        }

        attempt("stops") {
            try register.load(
                stopsFile: directory.appendingPathComponent("stops.bin"),
                foreignFile: directory.appendingPathComponent("foreign.bin")
            )
        }
        attempt("operators") { try operators.load(directory.appendingPathComponent("operators.bin")) }
        attempt("platforms") { try platforms.load(directory.appendingPathComponent("platforms.bin")) }
        attempt("platform access") { try platformAccess.load(directory.appendingPathComponent("access.bin")) }
        attempt("stop places") { try stopPlaces.load(directory.appendingPathComponent("stop-places.bin")) }
        attempt("routes") { try relations.load(directory.appendingPathComponent("routes.bin")) }
        attempt("railnet") { try railnet.load(directory.appendingPathComponent("railnet.bin")) }
        // Not through `attempt`: a missing timetable is not a problem to report,
        // it is a build without one. The feed still draws the map.
        timetable = try? TimetableStore(url: directory.appendingPathComponent("timetable.bin"))

        builder = GeometryBuilder(relations: relations, railnet: railnet)

        result.stops = register.stats.stops
        result.relations = relations.count
        result.railnetNodes = railnet.nodeCount
        result.stopPlaces = stopPlaces.count
        result.platformShapes = platforms.shapeCount
        return result
    }

    public func configure(token: String?) {
        client = OTDClient(token: token, budget: "gtfs-rt")
    }

    /// What the platform says is left of the live-feed budget.
    public func limits() async -> OTDClient.Limits? {
        await client?.limits(OTDClient.gtfsRT)
    }

    public func currentStatus() -> FleetStatus { status }

    public var hasFeed: Bool {
        get async { await client?.isConfigured ?? false }
    }

    // MARK: - Refresh

    /// Replace the live fleet with the national feed's view of it.
    ///
    /// Wholesale replacement rather than merging is the point. Every journey
    /// arrives with its complete call list — where it started is stated, not
    /// inferred — so there is nothing to splice and no reason to carry over a
    /// stale sighting. One call describes the entire country.
    @discardableResult
    public func refresh() async -> Bool {
        // Said out loud rather than returned as a bare `false`. Each of these
        // leaves the map without corrections for the rest of the session, and
        // each used to look from the outside exactly like a refresh that had
        // not happened yet.
        guard let client else { return fail("no feed configured") }
        guard await client.isConfigured else { return fail("no GTFS-RT token") }
        guard hasTimetable else { return fail("no timetable to correct") }

        let started = Date()
        monitor.begin()
        monitor.phase(.receiving)

        let payload: Data
        do {
            payload = try await client.fetch(OTDClient.gtfsRT, query: "", maxWait: 65)
        } catch {
            status.failures += 1
            status.lastError = String(describing: error)
            monitor.settle(.failed(String(describing: error)))
            return false
        }

        monitor.phase(.indexing)
        // Decoded off the actor, because every frame is queued behind it.
        //
        // A tick's first act is to ask this same actor where the vehicles are,
        // so any stretch the fleet spends thinking is a stretch in which no
        // frame can be built — and the draw loop's rate is measured over the
        // wall clock whether or not it had anything to do. This is the largest
        // single piece of synchronous work the fleet does outside a timetable
        // expansion: eight thousand trip updates out of a few megabytes of
        // protobuf, on the refresh cadence, in front of the map.
        //
        // It is also the piece that has no reason to be here at all. Reading
        // the wire format is a pure function of the bytes and touches nothing
        // the actor owns; only the fold that follows does. So the bytes go out
        // to a task of their own and the actor is free while they are read,
        // which is what lets the map keep drawing across a refresh.
        //
        // Suspending here is no more reentrant than the fetch above it already
        // was — `applyRealtime` reads `journeys` when it runs, not when the
        // refresh began.
        let feed = await Task.detached(priority: .userInitiated) {
            Protobuf.feed(payload)
        }.value
        guard !feed.updates.isEmpty else {
            // A truncated or empty response must not wipe a good fleet.
            status.failures += 1
            status.lastError = "empty response"
            monitor.settle(.failed("empty response"))
            return false
        }

        let report = applyRealtime(feed)
        status.journeys = journeys.count
        status.seen = feed.updates.count
        status.unresolved = report.unmatched
        status.refreshedAt = Date()
        status.parseSeconds = Date().timeIntervalSince(started)
        status.refreshSeconds = status.parseSeconds
        status.bytes = payload.count
        status.source = "timetable + live"
        status.lastError = nil
        status.retained = retired.count
        let clock = Timestamp(Date().timeIntervalSince1970)
        status.vehicles = fleetByID().values.count { Positioning.standsUntil($0) >= clock }

        monitor.settle(.idle)
        return true
    }

    /// What the last live refresh made of the feed.
    public private(set) var lastRealtime: Reconcile.Report?

    /// Fold a national GTFS-Realtime feed onto the timetable the map is drawing.
    ///
    /// No matching step, and that is the point of having moved to this feed: a
    /// trip update names its run by the GTFS `trip_id`, which is the same string
    /// `TimetableStore` gives every journey as its identity. The join is a
    /// dictionary lookup and it lands 99.2% of the time — the 0.8% that miss are
    /// the added runs, which carry a synthetic id precisely because they are in
    /// no timetable.
    @discardableResult
    func applyRealtime(_ feed: RealtimeFeed, at moment: Date = Date()) -> Reconcile.Report {
        var report = Reconcile.Report()
        let now = Timestamp(moment.timeIntervalSince1970)
        // Two different kinds of change, because they cost three orders of
        // magnitude apart. See the fold at the end.
        var arrived = false
        var moved: [Journey] = []

        for update in feed.updates {
            guard let journey = journeys[update.tripID] else {
                // No timetabled run under this id. Either the feed is talking
                // about something outside the window the map has expanded — the
                // ordinary case, since it covers three hours and the map draws
                // ninety minutes — or it is a run that is in no timetable at
                // all, which is the one case worth building from scratch.
                if update.isExtra, let built = buildExtra(update, at: now) {
                    journeys[built.id] = built
                    report.added += 1
                    arrived = true
                } else if update.isExtra {
                    report.added += 1
                } else {
                    report.unmatched += 1
                }
                continue
            }
            report.matchedByRef += 1

            var changed = false
            switch update.relationship {
            case .canceled, .deleted:
                journey.cancelled = true
                changed = true
            case .added, .duplicated, .replacement, .unscheduled:
                journey.extra = true
            case .scheduled:
                break
            }

            if apply(update, to: journey, at: now) { changed = true }
            if changed { moved.append(journey) }
        }

        // **A national refresh must not re-chain the country.**
        //
        // `revision` is the chained fleet's staleness flag, so bumping it makes
        // the next frame run `Chains.build` over the whole timetable expansion
        // — 138 ms on a Mac in release against 25,965 journeys, and several
        // times that on a phone, on the actor every frame is queued behind. A
        // refresh lands on its own cadence with the camera sitting still, so it
        // reads as the map freezing at random for no reason the reader did
        // anything to cause. `applyTiming` was given `refold` for exactly this;
        // this path is the same fold arriving eight thousand at a time and kept
        // the whole-country rebuild.
        //
        // The distinction that matters is *membership* against *times*. A run
        // the feed invented is a journey the chained fleet has never seen and
        // cannot flatten without being rebuilt, so an arrival still bumps the
        // flag — there are about fifty of those in a national feed and they do
        // not arrive on every refresh. Everything else moved times on a journey
        // that is already in there, and `refold` brings exactly that vehicle up
        // to date; where the run was never joined to anything, the chained
        // fleet holds the very object just folded onto and there is nothing to
        // do at all.
        //
        // Same trade `applyTiming` documents: a delay can in principle break or
        // make a link at a junction, and that is now noticed at the next
        // refresh that adds a run rather than immediately. Links are decided by
        // margins of minutes.
        if arrived {
            revision += 1
        } else {
            for journey in moved { refold(journey, repathed: false) }
        }
        lastRealtime = report
        return report
    }

    /// Build a journey for a run that is in no timetable.
    ///
    /// A relief working, a replacement, an extra filed this morning — about
    /// fifty in a national feed. There is nothing to fold it onto, so it is
    /// made out of the update itself, which carries everything needed: every
    /// call names a SLOID the register can place and carries an absolute time.
    ///
    /// What it does not reliably carry is a name. The run is labelled only by a
    /// `route_id`, and about two in five of those resolve against the static
    /// feed — the rest use a form no timetable contains. Those are drawn with
    /// no line rather than left off the map, because an unlabelled train that is
    /// running is closer to the truth than no train at all, and `extra` says
    /// exactly what it is.
    private func buildExtra(_ update: TripUpdate, at now: Timestamp) -> Journey? {
        var calls: [Call] = []
        calls.reserveCapacity(update.stops.count)
        var visits: [String: Int] = [:]

        for stop in update.stops.sorted(by: { ($0.sequence ?? 0) < ($1.sequence ?? 0) }) {
            guard let ref = stop.stopID, let place = register.lookup(ref) else { continue }
            // A call with neither time is a call the vehicle cannot be
            // positioned against, and the interpolator needs both ends filled.
            guard let time = stop.departure ?? stop.arrival else { continue }
            let visit = (visits[ref] ?? 0) + 1
            visits[ref] = visit
            calls.append(Call(
                key: "\(ref)|\(visit)",
                ref: ref,
                name: place.name,
                lat: place.lat,
                lon: place.lon,
                platform: place.platform,
                precise: place.precise,
                arr: stop.arrival ?? time,
                dep: stop.departure ?? time,
                delay: nil,
                // Every time here is the operator's own statement about a run
                // it has just filed, so a call already behind us is what
                // happened rather than what was predicted.
                observed: time < now,
                assigned: place.assigned
            ))
        }
        guard calls.count >= 2 else { return nil }

        let known = update.routeID.flatMap { timetable?.route($0) }
        return Journey(
            id: update.tripID,
            // Where the route is not in any timetable the mode cannot be looked
            // up either. Read off the stops instead: a run calling mostly at
            // railway stations is a train, and everything else is drawn as road.
            mode: known?.mode ?? inferredMode(of: calls),
            category: nil,
            line: known?.line ?? "",
            number: nil,
            operatorName: nil,
            operatorFull: nil,
            to: calls.last?.name,
            from: calls[0].name,
            // Minutes, as everywhere `delay` is read; the feed states seconds.
            delay: SiriParser.reportableDelay(update.delay),
            start: calls[0].dep,
            end: calls[calls.count - 1].arr,
            complete: true,
            monitored: true,
            cancelled: update.relationship == .canceled || update.relationship == .deleted,
            source: Journey.timetableSource,
            stops: calls,
            extra: true
        )
    }

    /// A mode for a run whose route nothing knows, read off where it calls.
    private func inferredMode(of calls: [Call]) -> Mode {
        var rail = 0
        for call in calls {
            guard let ref = call.ref else { continue }
            if stopPlaces.place(id: StopRegister.stationOf(ref))?.rail == true { rail += 1 }
        }
        return rail * 2 >= calls.count ? .train : .bus
    }

    /// Fold one trip update onto one journey, by stop id.
    ///
    /// Returns whether anything actually moved, so a feed that says only "still
    /// on time" does not invalidate geometry for the whole country.
    /// Internal rather than private so the units can be tested directly. This
    /// is the third ingest path to have written the feed's seconds into a field
    /// the app draws as minutes, and the first two were found by reading rather
    /// than by a test.
    func apply(_ update: TripUpdate, to journey: Journey, at now: Timestamp) -> Bool {
        guard !update.stops.isEmpty else {
            // Minutes. Everything GTFS-RT states about lateness is in seconds —
            // `TripUpdate.delay` and both `StopTimeEvent.delay`s — and every
            // field it is being written into here is read as minutes, because
            // `Format.delay` prints the number unconverted. Handed straight
            // across, a train ninety seconds down reported `+90`.
            if let delay = SiriParser.reportableDelay(update.delay), delay != journey.delay {
                journey.delay = delay
                journey.monitored = true
                return true
            }
            return false
        }

        // Where this vehicle is before the fold, so a correction that moves it
        // a length of track is walked off rather than jumped. See
        // `Journey.settle`. Nil for a run not currently on the map, which is
        // nearly all of the six thousand in a national tick.
        let anchor = Positioning.retimeAnchor(journey, at: now)

        // The feed keys calls by `stop_id`, which is the SLOID the timetable's
        // calls already carry — so this is a lookup rather than a match. Where
        // it also gives a sequence number that is used in preference, because a
        // looping route calls at one stop twice.
        var bySequence: [Int: StopTimeUpdate] = [:]
        var byStop: [String: StopTimeUpdate] = [:]
        for stop in update.stops {
            if let n = stop.sequence { bySequence[n] = stop }
            if let ref = stop.stopID { byStop[ref] = stop }
        }

        var moved = false
        for index in journey.stops.indices {
            // GTFS stop_sequence is 1-based in this feed.
            let found = bySequence[index + 1] ?? journey.stops[index].ref.flatMap { byStop[$0] }
            guard let found else { continue }

            if found.skipped, !journey.stops[index].cancelled {
                journey.stops[index].cancelled = true
                moved = true
            }
            // Absolute times where they are given, delays where they are not.
            //
            // A bare delay is stated against the *printed* time, so it has to
            // be added to that rather than to whatever a previous tick already
            // moved the call to. Added to the live time it compounds: a run
            // ninety seconds down is drawn ninety seconds further back on every
            // refresh, and over an hour of polling it walks off the end of its
            // own route. This feed states absolute times and so never takes the
            // fallback — but it is a fallback precisely because a producer is
            // allowed not to, and the failure it would cause is silent.
            //
            // Only the departure is anchored here, because only the departure
            // has a printed time to anchor against: `Call.sched` is the booked
            // departure and there is no booked arrival beside it. Closing the
            // arrival half means carrying one, which is a change to what
            // `timetable.bin` and the fleet cache hold rather than a change to
            // this arithmetic — worth doing before anything relies on the
            // fallback, and not worth doing on the way past.
            let booked = journey.stops[index].sched
            if let arrival = found.arrival ?? found.arrivalDelay.map({ journey.stops[index].arr + $0 }),
               arrival != journey.stops[index].arr {
                journey.stops[index].arr = arrival
                moved = true
            }
            if let departure = found.departure ?? found.departureDelay.map({ (booked ?? journey.stops[index].dep) + $0 }),
               departure != journey.stops[index].dep {
                journey.stops[index].dep = departure
                moved = true
            }
            // Minutes, as above — and note the two lines before this one are
            // deliberately *not* converted: those add a delay to a `Timestamp`,
            // which is unix seconds, so seconds is exactly what they want.
            journey.stops[index].delay = SiriParser.reportableDelay(
                found.departureDelay ?? found.arrivalDelay
            )
            journey.stops[index].observed = journey.stops[index].dep < now
        }

        if moved {
            journey.monitored = true
            journey.delay = SiriParser.reportableDelay(update.delay)
                ?? journey.stops.last(where: { $0.dep < now })?.delay
                ?? journey.stops.first(where: { $0.dep >= now })?.delay
            if let first = journey.stops.first { journey.start = first.dep }
            if let last = journey.stops.last { journey.end = last.arr }
            // Times moved, not the rails. Dropping the path here put every
            // re-timed vehicle on the chord until the next attach, which is
            // the jump a tap (or a GTFS-RT tick) used to make. The path is
            // still the one this stop list was built for.
            Positioning.noteRetimed(journey, from: anchor, at: now)
        }
        return moved
    }

    // MARK: - Drawing from the timetable

    /// Whether there is a timetable to draw from at all.
    public var hasTimetable: Bool { timetable?.isReady ?? false }

    public var timetableTrips: Int { timetable?.tripCount ?? 0 }

    /// How far either side of now the timetable is expanded.
    ///
    /// Behind, because a vehicle that arrived ten minutes ago and leaves again
    /// in five is still standing on its platform and the map should say so —
    /// the same reason the feed's own journeys are retained. Ahead, because the
    /// time control offers a couple of hours and an empty map reads as a claim
    /// about Switzerland rather than about the window.
    public static let timetableBehind: TimeInterval = 30 * 60
    public static let timetableAhead: TimeInterval = 60 * 60

    /// Fill the fleet from the printed timetable, without touching the network.
    ///
    /// This is what makes SIRI-ET optional. The feed used to be the only thing
    /// that knew what was running, so a launch without it drew nothing; the
    /// timetable knows what is *scheduled* to run, which is the same map minus
    /// the delays — and the delays are now asked for one journey at a time.
    ///
    /// Nothing here is monitored and nothing carries a delay, deliberately. A
    /// timetabled journey is a claim about the plan, and the panel says so
    /// rather than letting a silence read as punctuality.
    @discardableResult
    public func drawTimetable(
        at moment: Date = Date(),
        behind: TimeInterval = Fleet.timetableBehind,
        ahead: TimeInterval = Fleet.timetableAhead,
        in region: BBox? = nil
    ) -> Bool {
        guard let timetable, timetable.isReady, register.isReady else { return false }

        let started = Date()
        let now = Timestamp(moment.timeIntervalSince1970)
        let built = timetable.journeys(
            from: now - Timestamp(behind),
            to: now + Timestamp(ahead),
            in: region,
            place: { [register] ref in register.lookup(ref) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        )
        // Record the window even when nothing came back, or a stretch the
        // archive has no service for would be re-expanded on every tick:
        // `redrawTimetableIfNeeded` measures against the last window, and a
        // stale one leaves the clock permanently outside it.
        defer { timetableWindow = (now - Timestamp(behind))...(now + Timestamp(ahead)) }
        guard !built.isEmpty else { return false }

        var found: [String: Journey] = [:]
        found.reserveCapacity(built.count)
        for journey in built { found[journey.id] = journey }

        var summary = SiriParser.Summary()
        summary.seen = built.count
        apply(
            found, summary: summary, started: started, bytes: 0, source: "timetable",
            drawnAt: moment
        )
        timetableRegion = region
        timetableDrawnAt = moment
        return true
    }

    /// The span the timetable was last expanded over.
    private var timetableWindow: ClosedRange<Timestamp>?

    /// The region the drawn fleet was clipped to, if it was clipped at all.
    ///
    /// `nil` is the ordinary state: the whole country, which is what everything
    /// but the first frame of a launch wants. A launch draws its viewport first
    /// and fills the rest in behind the map — see `completeTimetable` — and
    /// until that lands this says the fleet is a view rather than the country.
    public private(set) var timetableRegion: BBox?
    private var timetableDrawnAt: Date?

    public var isTimetablePartial: Bool { timetableRegion != nil }

    /// Expand the rest of the country onto a fleet that was drawn for a
    /// viewport.
    ///
    /// Deliberately additive rather than a second `drawTimetable`. A full draw
    /// *replaces* the store, and by the time this runs the map is already up:
    /// a train the reader tapped in the first second may have had OJP's timings
    /// folded onto it, and rebuilding would throw those away for a journey the
    /// clipped pass had already built correctly. So what is already drawn is
    /// kept exactly as it stands and only the missing ids are added.
    ///
    /// For the same reason `mirrored` and `mirrorAsked` survive: this is not a
    /// new national view superseding the last one, it is the same view being
    /// finished.
    @discardableResult
    public func completeTimetable() -> Bool {
        guard timetableRegion != nil, let timetable, timetable.isReady, register.isReady,
              let moment = timetableDrawnAt, let window = timetableWindow
        else { return false }

        let started = Date()
        let built = timetable.journeys(
            from: window.lowerBound,
            to: window.upperBound,
            place: { [register] ref in register.lookup(ref) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        )
        // Cleared whatever happens. A window the archive has no service for is
        // as complete as it is ever going to be, and leaving the flag set would
        // have every later tick try again.
        timetableRegion = nil
        guard !built.isEmpty else { return false }

        var found = journeys
        var added = 0
        for journey in built where found[journey.id] == nil {
            found[journey.id] = journey
            added += 1
        }
        guard added > 0 else { return false }

        journeys = found
        revision += 1
        status.journeys = found.count
        status.seen = found.count
        status.parseSeconds = Date().timeIntervalSince(started)
        let clock = Timestamp(moment.timeIntervalSince1970)
        status.vehicles = fleetByID().values.count { Positioning.standsUntil($0) >= clock }
        return true
    }

    /// How close to the edge of the drawn window the clock may come before the
    /// window is rebuilt.
    ///
    /// The map thins out towards the edges rather than ending at them — a
    /// journey is only in hand if its whole run was inside the expanded span —
    /// so the rebuild has to happen before the clock reaches the boundary, not
    /// when it crosses it.
    static let timetableMargin: TimeInterval = 10 * 60

    /// Re-expand the timetable if the clock has moved out from under the window.
    ///
    /// The window is an hour ahead and half an hour behind, which covers an
    /// ordinary session; scrubbing the time control moves the clock hours at a
    /// time and would otherwise run off the end of what was built.
    ///
    /// Rebuilding discards any OJP timings already folded in, which is why it
    /// is guarded rather than done on every tick: those cost a request each and
    /// are re-fetched when the vehicle is next opened.
    @discardableResult
    public func redrawTimetableIfNeeded(at moment: Date) -> Bool {
        guard hasTimetable else { return false }
        let now = Timestamp(moment.timeIntervalSince1970)
        guard let window = timetableWindow else { return drawTimetable(at: moment) }
        let margin = Timestamp(Self.timetableMargin)
        guard now < window.lowerBound + margin || now > window.upperBound - margin else {
            return false
        }
        return drawTimetable(at: moment)
    }

    /// Fold OJP's answer about one journey onto the copy the store holds.
    ///
    /// Returns how many of the journey's calls the answer covered, so a caller
    /// can tell "no delays published" from "asked about the wrong run".
    ///
    /// **This must not bump `revision`.** Doing so is what made the map stall
    /// for seconds at a time. `revision` is the chained fleet's staleness flag,
    /// and moving it makes the next `fleetByID()` — which is the next *frame* —
    /// re-chain the whole country: `Chains.build` over a national timetable
    /// expansion, measured at 138 ms per bump on a Mac in release against
    /// 25,965 journeys, and several times that on a phone. `keepTimingsLive`
    /// folds one answer every two and a half seconds, so that was a stall
    /// every two and a half seconds for as long as there was anything on
    /// screen left to ask about — the freeze that came back every time a new
    /// vehicle came into frame.
    ///
    /// What a fold actually changes is one journey. Where that journey was not
    /// joined to anything the chained fleet holds the very object just folded
    /// onto and there is nothing to do at all; where it was, `refold` brings
    /// that one vehicle up to date. The one thing this gives up is a re-join:
    /// a delay at a junction can in principle break or make a link, and now
    /// that is only noticed at the next refresh. A link is decided by margins
    /// of minutes and re-chaining the country to catch the rare one was never
    /// worth a stall on every fold.
    @discardableResult
    public func applyTiming(_ timing: JourneyTiming, to id: String, at moment: Date = Date()) -> Int {
        guard let journey = journeys[id] else { return 0 }
        let hadPath = journey.geometry != nil
        let quays = journey.stops.map(\.platform)
        let touched = journey.apply(timing, at: Timestamp(moment.timeIntervalSince1970))
        guard touched > 0 else { return 0 }
        // The path only moved if the platform did — `Journey.apply` drops it
        // then.
        let repathed = (hadPath && journey.geometry == nil)
            || quays != journey.stops.map(\.platform)
        if repathed { builtGeometry[id] = nil }
        refold(journey, repathed: repathed)
        return touched
    }

    /// Bring the joined vehicle carrying `leg` up to date with a fold onto it.
    ///
    /// A no-op for the ordinary case. Most journeys are not chained to
    /// anything, and `Chains.build` hands those back as the very objects it was
    /// given — so the fleet the map reads and the journey just folded onto are
    /// the same object and the new times are already in it.
    ///
    /// A chained vehicle is the exception: it is a *different* object, built by
    /// flattening its legs, and nothing in it points back at them. The legs'
    /// calls are copied into it at fixed offsets that `JourneyPart` records, so
    /// the fold can be replayed onto exactly the stretch this leg owns.
    ///
    /// Mutated in place rather than rebuilt with `Chains.join`. The boards read
    /// their own array of these objects (`indexedFleet`), and handing `chained`
    /// a fresh object would leave that array — and every board built from it —
    /// showing the times from before the fold.
    private func refold(_ leg: Journey, repathed: Bool) {
        // A full rebuild is already due, and it will take this in.
        guard chainedRevision == revision else { return }
        guard let vehicleId = chainOf[leg.id], let vehicle = chained[vehicleId],
              let part = vehicle.parts?.first(where: { $0.id == leg.id })
        else { return }

        // A junction is one call standing for two: the leg before arrives at
        // it and the leg after leaves it, and `Chains.join` builds it from
        // both — the arrival from the earlier leg, the departure from the
        // later one. So a leg owns its whole stretch except for the departure
        // of the call it ends on and the arrival of the call it starts from,
        // and writing either of those would move the *neighbouring* leg.
        let opensOnAJunction = part.start != 0
        let endsOnAJunction = part.end < vehicle.stops.count - 1
        for i in leg.stops.indices {
            let j = part.start + i
            guard j < vehicle.stops.count else { break }
            if i == 0 && opensOnAJunction {
                vehicle.stops[j].dep = leg.stops[i].dep
                if vehicle.stops[j].platform == nil {
                    vehicle.stops[j].platform = leg.stops[i].platform
                }
                continue
            }
            let heldDeparture = vehicle.stops[j].dep
            vehicle.stops[j] = leg.stops[i]
            if i == leg.stops.count - 1 && endsOnAJunction {
                vehicle.stops[j].dep = heldDeparture
            }
        }
        vehicle.start = vehicle.stops[0].dep
        vehicle.end = vehicle.stops[vehicle.stops.count - 1].arr
        // `Chains.join` takes these from the head, so only the head may move
        // them.
        if part.start == 0 {
            vehicle.delay = leg.delay
            vehicle.monitored = leg.monitored
            vehicle.cancelled = leg.cancelled
        }
        // The glide, and it belongs to the vehicle rather than to the leg the
        // answer happened to be about. Without this a correction landing on
        // anything but a chained vehicle's first leg was drawn as the jump the
        // glide exists to hide — see `Journey.settle`.
        if let settle = leg.settle { vehicle.settle = settle }

        if repathed {
            vehicle.invalidateGeometry()
            builtGeometry[vehicleId] = nil
        }
    }

    /// What the last reconciliation made of the feed.
    public private(set) var lastReconcile: Reconcile.Report?

    /// Merge a national SIRI snapshot onto the timetable the map is drawing.
    ///
    /// The timetable says what is scheduled; this says what is actually
    /// happening to it, and — crucially — what is happening that the timetable
    /// cannot know: 313 cancellations, 1,486 added calls and 184 unscheduled
    /// runs in a national snapshot. That last group is the reason this cannot
    /// be replaced by asking OJP: a relief working has no timetabled reference
    /// to ask about.
    ///
    /// A sighting that matches replaces the timetabled run wholesale rather
    /// than being spliced into it. SIRI carries the complete call list with real
    /// times, so there is nothing worth keeping from the plan except the OJP
    /// reference — which the plan has and the sighting often does not.
    private func reconcile(
        _ found: [String: Journey], zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
    ) -> Reconcile.Report {
        var report = Reconcile.Report()

        var byRef: [String: String] = [:]
        for journey in journeys.values {
            if let ref = journey.journeyRef { byRef[ref] = journey.id }
        }
        let byShape = Reconcile.index(journeys.values, zone: zone)

        var merged = journeys
        for sighting in found.values {
            var replacing: String?
            if let id = byRef[sighting.id] {
                replacing = id
                report.matchedByRef += 1
            } else if let key = Reconcile.key(for: sighting, zone: zone),
                      let timetabled = byShape[key] {
                replacing = timetabled.id
                report.matchedByShape += 1
            }

            if let replacing, let timetabled = merged[replacing] {
                // The sighting wins, but inherits the reference: a run filed
                // under `ch:1:ServiceJourney:823:…` has no OJP handle of its
                // own, and the timetabled twin it just matched does.
                if sighting.journeyRef == nil { sighting.journeyRef = timetabled.journeyRef }
                merged[replacing] = sighting
                continue
            }

            // Unmatched. An extra run is expected — it is in no timetable by
            // definition — and the rest are real vehicles the match missed,
            // measured at 1.6%. Both are drawn: a sighting is better evidence
            // than a plan, and dropping it would remove a train that is there.
            if sighting.extra { report.added += 1 } else { report.unmatched += 1 }
            merged[sighting.id] = sighting
        }

        retire(replacing: merged)
        journeys = merged
        builtGeometry = builtGeometry.filter { merged[$0.key] != nil }
        mirrored = [:]
        mirrorAsked = [:]
        revision += 1
        lastReconcile = report
        return report
    }

    /// The journey reference to ask OJP about, for a vehicle the map has.
    ///
    /// Nil where the feed gives the run none — 20.7% of a weekday's trips — and
    /// a caller that gets nil should say the run publishes no live data rather
    /// than sending a request that comes back empty.
    public func journeyRef(for id: String) -> (ref: String, day: String)? {
        guard let journey = journeys[id] ?? retired[id] else { return nil }
        // A feed journey is already keyed by the reference upstream knows it
        // by, so its own id is the reference. A timetabled one has the
        // reference beside it, or has none — and none means none: `tt:41903`
        // is this app's row number and OJP has never heard of it.
        let ref = journey.journeyRef ?? (journey.isTimetabled ? nil : journey.id)
        guard let ref, !ref.isEmpty else { return nil }
        return (ref, LoadService.Key.day(of: journey.stops.first?.sched
            ?? journey.stops.first?.dep ?? journey.start))
    }

    /// Record why a refresh did not happen, and say no.
    ///
    /// The reasons are permanent for the session — a missing token does not
    /// arrive later — so they are worth stating once and leaving on the status
    /// panel rather than counting as a transient failure.
    private func fail(_ reason: String) -> Bool {
        status.lastError = reason
        monitor.settle(.failed(reason))
        return false
    }

    /// Delete the XML snapshot an older build left behind.
    ///
    /// It is 150 MB of a phone's storage that nothing will read again, and an
    /// app that quietly keeps a copy of everything it has ever cached is one of
    /// the reasons people go looking through Settings for something to delete.
    private func discardLegacySnapshot() {
        let directory = snapshotURL.deletingLastPathComponent()
        for name in ["siri-et.xml", "siri-et.xml.partial"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Open with the last snapshot rather than spending a call on a restart —
    /// and, when there is no network at all, this is the fleet.
    ///
    /// Two kinds of file are accepted, told apart by what they contain rather
    /// than by what they are called: the packed fleet this app writes, and the
    /// feed's own XML. The second is how a recorded snapshot out of `archive/`
    /// is replayed to see a daytime network at three in the morning — and it is
    /// also the cache an older build of the app left behind.
    ///
    /// `maxAge` is generous rather than tight. It was an hour, which is the
    /// right window for "this is still live" and the wrong one for "draw
    /// something": open the app after lunch and the snapshot was refused, so
    /// the map had nothing on it at all for as long as the first download took
    /// — and said "no fleet", which reads as a broken app rather than a stale
    /// one. An old fleet is drawable, scrubbable, and honestly labelled by
    /// `status.refreshedAt`; nothing is none of those.
    @discardableResult
    public func replayCachedSnapshot(maxAge: TimeInterval = 12 * 3600) -> Bool {
        guard register.isReady,
              let attributes = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) <= maxAge
        else { return false }

        let started = Date()

        if FleetCache.isFleetCache(snapshotURL), let found = FleetCache.read(snapshotURL) {
            let size = (attributes[.size] as? Int) ?? 0
            var summary = SiriParser.Summary()
            summary.seen = found.count
            summary.placed = found.count
            apply(
                found, summary: summary, started: started, bytes: size,
                source: "cache", current: modified
            )
            return !found.isEmpty
        }

        guard let data = try? Data(contentsOf: snapshotURL, options: .mappedIfSafe) else { return false }
        // XML, then: read where it is mapped and split across the cores this
        // device has, rather than copied into a parser's buffer and walked on
        // one core.
        let (found, summary) = SnapshotReader.parse(data) { [register, operators] in
            SiriParser(
                resolve: { ref, platform, name in
                    register.lookup(ref, statedPlatform: platform, name: name)
                },
                operatorName: { operators.name(for: $0) },
                operatorFullName: { operators.fullName(for: $0) }
            )
        }

        guard !found.isEmpty else { return false }
        apply(
            found, summary: summary, started: started, bytes: data.count,
            source: "cache", current: modified
        )
        return true
    }

    /// - Parameter current: the moment this fleet describes. `Date()` for a
    ///   live answer; the snapshot's own timestamp for a replay, which is the
    ///   difference between "refreshed a second ago" and "this is what the
    ///   country looked like at nine".
    /// - Parameters:
    ///   - current: when the refresh happened, for "updated 2 min ago".
    ///   - drawnAt: the moment the fleet is a picture *of*, which is not the
    ///     same thing. A timetable expansion is built around wherever the clock
    ///     has been moved to, so counting what is running against real time
    ///     told a viewer scrubbed to tomorrow morning that nothing was — beside
    ///     a map full of vehicles.
    /// Internal rather than private so a test can stand a small fleet up the
    /// way a feed does, which is the only honest way to check what chaining
    /// and folding do to one.
    func apply(
        _ found: [String: Journey], summary: SiriParser.Summary,
        started: Date, bytes: Int, source: String, current: Date = Date(),
        drawnAt: Date? = nil
    ) {
        retire(replacing: found)
        journeys = found
        // The memo answers for what the feed still carries. Anything else has
        // finished, and a finished journey's path is not asked for again —
        // `retire` drops it for the same reason.
        builtGeometry = builtGeometry.filter { found[$0.key] != nil }
        // A new national view supersedes every stop-level sighting taken to
        // paper over the last one.
        mirrored = [:]
        mirrorAsked = [:]
        revision += 1
        status.journeys = found.count
        status.seen = summary.seen
        status.unresolved = summary.unresolved
        status.refreshedAt = current
        status.parseSeconds = Date().timeIntervalSince(started)
        if source == "feed" { status.refreshSeconds = status.parseSeconds }
        status.bytes = bytes
        status.source = source
        status.lastError = nil
        status.retained = retired.count
        // What is running or still to run, not what the store holds. Retained
        // journeys are in the same chained set and have all finished by
        // definition, so counting the set would have the status pill climb by a
        // few thousand over a session while the country carried on as it was.
        let clock = Timestamp((drawnAt ?? current).timeIntervalSince1970)
        status.vehicles = fleetByID().values.count { Positioning.standsUntil($0) >= clock }
    }

    /// The fleet as physical vehicles rather than numbered legs.
    ///
    /// Chaining scans the whole store, so it is rebuilt only when the store has
    /// actually changed — the map reads this many times per refresh.
    private func fleetByID() -> [String: Journey] {
        if chainedRevision != revision {
            let vehicles = Chains.build(standing())
            chained = Dictionary(vehicles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            chainedRevision = revision
            indexChainParts()
            // `Chains.build` makes a new object for every joined vehicle, and
            // a refresh bumps `revision` so the new times are the ones the
            // map reads. Without this those new objects had no path, and the
            // first frame after a tap drew every chained vehicle on the
            // chord until `alignToTrack` remembered — which it does not, for
            // a bus in a crowded viewport.
            restoreMemoisedGeometry()
        }
        return chained
    }

    /// Which chained vehicle each raw journey was flattened into.
    ///
    /// Only the joined ones are in here. An unjoined journey *is* its own
    /// chained vehicle — the same object — so there is nothing to look up and
    /// nothing for `refold` to do.
    private var chainOf: [String: String] = [:]

    private func indexChainParts() {
        chainOf.removeAll(keepingCapacity: true)
        for vehicle in chained.values {
            guard let parts = vehicle.parts else { continue }
            for part in parts { chainOf[part.id] = vehicle.id }
        }
    }

    /// Put kept paths back onto journeys that have just been rebuilt.
    ///
    /// The memo is the only thing that still knows a path after chaining
    /// replaces the object it was attached to. Walked from the memo rather
    /// than from the fleet: a few hundred kept paths, not the whole country.
    private func restoreMemoisedGeometry() {
        for (id, held) in builtGeometry {
            guard let journey = chained[id], journey.geometry == nil else { continue }
            guard held.fingerprint == Self.callFingerprint(journey.stops) else { continue }
            journey.geometry = held.geometry
            journey.legsFromRoute = held.fromRoute
            journey.legsFromGraph = held.fromGraph
        }
    }

    /// The chained fleet as a plain array, for the queries that live in another
    /// file of this module.
    func fleetVehicles() -> [Journey] { Array(fleetByID().values) }

    // MARK: - Which of the four things a cable service is

    /// Answered once per line and then remembered. There are 78 cable lines in
    /// the country and a busy gondola puts forty cabins on one of them.
    private var cableKinds: [String: LayoutLibrary.CableKind] = [:]

    /// Shortest an aerial ropeway gets, in metres.
    ///
    /// Below this it is not a ropeway, it is a lift. The Matte–Münsterplattform
    /// in Bern is a hundred metres of inclined elevator up the side of the
    /// Aare terrace, filed under the same mode as the Schilthornbahn, and it
    /// runs in a concrete shaft rather than on a rope. Nothing in the data says
    /// so; its length does.
    static let shortestRopeway = 250.0

    /// Which of the four vehicles this cable service runs.
    ///
    /// **The feed states this and the packed archive does not.** SIRI carries a
    /// product category — `GB`, `LB`, `FUN` — and where there is one it is
    /// taken and nothing here is guessed at. But the timetable pack collapses
    /// GTFS's route types to one `Mode` per route before the app ever sees
    /// them, so every cable run read out of the archive arrives with
    /// `category == nil`; and since the archive is where nearly all of them
    /// come from, "unstated" is the normal case rather than the corner. Left at
    /// the old default, every ropeway in the Alps was drawn as a funicular car
    /// standing on the mountainside.
    ///
    /// **So it is inferred, and the inference is a fact about the ground rather
    /// than a guess about the name.** A funicular runs on rails. Those rails
    /// are in OpenStreetMap as `railway=funicular`, they are in the packed
    /// graph under the `funicular` class, and `RailNet` will route a leg over
    /// them. An aerial ropeway runs on a rope, which is in no graph at all —
    /// so a cable leg the graph cannot route is a cable leg with nothing under
    /// it, and a vehicle with nothing under it hangs.
    ///
    /// Measured over the whole national timetable: of 78 cable lines, 26 route
    /// over funicular track and **every one of them is a funicular** — the
    /// Polybahn, the Dolderbahn, the Harderbahn, Territet–Glion, the four
    /// Neuchâtel FUNIs, Ligerz–Prêles. The other 52 route over nothing and all
    /// but one are ropeways — the Riederalpbahn, the Schilthornbahn, Weggis–
    /// Rigi Kaltbad, and the whole shelf of Valais village Luftseilbahnen at
    /// Unterbäch, Eischoll, Jeizinen, Gspon and Isérables. The exception is the
    /// Emosson Minifunic, a funicular too small for anyone to have mapped, and
    /// it says `FUN` in its own line code.
    ///
    /// The name rules are only there for that last case and for the lifts. They
    /// are read before the graph, because a service that says what it is should
    /// be believed ahead of an inference about it.
    func cableKind(of journey: Journey) -> LayoutLibrary.CableKind? {
        if let stated = LayoutLibrary.cableKind(of: journey.category) { return stated }
        guard journey.mode == .cable else { return nil }

        let key = "\(journey.operatorName ?? "")|\(journey.line)"
        if let known = cableKinds[key] { return known }
        let resolved = resolveCable(journey)
        // Remembered only once there is a graph to have asked. Half of this
        // answer is "the search found no track", and a search that could not
        // run finds no track either — so an answer reached before `railnet.bin`
        // was mapped would put every funicular in the country on a rope, and
        // being memoised it would stay there for the life of the process.
        if railnet.isReady { cableKinds[key] = resolved }
        return resolved
    }

    /// Words a service uses about itself, in the four languages it might.
    ///
    /// **Matched as whole words, and that is not fussiness.** The first version
    /// of this looked for the substring `funi`, which is how the app decided
    /// that the San Carlo–Robiei *funivia* was a funicular. It is not: `funivia`
    /// is Italian for an aerial cableway, and it is one of the longest ropeways
    /// in the country. Half of Europe's words for both machines start with the
    /// same four letters, so the text is cut into words and the words are
    /// compared — `funi` on its own, as the timetable abbreviates it in
    /// `Cossonay-Penthalaz (funi)`, is a funicular; `funivia` is not.
    ///
    /// `Standseilbahn` and `Drahtseilbahn` are the same trap in German. All
    /// three compounds end in `seilbahn`, and two of them are funiculars while
    /// `Luftseilbahn` — air-rope-railway — is the one that flies, so searching
    /// for the ending would get every one of them wrong.
    private static let saysFunicular: Set<String> = [
        "funi", "funicular", "funiculaire", "funicolare", "funicolar",
        "standseilbahn", "standseilb", "drahtseilbahn", "minifunic",
    ]
    private static let saysGondola: Set<String> = [
        "gondelbahn", "gondola", "gondelb", "telecabine", "cabinovia",
    ]

    private func resolveCable(_ journey: Journey) -> LayoutLibrary.CableKind {
        // Everything the service says about itself, cut into words. Accents
        // folded away because the same name is written `téléphérique` and
        // `telepherique` in one timetable.
        let said = Set(
            ([journey.line, journey.to] + journey.stops.map(\.name))
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_CH"))
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        if !said.isDisjoint(with: Self.saysFunicular) { return .funicular }

        guard journey.stops.count >= 2 else { return .funicular }

        // Rails under it, on the class of graph a funicular is mapped in. Asked
        // leg by leg because a line with a mid-station may have one leg the
        // graph is missing, and one routed leg is enough: an aerial ropeway
        // does not route anywhere.
        for i in 1..<journey.stops.count {
            let from = journey.stops[i - 1].coord
            let to = journey.stops[i].coord
            guard Geo.metres(from, to) > 1 else { continue }
            // Prefixed, so this can never read or write the entry
            // `GeometryBuilder` keeps for the same pair of stops. The two ask
            // the same question of the graph but they are not the same
            // question of the cache: one is "draw this leg" and is allowed to
            // be answered by whatever a previous mode's mask found, and this
            // one is a classification that must only ever see funicular track.
            let cacheKey = String(
                format: "cable|%.5f,%.5f|%.5f,%.5f", from.lat, from.lon, to.lat, to.lon
            )
            if let path = railnet.routeLeg(
                key: cacheKey, from: from, to: to, mode: .cable
            ), path.count > 1 {
                return .funicular
            }
        }

        // Nothing under it, so it hangs — but only if it is long enough to be a
        // ropeway at all. See `shortestRopeway`.
        let span = Geo.length(of: journey.stops.map(\.coord))
        guard span >= Self.shortestRopeway else { return .funicular }
        // A gondola where the name says so, and an aerial tramway car
        // otherwise. That default is the right way round for this country's
        // *timetabled* ropeways, which is what this is choosing for: the public
        // network is mostly village Luftseilbahnen — Unterbäch, Eischoll,
        // Jeizinen, Gspon, Isérables — carrying one big car apiece, and the
        // continuous gondolas on it are the minority and usually say
        // `Gondelbahn` on the station.
        return said.isDisjoint(with: Self.saysGondola) ? .tramway : .gondola
    }

    // MARK: - Which journeys call where

    /// The indexed fleet, and the index: stop identity to the journeys calling
    /// under it. Rebuilt with the chained fleet, and only when a board asks.
    private var callIndexRevision = -1
    private var indexedFleet: [Journey] = []
    private var callersByKey: [String: [Int32]] = [:]

    /// `StopRegister.stationOf` is string surgery — a substring search, a split
    /// and a join — and the same few thousand SLOIDs come round again and again
    /// across half a million calls. Answered from a table instead. It is a pure
    /// function of its argument, so this never needs clearing.
    private var stationOfRef: [String: String] = [:]
    private func stationOf(_ ref: String) -> String {
        if let known = stationOfRef[ref] { return known }
        let station = StopRegister.stationOf(ref)
        stationOfRef[ref] = station
        return station
    }

    /// Which journeys are worth asking about a stop, out of the whole country.
    ///
    /// A board used to be a linear walk of every call in the feed — 17,900
    /// journeys and half a million calls, with `stationOf` run on each one.
    /// Measured on the real national snapshot that is 690 ms for **one** board,
    /// and answering a tap builds up to sixteen of them: the ranking asks for
    /// one or two, and the picker asks for four of each kind it offers. It was
    /// the whole of the half-second freeze on selecting anything.
    ///
    /// The predicates that decide what belongs on a board are untouched and
    /// still run. This only says which journeys they are run *on*, and it is
    /// deliberately a superset of what can match: every way a call can be
    /// recognised is a key here. The station its SLOID belongs to, which covers
    /// both the platform-level `ch:1:sloid:7000:1:21` and station-level
    /// `ch:1:sloid:7000` forms the feed mixes — and separately the call's own
    /// name, which is the last-resort join for a stop the two sources spell
    /// differently. A station key and a stop name cannot collide, so one table
    /// holds both.
    private func callers(matchingAnyOf keys: some Sequence<String>) -> [Journey] {
        buildCallIndexIfNeeded()
        var slots = Set<Int32>()
        for key in keys {
            guard let found = callersByKey[key] else { continue }
            slots.formUnion(found)
        }
        return slots.map { indexedFleet[Int($0)] }
    }

    private func buildCallIndexIfNeeded() {
        let fleet = fleetByID()
        guard callIndexRevision != chainedRevision else { return }
        callIndexRevision = chainedRevision
        indexedFleet = Array(fleet.values)
        callersByKey.removeAll(keepingCapacity: true)
        callersByKey.reserveCapacity(indexedFleet.count * 2)
        for (position, journey) in indexedFleet.enumerated() {
            let slot = Int32(position)
            for stop in journey.stops {
                if let ref = stop.ref {
                    callersByKey[stationOf(ref), default: []].append(slot)
                }
                callersByKey[stop.name, default: []].append(slot)
            }
        }
    }

    // MARK: - Queries

    /// Every vehicle inside `bbox` at `now`, with geometry attached for the
    /// ones close enough to be drawn on their track.
    ///
    /// `detailed` is the viewport the user is actually looking at. Attaching
    /// geometry means matching a relation and possibly routing a leg over a
    /// 573,000-node graph, which is not work to do for a vehicle two cantons
    /// away that is one pixel wide.
    /// `fraction` is the part of a second `now` has lost, and it is the whole
    /// difference between a fleet that glides and one that hops. See
    /// `Positioning.position(of:at:)` in its `Double` form.
    ///
    /// `including` is a vehicle that has to come back even if it is no longer
    /// inside the box. Opening a train asks OJP about its delays, and folding
    /// those onto the timetable can move it kilometres in one tick — out of
    /// the viewport it was just drawn in. Without this, the map has nothing
    /// to pan to, and the train the reader tapped simply vanishes.
    ///
    /// `hiding` are the modes the reader has switched off. Applied here rather
    /// than by the caller because it was the caller's *last* filter and it
    /// belongs first: a bus nobody wants drawn should not be asked where it is,
    /// and it must not be allowed to take a place from a train that is — see
    /// `thinTheHidden`.
    ///
    /// `spacing` is how close together two vehicles have to be on the ground
    /// before the second one is only ever painted underneath the first. Zero,
    /// the default, draws every one of them. See `thinTheHidden`.
    public func vehicles(
        in bbox: BBox, at now: Timestamp, fraction: Double = 0, withGeometry detailed: Bool,
        including extraId: String? = nil, hiding: Set<Mode> = [],
        noCloserThan spacing: Double = 0
    ) -> [VehicleSnapshot] {
        let moment = Double(now) + min(1, max(0, fraction))
        // A little margin keeps vehicles from popping in exactly at the edge.
        let padded = bbox.padded(by: 0.15)

        // Who is in view, and where the timetable alone puts them. Separated
        // from the draw below so the geometry pass knows how many vehicles the
        // frame is about to show before it decides how to spend itself — and so
        // a vehicle that gets its track in this pass is drawn on it in this
        // frame rather than the next.
        var drawn: [(journey: Journey, position: VehiclePosition)] = []
        let hidden = !hiding.isEmpty
        for journey in fleetByID().values {
            // Rejected on what the journey *is* before it is asked where it
            // is, because asking is the expensive half and the answer is
            // thrown away for all but a screenful of them.
            //
            // A position is a walk into a call list and, for a train, an
            // interpolation along an attached path; the fleet is the whole
            // national timetable. Run for every journey on every frame — which
            // is what this loop used to do — a viewport a hundred metres across
            // cost exactly what a viewport of the whole country cost, and at
            // the zooms vehicles are drawn as vehicles that was the frame.
            //
            // **Order matters more than either test does.** The clock is two
            // comparisons against numbers already in hand and it throws out
            // three quarters of the fleet; the box has to be built the first
            // time it is asked for. Asking for the box first — which is what
            // the first version of this did — spends that build on every
            // journey in the country, including the ones that are not running
            // and were about to be dropped on the next line. See
            // `Journey.drawnWithin`.
            //
            // A mode the reader has switched off, before anything is spent on
            // it, and ahead of `extraId` because a hidden mode is hidden: the
            // caller used to drop these from the answer and this is the same
            // rule moved to where it costs one comparison against a value
            // already in hand instead of a position, a place in the thinning
            // and a snapshot. On a map showing trains only it clears four
            // fifths of the country before the clock test has to look at it.
            if hidden, hiding.contains(journey.mode) { continue }
            var gated = false
            if journey.id != extraId {
                // Exactly the bound `position` checks first, and checked here
                // so that everything below it can be skipped rather than
                // reached. Cheap enough to be worth repeating: a journey that
                // survives pays two comparisons twice.
                guard journey.stops.count >= 2,
                      moment >= Double(Positioning.appearsAt(journey)),
                      moment <= Double(Positioning.standsUntil(journey))
                else { continue }
                // Nowhere near the viewport. Exact — the box takes in the path
                // as well as the calls — so there is no mode this has to make
                // an exception for.
                if let box = journey.drawnWithin(), !padded.intersects(box) { continue }
                gated = true
            }
            guard let position = Positioning.position(
                of: journey, at: moment, settling: true, spanChecked: gated
            ) else { continue }
            if !padded.contains(lon: position.lon, lat: position.lat),
               journey.id != extraId {
                continue
            }
            drawn.append((journey, position))
        }

        // Before anything is spent on where these vehicles *really* are, drop
        // the ones that are going to be painted underneath another one.
        thinTheHidden(&drawn, noCloserThan: spacing, keeping: extraId)

        alignToTrack(&drawn, across: padded, at: moment)
        let drift = keepContinuous(drawn, at: moment)

        var out: [VehicleSnapshot] = []
        out.reserveCapacity(drawn.count)
        for i in drawn.indices {
            let journey = drawn[i].journey, position = drawn[i].position
            let shift = drift[i]
            out.append(VehicleSnapshot(
                id: journey.id, mode: journey.mode, category: journey.category,
                cable: cableKind(of: journey),
                line: journey.line, operatorName: journey.operatorName,
                operatorFull: journey.operatorFull, to: journey.to, from: journey.from,
                delay: journey.delay,
                lon: position.lon + (shift?.lon ?? 0), lat: position.lat + (shift?.lat ?? 0),
                bearing: position.bearing, moving: position.moving, speed: position.speed,
                index: position.index, progress: position.progress,
                complete: journey.complete, cancelled: journey.cancelled,
                stops: journey.stops, parts: journey.parts,
                geometry: detailed ? journey.geometry : nil,
                layover: journey.layover, onTrack: position.onTrack,
                extra: journey.extra, journeyRef: journey.journeyRef, drift: shift
            ))
        }
        return out
    }

    // MARK: - One dot per dot

    /// Which vehicles survived the last thinning pass, so the same ones survive
    /// this one. See `thinTheHidden`.
    private var drawnLastFrame: Set<String> = []

    /// Drop every vehicle that would be drawn underneath another vehicle.
    ///
    /// **A dot pulled back far enough stops being a position and becomes an
    /// area.** At zoom 6 the country is about four hundred points across and a
    /// point covers a kilometre, so Zurich, Bern, Geneva and Basel are each two
    /// or three points wide — and each of them has two or three hundred
    /// services standing in it. Six thousand vehicles are in view, of which
    /// something like a thousand land anywhere a reader could tell apart; the
    /// other five thousand are built into features, serialised, handed to the
    /// renderer, tessellated and painted every tick to put colour inside a disc
    /// that was already that colour.
    ///
    /// So they are not drawn. The rule is exact rather than a grid bucket: no
    /// two drawn vehicles end up closer together than `metres`, which is the
    /// caller's dot *radius* converted to ground — see `AppModel.dotSpacing`.
    /// A grid of that size is cheaper and was tried, and it is the wrong shape:
    /// two vehicles either side of a cell edge are a metre apart and both kept,
    /// while two in opposite corners of one cell are a cell diagonal apart and
    /// one is dropped. What is on screen is a property of the distance between
    /// them and of nothing else.
    ///
    /// Which vehicles survive is decided in a fixed order, and the order is
    /// the whole of whether the map flickers — see the sort below.
    ///
    /// Nothing is thinned when `metres` is zero, which is what the map asks for
    /// the moment a vehicle is more than a dot: a footprint is not hidden by
    /// the dot in front of it, two trains at one station are two trains, and a
    /// line number behind a dot is a service missing from the map.
    private func thinTheHidden(
        _ drawn: inout [(journey: Journey, position: VehiclePosition)],
        noCloserThan metres: Double, keeping extraId: String?
    ) {
        guard metres > 0, drawn.count > 1 else {
            if !drawnLastFrame.isEmpty { drawnLastFrame = [] }
            return
        }
        let count = drawn.count

        // Degrees, so the test is two subtractions and a compare rather than a
        // haversine per pair. Latitude is fixed at 111.32 km and longitude is
        // taken once at the middle of what is drawn: over a country two degrees
        // deep the cosine moves by three per cent, which is three per cent of a
        // dot's radius and nothing a reader could find.
        var midLat = 0.0
        for row in drawn { midLat += row.position.lat }
        midLat /= Double(count)
        let perLat = metres / Geo.metresPerDegree
        let perLon = metres / (Geo.metresPerDegree * max(0.2, cos(Geo.toRad(midLat))))

        // Everything the two passes below read, lifted out of the rows into
        // flat arrays first. Both of them are inner loops over tens of
        // thousands of pairs, and a row is a tuple carrying a class reference —
        // reaching through one to get at a `Double` is the difference between
        // this costing a millisecond and costing ten.
        var cellX = [Int32](repeating: 0, count: count)
        var cellY = [Int32](repeating: 0, count: count)
        var unitX = [Double](repeating: 0, count: count)
        var unitY = [Double](repeating: 0, count: count)
        // The order the survivors are chosen in, packed into one integer so
        // that choosing it is a sort of numbers rather than of ids. See below
        // for what the order has to be and why.
        var rank = [UInt64](repeating: 0, count: count)
        var forced = -1
        for i in 0..<count {
            let journey = drawn[i].journey, position = drawn[i].position
            let x = position.lon / perLon, y = position.lat / perLat
            unitX[i] = x
            unitY[i] = y
            cellX[i] = Int32(min(1e9, max(-1e9, x.rounded(.down))))
            cellY[i] = Int32(min(1e9, max(-1e9, y.rounded(.down))))
            let held = drawnLastFrame.contains(journey.id) ? 1 : 0
            rank[i] = UInt64(held) << 35 | UInt64(journey.mode.drawOrder) << 32
                | UInt64(UInt32.max - Self.settle(journey.id))
            if journey.id == extraId { forced = i }
        }

        // **The order is what stops this flickering.** A greedy pass keeps
        // whoever it reaches first, so left alone the survivors would be
        // whatever order the fleet dictionary handed over — which is stable
        // between ticks and *not* stable across a refresh, so every two and a
        // half seconds a different thousand dots would be the drawn ones. The
        // order here is fixed and, in front of it, hysteretic:
        //
        //  1. whatever was drawn last frame, so a dot that is on the map stays
        //     on the map until something genuinely closes on it,
        //  2. then `Mode.drawOrder`, because the vehicle painted on top is the
        //     one the reader would have seen anyway — a train survives its bus,
        //  3. then a hash of the id, which settles the rest the same way every
        //     time. A hash rather than the id itself because this is the tie
        //     nearly every pair falls to, and comparing six thousand strings
        //     seventy-six thousand times is most of what the pass would cost.
        //
        // The fixed part does most of it and the hysteresis takes the rest:
        // measured over the national timetable at zoom 6, the drawn set turns
        // over about 1% a second with (1) in and about 2% without, the
        // difference being vehicles that cross from one neighbourhood into
        // another and would otherwise hand their place to whoever they landed
        // beside.
        var order = Array(0..<count)
        order.sort { rank[$0] > rank[$1] }
        // And the vehicle the caller named first of all, wherever it is and
        // whatever is on top of it: it is the one being followed or read, and
        // the camera has nothing to pan to without it. Moved to the front
        // rather than exempted from the test, so it hides its neighbours
        // instead of standing beside one of them.
        if forced >= 0, let at = order.firstIndex(of: forced), at != 0 {
            order.remove(at: at)
            order.insert(forced, at: 0)
        }

        // A grid of exactly one radius, so everything within a radius of a
        // candidate is in the nine cells around it and there is nothing else to
        // look at. Chained through `next` rather than held as an array per
        // cell: there are as many cells as there are vehicles, and six thousand
        // one-element arrays cost more to allocate than the whole pass.
        var head: [Int64: Int32] = [:]
        head.reserveCapacity(count)
        var next = [Int32](repeating: -1, count: count)

        var keep = [Bool](repeating: false, count: count)
        var drew = Set<String>()
        drew.reserveCapacity(count / 4)

        for i in order {
            let x = unitX[i], y = unitY[i]
            let cx = cellX[i], cy = cellY[i]
            var covered = false
            search: for dx in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    var j = head[Int64(cx + dx) << 32 | Int64(UInt32(bitPattern: cy + dy))] ?? -1
                    while j >= 0 {
                        let k = Int(j)
                        let dLon = unitX[k] - x, dLat = unitY[k] - y
                        if dLon * dLon + dLat * dLat < 1 { covered = true; break search }
                        j = next[k]
                    }
                }
            }
            if covered { continue }
            keep[i] = true
            drew.insert(drawn[i].journey.id)
            let key = Int64(cx) << 32 | Int64(UInt32(bitPattern: cy))
            next[i] = head[key] ?? -1
            head[key] = Int32(i)
        }

        drawnLastFrame = drew
        guard drew.count < count else { return }
        // Rebuilt in the order it arrived in rather than in the order it was
        // chosen in, because the caller sorts what comes back by draw order and
        // a stable sort would otherwise carry the hysteresis into the paint
        // order — the same two vehicles swapping which is on top.
        var kept: [(journey: Journey, position: VehiclePosition)] = []
        kept.reserveCapacity(drew.count)
        for i in 0..<count where keep[i] { kept.append(drawn[i]) }
        drawn = kept
    }

    /// A journey id as one number, for the tie-break in `thinTheHidden`.
    ///
    /// FNV-1a, and written out rather than taken from `hashValue` because
    /// Swift seeds string hashing per process: the order two vehicles are
    /// offered in would then be one thing in a test run and another in the next
    /// one, which is not something to leave in the path that decides what the
    /// map draws.
    private static func settle(_ id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    // MARK: - Nothing on the map jumps

    /// Where each vehicle was drawn last frame, and the correction it is still
    /// walking off.
    private struct LastDrawn {
        var lon: Double
        var lat: Double
        /// Where the timetable put it that frame, before the drift displaced
        /// it.
        ///
        /// **The jump has to be measured between these two and not between the
        /// drawn ones.** A drift is a displacement that shrinks, so the drawn
        /// position covers the whole gap in the fraction of a second the glide
        /// lasts — hundreds of metres per second, far more than any vehicle
        /// could have travelled. Measured against the drawn position that reads
        /// as a fresh jump on the very next frame, and the guard answers it by
        /// pinning the vehicle again, to the same spot, with a gap that is now
        /// bigger. It never converges: the vehicle stands still for good while
        /// the run it belongs to carries on without it, which is "I zoom in and
        /// the transport freezes". The honest position's own step is the only
        /// thing that says whether anything actually jumped.
        var honestLon: Double
        var honestLat: Double
        /// The moment that frame was drawn *for*, not the wall clock it was
        /// drawn at. The map runs on a clock the reader can scrub, and a scrub
        /// is not a jump: the whole fleet is somewhere else because it is a
        /// different time, and easing that would be a lie.
        var moment: Double
        var drift: Drift?
    }

    /// A displacement being eased away, in degrees.
    private struct Drift {
        var lon: Double
        var lat: Double
        var from: Double
        var over: Double

        /// What is left of it, eased out the way `Positioning.settleShift`
        /// eases a re-time: most of the ground covered early and arriving
        /// gently, which reads as the map correcting itself rather than as the
        /// vehicle being dragged.
        func left(at now: Double) -> (lon: Double, lat: Double)? {
            let age = now - from
            guard age >= 0, age < over else { return nil }
            let share = 1 - age / over
            return (lon * share * share, lat * share * share)
        }
    }

    private var lastDrawn: [String: LastDrawn] = [:]

    /// Turn any move the timetable does not account for into a glide.
    ///
    /// A vehicle's position is a fraction of the way along a *path*, and which
    /// path that is depends on how much geometry the frame could afford: the
    /// straight line between two stops until something attaches the corridor it
    /// really runs on, and the corridor until the graph bends it onto its
    /// platform. Those are three different places, up to a couple of kilometres
    /// apart on a train going round a lake, and the vehicle moves between them
    /// the instant the path underneath it changes.
    ///
    /// Which is why zooming in moved everything. `alignToTrack` gives every
    /// train its corridor at any zoom, but a bus or a tram gets nothing at all
    /// until the viewport thins out — so the pinch that crossed that line
    /// attached a path to every one of them at once and each stepped onto it.
    /// `alignEverywhereAcross` is the half of the fix that stops that happening;
    /// this is the half that covers everything it cannot reach. Measured over a viewport of Bern, attaching geometry
    /// moves a vehicle a median of 10 m and a bus's ninetieth percentile 55 m,
    /// about half of it along the track and half across it. Even without the
    /// zoom the eight-millisecond `geometryBudget` means they arrive a few per
    /// frame, so they hop one after another for a second or two and then settle
    /// — which is exactly what a reader sees and describes as teleporting.
    ///
    /// `Journey.settle` already fixes the same complaint for live times, and
    /// deliberately holds its correction in seconds so the vehicle cannot leave
    /// its rails. That is the right answer for a re-time and no answer at all
    /// here: half of this move is *across* the path, and no amount of winding
    /// the clock walks a vehicle sideways onto a track it was not on. So this
    /// one is held in degrees, and the whole vehicle — coaches included — is
    /// drawn displaced by it while it decays. See `VehicleSnapshot.drift`.
    ///
    /// Deliberately about the *drawn* position rather than about geometry, so
    /// it does not care what moved the vehicle. A path attached, a path
    /// refined, a re-chain handing back an object whose memoised path was
    /// evicted, a fold the glide could not cover: all of them are the same
    /// thing from the reader's side, and all of them are covered by measuring
    /// what the last frame put on screen.
    private func keepContinuous(
        _ drawn: [(journey: Journey, position: VehiclePosition)], at moment: Double
    ) -> [Coord?] {
        var drifts = [Coord?](repeating: nil, count: drawn.count)
        // Rebuilt rather than updated, which is what prunes it: a vehicle that
        // has left the map is a vehicle this frame did not draw.
        var next: [String: LastDrawn] = [:]
        next.reserveCapacity(drawn.count)

        for i in drawn.indices {
            let id = drawn[i].journey.id
            let position = drawn[i].position
            let was = lastDrawn[id]
            var drift = was?.drift
            if drift?.left(at: moment) == nil { drift = nil }

            if let was {
                let since = moment - was.moment
                // Forward, and recently. Not a scrub, not a vehicle panned away
                // from and come back to, and not the same frame asked for twice.
                if since > 0, since <= Self.continuityWindow {
                    // The step the *honest* position took, which is the only
                    // move that can be a jump. See `LastDrawn.honestLon`.
                    let jumped = Geo.metres(
                        Coord(lon: was.honestLon, lat: was.honestLat),
                        Coord(lon: position.lon, lat: position.lat)
                    )
                    // What it could have covered honestly in that time. Twice
                    // over, because `Motion.profile` runs a leg at anything but
                    // a constant speed and `speed` is the reading at one end of
                    // the interval.
                    let honest = position.speed / 3.6 * since * 2 + Self.continuityFloor
                    if jumped > honest {
                        // Pinned to where the last frame drew it, so this frame
                        // starts exactly there. Replaces whatever was in flight
                        // rather than adding to it: the gap is measured against
                        // the drawn position, so it already contains it — and
                        // it is the gap, not the jump, that says how much
                        // ground the glide has to walk off.
                        let gap = Geo.metres(
                            Coord(lon: was.lon, lat: was.lat),
                            Coord(lon: position.lon, lat: position.lat)
                        )
                        drift = jumped <= Self.continuityCeiling
                            ? Drift(
                                lon: was.lon - position.lon, lat: was.lat - position.lat,
                                from: moment, over: Self.continuityOver(gap)
                            )
                            : nil
                    }
                }
            }

            let shift = drift?.left(at: moment)
            if shift == nil { drift = nil }
            if let shift { drifts[i] = Coord(lon: shift.lon, lat: shift.lat) }
            next[id] = LastDrawn(
                lon: position.lon + (shift?.lon ?? 0),
                lat: position.lat + (shift?.lat ?? 0),
                honestLon: position.lon, honestLat: position.lat,
                moment: moment, drift: drift
            )
        }
        lastDrawn = next
        return drifts
    }

    /// How stale a frame may be and still be one this frame has to be
    /// continuous with.
    ///
    /// Longer than the slowest tick the map runs — a whole second, below the
    /// zoom at which nothing visibly moves — and short enough that a vehicle
    /// panned away from and returned to simply appears where it is rather than
    /// gliding in from where it used to be.
    static let continuityWindow: Double = 1.5

    /// The smallest unexplained move worth easing. Under this the correction is
    /// smaller than the vehicle is drawn at any zoom that shows one.
    static let continuityFloor: Double = 6

    /// Past this it is not a correction to a vehicle in the same place, and it
    /// snaps.
    ///
    /// Generous, because the honest corrections *are* large: a chord across a
    /// lake and the rails around it are kilometres apart, and the widest one
    /// measured over the national timetable is an intercity on a leg with no
    /// OSM relation to match, drawn 5.8 km from its route until the graph
    /// answered. At the width that happens at, that is still six points on a
    /// phone — visible, and worth gliding. Twenty kilometres is past anything a
    /// path can be wrong by and short of a vehicle that has become a different
    /// vehicle, which is the case this refuses to slide across the country.
    static let continuityCeiling: Double = 20_000

    /// How long an unexplained move takes to walk off.
    ///
    /// The same shape and the same reasoning as `Positioning.settleOver`: short,
    /// and only weakly longer for a bigger correction. The glide exists to give
    /// the eye something to follow, not to act the correction out.
    static func continuityOver(_ metres: Double) -> Double {
        0.35 + min(0.45, metres / 500)
    }

    /// Put as many of the vehicles about to be drawn onto their real track as
    /// this frame can afford, and move them there before it draws.
    ///
    /// Two things used to leave a vehicle on the chord for far longer than the
    /// budget claims:
    ///
    /// The budget was a deadline set *before* a loop that walks the whole
    /// national fleet asking each journey where it is. That walk alone can cost
    /// the eight milliseconds, so by the time the loop reached a vehicle that
    /// needed building the deadline had usually passed and only the one the
    /// loop guaranteed got built. A screenful took seconds, not a frame or two.
    /// Timed over the attach calls themselves, the budget buys building.
    ///
    /// And building was gated on the zoom the *line* becomes worth drawing at.
    /// But the line is not the only thing geometry decides: it is also where
    /// the vehicle *is*, and a chord cuts corners at every zoom — across a lake
    /// at ten, across a valley at eight. The gate here is the count instead, so
    /// the position is right wherever the map is showing few enough vehicles
    /// for it to be affordable, which includes every zoom a vehicle can be
    /// picked out and tapped at.
    ///
    /// Trains are the exception, and they have to be. A bus on the chord is on
    /// the road it is already on; a train on the chord is across the lake the
    /// rails went around. The count gate used to skip *everyone* once the
    /// viewport held more than a screenful — which is exactly the zoom a long
    /// train is still visible as a thing in the wrong place, and the zoom-in
    /// that then attached its path is the teleport onto the track.
    ///
    /// So trains are aligned in two passes. The first matches each to its OSM
    /// relation — cheap, and enough to put the vehicle on the rails rather
    /// than the chord — and it runs for every train in view, crowd or not.
    /// The second bends onto platforms and fills gaps from the graph, and
    /// that one still spends the budget. Everything else still waits for the
    /// viewport to thin out.
    private func alignToTrack(
        _ drawn: inout [(journey: Journey, position: VehiclePosition)],
        across bbox: BBox, at now: Double
    ) {
        // How wide the map is, which is the only thing that decides whether
        // being in the wrong place can be seen.
        //
        // This used to count vehicles — align everything below a screenful,
        // nobody above it — and a count is a proxy for what the work *costs*
        // rather than for whether it buys anything. The two come apart at
        // exactly the wrong moment: a pinch crosses the count somewhere in the
        // middle of the gesture, so the frame that crosses it hands a path to
        // every bus and tram at once and each of them steps onto it. That is
        // the "everything jumps when I zoom in" this is being changed for.
        //
        // Measured cold against the national timetable, with the relation index
        // already loaded, attaching *both* halves to everything in view costs
        //
        //     a street    29 in view    3 ms
        //     a district  67 in view    5 ms
        //     a city     114 in view   10 ms
        //     a canton   338 in view   32 ms
        //     the country 2228 in view 205 ms
        //
        // paid once and then memoised, so the frame after it is free. The gate
        // is where that stops being affordable — and by then a ten-metre error
        // is a twentieth of a point, so there is nothing above it worth buying.
        let mid = (bbox.south + bbox.north) / 2
        let across = Geo.metres(
            Coord(lon: bbox.west, lat: mid), Coord(lon: bbox.east, lat: mid)
        )
        let coarse = across > Self.alignEverywhereAcross

        // One budget over both halves, spent in the order a reader would spend
        // it: corridors before platform bends, trains before everything else
        // within each.
        //
        // **The corridor half used to be charged to nothing at all**, on the
        // reasoning that it is not decoration but *where the vehicle is*, and a
        // vehicle drawn on the chord for one frame and moved afterwards has
        // already jumped. The reasoning is right about one vehicle and says
        // nothing about three hundred. Measured cold on the frame a pinch
        // reaches Bern, the corridor half alone is **4.6 seconds over 313
        // builds** — a median of half a millisecond and a tail of rural bus
        // routes at 300 to 700 ms each, because matching a long route to its
        // OSM relation is not the flat cost the median suggests. The graph half
        // beside it is another 4.3 s. Nine seconds on the actor the draw loop
        // is queued behind, and nothing on the map moves for any of it.
        //
        // A frame that cannot afford a corridor draws that one vehicle on its
        // chord and picks it up on the next, and `keepContinuous` eases the
        // step when it lands. That is a much smaller thing to be wrong about
        // than the whole map stopping.
        var spent: TimeInterval = 0

        // Trains walk past the width gate. A bus on the chord is on the road it
        // is already on; a train on the chord is across the lake the rails went
        // around, and a pixel-wide train in a lake is still in a lake.
        for i in drawn.indices where drawn[i].journey.mode == .train {
            if !attachCorridor(&drawn, at: i, now: now, spent: &spent) { return }
        }
        if !coarse {
            for i in drawn.indices where drawn[i].journey.mode != .train {
                if !attachCorridor(&drawn, at: i, now: now, spent: &spent) { return }
            }
        }

        // And the graph half — the platform bend and the run-up — which is
        // worth a few metres rather than a few hundred, and so is the half that
        // gives way first when the budget is short.
        for i in drawn.indices where drawn[i].journey.mode == .train {
            if !alignDrawn(&drawn, at: i, now: now, spent: &spent) { return }
        }
        guard !coarse else { return }
        for i in drawn.indices where drawn[i].journey.mode != .train {
            if !alignDrawn(&drawn, at: i, now: now, spent: &spent) { return }
        }
    }

    /// Put one vehicle on its OSM corridor, and say whether the frame has any
    /// budget left. See `alignToTrack` for why this is charged at all.
    private func attachCorridor(
        _ drawn: inout [(journey: Journey, position: VehiclePosition)],
        at i: Int, now: Double, spent: inout TimeInterval
    ) -> Bool {
        if drawn[i].journey.geometry != nil { return true }
        let started = Date()
        _ = attachGeometry(to: drawn[i].journey, refined: false)
        spent += Date().timeIntervalSince(started)
        if let aligned = Positioning.position(of: drawn[i].journey, at: now) {
            drawn[i].position = aligned
        }
        return spent < Self.geometryBudget
    }

    /// Attach this vehicle's path and move it onto it, if this frame can still
    /// afford a build.
    ///
    /// Returns whether the caller should keep going. A memo hit is not charged:
    /// it is the path a previous frame already paid for, and spending the
    /// budget on remembering it is how a refresh put every train back on the
    /// chord for one more zoom. A build is always finished before this returns
    /// — the first vehicle of a frame makes progress however expensive it was,
    /// and only the next one is refused.
    /// Build one vehicle's refined path, and say whether the frame has any
    /// budget left.
    ///
    /// **The budget applies on every pass, and that is the whole of "the tick
    /// freezes for ten seconds when I zoom into a city".** It used to be
    /// switched by a `capped` flag wired to whether the viewport was *wider*
    /// than `alignEverywhereAcross` — so a frame spent as long as it liked
    /// whenever the map was close in, which is precisely the zoom that puts
    /// four hundred vehicles in view and gives every one of them a graph search
    /// on the same frame. Measured cold on a pinch from the country to Bern,
    /// the frame that crossed into the city took **14.3 seconds** on the actor
    /// the draw loop is queued behind, and the whole map — every vehicle, the
    /// clock, the panel — stopped with it.
    ///
    /// The flag read as a cost control and did the opposite: it bounded the
    /// case where the work is invisible and let the visible case run
    /// unbounded. There is nothing the width has to say about it. Eight
    /// milliseconds of building per frame is what the frame can afford, at
    /// every zoom, and a vehicle still waiting is drawn on the corridor the
    /// cheap half already gave it rather than on nothing.
    private func alignDrawn(
        _ drawn: inout [(journey: Journey, position: VehiclePosition)],
        at i: Int, now: Double, spent: inout TimeInterval
    ) -> Bool {
        if let geometry = drawn[i].journey.geometry, geometry.refined { return true }
        let started = Date()
        let built = attachGeometry(to: drawn[i].journey, refined: true)
        if built { spent += Date().timeIntervalSince(started) }

        // Read the position again rather than leaving the chord to be drawn
        // for one more frame. The jump onto the track is the thing being
        // removed here, and making it a frame later is still making it.
        if let aligned = Positioning.position(of: drawn[i].journey, at: now) {
            drawn[i].position = aligned
        }
        return !built || spent < Self.geometryBudget
    }

    /// Put every running train on its mapped corridor.
    ///
    /// The draw loop still does this for whatever is in view, but a launch
    /// that opens on the country would otherwise spend the first second
    /// matching relations one train at a time — and a pinch onto one of them
    /// in that second is the teleport. Done here, once, behind the loading
    /// curtain, so the first frame already has them on the rails.
    public func warmTrainGeometry(
        at now: Timestamp = Timestamp(Date().timeIntervalSince1970)
    ) {
        let moment = Double(now)
        for journey in fleetByID().values where journey.mode == .train {
            guard Positioning.position(of: journey, at: moment) != nil else { continue }
            attachGeometry(to: journey, refined: false)
        }
    }

    /// The same warm, in batches, with the actor handed back between them.
    ///
    /// This used to run behind the loading curtain, and measured on a warm
    /// container it was 776 ms of a 2.3 s launch — 35% of the wait, spent
    /// putting trains on rails nobody was looking at yet. The draw loop already
    /// does this for whatever is in view (`alignToTrack` attaches a corridor to
    /// every train in the viewport, uncapped, precisely so it cannot be behind
    /// by a frame), and a cold first frame at zoom 9 costs 40 ms against 14 ms
    /// warm. Twenty-six milliseconds on the first frame is a better trade than
    /// three quarters of a second before it.
    ///
    /// So it runs *after* the curtain instead, and the country is warm within a
    /// second or two of the map appearing — which is what keeps a zoom out to
    /// the whole network from paying 264 ms of corridor matching in one frame.
    ///
    /// Batched with a suspension between, because `Fleet` is an actor and the
    /// draw loop is queued behind whatever is running on it. A single 776 ms
    /// call would be 776 ms in which no frame could be built; sixty-four trains
    /// at a time is a few milliseconds a slice, and a tap or a pan is answered
    /// in between.
    public func warmTrainGeometry(
        inBackground now: Timestamp, batch: Int = 64
    ) async {
        let moment = Double(now)
        let trains = fleetByID().values.filter { $0.mode == .train }
        var done = 0
        for journey in trains {
            if Task.isCancelled { return }
            guard journey.geometry == nil else { continue }
            guard Positioning.position(of: journey, at: moment) != nil else { continue }
            attachGeometry(to: journey, refined: false)
            done += 1
            if done % batch == 0 { await Task.yield() }
        }
    }

    /// Refine the paths of everything in view, a few at a time, off the frame.
    ///
    /// This is the fix for a vehicle that jumps when it is tapped.
    ///
    /// A tap goes through `journey(id:at:)`, which attaches *refined* geometry
    /// — legs bent onto platform rails, gaps filled from the routing graph.
    /// The draw loop mostly cannot: `alignToTrack` spends eight milliseconds a
    /// frame on refining and a busy viewport holds more than a thousand
    /// vehicles, so most of them are drawn on the corridor path instead. The
    /// two paths are different lengths, a position is interpolated along the
    /// path, and so the tap moved the vehicle. Measured over a Zurich viewport:
    /// 77% of vehicles moved, 41 of them by more than 250 m, the worst by
    /// 3.5 km — and tapping again moved it no further, because by then it was
    /// refined.
    ///
    /// Which way round the error runs matters. The refined path is the correct
    /// one, so this was never "tapping breaks the position" — it was the map
    /// drawing a train up to three kilometres from where it is, and the tap
    /// being the only thing that ever corrected it. Refining ahead of the
    /// finger fixes the tap by fixing the drawing.
    ///
    /// Returns whether there is more left to do, so a caller can keep asking
    /// until the viewport has settled and then stop.
    ///
    /// Skipped when the map is further out than the error can be seen from.
    ///
    /// The gate is the viewport's own width rather than a vehicle count, which
    /// is the honest way to ask the question: what matters is whether the
    /// correction is bigger than a pixel. Across a phone's ~390 points, a
    /// viewport `w` degrees wide is about `w · 194` metres to the point at Swiss
    /// latitudes — so the worst error seen, two kilometres, is four points at
    /// 2.5° and a quarter of a point at 40°. Past the threshold this would be
    /// several seconds of graph searches to move a dot by less than its own
    /// width, and it is also the zoom at which nobody is tapping a bus.
    ///
    /// Nearest the middle first, because that is where the next tap is, and
    /// because a pass is capped: an interrupted sweep should have spent itself
    /// on the vehicles somebody is looking at rather than on the corner of the
    /// screen.
    public func refineDrawn(
        in bbox: BBox, at now: Timestamp, batch: Int = 8, cap: Int = 200
    ) async -> Bool {
        guard bbox.east - bbox.west <= Self.refineWidestSpan else { return false }
        let moment = Double(now)
        let padded = bbox.padded(by: 0.15)
        let midLon = (bbox.west + bbox.east) / 2
        let midLat = (bbox.south + bbox.north) / 2

        var pending: [(journey: Journey, from: Double)] = []
        for journey in fleetByID().values {
            if let geometry = journey.geometry, geometry.refined { continue }
            // The clock and the box before the position, in that order, for
            // exactly the reasons `vehicles(in:at:)` gives: asking a journey
            // where it is is the expensive half, and this ran the whole
            // national timetable through it on every pass — with `keepRefining`
            // going straight round again whenever a pass found work, which on
            // a busy viewport is continuously.
            guard journey.stops.count >= 2,
                  moment >= Double(Positioning.appearsAt(journey)),
                  moment <= Double(Positioning.standsUntil(journey))
            else { continue }
            if let box = journey.drawnWithin(), !padded.intersects(box) { continue }
            guard let position = Positioning.position(
                of: journey, at: moment, settling: true, spanChecked: true
            ), padded.contains(lon: position.lon, lat: position.lat)
            else { continue }
            let dLon = position.lon - midLon, dLat = position.lat - midLat
            pending.append((journey, dLon * dLon + dLat * dLat))
        }
        guard !pending.isEmpty else { return false }
        if pending.count > cap { pending.sort { $0.from < $1.from } }

        var done = 0
        for entry in pending {
            if Task.isCancelled { return true }
            attachGeometry(to: entry.journey, refined: true)
            done += 1
            // Capped rather than run to the end, so a caller that re-reads the
            // viewport between passes follows a pan instead of finishing the
            // box the reader has already left.
            if done >= cap { return true }
            if done % batch == 0 { await Task.yield() }
        }
        return false
    }

    /// How wide a viewport may be, in degrees of longitude, before refining what
    /// is in it stops being worth the work. See `refineDrawn`.
    static let refineWidestSpan = 2.5

    /// One vehicle in view that nothing has yet said a live word about.
    public struct LiveTimingCandidate: Sendable, Hashable {
        /// The fleet's own key, to fold the answer back onto.
        public var id: String
        /// The reference OJP answers to, which is a different string. See
        /// `Journey.journeyRef`.
        public var ref: String
        public var day: String
    }

    /// Which vehicles on screen are still being drawn where the *timetable*
    /// puts them, nearest the middle first.
    ///
    /// This is the other half of the fix for a vehicle that jumps when it is
    /// tapped, and the half that stops the jump existing rather than hiding it.
    ///
    /// The map draws from `timetable.bin`, corrected by a national tick every
    /// minute or five. Delays for one run come from OJP, and until this existed
    /// the *only* thing that ever asked for them was opening the vehicle — so a
    /// run a minute down was drawn a minute's travel ahead of itself until the
    /// reader touched it, and the touch was what moved it back. `refineDrawn`
    /// had the same shape and the same answer: refining ahead of the finger
    /// fixed the tap by fixing the drawing, and so does this.
    ///
    /// `monitored` is the whole test. It is set by every path that folds a live
    /// time on — the national tick, a sighting, an OJP answer — so what is left
    /// is exactly the set nobody has said anything about.
    ///
    /// Skipped when the map is further out than the error can be seen from, and
    /// this gate is much tighter than the one `refineDrawn` uses. A refinement
    /// costs a graph search; this costs a request against a budget of fifty a
    /// minute shared with every panel the reader opens, so it is spent only
    /// where the reader is close enough to be picking a vehicle out.
    public func awaitingLiveTiming(
        in bbox: BBox, at now: Timestamp, limit: Int = 8
    ) -> [LiveTimingCandidate] {
        guard bbox.east - bbox.west <= Self.liveTimingWidestSpan else { return [] }
        let moment = Double(now)
        let padded = bbox.padded(by: 0.15)
        let midLon = (bbox.west + bbox.east) / 2
        let midLat = (bbox.south + bbox.north) / 2

        var pending: [(candidate: LiveTimingCandidate, from: Double)] = []
        for journey in fleetByID().values {
            if journey.monitored { continue }
            // Gated before the position is asked for, for the reason
            // `vehicles(in:at:)` gives. This sweep idles on a settled map by
            // design — one check a second — and an idle check was walking the
            // whole country through `Positioning.position` to find nothing.
            guard journey.stops.count >= 2,
                  moment >= Double(Positioning.appearsAt(journey)),
                  moment <= Double(Positioning.standsUntil(journey))
            else { continue }
            if let box = journey.drawnWithin(), !padded.intersects(box) { continue }
            guard let position = Positioning.position(
                of: journey, at: moment, settling: true, spanChecked: true
            ), padded.contains(lon: position.lon, lat: position.lat),
                  let handle = journeyRef(for: journey.id)
            else { continue }
            let dLon = position.lon - midLon, dLat = position.lat - midLat
            pending.append((
                LiveTimingCandidate(id: journey.id, ref: handle.ref, day: handle.day),
                dLon * dLon + dLat * dLat
            ))
        }
        guard !pending.isEmpty else { return [] }
        // Nearest the middle first, for the reason `refineDrawn` sorts: that is
        // where the next tap is, and a capped pass should spend itself on the
        // vehicles somebody is looking at.
        if pending.count > limit { pending.sort { $0.from < $1.from } }
        return pending.prefix(limit).map(\.candidate)
    }

    /// How wide a viewport may be before asking OJP about what is in it stops
    /// being worth a request. See `awaitingLiveTiming`.
    ///
    /// Across a phone's ~390 points a viewport `w` degrees wide is about
    /// `w · 194` metres to the point at Swiss latitudes, so at a third of a
    /// degree a bus a minute down is five points out of place and a train is
    /// twenty. Wider than this and the correction is smaller than the dot it
    /// would move, which is also the zoom at which nobody is tapping a bus.
    static let liveTimingWidestSpan = 0.34

    /// Attach geometry to `journey`, reusing what was built for it before the
    /// last refresh.
    ///
    /// Everything that needs a journey's path goes through here rather than
    /// through the builder, so the app pays once per run of a service rather
    /// than once per run per refresh.
    ///
    /// `refined` is the slower half: bending onto platforms and filling gaps
    /// from the graph. A corridor attach (`refined: false`) is enough to take
    /// a train off the chord, and a later refined attach replaces it.
    ///
    /// Returns whether the path had to be built from scratch. A memo hit is
    /// not a build: the draw loop must not spend its budget on remembering.
    ///
    /// Reachable from the rest of the module rather than private to this file:
    /// `rideCandidates` needs the same paths for the same reason the draw loop
    /// does — a chord cuts corners, and a corner is where a fit is decided.
    @discardableResult
    func attachGeometry(to journey: Journey, refined: Bool = true) -> Bool {
        if let geometry = journey.geometry {
            if geometry.refined || !refined { return false }
            journey.geometry = nil
        }
        guard journey.stops.count >= 2 else { return false }

        geometryUse += 1
        let fingerprint = Self.callFingerprint(journey.stops)

        if var held = builtGeometry[journey.id], held.fingerprint == fingerprint {
            if held.geometry.refined || !refined {
                journey.geometry = held.geometry
                journey.legsFromRoute = held.fromRoute
                journey.legsFromGraph = held.fromGraph
                held.usedAt = geometryUse
                builtGeometry[journey.id] = held
                return false
            }
        }

        builder.attach(to: journey, refined: refined)
        guard let built = journey.geometry else { return true }
        builtGeometry[journey.id] = BuiltGeometry(
            fingerprint: fingerprint, geometry: built,
            fromRoute: journey.legsFromRoute, fromGraph: journey.legsFromGraph,
            usedAt: geometryUse
        )
        evictGeometryIfNeeded()
        return true
    }

    /// Identifies the call list a path was built for.
    ///
    /// The stop keys alone are not enough. A call resolved to a different
    /// platform between one refresh and the next moves where the vehicle stands
    /// by the width of a track, which is the whole point of bending a leg onto
    /// the platform's own rail — so the coordinates are part of the identity,
    /// and so is the quay: OJP can re-platform a train without moving the
    /// published coordinate.
    private static func callFingerprint(_ stops: [Call]) -> Int {
        var hasher = Hasher()
        hasher.combine(stops.count)
        for stop in stops {
            hasher.combine(stop.key)
            hasher.combine(stop.platform)
            hasher.combine(Int((stop.lon * 100_000).rounded()))
            hasher.combine(Int((stop.lat * 100_000).rounded()))
        }
        return hasher.finalize()
    }

    /// Drop the least recently drawn paths once the memo is over its limit.
    ///
    /// Without this a session spent panning the country accumulates a path for
    /// every vehicle it has ever shown, held until the journey leaves the feed
    /// hours later. Least-recently-used because the map comes back to where it
    /// has been.
    private func evictGeometryIfNeeded() {
        guard builtGeometry.count > Self.geometryMemoLimit else { return }
        // Down to the low-water mark rather than back to the limit, and that is
        // the difference between an eviction that amortises and one that does
        // not. Trimming to exactly the limit leaves the memo full, so the very
        // next path built is over it again — and every build from then on pays
        // a fifteen-hundred-entry sort and a whole dictionary rebuilt, on the
        // actor a frame is waiting on. Taking a quarter off buys several
        // hundred builds before the next sort.
        let keep = builtGeometry
            .sorted { $0.value.usedAt > $1.value.usedAt }
            .prefix(Self.geometryMemoKeep)
        builtGeometry = Dictionary(keep.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Ask the mirror about a stop the national feed had nothing for.
    ///
    /// Returns whether anything new arrived, so the caller knows to re-read the
    /// board. Deliberately not called on the way *in*: the feed's answer is
    /// drawn immediately and this only improves on it, because a stop with no
    /// service left today should not wait on the network to say so.
    @discardableResult
    public func fillFromMirror(placeId: String, at now: Timestamp) async -> Bool {
        guard let place = stopPlaces.place(id: placeId) else { return false }
        if let asked = mirrorAsked[placeId], Date().timeIntervalSince(asked) < Self.mirrorTTL {
            return false
        }
        mirrorAsked[placeId] = Date()

        let found = await mirror.board(didok: place.id, at: now)
        guard !found.isEmpty else { return false }
        for journey in found { mirrored[journey.id] = journey }
        return true
    }

    /// The fleet as the feed filed it, before chaining or geometry.
    ///
    /// This is what the cache holds, so writing one is the same call the app
    /// makes after a refresh.
    public func everyRawJourney() -> [Journey] { Array(journeys.values) }

    /// Every vehicle in the loaded snapshot, with geometry attached.
    ///
    /// For measurement rather than for drawing — the map asks by viewport — but
    /// a claim about how the country is drawn has to be checkable over the whole
    /// of it rather than over whatever happens to be on screen.
    public func everyVehicle() -> [VehicleSnapshot] {
        fleetByID().values.map { journey in
            builder.attach(to: journey)
            return VehicleSnapshot(
                id: journey.id, mode: journey.mode, category: journey.category,
                cable: cableKind(of: journey),
                line: journey.line, operatorName: journey.operatorName,
                operatorFull: journey.operatorFull, to: journey.to, from: journey.from,
                delay: journey.delay, lon: journey.stops[0].lon, lat: journey.stops[0].lat,
                bearing: 0, moving: false, speed: 0, index: 0,
                complete: journey.complete, cancelled: journey.cancelled,
                stops: journey.stops, parts: journey.parts, geometry: journey.geometry,
                layover: journey.layover, extra: journey.extra,
                journeyRef: journey.journeyRef
            )
        }
    }

    /// One journey in full, whether or not a vehicle is on it at this moment.
    ///
    /// A board lists what leaves for the next hour or more, so most of it has
    /// not left yet — and those rows do nothing when tapped if the only place
    /// to look them up is a fleet that by construction does not hold them.
    public func journey(id: String, at now: Timestamp) -> VehicleSnapshot? {
        guard let journey = fleetByID()[id] ?? mirrored[id] else { return nil }
        // `refined: false`, and that one word is the whole of the fix for a
        // vehicle that jumped when it was tapped.
        //
        // This used to take the default and upgrade the path — bending legs
        // onto platform rails, filling gaps from the routing graph. The draw
        // loop mostly cannot afford that (`alignToTrack` has eight milliseconds
        // a frame for it and a busy viewport holds a thousand vehicles), so the
        // vehicle was on screen at its corridor position and this moved it to
        // its refined one the instant somebody touched it. Measured over a
        // Zurich viewport, 77% of vehicles moved, 41 of them by more than 250 m
        // and the worst by 3.5 km — and a second tap moved it no further,
        // because by then it was refined.
        //
        // Refining is still right and still happens: the draw loop spends its
        // budget on it and `refineDrawn` sweeps the viewport in the background.
        // What must not happen is a *reader's tap* being the thing that
        // triggers it, because a tap is the one moment the reader is looking
        // straight at the vehicle. Asking only that the journey have some path
        // — which a drawn vehicle always already does — makes this a read
        // rather than a write, and the panel now opens on the vehicle where the
        // map is drawing it.
        // No attach at all, and that is the point.
        //
        // `refined: false` was not enough: a vehicle the draw loop skipped has
        // no path yet — `alignToTrack` gives up on everything that is not a
        // train once the viewport is crowded — so asking for the cheap attach
        // still *built* one, and building one still moved the vehicle off the
        // chord it was drawn on. The tap has to be a read or it will always
        // move something.
        //
        // So the panel opens on the journey exactly as the map has it. Whatever
        // geometry it has is what the map drew it with; whatever it lacks, the
        // draw loop and `refineDrawn` supply within a frame or two, and the
        // vehicle moves then — ambiently, not under the reader's finger.
        let position = Positioning.position(of: journey, at: now)

        return VehicleSnapshot(
            id: journey.id, mode: journey.mode, category: journey.category,
            cable: cableKind(of: journey),
            line: journey.line, operatorName: journey.operatorName,
            operatorFull: journey.operatorFull, to: journey.to, from: journey.from,
            delay: journey.delay,
            lon: position?.lon ?? journey.stops[0].lon,
            lat: position?.lat ?? journey.stops[0].lat,
            bearing: position?.bearing ?? 0, moving: position?.moving ?? false,
            speed: position?.speed ?? 0, index: position?.index ?? 0,
            // Carried, and not defaulted away. `progress` is how anything that
            // draws the vehicle as a *vehicle* finds the point on the path its
            // body hangs off — see `VehicleFootprint.centreline`. Left at zero
            // it says "at the last stop", so a train mid-leg had its coaches
            // laid out along the track it had already run over: a body that
            // traces the right rails in the wrong place, which is what a tap
            // used to draw.
            progress: position?.progress ?? 0,
            complete: journey.complete, cancelled: journey.cancelled,
            stops: journey.stops, parts: journey.parts, geometry: journey.geometry,
            layover: journey.layover, onTrack: position?.onTrack ?? false,
            extra: journey.extra, journeyRef: journey.journeyRef
        )
    }

    /// Where a vehicle ends up once a correction in flight has been walked off,
    /// but only while that is somewhere the camera should be going.
    ///
    /// The camera catch-up is the caller, and it exists for a correction spent
    /// inside a frame or two: it fires on the frame a re-time lands, which is
    /// the frame the glide has by construction not moved the vehicle on yet, so
    /// measuring the jump from what is drawn would measure nothing and the
    /// camera would sit still while the train slid a kilometre out from under
    /// it. A vehicle that turns out to be *earlier* than the timetable said is
    /// exactly that case and still answers with its destination.
    ///
    /// A vehicle that turns out to be later is not. It gives its correction
    /// back by running slow over the rest of the leg rather than by reversing
    /// — see `Positioning.settleOver` — so where it "ends up" is minutes away
    /// and several kilometres down the line, and it never jumps out of shot on
    /// the way. Answering with that destination would throw the camera down the
    /// track to a platform the train has not reached, leaving the train the
    /// reader just tapped off screen: the catch-up would *cause* the lurch it
    /// exists to absorb.
    ///
    /// So a correction with further to run than `catchUpWithin` answers with
    /// where the vehicle is being drawn, which is where the camera already is.
    /// Nothing to catch up to, and nothing done.
    public func settledPosition(of id: String, at now: Timestamp) -> Coord? {
        guard let journey = fleetByID()[id] ?? mirrored[id] else { return nil }
        let moment = Double(now)
        let settling = (Positioning.settleShift(journey, at: moment) ?? 0) > 0
            && (journey.settle.map { $0.from + $0.over - moment } ?? 0) > Self.catchUpWithin
        guard let at = Positioning.position(
            of: journey, at: moment, settling: settling
        ) else { return nil }
        return Coord(lon: at.lon, lat: at.lat)
    }

    /// How soon a correction has to be over for the camera to be worth aiming
    /// at where it ends rather than at where the vehicle is now.
    ///
    /// A little longer than the longest forward glide `Positioning.settleOver`
    /// hands out, so the case the catch-up was written for still gets it.
    static let catchUpWithin: Double = 1.5

    /// Whether the journey behind an id is still running at `now`.
    ///
    /// The one thing worth knowing about a service while the phone has nothing
    /// to say about itself — in a tunnel, or with the app put away. A ride
    /// badge coasts on the last fit it made, and the only claim it is still
    /// entitled to make is that the train it names has not terminated. See
    /// `RideWatch.hold`.
    public func isRunning(id: String, at now: Timestamp) -> Bool {
        guard let journey = fleetByID()[id] ?? mirrored[id] else { return false }
        return Positioning.position(of: journey, at: now) != nil
    }

    /// The working that carries one half of a splitting train onward.
    ///
    /// For the splits the formation service does not file a relationship for.
    /// It always says *that* a train parts — the coach goals at every stop
    /// before the split name both destinations — and only sometimes says which
    /// two workings it parts into: the S44 from Burgistein has "coaches 1–4 to
    /// Solothurn, 5–8 to Sumiswald-Grünen" at every stop and a null
    /// `relationships`. With no journey id to look up, the half is found the
    /// way a passenger would: the train that leaves this station, about now,
    /// for that place.
    ///
    /// Deliberately narrow. The destination must match, the departure must be
    /// inside the hour after the trunk gets there, and the call must be the
    /// working's own origin — which is what a portion that has just been
    /// detached is. Nothing that fails all three is guessed at.
    public func onward(
        from stopName: String, notBefore moment: Timestamp, to destination: String,
        mode: Mode, at now: Timestamp
    ) -> VehicleSnapshot? {
        var best: (journey: Journey, dep: Timestamp)?
        for journey in fleetByID().values {
            guard journey.mode == mode, journey.stops.count >= 2,
                  let last = journey.stops.last,
                  Self.sameStop(last.name, destination)
            else { continue }
            // The parting has to be where this working *begins* — a detached
            // portion starts its own life there. A leg the feed renumbered and
            // this app chained into a longer vehicle counts too, which is why
            // the parts are checked as well as index zero: the Solothurn half
            // is often the second half of some other chained run.
            var origins = [0]
            origins.append(contentsOf: (journey.parts ?? []).map(\.start))
            for index in origins where journey.stops.indices.contains(index) {
                let call = journey.stops[index]
                guard Self.sameStop(call.name, stopName),
                      call.dep >= moment - 120, call.dep <= moment + 3600
                else { continue }
                if best == nil || call.dep < best!.dep { best = (journey, call.dep) }
            }
        }
        guard let found = best?.journey else { return nil }
        return journey(id: found.id, at: now)
    }

    /// Whether two names are one place written two ways.
    ///
    /// The feed and the formation service do not agree on punctuation or on
    /// what belongs in brackets — "Domodossola" against "Domodossola (I)",
    /// "Sumiswald-Grünen" against "Sumiswald-Gruenen" — so the comparison is on
    /// letters and digits alone, with diacritics folded away.
    static func sameStop(_ a: String, _ b: String) -> Bool {
        Self.squash(a) == Self.squash(b)
    }

    private static func squash(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US"))
            .filter { $0.isLetter || $0.isNumber }
    }

    /// How far from a station's own coordinate to treat a stop as part of it.
    ///
    /// A station is a place, not a point. "Bern" in the register is the railway
    /// station; the trams and buses out front are filed as "Bern, Bahnhof" and
    /// "Bern, Bollwerk". So the name alone answered "what leaves Bern" with
    /// trains only, which is not what anybody standing there means.
    static let stationSpread = 250.0

    /// Whether `name` is this station, or one of the stops within it.
    ///
    /// Proximity alone is worse than useless here: in a city centre 300 metres
    /// reaches several unrelated stops, and clicking Bern, Waisenhausplatz
    /// listed departures from Bärenplatz, Bundesplatz and Bollwerk — none of
    /// which are Waisenhausplatz. The comma is the separator the Swiss stop
    /// register uses for a stop inside a larger place, so it says what
    /// proximity cannot.
    static func partOfStation(_ name: String, _ stationName: String) -> Bool {
        name == stationName || name.hasPrefix("\(stationName), ")
    }

    /// The name the stop register holds for a UIC number.
    ///
    /// For the places another interface names by number alone — the formation
    /// service does it for every station outside Switzerland.
    public func stopName(uic: Int) -> String? { register.name(uic: uic) }

    /// The same for a handful of numbers at once, so a caller off the actor
    /// makes one hop rather than one per station.
    public func stopNames(uic numbers: Set<Int>) -> [Int: String] {
        var out: [Int: String] = [:]
        for number in numbers {
            if let name = register.name(uic: number) { out[number] = name }
        }
        return out
    }

    public func stationBoard(placeId: String, at now: Timestamp, limit: Int = 60) -> StationBoard? {
        guard let place = stopPlaces.place(id: placeId) else { return nil }
        return board(name: place.name, id: place.id, lon: place.lon, lat: place.lat, at: now, limit: limit)
    }

    public func stationBoard(near lon: Double, lat: Double, at now: Timestamp, limit: Int = 60) -> StationBoard? {
        guard let place = stopPlaces.nearest(lon: lon, lat: lat, within: 300) else { return nil }
        return board(name: place.name, id: place.id, lon: place.lon, lat: place.lat, at: now, limit: limit)
    }

    private func board(
        name: String, id: String, lon: Double, lat: Double, at now: Timestamp, limit: Int
    ) -> StationBoard {
        // Which SLOIDs count as "here".
        //
        // The feed references a stop at whichever level it likes. Two thirds of
        // calls name a platform — `ch:1:sloid:92770:0:25231` — and the rest name
        // the station itself, `ch:1:sloid:92770`. The first version matched only
        // the platform form, because the register index deliberately holds only
        // platform rows, and every rural bus stop in the country therefore
        // answered with an empty board: 3 of 60 stops tapped produced anything.
        //
        // Matching by name cannot rescue it, because the two sources spell the
        // same stop differently — the feed says `Dardagny-Les Tilleuls` where
        // the register says `Dardagny, Les Tilleuls`, and `Dardagny-Château`
        // against `Dardagny, château`. So the join is on the identifier, at both
        // levels: the station this place *is*, and the platforms belonging to it.
        var herePlatforms = Set<String>()
        var hereStations = Set<String>()
        // The kerbs this station is made of, so the mapped routes can be asked
        // about each of them rather than about the point between them.
        var kerbs: [Coord] = [Coord(lon: lon, lat: lat)]

        // Exact, and free: a DIDOK number is `85` plus the SLOID number.
        if let own = StopRegister.sloid(forDidok: id) { hereStations.insert(own) }

        if register.isReady {
            for stop in register.near(lon: lon, lat: lat, metres: Self.stationSpread)
            where Self.partOfStation(stop.name, name) {
                herePlatforms.insert(stop.id)
                hereStations.insert(StopRegister.stationOf(stop.id))
                kerbs.append(Coord(lon: stop.lon, lat: stop.lat))
            }
        }

        func callsHere(_ stop: Call) -> Bool {
            if let ref = stop.ref {
                if herePlatforms.contains(ref) { return true }
                if hereStations.contains(StopRegister.stationOf(ref)) { return true }
            }
            // Last resort, and exact rather than fuzzy: where the two sources do
            // happen to agree on a name, that is still an identifier.
            return stop.name == name
        }

        var found: [BoardEntry] = []
        var listed = Set<String>()
        /// One row for one run, wherever the run was read from.
        func list(_ journey: Journey) {
            guard let index = journey.stops.firstIndex(where: callsHere) else { return }
            let stop = journey.stops[index]
            // A departure board is about what is leaving, not what left. A
            // minute of grace covers a vehicle still standing there.
            if stop.dep < now - 60 { return }

            // Keyed twice, because the same run has two names here. A chained
            // journey carries its *first* leg's id — an S1 renumbered at
            // Gümligen is one row on the map and two trips in the file — so the
            // timetable's own row for the later leg is a different id for a
            // departure already on the board. The legs are claimed below; the
            // second key catches whatever chaining did not join.
            //
            // That key has to name the whole departure and not just its line
            // and minute: two directions of a city bus leave the same station
            // in the same minute all day, and they are two departures.
            guard listed.insert(journey.id).inserted else { return }
            guard listed.insert(
                "\(journey.mode.rawValue)|\(journey.line)|\(stop.dep)|\(stop.ref ?? stop.name)|\(journey.to ?? "")"
            ).inserted else { return }
            for part in journey.parts ?? [] { listed.insert(part.id) }

            found.append(BoardEntry(
                id: journey.id, mode: journey.mode, line: journey.line, to: journey.to,
                from: journey.stops[0].name, departure: stop.dep, arrival: stop.arr,
                platform: stop.platform ?? stop.assigned, delay: stop.delay ?? journey.delay,
                observed: stop.observed,
                stop: stop.name == name ? nil : stop.name,
                terminates: index == journey.stops.count - 1,
                originates: index == 0,
                running: Positioning.position(of: journey, at: now) != nil
            ))
        }

        // The national feed first, and the mirror's own sightings only if it
        // had nothing — so a service can never be listed twice.
        //
        // Narrowed by identity before anything is measured; see `callers`.
        // `herePlatforms` needs no key of its own, because every register row
        // that goes into it puts its own station into `hereStations` beside it.
        // The mirror is a handful of sightings around one stop and is walked as
        // it always was.
        var source = callers(matchingAnyOf: hereStations.union([name]))
        if !mirrored.isEmpty, !source.contains(where: { $0.stops.contains(where: callsHere) }) {
            source.append(contentsOf: mirrored.values)
        }
        for journey in source { list(journey) }
        for journey in scheduled(at: hereStations, from: now, filling: found.count, of: limit) {
            list(journey)
        }
        found.sort { $0.departure < $1.departure }

        return StationBoard(
            id: id, name: name, lon: lon, lat: lat, now: now,
            departures: Self.trim(found, to: limit),
            serving: servingLines(at: kerbs, besides: found)
        )
    }

    /// How far ahead a board reads when the drawn fleet runs out.
    ///
    /// A day, and the horizon is the point of it. The map holds an hour either
    /// side of now — see `timetableAhead`, which is about what can be *drawn* —
    /// and a board asked inside that hour and no further is wrong in exactly
    /// the places a board matters most: the Verkehrshaus lake landing whose
    /// next boat is at 21:35, Bern at one in the morning waiting on a Moonliner
    /// that leaves at 01:26, a village with four buses a day. Every one of
    /// those said "no data available", which reads as "nothing runs here" and
    /// was only ever "nothing runs here in the next hour".
    ///
    /// A day rather than a few hours because the failure it fixes is a stop
    /// with *one* departure left, and there is no cheaper horizon that catches
    /// the last boat of the evening from an afternoon. It costs an integer
    /// rejection per trip of the day and stops as soon as the board is full.
    public static let boardHorizon: TimeInterval = 24 * 3600

    /// How deep into the schedule a board reads before it is trimmed.
    ///
    /// Larger than the board, on purpose. The trim below keeps the next
    /// departure of every line, and a line running once a night is only found
    /// by reading past the line running every seven minutes — at Bern's stop M
    /// at 23:15, the 17 and the 19 fill forty rows before the Moonliner's 01:45
    /// is reached.
    static let boardDepth = 240

    /// The board, trimmed so a frequent line cannot crowd out a rare one.
    ///
    /// A count alone is the wrong cap for this panel, because the panel groups:
    /// forty rows of a bus every seven minutes draw as two rows with a
    /// disclosure on them, and the Moonliner that leaves stop M at 01:45 —
    /// which is the whole reason to look at that kerb at midnight — falls off
    /// the end of a list it was never really competing for. So the count is
    /// kept, and after it every service still unrepresented gets its next
    /// departure, up to a ceiling on how many a board is.
    ///
    /// Keyed as the panel groups — see `DepartureGroup.group`, which draws one
    /// row per line, destination and kerb.
    static func trim(_ entries: [BoardEntry], to limit: Int, services: Int = 24) -> [BoardEntry] {
        guard entries.count > limit else { return entries }
        var seen = Set<String>()
        var out: [BoardEntry] = []
        out.reserveCapacity(limit)
        for entry in entries {
            let key = "\(entry.mode.rawValue)|\(entry.line)|\(entry.to ?? "")|\(entry.stop ?? "")"
            let known = !seen.insert(key).inserted
            // Inside the count, everything; past it, only a service the board
            // has not named yet, and only while it is still a board rather than
            // a timetable.
            if out.count >= limit, known || seen.count > services { continue }
            out.append(entry)
        }
        return out
    }

    /// What the printed timetable says calls at these stations, for a board the
    /// live fleet could not fill.
    ///
    /// Deliberately not folded into `journeys`: these are rows for a panel, not
    /// vehicles for the map. Adding them to the store would draw tomorrow's
    /// first bus on today's map and would have to be undrawn again on the next
    /// tick, so they are built, read, and dropped.
    ///
    /// Asked only when the board has room. A station whose live board is
    /// already full has nothing to gain from the schedule, and skipping it
    /// there is what keeps a tap on Bern as cheap as it was.
    ///
    /// `accepting` narrows the query from the station to the stops a *platform*
    /// board is about. Without it the schedule spends the board's whole budget
    /// on the station's other kerbs — see `TimetableStore.patterns`.
    private func scheduled(
        at stations: Set<String>, key: String? = nil, accepting: ((String) -> Bool)? = nil,
        from now: Timestamp, filling count: Int, of limit: Int
    ) -> [Journey] {
        guard count < limit, !stations.isEmpty, register.isReady,
              let timetable, timetable.isReady
        else { return [] }
        return timetable.journeys(
            callingAt: stations,
            key: key,
            accepting: accepting,
            from: now,
            to: now + Timestamp(Self.boardHorizon),
            limit: max(limit, Self.boardDepth) - count,
            place: { [register] ref in register.lookup(ref) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        )
    }

    /// How far a mapped call may be from a kerb and still be that kerb's call.
    ///
    /// Measured rather than picked. At Bern the tram and trolleybus stop nodes
    /// sit 3–4 m from the register's Bärenplatz kerbs and the nearest bus node
    /// to railway platform 5 is 47 m away, so 30 m separates "this kerb" from
    /// "somewhere else in the station" cleanly. It fails closed: at a platform
    /// where nothing is mapped within 30 m the list is empty, which is the
    /// honest answer rather than a nearby one.
    static let servingSpread = 30.0

    /// The lines the mapped routes say call at any of these points.
    ///
    /// A station is asked about *by its kerbs*, not by its centre. The centre of
    /// a stop place is a point nothing stops at — at Bärenplatz it is 16 m from
    /// one kerb and 40 m from the other — so a single circle from it either
    /// misses a side of the street or grows wide enough to sweep in the next
    /// stop along. The kerbs come from the register by identifier, and each is
    /// asked about on its own.
    public func servingLines(at points: [Coord]) -> [ServingLine] {
        guard relations.isReady, !points.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [ServingLine] = []
        for point in points {
            for line in relations.linesStopping(
                lon: point.lon, lat: point.lat, within: Self.servingSpread
            ) where seen.insert("\(line.mode.rawValue)|\(line.ref)").inserted {
                out.append(line)
            }
        }
        return out.sorted {
            let a = Int($0.ref.prefix { $0.isNumber }), b = Int($1.ref.prefix { $0.isNumber })
            if let a, let b, a != b { return a < b }
            if (a == nil) != (b == nil) { return a != nil }
            return $0.ref < $1.ref
        }
    }

    /// The same list, without the lines the board already answers for.
    ///
    /// Both halves are shown together now, so the two must not say the same
    /// thing twice: with tram 8 leaving in four minutes, a row underneath
    /// saying tram 8 calls here is a worse copy of the row above it. What is
    /// left is the half the feed cannot answer — the night bus, the line whose
    /// hourly service has finished for the day — which is the whole reason the
    /// relations are asked at all.
    ///
    /// Matched on `normaliseRef`, because the two sources agree on a line's
    /// digits and not on its decoration: the feed's `S 1` and the relation's
    /// `S1` are one line. Where the mode disagrees the row survives, which errs
    /// towards showing a line twice rather than hiding one that runs.
    func servingLines(at points: [Coord], besides departures: [BoardEntry]) -> [ServingLine] {
        func key(_ mode: Mode, _ ref: String) -> String {
            "\(mode.rawValue)|\(RelationStore.normaliseRef(ref))"
        }
        let live = Set(departures.map { key($0.mode, $0.line) })
        return servingLines(at: points).filter { !live.contains(key($0.mode, $0.ref)) }
    }

    /// The individual platforms and kerbs inside a viewport, laid out so no two
    /// plates cover each other.
    ///
    /// Capped, and the cap prefers the coded rows: a city centre holds hundreds
    /// and "Bern, platform K1" is worth drawing over an unlabelled pole.
    ///
    /// `hidingDrawnTracks` is what makes the two ways of showing a platform stop
    /// fighting. Where a footprint is drawn, the shape is the better object in
    /// every way that matters — it says where the platform is, how long it is
    /// and which way it runs, and it is far easier to hit than a marker — so a
    /// plate stacked on top of it is a second thing to tap meaning the same
    /// thing, thirty of them at a station the size of Bern. Where nothing is
    /// drawn the plate is the only marker there is, so it stays; and the caller
    /// passes `false` whenever the shapes are not on the map, because a platform
    /// with neither a shape nor a plate is not a tidier map, it is a wrong one.
    ///
    /// Filtered before the cap rather than after, so hiding the rail platforms
    /// at a main station spends the budget on the bus kerbs around it instead of
    /// simply drawing less.
    public func platformPlates(
        in bbox: BBox, zoom: Double, limit: Int = 600, hidingDrawnTracks: Bool = false
    ) -> [PlacedPlate] {
        guard register.isReady else { return [] }
        let drawn = hidingDrawnTracks ? platforms.coveredTracks() : []

        var rows = register.within(bbox, limit: drawn.isEmpty ? limit : .max)
        if !drawn.isEmpty {
            rows = rows.filter { stop in
                // Matched by track, not by exact code, so the sector rows go
                // with it: `7A-D` and `7E-H` are not two more platforms to
                // label, they are the ends of platform 7, whose footprint is
                // right there and already tappable.
                guard let track = StopRegister.trackOf(stop.platform) else { return true }
                return !drawn.contains("\(StopRegister.stationOf(stop.id))|\(track)")
            }
            if rows.count > limit {
                rows.sort { ($0.platform != nil ? 1 : 0) > ($1.platform != nil ? 1 : 0) }
                rows = Array(rows.prefix(limit))
            }
        }
        return PlatformLayout.place(rows, zoom: zoom)
    }

    /// The board for whichever platform a plate names.
    public func plateBoard(id: String, at now: Timestamp) -> PlatformBoard? {
        platformBoard(ref: id, at: now)
    }

    /// What calls at one platform, soonest first.
    ///
    /// Matched on the SLOID the feed itself puts on each call, so this is exact
    /// rather than a proximity guess — the same identifier join that places the
    /// vehicles. Where a journey names the station rather than the platform,
    /// the platform *code* is compared instead, sectors aside.
    public func platformBoard(ref: String, at now: Timestamp, limit: Int = 40) -> PlatformBoard? {
        guard register.isReady, let place = register.lookup(ref) else { return nil }
        let station = StopRegister.stationOf(ref)

        var departures: [BoardEntry] = []
        var listed = Set<String>()
        /// One row for one run — see the station board's `list`, which this is.
        func list(_ journey: Journey) {
            for (i, stop) in journey.stops.enumerated() {
                let here = stop.ref == ref || (
                    stop.ref != nil && place.platform != nil
                        && StopRegister.sameTrack(stop.platform, place.platform)
                        && StopRegister.stationOf(stop.ref) == station
                )
                guard here else { continue }
                if stop.dep < now - 300 { continue } // already gone
                guard listed.insert(journey.id).inserted else { return }
                guard listed.insert(
                    "\(journey.mode.rawValue)|\(journey.line)|\(stop.dep)|\(journey.to ?? "")"
                ).inserted else { return }
                for part in journey.parts ?? [] { listed.insert(part.id) }

                departures.append(BoardEntry(
                    id: journey.id, mode: journey.mode, line: journey.line, to: journey.to,
                    from: journey.stops[0].name, departure: stop.dep, arrival: stop.arr,
                    platform: stop.platform ?? place.platform, delay: stop.delay ?? journey.delay,
                    observed: stop.observed, stop: nil,
                    terminates: i == journey.stops.count - 1, originates: i == 0,
                    running: Positioning.position(of: journey, at: now) != nil
                ))
                return
            }
        }

        // Both ways a call can belong to this platform put it at this station,
        // so the station's own callers are the whole candidate set. See
        // `callers`: without it this walks every call in the country.
        for journey in callers(matchingAnyOf: [station]) { list(journey) }
        // And the printed timetable for the rest of the day, for the same
        // reason the station board asks: a platform is quieter than the station
        // it is in, so it runs out of live departures sooner. Bern's stop M is
        // a Moonliner kerb, and before this it had a board only in the hour
        // before a Moonliner left.
        for journey in scheduled(
            at: [station], key: ref,
            // The same test `here` makes, asked of a stop rather than of a
            // call: this kerb, or one of the kerbs sharing its track.
            accepting: { [register] candidate in
                candidate == ref || (
                    place.platform != nil
                        && StopRegister.sameTrack(register.lookup(candidate)?.platform, place.platform)
                )
            },
            from: now, filling: departures.count, of: limit
        ) {
            list(journey)
        }
        departures.sort { $0.departure < $1.departure }

        return PlatformBoard(
            id: ref, name: place.name, code: place.platform, assigned: place.assigned,
            lon: place.lon, lat: place.lat, now: now,
            departures: Self.trim(departures, to: limit), stationOnly: false,
            serving: servingLines(
                at: [Coord(lon: place.lon, lat: place.lat)], besides: departures
            )
        )
    }

    /// The platform a formation stop names, as a strip with its stairs on it.
    ///
    /// Takes the DIDOK number the formation service reports rather than a
    /// SLOID, because that is what it reports: `8507000` and `1A-D`, which have
    /// to become `ch:1:sloid:7000` and `1` before anything can be looked up.
    /// Both conversions are exact string work — see `StopRegister.sloid(forDidok:)`
    /// — so a stop either has a strip or does not, and none is ever guessed at
    /// by distance.
    public func platformStrip(didok: Int, track: String?) -> PlatformStrip? {
        guard let track, !track.isEmpty else { return nil }
        guard let station = StopRegister.sloid(forDidok: String(didok)) else { return nil }
        return platformAccess.strip(station: station, track: track)
    }

    /// What calls at the platform a drawn shape represents.
    ///
    /// An island platform is one shape serving two tracks — Bern's platform
    /// between tracks 1 and 2 is a single OSM relation tagged `ref="1;2"` — and
    /// standing on it you can board from either side. So the board is the union
    /// of its tracks.
    public func shapeBoard(osmId: String, at now: Timestamp) -> PlatformBoard? {
        guard let shape = platforms.lookup(osmId) else { return nil }
        let boards = shape.sloids.compactMap { platformBoard(ref: $0, at: now) }
        guard let first = boards.first else { return nil }

        var departures: [BoardEntry] = []
        var seen = Set<String>()
        for board in boards {
            for entry in board.departures where !seen.contains(entry.id) {
                seen.insert(entry.id)
                departures.append(entry)
            }
        }
        departures.sort { $0.departure < $1.departure }

        return PlatformBoard(
            id: shape.sloids[0], name: shape.name,
            code: shape.codes.filter { !$0.isEmpty }.joined(separator: " · "),
            assigned: nil, lon: first.lon, lat: first.lat, now: now,
            departures: Self.trim(departures, to: 40), stationOnly: shape.stationOnly,
            // Asked again for the whole shape rather than unioning the tracks'
            // lists: a line live at one track and idle at the other is running
            // here, and each track's own list only knows about its own board.
            serving: servingLines(
                at: [Coord(lon: first.lon, lat: first.lat)], besides: departures
            ),
            shape: osmId
        )
    }

    /// Which station each of these drawn shapes belongs to.
    ///
    /// Asked for a viewport at a time rather than one at a time: the map uses it
    /// to decide which of several blobs over the same station to draw, and that
    /// is one question about a screenful rather than a hundred questions about
    /// features.
    public func stations(forShapes ids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(ids.count)
        for id in ids {
            if let station = platforms.station(for: id) { out[id] = station }
        }
        return out
    }

    /// The board for whichever station a drawn blob covers.
    ///
    /// Resolved by identity: the blob carries an OpenStreetMap element id, the
    /// element carries `uic_ref`, and that is the number the stop places are
    /// keyed on. Answering by nearest station instead is what returned Marzili
    /// for a tap on Zytglogge — the blobs are large and their centres are not
    /// where their name is.
    public func stationBoard(osmId: String, at now: Timestamp, limit: Int = 60) -> StationBoard? {
        guard let uic = platforms.station(for: osmId) else { return nil }
        if let place = stopPlaces.place(id: uic) {
            return board(name: place.name, id: place.id, lon: place.lon, lat: place.lat,
                         at: now, limit: limit)
        }
        // A station abroad is in neither the drawn stop places nor the Swiss
        // numbering — Milano Centrale is a UIC and nothing else — but the
        // register holds it, and a board is all this needs.
        guard let ref = StopRegister.sloid(forDidok: uic) ?? (uic.allSatisfy(\.isNumber) ? uic : nil),
              let place = register.lookup(ref)
        else { return nil }
        return board(name: place.name, id: uic, lon: place.lon, lat: place.lat, at: now, limit: limit)
    }

    /// Vehicles whose mapped route runs over any of these OSM ways.
    ///
    /// This is the join between the two datasets: a journey matched to a route
    /// relation knows exactly which way ids it uses, and those are the ids the
    /// railway layer draws.
    public func vehiclesOnWays(_ wayIds: [Int64], at now: Timestamp) -> [BoardEntry] {
        guard !wayIds.isEmpty else { return [] }
        let wanted = Set(wayIds)
        // Which line numbers could be here at all. Without this the loop below
        // attaches geometry to every journey in the country to find the two on
        // this track.
        let possible = relations.isReady ? relations.keysOnWays(wayIds) : nil

        var out: [BoardEntry] = []
        for journey in fleetByID().values {
            if let possible, journey.geometry == nil, !relations.couldRunOn(journey, keys: possible) { continue }
            // Corridor, not refined, for the reason `journey(id:at:)` gives:
            // upgrading a path moves the vehicle drawn on it, and answering
            // "which lines run over this track" is not a reason to move every
            // train in the country. The way ids come from the relation match,
            // which is the corridor half — so nothing is lost by asking for
            // the cheaper attach here.
            attachGeometry(to: journey, refined: false)
            guard let ways = journey.geometry?.ways, ways.contains(where: { wanted.contains($0) }) else { continue }

            out.append(BoardEntry(
                id: journey.id, mode: journey.mode, line: journey.line, to: journey.to,
                from: journey.from, departure: journey.stops[0].dep,
                arrival: journey.stops[journey.stops.count - 1].arr,
                platform: nil, delay: journey.delay, observed: false, stop: nil,
                terminates: false, originates: false,
                running: Positioning.position(of: journey, at: now) != nil
            ))
        }
        // Running services first, then by line, so the list reads sensibly.
        out.sort {
            $0.running != $1.running ? ($0.running && !$1.running) : $0.line < $1.line
        }
        return out
    }

    public func linesOnWays(_ wayIds: [Int64]) -> [RelationStore.LineOnWay] {
        relations.isReady ? relations.linesOnWays(wayIds) : []
    }

    /// Every line whose mapped geometry passes within `metres` of a point —
    /// what answers a tap on a piece of track.
    public func linesNear(lon: Double, lat: Double, within metres: Double) -> [RelationStore.LineOnWay] {
        relations.isReady ? relations.linesNear(lon: lon, lat: lat, within: metres) : []
    }

    /// The railway network inside a viewport, for the track overlay.
    public func trackLines(
        in bbox: BBox, limit: Int = 20_000, kindMask: UInt8 = 0,
        minLength: Double = 0, simplify: Double = 0
    ) -> [RailNet.TrackLine] {
        railnet.isReady
            ? railnet.lines(in: bbox, limit: limit, kindMask: kindMask,
                            minLength: minLength, simplify: simplify)
            : []
    }

    /// The classes worth drawing when the map is pulled back: main line and
    /// narrow gauge, without the tram reservations and sidings.
    public func mainLineMask() -> UInt8 {
        railnet.kindBit("heavy") | railnet.kindBit("narrow")
    }

    public func trackKindBit(_ name: String) -> UInt8 { railnet.kindBit(name) }

    /// One line's own geometry, so a route with nothing running on it can still
    /// be drawn.
    public func routeGeometry(relationId: Int32) -> (path: [Coord], stops: [Coord])? {
        guard relations.isReady, let relation = relations.relation(id: relationId) else { return nil }
        return (relations.path(of: relation).toArray(), relations.stops(of: relation).toArray())
    }

    /// Move journeys the new snapshot no longer carries into the retained set,
    /// and drop the ones that have aged out of it.
    ///
    /// Only journeys that have actually *finished* are kept. One that vanished
    /// mid-run is a cancellation or a feed hiccup, and drawing a vehicle the
    /// source has withdrawn is worse than drawing none.
    private func retire(replacing found: [String: Journey]) {
        let now = Timestamp(Date().timeIntervalSince1970)
        let cutoff = now - Timestamp(Self.retention)

        for (id, journey) in journeys where found[id] == nil {
            guard journey.end <= now, journey.end >= cutoff else { continue }
            // Geometry is the expensive half and is rebuilt on demand. Holding
            // it for an hour of finished journeys is tens of megabytes for a
            // line nobody may ever scrub back to.
            journey.invalidateGeometry()
            retired[id] = journey
        }

        retired = retired.filter { $0.value.end >= cutoff && found[$0.key] == nil }

        if retired.count > Self.retentionLimit {
            let keep = retired.values
                .sorted { $0.end > $1.end }
                .prefix(Self.retentionLimit)
            retired = Dictionary(keep.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Every journey the map may draw: the live snapshot plus what has been
    /// kept from the ones before it.
    private func standing() -> [Journey] {
        guard !retired.isEmpty else { return Array(journeys.values) }
        var out = Array(journeys.values)
        out.reserveCapacity(out.count + retired.count)
        for (id, journey) in retired where journeys[id] == nil { out.append(journey) }
        return out
    }

    // MARK: - Routed legs

    /// Load the routed-leg cache and remember where to write it back.
    ///
    /// `RailNet` has memoised every leg it routes since the first version, and
    /// on the phone that memo has never survived a launch: `loadCache` and
    /// `saveCache` existed and nothing called them. So every launch re-ran a
    /// Dijkstra over a 573,000-node graph for legs it had already solved — and
    /// that search runs *inside this actor*, which also answers the draw loop
    /// and every tap on the map. One cold journey stalled the lot, which is the
    /// pause on the first vehicle opened after launch and on no later one.
    public func openLegCache(at url: URL, seededBy seed: URL? = nil) {
        if let seed { railnet.loadCache(from: seed) }
        railnet.loadCache(from: url)
        legCacheURL = url
        legsAtLastSave = railnet.cachedLegs
        // `Library/Application Support` is not created for an app that has
        // never written there, so both this file and the fleet snapshot beside
        // it would fail to save with nothing said out loud.
        Self.ensureDirectory(for: url)
        Self.ensureDirectory(for: snapshotURL)
    }

    private static func ensureDirectory(for file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    /// Write the routed legs back, if any new ones have been found.
    @discardableResult
    public func saveLegCache() -> Bool {
        guard let legCacheURL else { return false }
        let count = railnet.cachedLegs
        guard count != legsAtLastSave else { return false }
        do {
            try railnet.saveCache(to: legCacheURL)
            legsAtLastSave = count
            return true
        } catch {
            status.lastError = "leg cache: \(error)"
            return false
        }
    }

    /// How many legs are memoised, for the diagnostics panel.
    public var routedLegs: Int { railnet.cachedLegs }

    /// The longest a single draw may spend building geometry it does not yet
    /// have.
    ///
    /// The draw loop runs at 15 Hz, so a tick has 66 ms before it is late.
    /// Eight of those is a budget the loop cannot feel — and it is eight
    /// milliseconds of *building*, measured over the attach calls, not a
    /// deadline the walk over the fleet can spend before the building starts.
    /// See `alignToTrack`, which is where that distinction was worth several
    /// seconds of chord-drawn vehicles.
    ///
    /// A vehicle still waiting on its path is drawn on the chord between its
    /// stops, so the cost of deferring is a line that straightens a frame or
    /// two later — and, since the memo survives a refresh, one it pays once.
    ///
    /// Without a budget the first draw over a city attached geometry for every
    /// vehicle in the viewport in one pass, each one possibly a graph search,
    /// and nothing else on this actor ran until it finished.
    static let geometryBudget: TimeInterval = 0.008

    /// How wide a viewport still gets every vehicle in it put on its real
    /// track, in metres.
    ///
    /// A hundred kilometres is about a canton on a phone, and a canton holds
    /// three or four hundred vehicles: attaching both halves of the geometry to
    /// all of them costs about thirty milliseconds, once, and every frame after
    /// it reads the memo for nothing. Past this the map is a picture of the
    /// country — the same work is a fifth of a second and buys a correction of
    /// a twentieth of a point, which is to say it buys nothing.
    ///
    /// A width rather than a count of vehicles, which is what this used to be.
    /// A count answers "can the frame afford it"; the question that decides
    /// whether a vehicle is drawn in the right place is "can it be seen", and
    /// the two disagree in the middle of a pinch — which is precisely when
    /// every bus in the viewport used to step onto its road at once. See
    /// `alignToTrack` and `keepContinuous`.
    ///
    /// The dearest frame this can produce is the one that crosses the gate cold
    /// — forty-odd milliseconds, once, for a viewport a hundred kilometres
    /// wide. That is about zoom 8 on a phone, which is under `stillZoom`, where
    /// the tick loop is already drawing once a second: the expensive frame
    /// lands where there is a whole second to put it in.
    static let alignEverywhereAcross: Double = 100_000

    /// How many built paths are kept for journeys not currently drawn.
    ///
    /// Costs nothing for the ones still on screen: a `JourneyGeometry` is
    /// immutable once built, so the memo and the journey share one copy. This
    /// bounds what is held for the ones the map has moved away from.
    static let geometryMemoLimit = 1500

    /// What an eviction trims down to. See `evictGeometryIfNeeded`.
    static let geometryMemoKeep = 1125

    /// The moments the app can be asked to draw.
    ///
    /// This used to be a *measurement* — how far either side of now the loaded
    /// SIRI snapshot thinned out before the map stopped meaning anything, drawn
    /// under the time control as a falloff curve. That was the honest answer
    /// while a downloaded snapshot was the only thing that knew what was
    /// running: it describes the fleet around the minute it was fetched, so an
    /// hour out most of the country is simply missing and an empty map reads as
    /// a claim about Switzerland.
    ///
    /// The archive settles it. `timetable.bin` holds a year of service days and
    /// answers for any minute in it off the file, so the bound is a fact about
    /// the packed feed rather than a curve to apologise for — and the falloff
    /// curve, which by then was measuring the width of the expansion window
    /// rather than anything real, is gone with it.
    ///
    /// Without a timetable there is only the snapshot in hand, and its outer
    /// edges are the best that can be said.
    ///
    /// The archive is only offered while it actually covers `now`. A packed
    /// year expires: the Swiss timetable turns over on the second Sunday of
    /// December, and this file is a bundle resource replaced by shipping a
    /// build, not by anything the app can do for itself. Past its last service
    /// day it still opens and still reads, and answers for nothing anybody is
    /// asking about — so offering it would leave the time control bounded
    /// entirely in the past, with no "now" to step from and every button dead.
    /// A stale archive falls back to the feed, which is where the app was
    /// before the archive existed.
    public func drawableSpan(
        at now: Timestamp = Timestamp(Date().timeIntervalSince1970)
    ) -> ClosedRange<Timestamp>? {
        if let span = timetable?.span(), span.contains(now) { return span }
        var lo = Timestamp.max
        var hi = Timestamp.min
        for journey in fleetByID().values {
            lo = min(lo, Positioning.appearsAt(journey))
            hi = max(hi, Positioning.standsUntil(journey))
        }
        guard lo <= hi else { return nil }
        return lo...hi
    }
}

/// Accumulates journeys while the response streams, off the actor.
final class JourneyCollector: @unchecked Sendable {
    private var found: [String: Journey] = [:]
    private let lock = NSLock()

    /// A cancelled *journey* is not running and is not drawn. A journey with a
    /// cancelled *call* is running and is — which is what this used to get
    /// wrong, because the parser reported the second as the first and 167
    /// journeys a snapshot said were moving never reached the map. See
    /// `Call.cancelled`.
    func consume(_ chunk: Data, parser: SiriParser) {
        lock.withLock {
            parser.consume(chunk) { journey in
                if !journey.cancelled { found[journey.id] = journey }
            }
        }
    }

    func finish(parser: SiriParser) {
        lock.withLock {
            parser.finish { journey in
                if !journey.cancelled { found[journey.id] = journey }
            }
        }
    }

    func take() -> [String: Journey] { lock.withLock { found } }

    /// How many are in hand, for a progress readout. Cheaper than `take()`,
    /// which copies the whole dictionary.
    var count: Int { lock.withLock { found.count } }
}

/// How much came over the wire, counted from the streaming callback.
///
/// A class rather than a captured `var`: the callback is `@Sendable` and runs
/// off the actor, so the count has to live somewhere both sides can see.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var total: Int { lock.withLock { count } }

    func add(_ bytes: Int) { lock.withLock { count += bytes } }
}
