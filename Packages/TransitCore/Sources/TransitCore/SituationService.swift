import Foundation

/// Disruption notices, from both halves of SIRI-SX, indexed for the two
/// questions the app actually asks: what is wrong with this vehicle, and what
/// is wrong at this stop.
///
/// The two feeds are polled on very different cycles because they are very
/// different things. The incident wire is 330 kB and changes by the minute, so
/// it is asked for often; the works catalogue is 113 MB and changes by the
/// week, so it is asked for four times a day. Both come out of one subscription
/// and one budget — 3,000 calls a day — which at these intervals is spent to
/// about a quarter.
public actor SituationService {
    /// How often the incident wire is re-read.
    static let unplannedInterval: TimeInterval = 120
    /// How often the works catalogue is. 113 MB is not a thing to fetch on a
    /// timer that means anything smaller.
    static let plannedInterval: TimeInterval = 6 * 3600

    /// Whether to fetch the planned half at all. Off.
    ///
    /// The works catalogue is engineering notices — a bridge renewal booked for
    /// three weekends in November — and measured live it is **4.26 MB on the
    /// wire, inflating to 112 MB of XML for 1,340 situations**, four times a
    /// day: 17 MB daily, and the single largest recurring download left in the
    /// app now that the timetable is on the device.
    ///
    /// It is off because it does not answer either question this service
    /// exists for. "What is wrong with this vehicle" and "what is wrong at this
    /// stop" are both about now, and a planned possession three weeks out is
    /// neither. The incident wire — 30 KB, and the half that is actually about
    /// today — is unaffected and keeps running.
    public private(set) var includesPlanned = false

    /// Turn the works catalogue on or off.
    ///
    /// Turning it off drops what it contributed rather than leaving a stale
    /// catalogue indexed against vehicles for the rest of the session — and
    /// clears it from the stored copy, so it does not come back on the next
    /// launch through `keepAnswers`. Turning it on clears the timer so the next
    /// refresh fetches immediately rather than waiting out a six-hour interval
    /// that never started.
    public func setIncludesPlanned(_ on: Bool) {
        guard on != includesPlanned else { return }
        includesPlanned = on
        plannedAt = nil
        if !on {
            planned = []
            reindex()
            save()
        }
    }

    private var client: OTDClient?
    /// Turns a notice's `OperatorRef` into the name the fleet knows the
    /// operator by.
    ///
    /// Resolved here rather than carried on the vehicle: `Journey` keeps the
    /// operator's *name*, having thrown the ref away as soon as it was named,
    /// and adding the ref back would mean widening the journey, the snapshot
    /// and the on-disk fleet format for one join. Both sides are named by the
    /// same register, so where it cannot name one it cannot name the other
    /// either and the two fail together rather than mismatching.
    private var operatorName: @Sendable (String?) -> String? = { _ in nil }
    /// Unplanned first, so a live incident outranks a works notice wherever
    /// only one line can be shown.
    private var situations: [Situation] = []
    private var unplanned: [Situation] = []
    private var planned: [Situation] = []

    private var byJourney: [String: [Int]] = [:]
    private var byStopPlace: [String: [Int]] = [:]
    /// Keyed on `line|operatorRef`, because a line number alone is not unique
    /// across the country. See `Situation.operators`.
    private var byLine: [String: [Int]] = [:]

    private var unplannedAt: Date?
    private var plannedAt: Date?
    private var store: URL?

    public private(set) var lastError: String?
    public private(set) var counts = Counts()

    public struct Counts: Sendable, Equatable {
        public var unplanned = 0
        public var planned = 0
        public var journeysCovered = 0
        public var stopsCovered = 0
    }

    public init(token: String? = nil) {
        if let token, !token.isEmpty { client = OTDClient(token: token, budget: "siri-sx") }
    }

    public func configure(token: String?) {
        guard let token, !token.isEmpty else { client = nil; return }
        client = OTDClient(token: token, budget: "siri-sx")
    }

    /// Wire in the operator register. Re-indexes, because the line join cannot
    /// be built until refs can be named.
    public func nameOperators(with resolve: @escaping @Sendable (String?) -> String?) {
        operatorName = resolve
        reindex()
    }

    public var isConfigured: Bool { client != nil }

    // MARK: - Asking

    /// Everything wrong with one vehicle at one moment.
    ///
    /// Explicit journey references take precedence. Otherwise, every supplied
    /// stop, line and operator restriction must agree: sharing Bern does not
    /// make an RE1 affected by works on S5/S52. Line-only notices are qualified
    /// by operator because published line numbers are not nationally unique.
    public func forVehicle(
        id: String, parts: [String] = [], line: String, operatorName: String?,
        stopRefs: [String], journeyRefs: [String] = [], at moment: Timestamp
    ) -> [Situation] {
        let journeys = Set([id] + parts + journeyRefs)
        let stops = Set(stopRefs.map { StopRegister.stationOf($0) })
        var exact = Set<Int>()
        for journey in journeys { exact.formUnion(byJourney[journey] ?? []) }
        var candidates = exact
        for ref in stops { candidates.formUnion(byStopPlace[ref] ?? []) }
        if let operatorName { candidates.formUnion(byLine["\(line)|\(operatorName)"] ?? []) }
        let found = candidates.filter { index in
            let notice = situations[index]
            if !notice.journeys.isEmpty { return exact.contains(index) }
            if !notice.lines.isEmpty && !notice.lines.contains(line) { return false }
            if !notice.operators.isEmpty {
                guard let operatorName,
                      notice.operators.contains(where: { self.operatorName($0) == operatorName })
                else { return false }
            }
            return notice.stopPlaces.isEmpty || notice.stopPlaces.contains {
                stops.contains(StopRegister.stationOf($0))
            }
        }
        return resolve(found, at: moment)
    }

    /// Everything wrong at one stop. The board's question, and the one join
    /// that is exact for both feeds.
    public func forStop(ref: String, at moment: Timestamp) -> [Situation] {
        resolve(Set(byStopPlace[StopRegister.stationOf(ref)] ?? []), at: moment)
    }

    /// Every stop place the index holds. For diagnostics and for tests that
    /// want to ask a question they know has an answer.
    public func indexedStopPlaces() -> [String] { Array(byStopPlace.keys) }

    private func resolve(_ indices: Set<Int>, at moment: Timestamp) -> [Situation] {
        indices
            .compactMap { situations.indices.contains($0) ? situations[$0] : nil }
            .filter { $0.isActive(at: moment) }
            // Live incidents before planned works; then the most recently
            // revised, which is the one most likely to be about right now.
            .sorted {
                $0.planned != $1.planned ? !$0.planned : ($0.updated ?? 0) > ($1.updated ?? 0)
            }
    }

    // MARK: - Fetching

    /// Bring both halves up to date, each on its own cycle.
    ///
    /// Returns whether anything changed, so a caller can avoid rebuilding a
    /// view for a refresh that found the same notices as last time.
    ///
    /// `allowPlanned` is the launch valve. The works catalogue is 4 MB on the
    /// wire and ~113 MB of XML to parse, and a session used to pay that on
    /// every cold start because the timers were not restored. The map does
    /// not need it to open; the caller lets this through once the first frame
    /// is up and the radio is cheap.
    @discardableResult
    public func refresh(
        now: Date = Date(), force: Bool = false, allowPlanned: Bool = true
    ) async -> Bool {
        guard client != nil else { return false }
        var changed = false

        if force || unplannedAt.map({ now.timeIntervalSince($0) >= Self.unplannedInterval }) ?? true {
            if let fresh = await load(OTDClient.siriSxUnplanned, planned: false, now: now) {
                changed = changed || fresh != unplanned
                unplanned = fresh
                unplannedAt = now
            }
        }
        if includesPlanned, allowPlanned,
           force || plannedRefreshDue(at: now) {
            if let fresh = await load(OTDClient.siriSx, planned: true, now: now) {
                changed = changed || fresh != planned
                planned = fresh
                plannedAt = now
            }
        }

        if changed { reindex(); save() }
        return changed
    }

    /// Whether the six-hour works catalogue is due another download.
    public func plannedRefreshDue(at now: Date = Date()) -> Bool {
        plannedAt.map { now.timeIntervalSince($0) >= Self.plannedInterval } ?? true
    }

    private func load(_ api: OTDClient.API, planned: Bool, now: Date) async -> [Situation]? {
        guard let client else { return nil }
        guard !Task.isCancelled else { return nil }
        let parser = SituationParser(planned: planned, now: Timestamp(now.timeIntervalSince1970))
        let collector = SituationCollector()

        do {
            try await client.stream(api, maxWait: 30) { chunk in
                collector.consume(chunk, parser: parser)
            }
        } catch is CancellationError {
            // Leaving the scene is not a failed refresh. `ChunkedDownload`
            // has already cancelled the transfer and drained/skipped parser
            // work before returning this cancellation.
            return nil
        } catch {
            lastError = String(describing: error)
            return nil
        }
        guard !Task.isCancelled else { return nil }
        collector.finish(parser: parser)
        lastError = nil
        return collector.take()
    }

    private func reindex() {
        // Unplanned first: `resolve` sorts, but the order here is what decides
        // which duplicate wins when the same notice is somehow in both.
        situations = unplanned + planned
        byJourney = [:]
        byStopPlace = [:]
        byLine = [:]

        for (index, situation) in situations.enumerated() {
            for journey in situation.journeys { byJourney[journey, default: []].append(index) }
            for stop in situation.stopPlaces {
                byStopPlace[StopRegister.stationOf(stop), default: []].append(index)
            }
            // Every line against every operator the notice names. Both lists
            // are short — one or two each — so the cross product is small and
            // it avoids having to pair them positionally, which the feed does
            // not promise.
            for line in situation.lines {
                for named in situation.operators.compactMap({ operatorName($0) }) {
                    byLine["\(line)|\(named)", default: []].append(index)
                }
            }
        }

        counts = Counts(
            unplanned: unplanned.count, planned: planned.count,
            journeysCovered: byJourney.count, stopsCovered: byStopPlace.count
        )
    }

    // MARK: - Between launches

    /// Keep the notices on disk, so a launch has something to say before the
    /// first fetch answers.
    public func keepAnswers(in directory: URL) {
        store = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        guard let file = store?.appendingPathComponent("situations.json"),
              let data = try? Data(contentsOf: file),
              let held = try? JSONDecoder().decode(Held.self, from: data)
        else { return }

        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        unplanned = held.unplanned
        // Restored, so a force-quit five minutes later does not spend another
        // request on incidents the file already holds. The two-minute cadence
        // still fires once the stamp is old.
        unplannedAt = held.unplannedAt ?? modified
        // Only if it is wanted. A stored catalogue from a session when this was
        // on would otherwise be silently indexed on every later launch, which
        // is the toggle appearing not to work.
        if includesPlanned {
            planned = held.planned
            // Six hours, and the whole point of keeping the catalogue on disk.
            // Without this stamp a launch always treated the works feed as due
            // and parsed 113 MB of XML in front of a map that had already
            // opened — the minute or two that a cold start seemed to hang
            // after the curtain dropped.
            plannedAt = held.plannedAt ?? modified
        } else {
            planned = []
            plannedAt = nil
            if !held.planned.isEmpty { save() }
        }
        reindex()
    }

    private struct Held: Codable {
        var unplanned: [Situation]
        var planned: [Situation]
        var unplannedAt: Date?
        var plannedAt: Date?
    }

    private func save() {
        guard let file = store?.appendingPathComponent("situations.json"),
              let data = try? JSONEncoder().encode(
                Held(
                    unplanned: unplanned, planned: planned,
                    unplannedAt: unplannedAt, plannedAt: plannedAt
                )
              )
        else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// Accumulates notices while the response streams, off the actor.
///
/// The same shape as `JourneyCollector`, and for the same reason: the chunk
/// handler is called on URLSession's queue and the parser is not an actor.
final class SituationCollector: @unchecked Sendable {
    private var found: [Situation] = []
    private let lock = NSLock()

    func consume(_ chunk: Data, parser: SituationParser) {
        lock.withLock { parser.consume(chunk) { found.append($0) } }
    }

    func finish(parser: SituationParser) {
        lock.withLock { parser.finish { found.append($0) } }
    }

    func take() -> [Situation] { lock.withLock { found } }
}
