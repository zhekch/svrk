import Foundation

/// How full the trains are, from Open Journey Planner 2.0.
///
/// The one thing the national feed cannot answer. SIRI-ET carries no occupancy
/// at all — checked against a live snapshot, every SIRI `Occupancy` element
/// absent from a 59-element vocabulary — and neither does the formation
/// service, which knows how many seats a coach has and nothing about how many
/// are taken. OJP does, per call and per class.
///
/// It is shaped like `FormationService` rather than like `Fleet`, and the
/// difference is the whole design. The fleet is one national snapshot every
/// minute; this is a question asked about one journey at a time, fifty a
/// minute. So it is asked about the vehicle somebody tapped and the screenful
/// around it, cached, and never asked about the country.
public actor LoadService {
    /// How long a forecast stands before it is asked for again.
    ///
    /// Four minutes rather than the formation's fifteen. A formation changes
    /// when a train is re-marshalled, which is to say almost never; a load
    /// changes at every stop, and a train that left Bern with seats free is a
    /// different proposition by Olten. Short enough to follow that, long
    /// enough that re-reading a panel fifteen times a second costs one request.
    static let ttl: TimeInterval = 240

    /// Slots kept back for a vehicle somebody is actually looking at.
    ///
    /// The map asks about what is on screen; a tap has to be answerable while
    /// that sweep is running, and being refused looks exactly like a train
    /// with no load published.
    static let foregroundReserve = 14

    public enum Answer: Sendable, Equatable {
        case load(JourneyLoad)
        /// OJP answered and had nothing — no forecast for this run. A silence,
        /// and the panel omits the row rather than apologising for it.
        case none
        case failed(String)
    }

    private let client: OTDClient
    private let configured: Bool
    private var cache: [Key: (answer: Answer, at: Date)] = [:]
    private var inFlight: [Key: Task<Answer, Never>] = [:]

    /// The timings from the same response, kept beside the occupancy.
    ///
    /// One `OJPTripInfoRequest` answers both questions — it returns the whole
    /// call list, with `TimetabledTime` and `EstimatedTime` on each half of each
    /// call — and this used to read the occupancy out and drop the rest on the
    /// floor. Asking twice for one document would double a budget that is fifty
    /// requests a minute and shared with every panel the user opens.
    private var timings: [Key: JourneyTiming] = [:]

    public struct Key: Hashable, Sendable {
        public var journeyID: String
        /// The service day the journey belongs to. A run past midnight belongs
        /// to the day it left on, which is the day OJP files it under.
        public var day: String

        public init(journeyID: String, day: String) {
            self.journeyID = journeyID
            self.day = day
        }

        /// The operating day for a journey that started at `start`.
        public static func day(of start: Timestamp) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
            let date = Date(timeIntervalSince1970: TimeInterval(start))
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(
                format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
            )
        }
    }

    public private(set) var lastError: String?
    public private(set) var asked = 0

    public init(token: String? = nil) {
        client = OTDClient(token: token)
        configured = token?.isEmpty == false
    }

    public var isConfigured: Bool { configured }

    /// What this journey's load is, from the cache where possible.
    ///
    /// `background` marks a request nobody is waiting for: answered from the
    /// cache like any other, but it will not spend the last of the minute's
    /// budget and gives up rather than queueing behind a full window.
    public func load(for key: Key, background: Bool = false) async -> Answer {
        if let held = cache[key], Date().timeIntervalSince(held.at) < Self.ttl {
            return held.answer
        }
        // A panel re-read while its first request is still open is one request.
        if let running = inFlight[key] { return await running.value }

        if background, await client.headroom(OTDClient.ojp) <= Self.foregroundReserve {
            return .failed("leaving room for the foreground")
        }

        // One request, both halves. The occupancy and the timings are two
        // readings of the same document, so there is exactly one `fetch` here —
        // and `inFlight` projects the answer out of it so a panel re-read while
        // it is open still coalesces onto this one call rather than starting a
        // second.
        let running = Task<Both, Never> { [client] in await Self.fetch(key: key, client: client) }
        inFlight[key] = Task { await running.value.answer }
        let both = await running.value
        let answer = both.answer
        timings[key] = both.timing
        inFlight[key] = nil
        asked += 1

        // A silence is cached and a failure is not, for the same reason as the
        // formation service: a run OJP has no forecast for will not acquire one
        // in the seconds a panel stays open, while being throttled says nothing
        // about the run at all.
        if case .failed = answer {} else { cache[key] = (answer, Date()) }
        return answer
    }

    /// Drop everything, for a caller that knows the day has turned.
    public func forget() {
        cache = [:]
        timings = [:]
    }

    /// What OJP said about a run, both halves of it.
    private struct Both: Sendable {
        var answer: Answer
        var timing: JourneyTiming?
    }

    private static func fetch(key: Key, client: OTDClient) async -> Both {
        let body = Data(request(for: key).utf8)
        do {
            let data = try await client.post(OTDClient.ojp, body: body)
            let timing = OJPTimings.trip(data)
            let byStop = OJPLoad.parse(data)
            guard !byStop.isEmpty else {
                return Both(answer: .none, timing: timing.isEmpty ? nil : timing)
            }
            let load = JourneyLoad(journeyID: key.journeyID, day: key.day, byStop: byStop)
            return Both(
                answer: load.isEmpty ? .none : .load(load),
                timing: timing.isEmpty ? nil : timing
            )
        } catch {
            return Both(answer: .failed(String(describing: error)), timing: nil)
        }
    }

    /// How late this run is, and where it is now expected.
    ///
    /// The delay half of the same request `load(for:)` makes, so a panel that
    /// asks for both spends one call rather than two. Nil where OJP publishes
    /// nothing for the run — which 20.7% of a weekday's trips have no reference
    /// to ask about in the first place.
    public func timing(for key: Key) async -> JourneyTiming? {
        if let held = cache[key], Date().timeIntervalSince(held.at) < Self.ttl {
            return timings[key]
        }
        _ = await load(for: key)
        return timings[key]
    }

    /// Delays for everything leaving one station, in one request.
    ///
    /// The bulk primitive, and the reason a screenful does not cost a request
    /// per vehicle: one `OJPStopEventRequest` at Zürich HB returns fifty
    /// departures — measured at 8.4 KB gzipped, of which 46 carried a live
    /// estimate — keyed by the same journey reference the timetable holds. A
    /// dozen busy stations therefore cover a city for about a hundred
    /// kilobytes, against 7 MB for the national feed.
    ///
    /// Answered per stop rather than cached per journey: what is standing at a
    /// platform changes as the window moves, and a cache keyed on the stop would
    /// hand back a departure that has already gone.
    public func departures(from stopPlace: String, limit: Int = 50, background: Bool = true) async -> [String: CallTiming] {
        guard configured else { return [:] }
        if background, await client.headroom(OTDClient.ojp) <= Self.foregroundReserve {
            return [:]
        }
        do {
            let body = Data(Self.stopEventRequest(stopPlace: stopPlace, limit: limit).utf8)
            let data = try await client.post(OTDClient.ojp, body: body)
            asked += 1
            return OJPTimings.stopEvents(data)
        } catch {
            lastError = String(describing: error)
            return [:]
        }
    }

    static func stopEventRequest(stopPlace: String, limit: Int, now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri" version="2.0">
        <OJPRequest><siri:ServiceRequest>
        <siri:ServiceRequestContext><siri:LanguageRef>en</siri:LanguageRef></siri:ServiceRequestContext>
        <siri:RequestTimestamp>\(stamp)</siri:RequestTimestamp>
        <siri:RequestorRef>\(OTDClient.userAgent)</siri:RequestorRef>
        <OJPStopEventRequest>
        <siri:RequestTimestamp>\(stamp)</siri:RequestTimestamp>
        <Location><PlaceRef><StopPlaceRef>\(escape(stopPlace))</StopPlaceRef></PlaceRef></Location>
        <Params>
        <NumberOfResults>\(limit)</NumberOfResults>
        <StopEventType>departure</StopEventType>
        <IncludePreviousCalls>false</IncludePreviousCalls>
        <IncludeOnwardCalls>false</IncludeOnwardCalls>
        <IncludeRealtimeData>true</IncludeRealtimeData>
        </Params>
        </OJPStopEventRequest>
        </siri:ServiceRequest></OJPRequest></OJP>
        """
    }

    /// One `OJPTripInfoRequest`, which answers about a whole journey rather
    /// than about one stop — so the panel's entire call list is covered by a
    /// single request rather than by one per row.
    static func request(for key: Key, now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri" version="2.0">
        <OJPRequest><siri:ServiceRequest>
        <siri:ServiceRequestContext><siri:LanguageRef>en</siri:LanguageRef></siri:ServiceRequestContext>
        <siri:RequestTimestamp>\(stamp)</siri:RequestTimestamp>
        <siri:RequestorRef>\(OTDClient.userAgent)</siri:RequestorRef>
        <OJPTripInfoRequest>
        <siri:RequestTimestamp>\(stamp)</siri:RequestTimestamp>
        <JourneyRef>\(escape(key.journeyID))</JourneyRef>
        <OperatingDayRef>\(escape(key.day))</OperatingDayRef>
        <Params>
        <UseTimetabledDataOnly>false</UseTimetabledDataOnly>
        <IncludeCalls>true</IncludeCalls>
        <IncludeService>true</IncludeService>
        <IncludePlacesContext>false</IncludePlacesContext>
        </Params>
        </OJPTripInfoRequest>
        </siri:ServiceRequest></OJPRequest></OJP>
        """
    }

    /// A journey id is `ch:1:sjyid:100001:19691-001` and has never needed
    /// escaping, which is exactly why it is escaped: the id comes from a feed
    /// rather than from this app, and an id with an `&` in it would otherwise
    /// produce a request the server rejects as malformed.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Read the occupancy out of an `OJPTripInfoResponse`.
///
/// String scanning rather than the byte machinery `SiriParser` uses, and
/// deliberately: that exists because the estimated timetable is 150 MB and must
/// never be held. This document is nine kilobytes, arrives whole, and is read
/// once per journey — the cost of materialising it is not worth a fourth copy
/// of a skip-table scanner to avoid.
enum OJPLoad {
    /// The wrappers a call arrives in. `TripInfo` uses these two directly;
    /// there is no `CallAtStop` here, which is a `StopEvent` shape.
    static let wrappers = ["PreviousCall", "OnwardCall", "ThisCall"]

    static func parse(_ data: Data) -> [String: Occupancy] {
        let xml = String(decoding: data, as: UTF8.self)
        var out: [String: Occupancy] = [:]

        for wrapper in wrappers {
            for call in blocks(xml[...], wrapper) {
                guard let ref = first(call, "siri:StopPointRef") else { continue }
                var occupancy = out[ref] ?? Occupancy()
                for entry in blocks(call, "siri:ExpectedDepartureOccupancy") {
                    guard let level = first(entry, "siri:OccupancyLevel") else { continue }
                    let read = OccupancyLevel(feedValue: level)
                    // `secondClass ` really does arrive with a trailing space.
                    switch first(entry, "siri:FareClass")?
                        .trimmingCharacters(in: .whitespacesAndNewlines) {
                    case "firstClass": occupancy.firstClass = read
                    case "secondClass": occupancy.secondClass = read
                    default: break
                    }
                }
                if !occupancy.isEmpty { out[ref] = occupancy }
            }
        }
        return out
    }

    /// Every `<name>…</name>` in `text`. Non-nesting, which holds for all three
    /// elements this reads.
    static func blocks(_ text: Substring, _ name: String) -> [Substring] {
        var out: [Substring] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<\(name)>", range: cursor..<text.endIndex),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) {
            out.append(text[open.upperBound..<close.lowerBound])
            cursor = close.upperBound
        }
        return out
    }

    static func first(_ text: Substring, _ name: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}
