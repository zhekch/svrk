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
    /// Keyed by the SLOID the call names, which is the same key the timetable's
    /// calls carry, so applying one to the other needs no matching step.
    public var byStop: [String: CallTiming]
    /// The whole run called off, as distinct from individual calls dropped.
    public var cancelled: Bool

    public init(byStop: [String: CallTiming], cancelled: Bool = false) {
        self.byStop = byStop
        self.cancelled = cancelled
    }

    public var isEmpty: Bool { byStop.isEmpty && !cancelled }

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
        var byStop: [String: CallTiming] = [:]

        for wrapper in wrappers {
            for call in OJPLoad.blocks(xml[...], wrapper) {
                guard let ref = OJPLoad.first(call, "siri:StopPointRef") else { continue }
                guard let timing = read(call) else { continue }
                // A looping route calls twice at the same stop and OJP files
                // both; the later one wins, which is the one still ahead.
                byStop[ref] = timing
            }
        }

        // A cancelled run is marked on the service rather than on every call.
        let cancelled = xml.contains("<Cancelled>true</Cancelled>")
        return JourneyTiming(byStop: byStop, cancelled: cancelled)
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
        let quay = OJPLoad.first(call, "EstimatedQuay").flatMap { OJPLoad.first(Substring($0), "Text") }

        return CallTiming(
            planned: planned,
            expectedArrival: expectedArrival, expectedDeparture: expectedDeparture,
            plannedArrival: plannedArrival, plannedDeparture: plannedDeparture,
            expectedQuay: quay,
            cancelled: call.contains("<Cancelled>true</Cancelled>")
        )
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
}

public extension Journey {
    /// Fold OJP's answer onto a journey the timetable produced.
    ///
    /// The join is by SLOID and needs no matching: both sides name the stop with
    /// the same identifier, because `stop_times.stop_id` and OJP's
    /// `StopPointRef` are the same register's keys.
    ///
    /// A call OJP says nothing about keeps its timetabled times and stays
    /// unobserved — which is the honest reading. Silence from a real-time system
    /// is not a claim that a train is on time.
    @discardableResult
    func apply(_ timing: JourneyTiming, at now: Timestamp) -> Int {
        var touched = 0
        var pathChanged = false
        // Where this vehicle is before the fold. A run that is late is late by
        // a length of track, so the correction below moves it — and read from
        // the map, a correction that lands in one frame is a teleport. See
        // `Journey.settle`.
        let anchor = Positioning.retimeAnchor(self, at: now)
        for index in stops.indices {
            guard let ref = stops[index].ref, let found = timing.byStop[ref] else { continue }
            touched += 1

            if let arrival = found.expectedArrival { stops[index].arr = arrival }
            if let departure = found.expectedDeparture { stops[index].dep = departure }
            if let quay = found.expectedQuay, stops[index].platform != quay {
                stops[index].platform = quay
                // The path was bent onto the booked platform. A different
                // quay is a different rail, so the next attach has to walk
                // the throat again. Times below are not.
                pathChanged = true
            }
            stops[index].cancelled = stops[index].cancelled || found.cancelled
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
