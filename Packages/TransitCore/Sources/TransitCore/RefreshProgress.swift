import Foundation

/// What a refresh is doing right now.
///
/// A national snapshot is a hundred megabytes of XML, and on a slow build or a
/// slow link the whole thing takes minutes. For all of that time the only thing
/// the app used to say was that it was "refreshing" — one boolean, unchanged
/// from the first byte to the last, over a wait long enough that the honest
/// reading was that the app had hung. Everything here already existed as a
/// local variable inside `Fleet.refresh`; the only new thing is that it is
/// written somewhere a view can read it.
public struct RefreshProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nothing in flight.
        case idle
        /// Held back by the interface's own rate limit, with seconds to go.
        /// SIRI-ET allows two calls a minute; asking for a third waits.
        case waiting(TimeInterval)
        /// Asking, and not yet answered.
        case connecting
        /// Bytes arriving. The parser runs alongside, a chunk behind.
        case receiving
        /// The socket is done and the parser is catching up on what it buffered.
        case indexing
        /// Writing the offline copy.
        case saving
        /// The last refresh ended this way, and nothing is running.
        case failed(String)

        public var label: String {
            switch self {
            case .idle: return "Idle"
            case let .waiting(seconds):
                return "Rate limited — \(Int(seconds.rounded()))s"
            case .connecting: return "Connecting"
            case .receiving: return "Downloading"
            case .indexing: return "Reading"
            case .saving: return "Saving"
            case .failed: return "Failed"
            }
        }
    }

    public var phase: Phase = .idle
    /// Bytes actually transferred — compressed, which is what the response is
    /// and what a data allowance is spent on.
    ///
    /// Not the same number as `parsed`, and the difference is a factor of
    /// nine: the platform serves SIRI-ET gzipped, so twelve megabytes on the
    /// wire become a hundred megabytes of XML. Reporting the second as "the
    /// download" is how a 12 MB fetch came to claim it had pulled 100 MB.
    public var received = 0
    /// What the response said it would be, where it said. Nil on a chunked
    /// response with no length.
    public var expected: Int?
    /// Bytes of XML the parser has walked — the decompressed body. Behind the
    /// download by however much is buffered between the two.
    public var parsed = 0
    /// Journeys recognised so far.
    public var journeys = 0
    /// Bytes a second over the last second or so, or nil before there are two
    /// samples to measure between.
    public var bytesPerSecond: Double?
    public var startedAt: Date?

    public init() {}

    /// How long the refresh in progress — or the one just finished — has been
    /// running.
    public var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    public var isRunning: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }
}

/// The box a refresh writes its progress into.
///
/// The refresh runs on the fleet actor, its download on a URLSession delegate
/// queue and its parse on a queue of its own; the thing that wants to read the
/// result is the main actor, fifteen times a second. A lock over a value type
/// is the whole mechanism — no actor hop to read, and no possibility of the
/// reader seeing half an update.
public final class RefreshMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RefreshProgress()

    /// The last sample the rate is measured against: when, and how many bytes
    /// had arrived by then.
    private var rateAt = Date.distantPast
    private var rateBytes = 0

    public init() {}

    public var current: RefreshProgress { lock.withLock { value } }

    func begin() {
        lock.withLock {
            value = RefreshProgress()
            value.startedAt = Date()
            value.phase = .connecting
            rateAt = Date()
            rateBytes = 0
        }
    }

    func phase(_ phase: RefreshProgress.Phase) {
        lock.withLock { value.phase = phase }
    }

    /// Nothing running, but leave the counters alone so the panel can still say
    /// what the last refresh did.
    func settle(_ phase: RefreshProgress.Phase) {
        lock.withLock {
            value.phase = phase
            value.bytesPerSecond = nil
        }
    }

    /// Cumulative bytes off the wire. The rate is re-measured no more than once
    /// a second, so a chunk every few milliseconds does not turn into a figure
    /// that flickers too fast to read.
    func received(_ total: Int, expected: Int?) {
        lock.withLock {
            value.received = total
            value.expected = expected
            let now = Date()
            let since = now.timeIntervalSince(rateAt)
            guard since >= 1 else { return }
            value.bytesPerSecond = Double(total - rateBytes) / since
            rateAt = now
            rateBytes = total
        }
    }

    func parsed(_ bytes: Int, journeys: Int) {
        lock.withLock {
            value.parsed = bytes
            value.journeys = journeys
        }
    }
}
