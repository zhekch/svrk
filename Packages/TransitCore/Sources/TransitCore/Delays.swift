import Foundation

/// What is actually happening to one run, as OJP reports it.
///
/// The counterpart to the timetable: `TimetableStore` says what is *meant* to
/// happen and carries no delay at all, and this is the correction, asked for one
/// journey at a time rather than downloaded for the country. A whole journey —
/// every call, both times for each — costs about 5 KB, against the 7 MB a
/// national SIRI-ET refresh costs to learn the same thing about 16,000 runs
/// nobody is looking at.
public struct JourneyTiming: Sendable, Equatable {
    /// Latest visit per published stop ID. A platform change can change this
    /// ID, so applying timings also checks the station and scheduled time.
    public var byStop: [String: CallTiming]
    /// Retain earlier visits on loops instead of applying the last visit's
    /// delay to every occurrence of the same stop.
    private var repeatedByStop: [String: [CallTiming]] = [:]
    /// The whole run called off, as distinct from individual calls dropped.
    public var cancelled: Bool
    /// Calls OJP published, in journey order. The packed Swiss timetable
    /// often ends at the border; this is the rest of the run.
    public var calls: [Call] = []

    public init(byStop: [String: CallTiming], cancelled: Bool = false, calls: [Call] = []) {
        self.byStop = byStop
        self.cancelled = cancelled
        self.calls = calls
    }

    /// A parsed stop-event journey retains the booked departure and its live
    /// calls. Share those estimates with the matching map working as well.
    init(liveBoardJourney journey: Journey) {
        self.init(byStop: [:], cancelled: journey.cancelled, calls: journey.stops)
        for (index, stop) in journey.stops.enumerated() {
            guard let ref = stop.ref, let planned = stop.sched,
                  stop.delay != nil || stop.cancelled else { continue }
            let terminal = index == journey.stops.count - 1
            record(CallTiming(
                planned: planned,
                expectedArrival: stop.arr,
                expectedDeparture: terminal ? nil : stop.dep,
                plannedArrival: stop.scheduledArrival ?? (terminal ? planned : nil),
                plannedDeparture: terminal ? nil : planned,
                expectedQuay: stop.platform, cancelled: stop.cancelled
            ), at: ref)
        }
    }

    public var isEmpty: Bool { byStop.isEmpty && !cancelled }

    fileprivate mutating func record(_ timing: CallTiming, at ref: String) {
        if let prior = byStop[ref] {
            var visits = repeatedByStop[ref] ?? [prior]
            if !visits.contains(timing) { visits.append(timing) }
            repeatedByStop[ref] = visits
            byStop[ref] = visits.max { $0.planned < $1.planned }
        } else {
            byStop[ref] = timing
        }
    }

    struct Match {
        let ref: String
        let timing: CallTiming
    }

    /// Match calls, not just platform IDs. Never use proximity or station names:
    /// the same parent station AND the scheduled event identify a changed quay.
    /// Build this index once per response, not once per vehicle animation tick.
    func matches(for stops: [Call]) -> [Match?] {
        var byStation: [String: [Match]] = [:]
        for (ref, latest) in byStop {
            for timing in repeatedByStop[ref] ?? [latest] {
                byStation[StopRegister.stationOf(ref), default: []].append(Match(ref: ref, timing: timing))
            }
        }
        return stops.map { stop in
            guard let ref = stop.ref else { return nil }
            let planned = stop.sched ?? stop.dep
            let candidates = (byStation[StopRegister.stationOf(ref)] ?? []).filter {
                // The packed timetable is minute-granular. Compare against
                // the immutable printed time, never an already delayed time.
                abs($0.timing.planned - planned) < 60
            }
            let exact = candidates.filter { $0.ref == ref }
            if exact.count == 1 { return exact[0] }
            guard exact.isEmpty, candidates.count == 1 else { return nil }
            return candidates[0]
        }
    }

    /// The delay to report for the run as a whole.
    ///
    /// The largest departure delay still ahead of `now`, falling back to the
    /// last one behind it. A single number for a journey is always a
    /// simplification; this is the one a passenger means — how late is it going
    /// to be when it gets to me — rather than an average that reads as nothing
    /// much while the train sits twenty minutes down the line.
    ///
    /// Seconds, as the two accessors it reads.
    public func delay(at now: Timestamp) -> Int? {
        var ahead: Int?
        var latestBehind: (at: Timestamp, seconds: Int)?
        for timing in byStop.values {
            guard let seconds = timing.departureDelay ?? timing.arrivalDelay else { continue }
            if timing.planned >= now {
                ahead = max(ahead ?? Int.min, seconds)
            } else if timing.planned > (latestBehind?.at ?? Timestamp.min) {
                // The *most recent* call behind us, not whichever one a
                // dictionary happened to yield last. Taking an arbitrary past
                // call made a finished run report a number that changed on
                // every read while nothing about the train did.
                latestBehind = (timing.planned, seconds)
            }
        }
        return ahead ?? latestBehind?.seconds
    }
}

/// One call's planned and expected times, and the platform it is now expected at.
public struct CallTiming: Sendable, Equatable {
    public var planned: Timestamp
    public var expectedArrival: Timestamp?
    public var expectedDeparture: Timestamp?
    public var plannedArrival: Timestamp?
    public var plannedDeparture: Timestamp?
    /// The platform the operator has actually put it on, where that differs
    /// from the booked one. The single most useful thing on a departure board
    /// and the one the printed timetable can never carry.
    public var expectedQuay: String?
    public var cancelled: Bool

    public init(
        planned: Timestamp,
        expectedArrival: Timestamp? = nil, expectedDeparture: Timestamp? = nil,
        plannedArrival: Timestamp? = nil, plannedDeparture: Timestamp? = nil,
        expectedQuay: String? = nil, cancelled: Bool = false
    ) {
        self.planned = planned
        self.expectedArrival = expectedArrival
        self.expectedDeparture = expectedDeparture
        self.plannedArrival = plannedArrival
        self.plannedDeparture = plannedDeparture
        self.expectedQuay = expectedQuay
        self.cancelled = cancelled
    }

    /// Seconds — the difference of two timestamps. Anything that draws this
    /// wants minutes; see `SiriParser.reportableDelay`.
    public var arrivalDelay: Int? {
        guard let expectedArrival, let plannedArrival else { return nil }
        return expectedArrival - plannedArrival
    }

    /// Seconds, as `arrivalDelay`.
    public var departureDelay: Int? {
        guard let expectedDeparture, let plannedDeparture else { return nil }
        return expectedDeparture - plannedDeparture
    }
}

/// Read timings out of an `OJPTripInfoResponse` or an `OJPStopEventResponse`.
///
/// String scanning rather than the byte machinery `SiriParser` uses, for the
/// same reason `OJPLoad` does it: that exists because the estimated timetable is
/// 150 MB and must never be held whole. These documents are five and a hundred
/// and fifty kilobytes respectively, arrive complete, and are read once.
public enum OJPTimings {
    /// The wrappers a call arrives in inside a trip-info response.
    static let wrappers = ["PreviousCall", "OnwardCall", "ThisCall"]

    /// Times arrive as `2026-08-22T21:31:00Z` and occasionally with a numeric
    /// offset. Built once: `ISO8601DateFormatter` is expensive to create and a
    /// panel re-read at the frame rate would create thousands.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func time(_ text: String?) -> Timestamp? {
        guard let text else { return nil }
        if let date = iso.date(from: text) { return Timestamp(date.timeIntervalSince1970) }
        if let date = isoFractional.date(from: text) { return Timestamp(date.timeIntervalSince1970) }
        return nil
    }

    /// One journey's timings, from a trip-info response.
    public static func trip(_ data: Data) -> JourneyTiming {
        let xml = String(decoding: data, as: UTF8.self)
        var result = JourneyTiming(byStop: [:])
        var ordered: [Call] = []

        for (ref, body) in calls(in: xml[...]) {
            if let timing = read(body) {
                result.record(timing, at: ref)
            }
            if let stop = stop(from: body, ref: ref) { ordered.append(stop) }
        }
        result.calls = ordered

        // A cancelled run is marked on the service rather than on every call.
        result.cancelled = serviceCancelled(in: xml[...])
        return result
    }

    /// Previous / this / onward calls in document order, not grouped by wrapper.
    private static func calls(in xml: Substring) -> [(ref: String, body: Substring)] {
        var out: [(String, Substring)] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            var next: (name: String, range: Range<String.Index>)?
            for name in wrappers {
                guard let open = OJPLoad.opening(xml, name, from: cursor) else { continue }
                if next == nil || open.lowerBound < next!.range.lowerBound {
                    next = (name, open)
                }
            }
            guard let found = next,
                  let close = xml.range(of: "</\(found.name)>", range: found.range.upperBound..<xml.endIndex)
            else { break }
            let body = xml[found.range.upperBound..<close.lowerBound]
            if let ref = OJPLoad.first(body, "siri:StopPointRef") {
                out.append((ref, body))
            }
            cursor = close.upperBound
        }
        return out
    }

    private static func stop(from body: Substring, ref: String) -> Call? {
        // Passing time: the vehicle goes through and nobody may board or
        // alight. SBB omits these; absorbing them minted "exceptional" stops.
        if flag(body, "NoBoardingAtStop"), flag(body, "NoAlightingAtStop") { return nil }
        if flag(body, "NotServicedStop") { return nil }
        let arrival = OJPLoad.first(body, "ServiceArrival").map { Substring($0) }
        let departure = OJPLoad.first(body, "ServiceDeparture").map { Substring($0) }
        let plannedArr = time(arrival.flatMap { OJPLoad.first($0, "TimetabledTime") })
        let plannedDep = time(departure.flatMap { OJPLoad.first($0, "TimetabledTime") })
        let arr = plannedArr ?? time(arrival.flatMap { OJPLoad.first($0, "EstimatedTime") })
        let dep = plannedDep ?? time(departure.flatMap { OJPLoad.first($0, "EstimatedTime") })
        guard let when = arr ?? dep else { return nil }
        let name = OJPLoad.first(body, "StopPointName")
            .flatMap { OJPLoad.first(Substring($0), "Text") }
            .map { ByteScan.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? ref
        let quay = OJPLoad.first(body, "PlannedQuay")
            .flatMap { OJPLoad.first(Substring($0), "Text") }
            ?? OJPLoad.first(body, "EstimatedQuay").flatMap { OJPLoad.first(Substring($0), "Text") }
        return Call(
            key: "\(ref)|ojp",
            ref: ref,
            name: name,
            lat: 0, lon: 0,
            platform: quay.map { ByteScan.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 },
            precise: false,
            arr: arr ?? when,
            dep: dep ?? when,
            sched: plannedDep ?? plannedArr ?? dep ?? arr ?? when,
            cancelled: flag(body, "Cancelled"),
            extra: flag(body, "ExtraCall") || flag(body, "UnplannedStop")
                || (plannedArr == nil && plannedDep == nil),
            scheduledArrival: plannedArr
        )
    }

    private static func read(_ call: Substring) -> CallTiming? {
        let arrival = OJPLoad.first(call, "ServiceArrival").map { Substring($0) }
        let departure = OJPLoad.first(call, "ServiceDeparture").map { Substring($0) }

        let plannedArrival = time(arrival.flatMap { OJPLoad.first($0, "TimetabledTime") })
        let plannedDeparture = time(departure.flatMap { OJPLoad.first($0, "TimetabledTime") })
        let expectedArrival = time(arrival.flatMap { OJPLoad.first($0, "EstimatedTime") })
        let expectedDeparture = time(departure.flatMap { OJPLoad.first($0, "EstimatedTime") })

        guard let planned = plannedDeparture ?? plannedArrival else { return nil }

        // `EstimatedQuay` is present only when it differs from the booked one,
        // which is exactly when it is worth showing.
        let quay = OJPLoad.first(call, "EstimatedQuay")
            .flatMap { OJPLoad.first(Substring($0), "Text") }
            .map { ByteScan.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return CallTiming(
            planned: planned,
            expectedArrival: expectedArrival, expectedDeparture: expectedDeparture,
            plannedArrival: plannedArrival, plannedDeparture: plannedDeparture,
            expectedQuay: quay,
            cancelled: flag(call, "Cancelled") || flag(call, "NotServicedStop")
        )
    }

    /// `<Name>true</Name>` and the `ojp:`-prefixed form the schema allows.
    private static func flag(_ xml: Substring, _ name: String) -> Bool {
        xml.contains("<\(name)>true</\(name)>")
            || xml.contains("<ojp:\(name)>true</ojp:\(name)>")
    }

    private static func serviceCancelled(in xml: Substring) -> Bool {
        let service = OJPLoad.first(xml, "Service") ?? OJPLoad.first(xml, "ojp:Service")
        return service.map { flag(Substring($0), "Cancelled") } ?? false
    }

    /// Many journeys' timings at one stop, from a stop-event response.
    ///
    /// The bulk primitive: one request covers fifty departures in about eight
    /// kilobytes gzipped, so a screenful of vehicles is a handful of requests
    /// rather than one per vehicle. The journeys come back keyed by the same
    /// reference the timetable carries.
    public static func stopEvents(_ data: Data) -> [String: CallTiming] {
        let xml = String(decoding: data, as: UTF8.self)
        var out: [String: CallTiming] = [:]

        for result in OJPLoad.blocks(xml[...], "StopEventResult") {
            guard let ref = OJPLoad.first(result, "JourneyRef") else { continue }
            // The call this result is about is `ThisCall`; the service block
            // that follows carries the reference.
            let call = OJPLoad.first(result, "ThisCall").map { Substring($0) } ?? result
            guard let timing = read(call) else { continue }
            out[ref] = timing
        }
        return out
    }

    /// Whole workings at one stop, from a stop-event response with its call
    /// lists included.
    ///
    /// The packed Swiss timetable truncates international trains at the border,
    /// so Milano's board would otherwise be RE80 and nothing else. OJP still
    /// knows the EC that leaves for Zürich, and this is that list as journeys
    /// a board can merge.
    public static func stopEventJourneys(_ data: Data) -> [Journey] {
        let xml = String(decoding: data, as: UTF8.self)
        var out: [Journey] = []
        for result in OJPLoad.blocks(xml[...], "StopEventResult") {
            if let journey = eventJourney(result) { out.append(journey) }
        }
        return out
    }

    private static func eventJourney(_ result: Substring) -> Journey? {
        let event = OJPLoad.first(result, "StopEvent").map { Substring($0) } ?? result
        var stops: [Call] = []
        for (ref, body) in calls(in: event) {
            if let stop = stop(from: body, ref: ref) { stops.append(stop) }
        }
        guard !stops.isEmpty else { return nil }

        let service = OJPLoad.first(event, "Service").map { Substring($0) } ?? event
        let journeyRef = OJPLoad.first(service, "JourneyRef")
        let code = text(service, "PublicCode")
            ?? text(service, "PublishedServiceName")
            ?? text(service, "ShortName")
        let number = OJPLoad.first(service, "TrainNumber")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let dest = text(service, "DestinationText").map(StopNaming.display)
        let ptMode = OJPLoad.first(service, "PtMode")
        let mode: Mode = {
            if let ptMode {
                let fromPt = Categories.siriMode(of: ptMode)
                return fromPt == .other ? .train : fromPt
            }
            let letters = String((code ?? "").prefix { $0.isLetter })
            let fromCode = Categories.mode(of: letters)
            return fromCode == .other ? Categories.mode(of: code) : fromCode
        }()
        let line = Journey.publishedLine(lineName(code: code, number: number), mode: mode)
        let id = journeyRef ?? "ojp|\(line)|\(stops[0].dep)|\(dest ?? line)"
        let operatorRef: String? = {
            let pieces = journeyRef?.split(separator: ":") ?? []
            if pieces.count == 5, pieces[2] == "sjyid" {
                return "ch:1:sboid:\(pieces[3])"
            }
            let ref = OJPLoad.first(service, "siri:OperatorRef")
                ?? OJPLoad.first(service, "OperatorRef")
            // OJP's agency namespace is the same one used by the packed
            // timetable. Resolve it before matching live and scheduled runs.
            // Without this, a ref-less PostAuto journey has no recognised
            // operator and appears beside its timetable copy on the board.
            if let ref, ref.hasPrefix("ojp:") {
                return TimetableStore.operatorRef(ofAgency: String(ref.dropFirst(4))) ?? ref
            }
            return ref
        }()
        let journey = Journey(
            id: id,
            mode: mode,
            category: code,
            line: line,
            number: number,
            operatorName: operatorRef,
            operatorFull: nil,
            to: dest ?? stops.last.map { StopNaming.display($0.name) },
            from: StopNaming.display(stops[0].name),
            delay: stops[0].delay,
            start: stops[0].dep,
            end: stops[stops.count - 1].arr,
            complete: stops.count >= 2,
            monitored: false,
            cancelled: serviceCancelled(in: event),
            source: "ojp",
            stops: stops,
            journeyRef: journeyRef
        )
        // A stop-event board needs the estimates as well as the booked calls.
        // Keeping only the planned times made the main row look on time.
        journey.apply(trip(Data(event.utf8)), at: Timestamp(Date().timeIntervalSince1970))
        return journey
    }


    /// `RE80` is already the badge; `EC` plus train `28` is `EC28`.
    static func lineName(code: String?, number: String?) -> String {
        let code = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let number = number?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code.isEmpty { return number.isEmpty ? "?" : number }
        if number.isEmpty || code == number { return code }
        if code.contains(where: \.isNumber) { return code }
        return code + number
    }

    static func text(_ xml: Substring, _ name: String) -> String? {
        guard let inner = OJPLoad.first(xml, name) else { return nil }
        if let nested = OJPLoad.first(Substring(inner), "Text") {
            let decoded = ByteScan.decodeEntities(nested)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return decoded.isEmpty ? nil : decoded
        }
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") { return nil }
        return ByteScan.decodeEntities(trimmed)
    }
}

public extension Journey {
    /// Fold OJP's answer onto a journey the timetable produced.
    ///
    /// Match exact platform IDs first, then a unique station/scheduled-time
    /// match for a platform change. The register resolves the new platform's
    /// location without changing the call's stable timetable identity.
    ///
    /// A call OJP says nothing about keeps its timetabled times and stays
    /// unobserved — which is the honest reading. Silence from a real-time system
    /// is not a claim that a train is on time.
    @discardableResult
    func apply(
        _ timing: JourneyTiming, at now: Timestamp,
        resolve: ((String, String?) -> Place?)? = nil
    ) -> Int {
        var touched = 0
        var pathChanged = false
        // Where this vehicle is before the fold. A run that is late is late by
        // a length of track, so the correction below moves it — and read from
        // the map, a correction that lands in one frame is a teleport. See
        // `Journey.settle`.
        let anchor = Positioning.retimeAnchor(self, at: now)
        let matches = timing.matches(for: stops)
        for index in stops.indices {
            guard let match = matches[index] else { continue }
            let found = match.timing
            touched += 1

            if stops[index].sched == nil { stops[index].sched = stops[index].dep }
            let bookedDeparture = found.plannedDeparture ?? stops[index].sched ?? stops[index].dep
            let bookedArrival = found.plannedArrival ?? stops[index].scheduledArrival
                ?? (stops[index].arr - (stops[index].dep - bookedDeparture))
            stops[index].scheduledArrival = bookedArrival
            if let arrival = found.expectedArrival {
                stops[index].arr = arrival
            } else if let delay = found.departureDelay {
                stops[index].arr = bookedArrival + delay
            }
            if let departure = found.expectedDeparture {
                stops[index].dep = departure
            } else if let delay = found.arrivalDelay {
                stops[index].dep = bookedDeparture + delay
            }
            stops[index].dep = max(stops[index].arr, stops[index].dep)
            // Endpoints have one real event and one synthetic counterpart.
            // Keep those coherent when only the real event is delayed.
            if index == 0, found.plannedArrival == nil, let departure = found.expectedDeparture {
                stops[index].arr = departure
            }
            if index == stops.count - 1, found.plannedDeparture == nil, let arrival = found.expectedArrival {
                stops[index].dep = arrival
            }
            // OJP often answers for the parent station even when the packed
            // call already names its platform. That is less precise identity,
            // not a platform change: downgrading it discarded the rail path
            // and moved the selected train towards the station centre.
            let parentAnswer = match.ref == StopRegister.stationOf(stops[index].ref)
            let changedReference = match.ref != stops[index].ref && !parentAnswer
            let changedTrack = found.expectedQuay.map {
                !StopRegister.sameTrack($0, stops[index].platform)
            } ?? false
            if changedReference || changedTrack {
                stops[index].ref = match.ref
                let place = resolve?(match.ref, found.expectedQuay)
                stops[index].platform = found.expectedQuay ?? place?.platform ?? stops[index].platform
                if let place {
                    stops[index].lon = place.lon
                    stops[index].lat = place.lat
                    stops[index].precise = place.precise
                } else {
                    // An old platform coordinate must not pin the new route.
                    stops[index].precise = false
                }
                // The path was bent onto the booked platform. A different
                // quay is a different rail, so the next attach has to walk
                // the throat again. Times below are not.
                pathChanged = true
            } else if let quay = found.expectedQuay {
                // Sector detail can change on the same track without
                // invalidating its mapped approach.
                stops[index].platform = quay
            }
            // A newer statement for this booked call can reinstate it. OR-ing
            // the flag made a transient withdrawal permanent after a refresh.
            stops[index].cancelled = found.cancelled
            // Minutes, not seconds. `CallTiming` subtracts two timestamps, so
            // what it holds is seconds, and `Call.delay` is read as minutes
            // everywhere it is drawn — `Format.delay` prints it unconverted.
            // Assigning the raw difference here is what made a train one minute
            // down report `+60`.
            stops[index].delay = SiriParser.reportableDelay(found.departureDelay ?? found.arrivalDelay)
            // Observed means measured rather than forecast, and OJP draws that
            // line by time rather than by element: a call already in the past
            // with an estimate is what happened.
            stops[index].observed = found.planned < now
        }

        if touched > 0 {
            // Minutes, for the same reason, and filtered for the same reason:
            // an aimed time from a different service day subtracts to a delay
            // nobody believes.
            delay = SiriParser.reportableDelay(timing.delay(at: now))
            monitored = true
            if let first = stops.first { start = first.dep }
            if let last = stops.last { end = last.arr }
            // The path is the rails. Times are where along them the vehicle
            // stands. A tap used to throw the path away so the next frame
            // interpolated along the chord instead — the train that jumps
            // back off its track the moment somebody opens it. Keep the
            // rails unless the platform they were bent onto has actually
            // changed.
            if pathChanged { invalidateGeometry() }
            Positioning.noteRetimed(self, from: anchor, at: now)
        }
        if timing.cancelled { cancelled = true }
        return touched
    }
}
