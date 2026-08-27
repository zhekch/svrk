import SwiftUI
import TransitCore

/// Everything the legend says about the feed, as a value.
///
/// Taken off the model rather than read from it, so the panel can be previewed
/// mid-download in Xcode — which is the state that most needs looking at and
/// the one hardest to catch by hand, since it lasts only as long as the
/// refresh does.
struct FeedActivity: Equatable {
    var progress = RefreshProgress()
    var status = FleetStatus.empty
    /// Nil on the manual cadence, where a refresh taking longer than the
    /// interval is not a thing that can happen.
    var interval: TimeInterval?
    /// What failed to load out of the bundle at launch. Collected since the
    /// first build and, until now, never shown anywhere.
    var problems: [String] = []
    /// What the platform says is left of the budget, where it has said.
    var limits: OTDClient.Limits?

    init(
        progress: RefreshProgress = RefreshProgress(),
        status: FleetStatus = .empty,
        interval: TimeInterval? = nil,
        problems: [String] = [],
        limits: OTDClient.Limits? = nil
    ) {
        self.progress = progress
        self.status = status
        self.interval = interval
        self.problems = problems
        self.limits = limits
    }

    /// A refresh that takes longer than the gap between refreshes means the app
    /// is downloading continuously — and that the cadence chosen in Settings is
    /// not the cadence being kept.
    var overrunsCadence: Bool {
        guard let interval, status.refreshSeconds > 0 else { return false }
        return status.refreshSeconds > interval
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func rate(_ perSecond: Double) -> String {
        "\(bytes(Int(perSecond)))/s"
    }

    static func seconds(_ interval: TimeInterval) -> String {
        let whole = Int(interval.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// What the feed is doing, and the key for the coloured vehicle markers.
///
/// The two live together because they are what one tap on the status pill has
/// to answer. The pill is the only thing on the map that reports on the
/// network, and a pill that read "no fleet" with a legend of dot colours behind
/// it left the actual question — why is there no fleet — with nowhere to be
/// asked.
struct VehicleLegend: View {
    var activity = FeedActivity()
    private let modes = Mode.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Live data")
                .font(.headline)

            FeedActivityReadout(activity: activity)

            Divider()

            Text("Vehicle dots")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                ForEach(modes, id: \.rawValue) { mode in
                    Label {
                        Text(mode.label)
                    } icon: {
                        Circle().fill(mode.color).frame(width: 11, height: 11)
                    }
                    .font(.callout)
                }
            }

            Divider()

            Label("Live data available", systemImage: "circle.fill")
                .foregroundStyle(.green)
            Label("Refreshing live data", systemImage: "circle.fill")
                .foregroundStyle(.yellow)
            Label("Drawing a stored fleet — the last refresh failed", systemImage: "circle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Label("No live data available", systemImage: "circle.fill")
                .foregroundStyle(.red)
        }
        .font(.caption)
        .padding(18)
        .frame(width: 320, alignment: .leading)
    }
}

/// What the app is doing about live data, right now.
///
/// The national feed is a hundred megabytes and takes as long as it takes. The
/// only thing this has to do is never leave that looking like nothing
/// happening: a phase, a figure that moves, and — when a refresh is slower than
/// the cadence it is being asked to keep — a sentence saying so.
private struct FeedActivityReadout: View {
    let activity: FeedActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline

            if activity.progress.isRunning { running }

            VStack(alignment: .leading, spacing: 4) {
                row("Fleet", fleet)
                row("Source", source)
                if activity.status.refreshSeconds > 0 {
                    row("Last refresh took", FeedActivity.seconds(activity.status.refreshSeconds))
                }
                if activity.status.bytes > 0 {
                    row("Last download", FeedActivity.bytes(activity.status.bytes))
                }
                if activity.status.failures > 0 {
                    row("Failed refreshes", "\(activity.status.failures)")
                }
                if let budget { row("Budget", budget) }
            }

            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: some View {
        HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(activity.progress.phase.label)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            if let elapsed = activity.progress.elapsed, activity.progress.isRunning {
                Text(FeedActivity.seconds(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The figures that only exist while something is in flight.
    ///
    /// Two of them, deliberately. The download is the compressed response —
    /// twelve megabytes, and what the data allowance is charged — and the read
    /// is the hundred megabytes of XML that comes out of it. Reporting only the
    /// second made a 12 MB fetch claim it had pulled 100 MB; reporting only the
    /// first would hide where a slow refresh actually spends its time, because
    /// the gap between the two *is* the answer.
    @ViewBuilder private var running: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = downloadFraction {
                ProgressView(value: fraction).tint(tint)
            } else {
                ProgressView().progressViewStyle(.linear).tint(tint)
            }

            switch activity.progress.phase {
            case .receiving:
                row("Downloaded", downloaded)
                row("Read", read)
            case .indexing:
                row("Read", read)
            case let .waiting(seconds):
                Text("""
                The live feed allows two calls a minute. The next slot opens in \
                \(Int(seconds.rounded())) seconds.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
    }

    /// Determinate where the response said how long it would be, which it does
    /// — `Content-Length` on the compressed body.
    private var downloadFraction: Double? {
        guard case .receiving = activity.progress.phase,
              let expected = activity.progress.expected, expected > 0
        else { return nil }
        return min(1, Double(activity.progress.received) / Double(expected))
    }

    private var downloaded: String {
        var text = FeedActivity.bytes(activity.progress.received)
        if let expected = activity.progress.expected, expected > 0 {
            text += " of \(FeedActivity.bytes(expected))"
        }
        text += " gzip"
        guard let rate = activity.progress.bytesPerSecond, rate > 0 else { return text }
        return "\(text) · \(FeedActivity.rate(rate))"
    }

    private var read: String {
        let bytes = FeedActivity.bytes(activity.progress.parsed)
        return "\(bytes) XML · \(activity.progress.journeys) journeys"
    }

    private var fleet: String {
        activity.status.journeys == 0
            ? "nothing loaded"
            : "\(activity.status.journeys) journeys · \(activity.status.vehicles) running"
    }

    /// Where what is drawn came from, and how old it is.
    ///
    /// A replayed snapshot used to report the moment it was replayed, so a
    /// fleet from breakfast said it had refreshed a second ago.
    private var source: String {
        guard let at = activity.status.refreshedAt else { return activity.status.source }
        let age = Date().timeIntervalSince(at)
        let name = activity.status.source == "cache" ? "stored snapshot" : "live feed"
        return age < 90 ? "\(name), just now" : "\(name), \(FeedActivity.seconds(age)) old"
    }

    private var tint: Color {
        switch activity.progress.phase {
        case .failed: return .red
        case .idle: return activity.status.journeys > 0 ? .green : .red
        default: return .yellow
        }
    }

    /// What the platform says is left, in its own words.
    private var budget: String? {
        guard let limits = activity.limits else { return nil }
        var parts: [String] = []
        if let remaining = limits.remaining, let limit = limits.limit {
            parts.append("\(remaining) of \(limit) calls left today")
        }
        if limits.perMinute > 0 {
            parts.append("\(limits.inLastMinute)/\(limits.perMinute) this minute")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var warnings: [String] {
        var found: [String] = []
        if case let .failed(reason) = activity.progress.phase {
            found.append(reason)
            // A 429 says only that something was refused. Which limit, and how
            // long it lasts, are two different answers — a minute, or until
            // midnight — and the difference decides whether waiting is worth it.
            if reason.contains("429") || reason.contains("quota") {
                found.append(refusalAdvice)
            }
        } else if let error = activity.status.lastError {
            found.append(error)
        }
        if activity.overrunsCadence, let interval = activity.interval {
            found.append("""
            A refresh takes longer than the \(Int(interval / 60))-minute cadence, \
            so the app is downloading almost continuously.
            """)
        }
        found.append(contentsOf: activity.problems.map { "Did not load — \($0)" })
        return found
    }

    private var refusalAdvice: String {
        if let remaining = activity.limits?.remaining, remaining <= 0 {
            guard let at = activity.limits?.resetsAt else {
                return "The daily quota is spent. It refills at midnight."
            }
            return "The daily quota is spent. It refills at \(FeedActivity.clock(at))."
        }
        return "Two calls a minute on this interface. The next one will go through in under a minute."
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview("Legend — downloading") {
    var progress = RefreshProgress()
    progress.phase = .receiving
    progress.startedAt = Date().addingTimeInterval(-42)
    progress.received = 61 << 20
    progress.parsed = 47 << 20
    progress.journeys = 7204
    progress.bytesPerSecond = 8.1 * 1_048_576

    var status = FleetStatus.empty
    status.journeys = 11_520
    status.vehicles = 9753
    status.source = "cache"
    status.refreshedAt = Date().addingTimeInterval(-3600)
    status.refreshSeconds = 352
    status.bytes = 104 << 20

    return VehicleLegend(activity: FeedActivity(progress: progress, status: status, interval: 300))
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Legend — nothing loaded") {
    var progress = RefreshProgress()
    progress.phase = .failed("no GTFS-RT token")

    return VehicleLegend(activity: FeedActivity(
        progress: progress,
        interval: 300,
        problems: ["stops: The file “stops.bin” couldn’t be opened."]
    ))
    .padding()
    .preferredColorScheme(.dark)
}

