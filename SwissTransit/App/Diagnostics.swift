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


