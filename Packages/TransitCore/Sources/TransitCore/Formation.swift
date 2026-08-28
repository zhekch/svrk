import Foundation

// The train itself: which coaches are on it, in which order, and where each one
// stops on the platform.
//
// This comes from a different interface to everything else in this module.
// SIRI-ET describes a *journey* — where the vehicle is and when it calls — and
// says nothing at all about what the vehicle is made of. The formation service
// answers the other half: sixteen coaches, the restaurant is the ninth, the
// wheelchair space is in coach 5, and at Bern that coach stops in sector C.
//
// Two things about it are worth knowing before reading any of the rest.
//
// **It is keyed by train number, not by journey id.** The feed identifies a run
// as `ch:1:sjyid:100015:2806-001`; the formation service wants `evu=BLSP,
// trainNumber=2806`. Both halves of that are inside the journey id, which is
// why no new field had to be carried through the fleet to ask the question —
// see `FormationKey.init(journeyID:)`.
//
// **The order is the direction of travel.** Nothing in the API says so, and it
// is the one fact the whole drawing depends on, so it was established rather
// than assumed: train 2806 arrives in Bern on track 9 and leaves again as 2809
// off the same track, the same physical train pointed the other way. Its
// vehicles are listed in the same order both times, and the platform sectors
// they are recorded against run G→A on arrival and A→G on departure. The
// listing is therefore front-first, and position 1 is the leading vehicle.

/// Which railway undertaking to ask, as the formation service spells it.
///
/// A closed set of eleven: the service carries only the companies that hand
/// their formations to SBB *and* agreed to publish them as open data. Everyone
/// else — every bus, every tram, and a good number of trains — is simply not in
/// it, which is a silence rather than a failure.
public enum FormationOperator: String, Sendable, CaseIterable {
    case sbb = "SBBP"
    case bls = "BLSP"
    case mbc = "MBC"
    case oensingenBalsthal = "OeBB"
    case rhb = "RhB"
    case sob = "SOB"
    case thurbo = "THURBO"
    case tpf = "TPF"
    case trn = "TRN"
    case dampfbahnBernKonolfingen = "VDBB"
    case zentralbahn = "ZB"

    /// The federal business-organisation id each one is filed under.
    ///
    /// Keyed on the number rather than on the name the register prints, because
    /// the number is what the journey id already carries. Note `OeBB` is the
    /// Oensingen–Balsthal-Bahn and not the Austrian ÖBB, which the shared
    /// abbreviation makes very easy to get backwards.
    /// Audited against the national timetable rather than transcribed: every id
    /// here was checked for how many of the year's trips actually carry it, and
    /// two were wrong.
    ///
    /// `100018` was filed for the Südostbahn and appears on **no trip at all**;
    /// the SOB files under `100061`, which is 9,987 trips. Because a key that
    /// cannot be built is never asked about, every SOB train drew no formation
    /// — silently, and indistinguishably from a company the service does not
    /// cover. The formations were there the whole time: asked with `SOB` and a
    /// train number, `formations_stop_based` answers for all of them.
    ///
    /// The Morges–Bière–Cossonay is filed under two agency entries differing
    /// only in the case of "Région", and the second, `100301`, carries 4,880 of
    /// its 6,804 trips — so three quarters of the MBC was missing too.
    static let bySBOID: [Int: FormationOperator] = [
        100001: .sbb,
        100012: .mbc,
        100301: .mbc,
        100015: .bls,
        100061: .sob,
        100025: .trn,
        100034: .tpf,
        100046: .thurbo,
        100049: .oensingenBalsthal,
        100053: .rhb,
        100064: .zentralbahn,
        101240: .dampfbahnBernKonolfingen,
    ]
}

public extension VehicleSnapshot {
    /// The reference to ask the formation service about, for the leg being run.
    ///
    /// `id` is the fleet's key, and for anything the timetable produced that is
    /// a row number — `tt:41903` — which parses to no train number and no
    /// operator, so the panel concluded the service had nothing to say about
    /// any timetabled train and drew no formation at all. The Swiss Journey ID
    /// is what carries both, and it travels beside the id rather than as it.
    ///
    /// Both callers go through this. The two readings have to agree, or a
    /// formation learned in the background is filed under a key the panel never
    /// looks up.
    func formationReference(leg: JourneyPart?) -> String {
        if let leg { return leg.journeyRef ?? leg.id }
        return journeyRef ?? id
    }
}

/// Everything needed to ask for one train's formation.
public struct FormationKey: Hashable, Sendable {
    public var operatorCode: FormationOperator
    public var trainNumber: Int
    /// The operating day, `YYYY-MM-DD`. The service refuses anything before
    /// today and holds at most three days ahead.
    public var operationDate: String

    public init(operatorCode: FormationOperator, trainNumber: Int, operationDate: String) {
        self.operatorCode = operatorCode
        self.trainNumber = trainNumber
        self.operationDate = operationDate
    }

    /// Read out of a SIRI journey reference, or nil where there is nothing to
    /// ask.
    ///
    /// A Swiss Journey ID is `ch:1:sjyid:<sboid>:<train>-<variant>`, and both
    /// the parts this needs are in it. The tail is not always a train number —
    /// buses carry `plan:4c07ee05-…` and `SKI-1234` — and where it is not, this
    /// returns nil rather than guessing at a number to send.
    public init?(journeyID: String, operationDate: String) {
        let parts = journeyID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[2] == "sjyid",
              let sboid = Int(parts[3]),
              let operatorCode = FormationOperator.bySBOID[sboid]
        else { return nil }

        // `2806-001`, `96244-002`, or a bare `00902` — everything before the
        // variant, and only where all of it is digits.
        let tail = parts[4]
        let number = tail.split(separator: "-", maxSplits: 1).first ?? tail
        guard !number.isEmpty, number.allSatisfy(\.isNumber), let trainNumber = Int(number)
        else { return nil }

        self.init(operatorCode: operatorCode, trainNumber: trainNumber, operationDate: operationDate)
    }

    /// The operating day of a journey, in the timezone the timetable is written
    /// in.
    ///
    /// The departure rather than the clock: a train that leaves at 23:50 and
    /// runs past midnight belongs to the day it left on, which is the day the
    /// formation service files it under.
    public static func operationDate(of departure: Timestamp) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(departure))
        )
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - What a coach is

/// What kind of vehicle it is, as the short string codes it.
public enum CoachKind: String, Sendable, Equatable, Hashable, Codable {
    case first = "1"
    case second = "2"
    case mixed = "12"
    case couchette = "CC"
    case family = "FA"
    case sleeper = "WL"
    case restaurant = "WR"
    case diningFirst = "W1"
    case diningSecond = "W2"
    case locomotive = "LK"
    case luggage = "D"
    /// Not a vehicle: platform length the train does not occupy. Kept out of
    /// the drawing, but it is what makes an empty sector detectable.
    case fictitious = "F"
    case classless = "K"
    case parked = "X"

    /// The known codes, longest first, because `12` and `1` share a prefix and
    /// the two-character reading is the right one where it fits.
    static let codes: [String] = ["12", "CC", "FA", "WL", "WR", "W1", "W2", "LK",
                                  "1", "2", "D", "F", "K", "X"]

    public var carriesPassengers: Bool {
        switch self {
        case .locomotive, .luggage, .fictitious, .parked: return false
        default: return true
        }
    }
}

/// The status prefix a vehicle can carry.
public enum CoachStatus: Character, Sendable, Equatable {
    case closed = "-"
    case groupsBoarding = ">"
    case groupsReserved = "="
    /// A dining car that is open but unattended.
    case unattended = "%"
}

/// One of the things printed on the outside of a coach.
public enum CoachOffer: String, Sendable, Equatable, CaseIterable {
    case wheelchairSpaces = "BHP"
    case businessZone = "BZ"
    case familyZone = "FZ"
    case pramPlatform = "KW"
    case lowFloor = "NF"
    case bicycleHooks = "VH"
    case bicycleHooksReserved = "VR"
}

/// One vehicle in a train, as it stands at one stop.
public struct Coach: Sendable, Equatable, Identifiable {
    /// Position in the formation, counting from the front. 1-based.
    public var position: Int
    public var id: Int { position }
    public var kind: CoachKind
    /// The number painted on the coach, which is what a reservation names. Nil
    /// where the train is not numbered for reservation.
    public var number: Int?
    public var status: Set<CoachStatus>
    public var offers: Set<CoachOffer>
    /// Platform sector this vehicle stands in, where the stop has sectors.
    public var sector: String?
    /// Whether the gangway to the vehicle in front is blocked.
    public var noAccessForward: Bool
    /// Whether the gangway to the vehicle behind is blocked.
    public var noAccessBackward: Bool

    // Filled in from the vehicle-based half of the response, which the short
    // string knows nothing about. All optional: a train the realtime system has
    // but the rolling-stock register does not comes through with the drawing
    // intact and the detail missing.
    public var seatsFirst: Int?
    public var seatsSecond: Int?
    public var wheelchairSpaces: Int?
    public var wheelchairToilet: Bool?
    public var bicycleHooks: Int?
    public var beds: Int?
    public var lowFloor: Bool?
    public var airConditioned: Bool?
    public var length: Double?
    /// The European Vehicle Number, which is the coach's identity for life.
    public var evn: String?
    /// `RABe515_6_1`, `Bpm`, `Ge` — the class of rolling stock.
    public var typeName: String?

    public var isClosed: Bool { status.contains(.closed) }

    public init(
        position: Int, kind: CoachKind, number: Int? = nil,
        status: Set<CoachStatus> = [], offers: Set<CoachOffer> = [],
        sector: String? = nil, noAccessForward: Bool = false,
        noAccessBackward: Bool = false
    ) {
        self.position = position
        self.kind = kind
        self.number = number
        self.status = status
        self.offers = offers
        self.sector = sector
        self.noAccessForward = noAccessForward
        self.noAccessBackward = noAccessBackward
    }
}

/// The train as it stands at one stop.
public struct FormationAtStop: Sendable, Equatable {
    public var stopName: String
    public var uic: Int
    public var track: String?
    public var arrival: Date?
    public var departure: Date?
    /// Real vehicles, front first. Fictitious padding is dropped; what it said
    /// about unoccupied platform survives in `sectors`.
    public var coaches: [Coach]
    /// Every sector the train's own vehicles reach, in platform order.
    public var sectors: [String]
    /// The formation as filed, padding included — every vehicle *and* every
    /// length of empty platform beside it, in platform order.
    ///
    /// The service describes a platform, not a train: `@D,F,F,F@C,F` is three
    /// coach-lengths of sector D followed by one of sector C, and the `F`s are
    /// platform the train does not reach. `coaches` drops them because a picture
    /// of a train should not contain vehicles that are not there — but they are
    /// the only statement anything makes about the sectors *beyond* the train,
    /// so they are kept here rather than thrown away. The drawing uses them to
    /// letter the whole platform instead of only the part under the train.
    public var padded: [Coach] = []
    /// Which part of the train goes where, for a train that splits.
    public var portions: [Portion]

    public struct Portion: Sendable, Equatable {
        /// Where these coaches are going, where the service says so in words.
        ///
        /// Optional, and the reason is a train that splits at Spiez: the half
        /// going to Zweisimmen is named, and the half going to Domodossola
        /// arrives as `{"name": null, "uic": 8301003}`. Requiring a name threw
        /// that portion away, which left one portion instead of two — and a
        /// train with one portion is a train that does not split, so the
        /// drawing said nothing about the split at all. The number is enough to
        /// find the name with; see `TrainFormation.naming(_:)`.
        public var destination: String?
        /// The UIC number of that station, which the service always sends.
        public var destinationUIC: Int?
        public var fromPosition: Int
        public var toPosition: Int

        public init(
            destination: String?, destinationUIC: Int? = nil,
            fromPosition: Int, toPosition: Int
        ) {
            self.destination = destination
            self.destinationUIC = destinationUIC
            self.fromPosition = fromPosition
            self.toPosition = toPosition
        }
    }

    public init(
        stopName: String, uic: Int, track: String?, arrival: Date?, departure: Date?,
        coaches: [Coach], sectors: [String], portions: [Portion], padded: [Coach] = []
    ) {
        self.stopName = stopName
        self.uic = uic
        self.track = track
        self.arrival = arrival
        self.departure = departure
        self.coaches = coaches
        self.sectors = sectors
        self.padded = padded
        self.portions = portions
    }

    /// A stop the drawing can say nothing about — no vehicles resolved.
    public var isEmpty: Bool { coaches.isEmpty }

    /// How far this stop is, in time, from a given moment.
    ///
    /// For matching a formation's own stop list against the panel's, which can
    /// spell a station differently or cover a different set of legs. Either
    /// time will do; a stop that carries neither is infinitely far away.
    public func distance(from moment: Date) -> TimeInterval {
        guard let time = arrival ?? departure else { return .infinity }
        return abs(time.timeIntervalSince(moment))
    }
}

/// One train's formation, for the whole of its run.
public struct TrainFormation: Sendable, Equatable {
    public var trainNumber: Int
    public var operatorCode: String
    /// Whether the train is running at all, as the realtime system has it.
    public var runs: RunState
    public var totalLength: Double?
    public var totalSeats: Int?
    public var vehicleCount: Int?
    public var axleCount: Int?
    public var lastUpdate: Date?
    public var stops: [FormationAtStop]
    /// Turnarounds, splits and joins along the way.
    public var relationships: [Relationship]

    public enum RunState: String, Sendable, Equatable {
        case runs = "J"
        case doesNotRun = "N"
        case partial = "T"
        case deleted = "L"
    }

    /// One of the other workings a relationship names.
    public struct Working: Sendable, Equatable {
        public var trainNumber: Int?
        /// Its Swiss Journey ID, where the service gives one.
        ///
        /// The number alone is not enough to find it in the realtime feed: the
        /// feed is keyed by journey id, and resolving a number back to one
        /// means a search that two services leaving together can defeat. The
        /// service hands over the id, so it is taken rather than reconstructed.
        public var journeyID: String?

        public init(trainNumber: Int?, journeyID: String? = nil) {
            self.trainNumber = trainNumber
            self.journeyID = journeyID
        }
    }

    public struct Relationship: Sendable, Equatable {
        public var kind: Kind
        /// Whether the other working runs before this point or after it.
        public var direction: Direction?
        public var stopName: String?
        public var stopUIC: Int?
        /// The workings on the other side of this relationship.
        ///
        /// A separation names **two**, and both matter: they are the two trains
        /// this one becomes. The response carries them as
        /// `advancedJourneyInformation1` and `…2`, and reading only the first
        /// was the bug behind an RE from Bern that never mentioned Zweisimmen —
        /// at Spiez it parts into 4281 for Domodossola and 6833 for Zweisimmen,
        /// and 4281 is the leg the train the reader is standing in continues
        /// as. Taking the first named working therefore handed back the
        /// reader's own train as "the other half", which draws the line already
        /// drawn and names the destination already named. Every other kind of
        /// relationship names one.
        public var others: [Working]

        /// The first working named, which for everything but a separation is
        /// the only one.
        public var otherTrainNumber: Int? { others.first?.trainNumber }
        public var otherJourneyID: String? { others.first?.journeyID }

        public init(
            kind: Kind, direction: Direction? = nil, stopName: String?,
            stopUIC: Int? = nil, others: [Working]
        ) {
            self.kind = kind
            self.direction = direction
            self.stopName = stopName
            self.stopUIC = stopUIC
            self.others = others
        }

        public init(
            kind: Kind, direction: Direction? = nil, stopName: String?,
            stopUIC: Int? = nil, otherTrainNumber: Int?, otherJourneyID: String? = nil
        ) {
            self.init(
                kind: kind, direction: direction, stopName: stopName, stopUIC: stopUIC,
                others: [Working(trainNumber: otherTrainNumber, journeyID: otherJourneyID)]
            )
        }

        /// What the relationship *is*, as `relationshipType`.
        ///
        /// `N` and `V` are deliberately not in here. They look like they belong
        /// — they are single letters out of the same response — but they are
        /// values of `direction`, a different field, and putting them in this
        /// enum makes two cases that no `relationshipType` can ever match.
        public enum Kind: String, Sendable, Equatable {
            case relief = "D", substitute = "E"
            case continuation = "F", separation = "T", rerouting = "U"
            case turnaround = "W", merge = "Z"
        }

        public enum Direction: String, Sendable, Equatable {
            case before = "V", after = "N"
        }
    }

    /// Where this train splits, and what the other half is.
    ///
    /// A splitting train is filed as two workings that happen to be coupled for
    /// the first part of the run, so the half a reader is not standing in is a
    /// different journey with a different number — and after the separation it
    /// goes somewhere this train's own stop list never mentions.
    public struct Separation: Sendable, Equatable {
        public var stopName: String
        public var stopUIC: Int?
        /// The two workings the train becomes, as the service names them.
        ///
        /// Both, because one of them is usually the reader's own train: a
        /// separation is filed against the working that arrives, and the leg
        /// that carries on to the far destination is a new number the realtime
        /// feed has already chained onto the vehicle in hand. Which of the two
        /// is "the other half" is therefore not a fact about the formation, it
        /// is a fact about who is asking — see `branch(excluding:)`.
        public var branches: [Working]

        public var otherJourneyID: String? { branches.first?.journeyID }
        public var otherTrainNumber: Int? { branches.first?.trainNumber }

        public init(stopName: String, stopUIC: Int?, branches: [Working]) {
            self.stopName = stopName
            self.stopUIC = stopUIC
            self.branches = branches
        }

        /// The half the reader is *not* standing in.
        ///
        /// `mine` is every journey id the vehicle in hand covers — its own and,
        /// where the feed renumbers it partway, each leg it is chained out of.
        /// A branch that is one of those is the train being looked at, not the
        /// other half of it.
        public func branch(excluding mine: Set<String>) -> Working? {
            branches.first { working in
                guard let id = working.journeyID else { return false }
                return !mine.contains(id)
            } ?? branches.first
        }
    }

    /// The separation this train makes on its way, where it makes one.
    ///
    /// Only one is taken. A working that parts company twice is possible on
    /// paper and is not something the drawing or the map has a way to say, and
    /// the first is the one a reader on board reaches first.
    public var separation: Separation? {
        relationships.lazy.compactMap { relation -> Separation? in
            guard relation.kind == .separation, let stopName = relation.stopName
            else { return nil }
            return Separation(
                stopName: stopName, stopUIC: relation.stopUIC, branches: relation.others
            )
        }.first
    }

    public init(
        trainNumber: Int, operatorCode: String, runs: RunState, totalLength: Double?,
        totalSeats: Int?, vehicleCount: Int?, axleCount: Int?, lastUpdate: Date?,
        stops: [FormationAtStop], relationships: [Relationship]
    ) {
        self.trainNumber = trainNumber
        self.operatorCode = operatorCode
        self.runs = runs
        self.totalLength = totalLength
        self.totalSeats = totalSeats
        self.vehicleCount = vehicleCount
        self.axleCount = axleCount
        self.lastUpdate = lastUpdate
        self.stops = stops
        self.relationships = relationships
    }

    /// Where the train parts company, and which coaches go where.
    public struct Split: Sendable, Equatable {
        public var stopName: String
        public var stopUIC: Int
        /// When the train gets there, so the two halves can be recognised in
        /// the realtime feed by the time they leave.
        public var moment: Date?
        /// The portions as they stand while the train is still one train.
        public var portions: [FormationAtStop.Portion]
    }

    /// The split this train makes, read from the coach goals rather than from a
    /// relationship.
    ///
    /// `separation` is the better source and is used where it exists, but it
    /// often does not: the S44 out of Burgistein has "coaches 1–4 to Solothurn,
    /// 5–8 to Sumiswald-Grünen" against every stop and a null `relationships`.
    /// The goals alone are enough to find the parting, because they are listed
    /// while the coaches are together and stop being listed once they are not —
    /// so the split is the stop after the last one that named two destinations.
    public var split: Split? {
        guard let last = stops.lastIndex(where: { $0.portions.count > 1 }) else { return nil }
        let together = stops[last]
        let next = stops.indices.contains(last + 1) ? stops[last + 1] : together
        // The relationship wins on where, when there is one: it names the stop
        // outright rather than by inference from a gap in a list.
        let name = separation?.stopName ?? next.stopName
        let parting = stops.first {
            $0.stopName.compare(name, options: .caseInsensitive) == .orderedSame
        } ?? next
        return Split(
            stopName: parting.stopName, stopUIC: parting.uic,
            moment: parting.arrival ?? parting.departure,
            portions: together.portions
        )
    }

    /// The same formation with every unnamed portion destination filled in.
    ///
    /// The service names a portion's destination by UIC always and in words
    /// only sometimes — a Swiss station is spelled out, an Italian one comes
    /// back as `{"name": null, "uic": 8301003}`. The stop register holds that
    /// number and the name beside it, so the gap is closable; it is closed here
    /// rather than in the parser because the parser has no register to ask.
    public func naming(_ resolve: (Int) -> String?) -> TrainFormation {
        var copy = self
        for stopIndex in copy.stops.indices {
            for portionIndex in copy.stops[stopIndex].portions.indices {
                let portion = copy.stops[stopIndex].portions[portionIndex]
                guard portion.destination == nil, let uic = portion.destinationUIC,
                      let name = resolve(uic)
                else { continue }
                copy.stops[stopIndex].portions[portionIndex].destination = name
            }
        }
        return copy
    }

    /// The stop whose name matches, preferring one that has not been passed.
    public func stop(named name: String) -> FormationAtStop? {
        stops.first { $0.stopName.compare(name, options: .caseInsensitive) == .orderedSame }
    }
}

// MARK: - The short string

/// The compact representation CUS publishes for each stop.
///
/// `@C,F,[(2#NF,2#VH;KW;NF@B,2)#NF],F` is a whole train: sector C holds a length
/// of unoccupied platform and then two coaches, sector B holds a third, and the
/// gangways at both ends of the set are blocked. The pieces:
///
/// - `@X` opens platform sector X. Everything after it belongs to X.
/// - `,` separates vehicles.
/// - `[` `]` bracket the vehicles that are actually part of this train.
/// - `(` `)` mark a gangway that cannot be walked through, on that side.
/// - a leading `-`, `>`, `=` or `%` is the vehicle's status.
/// - then the type — `1`, `2`, `12`, `WR`, `LK`, `F`, …
/// - then `:` and the number painted on the coach.
/// - then `#` and the offers on board, separated by `;`.
public enum FormationShortString {
    /// Every vehicle the string names, in order, fictitious ones included.
    ///
    /// Nothing is thrown away here: a caller that wants only the real coaches
    /// filters, and a caller asking which sectors the train fails to reach
    /// needs the padding to answer. `position` counts real vehicles only, from
    /// 1, so it is the same number the vehicle-based half of the response uses;
    /// padding is left at 0.
    public static func parse(_ string: String) -> [Coach] {
        var coaches: [Coach] = []
        var position = 0

        // Cut at each sector marker first. A marker is not a vehicle and does
        // not sit tidily between commas — `@D,F,F,F@C,F` puts one at the head of
        // the string and one glued to the back of the third F — so the sector
        // runs are taken out before the commas are looked at.
        for segment in segments(of: string) {
            for piece in segment.body.split(separator: ",", omittingEmptySubsequences: true) {
                guard var coach = vehicle(String(piece), position: 0) else { continue }
                if coach.kind != .fictitious {
                    position += 1
                    coach.position = position
                }
                coach.sector = segment.sector
                coaches.append(coach)
            }
        }
        return coaches
    }

    /// The string split into runs of one sector each.
    private static func segments(of string: String) -> [(sector: String?, body: Substring)] {
        var out: [(String?, Substring)] = []
        var sector: String?
        var start = string.startIndex
        var index = string.startIndex

        func close(at end: String.Index) {
            let body = string[start..<end]
            if !body.isEmpty { out.append((sector, body)) }
        }

        while index < string.endIndex {
            let next = string.index(after: index)
            if string[index] == "@", next < string.endIndex, string[next].isLetter {
                close(at: index)
                sector = String(string[next])
                start = string.index(after: next)
                index = start
                continue
            }
            index = next
        }
        close(at: string.endIndex)
        return out
    }

    /// One comma-separated piece: `[(2#NF`, `%W2:4#BHP;NF`, `2)#NF]`, `F`.
    private static func vehicle(_ token: String, position: Int) -> Coach? {
        var status: Set<CoachStatus> = []
        var noAccessForward = false
        var noAccessBackward = false
        var body = ""
        // Brackets and parens can sit anywhere in the token — before the status,
        // after the type, between the type and its number — so they are picked
        // out rather than matched in place. A `(` seen before the type is the
        // gangway in front; after it, the one behind.
        var seenType = false
        for character in token {
            switch character {
            case "[", "]":
                continue
            case "(":
                if seenType { noAccessBackward = true } else { noAccessForward = true }
            case ")":
                if seenType { noAccessBackward = true } else { noAccessForward = true }
            case "-", ">", "=", "%":
                // Only a prefix is a status. A `-` cannot appear inside the rest
                // of the grammar, so this is unambiguous.
                if !seenType, let flag = CoachStatus(rawValue: character) { status.insert(flag) }
            default:
                if !character.isWhitespace {
                    body.append(character)
                    seenType = true
                }
            }
        }

        guard let kindCode = CoachKind.codes.first(where: { body.hasPrefix($0) }),
              let kind = CoachKind(rawValue: kindCode)
        else { return nil }

        var rest = Substring(body.dropFirst(kindCode.count))

        var number: Int?
        if rest.first == ":" {
            let digits = rest.dropFirst().prefix { $0.isNumber }
            number = Int(digits)
            rest = rest.dropFirst(1 + digits.count)
        }

        var offers: Set<CoachOffer> = []
        if rest.first == "#" {
            for code in rest.dropFirst().split(separator: ";") {
                if let offer = CoachOffer(rawValue: String(code)) { offers.insert(offer) }
            }
        }

        // A coach numbered 0 is one the operator does not number: the field is
        // there, and it means "not for reservation" rather than "coach zero".
        return Coach(
            position: position, kind: kind, number: number == 0 ? nil : number,
            status: status, offers: offers,
            noAccessForward: noAccessForward, noAccessBackward: noAccessBackward
        )
    }
}
