import Foundation

/// What is happening to the timetable right now, from GTFS-Realtime.
///
/// This replaces SIRI-ET, and the numbers are why. Measured within minutes of
/// each other on the same evening:
///
/// | | SIRI-ET | GTFS-RT |
/// |---|---|---|
/// | on the wire | 7.93 MB | **1.31 MB** |
/// | to parse | 64.5 MB of XML | **4.05 MB of protobuf** |
/// | covering | 7,101 journeys | 6,295 trip updates |
///
/// Six times less to fetch and sixteen times less to walk, for the same
/// national scope — and it names runs by their GTFS `trip_id`, which is exactly
/// what `timetable.bin` keys journeys on. Where SIRI-ET needed a structural
/// matcher to reach 97.5%, this joins at **99.2%**, and the 0.8% that do not
/// match are precisely the added runs, which by definition are in no timetable.
///
/// The one thing it does not do is reach further than three hours ahead. That
/// matters not at all here: the map draws half an hour behind and an hour
/// forward, and the time control offers under three hours, so everything the
/// app can display is inside the window.
public struct RealtimeFeed: Sendable {
    public var timestamp: Timestamp
    public var updates: [TripUpdate]

    public init(timestamp: Timestamp = 0, updates: [TripUpdate] = []) {
        self.timestamp = timestamp
        self.updates = updates
    }

    public var cancelled: Int { updates.count { $0.relationship == .canceled } }
    public var added: Int { updates.count { $0.relationship == .added } }
    public var skippedStops: Int { updates.reduce(0) { $0 + $1.stops.count { $0.skipped } } }
}

/// One run, as the operator now expects it to go.
public struct TripUpdate: Sendable {
    public enum Relationship: Int, Sendable {
        case scheduled = 0
        /// A run that is not in the timetable at all — a relief working. Its
        /// `tripID` is synthetic and will not match anything, which is how it
        /// is recognised rather than a problem to solve.
        case added = 1
        case unscheduled = 2
        case canceled = 3
        case replacement = 5
        case duplicated = 6
        case deleted = 7
    }

    public var tripID: String
    public var routeID: String?
    public var startDate: String?
    public var relationship: Relationship
    /// The run-level delay in seconds, where the producer states one.
    public var delay: Int?
    public var stops: [StopTimeUpdate]

    /// Whether this run is one the timetable cannot contain.
    ///
    /// All four of these describe a working that was not planned, and all four
    /// therefore arrive under a synthetic id that matches nothing — which is
    /// how they are recognised, rather than a lookup failure to be explained.
    public var isExtra: Bool {
        switch relationship {
        case .added, .unscheduled, .duplicated, .replacement: return true
        case .scheduled, .canceled, .deleted: return false
        }
    }

    public init(
        tripID: String, routeID: String? = nil, startDate: String? = nil,
        relationship: Relationship = .scheduled, delay: Int? = nil,
        stops: [StopTimeUpdate] = []
    ) {
        self.tripID = tripID
        self.routeID = routeID
        self.startDate = startDate
        self.relationship = relationship
        self.delay = delay
        self.stops = stops
    }
}

/// One call, as it is now expected to happen.
public struct StopTimeUpdate: Sendable {
    public var stopID: String?
    public var sequence: Int?
    /// Absolute times where the producer gives them, which this feed does.
    public var arrival: Timestamp?
    public var departure: Timestamp?
    public var arrivalDelay: Int?
    public var departureDelay: Int?
    /// The vehicle passes without serving this stop — the counterpart to
    /// SIRI's cancelled call.
    public var skipped: Bool

    public init(
        stopID: String? = nil, sequence: Int? = nil,
        arrival: Timestamp? = nil, departure: Timestamp? = nil,
        arrivalDelay: Int? = nil, departureDelay: Int? = nil, skipped: Bool = false
    ) {
        self.stopID = stopID
        self.sequence = sequence
        self.arrival = arrival
        self.departure = departure
        self.arrivalDelay = arrivalDelay
        self.departureDelay = departureDelay
        self.skipped = skipped
    }
}

/// Just enough protocol-buffer decoding to read a `FeedMessage`.
///
/// Hand-written rather than generated, for the reason the Mapbox SDK is
/// vendored and the ZIP reader in `pack-timetable.mjs` is twenty lines: this
/// app has no package dependencies, and the alternative is the protobuf runtime
/// plus a code generator in the build for six fields.
///
/// Wire format is four cases and a variable-length integer. Fields this does
/// not recognise are skipped by length, which is the format's own guarantee and
/// what makes reading a subset safe — a producer adding fields cannot break it.
enum Protobuf {
    struct Reader {
        let bytes: UnsafeRawBufferPointer
        var at: Int
        let end: Int

        init(_ bytes: UnsafeRawBufferPointer, from: Int = 0, to: Int? = nil) {
            self.bytes = bytes
            self.at = from
            self.end = to ?? bytes.count
        }

        var hasMore: Bool { at < end }

        mutating func varint() -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while at < end {
                let byte = bytes.load(fromByteOffset: at, as: UInt8.self)
                at += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                // A varint longer than ten bytes is malformed; stopping keeps a
                // corrupt response from spinning rather than throwing.
                if shift > 63 { break }
            }
            return value
        }

        /// The next field's number and wire type, or nil at the end.
        mutating func next() -> (field: Int, wire: Int)? {
            guard hasMore else { return nil }
            let tag = varint()
            return (Int(tag >> 3), Int(tag & 7))
        }

        /// The bounds of a length-delimited field, having consumed it.
        mutating func region() -> Range<Int> {
            let length = Int(varint())
            let lo = at
            let hi = min(end, lo + length)
            at = hi
            return lo..<hi
        }

        mutating func string() -> String {
            let r = region()
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[r]), as: UTF8.self)
        }

        /// Step over a field this reader does not care about.
        mutating func skip(_ wire: Int) {
            switch wire {
            case 0: _ = varint()
            case 1: at = min(end, at + 8)
            case 2: _ = region()
            case 5: at = min(end, at + 4)
            default: at = end
            }
        }

        /// Protobuf stores signed ints as unsigned; reinterpret rather than clamp.
        static func signed(_ raw: UInt64) -> Int { Int(Int64(bitPattern: raw)) }
    }

    /// Read a `FeedMessage`, keeping only trip updates.
    static func feed(_ data: Data) -> RealtimeFeed {
        data.withUnsafeBytes { raw in
            var out = RealtimeFeed()
            out.updates.reserveCapacity(8_000)
            var reader = Reader(raw)
            while let (field, wire) = reader.next() {
                switch (field, wire) {
                case (1, 2):                       // FeedHeader
                    var header = Reader(raw, from: reader.region().lowerBound, to: reader.at)
                    while let (hf, hw) = header.next() {
                        if hf == 3, hw == 0 { out.timestamp = Timestamp(header.varint()) }
                        else { header.skip(hw) }
                    }
                case (2, 2):                       // FeedEntity
                    let r = reader.region()
                    if let update = entity(raw, r) { out.updates.append(update) }
                default:
                    reader.skip(wire)
                }
            }
            return out
        }
    }

    private static func entity(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> TripUpdate? {
        var reader = Reader(raw, from: range.lowerBound, to: range.upperBound)
        while let (field, wire) = reader.next() {
            if field == 3, wire == 2 {             // TripUpdate
                let r = reader.region()
                return tripUpdate(raw, r)
            }
            reader.skip(wire)
        }
        return nil
    }

    private static func tripUpdate(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> TripUpdate? {
        var reader = Reader(raw, from: range.lowerBound, to: range.upperBound)
        var out = TripUpdate(tripID: "")
        while let (field, wire) = reader.next() {
            switch (field, wire) {
            case (1, 2):                           // TripDescriptor
                let r = reader.region()
                var trip = Reader(raw, from: r.lowerBound, to: r.upperBound)
                while let (tf, tw) = trip.next() {
                    switch (tf, tw) {
                    case (1, 2): out.tripID = trip.string()
                    case (3, 2): out.startDate = trip.string()
                    case (5, 2): out.routeID = trip.string()
                    case (4, 0):
                        out.relationship = TripUpdate.Relationship(rawValue: Int(trip.varint())) ?? .scheduled
                    default: trip.skip(tw)
                    }
                }
            case (2, 2):                           // StopTimeUpdate
                let r = reader.region()
                out.stops.append(stopTime(raw, r))
            case (5, 0):
                out.delay = Reader.signed(reader.varint())
            default:
                reader.skip(wire)
            }
        }
        return out.tripID.isEmpty ? nil : out
    }

    private static func stopTime(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> StopTimeUpdate {
        var reader = Reader(raw, from: range.lowerBound, to: range.upperBound)
        var out = StopTimeUpdate()
        while let (field, wire) = reader.next() {
            switch (field, wire) {
            case (1, 0): out.sequence = Int(reader.varint())
            case (4, 2): out.stopID = reader.string()
            case (2, 2), (3, 2):                   // StopTimeEvent, arrival or departure
                let arriving = field == 2
                let r = reader.region()
                var event = Reader(raw, from: r.lowerBound, to: r.upperBound)
                var delay: Int?
                var time: Timestamp?
                while let (ef, ew) = event.next() {
                    switch (ef, ew) {
                    case (1, 0): delay = Reader.signed(event.varint())
                    case (2, 0): time = Timestamp(Reader.signed(event.varint()))
                    default: event.skip(ew)
                    }
                }
                if arriving { out.arrival = time; out.arrivalDelay = delay }
                else { out.departure = time; out.departureDelay = delay }
            case (5, 0):
                out.skipped = reader.varint() == 1
            default:
                reader.skip(wire)
            }
        }
        return out
    }
}
