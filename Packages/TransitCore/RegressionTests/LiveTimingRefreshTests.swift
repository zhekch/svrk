import XCTest
@testable import TransitCore

private final class TimingResponseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [Data] = []
    private static var requests = 0

    static func reset(_ responses: [String]) {
        lock.lock()
        replies = responses.map { Data($0.utf8) }
        requests = 0
        lock.unlock()
    }

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "live-timing.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let response = Self.replies.isEmpty ? Data() : Self.replies.removeFirst()
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LiveTimingRefreshTests: XCTestCase {
    func testOpenCardCanRefreshDelayInsideBackgroundCacheLifetime() async throws {
        let call: (String) -> String = { estimate in
            """
            <ThisCall><siri:StopPointRef>ch:1:sloid:123</siri:StopPointRef>
            <ServiceDeparture><TimetabledTime>2026-09-06T17:46:00Z</TimetabledTime>
            <EstimatedTime>2026-09-06T17:\(estimate):00Z</EstimatedTime></ServiceDeparture></ThisCall>
            """
        }
        TimingResponseProtocol.reset([call("46"), call("51"), call("48")])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OTDClient(token: "test", baseURL: URL(string: "https://live-timing.test")!, session: session)
        let service = LoadService(client: client)
        let key = LoadService.Key(journeyID: "run", day: "2026-09-06")
        _ = await service.load(for: key)
        let initial = await service.timing(for: key)
        XCTAssertEqual(initial?.byStop.values.first?.departureDelay, 0)
        _ = await service.load(for: key, background: true)
        XCTAssertEqual(TimingResponseProtocol.count, 1, "The map should retain its cheaper cache cadence")
        _ = await service.load(for: key, maxAge: 0)
        let late = await service.timing(for: key)
        XCTAssertEqual(late?.byStop.values.first?.departureDelay, 300)
        XCTAssertEqual(TimingResponseProtocol.count, 2, "Load and timing must share one fresh response")
        _ = await service.load(for: key, maxAge: 0)
        let revised = await service.timing(for: key)
        XCTAssertEqual(revised?.byStop.values.first?.departureDelay, 120)
        XCTAssertEqual(TimingResponseProtocol.count, 3)
    }
}
