import Foundation
import SwiftUI

struct WatchVehicleDetailView: View {
    let vehicle: WatchTransitVehicle
    let routeValue: WatchRoute

    private var canShowRoute: Bool {
        vehicle.stops.lazy.compactMap(\.coordinate).filter(\.isValid).prefix(2).count == 2
    }

    var body: some View {
        // TimelineView lets watchOS coalesce this inexpensive minute update.
        // It keeps "next" tied to the clock without re-enabling vehicle or
        // location polling.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(at: timeline.date)
        }
    }

    private func content(at now: Date) -> some View {
        let nextStop = vehicle.nextStop(at: now)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                WatchGlassCard {
                    header
                }

                if let nextStop {
                    WatchGlassCard {
                        nextStopSummary(nextStop, now: now)
                    }
                }

                if canShowRoute {
                    NavigationLink(value: routeValue) {
                        WatchGlassActionLabel(
                            title: "Show route",
                            systemName: "map.fill",
                            tint: WatchModeStyle.color(for: vehicle.mode)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !vehicle.stops.isEmpty {
                    Text("Stops")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)

                    WatchGlassCard(padding: 8) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(vehicle.stops.enumerated()), id: \.element.id) { index, stop in
                                NavigationLink(
                                    value: WatchRoute.station(stop)
                                ) {
                                    WatchStopTimelineRow(
                                        stop: stop,
                                        index: index,
                                        count: vehicle.stops.count,
                                        now: now,
                                        isNext: stop.id == nextStop?.id,
                                        tint: WatchModeStyle.color(for: vehicle.mode)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if let operatorName = vehicle.operatorName,
                   !operatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "building.2")
                        Text(operatorName)
                            .lineLimit(2)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .watchGlassScreen()
        .navigationTitle(vehicle.displayLine)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(WatchModeStyle.color(for: vehicle.mode).opacity(0.22))
                        .frame(width: 22, height: 22)
                    Image(systemName: WatchModeStyle.symbol(for: vehicle.mode))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchModeStyle.color(for: vehicle.mode))
                }
                Text(vehicle.displayLine)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let delay = vehicle.delayMinutes {
                    if delay != 0 {
                        Text(delayDescription(delay))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(delay > 0 ? .orange : .green)
                    }
                }
            }

            Text(vehicle.displayDestination)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            if vehicle.origin != vehicle.displayDestination {
                Text("From \(vehicle.origin)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
    }

    private func nextStopSummary(_ stop: WatchTransitStop, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Next stop", systemImage: "arrow.down.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchModeStyle.color(for: vehicle.mode))

            Text(stop.name)
                .font(.headline)
                .lineLimit(2)

            HStack(alignment: .bottom, spacing: 6) {
                if let time = stop.eventTime {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(time.formatted(date: .omitted, time: .shortened))
                            .font(.body.weight(.semibold).monospacedDigit())
                        Text(relativeDescription(time, from: now))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Spacer(minLength: 2)
                if let platform = stop.displayPlatform {
                    Text("Pl. \(platform)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private func delayDescription(_ minutes: Int) -> String {
        if minutes > 0 { return "+\(minutes) min" }
        return "\(-minutes) min early"
    }

    private func relativeDescription(_ date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes == 0 { return "now" }
        if minutes < 0 { return "\(-minutes) min ago" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "in \(hours) hr" : "in \(hours) hr \(remainder) min"
    }
}

private struct WatchStopTimelineRow: View {
    let stop: WatchTransitStop
    let index: Int
    let count: Int
    let now: Date
    let isNext: Bool
    let tint: Color

    private var time: Date? {
        index == 0 ? (stop.departure ?? stop.arrival) : stop.eventTime
    }

    private var isPast: Bool {
        guard let time else { return false }
        return time < now && !isNext
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(spacing: 2) {
                Circle()
                    .fill(isNext ? tint : (isPast ? Color.secondary.opacity(0.45) : .white))
                    .overlay {
                        if isNext { Circle().stroke(.white, lineWidth: 1.5) }
                    }
                    .frame(width: isNext ? 9 : 6, height: isNext ? 9 : 6)
                if index < count - 1 {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 1, height: 27)
                }
            }
            .frame(width: 10)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.caption.weight(isNext ? .bold : .regular))
                    .foregroundStyle(isPast ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if let time {
                        Text(time.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                    }
                    if let platform = stop.displayPlatform {
                        Text("Pl. \(platform)")
                    }
                    if let delay = stop.delayMinutes, delay > 0 {
                        Text("+\(delay)").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension WatchTransitVehicle {
    var displayLine: String {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? mode.capitalized
            : line
    }

    var displayDestination: String {
        if let destination,
           !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return destination
        }
        return origin
    }
}

#if DEBUG
#Preview("Train") {
    WatchVehicleDetailView(
        vehicle: WatchPreviewData.train,
        routeValue: .vehicleRoute(WatchPreviewData.train.id)
    )
}
#endif
