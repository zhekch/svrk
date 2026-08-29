import Foundation

// What the app is actually asking the network for, across everything that asks.
//
// There were already two counters and both were narrow. `OTDClient` keeps a
// sliding minute per *subscription*, because that is what the platform's rate
// limit is counted against — so there is one for the fleet feed, another for
// situations, another for the journey planner, and no way to see the sum.
// `AppModel` counts background formation requests, which is one caller of one
// of those. Between them the debug readout could say "we asked for 6 train
// formations this minute" and nothing at all about the other twenty calls or
// the thirty megabytes they brought back.
//
// This is the sum, kept in one place because "how much network is this app
// using" is one question. Every request the app makes goes through `OTDClient`
// — the GTFS-RT fleet feed, SIRI-SX situations, OJP formations and occupancy —
// so instrumenting the three ways out of that client covers all of it, and
// anything else that learns to make a request can report here too.
//
// **Two numbers per call, and they are not the same number.** The wire count is
// what a data allowance is charged: the compressed body, about 1.3 MB for a
// fleet refresh. The payload is what comes out of it, four megabytes of
// protobuf or a hundred of XML, which is the parser's workload and nobody's
// bill. Reporting only the second makes a small download look enormous;
// reporting only the first hides where a slow refresh spends its time.
//
// **A rolling minute, not a total.** A total since launch answers "has this
// been busy" and the rate answers "is it busy *now*", which is the one a person
// watching a readout is asking. Both are kept, because the total is free.

/// A tally of every request the app makes, and what it costs.
///
/// A plain object behind a lock rather than an actor, and for the same reason
/// `WagonCatalogue`'s cache is: it is written from inside network callbacks on
/// whatever thread URLSession chose, and read from a SwiftUI view four times a
/// second. An `await` in either direction would be the wrong shape for a
/// critical section that is one array append.
public final class NetworkMeter: @unchecked Sendable {
    /// The one every caller reports to.
    ///
    /// A singleton, which is a thing worth being uncomfortable about and is
    /// right here: there is one network, the question is about all of it at
    /// once, and threading a meter through four services and two actors to
    /// answer a debug readout would put the plumbing in every signature for the
    /// benefit of a line of text.
    public static let shared = NetworkMeter()

    /// One request, as it is remembered for the length of the window.
    private struct Call {
        var at: Date
        var api: String
        var wire: Int
        var payload: Int
    }

    private let lock = NSLock()
    private var window: [Call] = []
    private var totalCalls = 0
    private var totalWire = 0
    private var totalPayload = 0

    /// How long the rolling window is.
    public static let minute: TimeInterval = 60

    /// A bound on the window, so a runaway caller cannot grow it without limit.
    /// Fifty calls a minute is the most generous published limit on the
    /// platform; several hundred is already a fault worth seeing rather than a
    /// number worth keeping exactly.
    private static let cap = 600

    public init() {}

    /// Note that a request went out.
    ///
    /// Recorded when the call is *made* rather than when it returns, so the
    /// rate is right about the ones that fail, are refused, or are still in
    /// flight — which are exactly the ones somebody looking at this readout is
    /// trying to find.
    public func began(_ api: String, at moment: Date = Date()) {
        lock.lock()
        window.append(Call(at: moment, api: api, wire: 0, payload: 0))
        if window.count > Self.cap { window.removeFirst(window.count - Self.cap) }
        totalCalls += 1
        lock.unlock()
    }

    /// Note what came back, against the most recent call on that interface.
    ///
    /// Matched by interface rather than by a handle, because a handle would
    /// mean a token type threaded through three call sites to solve a problem
    /// that does not arise: the platform allows two concurrent calls on the
    /// interfaces that carry real bytes, and attributing a response to the
    /// wrong one of two identical requests changes no number this reports.
    public func received(
        _ api: String, wire: Int, payload: Int, at moment: Date = Date()
    ) {
        lock.lock()
        if let index = window.lastIndex(where: { $0.api == api && $0.wire == 0 }) {
            window[index].wire = wire
            window[index].payload = payload
        } else {
            window.append(Call(at: moment, api: api, wire: wire, payload: payload))
        }
        totalWire += wire
        totalPayload += payload
        lock.unlock()
    }

    /// What the last minute looked like.
    public func reading(at moment: Date = Date()) -> Reading {
        lock.lock()
        window.removeAll { moment.timeIntervalSince($0.at) > Self.minute }
        let recent = window
        let reading = Reading(
            callsPerMinute: recent.count,
            wirePerMinute: recent.reduce(0) { $0 + $1.wire },
            payloadPerMinute: recent.reduce(0) { $0 + $1.payload },
            calls: totalCalls,
            wire: totalWire,
            payload: totalPayload,
            byInterface: Dictionary(grouping: recent, by: \.api)
                .map { Interface(name: $0.key, calls: $0.value.count) }
                .sorted { ($0.calls, $1.name) > ($1.calls, $0.name) }
        )
        lock.unlock()
        return reading
    }

    /// Forget everything. For tests, and for a readout that has been reset.
    public func reset() {
        lock.lock()
        window.removeAll()
        totalCalls = 0
        totalWire = 0
        totalPayload = 0
        lock.unlock()
    }

    /// What the meter has to say.
    public struct Reading: Sendable, Equatable {
        /// Requests begun in the last minute, across every interface.
        public var callsPerMinute = 0
        /// Bytes over the wire in the last minute — the compressed body, which
        /// is what a data allowance is charged.
        public var wirePerMinute = 0
        /// What those bytes inflate to once decoded, which is the parser's
        /// workload rather than anybody's bill.
        public var payloadPerMinute = 0
        /// Since launch.
        public var calls = 0
        public var wire = 0
        public var payload = 0
        /// Which interfaces the last minute's calls went to, busiest first.
        public var byInterface: [Interface] = []

        public init(
            callsPerMinute: Int = 0, wirePerMinute: Int = 0, payloadPerMinute: Int = 0,
            calls: Int = 0, wire: Int = 0, payload: Int = 0,
            byInterface: [Interface] = []
        ) {
            self.callsPerMinute = callsPerMinute
            self.wirePerMinute = wirePerMinute
            self.payloadPerMinute = payloadPerMinute
            self.calls = calls
            self.wire = wire
            self.payload = payload
            self.byInterface = byInterface
        }
    }

    public struct Interface: Sendable, Equatable {
        public var name: String
        public var calls: Int

        public init(name: String, calls: Int) {
            self.name = name
            self.calls = calls
        }
    }
}
