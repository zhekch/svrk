import Foundation

/// Client for opentransportdata.swiss, the official platform.
///
/// Each interface is a separate subscription with its own token and its own
/// limits, so there is no single budget to keep — there are several, and they
/// differ by an order of magnitude. SIRI-ET allows two calls a minute and three
/// thousand a day; most others allow fifty a minute. Exceeding either is a 429,
/// and the day quota does not recover until midnight.
public actor OTDClient {
    public struct API: Sendable {
        public var path: String
        public var perMinute: Int
        public var perDay: Int?
        public var accept: String
    }

    /// The interfaces this app knows how to talk to. `perMinute`/`perDay` are
    /// the platform's published limits, applied here rather than discovered by
    /// being refused.
    ///
    /// GTFS-Realtime: the whole country's live deviations as protobuf.
    ///
    /// What SIRI-ET used to be for, at a sixth of the bytes and a sixteenth of
    /// the parse — 1.31 MB on the wire against 7.93 MB, 4.05 MB decoded against
    /// 64.5 MB of XML. Cached upstream for thirty seconds, so there is nothing
    /// to gain by asking faster than the two calls a minute it allows.
    public static let gtfsRT = API(
        path: "/la/gtfs-rt", perMinute: 2, perDay: 3000, accept: "application/octet-stream"
    )

    /// Situation exchange, both halves.
    ///
    /// One subscription and therefore one budget: the platform answers both
    /// paths with the same `X-Ratelimit-Limit: 3000` counter, and a client
    /// shares its window across every interface it holds, so the two are
    /// accounted together by construction. The per-minute figure is not
    /// published for these and is set to the tight one — a burst of four
    /// requests inside five seconds is refused.
    public static let siriSx = API(
        path: "/la/siri-sx", perMinute: 2, perDay: 3000, accept: "text/xml"
    )
    public static let siriSxUnplanned = API(
        path: "/la/siri-sx-unplanned", perMinute: 2, perDay: 3000, accept: "text/xml"
    )

    /// Open Journey Planner 2.0. The only interface here that is asked rather
    /// than downloaded: one POSTed XML request about one journey or one stop,
    /// answered in kilobytes. Fifty a minute, and no published daily cap.
    public static let ojp = API(
        path: "/ojp20", perMinute: 50, perDay: nil, accept: "application/xml"
    )

    static let base = URL(string: "https://api.opentransportdata.swiss")!
    /// The platform rejects requests without one.
    static let userAgent = "swiss-live-transit-ios/1.0"

    private let token: String?
    private var recent: [Date] = []
    private var day = Calendar(identifier: .gregorian).startOfDay(for: Date())
    private var today = 0

    /// Where the sliding minute is kept between launches, or nil to keep it
    /// only in memory.
    ///
    /// The window used to start empty on every launch, which is wrong in the
    /// one direction that matters: the platform is still counting the calls the
    /// last run made. Two builds in a minute — an ordinary thing to do while
    /// working on the app — and the second launch asks immediately, inside a
    /// window it has forgotten about, and is refused with a 429 that the
    /// client's own accounting said could not happen.
    private let budgetKey: String?

    public private(set) var calls = 0
    public private(set) var throttled = 0
    public private(set) var errors = 0
    public private(set) var lastError: String?

    /// What the platform itself says is left of the day, read off the response
    /// headers rather than counted here. Nil until a call has been answered.
    public private(set) var quotaRemaining: Int?
    public private(set) var quotaLimit: Int?
    /// When the daily counter rolls over, as the platform reports it.
    public private(set) var quotaResetsAt: Date?

    /// - Parameter budget: a name for the subscription this client speaks for,
    ///   under which its rate-limit window is remembered across launches. The
    ///   platform counts per subscription, so the name is the subscription's,
    ///   not the interface's.
    public init(token: String?, budget: String? = nil) {
        self.token = token
        self.budgetKey = budget.map { "otd.window.\($0)" }
        if let budgetKey,
           let stored = UserDefaults.standard.array(forKey: budgetKey) as? [Double] {
            let now = Date()
            recent = stored.map(Date.init(timeIntervalSince1970:))
                .filter { now.timeIntervalSince($0) < 60 }
        }
    }

    private func rememberWindow() {
        guard let budgetKey else { return }
        UserDefaults.standard.set(recent.map(\.timeIntervalSince1970), forKey: budgetKey)
    }

    /// What the platform said about the budget on its way past.
    ///
    /// Every response carries these, including the ones that refuse. Taking
    /// them from the wire rather than counting locally is the only way to be
    /// right about a quota shared with anything else holding the same token.
    private func note(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else { return }
        func number(_ field: String) -> Int? {
            (http.value(forHTTPHeaderField: field)).flatMap(Int.init)
        }
        if let remaining = number("X-Ratelimit-Remaining") { quotaRemaining = remaining }
        if let limit = number("X-Ratelimit-Limit") { quotaLimit = limit }
        if let reset = number("X-Ratelimit-Reset") {
            quotaResetsAt = Date(timeIntervalSince1970: TimeInterval(reset))
        }
    }

    /// The budget as a whole, for a panel that has to explain a refusal.
    public struct Limits: Sendable, Equatable {
        public var remaining: Int?
        public var limit: Int?
        public var resetsAt: Date?
        /// Calls made in the last minute, against what the interface allows.
        public var inLastMinute = 0
        public var perMinute = 0

        public init(
            remaining: Int? = nil, limit: Int? = nil, resetsAt: Date? = nil,
            inLastMinute: Int = 0, perMinute: Int = 0
        ) {
            self.remaining = remaining
            self.limit = limit
            self.resetsAt = resetsAt
            self.inLastMinute = inLastMinute
            self.perMinute = perMinute
        }
    }

    public func limits(_ api: API) -> Limits {
        let now = Date()
        return Limits(
            remaining: quotaRemaining, limit: quotaLimit, resetsAt: quotaResetsAt,
            inLastMinute: recent.count { now.timeIntervalSince($0) < 60 },
            perMinute: api.perMinute
        )
    }

    public var isConfigured: Bool { token?.isEmpty == false }

    /// How long to wait before a call would be within its limits, or nil when
    /// the daily quota is spent and waiting will not help.
    func delayBefore(_ api: API) -> TimeInterval? {
        rollOver()
        if let perDay = api.perDay, today >= perDay { return nil }
        // The platform's own count outranks the local one, which starts at zero
        // on every launch and knows nothing of what anything else holding this
        // token has spent.
        if let quotaRemaining, quotaRemaining <= 0 { return nil }

        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) >= 60 }
        if recent.count < api.perMinute { return 0 }
        // The window is a sliding minute, so the next slot opens when the
        // oldest call in it ages out.
        guard let oldest = recent.first else { return 0 }
        return max(0, 60 - now.timeIntervalSince(oldest) + 0.05)
    }

    /// How many more calls this interface will take in the current minute.
    ///
    /// Exposed so a caller doing work nobody asked for can leave room for work
    /// somebody did. The window is shared per subscription, so a background
    /// sweep that spends every slot does not merely slow itself down — it makes
    /// the next panel somebody opens fail with a rate limit, which looks
    /// exactly like a train that has no formation.
    public func headroom(_ api: API) -> Int {
        rollOver()
        if let perDay = api.perDay, today >= perDay { return 0 }
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) >= 60 }
        return max(0, api.perMinute - recent.count)
    }

    private func rollOver() {
        let start = Calendar(identifier: .gregorian).startOfDay(for: Date())
        if start != day {
            day = start
            today = 0
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noToken
        case quotaExhausted
        case wouldWait(TimeInterval)
        case http(Int)

        public var description: String {
            switch self {
            case .noToken: return "no token for this interface"
            case .quotaExhausted: return "daily quota spent"
            case let .wouldWait(seconds): return "rate limited for \(Int(seconds))s"
            // 429 is the one status worth spelling out. SIRI-ET allows two
            // calls a minute, and the way to meet this is to ask for a refresh
            // twice in quick succession — which is exactly what someone does
            // when the first one looked like it had hung.
            case .http(429): return "rate limited (HTTP 429) — this interface allows two calls a minute"
            case .http(401), .http(403): return "token refused (HTTP 401/403)"
            case let .http(code): return "HTTP \(code)"
            }
        }
    }

    /// One ordinary request, answered in one buffer.
    ///
    /// The counterpart to `stream` for the interfaces that answer in kilobytes
    /// rather than in megabytes — the formation service returns about 20 KB for
    /// a sixteen-coach train, and there is nothing to be gained by taking it a
    /// chunk at a time. Shares the same window, because the platform's limits
    /// are counted per subscription and each client holds one.
    public func fetch(_ api: API, query: String, maxWait: TimeInterval = 20) async throws -> Data {
        try await reserve(api, maxWait: maxWait)

        var components = URLComponents(
            url: Self.base.appendingPathComponent(api.path), resolvingAgainstBaseURL: false
        )
        components?.percentEncodedQuery = query.isEmpty ? nil : query
        guard let url = components?.url else { throw Failure.http(0) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(api.accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            note(response)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                errors += 1
                lastError = "HTTP \(code)"
                if code == 429 { throttled += 1 }
                throw Failure.http(code)
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            errors += 1
            lastError = error.localizedDescription
            throw error
        }
    }

    /// One request with a body, answered in one buffer.
    ///
    /// The counterpart to `fetch` for OJP, which is the one interface on this
    /// platform that asks a question rather than downloading an answer: the
    /// request is an XML document and there is no way to put it in a query
    /// string. Shares the same window as everything else this client holds,
    /// because the platform counts per subscription.
    public func post(
        _ api: API, body: Data, contentType: String = "application/xml",
        maxWait: TimeInterval = 20
    ) async throws -> Data {
        try await reserve(api, maxWait: maxWait)

        var request = URLRequest(url: Self.base.appendingPathComponent(api.path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(api.accept, forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            note(response)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                errors += 1
                lastError = "HTTP \(code)"
                if code == 429 { throttled += 1 }
                throw Failure.http(code)
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            errors += 1
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Take a slot in the window, waiting for one where waiting is short enough
    /// to be worth it.
    private func reserve(
        _ api: API, maxWait: TimeInterval, monitor: RefreshMonitor? = nil
    ) async throws {
        guard let token, !token.isEmpty else { throw Failure.noToken }

        guard let wait = delayBefore(api) else {
            throttled += 1
            throw Failure.quotaExhausted
        }
        if wait > maxWait {
            throttled += 1
            throw Failure.wouldWait(wait)
        }
        if wait > 0 {
            // A minute of waiting for a rate-limit slot looks exactly like a
            // minute of a stalled download unless it is said out loud.
            monitor?.phase(.waiting(wait))
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            monitor?.phase(.connecting)
        }

        recent.append(Date())
        rememberWindow()
        today += 1
        calls += 1
    }

    /// Stream one of the interfaces, handing back chunks as they arrive.
    ///
    /// SIRI-ET decompresses to about 150 MB, which there is no reason to hold
    /// in memory when the parser consumes it a journey at a time. URLSession
    /// negotiates and undoes the response's gzip itself, so what arrives here
    /// is already plain XML — about 7 MB on the wire becoming 150 MB of chunks.
    public func stream(
        _ api: API, maxWait: TimeInterval = 65, monitor: RefreshMonitor? = nil,
        onChunk: @Sendable @escaping (Data) -> Void
    ) async throws {
        try await reserve(api, maxWait: maxWait, monitor: monitor)

        var request = URLRequest(url: Self.base.appendingPathComponent(api.path))
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(api.accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 180

        do {
            let answer = try await ChunkedDownload.run(
                request: request, monitor: monitor, onChunk: onChunk
            )
            note(answer.response)
            let received = answer.status
            guard (200..<300).contains(received) else {
                errors += 1
                lastError = "HTTP \(received)"
                if received == 429 { throttled += 1 }
                throw Failure.http(received)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            errors += 1
            lastError = error.localizedDescription
            throw error
        }
    }
}

/// A download delivered as `Data` chunks rather than one buffer.
///
/// `URLSession.bytes(for:)` would be the obvious API and is the wrong one here:
/// it yields a byte at a time through an `AsyncSequence`, and a suspension point
/// per byte over 150 MB is not a cost this can absorb. The delegate hands over
/// whole chunks as the socket produces them, which is what the parser wants
/// anyway.
///
/// The chunks are handed *on* to a queue of their own rather than parsed where
/// they land. `didReceive` runs on the session's delegate queue, and whatever
/// happens inside it is the socket's flow control: with the parse in there, a
/// response the network delivers in a second took **six minutes**, because
/// URLSession will not read faster than the delegate returns. Measured, on the
/// national feed: 11.7 MB of gzip, `transaction_duration_ms=352114`, an
/// effective 307 kbps on a link that does 10 MB/s. The parse costs what it
/// costs — around 27 seconds unoptimised — but it no longer costs it *twelve
/// times over*, and the two now overlap instead of taking turns.
final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// How far the socket may run ahead of the parser.
    ///
    /// The point of streaming was never to hold the response in memory, and an
    /// unbounded hand-off would do exactly that — a hundred megabytes of XML
    /// queued behind a parser thirty times slower than the wire. This is the
    /// buffer that keeps the parser fed without keeping the response: enough
    /// that an ordinary stall on either side is invisible, small enough to be a
    /// rounding error against what the fleet itself occupies.
    static let bufferLimit = 24 << 20

    /// Blocks the producer while the consumer is too far behind.
    ///
    /// Overshoots by at most one chunk, deliberately: a `waitUntil` that
    /// admitted nothing once the limit was reached would deadlock on a single
    /// chunk larger than the limit.
    private final class Gate {
        private let condition = NSCondition()
        private var outstanding = 0
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func acquire(_ bytes: Int) {
            condition.lock()
            while outstanding >= limit { condition.wait() }
            outstanding += bytes
            condition.unlock()
        }

        func release(_ bytes: Int) {
            condition.lock()
            outstanding -= bytes
            condition.broadcast()
            condition.unlock()
        }
    }

    private let onChunk: (Data) -> Void
    private let monitor: RefreshMonitor?
    private let gate = Gate(limit: ChunkedDownload.bufferLimit)
    /// Serial, so chunks reach the parser in the order the socket produced
    /// them — a parser that keeps a partial element across calls has no way to
    /// recover from any other order.
    private let parsing = DispatchQueue(label: "otd.parse", qos: .userInitiated)
    /// What the transfer ended as: the destination's status, and the response
    /// it came on so the caller can read the platform's budget headers off it.
    struct Answer: @unchecked Sendable {
        var status: Int
        var response: HTTPURLResponse?
    }

    private var continuation: CheckedContinuation<Answer, Error>?
    private var status = 0
    private var response: HTTPURLResponse?
    /// Decompressed bytes handed on, kept only as a fallback for a transport
    /// that will not say how many went over the wire.
    private var parsedBytes = 0

    private init(monitor: RefreshMonitor?, onChunk: @escaping (Data) -> Void) {
        self.monitor = monitor
        self.onChunk = onChunk
    }

    static func run(
        request: URLRequest, monitor: RefreshMonitor? = nil,
        onChunk: @Sendable @escaping (Data) -> Void
    ) async throws -> Answer {
        let delegate = ChunkedDownload(monitor: monitor, onChunk: onChunk)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    /// Follow the platform's redirect, without the credentials.
    ///
    /// Both SX paths answer `302` to a presigned CloudFront URL on
    /// `largeapi.opentransportdata.swiss`. The signature in the query *is* the
    /// authorisation there, and carrying a `Bearer` header onto a host that did
    /// not issue it is both pointless and a way to hand a token to whatever the
    /// redirect happens to name. Stripped rather than trusted.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var forwarded = request
        if request.url?.host != task.originalRequest?.url?.host {
            forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        // The redirect's own status is not the transfer's; the destination
        // will report that. The budget headers, though, are on *this* response
        // — the presigned host that answers the redirect knows nothing about
        // the subscription — so they are kept rather than replaced.
        note(response)
        status = 0
        return forwarded
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        self.response = response as? HTTPURLResponse
        status = self.response?.statusCode ?? 0
        if (200..<300).contains(status) { monitor?.phase(.receiving) }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Two different numbers, and only one of them is "the download".
        // `countOfBytesReceived` is the wire — twelve megabytes of gzip, and
        // what a data allowance is actually charged. `data.count` is what that
        // inflates to, around a hundred megabytes of XML, which is the parser's
        // workload and nobody's bill.
        parsedBytes += data.count
        let wire = Int(dataTask.countOfBytesReceived)
        let expected = Int(dataTask.countOfBytesExpectedToReceive)
        monitor?.received(
            wire > 0 ? wire : parsedBytes, expected: expected > 0 ? expected : nil
        )
        // Blocks only once the parser is a whole buffer behind, which is the
        // one case where reading faster would just be filling memory.
        gate.acquire(data.count)
        parsing.async { [self] in
            onChunk(data)
            gate.release(data.count)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The socket is finished; the parser is not. Everything already handed
        // over has to be through before the caller is told the response is
        // complete, or it would read a fleet with the tail missing. `sync` on a
        // serial queue is the whole barrier — every `async` above is ahead of
        // it in the same line.
        if error == nil { monitor?.phase(.indexing) }
        parsing.sync {}

        let pending = continuation
        continuation = nil
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume(returning: Answer(status: status, response: budget ?? response))
        }
    }

    /// The response the platform's own rate-limit headers arrived on.
    ///
    /// Both large interfaces answer `302` to a presigned CloudFront URL, and
    /// only the first response carries `X-Ratelimit-*`; the CDN has no idea
    /// what a subscription is. Held separately so the redirect's headers
    /// survive the hop.
    private var budget: HTTPURLResponse?

    private func note(_ response: HTTPURLResponse) {
        if response.value(forHTTPHeaderField: "X-Ratelimit-Limit") != nil { budget = response }
    }
}
