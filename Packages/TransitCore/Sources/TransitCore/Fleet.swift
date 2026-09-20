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

    /// A stopped last call may be a turnback or a join into another working.
    /// Resolve that working before using this snapshot as a panel's first
    /// paint; the raw stop list alone cannot say that the train ends here.
    public var isStandingAtLastStop: Bool {
        !moving && !stops.isEmpty && index == stops.count - 1
    }

    /// The same physical vehicle changes its advertised service at arrival,
    /// before the outgoing working gets its own map position at departure.
    public var isTurningAround: Bool {
        layover?.id != nil && isStandingAtLastStop
    }

    public var displayLine: String {
        isTurningAround ? (layover?.line ?? line) : line
    }

    public var displayDestination: String? {
        isTurningAround ? (layover?.to ?? to) : to
    }

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
    public var typicalIntervalMinutes: Int?
    public var runIdentity: BoardRunIdentity?

    /// A timetable row ID may recur later today or tomorrow. SwiftUI needs an
    /// occurrence identity for expanded times, while selection still uses `id`.
    public var eventID: String {
        "\(id)|\(runIdentity?.station ?? stop ?? "")|\(runIdentity?.scheduledDeparture ?? departure)|\(terminates)"
    }

    /// Keep the current displayed minute, including delayed departures whose
    /// booked time has passed. A running train may already have left this stop.
    public func isUpcoming(at now: Timestamp) -> Bool {
        departure >= Clock.displayMinute(now)
    }

    public init(
        id: String, mode: Mode, line: String, to: String? = nil, from: String,
        departure: Timestamp, arrival: Timestamp, platform: String? = nil,
        delay: Int? = nil, observed: Bool = false, stop: String? = nil,
        terminates: Bool = false, originates: Bool = false, running: Bool = true,
        typicalIntervalMinutes: Int? = nil, runIdentity: BoardRunIdentity? = nil
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
        self.typicalIntervalMinutes = typicalIntervalMinutes
        self.runIdentity = runIdentity
    }

    /// Same advertised service on a board: one tram, not `3` and `T3`.
    public func sameService(as other: BoardEntry) -> Bool {
        mode == other.mode
            && Journey.publishedLine(line, mode: mode)
                == Journey.publishedLine(other.line, mode: other.mode)
            && Fleet.sameBoardDestination(to ?? "", other.to ?? "")
            && stop == other.stop
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
    public var isLoading = false
    /// Preserve the OSM lookup for stations outside the Swiss stop-place index.
    public var shape: String? = nil

    public static func loading(id: String, name: String, at point: Coord, now: Timestamp) -> Self {
        Self(id: id, name: name, lon: point.lon, lat: point.lat, now: now,
             departures: [], isLoading: true)
    }
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
    /// Whether this is a railway platform rather than a bus/tram/boat stop.
    ///
    /// The distinction is wording, not decoration: track 7 is “Platform 7”,
    /// while the two sides of a tram or bus stop are “Stop A” and “Stop B”.
    /// Carry it with the board so every surface names the same place the same
    /// way instead of guessing from whichever departures happen to be present.
    public var rail: Bool
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
    public var isLoading = false
    public var shape: String?
}

/// The board belonging to a stationary phone near public transport.
///
/// A platform is returned only when the GPS uncertainty circle fits clearly
/// nearer one separated stop than every sibling. Otherwise this deliberately
/// falls back to the whole station: an honest “Bern” is more useful than a
/// confident-looking but invented “Platform 4”.
public enum NearbyBoard: Sendable, Equatable {
    case station(StationBoard)
    case platform(PlatformBoard)

    public var id: String {
        switch self {
        case let .station(board): return "station:\(board.id)"
        case let .platform(board): return "platform:\(board.id)"
        }
    }

    public var name: String {
        switch self {
        case let .station(board): return board.name
        case let .platform(board): return board.name
        }
    }

    public var coordinate: Coord {
        switch self {
        case let .station(board): return Coord(lon: board.lon, lat: board.lat)
        case let .platform(board): return Coord(lon: board.lon, lat: board.lat)
        }
    }

    /// What the compact offer says. Whole stations intentionally have no
    /// platform suffix; a specific result includes the one distinction the
    /// confidence test was able to establish.
    public var title: String {
        guard case let .platform(board) = self, !board.stationOnly else { return name }
        let code = [board.code, board.assigned]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let code else { return name }
        return "\(name) · \(board.rail ? "Platform" : "Stop") \(code)"
    }
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
    private var supportingLoaded = false
    private let osmRoutes = OSMRouteClient()
    /// Overpass keys that returned nothing useful, so a panel refresh does not
    /// ask again for a line OSM simply does not have.
    private var remoteRouteMisses: Set<String> = []

    private var journeys: [String: Journey] = [:]
    private(set) var revision = 0
    private var chainedRevision = -1
    private var chained: [String: Journey] = [:]
    /// Through-services the formation service has told us about.
    ///
    /// The packed timetable is the bulk of the graph and the better half of it
    /// — national, offline, and complete for the year. This is the other half:
    /// the workings put together this morning, which no printed timetable can
    /// contain. Both go into the same `ThroughGraph`; there is no second
    /// mechanism and no precedence to reason about, because a link is a link.
    private var learnedLinks: [FormationKey: [ThroughLink]] = [:]
    private var learnedDay: String?
    /// The packed graph for one operating day, which is the same for every
    /// rebuild within that day and costs a few tens of milliseconds to resolve.
    private var packedGraph = ThroughGraph.empty
    private var packedGraphDays: [String] = []
    /// The moment the drawn fleet is a picture of, for choosing that day.
    private var drawnMoment: Date?

    /// Use published through-services for map handovers as well as the panel.
    ///
    /// `working` is the reference the fleet files this train under — the same
    /// one the formation was asked for. It has to come from the caller because
    /// the formation service answers by operator and train number and never
    /// says its own journey id, so it cannot be reconstructed from the reply.
    @discardableResult
    public func learnConnections(
        _ formation: TrainFormation, for key: FormationKey, of working: String
    ) -> Bool {
        let links = formation.throughLinks(ownedBy: [working])
        if learnedDay != key.operationDate {
            learnedDay = key.operationDate
            learnedLinks.removeAll(keepingCapacity: true)
        }
        guard learnedLinks[key] != links else { return false }
        if links.isEmpty, learnedLinks[key] == nil { return false }
        learnedLinks[key] = links
        revision += 1
        return true
    }

    /// The published graph indexed by every name a working answers to.
    ///
    /// Values are indices into `graph.links` rather than copies of the names:
    /// the map is around 75,000 entries nationally and holding four strings per
    /// entry would cost several megabytes to say something the graph already
    /// says. Rebuilt when the day changes or the formation service adds a
    /// working, which between them is a handful of times a day.
    private var publishedForward: [String: [Int]] = [:]
    private var publishedBackward: [String: [Int]] = [:]
    private var publishedIndexed = ThroughGraph.empty
    private var publishedIndexKey: String?

    private func publishedIndex() -> ThroughGraph {
        let graph = publishedGraph()
        let key = "\(packedGraphDays.joined(separator: ","))|\(learnedLinks.count)|\(graph.links.count)"
        guard publishedIndexKey != key else { return publishedIndexed }
        publishedIndexKey = key
        publishedIndexed = graph
        publishedForward.removeAll(keepingCapacity: true)
        publishedBackward.removeAll(keepingCapacity: true)
        // Names arrive folded; see `ThroughLink`.
        for (i, link) in graph.links.enumerated() {
            for name in link.from { publishedForward[name, default: []].append(i) }
            for name in link.to { publishedBackward[name, default: []].append(i) }
        }
        return graph
    }

    /// Every name a working answers to, on the side being asked about.
    ///
    /// A chained vehicle is several numbered legs, and only the one at the edge
    /// can have a neighbour: asking what the Bern–Spiez leg continues as, when
    /// the object in hand already runs Bern–Domodossola, would find the leg it
    /// is already made of.
    private static func edgeNames(of journey: Journey, forward: Bool) -> [String] {
        var out: [String] = []
        if let parts = journey.parts, let edge = forward ? parts.last : parts.first {
            out.append(edge.id)
            if let ref = edge.journeyRef { out.append(ref) }
        }
        out.append(journey.id)
        if let ref = journey.journeyRef { out.append(ref) }
        return out.filter { !$0.isEmpty }
    }

    /// What the feed says this working becomes, or came from.
    ///
    /// Returns the declared names on the other side, which is not the same as
    /// a journey: the map draws ninety minutes and the named working is often
    /// outside it. An empty result means the feed said nothing, and only then
    /// is there anything to infer.
    private func publishedNeighbourNames(of journey: Journey, forward: Bool) -> Set<String> {
        let graph = publishedIndex()
        guard !graph.isEmpty else { return [] }
        let index = forward ? publishedForward : publishedBackward
        var out = Set<String>()
        for name in Self.edgeNames(of: journey, forward: forward) {
            for link in index[name.lowercased()] ?? [] {
                out.formUnion(forward ? graph.links[link].to : graph.links[link].from)
            }
        }
        return out
    }

    /// The workings the feed says this one parts into, named as the branch
    /// lookup wants them.
    ///
    /// `Fleet.onward` will accept a half whose line differs from the trunk's
    /// only where that half is *named* — otherwise an RE1 would adopt any R11
    /// leaving the same station at about the right time. Until now the only
    /// thing that named one was the formation service's `T` relationship,
    /// which is optional and often null, so the half that changes line number
    /// was routinely unfindable: at Spiez the RE1 keeps its number to
    /// Domodossola and the Zweisimmen half becomes an R11, and it was the
    /// Zweisimmen half that went missing from the direction picker.
    ///
    /// The packed graph names both halves by journey id for the whole country,
    /// offline, whether or not anybody filed a formation relationship.
    public func publishedBranches(of id: String, journeyRef: String?) -> [TrainFormation.Working] {
        let graph = publishedIndex()
        guard !graph.isEmpty else { return [] }
        var names = [id]
        if let journeyRef { names.append(journeyRef) }
        var out: [TrainFormation.Working] = []
        var seen = Set<String>()
        for name in names {
            for link in publishedForward[name.lowercased()] ?? [] {
                for other in graph.links[link].to where seen.insert(other).inserted {
                    // A journey id is what the branch lookup matches on; a trip
                    // id names the same run but not in the spelling the feed
                    // keys journeys by, so both are offered.
                    out.append(TrainFormation.Working(trainNumber: nil, journeyID: other))
                }
            }
        }
        return out
    }

    /// The parting this working makes, as the packed timetable has it.
    ///
    /// The formation service is the better answer and is not the *first*
    /// answer: it is a network request per train, it covers eleven companies
    /// out of the country's several hundred, and until it comes back the card
    /// had nothing to say about a train that comes apart — no picker, no
    /// branch stops, no second line on the map. The through-services graph is
    /// already on the device, is read offline, and names both halves for every
    /// operator in the timetable. It cannot say which coaches go where; that is
    /// the part worth waiting for, and it arrives later and fills in.
    ///
    /// A working that parts is filed as one that ends at the junction with two
    /// beginning there, so the parting is this working's last call and the two
    /// successors are the halves. Anything with one successor is a through
    /// service, which is a different thing and not this.
    public func publishedSplit(of id: String, journeyRef: String?, at parting: Call) -> TrainFormation.Split? {
        let graph = publishedIndex()
        guard !graph.isEmpty else { return nil }
        var names = [id]
        if let journeyRef { names.append(journeyRef) }
        var branches: [TrainFormation.Working] = []
        var seen = Set<String>()
        for name in names {
            for link in publishedForward[name.lowercased()] ?? [] {
                // One link is one successor: its `to` holds that working's
                // several spellings, not several trains. And one successor is
                // several links — the graph is built for the drawn day and the
                // one before it, so a service day that runs past midnight is
                // held twice. Counted either way round, an ordinary through
                // service would have looked like a train coming apart.
                let spellings = graph.links[link].to
                guard !spellings.isEmpty else { continue }
                let reference = spellings.first { $0.contains(":sjyid:") }
                    ?? spellings.sorted().joined(separator: "|")
                guard seen.insert(reference).inserted else { continue }
                branches.append(TrainFormation.Working(
                    trainNumber: FormationKey(journeyID: reference, operationDate: "")?.trainNumber,
                    journeyID: reference
                ))
            }
        }
        guard branches.count > 1 else { return nil }
        return TrainFormation.Split(
            stopName: parting.name,
            stopUIC: parting.ref.flatMap { StopRegister.didok(forSloid: $0).flatMap(Int.init) } ?? 0,
            moment: Date(timeIntervalSince1970: Double(parting.arr)),
            portions: [],
            branches: branches
        )
    }

    /// Everything published about which workings are one vehicle, right now.
    ///
    /// Both the drawn day and the one before it, because a service day runs
    /// past midnight: the 23:50 that continues at 00:10 is filed under the day
    /// it left on, and a fleet drawn at five past midnight is holding both.
    private func publishedGraph() -> ThroughGraph {
        let moment = drawnMoment ?? Date()
        let zone = TimeZone(identifier: "Europe/Zurich") ?? .current
        let days = [moment.addingTimeInterval(-86_400), moment]
        let keys = days.map { FormationKey.operationDate(of: Timestamp($0.timeIntervalSince1970)) }
        if keys != packedGraphDays {
            packedGraphDays = keys
            packedGraph = ThroughGraph(links: timetable.map { store in
                days.flatMap { store.throughServices(on: $0, zone: zone) }
            } ?? [])
        }
        guard !learnedLinks.isEmpty else { return packedGraph }
        return packedGraph.merging(ThroughGraph(links: Array(learnedLinks.values.joined())))
    }

    /// Timetabled runs a departure board has actually offered to the reader.
    ///
    /// The map expands only the small window in which a vehicle can be drawn,
    /// while a board deliberately reads a day ahead. Those later `Journey`
    /// objects used to be reduced to `BoardEntry` values and then discarded,
    /// so tapping tomorrow's departure could only ask the live fleet for it
    /// and inevitably got "not running". This is a bounded presentation cache,
    /// not another fleet: none of these journeys is returned by a map query.
    private struct BoardJourneyKey: Hashable {
        var id: String
        var departure: Timestamp
    }
    private var boardJourneys: [BoardJourneyKey: Journey] = [:]
    private var boardJourneyOrder: [BoardJourneyKey] = []
    private static let boardJourneyLimit = 1_024
    /// Through-workings assembled from packed numbered legs, keyed by every
    /// constituent id so opening 4257 after stitching 4157+4257 is free.
    private var throughWorkings: [String: Journey] = [:]
    private var throughRevision = -1
    /// Packed neighbours at a junction, so a Bern board does not re-expand
    /// the same twenty-minute window for every terminating train.
    private var neighbourCandidates: [String: [Journey]] = [:]

    private func rememberBoardJourney(_ journey: Journey, departure: Timestamp, as id: String? = nil) {
        let key = BoardJourneyKey(id: id ?? journey.id, departure: departure)
        if let held = boardJourneys[key], held.stops.count > journey.stops.count { return }
        if boardJourneys[key] == nil { boardJourneyOrder.append(key) }
        boardJourneys[key] = journey

        let overflow = boardJourneyOrder.count - Self.boardJourneyLimit
        guard overflow > 0 else { return }
        for old in boardJourneyOrder.prefix(overflow) { boardJourneys.removeValue(forKey: old) }
        boardJourneyOrder.removeFirst(overflow)
    }

    /// A broad one-minute time index for the draw/refinement queries.
    ///
    /// The final lifetime check remains second-precise. This only avoids asking
    /// all eight thousand national vehicles the same two cheap questions on
    /// every frame when three quarters of them cannot exist in this minute.
    private var activeMinute: Int64 = .min
    private var activeMinuteFleetRevision = -1
    private var activeMinuteTimingRevision = -1
    private var timingRevision = 0
    private var activeMinuteJourneys: [Journey] = []
    private var activeMinuteIDs: Set<String> = []
    /// Grid of `activeMinuteJourneys` by `drawnWithin`. Rebuilt with the
    /// minute index, not every tick, so a city viewport walks overlapping
    /// cells instead of every running journey in the country.
    private var activeSpatial = SpatialGrid()
    private var activeSpatialDirty = false

    /// A coarse geographic index over the current active-minute fleet.
    ///
    /// Cell size is about 22 km at Swiss latitudes: a Genève viewport hits a
    /// handful of cells, an intercity occupies a strip rather than hundreds.
    private struct SpatialGrid {
        static let cellDegrees = 0.2
        var cells: [Int: [Journey]] = [:]
        var unboxed: [Journey] = []

        mutating func removeAll() {
            cells.removeAll(keepingCapacity: true)
            unboxed.removeAll(keepingCapacity: true)
        }

        mutating func rebuild(_ journeys: [Journey]) {
            removeAll()
            for journey in journeys { insert(journey) }
        }

        mutating func insert(_ journey: Journey) {
            guard let box = journey.drawnWithin() else {
                unboxed.append(journey)
                return
            }
            let x0 = cell(box.west), x1 = cell(box.east)
            let y0 = cell(box.south), y1 = cell(box.north)
            for x in min(x0, x1)...max(x0, x1) {
                for y in min(y0, y1)...max(y0, y1) {
                    cells[key(x, y), default: []].append(journey)
                }
            }
        }

        func journeys(overlapping box: BBox) -> [Journey] {
            var seen = Set<String>()
            var out: [Journey] = []
            out.reserveCapacity(64)
            let x0 = cell(box.west), x1 = cell(box.east)
            let y0 = cell(box.south), y1 = cell(box.north)
            for x in min(x0, x1)...max(x0, x1) {
                for y in min(y0, y1)...max(y0, y1) {
                    guard let bucket = cells[key(x, y)] else { continue }
                    for journey in bucket where seen.insert(journey.id).inserted {
                        out.append(journey)
                    }
                }
            }
            for journey in unboxed where seen.insert(journey.id).inserted {
                out.append(journey)
            }
            return out
        }

        private func cell(_ value: Double) -> Int {
            Int(floor(value / Self.cellDegrees))
        }

        private func key(_ x: Int, _ y: Int) -> Int {
            x &* 73_421 &+ y
        }
    }

    private struct ActiveLifetime: Equatable {
        var appears: Timestamp
        var stands: Timestamp
    }

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

    /// Geometry the presentation path discovered it is missing.
    ///
    /// Route matching and graph search are synchronous operations. Keeping them
    /// on the Fleet actor made their *tail* the frame time: an otherwise cheap
    /// vehicle query could sit behind one rural bus relation for two hundred
    /// milliseconds. The actor now owns only this small queue and installs the
    /// immutable result; a single utility worker owns the expensive builder.
    private struct GeometryBuildKey: Hashable, Sendable {
        var id: String
        var fingerprint: Int
        var refined: Bool
    }

    private struct GeometryBuildRequest: Sendable {
        var key: GeometryBuildKey
        var draft: Journey
        var token: UInt64
        var urgent: Bool
    }

    private enum GeometryEnqueueResult {
        case enqueued(UInt64)
        case pending(UInt64)
        case full
        case suspended
        case invalid

        var newlyEnqueued: Bool {
            if case .enqueued = self { return true }
            return false
        }

        var token: UInt64? {
            switch self {
            case .enqueued(let token), .pending(let token): return token
            default: return nil
            }
        }
    }

    private var geometryBuildQueue: [GeometryBuildRequest] = []
    /// Includes the request currently inside the synchronous builder as well as
    /// the ones waiting in `geometryBuildQueue`. The token distinguishes an old
    /// cancelled request from a later request for the same journey and path.
    private var queuedGeometryBuilds: [GeometryBuildKey: UInt64] = [:]
    private var geometryBuildToken: UInt64 = 0
    private var geometryWorker: Task<Void, Never>?
    private var geometryWorkerGeneration = 0
    private var geometryBackgroundSuspended = false
    private var consecutiveUrgentGeometryBuilds = 0

    /// Queue-space and request-completion waits share one edge-triggered signal.
    /// Waiters always re-check their own predicate, so an urgent displacement
    /// can wake a warm pass without making that pass wait on the urgent work.
    private var geometryChangeRevision: UInt64 = 0
    private var geometryChangeWaiterID: UInt64 = 0
    private var geometryChangeWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    /// Bound speculative work when a pinch exposes hundreds of uncached runs.
    /// The next frame can add more after the worker makes room, while a pan does
    /// not leave minutes of now-invisible routes queued ahead of its new view.
    private static let geometryQueueLimit = 12
    /// User-visible work wins promptly, but a settled viewport still lets the
    /// speculative queue advance rather than starving it behind a steady tick.
    private static let geometryUrgentBurst = 4

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

    /// One record per operating run; feed IDs are aliases into this store.
    /// The map remains a bounded time-window projection of the timetable.
    private let runs = RunStore()
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
    /// Derived timetable geography, kept between launches so a cold start
    /// does not walk the stop register for every pattern in the window.
    private var geographyCacheURL: URL?
    /// How many legs were in the cache when it was last written, so an idle
    /// session does not rewrite an unchanged file.
    private var legsAtLastSave = -1

    public init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
        builder = GeometryBuilder(relations: relations, railnet: railnet)
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

    public func load(from directory: URL, supporting: Bool = true) -> Loaded {
        var result = Loaded()

        func attempt(_ name: String, _ body: () throws -> Void) {
            do { try body() } catch { result.problems.append("\(name): \(error)") }
        }

        // What the first frame needs: placing calls, naming operators, drawing
        // stop dots, and expanding the timetable for the opening camera.
        // Routes, the railway graph and platform plates wait until the map is
        // up — together they were the other half of a four-second read on a
        // phone, and none of them is required to put a vehicle on the chord
        // between its two stops.
        attempt("stops") {
            try register.load(
                stopsFile: directory.appendingPathComponent("stops.bin"),
                foreignFile: directory.appendingPathComponent("foreign.bin"),
                spatial: supporting
            )
        }
        attempt("operators") { try operators.load(directory.appendingPathComponent("operators.bin")) }
        attempt("stop places") { try stopPlaces.load(directory.appendingPathComponent("stop-places.bin")) }
        // Not through `attempt`: a missing timetable is not a problem to report,
        // it is a build without one. The feed still draws the map.
        timetable = try? TimetableStore(url: directory.appendingPathComponent("timetable.bin"))
        if let geographyCacheURL {
            timetable?.openGeographyCache(at: geographyCacheURL)
        }

        builder = GeometryBuilder(relations: relations, railnet: railnet)

        result.stops = register.stats.stops
        result.stopPlaces = stopPlaces.count
        if supporting {
            supportingLoaded = false
            loadSupporting(from: directory, into: &result)
        }
        return result
    }

    /// Routes, rails, platforms — everything the first frame can do without.
    ///
    /// Called once the map is up. The builder already holds these stores, so
    /// filling them in is enough for the next refine pass to put vehicles on
    /// their tracks.
    @discardableResult
    public func loadSupporting(from directory: URL) -> Loaded {
        var result = Loaded()
        loadSupporting(from: directory, into: &result)
        return result
    }

    private func loadSupporting(from directory: URL, into result: inout Loaded) {
        if supportingLoaded {
            result.relations = relations.count
            result.railnetNodes = railnet.nodeCount
            result.platformShapes = platforms.shapeCount
            result.stops = register.stats.stops
            result.stopPlaces = stopPlaces.count
            return
        }
        supportingLoaded = true
        func attempt(_ name: String, _ body: () throws -> Void) {
            do { try body() } catch { result.problems.append("\(name): \(error)") }
        }
        register.buildSpatialIndex()
        attempt("platforms") { try platforms.load(directory.appendingPathComponent("platforms.bin")) }
        attempt("platform access") { try platformAccess.load(directory.appendingPathComponent("access.bin")) }
        attempt("routes") { try relations.load(directory.appendingPathComponent("routes.bin")) }
        if !railnet.isReady {
            attempt("railnet") { try railnet.load(directory.appendingPathComponent("railnet.bin")) }
        }
        result.relations = relations.count
        result.railnetNodes = railnet.nodeCount
        result.platformShapes = platforms.shapeCount
        result.stops = register.stats.stops
        result.stopPlaces = stopPlaces.count
    }

    /// Station-board indexes: slot→station, station→patterns, pattern→trips.
    ///
    /// Built off the tap path so the first station card does not pay the
    /// 179,000-pattern walk while a spinner is on screen.
    public func prepareBoardIndexes() {
        timetable?.prepareBoardIndexes()
    }

    /// The overlay graph, without the 31 MB route store.
    ///
    /// Track drawing only needs this file. Loading it behind `routes.bin` is
    /// why the rails used to arrive ten seconds after the vehicles: the map
    /// was up, and still waiting on a string table it does not paint.
    @discardableResult
    public func loadRailnet(from directory: URL) async -> Loaded {
        var result = Loaded()
        result.stops = register.stats.stops
        result.stopPlaces = stopPlaces.count
        result.relations = relations.count
        if railnet.isReady {
            result.railnetNodes = railnet.nodeCount
            return result
        }
        let url = directory.appendingPathComponent("railnet.bin")
        let loaded = await Task.detached(priority: .userInitiated) {
            let net = RailNet()
            try? net.load(url)
            return net
        }.value
        if loaded.isReady {
            railnet.take(loaded)
        }
        result.railnetNodes = railnet.nodeCount
        if !railnet.isReady {
            result.problems.append("railnet: missing")
        }
        return result
    }

    /// Install a graph loaded off the actor. No-op if rails are already in.
    public func installRailnet(_ net: RailNet) {
        guard net.isReady, !railnet.isReady else { return }
        railnet.take(net)
    }

    public func configure(token: String?) {
        client = OTDClient(token: token, budget: "gtfs-rt")
    }

    /// Pattern boxes and slot coordinates, written once so the next launch
    /// does not derive them from cold mapped pages.
    public func openGeographyCache(at url: URL) {
        geographyCacheURL = url
        timetable?.openGeographyCache(at: url)
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
        guard !Task.isCancelled else { return false }
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
            if error is CancellationError || Task.isCancelled {
                monitor.settle(.idle)
                return false
            }
            status.failures += 1
            status.lastError = String(describing: error)
            monitor.settle(.failed(String(describing: error)))
            return false
        }

        guard !Task.isCancelled else {
            monitor.settle(.idle)
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
        // A suspended app may cancel while the pure decoder is running. Its
        // result is harmless, but folding it would mutate the fleet after the
        // lifecycle boundary and make that intentional cancellation a refresh.
        guard !Task.isCancelled else {
            monitor.settle(.idle)
            return false
        }
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
    private var realtimeReplacements: [String: (id: String, departure: Timestamp)] = [:]

    /// Some producers publish a cancellation plus a new trip for a changed
    /// platform, or an added extra for a delayed working after an incident.
    /// Preserve the scheduled identity for a unique complete-route match,
    /// including when the extra is already running late.
    private func reconcilePlatformReplacements(_ feed: RealtimeFeed, at now: Timestamp) -> Bool {
        realtimeReplacements = realtimeReplacements.filter { _, held in
            guard let run = journeys[held.id], let first = run.stops.first else { return false }
            return abs((first.sched ?? first.dep) - held.departure) < 12 * 3600
        }
        let cancelled = Set(feed.updates.filter {
            $0.relationship == .canceled || $0.relationship == .deleted
        }.map(\.tripID))
        // Cancelled originals first, then any still-running timetable twin.
        // A delayed extra after an accident is often published without
        // cancelling the printed trip, and matching only cancellations left
        // both on the map: an on-time ghost and an "unscheduled" extra.
        let candidates = journeys.values.filter { !$0.extra }.sorted { a, b in
            let aCancelled = a.cancelled || cancelled.contains(a.id)
            let bCancelled = b.cancelled || cancelled.contains(b.id)
            if aCancelled != bCancelled { return aCancelled && !bCancelled }
            return a.id < b.id
        }
        guard !candidates.isEmpty else { return false }
        var proposals: [String: [String]] = [:]
        for update in feed.updates where update.relationship == .added || update.relationship == .replacement {
            guard realtimeReplacements[update.tripID] == nil,
                  journeys[update.tripID]?.extra != false,
                  let new = buildExtra(update, at: now) else { continue }
            let matching = candidates.filter { Reconcile.isPlatformReplacement(new, of: $0) }
            guard matching.count == 1, let original = matching.first else { continue }
            proposals[original.id, default: []].append(update.tripID)
        }
        var removed = false
        for (originalID, replacements) in proposals where replacements.count == 1 {
            guard let newID = replacements.first, let original = journeys[originalID],
                  let first = original.stops.first else { continue }
            realtimeReplacements[newID] = (originalID, first.sched ?? first.dep)
            if let update = feed.updates.first(where: { $0.tripID == newID }),
               let replacement = buildExtra(update, at: now) {
                runs.registerReplacement(replacement, of: original)
            }
            if journeys.removeValue(forKey: newID) != nil { removed = true }
            retired.removeValue(forKey: newID)
        }
        return removed
    }

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
        var arrived = reconcilePlatformReplacements(feed, at: now)
        // The old entry may remain SCHEDULED with individual SKIPPED calls.
        // Once linked, only the replacement describes this occurrence, even
        // when a later snapshot omits it. Feed order must not reinstate the old
        // platforms or cancelled calls.
        let replaced = Set(realtimeReplacements.values.map(\.id))
        var moved: [(journey: Journey, repathed: Bool)] = []
        // If the chained fleet is already current, remember only the visible
        // lifetime of vehicles actually touched. A cancellation, a platform
        // change or a middle-stop correction must not make the next frame
        // rebuild the national minute index when neither edge moved.
        let trackingActiveLifetime = chainedRevision == revision
        var activeLifetimeBefore: [String: ActiveLifetime] = [:]

        for update in feed.updates {
            if replaced.contains(update.tripID) { continue }
            let identity = realtimeReplacements[update.tripID]?.id ?? update.tripID
            let alias = runs.journey(id: identity, at: now)
            guard let active = journeys[identity] ?? alias.flatMap({ journeys[$0.id] }) else {
                // No timetabled run under this id. Either the feed is talking
                // about something outside the window the map has expanded — the
                // ordinary case, since it covers three hours and the map draws
                // ninety minutes — or it is a run that is in no timetable at
                // all, which is the one case worth building from scratch.
                if update.isExtra, let built = buildExtra(update, at: now) {
                    let canonical = runs.ingest(built)
                    journeys[canonical.id] = canonical
                    report.added += 1
                    arrived = true
                } else if update.isExtra {
                    report.added += 1
                } else {
                    report.unmatched += 1
                }
                continue
            }
            let journey = runs.resolve(active)
            if journey !== active {
                journeys.removeValue(forKey: active.id)
                journeys[journey.id] = journey
                arrived = true
            }
            report.matchedByRef += 1

            let lifetimeBefore: (id: String, lifetime: ActiveLifetime)?
            if trackingActiveLifetime {
                let vehicle = currentVehicle(containing: journey)
                lifetimeBefore = (vehicle.id, Self.activeLifetime(of: vehicle))
            } else {
                lifetimeBefore = nil
            }

            var changed = false
            if realtimeReplacements[update.tripID] != nil,
               let reference = update.journeyReference {
                if journey.journeyRef != reference {
                    journey.journeyRef = reference
                    changed = true
                    arrived = true // Joined parts copy the journey reference.
                }
                if let number = FormationKey(journeyID: reference, operationDate: "").map({ String($0.trainNumber) }),
                   journey.number != number {
                    journey.number = number
                    changed = true
                    arrived = true
                }
            }
            let wasCancelled = journey.cancelled
            switch update.relationship {
            case .canceled, .deleted:
                journey.cancelled = true
                changed = changed || !wasCancelled
            case .added, .duplicated, .replacement, .unscheduled:
                let extra = journey.extra && realtimeReplacements[update.tripID] == nil
                    && update.relationship != .replacement
                changed = changed || journey.extra != extra || journey.cancelled
                journey.extra = extra
                journey.cancelled = false
            case .scheduled:
                changed = changed || journey.cancelled
                journey.cancelled = false
            }
            if wasCancelled != journey.cancelled { arrived = true }

            let refs = journey.stops.map(\.ref)
            if apply(update, to: journey, at: now) { changed = true }
            if changed {
                moved.append((journey, refs != journey.stops.map(\.ref)))
                if let lifetimeBefore, activeLifetimeBefore[lifetimeBefore.id] == nil {
                    activeLifetimeBefore[lifetimeBefore.id] = lifetimeBefore.lifetime
                }
            }
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
            for change in moved { refold(change.journey, repathed: change.repathed) }
            let lifetimeMoved = activeLifetimeBefore.contains { id, before in
                guard let vehicle = chained[id] ?? journeys[id] else { return true }
                return Self.activeLifetime(of: vehicle) != before
            }
            if lifetimeMoved { timingRevision &+= 1 }
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
    /// feed — the rest use a form no timetable contains. Those are drawn as
    /// `ext` rather than left off the map: an empty plate reads as a missing
    /// chip, and `extra` is what they are.
    private func buildExtra(_ update: TripUpdate, at now: Timestamp) -> Journey? {
        var calls: [Call] = []
        calls.reserveCapacity(update.stops.count)
        var visits: [String: Int] = [:]

        for stop in update.stops.sorted(by: { ($0.sequence ?? 0) < ($1.sequence ?? 0) }) {
            guard let ref = stop.assignedStopID ?? stop.stopID, let place = register.lookup(ref) else { continue }
            // A call with neither time is a call the vehicle cannot be
            // positioned against, and the interpolator needs both ends filled.
            guard let time = stop.departure ?? stop.arrival else { continue }
            let visit = (visits[ref] ?? 0) + 1
            visits[ref] = visit
            let live = stop.departure ?? time
            let delaySeconds = stop.departureDelay ?? stop.arrivalDelay ?? update.delay
            calls.append(Call(
                key: "\(ref)|\(visit)",
                ref: ref,
                name: place.name,
                lat: place.lat,
                lon: place.lon,
                platform: place.platform,
                precise: place.precise,
                arr: stop.arrival ?? time,
                dep: live,
                delay: SiriParser.reportableDelay(delaySeconds),
                // Every time here is the operator's own statement about a run
                // it has just filed, so a call already behind us is what
                // happened rather than what was predicted.
                observed: time < now,
                sched: live - (delaySeconds ?? 0),
                assigned: place.assigned,
                cancelled: stop.skipped,
                extra: stop.extra,
                scheduledArrival: stop.arrival.map { $0 - (stop.arrivalDelay ?? update.delay ?? 0) }
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
            // About two in five extras have a route_id no timetable contains.
            // Those used to be drawn with an empty plate; `ext` is the word
            // that says what they are, and a published number still wins.
            line: Journey.badgeLine(known?.line, extra: true, mode: known?.mode),
            number: update.journeyReference.flatMap { FormationKey(journeyID: $0, operationDate: "") }.map { String($0.trainNumber) },
            operatorName: nil,
            operatorFull: nil,
            to: calls.last?.name,
            from: calls[0].name,
            // Minutes, as everywhere `delay` is read; the feed states seconds.
            // Trip-level delay is often omitted on added runs even when every
            // call is eight minutes down, so fall back to the calls.
            delay: SiriParser.reportableDelay(update.delay)
                ?? calls.compactMap(\.delay).max { abs($0) < abs($1) },
            start: calls[0].dep,
            end: calls[calls.count - 1].arr,
            complete: true,
            monitored: true,
            cancelled: update.relationship == .canceled || update.relationship == .deleted,
            source: Journey.timetableSource,
            stops: calls,
            extra: true,
            journeyRef: update.journeyReference
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
            guard let seconds = update.delay, let minutes = SiriParser.reportableDelay(seconds) else { return false }
            let calls = journey.stops.indices.filter { !journey.stops[$0].observed }.map {
                StopTimeUpdate(sequence: $0 + 1, arrivalDelay: seconds, departureDelay: seconds)
            }
            guard !calls.isEmpty else {
                let changed = journey.delay != minutes
                journey.delay = minutes
                return changed
            }
            return apply(TripUpdate(tripID: update.tripID, delay: seconds, stops: calls), to: journey, at: now)
        }

        // Where this vehicle is before the fold, so a correction that moves it
        // a length of track is walked off rather than jumped. See
        // `Journey.settle`. Nil for a run not currently on the map, which is
        // nearly all of the six thousand in a national tick.
        let anchor = Positioning.retimeAnchor(journey, at: now)

        // The feed keys calls by `stop_id`, which is the SLOID the timetable's
        // calls already carry — so this is a lookup rather than a match.
        // Sequence is the fallback for a looping route that calls twice, not
        // the first key: an exceptional halt inserted as sequence 2 would
        // otherwise overwrite the printed second stop.
        var bySequence: [Int: StopTimeUpdate] = [:]
        var byStop: [String: StopTimeUpdate] = [:]
        for stop in update.stops {
            if let n = stop.sequence { bySequence[n] = stop }
            if let ref = stop.stopID { byStop[ref] = stop }
            if let ref = stop.assignedStopID { byStop[ref] = stop }
        }

        var moved = false
        var platformChanged = false
        for index in journey.stops.indices {
            let found = matchingUpdate(
                for: journey.stops[index], at: index,
                byStop: byStop, bySequence: bySequence
            )
            guard let found else { continue }

            if found.skipped != journey.stops[index].cancelled {
                journey.stops[index].cancelled = found.skipped
                moved = true
            }
            if let ref = found.assignedStopID ?? found.stopID,
               ref != journey.stops[index].ref,
               StopRegister.stationOf(ref) == StopRegister.stationOf(journey.stops[index].ref),
               let place = register.lookup(ref) {
                journey.stops[index].ref = ref
                journey.stops[index].platform = place.platform
                journey.stops[index].assigned = place.assigned
                journey.stops[index].lat = place.lat
                journey.stops[index].lon = place.lon
                journey.stops[index].precise = place.precise
                platformChanged = true
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
            let booked = journey.stops[index].sched ?? journey.stops[index].dep
            journey.stops[index].sched = booked
            let bookedArrival = journey.stops[index].scheduledArrival
                ?? journey.stops[index].arr - (journey.stops[index].dep - booked)
            journey.stops[index].scheduledArrival = bookedArrival
            let departure = found.departure ?? found.departureDelay.map { booked + $0 }
            let arrival = found.arrival ?? found.arrivalDelay.map { bookedArrival + $0 }
                ?? departure.map { bookedArrival + ($0 - booked) }
            let resolvedDeparture = departure ?? arrival.map { booked + ($0 - bookedArrival) }
            if let arrival, arrival != journey.stops[index].arr {
                journey.stops[index].arr = arrival
                moved = true
            }
            if let resolvedDeparture {
                let time = max(journey.stops[index].arr, resolvedDeparture)
                if time != journey.stops[index].dep {
                    journey.stops[index].dep = time
                    moved = true
                }
            }
            // Minutes, as above — and note the two lines before this one are
            // deliberately *not* converted: those add a delay to a `Timestamp`,
            // which is unix seconds, so seconds is exactly what they want.
            // Absolute times without a delay field still have a delay: the
            // printed slot is `sched`, and the live clock minus that slot is
            // the number the board should print.
            if let stated = found.departureDelay ?? found.arrivalDelay {
                journey.stops[index].delay = SiriParser.reportableDelay(stated)
            } else {
                journey.stops[index].delay = SiriParser.reportableDelay(
                    journey.stops[index].dep - booked
                )
            }
            journey.stops[index].observed = journey.stops[index].dep < now
        }

        if insertExtraStops(update.stops, onto: journey, at: now) {
            moved = true
            platformChanged = true
        }

        if moved {
            if platformChanged {
                journey.invalidateGeometry()
                builtGeometry[journey.id] = nil
            }
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

    /// Prefer the update that names this call, so an extra halt at sequence 2
    /// does not steal the printed second stop's times.
    private func matchingUpdate(
        for call: Call, at index: Int,
        byStop: [String: StopTimeUpdate], bySequence: [Int: StopTimeUpdate]
    ) -> StopTimeUpdate? {
        if let ref = call.ref {
            if let hit = byStop[ref] { return hit }
            let station = StopRegister.stationOf(ref)
            let hits = byStop.filter { StopRegister.stationOf($0.key) == station }
            if hits.count == 1 { return hits.first?.value }
        }
        return bySequence[index + 1]
    }

    /// Halt the printed trip does not contain. GTFS-RT files those as a
    /// `UNSCHEDULED` stop-time update. An unmatched `SCHEDULED` or `NO_DATA`
    /// `stop_id` is a packing difference — passing time, operating point —
    /// not SBB's exceptional stop.
    private func insertExtraStops(
        _ updates: [StopTimeUpdate], onto journey: Journey, at now: Timestamp
    ) -> Bool {
        var inserted = false
        let ordered = updates.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
        for stop in ordered where stop.extra && !stop.skipped {
            let ref = stop.assignedStopID ?? stop.stopID
            guard let ref else { continue }
            let station = StopRegister.stationOf(ref)
            if journey.stops.contains(where: {
                $0.ref.map { StopRegister.stationOf($0) == station } == true
            }) { continue }
            guard let time = stop.departure ?? stop.arrival,
                  let place = register.lookup(ref) else { continue }
            if StopNaming.isTechnical(place.name) { continue }
            let delaySeconds = stop.departureDelay ?? stop.arrivalDelay
            let call = Call(
                key: "\(ref)|extra",
                ref: ref,
                name: place.name,
                lat: place.lat,
                lon: place.lon,
                platform: place.platform,
                precise: place.precise,
                arr: stop.arrival ?? time,
                dep: stop.departure ?? time,
                delay: SiriParser.reportableDelay(delaySeconds),
                observed: time < now,
                sched: (stop.departure ?? time) - (delaySeconds ?? 0),
                assigned: place.assigned,
                extra: true
            )
            let index = journey.stops.firstIndex(where: { $0.dep > call.dep })
                ?? journey.stops.count
            journey.stops.insert(call, at: index)
            inserted = true
        }
        return inserted
    }

    // MARK: - Drawing from the timetable

    /// Whether there is a timetable to draw from at all.
    public var hasTimetable: Bool { timetable?.isReady ?? false }

    /// Slot coordinates and pattern boxes, once, before a window query.
    private func prepareTimetableQuery() {
        guard let timetable, register.isReady else { return }
        timetable.prepareQuery(place: { [register] ref in register.lookup(ref) })
    }

    /// Finish and persist pattern boxes after the first frame, so the next
    /// launch does not re-derive them.
    public func completeTimetableGeography() {
        guard let timetable, register.isReady else { return }
        timetable.completeGeography(place: { [register] ref in register.lookup(ref) })
    }

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
        prepareTimetableQuery()

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
        rememberCoverage(region)
        timetableDrawnAt = moment
        return true
    }

    /// The span the timetable was last expanded over.
    private var timetableWindow: ClosedRange<Timestamp>?

    /// The region the drawn fleet was clipped to, if it was clipped at all.
    ///
    /// `nil` means the last pass was national — either a country-wide opening
    /// or an explicit `completeTimetable`. A launch that opened on one place
    /// keeps this set and grows `timetableCoverage` as the camera asks for
    /// more, rather than filling the country behind the map.
    public private(set) var timetableRegion: BBox?
    private var timetableDrawnAt: Date?

    /// Regions already expanded, each padded the way `expandTimetable` queries.
    ///
    /// A list rather than their union: Geneva and Zürich together must not
    /// claim Lausanne is covered. Empty means the fleet is the country.
    private var timetableCoverage: [BBox] = []

    public var isTimetablePartial: Bool { timetableRegion != nil }

    /// How much larger than the asked viewport a coverage box is stored.
    ///
    /// Big enough that a short pan does not rebuild, small enough that a
    /// pinch-out still asks for the newly visible ground. The store pads again
    /// internally (a quarter of the query) against whole *routes*, so this is
    /// only the margin the camera can move before we spend another expand.
    static let timetableCoveragePad = 0.4

    /// Rough extent of the packed network, used only to recognise a camera
    /// that is already looking at the country.
    static let networkBounds = BBox(west: 5.5, south: 45.6, east: 10.9, north: 48.0)

    /// Whether `region` is already inside a box the timetable has expanded.
    ///
    /// The draw query pads its viewport by 0.15, so this asks about a slightly
    /// larger box than the screen: expanding after the edge has gone empty is
    /// a frame of missing trains.
    public func covers(_ region: BBox) -> Bool {
        guard timetableWindow != nil else { return false }
        if timetableCoverage.isEmpty {
            return !isTimetablePartial && !journeys.isEmpty
        }
        let needed = region.padded(by: 0.2)
        return timetableCoverage.contains { $0.contains(needed) }
    }

    private func rememberCoverage(_ region: BBox?) {
        guard let region else {
            timetableCoverage = []
            timetableRegion = nil
            return
        }
        let padded = region.padded(by: Self.timetableCoveragePad)
        if padded.contains(Self.networkBounds) {
            timetableCoverage = []
            timetableRegion = nil
            return
        }
        if !timetableCoverage.contains(where: { $0.contains(padded) }) {
            timetableCoverage.append(padded)
        }
        timetableRegion = padded
    }

    /// Add the services that run through `region` onto a fleet that was drawn
    /// for a smaller view.
    ///
    /// Additive, like `completeTimetable`: a train the reader has already
    /// opened may have OJP timings folded onto it, and replacing the store
    /// would throw those away. Ids already in hand stay as they are; only the
    /// missing ones are built.
    ///
    /// This is what a zoom-out and a pan onto new ground both call. The
    /// country is not filled in behind the map — it is filled in when the
    /// camera actually asks to see it.
    @discardableResult
    public func expandTimetable(to region: BBox) -> Bool {
        guard let timetable, timetable.isReady, register.isReady,
              let moment = timetableDrawnAt, let window = timetableWindow
        else { return false }
        if covers(region) { return false }
        prepareTimetableQuery()

        let started = Date()
        let padded = region.padded(by: Self.timetableCoveragePad)
        let built = timetable.journeys(
            from: window.lowerBound,
            to: window.upperBound,
            in: padded,
            place: { [register] ref in register.lookup(ref) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        )
        // Recorded even when nothing was added, or a quiet valley would be
        // asked about on every later pan across the same empty ground.
        rememberCoverage(region)
        guard !built.isEmpty else { return false }

        var found = journeys
        var added = 0
        for journey in built where found[journey.id] == nil {
            let canonical = runs.ingest(journey)
            if found[canonical.id] == nil {
                found[canonical.id] = canonical
                added += 1
            }
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
    /// The launch path no longer calls this. Zooming out to the country still
    /// can, and tests that want the whole window in one go still do.
    @discardableResult
    public func completeTimetable() -> Bool {
        guard isTimetablePartial, let timetable, timetable.isReady, register.isReady,
              let moment = timetableDrawnAt, let window = timetableWindow
        else { return false }
        prepareTimetableQuery()

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
        rememberCoverage(nil)
        guard !built.isEmpty else { return false }

        var found = journeys
        var added = 0
        for journey in built where found[journey.id] == nil {
            let canonical = runs.ingest(journey)
            if found[canonical.id] == nil {
                found[canonical.id] = canonical
                added += 1
            }
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

    /// Resolve pattern boxes for the rest of the current window, a budget at a
    /// time, without building the journeys.
    ///
    /// The first clipped draw only works out the boxes it needed to reject
    /// against. This walks the remainder so a later expand — a zoom-out, a pan
    /// two valleys over — is a compare and a build, not a stop-register walk
    /// on the actor the frame is waiting on. Returns whether more unknown
    /// boxes remain, so the caller can yield between chunks.
    public func prefetchTimetableGeography(budget: Int = 512) -> Bool {
        guard let timetable, let window = timetableWindow, register.isReady else {
            return false
        }
        if timetable.geographyReady { return false }
        prepareTimetableQuery()
        return timetable.prefetchGeography(
            from: window.lowerBound,
            to: window.upperBound,
            budget: budget,
            place: { [register] ref in register.lookup(ref) }
        )
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
    ///
    /// A partial fleet is rebuilt as the same regions, not as the country: the
    /// whole point of staying clipped is not to spend a time-scrub on 25,000
    /// journeys the camera is not looking at.
    @discardableResult
    public func redrawTimetableIfNeeded(at moment: Date) -> Bool {
        guard hasTimetable else { return false }
        let now = Timestamp(moment.timeIntervalSince1970)
        guard let window = timetableWindow else {
            return drawTimetable(at: moment, in: timetableRegion)
        }
        let margin = Timestamp(Self.timetableMargin)
        guard now < window.lowerBound + margin || now > window.upperBound - margin else {
            return false
        }
        let saved = timetableCoverage
        let region = saved.first ?? timetableRegion
        let ok = drawTimetable(at: moment, in: saved.isEmpty ? nil : region)
        if saved.count > 1 {
            for extra in saved.dropFirst() {
                _ = expandTimetable(to: extra)
            }
        }
        return ok
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
    public func applyTiming(
        _ timing: JourneyTiming, to id: String, at moment: Date = Date(),
        boardDeparture: Timestamp? = nil
    ) -> Int {
        if let boardDeparture {
            // Scheduled panels can name tomorrow's instance of a reused trip
            // ID. Never apply that response (especially cancellation or extra
            // calls) to today's map vehicle under the same ID.
            guard let listed = boardJourneys[BoardJourneyKey(id: id, departure: boardDeparture)] else { return 0 }
            let resolve: (String, String?) -> Place? = { [register] ref, quay in
                register.lookup(ref, statedPlatform: quay, name: nil)
            }
            let wasCancelled = listed.cancelled
            let touched = listed.apply(timing, at: Timestamp(moment.timeIntervalSince1970), resolve: resolve)
            let grew = listed.absorb(extras: timing.calls, resolve: resolve)
            return touched + (grew || wasCancelled != listed.cancelled ? 1 : 0)
        }
        guard let journey = journeys[id] ?? chained[id] ?? runs.journey(id: id, at: Timestamp(moment.timeIntervalSince1970)) else { return 0 }
        let boardOnly = journeys[id] == nil && chained[id] == nil
        let lifetimeBefore: (id: String, lifetime: ActiveLifetime)?
        if !boardOnly, chainedRevision == revision {
            let vehicle = currentVehicle(containing: journey)
            lifetimeBefore = (vehicle.id, Self.activeLifetime(of: vehicle))
        } else {
            lifetimeBefore = nil
        }
        let hadPath = journey.geometry != nil
        let quays = journey.stops.map(\.platform)
        let refs = journey.stops.map(\.ref)
        let resolve: (String, String?) -> Place? = { [register] ref, quay in
            if let quay, let platform = register.platformPoint(station: StopRegister.stationOf(ref), code: quay) {
                return register.lookup(platform.id)
            }
            return register.lookup(ref, statedPlatform: quay, name: nil)
        }
        let touched = journey.apply(timing, at: Timestamp(moment.timeIntervalSince1970), resolve: resolve)
        let grew = journey.absorb(extras: timing.calls, resolve: resolve)
        guard touched > 0 || grew else { return 0 }
        if boardOnly {
            if journey.source == "ojp" { applyBoardTimingToMap(journey) }
            return touched + (grew ? 1 : 0)
        }
        // The path only moved if the platform did — `Journey.apply` drops it
        // then — or if the stop list grew past the border.
        let repathed = grew || (hadPath && journey.geometry == nil)
            || zip(quays, journey.stops).contains {
                $0 != $1.platform && !StopRegister.sameTrack($0, $1.platform)
            }
            || refs != journey.stops.map(\.ref)
        if repathed { builtGeometry[id] = nil }
        refold(journey, repathed: repathed)
        if let lifetimeBefore {
            let vehicle = chained[lifetimeBefore.id] ?? journeys[lifetimeBefore.id]
            if vehicle.map(Self.activeLifetime(of:)) != lifetimeBefore.lifetime {
                timingRevision &+= 1
            }
        }
        return touched + (grew ? 1 : 0)
    }

    /// Fold formation stops the packed timetable omitted onto either end of
    /// a journey. Middle extras have to come from a feed that marked them as
    /// such; formation lists passing stations too.
    @discardableResult
    public func absorbFormationStops(_ formation: TrainFormation, onto id: String) -> Bool {
        guard let journey = journeys[id] ?? chained[id] else { return false }
        let extras: [Call] = formation.stops.compactMap { stop in
            let ref = StopRegister.sloid(forDidok: String(format: "%07d", stop.uic))
                ?? String(stop.uic)
            let arr = stop.arrival.map { Timestamp($0.timeIntervalSince1970) }
            let dep = stop.departure.map { Timestamp($0.timeIntervalSince1970) }
            guard let when = arr ?? dep else { return nil }
            return Call(
                key: "\(ref)|formation",
                ref: ref,
                name: stop.stopName,
                lat: 0, lon: 0,
                platform: stop.track,
                precise: false,
                arr: arr ?? when,
                dep: dep ?? when,
                sched: dep ?? arr ?? when
            )
        }
        let grew = journey.absorb(extras: extras) { [register] ref, quay in
            register.lookup(ref, statedPlatform: quay, name: nil)
        }
        guard grew else { return false }
        builtGeometry[id] = nil
        refold(journey, repathed: true)
        return true
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
        keepGeometry(for: merged.keys)
        runs.removeAll()
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
        drawnMoment = drawnAt ?? current
        runs.prune(around: Timestamp((drawnAt ?? current).timeIntervalSince1970))
        for input in found.values.sorted(by: { $0.id < $1.id }) {
            runs.ingest(input)
        }
        var canonical: [String: Journey] = [:]
        for input in found.values {
            let run = runs.resolve(input)
            canonical[run.id] = run
        }
        retire(replacing: canonical)
        journeys = canonical
        // The memo answers for what the feed still carries. Anything else has
        // finished, and a finished journey's path is not asked for again —
        // `retire` drops it for the same reason. Re-key by alias so an OJP id
        // does not drop the path built under the timetable id.
        keepGeometry(for: canonical.keys)
        mirrorAsked = [:]
        revision += 1
        status.journeys = canonical.count
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
            let vehicles = Chains.build(standing(), published: publishedGraph())
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
            noteGeometryChanged()
        }
        return chained
    }

    /// The physical vehicle carrying a raw leg in the current chained fleet.
    /// Called only while `chainedRevision == revision`; otherwise the pending
    /// rebuild is already sufficient to invalidate every derived index.
    private func currentVehicle(containing journey: Journey) -> Journey {
        if let id = chainOf[journey.id], let vehicle = chained[id] { return vehicle }
        return chained[journey.id] ?? journey
    }

    private static func activeLifetime(of journey: Journey) -> ActiveLifetime {
        ActiveLifetime(
            appears: Positioning.appearsAt(journey),
            stands: Positioning.standsUntil(journey)
        )
    }

    /// Journeys whose visible lifetime intersects the minute containing
    /// `moment`. The callers still apply their original exact time tests; this
    /// is an index, never a change in inclusion semantics.
    private func activeJourneys(
        in fleet: [String: Journey], at moment: Double
    ) -> [Journey] {
        let minute = Int64(floor(moment / 60))
        if minute == activeMinute
            && activeMinuteFleetRevision == chainedRevision
            && activeMinuteTimingRevision == timingRevision {
            if activeSpatialDirty {
                activeSpatial.rebuild(activeMinuteJourneys)
                activeSpatialDirty = false
            }
            return activeMinuteJourneys
        }

        let lower = Double(minute) * 60
        let upper = lower + 60
        activeMinuteJourneys.removeAll(keepingCapacity: true)
        activeMinuteJourneys.reserveCapacity(fleet.count / 3)
        activeMinuteIDs.removeAll(keepingCapacity: true)
        activeMinuteIDs.reserveCapacity(fleet.count / 3)
        for journey in fleet.values where journey.stops.count >= 2 {
            guard Double(Positioning.appearsAt(journey)) <= upper,
                  Double(Positioning.standsUntil(journey)) >= lower
            else { continue }
            activeMinuteJourneys.append(journey)
            activeMinuteIDs.insert(journey.id)
        }

        activeMinute = minute
        activeMinuteFleetRevision = chainedRevision
        activeMinuteTimingRevision = timingRevision
        activeSpatial.rebuild(activeMinuteJourneys)
        activeSpatialDirty = false
        return activeMinuteJourneys
    }

    /// Geometry attach enlarges `drawnWithin`. Rebuild the grid on the next
    /// query rather than walking the country until the minute rolls over.
    private func noteGeometryChanged() {
        activeSpatialDirty = true
    }

    /// Active-minute journeys whose route box overlaps `padded`.
    ///
    /// `including` is still an explicit exception: a selected vehicle that
    /// just jumped out of the box has to come back.
    private func spatialCandidates(
        in padded: BBox, at moment: Double, including extraId: String? = nil
    ) -> [Journey] {
        let fleet = fleetByID()
        _ = activeJourneys(in: fleet, at: moment)
        var candidates = activeSpatial.journeys(overlapping: padded)
        if let extraId, let extra = fleet[extraId],
           !candidates.contains(where: { $0.id == extraId }) {
            candidates.append(extra)
        }
        return candidates
    }

    /// Test seam: the spatial index's candidate set before positioning.
    func spatialCandidateIDs(in bbox: BBox, at now: Timestamp) -> Set<String> {
        let padded = bbox.padded(by: 0.15)
        return Set(spatialCandidates(in: padded, at: Double(now)).map(\.id))
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
            guard let journey = chainedVehicle(forID: id), journey.geometry == nil else { continue }
            guard held.fingerprint == Self.callFingerprint(journey.stops) else { continue }
            journey.geometry = held.geometry
            journey.legsFromRoute = held.fromRoute
            journey.legsFromGraph = held.fromGraph
            noteGeometryChanged()
        }
    }

    /// Keep memoised paths for the journeys that are still in the store, even
    /// when a live alias changed the public id the path was first stored under.
    private func keepGeometry(for ids: some Collection<String>) {
        var remapped: [String: BuiltGeometry] = [:]
        remapped.reserveCapacity(ids.underestimatedCount)
        for id in ids {
            if let held = builtGeometry[id] {
                remapped[id] = held
                continue
            }
            for alias in runs.allAliases(of: id) where alias != id {
                if let held = builtGeometry[alias] {
                    remapped[id] = held
                    break
                }
            }
        }
        builtGeometry = remapped
    }

    /// The chained vehicle this public id currently names.
    private func chainedVehicle(forID id: String) -> Journey? {
        if let direct = chained[id] { return direct }
        if let chain = chainOf[id], let joined = chained[chain] { return joined }
        for alias in runs.allAliases(of: id) where alias != id {
            if let direct = chained[alias] { return direct }
            if let chain = chainOf[alias], let joined = chained[chain] { return joined }
        }
        return nil
    }

    /// The chained fleet as a plain array, for the queries that live in another
    /// file of this module.
    func fleetVehicles() -> [Journey] { Array(fleetByID().values) }

    /// The time-indexed subset for live module-level queries. Callers retain
    /// their exact second-level lifetime and position checks.
    func activeFleetVehicles(at moment: Double) -> [Journey] {
        let fleet = fleetByID()
        return activeJourneys(in: fleet, at: moment)
    }

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
        if railnet.isReady {
            cableKinds[key] = resolved.kind
            // And an answer that was only reached because the window did not
            // hold enough of the line to measure is kept, but marked, so the
            // next window that holds more gets to change its mind. Without
            // this, a line first seen during the clipped opening draw would
            // wear that first guess for the life of the process.
            if resolved.settled { unsettledCable.remove(key) }
            else { unsettledCable.insert(key) }
        }
        return resolved.kind
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
    /// And the words for the small cabin, which includes the smallest of all.
    ///
    /// A chair on a lift is filed as `SL` and is drawn as a gondola, because
    /// what it is on this map is the same thing at the same size: a little body
    /// hanging off a rope, a great many of them, one behind another. It is much
    /// further from the eighty-seat car than it is from the six-seat pod.
    private static let saysGondola: Set<String> = [
        "gondelbahn", "gondola", "gondelb", "telecabine", "cabinovia",
        "sesselbahn", "sessellift", "telesiege", "seggiovia",
    ]

    /// At or under this, the cabins are running one behind another, in seconds.
    ///
    /// **Measured, and the gap it sits in is enormous.** Over a two-hour window
    /// of the national timetable, every aerial line in the country falls into
    /// one of two groups and there is nothing between them: the continuous ones
    /// run at a median headway of **one minute or less** — Flims Foppa, Kriens–
    /// Fräkmüntegg, Grindelwald–Männlichen, the Eiger Express, Marbachegg,
    /// Sörenberg–Rossweid, Mägisalp–Planplatten, Wildhaus, Chur–Brambrüesch —
    /// and the shuttles run at **five minutes or more**, nearly all of them at
    /// fifteen or twenty. Three minutes is the middle of a gap with a factor of
    /// five in it, so the threshold is not a tuning knob; anything from two to
    /// four would separate the same lines.
    static let gondolaHeadway: TimeInterval = 180

    /// How many departures it takes before a headway means anything.
    ///
    /// Two runs is one gap and one gap is not a rate: a line whose window
    /// happens to catch its two hourly departures forty seconds apart is not a
    /// gondola. Three runs is two gaps and a median of them.
    static let headwayNeedsRuns = 3

    /// Every departure time on each cable line *and direction*, from the drawn
    /// set, rebuilt when that set changes.
    ///
    /// Per direction, because the two halves of a shuttle leave their two ends
    /// on the same clock: pooled, an hourly Luftseilbahn reads as a
    /// half-hourly one, and on a line where the two ends are timetabled
    /// together it reads as a service running every few seconds.
    private var cableRuns: [String: [Int]] = [:]
    private var cableRunsFor = -1
    /// Lines whose kind was settled by a guess rather than by a measurement.
    /// See `cableKind(of:)`.
    private var unsettledCable: Set<String> = []

    private func cableRunTimes() -> [String: [Int]] {
        guard cableRunsFor != journeys.count else { return cableRuns }
        // A different set of journeys is a different set of departures, so
        // anything that could not be measured against the last one is given
        // back its chance against this one.
        for key in unsettledCable { cableKinds.removeValue(forKey: key) }
        unsettledCable.removeAll(keepingCapacity: true)
        var out: [String: [Int]] = [:]
        for journey in journeys.values where journey.mode == .cable {
            guard let first = journey.stops.first else { continue }
            out[Self.runKey(journey), default: []].append(first.dep)
        }
        cableRuns = out
        cableRunsFor = journeys.count
        return out
    }

    private static func runKey(_ journey: Journey) -> String {
        "\(journey.operatorName ?? "")|\(journey.line)|\(journey.stops.first?.name ?? "")"
    }

    /// The median gap between departures on this line and in this direction, in
    /// seconds, or nil where too few of them are in the window to say.
    ///
    /// The median rather than the mean, and that is what makes it robust on the
    /// only irregularity these lines have: a continuous gondola pauses over
    /// lunch and at the ends of the day, and one thirty-minute hole in a run of
    /// sixty-second gaps would pull an average clean across the threshold.
    private func headway(of journey: Journey) -> TimeInterval? {
        let times = cableRunTimes()[Self.runKey(journey)] ?? []
        guard times.count >= Self.headwayNeedsRuns else { return nil }
        let sorted = times.sorted()
        var gaps: [TimeInterval] = []
        gaps.reserveCapacity(sorted.count - 1)
        for i in 1..<sorted.count { gaps.append(TimeInterval(sorted[i] - sorted[i - 1])) }
        return gaps.sorted()[gaps.count / 2]
    }

    /// `settled` is false only where the answer is the fallback and the window
    /// held too little of the line to do better. See `cableKind(of:)`.
    private func resolveCable(
        _ journey: Journey
    ) -> (kind: LayoutLibrary.CableKind, settled: Bool) {
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
        if !said.isDisjoint(with: Self.saysFunicular) { return (.funicular, true) }

        guard journey.stops.count >= 2 else { return (.funicular, true) }

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
                return (.funicular, true)
            }
        }

        // Nothing under it, so it hangs — but only if it is long enough to be a
        // ropeway at all. See `shortestRopeway`.
        let span = Geo.length(of: journey.stops.map(\.coord))
        guard span >= Self.shortestRopeway else { return (.funicular, true) }

        // It hangs. Which of the two things that hang it is comes down to how
        // many of them there are, and the timetable says so outright.
        //
        // The name first, where there is one — `Gondelbahn`, `télécabine`,
        // `Sesselbahn` — because a service that states what it is should be
        // believed ahead of a measurement about it. But the names cannot be
        // relied on: `Hasliberg Reuti (Gondelbahn)` and `Meiringen
        // (Luftseilbahn)` are the two ends of *one* line, and they disagree.
        if !said.isDisjoint(with: Self.saysGondola) { return (.gondola, true) }

        // Then the rate, which is the honest distinction between the two
        // machines and not a proxy for it. A gondola is a loop of rope with the
        // cabins clamped onto it all the way round, so they arrive one behind
        // another for as long as the line is open; an aerial tramway is one or
        // two cars shuttling back and forth on a fixed rope, and every trip has
        // to wait for the last one to come back. One minute against fifteen.
        // See `gondolaHeadway`.
        if let gap = headway(of: journey) {
            return (gap <= Self.gondolaHeadway ? .gondola : .tramway, true)
        }

        // And the big car when nothing says otherwise. That default is the
        // right way round for this country's *timetabled* ropeways: the public
        // network is mostly village Luftseilbahnen — Unterbäch, Eischoll,
        // Jeizinen, Gspon, Isérables — carrying one car apiece.
        return (.tramway, false)
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
    func callers(matchingAnyOf keys: some Sequence<String>) -> [Journey] {
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
    /// `thinTheHidden`. `including` outranks it: the one vehicle the reader has
    /// opened is drawn whatever its mode.
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
        let candidates = spatialCandidates(
            in: padded, at: moment, including: extraId
        )
        for journey in candidates {
            guard !journey.cancelled else { continue }
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
            // it: the caller used to drop these from the answer and this is
            // the same rule moved to where it costs one comparison against a
            // value already in hand instead of a position, a place in the
            // thinning and a snapshot. On a map showing trains only it clears
            // four fifths of the country before the clock test has to look at
            // it.
            //
            // `extraId` is the one exception, and it has to be. The filter
            // answers *which of the fleet do I want to see*, and it cannot
            // also answer the vehicle the reader has opened and is following:
            // a bus opened from a board while buses are switched off left the
            // panel tracking it, the camera chasing it and nothing under
            // either. One vehicle is not the mode.
            if hidden, journey.id != extraId, hiding.contains(journey.mode) { continue }
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
                line: Journey.badgeLine(journey.line, extra: journey.extra, mode: journey.mode),
                operatorName: journey.operatorName,
                operatorFull: journey.operatorFull,
                to: Journey.reachedDestination(journey), from: journey.from,
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
    /// zoom the background queue means they arrive a few per frame, so they
    /// glide one after another for a second or two and then settle
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

    /// Restore cached geometry immediately and queue at most one cold build for
    /// this presentation query. Trains keep priority because a rail chord can
    /// cross a lake; road vehicles are queued only while that error is visible.
    /// The cold matcher never runs on this actor, so its long tail cannot become
    /// the frame time.
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

        // One new request per frame, in the order a reader would spend it:
        // corridors before platform bends, trains before everything else.
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
        // Trains walk past the width gate. A bus on the chord is on the road it
        // is already on; a train on the chord is across the lake the rails went
        // around, and a pixel-wide train in a lake is still in a lake.
        for i in drawn.indices where drawn[i].journey.mode == .train {
            if !attachCorridor(&drawn, at: i, now: now) { return }
        }
        if !coarse {
            for i in drawn.indices where drawn[i].journey.mode != .train {
                if !attachCorridor(&drawn, at: i, now: now) { return }
            }
        }

        // And the graph half — the platform bend and the run-up — which is
        // worth a few metres rather than a few hundred, and so is queued after
        // the corridor work that fixes the larger error.
        for i in drawn.indices where drawn[i].journey.mode == .train {
            if !alignDrawn(&drawn, at: i, now: now) { return }
        }
        guard !coarse else { return }
        for i in drawn.indices where drawn[i].journey.mode != .train {
            if !alignDrawn(&drawn, at: i, now: now) { return }
        }
    }

    /// Put one vehicle on its cached corridor, or queue its cold build.
    private func attachCorridor(
        _ drawn: inout [(journey: Journey, position: VehiclePosition)],
        at i: Int, now: Double
    ) -> Bool {
        if drawn[i].journey.geometry != nil { return true }
        if !restoreGeometry(to: drawn[i].journey, refined: false) {
            // One cold request per presentation query. Cached paths still land
            // synchronously, but an unbounded relation match never owns the
            // Fleet actor (and therefore never owns the frame) again.
            if enqueueGeometryBuild(
                for: drawn[i].journey, refined: false, urgent: true
            ).newlyEnqueued {
                return false
            }
            return true
        }
        if let aligned = Positioning.position(of: drawn[i].journey, at: now) {
            drawn[i].position = aligned
        }
        return true
    }

    /// Restore a refined path or queue it, retaining the corridor until the
    /// replacement is ready.
    private func alignDrawn(
        _ drawn: inout [(journey: Journey, position: VehiclePosition)],
        at i: Int, now: Double
    ) -> Bool {
        if let geometry = drawn[i].journey.geometry, geometry.refined { return true }
        if !restoreGeometry(to: drawn[i].journey, refined: true) {
            if enqueueGeometryBuild(
                for: drawn[i].journey, refined: true, urgent: true
            ).newlyEnqueued {
                return false
            }
            return true
        }

        // Read the position again rather than leaving the chord to be drawn
        // for one more frame. The jump onto the track is the thing being
        // removed here, and making it a frame later is still making it.
        if let aligned = Positioning.position(of: drawn[i].journey, at: now) {
            drawn[i].position = aligned
        }
        return true
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
        guard !geometryBackgroundSuspended else { return }
        let moment = Double(now)
        let fleet = fleetByID()
        let trains = activeJourneys(in: fleet, at: moment).filter { $0.mode == .train }
        let yieldEvery = max(1, batch)
        var done = 0
        var passTokens = Set<UInt64>()
        for journey in trains {
            if Task.isCancelled { return }
            guard !restoreGeometry(to: journey, refined: false) else { continue }
            guard Positioning.position(of: journey, at: moment) != nil else { continue }

            enqueue: while true {
                if Task.isCancelled || geometryBackgroundSuspended { return }
                // A visible request may have completed this journey while the
                // warm pass was waiting for capacity.
                if restoreGeometry(to: journey, refined: false) { break enqueue }
                let result = enqueueGeometryBuild(for: journey, refined: false, urgent: false)
                if let token = result.token {
                    passTokens.insert(token)
                    break enqueue
                }
                switch result {
                case .full:
                    guard await waitForGeometryQueueCapacity() else { return }
                case .suspended:
                    return
                case .invalid:
                    break enqueue
                case .enqueued, .pending:
                    break enqueue // handled by `token` above
                }
            }
            done += 1
            if done % yieldEvery == 0 { await Task.yield() }
        }
        // Wait only for the concrete requests this pass admitted or joined.
        // Refined viewport work queued later has different tokens and cannot
        // extend a national warm which has already done its share.
        await waitForGeometryBuilds(passTokens)
    }

    /// Refine the paths of everything in view, a few at a time, off the frame.
    ///
    /// This is the fix for a vehicle that jumps when it is tapped.
    ///
    /// A tap goes through `journey(id:at:)`, which attaches *refined* geometry
    /// — legs bent onto platform rails, gaps filled from the routing graph.
    /// The draw loop queues only a little refining at a time and a busy viewport
    /// holds more than a thousand vehicles, so most of them are drawn on the
    /// corridor path first. The
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
        guard !geometryBackgroundSuspended,
              bbox.east - bbox.west <= Self.refineWidestSpan
        else { return false }
        let moment = Double(now)
        let padded = bbox.padded(by: 0.15)
        let midLon = (bbox.west + bbox.east) / 2
        let midLat = (bbox.south + bbox.north) / 2

        var pending: [(journey: Journey, from: Double)] = []
        for journey in spatialCandidates(in: padded, at: moment) {
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

        let limit = max(1, min(batch, cap))
        var considered = 0
        var passTokens = Set<UInt64>()
        for entry in pending {
            if Task.isCancelled { return true }
            if restoreGeometry(to: entry.journey, refined: true) {
                considered += 1
            } else {
                let result = enqueueGeometryBuild(
                    for: entry.journey, refined: true, urgent: false
                )
                if let token = result.token {
                    passTokens.insert(token)
                    considered += 1
                } else if case .full = result {
                    // A queue transition is the useful next event. Waiting for
                    // it keeps the caller from spinning while still telling it
                    // truthfully that this viewport has unfinished geometry.
                    if passTokens.isEmpty {
                        guard await waitForGeometryQueueCapacity() else { return false }
                    }
                    break
                } else if case .suspended = result {
                    return false
                }
            }
            if considered >= limit { break }
        }

        // Returning before the admitted requests complete would make `true`
        // drive a tight caller loop over work which had not changed yet. The
        // token wait suspends without a timer and ignores unrelated requests.
        await waitForGeometryBuilds(passTokens)
        if Task.isCancelled { return true }
        guard !geometryBackgroundSuspended else { return false }
        return pending.contains { $0.journey.geometry?.refined != true }
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

    /// Visible vehicles eligible for a live timing refresh, nearest the middle
    /// first, excluding references the caller has checked recently.
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
    /// A monitored run can still have stale predictions. Only the caller's
    /// expiring hold excludes a run, and it is applied before the result limit
    /// so fresh answers cannot crowd out trains still waiting for a check.
    ///
    /// Skipped when the map is further out than the error can be seen from, and
    /// this gate is much tighter than the one `refineDrawn` uses. A refinement
    /// costs a graph search; this costs a request against a budget of fifty a
    /// minute shared with every panel the reader opens, so it is spent only
    /// where the reader is close enough to be picking a vehicle out.
    public func awaitingLiveTiming(
        in bbox: BBox, at now: Timestamp, limit: Int = 8,
        excludingJourneyRefs recentlyAsked: Set<String> = []
    ) -> [LiveTimingCandidate] {
        guard bbox.east - bbox.west <= Self.liveTimingWidestSpan else { return [] }
        let moment = Double(now)
        let padded = bbox.padded(by: 0.15)
        let midLon = (bbox.west + bbox.east) / 2
        let midLat = (bbox.south + bbox.north) / 2

        var pending: [(candidate: LiveTimingCandidate, from: Double)] = []
        for journey in spatialCandidates(in: padded, at: moment) {
            // `monitored` records provenance, not freshness. A train remains
            // monitored after its last prediction expires; the caller's timed
            // hold decides when it is worth asking again.
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
                  let handle = journeyRef(for: journey.id),
                  !recentlyAsked.contains(handle.ref)
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
    /// not a build: the draw loop restores it immediately.
    ///
    /// Reachable from the rest of the module rather than private to this file:
    /// `rideCandidates` needs the same paths for the same reason the draw loop
    /// does — a chord cuts corners, and a corner is where a fit is decided.
    @discardableResult
    func attachGeometry(to journey: Journey, refined: Bool = true) -> Bool {
        if restoreGeometry(to: journey, refined: refined) { return false }
        guard journey.stops.count >= 2 else { return false }

        let fingerprint = Self.callFingerprint(journey.stops)
        // The synchronous builder treats any path as complete. Clear a coarse
        // path only here, immediately before replacing it; the asynchronous
        // presentation path keeps drawing that corridor until its refined
        // replacement is ready.
        if refined { journey.geometry = nil }

        builder.attach(to: journey, refined: refined)
        if journey.geometry != nil { noteGeometryChanged() }
        guard let built = journey.geometry else { return true }
        builtGeometry[journey.id] = BuiltGeometry(
            fingerprint: fingerprint, geometry: built,
            fromRoute: journey.legsFromRoute, fromGraph: journey.legsFromGraph,
            usedAt: geometryUse
        )
        evictGeometryIfNeeded()
        return true
    }

    /// Make geometry available for a latency-sensitive module-level query
    /// without letting a cache miss run synchronously on the Fleet actor.
    @discardableResult
    func prepareGeometryInBackground(for journey: Journey, refined: Bool = true) -> Bool {
        if restoreGeometry(to: journey, refined: refined) { return true }
        _ = enqueueGeometryBuild(for: journey, refined: refined, urgent: true)
        return journey.geometry != nil
    }

    /// Install an already-built path, or restore one from the cross-refresh
    /// memo, without starting a route match or graph search.
    private func restoreGeometry(to journey: Journey, refined: Bool) -> Bool {
        if let geometry = journey.geometry {
            if geometry.refined || !refined { return true }
            // Keep the corridor in place while an asynchronous refined build is
            // pending. The synchronous caller clears it immediately before its
            // replacement, so neither path ever exposes a chord in between.
        }
        guard journey.stops.count >= 2 else { return true }

        geometryUse += 1
        let fingerprint = Self.callFingerprint(journey.stops)
        guard var held = memoisedGeometry(for: journey, fingerprint: fingerprint, refined: refined)
        else { return false }

        journey.geometry = held.geometry
        journey.legsFromRoute = held.fromRoute
        journey.legsFromGraph = held.fromGraph
        held.usedAt = geometryUse
        builtGeometry[journey.id] = held
        noteGeometryChanged()
        return true
    }

    /// A path stored under this occurrence's current id or any live alias.
    private func memoisedGeometry(
        for journey: Journey, fingerprint: Int, refined: Bool
    ) -> BuiltGeometry? {
        var keys = runs.allAliases(of: journey.id)
        keys.insert(journey.id)
        if let ref = journey.journeyRef { keys.insert(ref) }
        for part in journey.parts ?? [] {
            keys.insert(part.id)
            if let ref = part.journeyRef { keys.insert(ref) }
        }
        for key in keys {
            guard let held = builtGeometry[key], held.fingerprint == fingerprint,
                  held.geometry.refined || !refined
            else { continue }
            return held
        }
        return nil
    }

    /// Queue one cold build without letting it run on the Fleet actor.
    @discardableResult
    private func enqueueGeometryBuild(
        for journey: Journey, refined: Bool, urgent: Bool
    ) -> GeometryEnqueueResult {
        guard !geometryBackgroundSuspended else { return .suspended }
        guard journey.stops.count >= 2 else { return .invalid }
        let fingerprint = Self.callFingerprint(journey.stops)
        let key = GeometryBuildKey(id: journey.id, fingerprint: fingerprint, refined: refined)
        let corridor = GeometryBuildKey(id: journey.id, fingerprint: fingerprint, refined: false)
        if let token = queuedGeometryBuilds[key] {
            if urgent { promoteGeometryRequest(token: token) }
            return .pending(token)
        }
        // Let the cheap corridor land before asking the same worker for its
        // refined replacement. The waiter follows this concrete token and can
        // retry as soon as the corridor has completed.
        if refined, let token = queuedGeometryBuilds[corridor] {
            if urgent { promoteGeometryRequest(token: token) }
            return .pending(token)
        }

        // Bound both admission and execution priority. Four visible requests
        // are enough to keep the single worker busy; allowing the whole queue
        // to become urgent would leave no slot through which a warm/refinement
        // request could ever make the fairness rule below take effect.
        if urgent,
           geometryBuildQueue.lazy.filter({ $0.urgent }).count >= Self.geometryUrgentBurst {
            return .full
        }

        if geometryBuildQueue.count >= Self.geometryQueueLimit {
            // Presentation work may replace an old speculative request, never
            // another visible one. Requests are tokens, so the displaced warm
            // or refinement pass wakes without becoming coupled to this new job.
            guard urgent,
                  let stale = geometryBuildQueue.firstIndex(where: { !$0.urgent })
            else { return .full }
            let displaced = geometryBuildQueue.remove(at: stale)
            _ = finishGeometryRequest(displaced)
        }

        geometryBuildToken &+= 1
        let token = geometryBuildToken
        let request = GeometryBuildRequest(
            key: key, draft: Self.geometryDraft(from: journey),
            token: token, urgent: urgent
        )
        queuedGeometryBuilds[key] = token
        // FIFO within each priority. `nextGeometryBuild` supplies bounded
        // priority rather than LIFO insertion starving an older visible path.
        geometryBuildQueue.append(request)
        startGeometryWorkerIfNeeded()
        return .enqueued(token)
    }

    /// A speculative request already serving the visible frame is visible work
    /// from this point on. Promotion also keeps a later power-state purge from
    /// discarding the request the frame just adopted.
    private func promoteGeometryRequest(token: UInt64) {
        guard let index = geometryBuildQueue.firstIndex(where: { $0.token == token }) else { return }
        geometryBuildQueue[index].urgent = true
    }

    /// A private journey the utility worker may mutate without racing the live
    /// fleet. Only its immutable geometry result crosses back into the actor.
    private static func geometryDraft(from journey: Journey) -> Journey {
        Journey(
            id: journey.id, mode: journey.mode, category: journey.category,
            line: journey.line, number: journey.number,
            operatorName: journey.operatorName, operatorFull: journey.operatorFull,
            to: journey.to, from: journey.from, delay: journey.delay,
            start: journey.start, end: journey.end, complete: journey.complete,
            monitored: journey.monitored, cancelled: journey.cancelled,
            source: journey.source, stops: journey.stops, parts: journey.parts,
            extra: journey.extra, journeyRef: journey.journeyRef
        )
    }

    private func startGeometryWorkerIfNeeded() {
        guard !geometryBackgroundSuspended,
              geometryWorker == nil, !geometryBuildQueue.isEmpty
        else { return }
        geometryWorkerGeneration &+= 1
        let generation = geometryWorkerGeneration
        // A separate builder keeps its switches and scratch state away from the
        // actor's synchronous diagnostic paths. RelationStore and RailNet own
        // their shared caches behind locks.
        let workerBuilder = GeometryBuilder(relations: relations, railnet: railnet)
        geometryWorker = Task.detached(priority: .utility) { [weak self, workerBuilder] in
            while !Task.isCancelled {
                guard let request = await self?.nextGeometryBuild(for: generation) else { break }
                workerBuilder.attach(to: request.draft, refined: request.key.refined)
                await self?.installGeometryBuild(request, generation: generation)
            }
            await self?.geometryWorkerFinished(generation: generation)
        }
    }

    private func nextGeometryBuild(for generation: Int) -> GeometryBuildRequest? {
        guard !Task.isCancelled, !geometryBackgroundSuspended,
              generation == geometryWorkerGeneration
        else { return nil }
        guard !geometryBuildQueue.isEmpty else {
            consecutiveUrgentGeometryBuilds = 0
            return nil
        }

        let index: Int
        if consecutiveUrgentGeometryBuilds >= Self.geometryUrgentBurst,
           let speculative = geometryBuildQueue.firstIndex(where: { !$0.urgent }) {
            index = speculative
        } else if let urgent = geometryBuildQueue.firstIndex(where: { $0.urgent }) {
            index = urgent
        } else {
            index = 0
        }
        let request = geometryBuildQueue.remove(at: index)
        if request.urgent { consecutiveUrgentGeometryBuilds += 1 }
        else { consecutiveUrgentGeometryBuilds = 0 }
        // Capacity became available when the request left the waiting queue;
        // its token remains active until the synchronous build finishes.
        signalGeometryChange()
        return request
    }

    private func installGeometryBuild(_ request: GeometryBuildRequest, generation: Int) {
        let wasActive = finishGeometryRequest(request)
        guard wasActive, !geometryBackgroundSuspended,
              generation == geometryWorkerGeneration,
              let built = request.draft.geometry
        else { return }

        geometryUse += 1
        builtGeometry[request.key.id] = BuiltGeometry(
            fingerprint: request.key.fingerprint, geometry: built,
            fromRoute: request.draft.legsFromRoute,
            fromGraph: request.draft.legsFromGraph, usedAt: geometryUse
        )
        evictGeometryIfNeeded()

        // Install into every retained instance of this run. A departure board
        // can hold a journey outside the map's live window, so it is not
        // necessarily present in `fleetByID`; discarding that worker result is
        // what previously left scheduled-service pages with only stop chords.
        func install(into journey: Journey) {
            guard Self.callFingerprint(journey.stops) == request.key.fingerprint else { return }
            // A slower corridor job must never replace a refined result that
            // arrived while it was running.
            if let current = journey.geometry, current.refined && !built.refined { return }
            journey.geometry = built
            journey.legsFromRoute = request.draft.legsFromRoute
            journey.legsFromGraph = request.draft.legsFromGraph
            noteGeometryChanged()
        }

        _ = fleetByID()
        if let live = chainedVehicle(forID: request.key.id) {
            install(into: live)
        }
        let aliases = runs.allAliases(of: request.key.id)
        for (key, listed) in boardJourneys where aliases.contains(key.id) {
            install(into: listed)
        }
    }

    /// Remove exactly this incarnation of a request. A cancelled worker may
    /// finish after a resumed pass has queued the same key with a new token.
    @discardableResult
    private func finishGeometryRequest(_ request: GeometryBuildRequest) -> Bool {
        guard queuedGeometryBuilds[request.key] == request.token else { return false }
        queuedGeometryBuilds.removeValue(forKey: request.key)
        signalGeometryChange()
        return true
    }

    private func geometryWorkerFinished(generation: Int) {
        guard generation == geometryWorkerGeneration else { return }
        // This is the only place the handle is cleared. Cancellation can leave
        // a worker inside synchronous route matching, and retaining the handle
        // until this acknowledgement is what prevents an overlapping worker.
        geometryWorker = nil
        signalGeometryChange()
        startGeometryWorkerIfNeeded()
    }

    private func waitForGeometryQueueCapacity() async -> Bool {
        while !Task.isCancelled {
            guard !geometryBackgroundSuspended else { return false }
            if geometryBuildQueue.count < Self.geometryQueueLimit { return true }
            let revision = geometryChangeRevision
            await waitForGeometryChange(after: revision)
        }
        return false
    }

    private func waitForGeometryBuilds(_ tokens: Set<UInt64>) async {
        guard !tokens.isEmpty else { return }
        while !Task.isCancelled, !geometryBackgroundSuspended {
            let active = queuedGeometryBuilds.values.contains { tokens.contains($0) }
            guard active else { return }
            let revision = geometryChangeRevision
            await waitForGeometryChange(after: revision)
        }
    }

    private func waitForGeometryChange(after revision: UInt64) async {
        guard !Task.isCancelled, revision == geometryChangeRevision else { return }
        geometryChangeWaiterID &+= 1
        let id = geometryChangeWaiterID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, revision == geometryChangeRevision else {
                    continuation.resume()
                    return
                }
                geometryChangeWaiters[id] = continuation
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelGeometryChangeWaiter(id) }
        }
    }

    private func cancelGeometryChangeWaiter(_ id: UInt64) {
        geometryChangeWaiters.removeValue(forKey: id)?.resume()
    }

    private func signalGeometryChange() {
        geometryChangeRevision &+= 1
        let waiters = Array(geometryChangeWaiters.values)
        geometryChangeWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    /// Drop work which exists only to warm or refine a future frame.
    ///
    /// Visible requests remain queued, and a speculative request already inside
    /// the synchronous matcher is allowed to finish: it cannot be interrupted
    /// safely, and retaining its token lets its useful result install normally.
    /// Removing the waiting tokens wakes only the warm/refinement passes which
    /// owned them; they observe their caller's cancellation or power state and
    /// stop without holding the queue open.
    public func cancelSpeculativeGeometry() {
        let removed = geometryBuildQueue.filter { !$0.urgent }
        guard !removed.isEmpty else { return }
        geometryBuildQueue.removeAll { !$0.urgent }
        for request in removed where queuedGeometryBuilds[request.key] == request.token {
            queuedGeometryBuilds.removeValue(forKey: request.key)
        }
        signalGeometryChange()
    }

    /// Stop accepting background geometry and invalidate everything queued.
    /// A build already inside the synchronous matcher finishes on its utility
    /// thread, but its token is gone and the worker handle remains occupied, so
    /// it can neither install nor overlap a replacement after resume.
    public func cancelBackgroundGeometry() {
        geometryBackgroundSuspended = true
        geometryWorker?.cancel()
        geometryBuildQueue.removeAll(keepingCapacity: true)
        queuedGeometryBuilds.removeAll(keepingCapacity: true)
        consecutiveUrgentGeometryBuilds = 0
        signalGeometryChange()
    }

    /// Allow presentation and warm requests again after the app becomes active.
    /// If a cancelled synchronous build is still draining, requests may queue
    /// but the next worker starts only after that build acknowledges completion.
    public func resumeBackgroundGeometry() {
        guard geometryBackgroundSuspended else {
            startGeometryWorkerIfNeeded()
            return
        }
        geometryBackgroundSuspended = false
        signalGeometryChange()
        startGeometryWorkerIfNeeded()
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
        let didok = StopRegister.didok(forSloid: placeId) ?? placeId
        if let asked = mirrorAsked[didok], Date().timeIntervalSince(asked) < Self.mirrorTTL {
            return false
        }
        mirrorAsked[didok] = Date()

        let found = await mirror.board(didok: didok, at: now)
        guard !found.isEmpty else { return false }
        ingestBoardFill(found)
        return true
    }

    public func overlayRoutes(_ routes: [OSMFetchedRoute]) {
        relations.overlay(routes)
    }

    func boardFillJourneys() -> [Journey] { runs.boardValues }

    /// Merge OJP stop-event workings into the board fill, locating each call.
    ///
    /// These win over a packed trip with the same journey reference because
    /// they still have the Italian or German tail the Swiss file dropped.
    public func ingestBoardFill(_ journeys: [Journey]) {
        for journey in journeys {
            let filled = journey
            let located = journey.stops.map(locateBoardCall)
            filled.stops = located
            if let name = operators.name(for: filled.operatorName) {
                filled.operatorFull = operators.fullName(for: filled.operatorName)
                filled.operatorName = name
            }
            filled.from = located.first?.name ?? filled.from
            filled.to = filled.to.map(StopNaming.display)
            // Resolve against the printed occurrence before admitting a new
            // record. This also works for tomorrow's board, outside the map's
            // small active window, and when the live answer arrives first.
            if let first = filled.stops.first, let ref = first.ref, let timetable {
                let booked = first.sched ?? first.dep
                let candidates = timetable.journeys(
                    callingAt: [StopRegister.stationOf(ref)],
                    from: booked - 30, to: booked + 30, limit: 500,
                    place: { [register] ref in register.lookup(ref) },
                    operatorName: { [operators] agency in operators.name(for: agency) }
                ).filter { RunStore.matches($0, filled) }
                if candidates.count == 1, let planned = candidates.first {
                    // Retain an already-observed map object when it is this
                    // occurrence; otherwise use the freshly expanded plan.
                    let active = self.journeys[planned.id]
                    runs.ingest(active.map { RunStore.matches($0, planned) ? $0 : planned } ?? planned)
                }
            }
            let canonical = runs.ingest(filled, supplemental: true)
            if filled.source == "ojp" { applyBoardTimingToMap(canonical) }
        }
    }

    /// OJP may name a bus with a UUID while the timetable names the same
    /// working SKI-1054. Match its operator, course and booked calls before
    /// updating the map copy; opening that vehicle must not show old times.
    private func applyBoardTimingToMap(_ live: Journey) {
        let timing = JourneyTiming(liveBoardJourney: live)
        guard !timing.isEmpty else { return }
        var matches = Set<String>()
        for (index, call) in live.stops.enumerated() {
            guard let ref = call.ref else { continue }
            let identity = BoardRunIdentity(journey: live, at: index)
            for candidate in callers(matchingAnyOf: [StopRegister.stationOf(ref)]) {
                guard candidate.mode == live.mode else { continue }
                for i in candidate.stops.indices {
                    let booked = candidate.stops[i]
                    guard StopRegister.stationOf(booked.ref) == identity.station,
                          abs((booked.sched ?? booked.dep) - identity.scheduledDeparture) <= 30 else { continue }
                    guard identity.matches(BoardRunIdentity(journey: candidate, at: i)) else { continue }
                    let part = candidate.parts?.last { $0.start <= i && i <= $0.end }
                    matches.insert(part?.id ?? candidate.id)
                }
            }
            if !matches.isEmpty { break }
        }
        guard matches.count == 1, let id = matches.first else { return }
        _ = applyTiming(timing, to: id)
    }

    private func locateBoardCall(_ call: Call) -> Call {
        var call = call
        call.name = StopNaming.display(call.name)
        guard let ref = call.ref, let place = register.lookup(ref, name: call.name) else {
            return call
        }
        if call.lat == 0, call.lon == 0 {
            call.lat = place.lat
            call.lon = place.lon
            call.precise = place.precise
        }
        if call.name.isEmpty || call.name == ref {
            call.name = StopNaming.display(place.name)
        }
        return call
    }

    /// The fleet as the feed filed it, before chaining or geometry.
    ///
    /// This is what the cache holds, so writing one is the same call the app
    /// makes after a refresh.
    public func everyRawJourney() -> [Journey] { Array(journeys.values) }

    /// Query only on opening a cable card. The nearby six-hour timetable
    /// window includes sparse shuttles without using the map's thinned dots
    /// as a count of departures or adding network requests.
    public func cableService(for vehicle: VehicleSnapshot, at moment: Timestamp) -> CableService.Summary {
        guard vehicle.mode == .cable else {
            return CableService.summarize(vehicle, journeys: [])
        }
        let stations = Set(vehicle.stops.compactMap(\.ref).map { StopRegister.stationOf($0) })
        let scheduled = timetable?.journeys(
            callingAt: stations, from: moment - 3 * 3600, to: moment + 3 * 3600,
            limit: 10_000,
            place: { [register] ref in register.lookup(ref) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        ) ?? []
        let source = scheduled.isEmpty ? journeys.values.filter {
            $0.mode == .cable && abs(($0.stops.first?.dep ?? 0) - moment) <= 3 * 3600
        } : scheduled
        return CableService.summarize(vehicle, journeys: source)
    }

    /// Cableway infrastructure scheduled anywhere in a view on this service
    /// day, whether or not a cabin is running at the selected moment.
    ///
    /// Vehicle queries intentionally discard journeys that are not alive at
    /// `now`; a station and its rope are not vehicles and must not inherit that
    /// lifetime. The packed timetable is therefore asked for the whole service
    /// day, clipped to the view and filtered to cable mode before any Journey
    /// objects are built. Live runs are merged over this plan by the map, where
    /// their attached geometry can improve the timetable's stop-to-stop chord.
    public func cablewayPlan(in region: BBox, at moment: Date) -> Cableway.Plan {
        let zone = TimeZone(identifier: "Europe/Zurich") ?? .current
        guard let timetable, timetable.isReady,
              let day = TimetableStore.dayStart(moment, zone: zone)
        else { return Cableway.Plan() }

        let scheduled = timetable.journeys(
            from: day,
            // GTFS permits departures after 24:00. Thirty hours covers the
            // complete service day without pulling in the following daytime.
            to: day + 30 * 3600,
            zone: zone,
            limit: 10_000,
            modes: [.cable],
            uniquePatterns: true,
            in: region,
            place: { [register] ref in register.lookup(ref) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        )
        let runs = scheduled.compactMap { journey -> VehicleSnapshot? in
            guard let first = journey.stops.first else { return nil }
            return VehicleSnapshot(
                id: journey.id, mode: journey.mode, category: journey.category,
                cable: cableKind(of: journey),
                line: Journey.badgeLine(journey.line, extra: journey.extra, mode: journey.mode),
                operatorName: journey.operatorName, operatorFull: journey.operatorFull,
                to: Journey.reachedDestination(journey), from: journey.from,
                lon: first.lon, lat: first.lat, stops: journey.stops,
                geometry: journey.geometry, journeyRef: journey.journeyRef
            )
        }
        return Cableway.plan(for: runs)
    }

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
                line: Journey.badgeLine(journey.line, extra: journey.extra, mode: journey.mode),
                operatorName: journey.operatorName,
                operatorFull: journey.operatorFull, to: Journey.reachedDestination(journey), from: journey.from,
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
    /// The drawn vehicle a journey id names, whichever of its names was used.
    ///
    /// **Three ways to name one vehicle, and only one of them used to work.** A
    /// chained working — an S1 renumbered at Gümligen, a train that changes
    /// number en route — is one vehicle on the map and two or three trips in
    /// the file. `Chains.build` folds them into a single journey under the
    /// *first* leg's id, so the later legs' ids are keys of nothing: they are
    /// in `chainOf`, which is built for exactly this and was being consulted by
    /// nothing that answers a tap.
    ///
    /// What that looked like is the bug it was found as. A departure board
    /// lists a run by whatever id the timetable filed it under, so a row for a
    /// later leg handed back an id the fleet could not resolve; the panel asked
    /// for it, got nil, and sat on the spinner it shows while a vehicle is
    /// being fetched — for ever, because nothing was ever going to arrive.
    private func drawnJourney(_ id: String, at moment: Timestamp? = nil) -> Journey? {
        // `fleetByID()` first and not merely for its answer: it is what builds
        // `chainOf`, so the fallback below has nothing to read until it has run.
        _ = fleetByID()
        if let vehicle = chainedVehicle(forID: id) { return vehicle }
        guard let run = runs.journey(id: id, at: moment) else { return nil }
        return fleetVehicle(matching: run) ?? run
    }

    /// The map vehicle for this operating run, if the fleet is already drawing it.
    ///
    /// A live alias is a different public id of the same occurrence. Resolving
    /// the map object through `RunStore` used to *replace* it with that alias,
    /// which dropped chained parts and the path already drawn for the tap.
    private func fleetVehicle(matching run: Journey) -> Journey? {
        let fleet = fleetByID()
        var keys = runs.allAliases(of: run.id)
        keys.insert(run.id)
        if let ref = run.journeyRef { keys.insert(ref) }
        for part in run.parts ?? [] {
            keys.insert(part.id)
            if let ref = part.journeyRef { keys.insert(ref) }
        }
        for key in keys {
            if let direct = fleet[key] { return direct }
            if let chain = chainOf[key], let joined = fleet[chain] { return joined }
        }
        return nil
    }

    /// The journey a panel, tap or route request is naming, preferring the
    /// object the map is already drawing.
    private func occurrence(
        id: String, at moment: Timestamp? = nil, boardDeparture: Timestamp? = nil
    ) -> Journey? {
        if let boardDeparture, let listed = boardJourneys[BoardJourneyKey(id: id, departure: boardDeparture)] {
            // `RunStore` ingested the packed numbered leg. Resolving the
            // through-working against it used to replace Bern→Brig with the
            // five-stop Spiez shuttle the file actually contains.
            if let live = fleetVehicle(matching: listed) {
                return listed.stops.count >= live.stops.count ? listed : live
            }
            let resolved = runs.resolve(listed)
            return listed.stops.count >= resolved.stops.count ? listed : resolved
        }
        return drawnJourney(id, at: moment)
    }

    public func splitContinuation(of id: String, preferredID: String?, at now: Timestamp) -> VehicleSnapshot? {
        guard let source = drawnJourney(id), !source.splitContinuations.isEmpty else { return nil }
        let children = source.splitContinuations.compactMap { drawnJourney($0) }
        guard let next = Chains.continuation(of: source, among: children, preferredID: preferredID, at: now),
              now <= Positioning.standsUntil(next) else { return nil }
        return journey(id: next.id, at: now)
    }

    public func journey(
        id: String, at now: Timestamp, boardDeparture: Timestamp? = nil,
        through: Bool = true
    ) -> VehicleSnapshot? {
        let listed = boardDeparture.flatMap {
            boardJourneys[BoardJourneyKey(id: id, departure: $0)]
        }
        guard let found = occurrence(id: id, at: now, boardDeparture: boardDeparture) else { return nil }
        // Board rows already stitch packed legs; a map tap on the outgoing
        // numbered working must too, or the panel says "from Spiez" for a
        // train that ran from Bern. Offline: packed timetable only.
        // `through: false` is the packed/map object for the first paint of
        // the card; the caller then asks again with the default to join legs.
        let journey = through ? boardWorking(found) : found
        if listed != nil {
            // A future departure is outside the map fleet, but its route is no
            // less real. Restore a cached path immediately or queue the normal
            // relation/rail-graph builder on its utility worker. Never invent a
            // stop-to-stop chord merely because the train has not started yet.
            _ = prepareGeometryInBackground(for: journey, refined: true)
        }
        // `refined: false`, and that one word is the whole of the fix for a
        // vehicle that jumped when it was tapped.
        //
        // This used to take the default and upgrade the path — bending legs
        // onto platform rails, filling gaps from the routing graph. The draw
        // loop supplies that asynchronously (`alignToTrack` queues a cold path
        // and a busy viewport holds a thousand vehicles), so the
        // vehicle was on screen at its corridor position and this moved it to
        // its refined one the instant somebody touched it. Measured over a
        // Zurich viewport, 77% of vehicles moved, 41 of them by more than 250 m
        // and the worst by 3.5 km — and a second tap moved it no further,
        // because by then it was refined.
        //
        // Refining is still right and still happens: the draw loop queues it and
        // `refineDrawn` sweeps the viewport in the background.
        // What must not happen is a *reader's tap* being the thing that
        // triggers it, because a tap is the one moment the reader is looking
        // straight at the vehicle. Asking only that the journey have some path
        // — which a drawn vehicle always already does — makes this a read
        // rather than a write, and the panel now opens on the vehicle where the
        // map is drawing it.
        // No attach at all for a live map journey, and that is the point.
        //
        // `refined: false` was not enough: a vehicle the draw loop skipped has
        // no path yet — `alignToTrack` gives up on everything that is not a
        // train once the viewport is crowded — so asking for the cheap attach
        // still *built* one, and building one still moved the vehicle off the
        // chord it was drawn on. The tap has to be a read or it will always
        // move something.
        //
        // So a live panel opens on the journey exactly as the map has it.
        // Whatever geometry it has is what the map drew it with; whatever it
        // lacks, the draw loop and `refineDrawn` supply within a frame or two,
        // and the vehicle moves then — ambiently, not under the reader's finger.
        return snapshot(of: journey, identity: found, at: now)
    }

    /// Panel card for `identity`, with `journey`'s through-working route.
    private func snapshot(of journey: Journey, identity: Journey, at now: Timestamp) -> VehicleSnapshot {
        let position = Positioning.panelPosition(of: identity, at: now)
            ?? Positioning.panelPosition(of: journey, at: now)
        let throughIndex = Positioning.panelPosition(of: journey, at: now)?.index
        return VehicleSnapshot(
            id: identity.id, mode: identity.mode, category: identity.category,
            cable: cableKind(of: identity),
            line: Journey.badgeLine(identity.line, extra: identity.extra, mode: identity.mode),
            operatorName: identity.operatorName,
            operatorFull: identity.operatorFull, to: Journey.reachedDestination(journey), from: journey.from,
            delay: journey.delay,
            lon: position?.lon ?? identity.stops[0].lon,
            lat: position?.lat ?? identity.stops[0].lat,
            bearing: position?.bearing ?? 0, moving: position?.moving ?? false,
            speed: position?.speed ?? 0, index: throughIndex ?? position?.index ?? 0,
            progress: position?.progress ?? 0,
            complete: journey.complete, cancelled: journey.cancelled,
            stops: journey.stops, parts: journey.parts,
            geometry: identity.geometry ?? journey.geometry,
            layover: identity.layover ?? journey.layover, onTrack: position?.onTrack ?? false,
            extra: identity.extra, journeyRef: identity.journeyRef ?? journey.journeyRef
        )
    }

    /// Wait for the real mapped path of a service retained by a departure
    /// board. The synchronous route matcher stays on the utility worker; this
    /// actor only waits for its token and installs the immutable result.
    ///
    /// The service page is already visible while this suspends. Returning nil
    /// leaves the map without a line rather than substituting geometry known to
    /// be false.
    public func boardJourneyGeometry(
        id: String, departure: Timestamp
    ) async -> JourneyGeometry? {
        await journeyGeometry(id: id, boardDeparture: departure)
    }

    /// A selected train gets its route even while waiting at its origin or
    /// outside the viewport. Queue the existing worker rather than routing
    /// synchronously during hit detection or waiting for the train to move.
    public func journeyGeometry(
        id: String, boardDeparture: Timestamp? = nil
    ) async -> JourneyGeometry? {
        guard let journey = occurrence(
            id: id, at: boardDeparture, boardDeparture: boardDeparture
        ) else { return nil }

        while !Task.isCancelled, !geometryBackgroundSuspended {
            if restoreGeometry(to: journey, refined: true) {
                // A cached all-chord path is from an earlier matcher that
                // needed three stops on one relation. Rebuild locally so the
                // Swiss half of an ICE can land on IC 61 before Overpass
                // is asked — and return that without waiting for the network.
                if journey.geometry?.hasUnmappedLeg == true,
                   journey.geometry?.relation == nil {
                    builtGeometry.removeValue(forKey: journey.id)
                    journey.geometry = nil
                    _ = attachGeometry(to: journey, refined: true)
                }
                return journey.geometry
            }
            let result = enqueueGeometryBuild(for: journey, refined: true, urgent: true)
            if let token = result.token {
                await waitForGeometryBuilds([token])
                continue
            }
            switch result {
            case .full:
                guard await waitForGeometryQueueCapacity() else { return nil }
            case .suspended, .invalid:
                return nil
            case .enqueued, .pending:
                // Both carry a token and are handled above.
                return nil
            }
        }
        return nil
    }

    /// Overpass for the hops the packed extract still draws as a chord.
    ///
    /// Separate from `journeyGeometry` so the map can draw the Swiss rails
    /// immediately and splice in the foreign ones when this returns.
    public func refineRemoteRoute(
        id: String, boardDeparture: Timestamp? = nil
    ) async -> JourneyGeometry? {
        guard let journey = occurrence(
            id: id, at: boardDeparture, boardDeparture: boardDeparture
        ) else { return nil }
        _ = restoreGeometry(to: journey, refined: true)
        await fetchRemoteRoute(for: journey)
        return journey.geometry
    }

    /// Ask Overpass for the OSM relation of a run the packed Swiss extract
    /// could not describe. Selecting the vehicle is what makes the download
    /// worth it; the chord stays on the map until a relation actually matches.
    private func fetchRemoteRoute(for journey: Journey) async {
        let ref = RelationStore.normaliseRef(journey.line)
        guard !ref.isEmpty, journey.stops.count >= 2 else { return }
        let key = remoteRouteKey(journey)
        guard !remoteRouteMisses.contains(key) else { return }

        var extra: [String] = []
        if let id = journey.geometry?.relation, let rel = relations.relation(id: id) {
            extra.append(contentsOf: [rel.from, rel.to, rel.name].compactMap { $0 })
        }
        let fetched = await osmRoutes.fetch(
            line: journey.line, mode: journey.mode, stops: journey.stops, extraTokens: extra
        )
        guard !fetched.isEmpty else {
            remoteRouteMisses.insert(key)
            return
        }
        relations.ingest(fetched)
        builtGeometry.removeValue(forKey: journey.id)
        journey.geometry = nil
        _ = attachGeometry(to: journey, refined: true)
        if journey.geometry?.hasUnmappedLeg != false {
            remoteRouteMisses.insert(key)
        }
    }

    private func remoteRouteKey(_ journey: Journey) -> String {
        let ref = RelationStore.normaliseRef(journey.line)
        let bbox = OSMRouteClient.bbox(of: journey.stops)
        let cell = bbox.map { OSMRouteClient.cacheCell($0) } ?? ""
        return "\(journey.mode.rawValue)|\(ref)|\(cell)"
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
        guard let journey = drawnJourney(id) else { return nil }
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
        guard let journey = drawnJourney(id) else { return false }
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
    /// within twenty minutes after the trunk gets there, and the call must be the
    /// working's own origin — which is what a portion that has just been
    /// detached is. Nothing that fails all three is guessed at.
    public func onward(
        from stopName: String, stopUIC: Int? = nil,
        notBefore moment: Timestamp, to destination: String?, destinationUIC: Int? = nil,
        mode: Mode, operatorName: String? = nil, line: String? = nil,
        workings: [TrainFormation.Working] = [], at now: Timestamp
    ) -> VehicleSnapshot? {
        let station = stopUIC.flatMap { StopRegister.sloid(forDidok: String($0)) }
        let target = destinationUIC.flatMap { StopRegister.sloid(forDidok: String($0)) }
        // A half the service named as a working and gave no coach goal for.
        // Then the name is the whole of the evidence and nothing else may
        // stand in for it — see the `explicit` requirement below.
        let named = destination == nil && destinationUIC == nil
        func reachesDestination(_ call: Call) -> Bool {
            if let target { return StopRegister.stationOf(call.ref) == target }
            if let destinationUIC, let ref = call.ref {
                // Foreign UICs have no Swiss SLOID. Compare their actual
                // identity, independent of country suffixes in display names.
                let code = StopRegister.scheduledStopPointCode(ref) ?? ref
                return Int(code) == destinationUIC
            }
            guard let destination else { return false }
            return Self.sameStop(call.name, destination)
        }
        var candidates = Array(fleetByID().values)
        // A branch can start beyond the map's time window or outside its
        // viewport. Ask the packed timetable at the split, independently of
        // which vehicles have been expanded for drawing.
        if let station, let timetable, register.isReady {
            candidates += timetable.journeys(
                callingAt: [station], from: moment - 120, to: moment + 20 * 60,
                limit: 240, place: { [register] in register.lookup($0) },
                operatorName: { [operators] in operators.name(for: $0) }
            )
        }
        // Folded, because a published name is: see `ThroughLink`. A half named
        // by the graph and the same half named by the formation service differ
        // only in the case of the namespace, and an exact compare finds one.
        let ids = Set(workings.compactMap { $0.journeyID?.lowercased() })
        let numbers = Set(workings.compactMap(\.trainNumber))
        var matches: [(journey: Journey, departure: Timestamp, explicit: Bool)] = []
        var seen = Set<String>()
        for journey in candidates {
            guard journey.mode == mode, !journey.cancelled, journey.stops.count >= 2,
                  let last = journey.stops.last else { continue }
            let reachesTarget = reachesDestination(last)
            if let operatorName, journey.operatorName != operatorName { continue }
            let origins = Set([0] + (journey.parts ?? []).map(\.start))
            for index in origins.sorted() where journey.stops.indices.contains(index) {
                let call = journey.stops[index]
                let atSplit = station.map { StopRegister.stationOf(call.ref) == $0 }
                    ?? Self.sameStop(call.name, stopName)
                guard atSplit, !call.cancelled,
                      call.dep >= moment - 120, call.dep <= moment + 20 * 60 else { continue }
                let part = journey.parts?.last { $0.start == index }
                let ref = part?.journeyRef ?? part?.id ?? journey.journeyRef ?? journey.id
                let number = FormationKey(journeyID: ref, operationDate: "")?.trainNumber
                let explicit = ids.contains(ref.lowercased())
                    || ids.contains((part?.id ?? journey.id).lowercased())
                    || (number.map { numbers.contains($0) } ?? false)
                // Coach goals may end before the passenger working does:
                // Bern's RE1 names Brig, while its published child 4277
                // continues through Brig to Domodossola. Use that explicit
                // relationship, but still distinguish it from the other half
                // by requiring the goal on this child's onward route.
                if named {
                    guard explicit else { continue }
                } else {
                    guard reachesTarget || (explicit && journey.stops.dropFirst(index + 1).contains(where: reachesDestination))
                    else { continue }
                }
                // Without a published link, require the same advertised line
                // as well as operator, place, destination, and a short dwell.
                if !explicit, let line, (part?.line ?? journey.line) != line { continue }
                let identity = "\(ref)|\(call.sched ?? call.dep)"
                guard seen.insert(identity).inserted else { continue }
                matches.append((journey, call.dep, explicit))
            }
        }
        matches.sort {
            if $0.explicit != $1.explicit { return $0.explicit }
            return abs($0.departure - moment) < abs($1.departure - moment)
        }
        guard let best = matches.first else { return nil }
        // Equally plausible departures are not evidence for a connection.
        if matches.count > 1, matches[1].explicit == best.explicit,
           abs(abs(matches[1].departure - moment) - abs(best.departure - moment)) < 120 {
            return nil
        }
        // Retain this scheduled working for the panel and its asynchronous
        // route builder, without inserting future trains into the map fleet.
        rememberBoardJourney(best.journey, departure: best.departure)
        // The detached portion, not the through-working: a Burgdorf S44
        // branch is nine stops to Solothurn, even though the trunk ran from
        // Thun. `journey()` would stitch that trunk back on.
        return snapshot(of: best.journey, identity: best.journey, at: now)
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

    /// `Domodossola (I)` and `Domodossola` are one station.
    public static func sameListedStop(_ a: String, _ b: String) -> Bool {
        StopNaming.sameListedStop(a, b)
    }

    /// Destinations as two feeds write them. See `StopNaming.sameBoardDestination`.
    public static func sameBoardDestination(_ a: String, _ b: String) -> Bool {
        StopNaming.sameBoardDestination(a, b)
    }

    public static func localDestination(_ name: String) -> String {
        StopNaming.localDestination(name)
    }

    static func squash(_ name: String) -> String {
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
    /// which are Waisenhausplatz. The comma is normally the separator the Swiss
    /// stop register uses for a stop inside a larger place, so it says what
    /// proximity cannot.
    ///
    /// Some interchanges are filed both ways, though. The Spiez boat landing is
    /// `Spiez Schiffstation` while the bus stop beside it is
    /// `Spiez, Schiffstation`. Those are two identifiers for one place, not two
    /// choices, and comparing letters and digits lets their board contain both
    /// modes without weakening the prefix rule for genuinely different stops.
    static func partOfStation(_ name: String, _ stationName: String) -> Bool {
        sameStop(name, stationName) || name.hasPrefix("\(stationName), ")
            || isGenericStationStop(name, stationName: stationName)
    }

    /// Whether a stop name is merely the generic forecourt name of a station.
    ///
    /// This is intentionally narrower than `partOfStation`: `Bern, Bahnhof`
    /// is the bus side of Bern station, while `Bern, Welle 7` and `Bern,
    /// Schanzenstrasse` are individually useful places and must survive.
    public static func isGenericStationStop(
        _ name: String, stationName: String
    ) -> Bool {
        func folded(_ value: String) -> String {
            value.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "de_CH")
            ).split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let child = folded(name)
        var parent = folded(stationName)
        if child == parent { return true }
        // Main stations can carry the generic suffix on either side of the
        // join: Zürich HB / Zürich, Bahnhof; Bern / Bern, Hauptbahnhof.
        for suffix in [" hauptbahnhof", " hb"] where parent.hasSuffix(suffix) {
            parent.removeLast(suffix.count)
            break
        }
        guard !parent.isEmpty, child.hasPrefix("\(parent) ") else { return false }
        let suffix = String(child.dropFirst(parent.count + 1))
        return ["bahnhof", "hauptbahnhof", "hb", "gare", "station", "stazione", "staziun",
                "gare centrale", "stazione centrale"].contains(suffix)
    }

    /// Whether `candidate` is the whole interchange that contains `place`.
    /// Kept as a pure predicate so the conservative boundary is testable
    /// without loading the national stop register.
    static func isStationParent(_ candidate: StopPlace, of place: StopPlace) -> Bool {
        guard candidate.id != place.id,
              !place.rail || candidate.rail,
              Geo.flatMetres(
                  place.lon, place.lat, candidate.lon, candidate.lat
              ) <= Self.stationSpread
        else { return false }
        if Self.sameStop(place.name, candidate.name) { return true }
        return candidate.rail && Self.isGenericStationStop(
            place.name, stationName: candidate.name
        )
    }

    /// The whole interchange a stop-place row belongs to.
    ///
    /// The national register commonly publishes a railway station and its
    /// forecourt as separate places: `Mülenen` and `Mülenen, Bahnhof`. Opening
    /// the first already gathers the second's buses in `board`; opening the
    /// second used to stay bus-only because the prefix relation is directional.
    /// Resolve that relation once, before any station board is built, so taps,
    /// search, nearby-live and route-stop links all agree on the same place.
    ///
    /// A comma alone is not enough to merge two stops. Prefix children are
    /// folded only into a nearby *railway* parent. Equivalent names such as
    /// `Spiez Schiffstation` and `Spiez, Schiffstation` may merge without one,
    /// because their letters and digits identify the same named place. Kerb
    /// and platform boards never pass through this function, so Stop A/B and
    /// Platform 1/2 remain individually selectable.
    private func canonicalStationPlace(
        _ place: StopPlace, among supplied: [StopPlace]? = nil
    ) -> StopPlace {
        let nearby = supplied ?? stopPlaces.nearby(
            lon: place.lon, lat: place.lat,
            within: Self.stationSpread, limit: 200
        )
        let parents = nearby.filter { Self.isStationParent($0, of: place) }
        return parents.min { a, b in
            if a.rail != b.rail { return a.rail && !b.rail }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            let aDistance = Geo.flatMetres(place.lon, place.lat, a.lon, a.lat)
            let bDistance = Geo.flatMetres(place.lon, place.lat, b.lon, b.lat)
            if aDistance != bDistance { return aDistance < bDistance }
            return a.id < b.id
        } ?? place
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

    public func cityStation(named name: String, near centre: Coord) -> StopPlace? {
        guard centre.lon.isFinite, centre.lat.isFinite,
              abs(centre.lon) <= 180, abs(centre.lat) <= 85 else { return nil }
        let candidates = stopPlaces.nearby(
            lon: centre.lon, lat: centre.lat, within: CityStation.searchRadius, limit: .max
        )
        return CityStation.resolve(named: name, near: centre, among: candidates) { place in
            place.rail || timetable?.isRailwayStation(place.id) == true
        }
    }

    /// `loadingOnly` resolves the canonical place without scanning departures,
    /// expanding timetable journeys or looking up serving routes. Map hit
    /// testing needs only that identity before it can present a card.
    ///
    /// `preview` is the packed timetable for the next couple of hours, without
    /// chaining through-workings or looking up serving routes. The card can
    /// paint that immediately; the full board replaces it when the rest is
    /// ready. Live OJP/mirror rows arrive later still.
    public func stationBoard(
        placeId: String, at now: Timestamp, limit: Int = 60,
        loadingOnly: Bool = false, preview: Bool = false
    ) -> StationBoard? {
        if let place = stopPlaces.place(id: placeId) {
            let station = canonicalStationPlace(place)
            if loadingOnly {
                return .loading(id: station.id, name: station.name,
                                at: Coord(lon: station.lon, lat: station.lat), now: now)
            }
            return board(
                name: station.name, id: station.id, lon: station.lon, lat: station.lat,
                at: now, limit: limit, preview: preview
            )
        }
        // Milano Centrale is a UIC and not a drawn Swiss stop place. The
        // register still names it, and a board is all this needs.
        let didok = StopRegister.didok(forSloid: placeId) ?? placeId
        guard didok.allSatisfy(\.isNumber),
              let place = register.lookup(didok) ?? register.lookup(placeId)
        else { return nil }
        if loadingOnly {
            return .loading(id: didok, name: place.name,
                            at: Coord(lon: place.lon, lat: place.lat), now: now)
        }
        return board(
            name: place.name, id: didok, lon: place.lon, lat: place.lat,
            at: now, limit: limit, preview: preview
        )
    }

    /// Whether the coordinate is close enough to transit to justify a more
    /// precise location fix. This touches only the stop-place grid: it builds no
    /// board, journeys or presentation models.
    public func hasStopPlace(
        near lon: Double, lat: Double, within metres: Double = 500
    ) -> Bool {
        guard metres > 0, stopPlaces.count > 0 else { return false }
        return stopPlaces.nearest(lon: lon, lat: lat, within: metres) != nil
    }

    public func stationBoard(near lon: Double, lat: Double, at now: Timestamp, limit: Int = 60) -> StationBoard? {
        guard let place = stopPlaces.nearest(lon: lon, lat: lat, within: 300) else { return nil }
        return stationBoard(placeId: place.id, at: now, limit: limit)
    }

    /// The stop a stationary, accurately located phone can honestly claim.
    ///
    /// The register's platform points answer proximity; `StopPlace` answers
    /// ownership. That order matters at a large station, whose centre may be a
    /// hundred metres from the platform the phone is standing on. Nearby child
    /// stops such as “Bern, Bahnhof” are folded into their parent “Bern” for the
    /// station fallback, while a confidently isolated child can still return
    /// its own platform board.
    public func nearbyBoard(
        lon: Double, lat: Double, accuracy: Double, at now: Timestamp
    ) -> NearbyBoard? {
        guard accuracy.isFinite, accuracy >= 0,
              accuracy <= RideMatching.stationaryAccuracy,
              stopPlaces.count > 0
        else { return nil }

        // Wide enough to see the parent point from the outer platforms of a
        // main station, but the final acceptance below is against a stop the
        // phone can actually be standing at, not against this search radius.
        let placeReach = max(Self.stationSpread, accuracy + 80)
        let places = stopPlaces.nearby(
            lon: lon, lat: lat, within: placeReach, limit: 80
        )

        var groupPlace: [String: StopPlace] = [:]
        var groupStops: [String: [RegisteredStop]] = [:]
        var groupDistance: [String: Double] = [:]

        func include(_ place: StopPlace, distance: Double) {
            let parent = canonicalStationPlace(place, among: places)
            groupPlace[parent.id] = parent
            groupDistance[parent.id] = min(groupDistance[parent.id] ?? .infinity, distance)
        }

        for place in places {
            include(
                place,
                distance: Geo.flatMetres(place.lon, place.lat, lon, lat)
            )
        }

        // A phone need only be close to a platform point. The parent station's
        // own point may be much further away and must not veto it.
        let stopReach = max(120, accuracy + 50)
        for stop in register.near(lon: lon, lat: lat, metres: stopReach) {
            let station = StopRegister.stationOf(stop.id)
            guard let place = stopPlaces.place(id: station) else { continue }
            let parent = canonicalStationPlace(place, among: places)
            let distance = Geo.flatMetres(stop.lon, stop.lat, lon, lat)
            include(place, distance: distance)
            groupStops[parent.id, default: []].append(stop)
        }

        let ranked = groupDistance.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value < b.value
        }
        guard let nearest = ranked.first, let station = groupPlace[nearest.key],
              // Railway platforms extend well beyond their register points.
              // A precise fix 80 m along Spiez's platform still identifies the
              // station; it does not identify a particular track. Kerbside
              // stops retain their smaller reach and platform selection below
              // still requires clear separation from the adjacent platform.
              nearest.value <= max(station.rail ? 100 : 25, accuracy + 25)
        else { return nil }

        // Two unrelated stops equally plausible under the accuracy circle are
        // not a choice to make silently. Equivalent interchange names have
        // already been canonicalised into one group above.
        if ranked.count > 1,
           ranked[1].value - nearest.value <= max(8, accuracy * 1.5) {
            return nil
        }

        if let stop = Self.confidentStop(
            among: groupStops[nearest.key] ?? [],
            lon: lon, lat: lat, accuracy: accuracy
        ), let board = platformBoard(ref: stop.id, at: now) {
            return .platform(board)
        }

        return stationBoard(placeId: station.id, at: now).map(NearbyBoard.station)
    }

    /// Choose one platform only when its uncertainty disc and its nearest
    /// sibling's do not overlap. Rows naming the same track are collapsed first
    /// so duplicate directional records cannot manufacture ambiguity.
    static func confidentStop(
        among stops: [RegisteredStop],
        lon: Double, lat: Double, accuracy: Double
    ) -> RegisteredStop? {
        guard accuracy <= 18 else { return nil }

        var nearestByLabel: [String: (stop: RegisteredStop, distance: Double)] = [:]
        for stop in stops {
            guard stop.platform != nil || stop.assigned != nil else { continue }
            let label: String
            if let platform = stop.platform {
                label = "platform:\(StopRegister.trackOf(platform) ?? platform)"
            } else {
                label = "assigned:\(stop.assigned!)"
            }
            let distance = Geo.flatMetres(stop.lon, stop.lat, lon, lat)
            if distance < (nearestByLabel[label]?.distance ?? .infinity) {
                nearestByLabel[label] = (stop, distance)
            }
        }

        let ranked = nearestByLabel.values.sorted { a, b in
            a.distance == b.distance ? a.stop.id < b.stop.id : a.distance < b.distance
        }
        guard ranked.count >= 2 else { return nil }
        let first = ranked[0], second = ranked[1]
        let separation = Geo.flatMetres(
            first.stop.lon, first.stop.lat, second.stop.lon, second.stop.lat
        )
        guard first.distance <= max(12, accuracy * 1.5),
              separation >= max(16, accuracy * 2.5),
              second.distance - first.distance > accuracy * 2
        else { return nil }
        return first.stop
    }

    /// Use the same cached, direction-specific daytime cadence as the Watch
    /// board, rather than estimating a frequency from a few visible rows.
    private func typicalInterval(of journey: Journey, at index: Int, now: Timestamp) -> Int? {
        guard let ref = journey.stops.indices.contains(index) ? journey.stops[index].ref : nil else {
            return nil
        }
        let station = StopRegister.stationOf(ref)
        return intervalMinutes(
            of: journey, at: index,
            cadences: timetable?.departureCadences(
                callingAt: [station], on: Date(timeIntervalSince1970: Double(now))
            ) ?? []
        )
    }

    private func intervalMinutes(
        of journey: Journey, at index: Int, cadences: [TimetableCadence]
    ) -> Int? {
        guard journey.stops.indices.contains(index),
              let ref = journey.stops[index].ref else { return nil }
        let station = StopRegister.stationOf(ref)
        guard let direction = journey.stops.dropFirst(index + 1).compactMap({ call -> String? in
            guard let ref = call.ref else { return nil }
            let next = StopRegister.stationOf(ref)
            return next == station ? nil : next
        }).first else { return nil }
        return cadences.first {
            $0.mode == journey.mode && $0.line == journey.line && $0.direction == direction
        }?.minutes
    }

    private func board(
        name: String, id: String, lon: Double, lat: Double, at now: Timestamp, limit: Int,
        preview: Bool = false
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
        //
        // Each carries whether it may use the widened rail radius, and only its
        // numbered platforms do. A whole-station board still names the S-Bahn,
        // because the platforms it is made of ask for it; what it no longer does
        // is let the road-side kerbs ask, which at Bern is how a pole on the
        // Bollwerk came to list the RBS lines running under the forecourt.
        var kerbs: [ServingPoint] = []
        // The centre is a point nothing stops at, so it asks as the station: at
        // a railway station the tracks are genuinely what is here, and at a bus
        // terminal beside a railway they are not.
        var stationIsRail = stopPlaces.place(id: id)?.rail ?? false

        // Exact, and free: a DIDOK number is `85` plus the SLOID number.
        if let own = StopRegister.sloid(forDidok: id) { hereStations.insert(own) }
        // Italian / French / German stations are a UIC, not a Swiss SLOID.
        if id.allSatisfy(\.isNumber) { hereStations.insert(id) }
        if let code = StopRegister.scheduledStopPointCode(id) { hereStations.insert(code) }

        // Sibling stop places first. Most stations are joined below through
        // their registered platforms, but a boat landing has no platform row.
        // Without this symmetric pass, tapping `Spiez Schiffstation` found the
        // buses beside it while tapping `Spiez, Schiffstation` did not find the
        // boats: only the bus stop existed in the platform register. Stop-place
        // identity closes that one-way join before the platform detail is added.
        for place in stopPlaces.nearby(
            lon: lon, lat: lat, within: Self.stationSpread, limit: 200
        ) where Self.partOfStation(place.name, name) {
            if let station = StopRegister.sloid(forDidok: place.id) {
                hereStations.insert(station)
            }
            if place.rail { stationIsRail = true }
            kerbs.append(ServingPoint(Coord(lon: place.lon, lat: place.lat), rail: place.rail))
        }

        if register.isReady {
            for stop in register.near(lon: lon, lat: lat, metres: Self.stationSpread)
            where Self.partOfStation(stop.name, name) {
                herePlatforms.insert(stop.id)
                hereStations.insert(StopRegister.stationOf(stop.id))
                kerbs.append(ServingPoint(
                    Coord(lon: stop.lon, lat: stop.lat), rail: railPlatform(track: stop.platform, at: StopRegister.stationOf(stop.id))
                ))
            }
        }
        // First, as it was before the kerbs were added around it: where two
        // relations carry the same line the nearest one to the tap should be
        // the one whose direction the row names.
        kerbs.insert(ServingPoint(Coord(lon: lon, lat: lat), rail: stationIsRail), at: 0)

        func callsHere(_ stop: Call) -> Bool {
            if let ref = stop.ref {
                if herePlatforms.contains(ref) { return true }
                if hereStations.contains(StopRegister.stationOf(ref)) { return true }
            }
            // Last resort, and exact rather than fuzzy: where the two sources do
            // happen to agree on a name, that is still an identifier.
            return stop.name == name
        }

        /// Which of a run's calls inside this station the board should name.
        ///
        /// A station is a place, not a point, so a run can call at several of
        /// its stops one after another: tram 3 reaches Bern, Hirschengraben a
        /// minute before Bern, Bahnhof. Naming the first of those answered
        /// "what leaves Bern" with a tram *to* Bern — a departure whose whole
        /// remaining journey never left the station it was listed on. Walk the
        /// adjacent calls that are all here, and name the one a passenger
        /// means:
        ///
        /// - where they run to the end of the journey, the last of them. It
        ///   terminates inside this station, so it is an arrival here and not
        ///   a departure, and the board files it as one.
        /// - otherwise the station's own stop, if it is among them. Somebody
        ///   standing at Bern boards at Bern, Bahnhof; the kerb one street
        ///   earlier is a place the same vehicle happens to pass first.
        /// - otherwise the first, as before.
        ///
        /// Adjacency is the whole of it: a bus that leaves Bern, Bollwerk,
        /// loops the city for forty minutes and comes back to the station at
        /// the end of its run still leaves from Bollwerk.
        func boardCall(_ journey: Journey, from first: Int) -> Int {
            var last = first
            while last + 1 < journey.stops.count, callsHere(journey.stops[last + 1]) {
                last += 1
            }
            if last == journey.stops.count - 1 { return last }
            guard last > first else { return first }
            return (first...last).first {
                Self.sameStop(journey.stops[$0].name, name)
                    || Self.isGenericStationStop(journey.stops[$0].name, stationName: name)
            } ?? first
        }

        var found: [BoardEntry] = []
        /// One row for one run, wherever the run was read from.
        var listedRuns = Set<String>()
        func list(_ input: Journey) {
            // Packed legs first. Chaining every candidate at Bern used to look
            // up fifty destination stations (~250 ms each) before a single row
            // appeared. Through-workings run only on the trimmed list below.
            let journey = listedJourney(input)
            guard let first = journey.stops.firstIndex(where: {
                callsHere($0) && $0.dep >= Clock.displayMinute(now)
            }) else { return }
            let index = boardCall(journey, from: first)
            let occurrence = "\(journey.id)|\(journey.stops[index].sched ?? journey.stops[index].dep)"
            guard listedRuns.insert(occurrence).inserted else { return }
            let stop = journey.stops[index]
            found.append(
                boardEntry(input, journey: journey, at: index, now: now, stationName: name)
            )
            rememberBoardJourney(journey, departure: stop.dep, as: input.id)
        }

        // OJP / mirror first: those still have the foreign tail the packed
        // Swiss trip dropped, and `list` then skips the truncated duplicate.
        var source = runs.boardValues
        source.append(contentsOf: callers(matchingAnyOf: hereStations.union([name])))
        for journey in source { list(journey) }
        for journey in scheduled(
            at: hereStations, from: now, filling: found.count, of: limit, preview: preview
        ) {
            list(journey)
        }
        found.sort { $0.departure < $1.departure }
        found = Self.trim(Self.collapseDuplicateRuns(found).filter { $0.isUpcoming(at: now) }, to: limit)
        if preview {
            return StationBoard(
                id: id, name: StopNaming.display(name), lon: lon, lat: lat, now: now,
                departures: found
            )
        }
        found = enrichBoardRows(found, now: now, stationName: name, stations: hereStations, callsHere: callsHere)
        found = Self.trim(Self.collapseDuplicateRuns(found).filter { $0.isUpcoming(at: now) }, to: limit)
        return StationBoard(
            id: id, name: StopNaming.display(name), lon: lon, lat: lat, now: now,
            departures: found,
            serving: servingLines(at: kerbs, besides: found)
        )
    }

    /// Prefer the RunStore record when live and packed have already merged,
    /// without walking neighbours. `boardWorking` is the later, slower join.
    private func listedJourney(_ input: Journey) -> Journey {
        let resolved = runs.resolve(input)
        return input.stops.count > resolved.stops.count ? input : resolved
    }

    private func boardEntry(
        _ input: Journey, journey: Journey, at index: Int, now: Timestamp, stationName: String,
        interval: Int? = nil, showStop: Bool = true
    ) -> BoardEntry {
        let stop = journey.stops[index]
        return BoardEntry(
            id: input.id, mode: journey.mode,
            line: Journey.badgeLine(input.line, extra: input.extra, mode: input.mode),
            to: Journey.reachedDestination(journey, from: index),
            from: StopNaming.display(journey.stops[0].name),
            departure: stop.dep, arrival: stop.arr,
            platform: stop.platform ?? stop.assigned, delay: stop.delay ?? journey.delay,
            observed: stop.observed,
            // The second line answers "which stop of this station", so it is
            // worth a line only where the answer is somewhere else. `Bern,
            // Bahnhof` is the forecourt of Bern: naming it under every tram on
            // Bern's board repeats the title once per row and buries the one
            // line that means something — `Bern, Hirschengraben`, which is a
            // walk away.
            stop: showStop && !Self.sameListedStop(stop.name, stationName)
                && !Self.isGenericStationStop(stop.name, stationName: stationName)
                ? StopNaming.display(stop.name) : nil,
            terminates: index == journey.stops.count - 1,
            originates: index == 0,
            running: Positioning.position(of: journey, at: now) != nil,
            typicalIntervalMinutes: interval,
            runIdentity: BoardRunIdentity(journey: journey, at: index)
        )
    }

    /// Through-workings and daytime cadence, only for the rows the panel will
    /// actually draw. The packed list is already on screen.
    private func enrichBoardRows(
        _ entries: [BoardEntry], now: Timestamp, stationName: String, stations: Set<String>,
        callsHere: (Call) -> Bool, showStop: Bool = true
    ) -> [BoardEntry] {
        let cadences = timetable?.departureCadences(
            callingAt: stations, on: Date(timeIntervalSince1970: Double(now))
        ) ?? []
        return entries.map { entry in
            let stored = boardJourneys[BoardJourneyKey(id: entry.id, departure: entry.departure)]
            guard let stored else {
                return withInterval(entry, of: nil, cadences: cadences, now: now)
            }
            let working = boardWorking(stored, predecessors: true)
            let booked = entry.runIdentity?.scheduledDeparture ?? entry.departure
            guard let index = working.stops.firstIndex(where: {
                callsHere($0) && abs(($0.sched ?? $0.dep) - booked) <= 30
            }) else {
                return withInterval(entry, of: stored, cadences: cadences, now: now)
            }
            rememberBoardJourney(working, departure: working.stops[index].dep, as: entry.id)
            var out = boardEntry(
                stored, journey: working, at: index, now: now, stationName: stationName,
                interval: intervalMinutes(of: working, at: index, cadences: cadences),
                showStop: showStop
            )
            if entry.delay != nil {
                out.delay = entry.delay
                out.departure = entry.departure
                out.arrival = entry.arrival
                out.observed = entry.observed
                out.platform = entry.platform ?? out.platform
            }
            return out
        }
    }

    private func withInterval(
        _ entry: BoardEntry, of journey: Journey?, cadences: [TimetableCadence], now _: Timestamp
    ) -> BoardEntry {
        var out = entry
        if let journey, let index = journey.stops.firstIndex(where: {
            ($0.sched ?? $0.dep) == (entry.runIdentity?.scheduledDeparture ?? entry.departure)
        }) {
            out.typicalIntervalMinutes = intervalMinutes(of: journey, at: index, cadences: cadences)
        } else if let journey, let index = journey.stops.firstIndex(where: { $0.dep == entry.departure }) {
            out.typicalIntervalMinutes = intervalMinutes(of: journey, at: index, cadences: cadences)
        }
        return out
    }

    /// The through-working a board should name.
    ///
    /// Packed GTFS splits a physical train at a junction — RE1 Frutigen→Spiez
    /// continues Spiez→Bern under a new trip id — so a row built from the
    /// printed leg says Spiez while the panel, which opens the chained vehicle,
    /// says Bern. Prefer the chained vehicle, then unique same-line neighbours
    /// from the packed timetable. Look backwards as well as forwards: opening
    /// the Spiez→Brig numbered working still started in Bern.
    func boardWorking(_ input: Journey, predecessors: Bool = true) -> Journey {
        _ = fleetByID()
        if throughRevision != revision {
            throughWorkings.removeAll(keepingCapacity: true)
            neighbourCandidates.removeAll(keepingCapacity: true)
            throughRevision = revision
        }
        let resolved = runs.resolve(input)
        let base = input.stops.count > resolved.stops.count ? input : resolved
        let live = fleetVehicle(matching: base) ?? currentVehicle(containing: base)
        var seed = live
        if base.stops.count > seed.stops.count { seed = base }
        if input.stops.count > seed.stops.count { seed = input }
        if predecessors,
           let cached = throughWorkings[Self.throughKey(seed)] ?? throughWorkings[Self.throughKey(input)],
           cached.stops.count >= seed.stops.count {
            return cached
        }
        var legs = [seed]
        // Predecessors are for the opened panel ("from Bern" on the Spiez
        // numbered working). A station board that asked this for every row
        // spent half a minute at Bern querying the origin of each departure.
        if predecessors {
            while legs.count < Chains.maxChainLength,
                  let prev = boardNeighbour(of: legs[0], forward: false) {
                if legs.contains(where: { $0.id == prev.id }) { break }
                legs.insert(prev, at: 0)
            }
        }
        while legs.count < Chains.maxChainLength,
              (predecessors || Self.needsForwardContinuation(legs[legs.count - 1])),
              let next = boardNeighbour(of: legs[legs.count - 1], forward: true) {
            if legs.contains(where: { $0.id == next.id }) { break }
            legs.append(next)
        }
        let working = legs.count == 1 ? seed : Chains.join(legs)
        if predecessors { rememberThrough(working, keys: [seed, input, working]) }
        return working
    }

    private static func throughKey(_ journey: Journey) -> String {
        "\(journey.id)|\(journey.start)"
    }

    private func packedCallers(
        _ timetable: TimetableStore, station: String, from: Timestamp, until: Timestamp
    ) -> [Journey] {
        let quantum: Timestamp = 5 * 60
        let qFrom = from / quantum * quantum
        let qUntil = ((until + quantum - 1) / quantum) * quantum
        let key = "\(station)|\(qFrom)|\(qUntil)"
        if let cached = neighbourCandidates[key] { return cached }
        let found = timetable.journeys(
            callingAt: [station],
            from: qFrom,
            to: qUntil,
            limit: 80,
            place: { [register] stop in register.lookup(stop) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        )
        neighbourCandidates[key] = found
        return found
    }

    /// Packed split headsigns already name the passenger destination. Trams
    /// and buses that end where they advertise do not need a neighbour search;
    /// trains still might (RE1 4157 advertises Spiez and continues as 4257).
    private static func needsForwardContinuation(_ journey: Journey) -> Bool {
        if journey.to?.contains("|") == true { return false }
        switch journey.mode {
        case .train, .metro: return true
        default: return false
        }
    }

    private func rememberThrough(_ working: Journey, keys: [Journey]) {
        for journey in keys { throughWorkings[Self.throughKey(journey)] = working }
        for part in working.parts ?? [] {
            let start = working.stops.indices.contains(part.start)
                ? working.stops[part.start].dep : working.start
            throughWorkings["\(part.id)|\(start)"] = working
        }
    }

    /// Unique packed neighbour of this numbered leg, or nil when the working
    /// begins or ends here.
    private func boardNeighbour(of journey: Journey, forward: Bool) -> Journey? {
        guard let edge = forward ? journey.stops.last : journey.stops.first else { return nil }
        let junction = Chains.stationKey(edge)
        // What the feed says, if it says anything. Where it does, the scoring
        // below is not consulted at all — not as a tie-break and not as a
        // fallback. Two RE1s leave Spiez within the ambiguity margin and the
        // score cannot tell them apart, which is exactly the case where the
        // feed names the right one outright.
        let declared = publishedNeighbourNames(of: journey, forward: forward)
        var stated: [Journey] = []
        var best: (journey: Journey, score: Int)?
        var runnerUp = Int.max
        var considered: [Journey] = []
        func consider(_ input: Journey) {
            let inputEdge = forward ? input.stops.first : input.stops.last
            guard let inputEdge, Chains.stationKey(inputEdge) == junction else { return }
            // The map and packed lookup can return the same occurrence, and
            // OJP can give it another ID. Rank operating runs, not copies:
            // otherwise the duplicate becomes its own ambiguous runner-up.
            // Resolve first so a stale packed copy cannot override live data.
            let candidate = runs.resolve(input)
            guard candidate.id != journey.id else { return }
            let otherEdge = forward ? candidate.stops.first : candidate.stops.last
            guard let otherEdge, Chains.stationKey(otherEdge) == junction else { return }
            guard !considered.contains(where: { RunStore.matches($0, candidate) }) else { return }
            considered.append(candidate)
            if !declared.isEmpty {
                let names = Self.edgeNames(of: candidate, forward: !forward)
                // The same turnaround caveat as the map's: the feed publishes a
                // bus continuing as its own return working, and joining those
                // halves gives the panel a run that goes out and back.
                if names.contains(where: { declared.contains($0.lowercased()) }),
                   Chains.carriesOn(forward ? journey : candidate, forward ? candidate : journey) {
                    stated.append(candidate)
                }
                return
            }
            let earlier = forward ? journey : candidate
            let later = forward ? candidate : journey
            guard var score = Chains.candidateScore(earlier, later)
                    ?? Chains.passengerContinuationScore(earlier, later)
            else { return }
            // The incoming headsign "Brig | Zweisimmen" names the portions.
            // Prefer the continuation that actually goes to one of them when
            // two RE1s leave Spiez in the same window.
            let advertised = earlier.to
            if let advertised, advertised.contains("|") {
                let wanted = advertised.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if let dest = later.to ?? later.stops.last?.name,
                   wanted.contains(where: { StopNaming.sameBoardDestination(dest, $0) }) {
                    score -= 60
                }
            }
            if let held = best {
                if score < held.score {
                    runnerUp = held.score
                    best = (candidate, score)
                } else if score < runnerUp {
                    runnerUp = score
                }
            } else {
                best = (candidate, score)
            }
        }

        let keys = [edge.ref.map { StopRegister.stationOf($0) }, edge.name]
            .compactMap { $0 }.filter { !$0.isEmpty }
        for candidate in callers(matchingAnyOf: keys) { consider(candidate) }

        // Always ask the packed file, not only when the map fleet is empty.
        // Callers at a junction like Spiez are often two RE1s a few minutes
        // apart; that used to look like ambiguity and skip the timetable,
        // leaving the board on the numbered leg's last stop.
        if let timetable, register.isReady, let ref = edge.ref {
            let station = StopRegister.stationOf(ref)
            let from = forward ? edge.arr : edge.dep - Chains.maxGapSameLine
            let until = forward ? edge.arr + Chains.maxGapSameLine : edge.dep
            if !station.isEmpty, until > from {
                for candidate in packedCallers(
                    timetable, station: station, from: from, until: until
                ) { consider(candidate) }
            }
        }

        if !declared.isEmpty {
            if stated.count == 1 { return stated[0] }
            // **Forward, a working that parts keeps nothing.** RE1 4177 leaves
            // Bern advertising "Domodossola (I) | Zweisimmen" and comes apart at
            // Spiez into RE1 4277 and R11 6829. Folding in the half that keeps
            // the line number reads as a train that runs through to Domodossola,
            // and that is a worse answer than a short one: the Zweisimmen half
            // is then a destination the card names in its title and cannot
            // show, the direction picker has one direction in it, and the map
            // draws one line down the Lötschberg for a train that is two.
            // The trunk therefore ends where the train does, and both halves
            // are offered beside it — see `AppModel.loadBranches`, which is what
            // the stop list, the picker and the extra map lines are built from.
            //
            // **Backward, a join still answers.** Two trains coupling are one
            // train leaving, and the reader's own coaches came from one of
            // them: the half that keeps the line is the working this one
            // continues, the same rule the map uses in
            // `Chains.continuation(of:among:preferredID:at:)`.
            guard !forward else { return nil }
            let sameLine = stated.filter { $0.line == journey.line && !journey.line.isEmpty }
            return sameLine.count == 1 ? sameLine[0] : nil
        }

        guard let best, runnerUp == Int.max || runnerUp - best.score >= Chains.ambiguityMargin
        else { return nil }
        return best.journey
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
    /// First paint of a station card: the next couple of hours, packed only.
    /// Night buses and through-destinations arrive on the full read that
    /// replaces this.
    public static let boardPreviewHorizon: TimeInterval = 2 * 3600

    /// How deep into the schedule a board reads before it is trimmed.
    ///
    /// Larger than the board, on purpose. The trim below keeps the next
    /// departure of every line, and a line running once a night is only found
    /// by reading past the line running every seven minutes — at Bern's stop M
    /// at 23:15, the 17 and the 19 fill forty rows before the Moonliner's 01:45
    /// is reached.
    static let boardDepth = 240
    static let boardPreviewDepth = 80

    /// The board, trimmed so a frequent line cannot crowd out a rare one.
    ///
    /// A count alone is the wrong cap, because the panel groups: forty rows of
    /// a bus every seven minutes draw as two rows with a disclosure on them.
    /// The next departure of *every* service that calls here is kept, even when
    /// that is more rows than `limit`. Remaining slots are later runs of the
    /// busy lines, so the disclosure still fills.
    ///
    /// Keyed as the panel groups — see `DepartureGroup.group`.
    /// Shared by station, platform and platform-shape boards. Match the
    /// operating run and booked call before normalising the display label.
    /// Presentation still has to collapse: `RunStore` keeps ambiguous
    /// lookalikes distinct, and a board lists every source until this runs.
    static func collapseDuplicateRuns(_ entries: [BoardEntry]) -> [BoardEntry] {
        var out: [BoardEntry] = []
        out.reserveCapacity(entries.count)
        // Compare only neighbouring booked minutes at the same station. A day
        // of departures otherwise reparses/compares every run with every other.
        var buckets: [String: Set<Int>] = [:]
        func bucket(_ entry: BoardEntry, minute: Int) -> String {
            let station = entry.runIdentity?.station ?? "id:" + entry.id
            return "\(entry.mode.rawValue)|\(station)|\(entry.terminates)|\(minute)"
        }
        for var entry in entries {
            entry.line = Journey.publishedLine(entry.line, mode: entry.mode)
            let minute = (entry.runIdentity?.scheduledDeparture ?? entry.departure) / 60
            var candidates = Set<Int>()
            for nearby in (minute - 1)...(minute + 1) {
                candidates.formUnion(buckets[bucket(entry, minute: nearby)] ?? [])
            }
            let index: Int
            if let i = candidates.sorted().first(where: { isSameWorking(out[$0], entry) }) {
                out[i] = preferredWorking(out[i], entry)
                index = i
            } else {
                index = out.count
                out.append(entry)
            }
            buckets[bucket(entry, minute: minute), default: []].insert(index)
        }
        return out.sorted { ($0.departure, $0.id) < ($1.departure, $1.id) }
    }

    static func isSameWorking(_ a: BoardEntry, _ b: BoardEntry) -> Bool {
        guard a.mode == b.mode, a.terminates == b.terminates else { return false }
        if let first = a.runIdentity, let second = b.runIdentity {
            return first.matches(second)
        }
        // Older callers without journey metadata can only prove exact identity.
        return a.id == b.id && a.departure == b.departure && a.stop == b.stop
    }

    static func preferredWorking(_ a: BoardEntry, _ b: BoardEntry) -> BoardEntry {
        let keep: BoardEntry
        let drop: BoardEntry
        let aLive = a.runIdentity?.source == "ojp" && a.delay != nil
        let bLive = b.runIdentity?.source == "ojp" && b.delay != nil
        if aLive != bLive {
            keep = aLive ? a : b
            drop = aLive ? b : a
        } else if let first = a.runIdentity, let second = b.runIdentity,
           first.onward.last?.station != second.onward.last?.station,
           first.onward.count != second.onward.count {
            keep = first.onward.count > second.onward.count ? a : b
            drop = first.onward.count > second.onward.count ? b : a
        } else if a.running != b.running {
            keep = a.running ? a : b
            drop = a.running ? b : a
        } else if a.observed != b.observed {
            keep = a.observed ? a : b
            drop = a.observed ? b : a
        } else if (a.delay == nil) != (b.delay == nil) {
            keep = a.delay != nil ? a : b
            drop = a.delay != nil ? b : a
        } else {
            let chooseA = a.runIdentity?.timetabled != b.runIdentity?.timetabled
                ? a.runIdentity?.timetabled == true
                : (a.line.count, a.id) <= (b.line.count, b.id)
            keep = chooseA ? a : b
            drop = chooseA ? b : a
        }
        var out = keep
        let live = [keep, drop].first { $0.delay != nil }
            ?? [keep, drop].first { $0.observed }
        if let live {
            out.departure = live.departure
            out.arrival = live.arrival
            out.delay = live.delay
            out.observed = live.observed
            out.platform = live.platform ?? out.platform
        }
        if out.platform == nil { out.platform = drop.platform }
        if out.typicalIntervalMinutes == nil { out.typicalIntervalMinutes = drop.typicalIntervalMinutes }
        if let other = drop.runIdentity { out.runIdentity?.includeAliases(of: other) }
        out.line = Journey.publishedLine(out.line, mode: out.mode)
        return out
    }

    static func trim(_ entries: [BoardEntry], to limit: Int) -> [BoardEntry] {
        guard entries.count > limit else { return entries }
        var counts: [String: Int] = [:]
        var firsts: [BoardEntry] = []
        var extras: [BoardEntry] = []
        firsts.reserveCapacity(min(entries.count, limit))
        for entry in entries {
            let line = Journey.publishedLine(entry.line, mode: entry.mode)
            let dest = squash(localDestination(entry.to ?? ""))
            let key = "\(entry.mode.rawValue)|\(line)|\(dest)|\(entry.stop ?? "")"
            // The main list groups services. Keep a following occurrence for
            // each one before frequent buses consume the remaining row budget;
            // otherwise fixing a label alias also erases its disclosure times.
            let count = counts[key, default: 0]
            counts[key] = count + 1
            if count < 2 {
                firsts.append(entry)
            } else {
                extras.append(entry)
            }
        }
        guard firsts.count < limit else { return firsts }
        var out = firsts
        out.append(contentsOf: extras.prefix(limit - firsts.count))
        out.sort { $0.departure < $1.departure }
        return out
    }

    /// What the printed timetable says calls at these stations, for a board the
    /// live fleet could not fill.
    ///
    /// Deliberately not folded into `journeys`: these are rows for a panel, not
    /// vehicles for the map. Adding them to the store would draw tomorrow's
    /// first bus on today's map and would have to be undrawn again on the next
    /// tick. They enter the shared run registry without joining the active map.
    ///
    /// Always asked. A station whose live board is already "full" is exactly
    /// the one that used to hide an hourly train: the next sixty rows were the
    /// seven-minute tram, and the scan never reached S44. The timetable walk
    /// keeps one upcoming trip per pattern past that count, so a busy station
    /// still names every service that calls.
    ///
    /// `accepting` narrows the query from the station to the stops a *platform*
    /// board is about. Without it the schedule spends the board's whole budget
    /// on the station's other kerbs — see `TimetableStore.patterns`.
    func scheduled(
        at stations: Set<String>, key: String? = nil, accepting: ((String) -> Bool)? = nil,
        from now: Timestamp, filling count: Int, of limit: Int, preview: Bool = false
    ) -> [Journey] {
        guard !stations.isEmpty, register.isReady,
              let timetable, timetable.isReady
        else { return [] }
        let horizon = preview ? Self.boardPreviewHorizon : Self.boardHorizon
        let depth = preview ? Self.boardPreviewDepth : Self.boardDepth
        return timetable.journeys(
            callingAt: stations,
            key: key,
            accepting: accepting,
            from: now,
            to: now + Timestamp(horizon),
            limit: preview ? depth : max(max(limit, count), depth),
            keepHiddenPatterns: !preview,
            place: { [register] ref in register.lookup(ref) },
            operatorName: { [operators] agency in operators.name(for: agency) }
        ).map { runs.ingest($0) }
    }

    /// A point the serving lines are asked about, and whether the widened rail
    /// radius may be spent on it.
    ///
    /// The flag is not "is this station a railway station" — at Bern that is
    /// true of the bus poles on the forecourt too, which is the whole problem.
    /// It is "is this point a railway platform", which is decided by
    /// `Fleet.railPlatform(_:)` from the register.
    public struct ServingPoint: Sendable, Equatable {
        public var coord: Coord
        public var rail: Bool

        public init(_ coord: Coord, rail: Bool = false) {
            self.coord = coord
            self.rail = rail
        }
    }

    /// Whether a registered stop is a railway platform, and so may ask the
    /// mapped routes about itself at `servingRailSpread` rather than at
    /// `servingSpread`.
    ///
    /// Two tests, both on data already held, and both required:
    ///
    /// - the track is numbered. The register codes a railway track with digits
    ///   — Bern's platform 5 is `5` and its sectors are `7A-D` — and a station's
    ///   road-side kerbs with letters: `Z`, `K1`. `trackOf` already reduces the
    ///   sectors to their track, and `coveredTracks` already relies on the same
    ///   convention to decide which platforms a drawn shape replaces.
    /// - the station is a railway station. Without this a numbered bay at a bus
    ///   terminal beside a railway would reach the same 120 m for the same wrong
    ///   reason.
    func railPlatform(track code: String?, at station: String) -> Bool {
        guard let track = StopRegister.trackOf(code),
              !track.isEmpty, track.allSatisfy(\.isNumber) else { return false }
        return stopPlaces.place(id: station)?.rail ?? false
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
    /// Railway stop nodes sit on the platform, often tens of metres from the
    /// register point used for a tap. Thirty metres is the right kerb radius
    /// and misses an S-Bahn at a station the size of Bern.
    ///
    /// Only a numbered track at a railway station may use it — see
    /// `ServingPoint`. Applied to every point instead, it made the bus kerbs of
    /// a main station inherit the railway under them: Bern's stop Z is a pole
    /// on the Bollwerk and the RBS platforms are directly beneath the forecourt
    /// beside it, so a 120 m circle from the pole reached their stop nodes and
    /// the kerb's board announced four S-Bahn lines "through here".
    static let servingRailSpread = 120.0

    /// The lines the mapped routes say call at any of these points.
    ///
    /// A station is asked about *by its kerbs*, not by its centre. The centre of
    /// a stop place is a point nothing stops at — at Bärenplatz it is 16 m from
    /// one kerb and 40 m from the other — so a single circle from it either
    /// misses a side of the street or grows wide enough to sweep in the next
    /// stop along. The kerbs come from the register by identifier, and each is
    /// asked about on its own.
    public func servingLines(at points: [ServingPoint]) -> [ServingLine] {
        guard relations.isReady, !points.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [ServingLine] = []
        func add(_ lines: [ServingLine]) {
            for line in lines where seen.insert("\(line.mode.rawValue)|\(line.ref)").inserted {
                out.append(line)
            }
        }
        for point in points {
            add(relations.linesStopping(
                lon: point.coord.lon, lat: point.coord.lat, within: Self.servingSpread, limit: 80
            ))
            // Train stop nodes at a main station sit on the platform, often
            // farther from the tapped point than a bus kerb is. The wider circle
            // is why a railway platform finds its S-Bahn at all, and it is spent
            // only on the points that are themselves railway platforms, so a
            // lettered bay does not inherit the tracks it stands over.
            guard point.rail else { continue }
            add(relations.linesStopping(
                lon: point.coord.lon, lat: point.coord.lat,
                within: Self.servingRailSpread, limit: 80
            ).filter { $0.mode == .train || $0.mode == .metro })
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
    func servingLines(at points: [ServingPoint], besides departures: [BoardEntry]) -> [ServingLine] {
        func key(_ mode: Mode, _ ref: String) -> String {
            "\(mode.rawValue)|\(Journey.publishedLine(ref, mode: mode))"
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
        // One indexed viewport query, rather than a nearby-place query for
        // every marker. A large city can put hundreds of kerbs in this method;
        // the filtering must stay insignificant beside laying them out.
        let railPlaces = stopPlaces.within(
            bbox.padded(byMetres: Self.stationSpread),
            railOnly: true, limit: .max
        )
        // A generic, unlabelled forecourt point is already represented by the
        // railway station dot and its combined board. Drawing it again created
        // the stray square beside Bern and Wichtrach and made one place answer
        // as two choices. Real platform/stop codes and generated A/B sides are
        // retained; so are codeless stops that are not simply “…, Bahnhof”.
        rows.removeAll { stop in
            guard stop.platform == nil, stop.assigned == nil else { return false }
            return railPlaces.contains { place in
                Geo.flatMetres(stop.lon, stop.lat, place.lon, place.lat)
                    <= Self.stationSpread
                    && Self.isGenericStationStop(
                        stop.name, stationName: place.name
                    )
            }
        }
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
    public func plateBoard(
        id: String, at now: Timestamp, loadingOnly: Bool = false, preview: Bool = false
    ) -> PlatformBoard? {
        platformBoard(ref: id, at: now, loadingOnly: loadingOnly, preview: preview)
    }

    /// What calls at one platform, soonest first.
    ///
    /// Matched on the SLOID the feed itself puts on each call, so this is exact
    /// rather than a proximity guess — the same identifier join that places the
    /// vehicles. Where a journey names the station rather than the platform,
    /// the platform *code* is compared instead, sectors aside.
    public func platformBoard(
        ref: String, at now: Timestamp, limit: Int = 40,
        loadingOnly: Bool = false, preview: Bool = false
    ) -> PlatformBoard? {
        guard register.isReady, let place = register.lookup(ref) else { return nil }
        let station = StopRegister.stationOf(ref)

        if loadingOnly {
            return PlatformBoard(
                id: ref, name: place.name, code: place.platform, assigned: place.assigned,
                lon: place.lon, lat: place.lat, now: now, departures: [],
                rail: stopPlaces.place(id: station)?.rail ?? false,
                stationOnly: false, isLoading: true
            )
        }

        func callsHere(_ stop: Call) -> Bool {
            stop.ref == ref || (
                stop.ref != nil && place.platform != nil
                    && StopRegister.sameTrack(stop.platform, place.platform)
                    && StopRegister.stationOf(stop.ref) == station
            )
        }

        var departures: [BoardEntry] = []
        /// One row for one run — see the station board's `list`, which this is.
        var listedRuns = Set<String>()
        func list(_ input: Journey) {
            let journey = listedJourney(input)
            guard let i = journey.stops.firstIndex(where: {
                callsHere($0) && $0.dep >= Clock.displayMinute(now)
            }) else { return }
            let stop = journey.stops[i]
            let occurrence = "\(journey.id)|\(stop.sched ?? stop.dep)"
            guard listedRuns.insert(occurrence).inserted else { return }
            departures.append(
                boardEntry(
                    input, journey: journey, at: i, now: now, stationName: place.name, showStop: false
                )
            )
            rememberBoardJourney(journey, departure: stop.dep, as: input.id)
        }

        // Both ways a call can belong to this platform put it at this station,
        // so the station's own callers are the whole candidate set. See
        // `callers`: without it this walks every call in the country.
        for journey in runs.boardValues { list(journey) }
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
            from: now, filling: departures.count, of: limit, preview: preview
        ) {
            list(journey)
        }
        departures.sort { $0.departure < $1.departure }
        departures = Self.trim(Self.collapseDuplicateRuns(departures).filter { $0.isUpcoming(at: now) }, to: limit)
        if !preview {
            departures = enrichBoardRows(
                departures, now: now, stationName: place.name,
                stations: [station], callsHere: callsHere, showStop: false
            )
            departures = Self.trim(Self.collapseDuplicateRuns(departures).filter { $0.isUpcoming(at: now) }, to: limit)
        }

        let rail = stopPlaces.place(id: station)?.rail
            ?? departures.contains { $0.mode == .train }

        return PlatformBoard(
            id: ref, name: place.name, code: place.platform, assigned: place.assigned,
            lon: place.lon, lat: place.lat, now: now,
            departures: departures, rail: rail,
            stationOnly: false,
            serving: preview ? [] : servingLines(
                at: [ServingPoint(
                    Coord(lon: place.lon, lat: place.lat),
                    rail: railPlatform(track: place.platform, at: station)
                )],
                besides: departures
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
    public func shapeBoard(
        osmId: String, at now: Timestamp, loadingOnly: Bool = false, preview: Bool = false
    ) -> PlatformBoard? {
        guard let shape = platforms.lookup(osmId) else { return nil }
        let boards = shape.sloids.compactMap {
            platformBoard(ref: $0, at: now, loadingOnly: loadingOnly, preview: preview)
        }
        guard let first = boards.first else { return nil }

        var departures: [BoardEntry] = []
        var events = Set<String>()
        for board in boards {
            departures.append(contentsOf: board.departures.filter { events.insert($0.eventID).inserted })
        }
        departures.sort { $0.departure < $1.departure }

        return PlatformBoard(
            id: shape.sloids[0], name: shape.name,
            code: shape.codes.filter { !$0.isEmpty }.joined(separator: " · "),
            assigned: nil, lon: first.lon, lat: first.lat, now: now,
            departures: Self.trim(Self.collapseDuplicateRuns(departures), to: 40), rail: first.rail,
            stationOnly: shape.stationOnly,
            // Asked again for the whole shape rather than unioning the tracks'
            // lists: a line live at one track and idle at the other is running
            // here, and each track's own list only knows about its own board.
            serving: loadingOnly || preview ? [] : servingLines(
                at: [ServingPoint(
                    Coord(lon: first.lon, lat: first.lat),
                    // A shape covering several tracks is a railway platform if
                    // any of them is one: standing on it you board from either
                    // side, which is the same reason the board is their union.
                    rail: shape.sloids.enumerated().contains { i, sloid in
                        railPlatform(
                            track: i < shape.codes.count ? shape.codes[i] : nil,
                            at: StopRegister.stationOf(sloid)
                        )
                    }
                )],
                besides: departures
            ),
            isLoading: loadingOnly, shape: osmId
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
    public func stationBoard(
        osmId: String, at now: Timestamp, limit: Int = 60,
        loadingOnly: Bool = false, preview: Bool = false
    ) -> StationBoard? {
        guard let uic = platforms.station(for: osmId) else { return nil }
        if let place = stopPlaces.place(id: uic) {
            var result = stationBoard(
                placeId: place.id, at: now, limit: limit,
                loadingOnly: loadingOnly, preview: preview
            )
            result?.shape = osmId
            return result
        }
        // A station abroad is in neither the drawn stop places nor the Swiss
        // numbering — Milano Centrale is a UIC and nothing else — but the
        // register holds it, and a board is all this needs.
        guard let ref = StopRegister.sloid(forDidok: uic) ?? (uic.allSatisfy(\.isNumber) ? uic : nil),
              let place = register.lookup(ref)
        else { return nil }
        var result = loadingOnly
            ? StationBoard.loading(id: uic, name: place.name,
                                   at: Coord(lon: place.lon, lat: place.lat), now: now)
            : board(
                name: place.name, id: uic, lon: place.lon, lat: place.lat,
                at: now, limit: limit, preview: preview
            )
        result.shape = osmId
        return result
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
                id: journey.id, mode: journey.mode,
                line: Journey.badgeLine(journey.line, extra: journey.extra, mode: journey.mode),
                to: Journey.reachedDestination(journey),
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

    /// Railway platform positions used to keep covered station tracks visible.
    public func tunnelStationPoints(in bbox: BBox) -> [Coord] {
        let box = bbox.padded(byMetres: TunnelIndex.stationHalfLength)
        let stations = stopPlaces.within(box, railOnly: true, limit: .max)
        let refs = Set(stations.compactMap { StopRegister.sloid(forDidok: $0.id) })
        var served = Set<String>()
        var points = Set<Coord>()
        for stop in register.within(box, limit: .max) {
            let ref = StopRegister.stationOf(stop.id)
            guard refs.contains(ref) else { continue }
            served.insert(ref)
            points.insert(Coord(lon: stop.lon, lat: stop.lat))
        }
        for station in stations {
            if let ref = StopRegister.sloid(forDidok: station.id), served.contains(ref) { continue }
            points.insert(Coord(lon: station.lon, lat: station.lat))
        }
        return points.sorted { $0.lon == $1.lon ? $0.lat < $1.lat : $0.lon < $1.lon }
    }

    /// Captured once, so camera-driven track queries never queue behind fleet work.
    public func trackOverlay() -> RailNet.TrackOverlay { railnet.trackOverlay() }

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
        return (relations.pathCoords(of: relation), relations.stopCoords(of: relation))
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
            // A winning feed can change the public ID of the same occurrence.
            // That is an alias change, not a finished vehicle to retain.
            guard found[runs.resolve(journey).id] == nil else { continue }
            guard journey.end <= now, journey.end >= cutoff else { continue }
            // Geometry is the expensive half and is rebuilt on demand. Holding
            // it for an hour of finished journeys is tens of megabytes for a
            // line nobody may ever scrub back to.
            journey.invalidateGeometry()
            retired[id] = journey
        }

        retired = retired.filter {
            $0.value.end >= cutoff && found[runs.resolve($0.value).id] == nil
        }

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
