import Foundation

/// A background URL session is essential for a watch-sized runtime: the system
/// process continues the explicit 124 MB download after the display sleeps or
/// the app is suspended, without keeping SwissTransit running.
struct WatchTimetableDownloadProgress: Equatable, Sendable {
    var receivedBytes: Int64
    var expectedBytes: Int64

    var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    var remainingBytes: Int64 {
        max(0, expectedBytes - receivedBytes)
    }

    var hasBytes: Bool { receivedBytes > 0 && expectedBytes > 0 }
}

final class WatchTimetableDownloadCoordinator: NSObject, @unchecked Sendable {
    static let shared = WatchTimetableDownloadCoordinator()
    static let sessionIdentifier = "com.kexts.swisstransit.watch.full-timetable"

    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var backgroundEventWaiters: [CheckedContinuation<Void, Never>] = []
    private var sessionStorage: URLSession?
    private var receivedByTask: [Int: Int64] = [:]
    private var expectedByTask: [Int: Int64] = [:]

    private override init() {
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let sessionStorage { return sessionStorage }

        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        let created = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        sessionStorage = created
        return created
    }

    func startAndWait() async throws {
        let session = session
        let existing = await session.allTasks
        if existing.isEmpty {
            resetProgress()
            try WatchNationalArchiveFiles.prepareStaging()
            for asset in WatchNationalArchiveFiles.assets {
                var request = URLRequest(url: asset.remoteURL, timeoutInterval: 20 * 60)
                request.setValue("SwissTransit-watchOS/1.0", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                task.taskDescription = asset.name
                task.countOfBytesClientExpectsToReceive = asset.expectedBytes
                rememberExpected(task.taskIdentifier, asset.expectedBytes)
                task.resume()
            }
        } else {
            adoptProgress(from: existing)
        }

        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func isActive() async -> Bool {
        !(await session.allTasks).isEmpty
    }

    func progressSnapshot() async -> WatchTimetableDownloadProgress {
        let tasks = await session.allTasks
        if !tasks.isEmpty { adoptProgress(from: tasks) }
        lock.lock()
        let received = receivedByTask.values.reduce(0, +)
        let reported = expectedByTask.values.reduce(0, +)
        lock.unlock()
        let baseline = WatchNationalArchiveFiles.assets.reduce(Int64(0)) {
            $0 + $1.expectedBytes
        }
        return WatchTimetableDownloadProgress(
            receivedBytes: received,
            expectedBytes: max(reported, baseline)
        )
    }

    private func resetProgress() {
        lock.lock()
        receivedByTask.removeAll()
        expectedByTask.removeAll()
        lock.unlock()
    }

    private func rememberExpected(_ taskID: Int, _ bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        expectedByTask[taskID] = max(expectedByTask[taskID] ?? 0, bytes)
        lock.unlock()
    }

    private func adoptProgress(from tasks: [URLSessionTask]) {
        lock.lock()
        for task in tasks {
            if task.countOfBytesReceived > 0 {
                receivedByTask[task.taskIdentifier] = task.countOfBytesReceived
            }
            let expected = max(
                task.countOfBytesExpectedToReceive,
                task.countOfBytesClientExpectsToReceive
            )
            if expected > 0 {
                expectedByTask[task.taskIdentifier] = max(
                    expectedByTask[task.taskIdentifier] ?? 0,
                    expected
                )
            } else if let name = task.taskDescription,
                      let asset = WatchNationalArchiveFiles.asset(named: name) {
                expectedByTask[task.taskIdentifier] = max(
                    expectedByTask[task.taskIdentifier] ?? 0,
                    asset.expectedBytes
                )
            }
        }
        lock.unlock()
    }

    /// Called by SwiftUI's matching `.urlSession` background task. Merely
    /// touching `session` reconnects this process to transfers created before a
    /// suspension or termination; returning waits until delegate delivery ends.
    func waitForBackgroundEvents() async {
        _ = session
        await withCheckedContinuation { continuation in
            lock.lock()
            backgroundEventWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func finishWaiters(with result: Result<Void, Error>) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(with: result) }
    }

    private func finishBackgroundEventWaiters() {
        lock.lock()
        let pending = backgroundEventWaiters
        backgroundEventWaiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

extension WatchTimetableDownloadCoordinator: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        receivedByTask[downloadTask.taskIdentifier] = totalBytesWritten
        let expected = max(
            totalBytesExpectedToWrite,
            downloadTask.countOfBytesClientExpectsToReceive
        )
        if expected > 0 {
            expectedByTask[downloadTask.taskIdentifier] = max(
                expectedByTask[downloadTask.taskIdentifier] ?? 0,
                expected
            )
        }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let name = downloadTask.taskDescription,
                  let asset = WatchNationalArchiveFiles.asset(named: name),
                  let http = downloadTask.response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode)
            else { throw WatchNationalArchiveFiles.ArchiveError.downloadUnavailable }

            try? FileManager.default.removeItem(at: asset.stagedURL)
            try FileManager.default.moveItem(at: location, to: asset.stagedURL)
            try WatchNationalArchiveFiles.validate(asset.stagedURL, as: asset)
            if let size = try? WatchNationalArchiveFiles.fileSize(asset.stagedURL) {
                lock.lock()
                receivedByTask[downloadTask.taskIdentifier] = size
                expectedByTask[downloadTask.taskIdentifier] = max(
                    expectedByTask[downloadTask.taskIdentifier] ?? 0,
                    size
                )
                lock.unlock()
            }

            if try WatchNationalArchiveFiles.installIfComplete() {
                finishWaiters(with: .success(()))
            }
        } catch {
            finishWaiters(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { finishWaiters(with: .failure(error)) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishBackgroundEventWaiters()
    }
}

enum WatchNationalArchiveFiles {
    struct Asset: Sendable {
        var name: String
        var remoteURL: URL
        var stagedURL: URL
        var installedURL: URL
        var magic: String
        var version: UInt32
        var minimumBytes: Int64
        var expectedBytes: Int64
    }

    static let fileManager = FileManager.default
    static let releaseRoot = URL(
        string: "https://github.com/zhekch/svrk/releases/download/watch-timetable-2026/"
    )!

    static var directory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NationalTimetable", isDirectory: true)
    }

    static var timetableURL: URL { directory.appendingPathComponent("timetable.bin") }
    static var stopsURL: URL { directory.appendingPathComponent("stops.bin") }

    static var assets: [Asset] {
        [
            Asset(
                name: "watch-timetable-v3.bin",
                remoteURL: releaseRoot.appendingPathComponent("watch-timetable-v3.bin"),
                stagedURL: directory.appendingPathComponent("timetable.download"),
                installedURL: timetableURL,
                magic: "SVTIMTB1",
                version: 3,
                minimumBytes: 100 * 1_024 * 1_024,
                expectedBytes: 119 * 1_024 * 1_024
            ),
            Asset(
                name: "watch-stops-v1.bin",
                remoteURL: releaseRoot.appendingPathComponent("watch-stops-v1.bin"),
                stagedURL: directory.appendingPathComponent("stops.download"),
                installedURL: stopsURL,
                magic: "SVSTOPS_",
                version: 1,
                minimumBytes: 1 * 1_024 * 1_024,
                expectedBytes: 5 * 1_024 * 1_024
            ),
        ]
    }

    static func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }

    static func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    static func prepareStaging() throws {
        try ensureDirectory()
        for asset in assets where fileManager.fileExists(atPath: asset.stagedURL.path) {
            try fileManager.removeItem(at: asset.stagedURL)
        }
    }

    static func installIfComplete() throws -> Bool {
        guard assets.allSatisfy({ fileManager.fileExists(atPath: $0.stagedURL.path) })
        else { return false }
        for asset in assets { try validate(asset.stagedURL, as: asset) }
        for asset in assets { try install(asset.stagedURL, as: asset.installedURL) }
        return true
    }

    static func validateInstalledArchive() throws {
        for asset in assets { try validate(asset.installedURL, as: asset) }
    }

    static func validate(_ url: URL, as asset: Asset) throws {
        guard try fileSize(url) >= asset.minimumBytes else { throw ArchiveError.invalidArchive }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              String(decoding: header.prefix(8), as: UTF8.self) == asset.magic
        else { throw ArchiveError.invalidArchive }
        let foundVersion = header.dropFirst(8).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        guard foundVersion == asset.version else { throw ArchiveError.invalidArchive }
    }

    static func install(_ stagedURL: URL, as destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw ArchiveError.invalidArchive
        }
        return number.int64Value
    }

    enum ArchiveError: LocalizedError {
        case notInstalled
        case invalidArchive
        case downloadUnavailable

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "The full timetable is not downloaded."
            case .invalidArchive: return "The downloaded timetable is invalid."
            case .downloadUnavailable: return "The full timetable download is unavailable."
            }
        }
    }
}
