import Foundation
import Observation
import SwiftUI

struct WatchFleetView: View {
    @Bindable var model: WatchTransitModel

    private var vehicles: [WatchTransitVehicle] {
        model.snapshot.vehicles.sorted { lhs, rhs in
            let lineOrder = lhs.line.localizedStandardCompare(rhs.line)
            if lineOrder != .orderedSame { return lineOrder == .orderedAscending }
            return (lhs.destination ?? lhs.origin)
                .localizedStandardCompare(rhs.destination ?? rhs.origin)
                == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if vehicles.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "circle.grid.2x2")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No vehicles cached")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Button {
                        model.refresh()
                    } label: {
                        WatchGlassActionLabel(
                            title: "Refresh",
                            systemName: "arrow.clockwise",
                            tint: .cyan
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRefreshing)
                }
                .padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(vehicles) { vehicle in
                            NavigationLink(value: WatchRoute.vehicle(vehicle.id)) {
                                WatchGlassCard(interactive: true) {
                                    WatchVehicleRow(vehicle: vehicle)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
            }
        }
        .watchGlassScreen()
        .navigationTitle("Vehicles")
    }
}

private struct WatchVehicleRow: View {
    let vehicle: WatchTransitVehicle

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(WatchModeStyle.color(for: vehicle.mode).opacity(0.2))
                    .frame(width: 28, height: 28)
                Image(systemName: WatchModeStyle.symbol(for: vehicle.mode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WatchModeStyle.color(for: vehicle.mode))
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(vehicle.displayLine)
                        .font(.headline)
                        .lineLimit(1)
                    if let delay = vehicle.delayMinutes, delay > 0 {
                        Text("+\(delay)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
                Text(vehicle.displayDestination)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

struct WatchVehicleDetailView: View {
    let vehicle: WatchTransitVehicle
    let snapshotDate: Date

    private var nextStop: WatchTransitStop? {
        vehicle.nextStop(at: snapshotDate)
    }

    private var canShowRoute: Bool {
        vehicle.stops.lazy.compactMap(\.coordinate).filter(\.isValid).prefix(2).count == 2
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                WatchGlassCard {
                    header
                }

                if let nextStop {
                    WatchGlassCard {
                        nextStopSummary(nextStop)
                    }
                }

                if canShowRoute {
                    NavigationLink(value: WatchRoute.vehicleRoute(vehicle.id)) {
                        WatchGlassActionLabel(
                            title: "Show route",
                            systemName: "map.fill",
                            tint: WatchModeStyle.color(for: vehicle.mode)
                        )
                    }
                    .buttonStyle(.plain)
                }

                WatchGlassCard {
                    journeySummary
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
                                    value: WatchRoute.station(
                                        vehicleID: vehicle.id,
                                        stopID: stop.id
                                    )
                                ) {
                                    WatchStopTimelineRow(
                                        stop: stop,
                                        index: index,
                                        count: vehicle.stops.count,
                                        snapshotDate: snapshotDate,
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
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(WatchModeStyle.color(for: vehicle.mode).opacity(0.22))
                    .frame(width: 36, height: 36)
                Image(systemName: WatchModeStyle.symbol(for: vehicle.mode))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(WatchModeStyle.color(for: vehicle.mode))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(vehicle.displayLine)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(vehicle.displayDestination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let delay = vehicle.delayMinutes {
                Text(delayDescription(delay))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(delay > 0 ? .orange : .green)
            }
        }
    }

    private func nextStopSummary(_ stop: WatchTransitStop) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Next stop", systemImage: "arrow.down.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchModeStyle.color(for: vehicle.mode))

            Text(stop.name)
                .font(.headline)
                .lineLimit(2)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let time = stop.eventTime {
                    Text(time.formatted(date: .omitted, time: .shortened))
                        .font(.body.weight(.semibold).monospacedDigit())
                    Text(relativeDescription(time))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private var journeySummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Journey", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            WatchJourneyFact(caption: "From", value: vehicle.origin)
            Divider().opacity(0.4)
            WatchJourneyFact(caption: "To", value: vehicle.displayDestination)
        }
    }

    private func delayDescription(_ minutes: Int) -> String {
        if minutes == 0 { return "On time" }
        if minutes > 0 { return "+\(minutes) min" }
        return "\(-minutes) min early"
    }

    private func relativeDescription(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSince(snapshotDate) / 60).rounded())
        if minutes == 0 { return "now" }
        if minutes < 0 { return "\(-minutes)m ago" }
        if minutes < 60 { return "in \(minutes)m" }
        return "in \(minutes / 60)h \(minutes % 60)m"
    }
}

private struct WatchJourneyFact: View {
    let caption: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
    }
}

private struct WatchStopTimelineRow: View {
    let stop: WatchTransitStop
    let index: Int
    let count: Int
    let snapshotDate: Date
    let isNext: Bool
    let tint: Color

    private var time: Date? {
        index == 0 ? (stop.departure ?? stop.arrival) : stop.eventTime
    }

    private var isPast: Bool {
        guard let time else { return false }
        return time < snapshotDate && !isNext
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
