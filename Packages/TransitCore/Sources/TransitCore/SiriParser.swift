import Foundation

/// Read SIRI-ET, the official estimated timetable for the whole Swiss network.
///
/// One call returns every journey running in the country — about 16,000 of
/// them, each with its complete call list, its platforms, and observed times
/// for the stops it has already served. Three things follow, and they are the
/// point of this file:
///
/// - **`RecordedCalls` are the stops already served.** Where a journey started
///   is a stated fact, not something to infer from a route relation and a speed
///   estimate. There is nothing left to backfill.
/// - **The times are observed, not predicted.** A recorded call carries
///   `ActualDepartureTime` — when the vehicle really left.
/// - **Every call carries its platform.**
///
/// The response is ~150 MB of XML (7 MB on the wire), so it is parsed as it
/// streams: journeys are cut out of the byte stream one at a time and the
/// consumed prefix is dropped. Holding the document would cost more memory than
/// the entire rest of the app.
public final class SiriParser {
    public struct Summary: Sendable {
        public var seen = 0
        public var placed = 0
        public var unresolved = 0
    }

    /// Resolve a `StopPointRef` to a place. `StopRegister.lookup`, in practice.
    public typealias Resolver = (_ ref: String, _ statedPlatform: String?, _ name: String?) -> Place?

    /// An element's opening and closing tag, with their skip tables built.
    ///
    /// Immutable and shared: the tag names are a fixed vocabulary, and a
    /// national snapshot reads them several million times.
    struct Tag {
        let open: ByteScan.Needle
        let close: ByteScan.Needle
        let openLength: Int
        let closeLength: Int

        init(_ name: String) {
            open = ByteScan.Needle("<\(name)>")
            close = ByteScan.Needle("</\(name)>")
            openLength = name.utf8.count + 2
            closeLength = name.utf8.count + 3
        }
    }

    /// Every element this parser reads, resolved once.
    struct Tags {
        let journey = Tag("EstimatedVehicleJourney")
        let recordedCalls = ByteScan.Needle("<RecordedCalls>")
        let estimatedCalls = ByteScan.Needle("<EstimatedCalls>")
        let recordedCall = Tag("RecordedCall")
        let estimatedCall = Tag("EstimatedCall")
        /// Serves both scopes: SIRI spells a cancelled journey and a cancelled
        /// call with the same element, and only the range it is sought in tells
        /// them apart. See `parseJourney`.
        let cancellation = ByteScan.Needle("<Cancellation>true</Cancellation>")
        let extraCall = ByteScan.Needle("<ExtraCall>true</ExtraCall>")
        let extraJourney = ByteScan.Needle("<ExtraJourney>true</ExtraJourney>")

        let stopPointRef = Tag("StopPointRef")
        let stopPointName = Tag("StopPointName")
        let visitNumber = Tag("VisitNumber")
        let callNote = Tag("CallNote")
        let aimedArrival = Tag("AimedArrivalTime")
        let aimedDeparture = Tag("AimedDepartureTime")
        let actualArrival = Tag("ActualArrivalTime")
        let actualDeparture = Tag("ActualDepartureTime")
        let expectedArrival = Tag("ExpectedArrivalTime")
        let expectedDeparture = Tag("ExpectedDepartureTime")
        let departurePlatform = Tag("DeparturePlatformName")
        let arrivalPlatform = Tag("ArrivalPlatformName")

        let vehicleMode = Tag("VehicleMode")
        let productCategory = Tag("ProductCategoryRef")
        let publishedLine = Tag("PublishedLineName")
        let datedRef = Tag("DatedVehicleJourneyRef")
        let trainNumber = Tag("TrainNumberRef")
        let operatorRef = Tag("OperatorRef")
        let direction = Tag("DirectionName")
        let origin = Tag("OriginName")
        let completeSequence = Tag("IsCompleteStopSequence")
        let monitored = Tag("Monitored")
    }

    private static let tags = Tags()

    private var held: [UInt8] = []
    public private(set) var summary = Summary()

    private let resolve: Resolver
    private let operatorName: (String?) -> String?
    private let operatorFullName: (String?) -> String?

    public init(
        resolve: @escaping Resolver,
        operatorName: @escaping (String?) -> String? = { _ in nil },
        operatorFullName: @escaping (String?) -> String? = { _ in nil }
    ) {
        self.resolve = resolve
        self.operatorName = operatorName
        self.operatorFullName = operatorFullName
        held.reserveCapacity(1 << 20)
    }

    /// Feed one chunk of the response in. `onJourney` is called with each
    /// journey as it completes, so a caller can build its index without a
    /// second pass over sixteen thousand of them.
    public func consume(_ chunk: Data, onJourney: (Journey) -> Void) {
        held.append(contentsOf: chunk)
        // Only worth scanning once there is plausibly a whole journey in hand;
        // a journey block runs to about 11 kB.
        if held.count > 65_536 { drain(onJourney: onJourney) }
    }

    /// Flush whatever is left once the stream ends.
    public func finish(onJourney: (Journey) -> Void) {
        drain(onJourney: onJourney)
    }

    private func drain(onJourney: (Journey) -> Void) {
        var consumedTo = 0

        held.withUnsafeBytes { raw in
            consumedTo = scan(raw, from: 0, upTo: raw.count, onJourney: onJourney)
        }

        if consumedTo > 0 { held.removeFirst(consumedTo) }
    }

    /// Cut every whole journey out of `raw` between `from` and `upTo`, and say
    /// how far the buffer was consumed.
    ///
    /// A journey that *begins* before `upTo` is parsed in full even where it
    /// ends after it: the bound picks which worker owns a journey, not how much
    /// of one it may read. That is what lets a complete snapshot be split
    /// across cores without a journey being cut in half or claimed twice.
    @discardableResult
    func scan(
        _ raw: UnsafeRawBufferPointer, from: Int, upTo: Int, onJourney: (Journey) -> Void
    ) -> Int {
        var at = from
        while at < upTo {
            guard let start = ByteScan.find(Self.tags.journey.open, in: raw, from: at),
                  start < upTo
            else {
                // Keep only a tail long enough to hold a split opening tag.
                return max(at, upTo - Self.tags.journey.openLength)
            }
            guard let end = ByteScan.find(Self.tags.journey.close, in: raw, from: start) else {
                return start
            }

            summary.seen += 1
            let body = (start + Self.tags.journey.openLength)..<end
            if let journey = parseJourney(raw, body) {
                summary.placed += 1
                onJourney(journey)
            } else {
                summary.unresolved += 1
            }
            at = end + Self.tags.journey.closeLength
        }
        return at
    }

    // MARK: - One journey

    /// Turn one `<EstimatedVehicleJourney>` into the journey shape the rest of
    /// the app speaks, or nil if it cannot be placed on a map.
    private func parseJourney(_ raw: UnsafeRawBufferPointer, _ body: Range<Int>) -> Journey? {
        let mode = Categories.siriMode(of: text(raw, body, Self.tags.vehicleMode))

        var stops: [Call] = []
        var seen: [String: Int] = [:]
        /// Which calls were placed by the OpenStreetMap `uic_ref` supplement
        /// rather than the official register. See `dropImpossiblePlacements`.
        var supplement: [Bool] = []

        /// Add a call, or fold it into the one already there.
        ///
        /// A vehicle standing at a stop right now appears in *both* lists: its
        /// arrival has happened, so it is a recorded call, while its departure
        /// has not, so it is also an estimated one. Appended blindly that stop
        /// is listed twice, a second apart — which reads as a fault in the panel
        /// and gives the interpolator a zero-length leg to place the vehicle on.
        func add(_ stop: Call, viaSupplement: Bool) {
            guard let at = seen[stop.key] else {
                seen[stop.key] = stops.count
                stops.append(stop)
                supplement.append(viaSupplement)
                return
            }
            stops[at].dep = max(stops[at].dep, stop.dep)
            if stops[at].platform == nil { stops[at].platform = stop.platform }
            if stops[at].note == nil { stops[at].note = stop.note }
            if let delay = stop.delay { stops[at].delay = delay }
            // A stop standing in both lists is one call, and either half of it
            // may be the half carrying the flag: the recorded arrival can be
            // plain while the estimated departure is withdrawn.
            stops[at].cancelled = stops[at].cancelled || stop.cancelled
            stops[at].extra = stops[at].extra || stop.extra
        }

        let recordedAt = ByteScan.find(Self.tags.recordedCalls, in: raw, from: body.lowerBound)
            .flatMap { $0 < body.upperBound ? $0 : nil }
        let estimatedAt = ByteScan.find(Self.tags.estimatedCalls, in: raw, from: body.lowerBound)
            .flatMap { $0 < body.upperBound ? $0 : nil }

        // Everything before the first call block is the journey's own. The
        // bound matters: `Cancellation` is the same element at both scopes, so
        // a search across the whole body finds a cancelled *stop* and reports a
        // cancelled *run* — which is how 167 journeys that were running lost
        // every one of their vehicles at ingest.
        let callsBegin = min(recordedAt ?? body.upperBound, estimatedAt ?? body.upperBound)
        let head = body.lowerBound..<callsBegin
        let runCancelled = contains(raw, head, Self.tags.cancellation)
        let runIsExtra = contains(raw, head, Self.tags.extraJourney)

        if let recordedAt {
            let end = estimatedAt ?? body.upperBound
            forEachBlock(raw, recordedAt..<end, Self.tags.recordedCall) { range in
                if let stop = parseCall(raw, range, recorded: true) { add(stop.call, viaSupplement: stop.viaSupplement) }
            }
        }
        if let estimatedAt {
            forEachBlock(raw, estimatedAt..<body.upperBound, Self.tags.estimatedCall) { range in
                if let stop = parseCall(raw, range, recorded: false) { add(stop.call, viaSupplement: stop.viaSupplement) }
            }
        }
        Self.dropImpossiblePlacements(&stops, &supplement, mode: mode)
        guard stops.count >= 2 else { return nil }

        // Times must be non-decreasing or the interpolation can run backwards.
        // A recorded call and the forecast that follows it are produced by
        // different systems and can disagree by a few seconds across the join.
        for i in 1..<stops.count {
            if stops[i].arr < stops[i - 1].dep { stops[i].arr = stops[i - 1].dep }
            if stops[i].dep < stops[i].arr { stops[i].dep = stops[i].arr }
        }

        let category = text(raw, body, Self.tags.productCategory)
            .flatMap { $0.split(separator: ":").last.map(String.init) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let line = text(raw, body, Self.tags.publishedLine) ?? category ?? "?"

        // The journey reference is stable for the vehicle's whole run and
        // unique across the country, which is what the old
        // operator|trip|destination key was only approximating — and it needs
        // no splicing, because the call list is already complete.
        guard let id = text(raw, body, Self.tags.datedRef) else { return nil }

        let operatorRef = text(raw, body, Self.tags.operatorRef)
        // The reported delay is the one that matters now: at the next call it
        // has not yet made.
        let next = stops.first { !$0.observed && $0.delay != nil }

        return Journey(
            id: id,
            mode: mode,
            category: category,
            line: line,
            number: text(raw, body, Self.tags.trainNumber),
            // Named if the register can name it, otherwise omitted — never the
            // raw `ch:1:sboid:100015`, which reads as a fault rather than an
            // operator.
            operatorName: operatorName(operatorRef),
            operatorFull: operatorFullName(operatorRef),
            to: text(raw, body, Self.tags.direction) ?? stops[stops.count - 1].name,
            from: text(raw, body, Self.tags.origin) ?? stops[0].name,
            delay: next?.delay,
            start: stops[0].dep,
            end: stops[stops.count - 1].arr,
            // Whether the feed says this really is the whole run. It almost
            // always is, and saying so is what lets the panel stop hedging
            // about where a vehicle started.
            complete: text(raw, body, Self.tags.completeSequence) == "true",
            monitored: text(raw, body, Self.tags.monitored) == "true",
            cancelled: runCancelled,
            source: "siri",
            stops: stops,
            extra: runIsExtra
        )
    }

    /// One call, from either a RecordedCall or an EstimatedCall.
    ///
    /// The two differ only in which times they carry: a recorded call has
    /// happened, so it reports what was `Actual`; an estimated one has not, so
    /// it reports what is `Expected`. Both keep the `Aimed` times, which is
    /// what makes a delay computable per stop rather than per journey.
    private func parseCall(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, recorded: Bool
    ) -> (call: Call, viaSupplement: Bool)? {
        guard let ref = text(raw, range, Self.tags.stopPointRef) else { return nil }

        let aimedArrival = instant(raw, range, Self.tags.aimedArrival)
        let aimedDeparture = instant(raw, range, Self.tags.aimedDeparture)
        // The real-time value, where there is one — kept apart from the aimed
        // time rather than merged, because a delay is the difference between
        // them and collapsing the two first makes every delay read as zero.
        let realArrival = instant(raw, range, recorded ? Self.tags.actualArrival : Self.tags.expectedArrival)
        let realDeparture = instant(raw, range, recorded ? Self.tags.actualDeparture : Self.tags.expectedDeparture)

        let arrival = realArrival ?? aimedArrival
        let departure = realDeparture ?? aimedDeparture
        guard arrival != nil || departure != nil else { return nil }

        // The platform the feed prints for this call, which is also how a call
        // that names only its station is resolved the rest of the way. Read
        // before the place for exactly that reason.
        let stated = text(raw, range, Self.tags.departurePlatform) ?? text(raw, range, Self.tags.arrivalPlatform)
        let stopName = text(raw, range, Self.tags.stopPointName)

        // The name travels too, because for a foreign station whose UIC the two
        // sources spell differently it is the only thing left to join on.
        guard let place = resolve(ref, stated, stopName) else { return nil }

        // A call often carries a real-time value for only one of its two times:
        // a terminus has no departure, an origin no arrival. Whichever half the
        // feed actually reports on is the one that carries the delay.
        let lateness: Int?
        if let realArrival, let aimedArrival {
            lateness = realArrival - aimedArrival
        } else if let realDeparture, let aimedDeparture {
            lateness = realDeparture - aimedDeparture
        } else {
            lateness = nil
        }

        return (Call(
            key: "\(ref)|\(text(raw, range, Self.tags.visitNumber) ?? "")",
            ref: ref,
            name: stopName ?? place.name,
            lat: place.lat,
            lon: place.lon,
            // Prefer the platform the feed states for this call; the register's
            // own platform_code is a fallback for station-level references.
            platform: stated ?? place.platform,
            precise: place.precise,
            arr: arrival ?? departure!,
            dep: departure ?? arrival!,
            delay: Self.reportableDelay(lateness),
            observed: recorded,
            note: text(raw, range, Self.tags.callNote),
            sched: aimedDeparture ?? aimedArrival,
            assigned: place.assigned,
            // Sought within this call only, which is what separates the two
            // scopes the one element is used at.
            cancelled: contains(raw, range, Self.tags.cancellation),
            extra: contains(raw, range, Self.tags.extraCall)
        ), place.fromSupplement)
    }

    /// Beyond this a stated delay is not a delay.
    ///
    /// The feed sometimes reports an aimed time from a different service day
    /// than the expected one: PostAuto's 421 to Siat is aimed 15:34 and expected
    /// 02:15 the next morning, and the arithmetic between them is 641 minutes.
    /// Printed as `+653` beside every call it reads as a fault in the app, and
    /// it is a claim nobody believes — no Swiss bus is eleven hours late.
    ///
    /// Only the *badge* is suppressed. The expected times are what the map draws
    /// and they stay exactly as the feed states them; what is dropped is the
    /// subtraction between two numbers that turn out not to be about the same
    /// run.
    static let implausibleDelayMinutes = 180

    /// The delay for a call, or nil where the two times are not about the same
    /// run.
    ///
    /// Only implausibility is filtered here, not size. Whether a one-minute
    /// delay is worth printing is a question for whatever draws the board — see
    /// `Format.delay` — while whether an eleven-hour one is *true* is a question
    /// about the data, and this is where the data is read.
    static func reportableDelay(_ seconds: Int?) -> Int? {
        guard let seconds else { return nil }
        let minutes = Int((Double(seconds) / 60).rounded())
        guard abs(minutes) <= implausibleDelayMinutes else { return nil }
        return minutes
    }

    // MARK: - Impossible placements

    /// Straight-line speed above which a placement is not a train but a
    /// mistake, in metres per second.
    ///
    /// Still generous, and measured rather than guessed. Straight-line
    /// distance under-reads the track, so a call implying 300 km/h as the crow
    /// flies implies more than that on the rails — and the fastest scheduled
    /// service in Europe, the TGV over Paris–Lyon, averages about 205 km/h
    /// station to station. Nothing legitimate comes near this.
    ///
    /// It was 400 for one draft, which let two of the offenders through: Imst-
    /// Pitztal to a "Wörgl Hbf" that is really Wien Leopoldau implies 353 km/h,
    /// and Bad Gastein to a "Schwarzach-St.Veit" that is really Lebring, 394.
    /// Both are plainly wrong and both sat under the old bar.
    static func speedCeiling(_ mode: Mode) -> Double {
        mode == .train ? 300 / 3.6 : 200 / 3.6
    }

    /// Below this a placement is not worth doubting: short hops with coarse
    /// times produce silly speeds for entirely ordinary reasons.
    static let suspiciousDistance = 25_000.0

    /// Drop calls the OSM supplement placed somewhere the vehicle cannot have
    /// been.
    ///
    /// Austria runs two UIC numbering schemes and the feed and OpenStreetMap
    /// are on different ones, so the id join can *succeed with the wrong
    /// station*: `8101223` is Langen am Arlberg to the feed and Lambach Markt
    /// to OSM, 320 km away. That drew an EC to Innsbruck as a zig-zag across
    /// Austria — "Bludenz → Langen am Arlberg, 321 km in 24 minutes".
    ///
    /// Name comparison cannot settle it, because the supplement is also right
    /// under a different name: `Ústí nad Labem hl. n.` is `Aussig
    /// Hauptbahnhof` and `Děčín` is `Tetschen`, both correctly placed. So the
    /// test is physical rather than lexical — a call implying a speed no train
    /// reaches is wrong whatever it is called.
    ///
    /// Only supplement-placed calls are ever dropped, and they are dropped one
    /// at a time worst-first, so a correct call sitting next to a wrong one is
    /// vindicated as soon as its neighbour goes rather than condemned with it.
    /// A dropped call is the register's existing failure mode and the app
    /// already handles it; a call in the wrong country is not.
    static func dropImpossiblePlacements(_ stops: inout [Call], _ supplement: inout [Bool], mode: Mode) {
        guard supplement.contains(true), stops.count >= 2 else { return }
        let ceiling = speedCeiling(mode)

        while stops.count >= 2 {
            var worstIndex = -1
            var worstSpeed = ceiling

            for i in 0..<stops.count where supplement[i] {
                var implied = 0.0
                for neighbour in [i - 1, i + 1] where neighbour >= 0 && neighbour < stops.count {
                    let a = stops[min(i, neighbour)], b = stops[max(i, neighbour)]
                    let gap = Geo.metres(a.lon, a.lat, b.lon, b.lat)
                    guard gap > suspiciousDistance else { continue }
                    let seconds = max(60, b.arr - a.dep)
                    implied = max(implied, gap / Double(seconds))
                }
                if implied > worstSpeed {
                    worstSpeed = implied
                    worstIndex = i
                }
            }

            guard worstIndex >= 0 else { return }
            stops.remove(at: worstIndex)
            supplement.remove(at: worstIndex)
        }
    }

    // MARK: - Tag reading

    /// First text child of `tag`, within `range`. Attributes never appear on
    /// the elements this reads.
    private func text(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag) -> String? {
        guard let body = tagRange(raw, range, tag) else { return nil }
        let value = String(decoding: UnsafeRawBufferPointer(rebasing: raw[body]), as: UTF8.self)
        return ByteScan.decodeEntities(value)
    }

    private func instant(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag) -> Timestamp? {
        guard let body = tagRange(raw, range, tag) else { return nil }
        return ByteScan.parseInstant(raw, body)
    }

    /// Whether `needle` occurs inside `range`.
    ///
    /// `ByteScan.find` runs to the end of the buffer, so the upper bound has to
    /// be applied to its answer rather than to its search — the same shape the
    /// tag readers use, and the thing the journey-level cancellation check was
    /// missing.
    private func contains(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ needle: ByteScan.Needle
    ) -> Bool {
        guard let at = ByteScan.find(needle, in: raw, from: range.lowerBound) else { return false }
        return at < range.upperBound
    }

    private func tagRange(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag) -> Range<Int>? {
        guard let start = ByteScan.find(tag.open, in: raw, from: range.lowerBound), start < range.upperBound,
              let end = ByteScan.find(tag.close, in: raw, from: start), end < range.upperBound
        else { return nil }
        return (start + tag.openLength)..<end
    }

    /// Everything between `<name>` and `</name>`, repeated.
    private func forEachBlock(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag,
        _ body: (Range<Int>) -> Void
    ) {
        var at = range.lowerBound
        while true {
            guard let start = ByteScan.find(tag.open, in: raw, from: at), start < range.upperBound,
                  let end = ByteScan.find(tag.close, in: raw, from: start), end < range.upperBound
            else { return }
            body((start + tag.openLength)..<end)
            at = end + tag.closeLength
        }
    }
}

/// Read a snapshot that is already complete, across every core there is.
///
/// The streaming parser above exists for the response as it arrives, one chunk
/// at a time, and it is the right shape for that. A snapshot on disk is a
/// different problem with a different answer: the whole file is there, so it
/// need not be copied into the parser's buffer to be read, and it need not be
/// read one journey after another either.
///
/// Both of those cost real time on a phone. The launch path mapped 150 MB and
/// then appended it to a `[UInt8]` — a second copy of the file, and a second
/// 150 MB of memory to hold it — before scanning it on one core. Reading the
/// mapped pages in place, split at journey boundaries across the cores the
/// device has, is the same work done once and in parallel.
public enum SnapshotReader {
    /// Never split a small file: the fixed cost of a worker is not worth
    /// paying to halve something already fast.
    static let minimumPerWorker = 8 << 20

    /// Parse the whole of `data` and return the journeys by id.
    ///
    /// `makeParser` is called once per worker, because a parser carries its own
    /// counters. Everything a parser reaches into — the stop register, the
    /// operator table — is loaded before this runs and never written during it.
    public static func parse(
        _ data: Data, workers: Int = ProcessInfo.processInfo.activeProcessorCount,
        makeParser: () -> SiriParser
    ) -> (journeys: [String: Journey], summary: SiriParser.Summary) {
        guard !data.isEmpty else { return ([:], SiriParser.Summary()) }

        let count = max(1, min(workers, data.count / minimumPerWorker))
        var found: [String: Journey] = [:]
        var summary = SiriParser.Summary()

        let parsers = (0..<count).map { _ in makeParser() }
        var harvested = [[Journey]](repeating: [], count: count)

        data.withUnsafeBytes { raw in
            let bounds = boundaries(raw, count: count)
            harvested.withUnsafeMutableBufferPointer { slots in
                // Each worker owns one slot, so the writes never meet.
                let into = slots.baseAddress!
                func run(_ worker: Int) {
                    var mine: [Journey] = []
                    mine.reserveCapacity(20_000 / count)
                    parsers[worker].scan(
                        raw, from: bounds[worker], upTo: bounds[worker + 1]
                    ) { mine.append($0) }
                    into[worker] = mine
                }
                if count == 1 {
                    run(0)
                } else {
                    DispatchQueue.concurrentPerform(iterations: count) { run($0) }
                }
            }
        }

        for (worker, journeys) in harvested.enumerated() {
            let their = parsers[worker].summary
            summary.seen += their.seen
            summary.placed += their.placed
            summary.unresolved += their.unresolved
            // Whole runs only; a journey that merely skips a stop is running.
            for journey in journeys where !journey.cancelled { found[journey.id] = journey }
        }
        return (found, summary)
    }

    /// `count + 1` offsets, each on the start of a journey, so no journey is
    /// split between two workers or read by both.
    private static func boundaries(_ raw: UnsafeRawBufferPointer, count: Int) -> [Int] {
        let open = ByteScan.Needle("<EstimatedVehicleJourney>")
        var cuts = [0]
        for worker in 1..<max(1, count) {
            let wanted = raw.count / count * worker
            // The next journey to start at or after the nominal split — and
            // never before the previous cut, which would parse one twice.
            let at = ByteScan.find(open, in: raw, from: max(wanted, cuts[cuts.count - 1])) ?? raw.count
            cuts.append(at)
        }
        cuts.append(raw.count)
        return cuts
    }
}
