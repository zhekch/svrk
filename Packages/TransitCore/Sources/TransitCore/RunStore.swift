import Foundation

/// Timetable and live observations resolve to operating runs here, before any board or
/// panel is built. Aliases are indexes, never additional journey records.
/// Booked calls scope every match: a reused feed ID tomorrow is another run.
final class RunStore {
    private struct Record {
        var journey: Journey
        var aliases: Set<String>
        var timetableLine: String?
        var supplemental: Bool
    }
    private struct Slot: Hashable {
        var mode: Mode
        var station: String
        var minute: Timestamp
    }
    private var records: [Int: Record] = [:]
    private var slots: [Slot: Set<Int>] = [:]
    private var aliases: [String: Set<Int>] = [:]
    private var nextID = 0

    var values: [Journey] { records.keys.sorted().compactMap { records[$0]?.journey } }
    var boardValues: [Journey] {
        records.keys.sorted().compactMap { records[$0].flatMap { $0.supplemental ? $0.journey : nil } }
    }

    func removeAll() {
        records.removeAll(); slots.removeAll(); aliases.removeAll(); nextID = 0
    }

    /// Camera/time-window refreshes must not erase live observations or alias
    /// resolution. Retain nearby occurrences, with a bound for long sessions.
    func prune(around time: Timestamp) {
        let keep = Set(records.keys.sorted().reversed().filter {
            guard let journey = records[$0]?.journey else { return false }
            return journey.end >= time - 86_400 && journey.start <= time + 2 * 86_400
        }.prefix(32_768))
        records = records.filter { keep.contains($0.key) }
        aliases = aliases.compactMapValues {
            let remaining = $0.intersection(keep)
            return remaining.isEmpty ? nil : remaining
        }
        slots = slots.compactMapValues {
            let remaining = $0.intersection(keep)
            return remaining.isEmpty ? nil : remaining
        }
    }

    static func matches(_ a: Journey, _ b: Journey) -> Bool {
        guard a.mode == b.mode, !a.stops.isEmpty, !b.stops.isEmpty else { return false }
        // One feed may begin at the queried stop; the other has the origin.
        let first = (a.stops[0].sched ?? a.stops[0].dep) >= (b.stops[0].sched ?? b.stops[0].dep) ? a : b
        let other = first === a ? b : a
        let identity = BoardRunIdentity(journey: first, at: 0)
        return other.stops.indices.contains {
            guard BoardRunIdentity.station(of: other.stops[$0]) == identity.station,
                  abs((other.stops[$0].sched ?? other.stops[$0].dep) - identity.scheduledDeparture) <= 30
            else { return false }
            return identity.matches(BoardRunIdentity(journey: other, at: $0))
        }
    }

    private func candidates(for journey: Journey) -> Set<Int> {
        guard !journey.stops.isEmpty else { return [] }
        var found = Set<Int>()
        for call in journey.stops {
            let station = BoardRunIdentity.station(of: call)
            let minute = (call.sched ?? call.dep) / 60
            for time in (minute - 1)...(minute + 1) {
                found.formUnion(slots[Slot(mode: journey.mode, station: station, minute: time)] ?? [])
            }
        }
        return found
    }

    func resolve(_ journey: Journey) -> Journey {
        let matches = candidates(for: journey).filter {
            records[$0].map { Self.matches(journey, $0.journey) } ?? false
        }
        guard matches.count == 1, let id = matches.first else { return journey }
        return records[id]!.journey
    }

    func journey(id: String, at time: Timestamp? = nil) -> Journey? {
        let found = (aliases[id] ?? []).compactMap { records[$0]?.journey }
        guard let time else { return found.count == 1 ? found[0] : nil }
        return found.min {
            distance(time, to: $0) < distance(time, to: $1)
        }
    }

    /// Every public name this occurrence has been seen under, including `id`.
    func allAliases(of id: String) -> Set<String> {
        var found: Set<String> = [id]
        for recordID in aliases[id] ?? [] {
            if let record = records[recordID] { found.formUnion(record.aliases) }
        }
        return found
    }

    /// Called only after Fleet has established a unique complete-route,
    /// booked-time replacement. Keep an already-open extra card and board rows
    /// resolving to the original record, including extras ingested before the
    /// timetable was expanded into this region.
    func registerReplacement(_ replacement: Journey, of original: Journey) {
        if !records.values.contains(where: { $0.journey === original }) { ingest(original) }
        guard let id = records.first(where: { $0.value.journey === original })?.key else { return }
        var record = records[id]!
        record.aliases.formUnion(Self.references(original))
        record.aliases.formUnion(Self.references(replacement))
        let duplicates = records.keys.filter { key in
            key != id && records[key]!.aliases.contains(replacement.id)
                && Reconcile.isPlatformReplacement(records[key]!.journey, of: original)
        }
        for key in duplicates {
            record.aliases.formUnion(records[key]!.aliases)
            record.supplemental = record.supplemental || records[key]!.supplemental
            records.removeValue(forKey: key)
        }
        records[id] = record
        let removed = Set(duplicates)
        aliases = aliases.compactMapValues {
            let remaining = $0.subtracting(removed)
            return remaining.isEmpty ? nil : remaining
        }
        slots = slots.compactMapValues {
            let remaining = $0.subtracting(removed)
            return remaining.isEmpty ? nil : remaining
        }
        for alias in record.aliases { aliases[alias, default: []].insert(id) }
    }

    private func distance(_ time: Timestamp, to journey: Journey) -> Timestamp {
        if journey.start <= time && time <= journey.end { return 0 }
        return min(abs(time - journey.start), abs(time - journey.end))
    }

    @discardableResult
    func ingest(_ incoming: Journey, supplemental: Bool = false) -> Journey {
        let matches = candidates(for: incoming).filter {
            records[$0].map { Self.matches(incoming, $0.journey) } ?? false
        }
        let id: Int
        if matches.count == 1, let existing = matches.first {
            id = existing
            var record = records[id]!
            record.supplemental = record.supplemental || supplemental
            let held = record.journey
            if incoming.isTimetabled { record.timetableLine = incoming.line }
            // A complete international route wins over a truncated timetable;
            // within the same coverage, live OJP data wins over mirror/plan.
            let incomingWins: Bool
            if incoming.source != "mirror", held.source != "mirror",
               incoming.stops.count != held.stops.count {
                incomingWins = incoming.stops.count > held.stops.count
            } else {
                incomingWins = Self.priority(incoming) >= Self.priority(held)
            }
            if incomingWins {
                // A feed refresh replaces observations, not the route already
                // built for these same calls. Both timetable re-expansion and
                // live aliases usually arrive without geometry.
                if incoming.geometry == nil, let geometry = held.geometry,
                   Self.sameGeometryCalls(held.stops, incoming.stops) {
                    incoming.geometry = geometry
                    incoming.legsFromRoute = held.legsFromRoute
                    incoming.legsFromGraph = held.legsFromGraph
                }
                if incoming.journeyRef == nil { incoming.journeyRef = held.journeyRef }
                record.journey = incoming
            } else if held.isTimetabled && !incoming.isTimetabled {
                // A mirror estimate can enrich a plan without replacing its
                // complete route, stable platform refs or published line.
                _ = held.apply(JourneyTiming(liveBoardJourney: incoming), at: incoming.start)
            }
            if record.journey.journeyRef == nil { record.journey.journeyRef = incoming.journeyRef }
            record.aliases.formUnion(Self.references(incoming))
            // The timetable supplies the advertised service, while TrainNumber
            // identifies its occurrence. Never append that number to IRLEX,
            // GPX, etc. merely because a stop feed spells the badge differently.
            if let line = record.timetableLine { record.journey.line = line }
            records[id] = record
        } else {
            // Ambiguous lookalikes remain distinct; never pick the first one.
            id = nextID; nextID += 1
            records[id] = Record(journey: incoming, aliases: Self.references(incoming),
                                 timetableLine: incoming.isTimetabled ? incoming.line : nil,
                                 supplemental: supplemental)
        }
        let record = records[id]!
        for alias in record.aliases { aliases[alias, default: []].insert(id) }
        for call in incoming.stops {
            slots[Slot(mode: incoming.mode, station: BoardRunIdentity.station(of: call),
                       minute: (call.sched ?? call.dep) / 60), default: []].insert(id)
        }
        return record.journey
    }

    private static func sameGeometryCalls(_ lhs: [Call], _ rhs: [Call]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            BoardRunIdentity.station(of: a) == BoardRunIdentity.station(of: b)
                && a.platform == b.platform
                && (a.lon * 100_000).rounded() == (b.lon * 100_000).rounded()
                && (a.lat * 100_000).rounded() == (b.lat * 100_000).rounded()
        }
    }

    private static func references(_ journey: Journey) -> Set<String> {
        Set([journey.id, journey.journeyRef].compactMap { $0 }.filter { !$0.isEmpty })
    }

    private static func priority(_ journey: Journey) -> Int {
        if journey.source == "ojp" { return 4 }
        if journey.monitored { return 3 }
        if journey.isTimetabled { return 2 }
        return 1
    }
}
