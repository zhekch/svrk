import Foundation

/// The operating run behind a board row. Display labels (PEGPX/GPX4068,
/// PEGEX/GEX, BAT3623/3623) are deliberately absent from its identity.
public struct BoardRunIdentity: Sendable, Equatable {
    public struct CallIdentity: Sendable, Equatable {
        public var station: String
        public var departure: Timestamp
    }

    public private(set) var references: Set<String>
    private var workings: Set<String>
    private var courseNumbers: Set<String>
    public var station: String
    public var scheduledDeparture: Timestamp
    public var operatorName: String?
    public var product: String
    public var onward: [CallIdentity]
    public var timetabled: Bool
    public var source: String

    /// The identifier live services know this run by. A timetable row
    /// (`tt:41903`) is this app's index and OJP has never heard of it.
    public var publishedJourneyRef: String? {
        Self.publishedJourneyRef(in: references)
    }

    /// Prefer a Swiss Journey ID, then any other non-timetable alias.
    public static func publishedJourneyRef(in references: Set<String>) -> String? {
        let usable = references.filter { !$0.isEmpty && !$0.hasPrefix("tt:") }
        if let sjyid = usable.filter({ $0.lowercased().contains(":sjyid:") }).sorted().first {
            return sjyid
        }
        return usable.sorted().first
    }

    public static func publishedJourneyRef(id: String?) -> String? {
        publishedJourneyRef(in: Set([id].compactMap { $0 }))
    }

    public init(journey: Journey, at index: Int) {
        let call = journey.stops[index]
        station = Self.station(of: call)
        scheduledDeparture = call.sched ?? call.dep
        operatorName = journey.operatorName.map(Self.operatorKey)
        product = Journey.publishedLine(journey.line, mode: journey.mode)
        timetabled = journey.isTimetabled
        source = journey.source
        references = Set([journey.id, journey.journeyRef].compactMap { $0 }.filter { !$0.isEmpty })
        // At a renumbering junction the departing leg owns the call. Claiming
        // every part would also claim unrelated departures on the arriving leg.
        if let part = journey.parts?.last(where: { $0.start <= index && index <= $0.end }) {
            references.formUnion([part.id, part.journeyRef].compactMap { $0 })
        }
        workings = Set(references.compactMap(Self.working))
        courseNumbers = Set(workings.compactMap { $0.split(separator: ":").last.map(String.init) })
        if let number = journey.trainNumber { courseNumbers.insert(number) }
        onward = journey.stops[index...].map {
            CallIdentity(station: Self.station(of: $0), departure: $0.sched ?? $0.dep)
        }
    }

    /// HAFAS appends a transport qualifier to registered operators, e.g.
    /// FART Aut / FART and SVB Auto / SVB. It is not another company.
    private static func operatorKey(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        if let suffix = words.last?.lowercased(), ["aut", "auto"].contains(suffix) {
            words.removeLast()
        }
        return Reconcile.fold(words.joined(separator: " "))
    }

    static func station(of call: Call) -> String {
        if let ref = call.ref, !ref.isEmpty {
            return StopRegister.stationOf(StopRegister.sloid(forDidok: ref) ?? ref)
        }
        return "name:" + Reconcile.fold(call.name)
    }

    /// Preserve the operator and course number across numeric and SKI SJYIDs.
    /// Variant suffixes are removed; ServiceJourney UUIDs remain opaque.
    private static func working(_ ref: String) -> String? {
        let pieces = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 5, pieces[2].lowercased() == "sjyid" else { return nil }
        let tail = pieces[4].hasPrefix("SKI-") ? pieces[4].dropFirst(4) : pieces[4][...]
        guard let number = tail.split(separator: "-", maxSplits: 1).first,
              !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return "\(pieces[3]):\(Journey.trimZeros(String(number)))"
    }

    mutating func includeAliases(of other: Self) {
        references.formUnion(other.references)
        workings.formUnion(other.workings)
        courseNumbers.formUnion(other.courseNumbers)
    }

    public func matches(_ other: Self) -> Bool {
        guard station == other.station,
              abs(scheduledDeparture - other.scheduledDeparture) <= 30 else { return false }
        if !references.isDisjoint(with: other.references) {
            return onward.count == 1 || other.onward.count == 1 || compatibleOnward(with: other)
        }
        let ours = workings, theirs = other.workings
        if !ours.isEmpty, !theirs.isEmpty, !ours.isDisjoint(with: theirs) {
            return compatibleOnward(with: other)
        }
        if !courseNumbers.isEmpty, !other.courseNumbers.isEmpty {
            // Two explicit, different course numbers are two real vehicles,
            // even if they share a line, destination, platform and minute.
            if courseNumbers.isDisjoint(with: other.courseNumbers) { return false }
            // The same numbered through-train is often filed twice: RhB and
            // MGB each publish Glacier Express 901, and the live feed names
            // one operator while the timetable names the other.
            if operatorsAgree(with: other) || panoramaAgrees(with: other) {
                return compatibleOnward(with: other)
            }
            return false
        }
        // Different feed namespaces, or a missing course on one side. A
        // shared corridor and minute is not enough: IR38 and GEX leave
        // St. Moritz together. The advertised product has to agree, and a
        // destination/line resemblance still needs booked calls.
        guard compatibleOnward(with: other), productsAgree(with: other),
              operatorsAgree(with: other) || panoramaAgrees(with: other) else { return false }
        let shorter = onward.count <= other.onward.count ? onward : other.onward
        let longer = onward.count <= other.onward.count ? other.onward : onward
        guard shorter.count >= 2 else { return false }
        var cursor = 0
        for call in shorter {
            guard let match = longer[cursor...].firstIndex(where: {
                $0.station == call.station && abs($0.departure - call.departure) <= 60
            }) else { return false }
            cursor = match + 1
        }
        return true
    }

    private func operatorsAgree(with other: Self) -> Bool {
        guard let operatorName, !operatorName.isEmpty else { return false }
        return operatorName == other.operatorName
    }

    private func productsAgree(with other: Self) -> Bool {
        !product.isEmpty && product == other.product
    }

    private func panoramaAgrees(with other: Self) -> Bool {
        productsAgree(with: other)
            && Journey.isPanoramaProduct(product)
            && Journey.isPanoramaProduct(other.product)
    }

    /// A border-truncated run can be a prefix of the complete run; diverging
    /// split destinations cannot. Intermediate operating points may be omitted.
    func compatibleOnward(with other: Self) -> Bool {
        guard let last = onward.last?.station, let otherLast = other.onward.last?.station else { return false }
        if last == otherLast { return true }
        let shorter = onward.count <= other.onward.count ? onward : other.onward
        let longer = onward.count <= other.onward.count ? other.onward : onward
        guard shorter.count >= 2 else { return false }
        var cursor = 0
        for call in shorter {
            guard let match = longer[cursor...].firstIndex(where: { $0.station == call.station }) else { return false }
            cursor = match + 1
        }
        return true
    }
}
