import AVFAudio
import Darwin
import Foundation
import os
import TransitCore
import UIKit

/// Debug-only tracing for the draw loop.
///
/// The map draws or it does not, and when it does not the interesting facts —
/// what the viewport actually was, how many journeys were in the fleet, what
/// moment was asked about — are exactly the ones not on screen. Rate-limited to
/// once a second so a 15 Hz loop does not bury the log.
enum Diagnostics {
    private static let log = Logger(subsystem: "com.kexts.swisstransit", category: "draw")
    private static var lastAt = Date.distantPast

    static func sample(
        now: Timestamp, zoom: Double, viewport: BBox,
        drawn: Int, onTrack: Int, fleet: Int
    ) {
        guard Date().timeIntervalSince(lastAt) > 1 else { return }
        lastAt = Date()
        log.info("""
        draw now=\(now) zoom=\(String(format: "%.2f", zoom)) \
        bbox=[\(String(format: "%.3f", viewport.west)),\(String(format: "%.3f", viewport.south)) \
        \(String(format: "%.3f", viewport.east)),\(String(format: "%.3f", viewport.north))] \
        drawn=\(drawn) onTrack=\(onTrack) fleet=\(fleet)
        """)
    }
}

extension Diagnostics {
    private static var lastPush = Date.distantPast

    /// What actually reached the map's sources, as opposed to what the model
    /// computed. The gap between the two is where a silent draw failure lives.
    static func pushed(vehicles: Int, tracks: Int, styleReady: Bool) {
        guard Date().timeIntervalSince(lastPush) > 1 else { return }
        lastPush = Date()
        Logger(subsystem: "com.kexts.swisstransit", category: "draw")
            .info("push vehicles=\(vehicles) tracks=\(tracks) styleReady=\(styleReady)")
    }
}

extension Diagnostics {
    /// Something that did not draw, said out loud.
    ///
    /// A layer the style refused is invisible in every other way — the map
    /// simply looks emptier than it should, with no error anywhere. Not
    /// DEBUG-only for that reason: the overlays this reports on are the ones
    /// that depend on a network, and a report from a real phone is the only
    /// place that will show.
    static func note(_ message: String) {
        Logger(subsystem: "com.kexts.swisstransit", category: "draw")
            .warning("\(message, privacy: .public)")
    }
}


/// What this process is costing the phone.
///
/// Three questions, and iOS answers two of them properly. Memory and CPU come
/// straight off the kernel: `phys_footprint` is the number the system actually
/// holds an app to, and the per-thread CPU sample is the same one Instruments
/// shows. Power is the one it will not answer — there is no API for
/// instantaneous draw — so what is reported instead is the evidence a phone
/// does give: whether it has started throttling itself, whether the user has
/// asked for low power, and where the battery is. Thermal state in particular
/// is the honest measure of "is this app too expensive", because it is the
/// thing that eventually makes the map stutter.
///
/// Sampled once a second rather than every frame. These are syscalls, and
/// `task_threads` allocates — a readout measured thirty times a second would be
/// reporting a cost it was itself creating.
enum DeviceLoad {
    struct Sample: Equatable {
        var cpuPercent = 0.0
        var memoryMB = 0.0
        var thermal = ProcessInfo.ThermalState.nominal
        var lowPower = false
        /// Nil where battery monitoring is off, which it is unless the readout
        /// is on.
        var batteryPercent: Double?
    }

    private static var lastAt = Date.distantPast
    private static var held = Sample()

    static func sample() -> Sample {
        guard Date().timeIntervalSince(lastAt) >= 1 else { return held }
        lastAt = Date()
        let device = UIDevice.current
        held = Sample(
            cpuPercent: cpuPercent(),
            memoryMB: Double(memoryBytes()) / 1_048_576,
            thermal: ProcessInfo.processInfo.thermalState,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryPercent: device.isBatteryMonitoringEnabled && device.batteryLevel >= 0
                ? Double(device.batteryLevel) * 100
                : nil
        )
        return held
    }

    /// Turn battery reporting on only while somebody is looking at it.
    static func watchBattery(_ on: Bool) {
        UIDevice.current.isBatteryMonitoringEnabled = on
    }

    /// The footprint iOS counts against the app's memory limit, in bytes.
    ///
    /// `resident_size` is the number that used to be reported here and it is
    /// the wrong one: it counts pages the app shares with the system and
    /// ignores the compressed ones, so it reads high on launch and low under
    /// exactly the pressure worth knowing about. `phys_footprint` is what the
    /// jetsam limit is applied to.
    static func memoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// `THREAD_BASIC_INFO_COUNT` and `TH_FLAGS_IDLE` are C macros, which Swift
    /// does not import. Both are stable parts of the Mach ABI.
    private static let threadInfoCount = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    private static let threadIdle: Int32 = 0x1

    /// Share of one core, in percent, summed over every live thread.
    ///
    /// Can exceed 100 on a phone with more than one core in use, which is the
    /// point: the draw loop is on the main thread and the fleet actor is not,
    /// and a number capped at 100 would hide one behind the other.
    static func cpuPercent() -> Double {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads
        else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }

        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = Self.threadInfoCount
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            // An idle thread reports whatever it was doing when it stopped.
            guard result == KERN_SUCCESS, info.flags & Self.threadIdle == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }
}

extension ProcessInfo.ThermalState {
    /// The actual thermal state, kept distinct from Energy Impact.
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }
}




/// Which resource actually missed the frame.
///
/// A frame rate is a symptom and never a cause, and on a fixed 60 Hz panel it
/// is not even a rate: 40 fps is two frames served across three refreshes —
/// the loop landing somewhere between 16.7 and 33.3 ms and finishing on the
/// wrong side of the deadline every other time. A steady 30 would mean the
/// budget is gone twice over. A steady 40 means it is gone by about three
/// milliseconds, which is a different problem with a different fix, and the
/// frame rate on its own cannot tell the two apart.
///
/// So this measures the two numbers that can. The refresh period comes from
/// the link (`targetTimestamp - timestamp`), which is the rate the panel is
/// actually being driven at rather than the one the app asked for. And
/// occupancy is the span from the callback to the run loop going back to
/// sleep, closed after Core Animation's own commit so the layer flush is
/// inside the number rather than hidden after it.
///
/// Read them together:
///
/// - occupancy at or near the refresh period → the main thread is the budget.
///   Something is queued in front of the draw, and the CPU figure beside it
///   says whether that something even belongs to this process.
/// - occupancy comfortably under it while the rate still sags → the main
///   thread handed off in time and the cost is downstream, in the renderer's
///   encode or in the compositor. That is a Metal System Trace, not a Time
///   Profiler.
///
/// `missed` is the third: refreshes the link was due on and did not fire on,
/// which is a main-thread stall stated directly rather than inferred from an
/// average.
///
/// Off unless asked for — `-frameProbe YES` in the scheme's arguments. Not
/// `#if DEBUG`, and for the inverse of the usual reason: an unoptimised build
/// changes the very quantity this reports, so the only measurement worth
/// taking is the one from the configuration that ships.
///
/// Main thread only, which is where a display link and a run loop observer on
/// the main run loop both call back.
final class FrameProbe {
    static let shared = FrameProbe()

    private static let log = Logger(subsystem: "com.kexts.swisstransit", category: "frame")

    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?

    /// Main-thread occupancy for each frame in the window, in milliseconds.
    /// Kept whole rather than averaged on the way in, because the nine frames
    /// that fit and the one that did not are the entire story and a mean
    /// erases it.
    private var occupancy: [Double] = []

    /// When the run loop turn carrying this frame began, or zero once it has
    /// been closed. `beforeWaiting` fires on every wake, most of which no
    /// display link caused, and the zero is how those are ignored.
    private var openedAt: CFTimeInterval = 0

    private var lastFire: CFTimeInterval = 0
    private var refresh: CFTimeInterval = 0
    private var served = 0
    private var missed = 0
    private var windowFrom: CFTimeInterval = 0

    private init() {}

    /// Started from `SwissTransitApp.init`, which is before the first frame —
    /// the window this exists to explain is the launch one, and a probe
    /// attached after the map appears has already missed it.
    func startIfRequested() {
        guard link == nil, UserDefaults.standard.bool(forKey: "frameProbe") else { return }

        // Pinned to the panel maximum, deliberately not to the rate the map is
        // holding itself to: a link asked for 30 skips every other refresh by
        // arrangement, and a skipped refresh is the thing being counted. On a
        // variable-refresh panel that pin is itself a nudge — asking for 120
        // can be the reason the panel is at 120 — so the number to trust on
        // ProMotion is the occupancy, not the rate. On a 60 Hz phone there is
        // only one rate to ask for and the question does not arise.
        let ceiling = Float(UIScreen.main.maximumFramesPerSecond)
        let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: ceiling, maximum: ceiling, preferred: ceiling
        )
        link.add(to: .main, forMode: .common)
        self.link = link

        // Ordered after Core Animation's commit observer, which sits at
        // 2,000,000 on the same activity. The layer tree is flushed to the
        // render server from there, and a frame closed ahead of it would leave
        // that flush outside the measurement it most often dominates.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000
        ) { [weak self] _, _ in
            self?.close()
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        windowFrom = CACurrentMediaTime()
        Diagnostics.note("frame probe on, panel \(Int(ceiling)) Hz")
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
    }

    @objc private func fire(_ link: CADisplayLink) {
        let period = link.targetTimestamp - link.timestamp
        if period > 0 { refresh = period }

        if lastFire > 0, refresh > 0 {
            let periods = Int(((link.timestamp - lastFire) / refresh).rounded())
            if periods > 1 { missed += periods - 1 }
        }
        lastFire = link.timestamp
        served += 1

        // The callback's own start, not `link.timestamp`: the timestamp is
        // when the frame was nominally due, which is already in the past by
        // however long the run loop took to reach us, and charging that to the
        // occupancy would double-count the stall `missed` has just recorded.
        openedAt = CACurrentMediaTime()

        report()
    }

    private func close() {
        guard openedAt > 0 else { return }
        occupancy.append((CACurrentMediaTime() - openedAt) * 1000)
        openedAt = 0
    }

    /// Once a second, for the reason `DeviceLoad` gives: the readout costs
    /// syscalls, and a per-frame one would be reporting its own weight.
    ///
    /// `otherAudio` is the closest an app can get to asking whether something
    /// else is on screen. There is no API for "is another app in Picture in
    /// Picture", but a PiP video is playing audio out of a process that is
    /// still very much alive and competing for the same cores, and the audio
    /// session will say so. A proxy, and labelled as one — it is also true of
    /// music with nothing on screen at all.
    private func report() {
        let now = CACurrentMediaTime()
        let elapsed = now - windowFrom
        guard elapsed >= 1 else { return }
        windowFrom = now

        let sorted = occupancy.sorted()
        let load = DeviceLoad.sample()
        let panel = refresh > 0 ? 1 / refresh : 0
        let budget = refresh > 0 ? refresh * 1000 : 0
        let dropped = missed
        let rate = Double(served) / elapsed

        // Built as one string and logged public. `Logger` redacts interpolated
        // strings by default, and every formatted number here would otherwise
        // reach Console as `<private>` — see `Diagnostics.note`.
        let message = String(
            format: """
            panel=%.0fHz budget=%.1fms served=%.1ffps missed=%d \
            busy p50=%.1f p95=%.1f max=%.1fms \
            cpu=%.0f%% mem=%.0fMB thermal=%@ otherAudio=%@
            """,
            panel, budget, rate, dropped,
            Self.percentile(sorted, 0.5), Self.percentile(sorted, 0.95), sorted.last ?? 0,
            load.cpuPercent, load.memoryMB, load.thermal.label,
            AVAudioSession.sharedInstance().isOtherAudioPlaying ? "yes" : "no"
        )
        Self.log.info("\(message, privacy: .public)")

        occupancy.removeAll(keepingCapacity: true)
        served = 0
        missed = 0

        GeoJSONQueueProbe.shared.flush()
    }

    /// Nearest-rank, which for a window of sixty samples is as much resolution
    /// as the question deserves.
    fileprivate static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
}


/// Round-trip latency of a GeoJSON write through Mapbox's serial parse queue.
///
/// Every `updateGeoJSONSource` / `updateGeoJSONSourceFeatures` takes a `dataId`,
/// and `onSourceDataLoaded` reports it back. The difference is the wait —
/// including everything already queued in front — which is the number the
/// follow-judder diagnosis turns on. Off unless `-frameProbe YES`.
final class GeoJSONQueueProbe {
    static let shared = GeoJSONQueueProbe()

    enum Kind: String, CaseIterable {
        /// Followed vehicle's point, patched from `followFrame`.
        case followPoint = "fp"
        /// Followed 3D wagons (and lamps): point features a fill-translate
        /// cannot move, so they go through the GeoJSON queue.
        case followWagons = "fw"
        /// Followed body's full source rewrite (polygons ± wagons).
        case followShape = "fs"
        /// Whole-fleet `transit-vehicles` rewrite on the model tick.
        case fleet = "fv"
        /// Whole-collection `transit-vehicle-shapes` rewrite on the model tick.
        case vehicleShapes = "vs"
    }

    struct Band: Equatable {
        var p50 = 0.0
        var p95 = 0.0
        var max = 0.0
        var sent = 0
        var landed = 0
    }

    struct Snapshot: Equatable {
        var followPoint = Band()
        var followWagons = Band()
        var followShape = Band()
        var fleet = Band()
        var vehicleShapes = Band()
        /// What the follow lane did with wagon points, even when it wrote
        /// nothing. Zero `followWagons.sent` with `solids` > 0 is the 60 Hz
        /// patch path not running.
        var wagonDraws = 0
        var wagonSolids = 0
        var wagonRebuilds = 0
        var wagonPatches = 0
        var wagonPoints = 0
    }

    private static let log = Logger(subsystem: "com.kexts.swisstransit", category: "queue")

    private let lock = NSLock()
    private var sent: [Kind: Int] = [:]
    private var landed: [Kind: Int] = [:]
    private var windowSent: [Kind: Int] = [:]
    private var windowLatencies: [Kind: [Double]] = [:]
    private var recentLatencies: [Kind: [Double]] = [:]
    private var snapshot = Snapshot()
    private var wagonDraws = 0
    private var wagonSolids = 0
    private var wagonRebuilds = 0
    private var wagonPatches = 0
    private var wagonPoints = 0
    private var started = false

    private init() {}

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "frameProbe") }

    /// Encode the enqueue time so the load event can subtract it. Nil when the
    /// probe is off, so the write is identical to an unstamped one.
    func stamp(_ kind: Kind, at time: CFTimeInterval) -> String? {
        guard isEnabled else { return nil }
        lock.lock()
        sent[kind, default: 0] += 1
        windowSent[kind, default: 0] += 1
        let first = !started
        started = true
        lock.unlock()
        if first { resetFiles() }
        return "\(kind.rawValue):\(String(format: "%.6f", time))"
    }

    /// Follow-lane wagon accounting, so a silent `fw` band can still say why.
    func noteFollowWagons(solids: Bool, points: Int, rebuilt: Bool, patched: Int) {
        guard isEnabled else { return }
        lock.lock()
        wagonDraws += 1
        if solids { wagonSolids += 1 }
        if rebuilt { wagonRebuilds += 1 }
        if patched > 0 { wagonPatches += 1 }
        wagonPoints = points
        lock.unlock()
    }

    func ingest(dataId: String?, at now: CFTimeInterval = CACurrentMediaTime()) {
        guard isEnabled, let dataId else { return }
        ingestLanded(dataId: dataId, at: now)
    }

    private func ingestLanded(dataId: String, at now: CFTimeInterval) {
        let parts = dataId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let kind = Kind(rawValue: String(parts[0])),
              let stamped = Double(parts[1])
        else { return }
        let ms = (now - stamped) * 1000
        lock.lock()
        landed[kind, default: 0] += 1
        windowLatencies[kind, default: []].append(ms)
        var recent = recentLatencies[kind, default: []]
        recent.append(ms)
        if recent.count > 300 { recent.removeFirst(recent.count - 300) }
        recentLatencies[kind] = recent
        lock.unlock()
    }

    func currentSnapshot() -> Snapshot {
        lock.lock()
        let value = snapshot
        lock.unlock()
        return value
    }

    /// Once a second, from `FrameProbe`, so the two reports share a clock.
    func flush() {
        guard isEnabled else { return }
        lock.lock()
        let kinds = Kind.allCases
        var lines: [String] = []
        var jsonBands: [[String: Any]] = []
        var next = Snapshot()
        for kind in kinds {
            let window = (windowLatencies[kind] ?? []).sorted()
            let recent = (recentLatencies[kind] ?? []).sorted()
            let band = Band(
                p50: FrameProbe.percentile(recent.isEmpty ? window : recent, 0.5),
                p95: FrameProbe.percentile(recent.isEmpty ? window : recent, 0.95),
                max: recent.last ?? window.last ?? 0,
                sent: sent[kind] ?? 0,
                landed: landed[kind] ?? 0
            )
            switch kind {
            case .followPoint: next.followPoint = band
            case .followWagons: next.followWagons = band
            case .followShape: next.followShape = band
            case .fleet: next.fleet = band
            case .vehicleShapes: next.vehicleShapes = band
            }
            let wSent = windowSent[kind] ?? 0
            let wLand = window.count
            if wSent > 0 || wLand > 0 || band.sent > 0 {
                lines.append(String(
                    format: "%@ win sent=%d landed=%d p50=%.1f p95=%.1f max=%.1f tot %d/%d",
                    kind.rawValue, wSent, wLand,
                    FrameProbe.percentile(window, 0.5),
                    FrameProbe.percentile(window, 0.95),
                    window.last ?? 0,
                    band.landed, band.sent
                ))
                jsonBands.append([
                    "kind": kind.rawValue,
                    "windowSent": wSent,
                    "windowLanded": wLand,
                    "windowP50": FrameProbe.percentile(window, 0.5),
                    "windowP95": FrameProbe.percentile(window, 0.95),
                    "windowMax": window.last ?? 0,
                    "sent": band.sent,
                    "landed": band.landed,
                    "p50": band.p50,
                    "p95": band.p95,
                    "max": band.max,
                ])
            }
        }
        next.wagonDraws = wagonDraws
        next.wagonSolids = wagonSolids
        next.wagonRebuilds = wagonRebuilds
        next.wagonPatches = wagonPatches
        next.wagonPoints = wagonPoints
        let wagonLine = String(
            format: "wagons draws=%d solids=%d rebuilds=%d patches=%d pts=%d",
            wagonDraws, wagonSolids, wagonRebuilds, wagonPatches, wagonPoints
        )
        wagonDraws = 0
        wagonSolids = 0
        wagonRebuilds = 0
        wagonPatches = 0
        snapshot = next
        windowSent.removeAll(keepingCapacity: true)
        windowLatencies.removeAll(keepingCapacity: true)
        lock.unlock()

        lines.append(wagonLine)
        guard !lines.isEmpty else { return }
        let message = "queue " + lines.joined(separator: " | ")
        Self.log.info("\(message, privacy: .public)")
        persist(text: message, bands: jsonBands, wagons: [
            "draws": next.wagonDraws,
            "solids": next.wagonSolids,
            "rebuilds": next.wagonRebuilds,
            "patches": next.wagonPatches,
            "points": next.wagonPoints,
        ])
    }

    private func resetFiles() {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: dir.appendingPathComponent("queue-latency.jsonl"))
        try? "".write(
            to: dir.appendingPathComponent("queue-latency.txt"),
            atomically: true, encoding: .utf8
        )
    }

    private func persist(text: String, bands: [[String: Any]], wagons: [String: Int]) {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("queue-latency.txt"),
            atomically: true, encoding: .utf8
        )
        let payload: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "line": text,
            "bands": bands,
            "wagons": wagons,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        let url = dir.appendingPathComponent("queue-latency.jsonl")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
