import Foundation

/// The national timetable, read in place.
///
/// The app used to learn what was running by downloading the country: SIRI-ET
/// has no regional filter, so every refresh was 7 MB on the wire and ~150 MB of
/// XML, and almost all of it was the *timetable* — which does not change from
/// one minute to the next. This store is that timetable, packed once by
/// `scripts/pack-timetable.mjs` and mapped rather than parsed, so the map can
/// draw the whole country with the network switched off.
///
/// What makes a year fit at all is the Takt. A pattern here is a stop sequence
/// *together with its relative times*, and keyed that way the feed's 2,071,007
/// trips fold to 179,287 patterns — the same shape of journey, run every hour,
/// stored once. A trip is then a pattern, a service, and the minute it starts.
///
/// Two invariants the rest of the app depends on:
///
/// - **A day is never expanded.** A weekday holds 215,943 trips and 3.07 million
///   calls; building those as `Journey` objects would cost something like 150 MB
///   of heap for data the map cannot draw. Only the asked-for window is built,
///   and because trips are stored sorted by start minute that window is a binary
///   search and a range scan rather than a sweep.
/// - **Calls name a SLOID and nothing else.** No coordinates are stored here,
///   because `stop_times.stop_id` in this feed *is* the SLOID with platform —
///   the same key `StopRegister` is built on — so placement goes through the
///   register exactly as it does for a SIRI call.
public final class TimetableStore: @unchecked Sendable {
    static let magic = "SVTIMTB1"
    static let version: UInt32 = 3

    /// One trip: pattern, service, start minute, class, id prefix, number, id
    /// suffix. Deliberately not a multiple of four — at two million trips the
    /// padding would cost more than the unaligned loads do.
    static let tripStride = 22

    /// One call in a pattern: stop slot, and minutes from the trip's first
    /// arrival to this call's arrival and departure.
    static let callStride = 8

    private let file: MappedFile
    private let bytes: UnsafeRawBufferPointer

    private let strings: [String]

    /// Days since 1970 of the feed's first service day; the calendar bitmaps
    /// are indexed from here.
    private let feedStart: Int
    private let dayCount: Int
    private let serviceStride: Int

    private let servicesAt: Int
    private let stopsAt: Int
    private let prefixesAt: Int
    private let classesAt: Int
    private let patternIndexAt: Int
    private let patternCallsAt: Int
    private let tripsAt: Int
    private let suffixesAt: Int
    /// Format 2: the GTFS `trip_id`, which is what GTFS-Realtime names runs by.
    private let keyPairsAt: Int
    private let tripKeysAt: Int
    private let literalsAt: Int
    private let keyPairCount: Int

    /// `route_id` to the line it is published as, and the mode it runs in.
    ///
    /// Kept because GTFS-Realtime names an *added* run — one in no timetable —
    /// by its route and nothing else. Small enough (5,121 routes) to hold as a
    /// dictionary rather than searched in place.
    private var routeLines: [String: (line: String?, mode: Mode)] = [:]

    public private(set) var patternCount = 0
    public private(set) var tripCount = 0
    private let stopCount: Int
    private let classCount: Int
    private let prefixCount: Int

    /// Each pattern's last departure offset, so a window query can reject a trip
    /// that finished before the window opened without reading its calls.
    ///
    /// Built at load by touching the last call of every pattern — 179,287 reads
    /// into a mapped file, a few milliseconds — because the alternative is
    /// scanning every trip from the start of the service day.
    private var patternDuration: [UInt16] = []
    private var longestPattern = 0

    /// Start minute of every trip, in file order, which is sorted.
    ///
    /// Copied out rather than read through the mapping: the window query
    /// binary-searches it on every refresh, and two million unaligned loads to
    /// find a bound is the one place a copy pays for itself.
    private var tripStart: [UInt16] = []

    public var isReady: Bool { tripCount > 0 }

    public init(url: URL) throws {
        file = try MappedFile(url: url)
        bytes = file.buffer

        var reader = BinaryReader(file)
        try reader.expect(magic: Self.magic, version: Self.version)
        strings = try reader.readStringTable()
        try reader.align(to: 4)

        feedStart = Int(try reader.readUInt32())
        dayCount = Int(try reader.readUInt32())
        let serviceCount = Int(try reader.readUInt32())
        patternCount = Int(try reader.readUInt32())
        tripCount = Int(try reader.readUInt32())
        stopCount = Int(try reader.readUInt32())
        classCount = Int(try reader.readUInt32())
        prefixCount = Int(try reader.readUInt32())

        serviceStride = (dayCount + 7) / 8
        servicesAt = try reader.skip(serviceCount * serviceStride)
        try reader.align(to: 4)

        stopsAt = try reader.skip(stopCount * 4)
        prefixesAt = try reader.skip(prefixCount * 4)
        classesAt = try reader.skip(classCount * 16)

        patternIndexAt = try reader.skip(patternCount * 8 + 4)
        try reader.align(to: 4)
        let callBytes = Int(
            bytes.loadUnaligned(fromByteOffset: patternIndexAt + patternCount * 8, as: UInt32.self)
        )
        patternCallsAt = try reader.skip(callBytes)
        try reader.align(to: 4)

        tripsAt = try reader.skip(tripCount * Self.tripStride)
        try reader.align(to: 4)
        let suffixBytes = Int(try reader.readUInt32())
        suffixesAt = try reader.skip(suffixBytes)
        try reader.align(to: 4)

        // Trip ids. Every one of the 2,071,007 in this feed is unique and every
        // one is `<prefix>.<number>.<season>` over 5,120 distinct prefix/season
        // pairs with the number below 65,536 — so an id is two `UInt16`s, four
        // bytes, and it comes back byte for byte. Whole they would be 55.6 MB.
        let routeCount = Int(try reader.readUInt32())
        let routesAt = try reader.skip(routeCount * 12)
        try reader.align(to: 4)

        keyPairCount = Int(try reader.readUInt32())
        keyPairsAt = try reader.skip(keyPairCount * 8)
        tripKeysAt = try reader.skip(tripCount * 4)
        try reader.align(to: 4)
        let literalBytes = Int(try reader.readUInt32())
        literalsAt = try reader.skip(literalBytes)

        buildIndexes()

        let modes: [Mode] = [.train, .tram, .bus, .metro, .boat, .cable, .other]
        routeLines.reserveCapacity(routeCount)
        for i in 0..<routeCount {
            let at = routesAt + i * 12
            let id = string(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            let line = string(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            let raw = Int(bytes.loadUnaligned(fromByteOffset: at + 8, as: UInt32.self))
            guard let id, !id.isEmpty else { continue }
            routeLines[id] = (line, raw < modes.count ? modes[raw] : .other)
        }
    }

    /// What a route is published as, where the static feed knows it.
    public func route(_ id: String) -> (line: String?, mode: Mode)? { routeLines[id] }

    private func buildIndexes() {
        patternDuration = [UInt16](unsafeUninitializedCapacity: patternCount) { out, count in
            for i in 0..<patternCount {
                let at = patternIndexAt + i * 8
                let offset = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                let calls = Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
                guard calls > 0 else { out[i] = 0; continue }
                let last = patternCallsAt + offset + (calls - 1) * Self.callStride
                out[i] = bytes.loadUnaligned(fromByteOffset: last + 6, as: UInt16.self)
            }
            count = patternCount
        }
        longestPattern = Int(patternDuration.max() ?? 0)

        tripStart = [UInt16](unsafeUninitializedCapacity: tripCount) { out, count in
            for i in 0..<tripCount {
                out[i] = bytes.loadUnaligned(
                    fromByteOffset: tripsAt + i * Self.tripStride + 8, as: UInt16.self
                )
            }
            count = tripCount
        }
    }

    // MARK: - Record access

    private struct Trip {
        var pattern: Int
        var service: Int
        var start: Int
        var klass: Int
        var prefix: Int
        var number: UInt32
        var suffix: Int
    }

    private func trip(_ i: Int) -> Trip {
        let at = tripsAt + i * Self.tripStride
        return Trip(
            pattern: Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)),
            service: Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)),
            start: Int(bytes.loadUnaligned(fromByteOffset: at + 8, as: UInt16.self)),
            klass: Int(bytes.loadUnaligned(fromByteOffset: at + 10, as: UInt16.self)),
            prefix: Int(bytes.loadUnaligned(fromByteOffset: at + 12, as: UInt16.self)),
            number: bytes.loadUnaligned(fromByteOffset: at + 14, as: UInt32.self),
            suffix: Int(bytes.loadUnaligned(fromByteOffset: at + 18, as: UInt32.self))
        )
    }

    /// The GTFS `trip_id` for a row, rebuilt from its pair and its number.
    ///
    /// This is the journey's identity everywhere in the app, because it is the
    /// one identifier all three sources agree on: it is unique in the static
    /// feed, it is what GTFS-Realtime names a run by, and it is therefore the
    /// join that needs no matching step at all.
    public func tripID(row: Int) -> String {
        guard row >= 0, row < tripCount else { return "" }
        let at = tripKeysAt + row * 4
        let pair = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self))
        let value = Int(bytes.loadUnaligned(fromByteOffset: at + 2, as: UInt16.self))

        // 0xffff marks an id that did not fit the shape and was kept whole.
        guard pair != 0xffff else {
            let base = literalsAt + value
            let length = Int(bytes.loadUnaligned(fromByteOffset: base, as: UInt16.self))
            let lo = base + 2
            return String(
                decoding: UnsafeRawBufferPointer(rebasing: bytes[lo..<(lo + length)]), as: UTF8.self
            )
        }
        guard pair < keyPairCount else { return "" }
        let entry = keyPairsAt + pair * 8
        let prefix = string(bytes.loadUnaligned(fromByteOffset: entry, as: UInt32.self)) ?? ""
        let season = string(bytes.loadUnaligned(fromByteOffset: entry + 4, as: UInt32.self)) ?? ""
        return prefix + String(value) + season
    }

    private func string(_ index: UInt32) -> String? {
        index == BinaryFormat.noString || Int(index) >= strings.count ? nil : strings[Int(index)]
    }

    private func stopRef(_ slot: Int) -> String {
        guard slot < stopCount else { return "" }
        let index = bytes.loadUnaligned(fromByteOffset: stopsAt + slot * 4, as: UInt32.self)
        return string(index) ?? ""
    }

    // MARK: - Geography

    /// Where each pattern runs, so a window query can reject a trip without
    /// building it.
    ///
    /// This is what makes a launch cost the viewport rather than the country.
    /// Expanding a 90-minute window nationally builds 25,518 `Journey` objects
    /// — half a million `Call`s, a string interpolation each — and a phone
    /// opened on one canton draws about a thousand of them. The other 96% were
    /// built, placed, and never looked at.
    ///
    /// Rejecting them needs a pattern's geographic extent, and the packed file
    /// does not carry one. It does not have to: a pattern's calls name stop
    /// slots, and a slot resolves through the same register the calls are
    /// placed by. So the extent is derived here once and kept, in two layers
    /// that are both filled lazily because a national query never asks:
    ///
    /// - **Slot coordinates.** A slot is resolved to a coordinate on first use
    ///   and remembered, so the 81,756 register lookups a full resolution would
    ///   cost are only paid for the slots patterns in the window actually name.
    /// - **Pattern boxes.** The min/max over a pattern's slots, computed once
    ///   and reused by every one of its trips — the Takt means a pattern runs
    ///   every hour, so this is amortised across a dozen trips per window and
    ///   across every later window in the session.
    ///
    /// Both are plain integer arrays in the packed coordinate encoding rather
    /// than dictionaries: the whole point is to be cheaper than building the
    /// journey, and a hash lookup per call is not.
    private var slotLon: [Int32] = []
    private var slotLat: [Int32] = []
    private var patternBoxes: [Int32] = []

    /// Not yet worked out. Outside any real coordinate: longitude is bounded by
    /// 180°, which encodes to 180,000,000.
    private static let unknown = Int32.min
    /// Worked out, and there is nothing to place — a slot the register does not
    /// know, or a pattern made entirely of them.
    private static let nowhere = Int32.max

    private func prepareGeography() {
        if slotLon.count != stopCount {
            slotLon = [Int32](repeating: Self.unknown, count: stopCount)
            slotLat = [Int32](repeating: 0, count: stopCount)
        }
        if patternBoxes.count != patternCount * 4 {
            patternBoxes = [Int32](repeating: Self.unknown, count: patternCount * 4)
        }
    }

    /// Where a stop slot is, in the packed encoding, or `nil` if the register
    /// cannot place it.
    private func slotCoord(_ slot: Int, place: (String) -> Place?) -> (lon: Int32, lat: Int32)? {
        guard slot >= 0, slot < stopCount else { return nil }
        var lon = slotLon[slot]
        if lon == Self.unknown {
            let found = place(stopRef(slot))
            // `(0, 0)` is how an unplaced call is written throughout — see
            // `build` — and it is in the Gulf of Guinea rather than in
            // Switzerland, so treating it as absent here loses nothing real.
            if let found, found.lat != 0 || found.lon != 0 {
                lon = BinaryFormat.encode(found.lon)
                slotLon[slot] = lon
                slotLat[slot] = BinaryFormat.encode(found.lat)
            } else {
                lon = Self.nowhere
                slotLon[slot] = lon
            }
        }
        guard lon != Self.nowhere else { return nil }
        return (lon, slotLat[slot])
    }

    /// The box a pattern's calls span, or `nil` if none of them can be placed.
    ///
    /// A journey is drawn between its calls, so the calls' own extent bounds
    /// every position it can be at — with one exception the caller pads for:
    /// a train bent onto its mapped rails can bow a little outside the chord.
    private func patternBox(
        _ pattern: Int, place: (String) -> Place?
    ) -> (w: Int32, s: Int32, e: Int32, n: Int32)? {
        let at = pattern * 4
        var west = patternBoxes[at]
        if west == Self.unknown {
            let index = patternIndexAt + pattern * 8
            let offset = Int(bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self))
            let count = Int(bytes.loadUnaligned(fromByteOffset: index + 4, as: UInt32.self))
            var minLon = Int32.max, maxLon = Int32.min
            var minLat = Int32.max, maxLat = Int32.min
            var placed = 0
            for c in 0..<count {
                let base = patternCallsAt + offset + c * Self.callStride
                let slot = Int(bytes.loadUnaligned(fromByteOffset: base, as: UInt32.self))
                guard let found = slotCoord(slot, place: place) else { continue }
                placed += 1
                minLon = min(minLon, found.lon); maxLon = max(maxLon, found.lon)
                minLat = min(minLat, found.lat); maxLat = max(maxLat, found.lat)
            }
            // One placed call is enough to keep, and that is not a rounding of
            // the rule but the same rule `build` applies: it wants two calls
            // and *one* of them placed. Rejecting on fewer than two placed
            // would drop journeys the national pass keeps, and a filter that
            // loses vehicles is worse than one that saves nothing.
            guard placed > 0 else {
                patternBoxes[at] = Self.nowhere
                return nil
            }
            patternBoxes[at] = minLon
            patternBoxes[at + 1] = minLat
            patternBoxes[at + 2] = maxLon
            patternBoxes[at + 3] = maxLat
            west = minLon
        }
        guard west != Self.nowhere else { return nil }
        return (west, patternBoxes[at + 1], patternBoxes[at + 2], patternBoxes[at + 3])
    }

    /// A region in the packed encoding, which is what the boxes are compared in.
    private struct Clip {
        var west: Int32, south: Int32, east: Int32, north: Int32

        init(_ box: BBox) {
            west = BinaryFormat.encode(box.west)
            south = BinaryFormat.encode(box.south)
            east = BinaryFormat.encode(box.east)
            north = BinaryFormat.encode(box.north)
        }
    }

    private func pattern(
        _ pattern: Int, intersects clip: Clip, place: (String) -> Place?
    ) -> Bool {
        guard let box = patternBox(pattern, place: place) else { return false }
        return box.w <= clip.east && box.e >= clip.west
            && box.s <= clip.north && box.n >= clip.south
    }

    private struct Class {
        var line: String?
        var headsign: String?
        var agency: String?
        var mode: Mode
    }

    private func klass(_ i: Int) -> Class {
        let at = classesAt + i * 16
        func field(_ n: Int) -> UInt32 {
            bytes.loadUnaligned(fromByteOffset: at + n * 4, as: UInt32.self)
        }
        let raw = Int(field(3))
        let modes: [Mode] = [.train, .tram, .bus, .metro, .boat, .cable, .other]
        return Class(
            line: string(field(0)), headsign: string(field(1)), agency: string(field(2)),
            mode: raw < modes.count ? modes[raw] : .other
        )
    }

    /// Rebuild the OJP journey reference from its interned prefix and packed
    /// tail, or nil where the feed gives this run none.
    ///
    /// The tail is stored as what it is rather than as the text it is written
    /// in — 47% of these are a UUID and most of the rest an integer — so this is
    /// where those become characters again. It has to be exact: a reference that
    /// does not come back byte for byte is one OJP will not answer to.
    private func journeyRef(prefix: Int, suffix at: Int) -> String? {
        guard bytes.load(fromByteOffset: suffixesAt + at, as: UInt8.self) != 3 else { return nil }

        let head: String
        if prefix < prefixCount {
            let index = bytes.loadUnaligned(fromByteOffset: prefixesAt + prefix * 4, as: UInt32.self)
            head = string(index) ?? ""
        } else {
            head = ""
        }

        let base = suffixesAt + at
        switch bytes.load(fromByteOffset: base, as: UInt8.self) {
        case 1:
            var hex = ""
            hex.reserveCapacity(36)
            for i in 0..<16 {
                if i == 4 || i == 6 || i == 8 || i == 10 { hex.append("-") }
                let byte = bytes.load(fromByteOffset: base + 1 + i, as: UInt8.self)
                hex.append(String(format: "%02x", byte))
            }
            return head + hex
        case 2:
            let value = bytes.loadUnaligned(fromByteOffset: base + 1, as: UInt32.self)
            return head + String(value)
        default:
            let length = Int(bytes.loadUnaligned(fromByteOffset: base + 1, as: UInt16.self))
            let lo = base + 3
            let text = String(
                decoding: UnsafeRawBufferPointer(rebasing: bytes[lo..<(lo + length)]), as: UTF8.self
            )
            return head + text
        }
    }

    /// The operator reference a Swiss Journey ID names, or nil.
    ///
    /// `ch:1:sjyid:100058:2806-001` carries its operator in the third field,
    /// and that field is an SBOID — the same key `OperatorRegister` is built
    /// on. The timetable's own `agency_id` is not the same key space: GTFS
    /// files it as `801`, `11`, `sbg034`, and the federal register has never
    /// heard of any of them. Resolving the operator through the agency id
    /// therefore named nobody on every single timetabled run, and a vehicle
    /// with no operator is drawn in no livery.
    ///
    /// 432 of the 441 prefixes in the packed year resolve this way. The nine
    /// that do not are foreign — `ch:1:sjyid:AT817000:`, `DE807000` — and nil
    /// is the right answer for those: the register is Swiss.
    static func operatorRef(ofJourneyRef ref: String?) -> String? {
        guard let ref else { return nil }
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[2].lowercased() == "sjyid",
              !parts[3].isEmpty, parts[3].allSatisfy(\.isNumber)
        else { return nil }
        return "ch:1:sboid:\(parts[3])"
    }

    /// The moments the packed feed can answer for.
    ///
    /// The whole point of having an archive rather than a snapshot: `feedStart`
    /// is the first service day and `dayCount` how many follow, so this is a
    /// year wide and every minute inside it draws from the file with no network
    /// at all. It is also the only *real* bound on the clock — before this
    /// existed, the app had to measure how far the SIRI snapshot in hand could
    /// be stretched, which is a couple of hours and a falloff to apologise for.
    ///
    /// The upper edge is the start of the day after the last service day, so
    /// the last day is offered whole rather than up to its own midnight.
    public func span(zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current) -> ClosedRange<Timestamp>? {
        guard isReady, dayCount > 0 else { return nil }
        // Midday UTC on the day in question, which lands on the same calendar
        // date in Zurich either side of the clocks changing — `dayStart` then
        // reads that date and steps back to the service day's own zero.
        func midday(_ index: Int) -> Date {
            Date(timeIntervalSince1970: TimeInterval((feedStart + index) * 86400 + 43_200))
        }
        guard let first = Self.dayStart(midday(0), zone: zone),
              let last = Self.dayStart(midday(dayCount - 1), zone: zone),
              first < last + 86_400
        else { return nil }
        return first...(last + 86_400)
    }

    private func runs(service: Int, onDay day: Int) -> Bool {
        guard day >= 0, day < dayCount, service >= 0 else { return false }
        let byte = bytes.load(fromByteOffset: servicesAt + service * serviceStride + day / 8, as: UInt8.self)
        return byte >> UInt8(day % 8) & 1 == 1
    }

    // MARK: - The window query

    /// The service day a GTFS time is measured from.
    ///
    /// Not local midnight, deliberately. GTFS counts from "noon minus twelve
    /// hours" so that the two days a year when midnight is 23 or 25 hours away
    /// do not shift every departure on them by an hour. Taking noon and
    /// stepping back is the rule as written, and it is the only handling of it
    /// that survives the clocks changing.
    static func dayStart(_ day: Date, zone: TimeZone) -> Timestamp? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = 12
        parts.minute = 0
        parts.second = 0
        guard let noon = calendar.date(from: parts) else { return nil }
        return Timestamp(noon.timeIntervalSince1970) - 12 * 3600
    }

    private static func daysSince1970(_ day: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        var utc = DateComponents()
        utc.year = parts.year
        utc.month = parts.month
        utc.day = parts.day
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = gregorian.date(from: utc) else { return 0 }
        return Int(date.timeIntervalSince1970) / 86400
    }

    /// The first trip whose start minute is at or after `minute`.
    private func lowerBound(_ minute: Int) -> Int {
        var lo = 0
        var hi = tripCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(tripStart[mid]) < minute { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// What the timetable says is running between two moments.
    ///
    /// - Parameters:
    ///   - place: resolves a SLOID to a coordinate, as `StopRegister.lookup`
    ///     does for a SIRI call.
    ///   - operatorName: the printed name for an operator reference. Given an
    ///     SBOID read out of the run's journey reference — see `operatorRef` —
    ///     because that is the key the register is built on.
    ///   - limit: a ceiling on how many journeys to build. The busiest hour of a
    ///     weekday has 20,988 vehicles moving at once, which is the same order
    ///     as the SIRI fleet this replaces, but a caller asking for a whole day
    ///     would otherwise get three million calls.
    public func journeys(
        from: Timestamp,
        to: Timestamp,
        zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current,
        limit: Int = 30_000,
        in region: BBox? = nil,
        place: (String) -> Place?,
        operatorName: (String) -> String? = { _ in nil }
    ) -> [Journey] {
        guard isReady, to >= from else { return [] }

        // Clipped, this builds what a viewport can draw instead of what the
        // country is running. See `patternBox`; `nil` is the national pass and
        // costs nothing extra.
        var clip: Clip?
        if let region {
            prepareGeography()
            // A quarter of the viewport on each side, and the filter is far
            // more forgiving than that sounds. A pattern box is the extent of
            // the *whole route*, not of the vehicle: a Geneva–Zurich run is
            // kept for a reader looking at either end, and at every station
            // between. So this errs towards building journeys that will not be
            // drawn, which costs a little, rather than dropping one that would
            // have been, which is a vehicle missing from the map. The margin
            // covers the rest — a train bent onto its rails standing slightly
            // off the chord its calls describe.
            clip = Clip(region.padded(by: 0.25))
        }

        var out: [Journey] = []
        out.reserveCapacity(min(limit, region == nil ? 24_000 : 4_000))

        // A run filed under yesterday can still be moving — a night service
        // leaves at 25:40 — so the day before the window is always considered.
        let firstDay = Date(timeIntervalSince1970: TimeInterval(from) - 86400)
        let lastDay = Date(timeIntervalSince1970: TimeInterval(to))
        var cursor = firstDay
        while cursor <= lastDay {
            defer { cursor = cursor.addingTimeInterval(86400) }
            guard let dayZero = Self.dayStart(cursor, zone: zone) else { continue }
            let index = Self.daysSince1970(cursor, zone: zone) - feedStart
            guard index >= 0, index < dayCount else { continue }

            let lo = Int((from - dayZero) / 60) - longestPattern
            let hi = Int((to - dayZero) / 60)
            guard hi >= 0 else { continue }

            var i = lowerBound(max(lo, 0))
            while i < tripCount, out.count < limit {
                let start = Int(tripStart[i])
                if start > hi { break }
                defer { i += 1 }

                let record = trip(i)
                guard record.pattern < patternCount else { continue }
                // The cheap rejections first: a trip that had already finished,
                // then one that does not run today. Both are far cheaper than
                // reading the pattern's calls.
                if start + Int(patternDuration[record.pattern]) < Int((from - dayZero) / 60) { continue }
                guard runs(service: record.service, onDay: index) else { continue }
                // Last of the cheap rejections, because it is the only one that
                // can have work to do the first time it is asked: a pattern
                // whose box has never been worked out resolves its slots here.
                // Every later trip of the same pattern — and there are a dozen
                // an hour — reads the answer.
                if let clip, !pattern(record.pattern, intersects: clip, place: place) { continue }

                if let journey = build(record, row: i, dayZero: dayZero, place: place, operatorName: operatorName) {
                    out.append(journey)
                }
            }
        }
        return out
    }

    private func build(
        _ record: Trip,
        row: Int,
        dayZero: Timestamp,
        place: (String) -> Place?,
        operatorName: (String) -> String?
    ) -> Journey? {
        let at = patternIndexAt + record.pattern * 8
        let offset = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
        let count = Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
        guard count > 0 else { return nil }

        let info = klass(record.klass)
        let origin = dayZero + Timestamp(record.start) * 60
        // Read once: it is both what OJP is asked under and where the operator
        // is named.
        let ref = journeyRef(prefix: record.prefix, suffix: record.suffix)

        var calls: [Call] = []
        calls.reserveCapacity(count)
        // A looping route calls at the same stop twice, and the two are
        // different calls — so the visit number is part of a call's identity
        // here exactly as it is in the SIRI parser.
        var visits: [String: Int] = [:]

        for c in 0..<count {
            let base = patternCallsAt + offset + c * Self.callStride
            let slot = Int(bytes.loadUnaligned(fromByteOffset: base, as: UInt32.self))
            let arriveAt = Int(bytes.loadUnaligned(fromByteOffset: base + 4, as: UInt16.self))
            let departAt = Int(bytes.loadUnaligned(fromByteOffset: base + 6, as: UInt16.self))

            let ref = stopRef(slot)
            guard !ref.isEmpty else { continue }
            let visit = (visits[ref] ?? 0) + 1
            visits[ref] = visit

            let found = place(ref)
            let arrive = origin + Timestamp(arriveAt) * 60
            let depart = origin + Timestamp(departAt) * 60

            calls.append(Call(
                key: "\(ref)|\(visit)",
                ref: ref,
                name: found?.name ?? ref,
                lat: found?.lat ?? 0,
                lon: found?.lon ?? 0,
                platform: found?.platform,
                precise: found?.precise ?? false,
                arr: arrive,
                dep: depart,
                delay: nil,
                // Nothing here has been observed. It is the printed timetable,
                // and saying so is what keeps a forecast from being drawn as a
                // measurement once OJP has been asked and has not answered.
                observed: false,
                sched: depart,
                assigned: found?.assigned
            ))
        }

        // A call the register cannot place has no coordinate, and a journey of
        // those is a line through the sea. Two placed calls is the minimum that
        // can be drawn at all.
        guard calls.count >= 2, calls.contains(where: { $0.lat != 0 || $0.lon != 0 }) else { return nil }

        // Identity is the GTFS `trip_id`. It is unique across the whole feed,
        // it is what GTFS-Realtime names a run by, and using it here is what
        // makes applying the live feed a dictionary lookup rather than a match.
        // The journey *reference* is a different thing and stays separate: it
        // is absent on 20.7% of a weekday's trips and duplicated across others.
        return Journey(
            id: tripID(row: row),
            mode: info.mode,
            category: nil,
            line: info.line ?? "",
            number: string(record.number),
            operatorName: Self.operatorRef(ofJourneyRef: ref).flatMap(operatorName),
            operatorFull: nil,
            to: info.headsign,
            from: calls[0].name,
            delay: nil,
            start: calls[0].dep,
            end: calls[calls.count - 1].arr,
            complete: true,
            monitored: false,
            cancelled: false,
            source: Journey.timetableSource,
            stops: calls,
            journeyRef: ref
        )
    }
}

public extension Journey {
    /// Marks a journey the timetable produced rather than a feed.
    ///
    /// Worth a name of its own because the distinction is user-visible: a
    /// timetabled journey is what is *meant* to happen and carries no delay, and
    /// the panel says so rather than implying a silence means punctuality.
    static let timetableSource = "timetable"

    var isTimetabled: Bool { source == Journey.timetableSource }
}
