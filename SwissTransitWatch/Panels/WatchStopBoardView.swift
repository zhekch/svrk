import Observation
import SwiftUI

struct WatchStopBoardView: View {
    let stop: WatchTransitStop
    @Bindable var model: WatchTransitModel

    @State private var departures: [WatchStationDeparture] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                WatchGlassCard {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stop.name)
                                .font(.headline)
                                .lineLimit(2)
                            if let platform = stop.displayPlatform {
                                Text("Opened from platform \(platform)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Next departures")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                if isLoading {
                    WatchGlassCard {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading departures…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if departures.isEmpty {
                    WatchGlassCard {
                        VStack(spacing: 7) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text(errorMessage ?? "No upcoming departures")
                                .font(.caption)
                                .foregroundStyle(
                                    errorMessage == nil ? Color.secondary : Color.orange
                                )
                                .multilineTextAlignment(.center)
                            Button {
                                Task { await load() }
                            } label: {
                                WatchGlassActionLabel(
                                    title: "Try again",
                                    systemName: "arrow.clockwise",
                                    tint: .cyan
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(departures) { departure in
                        WatchGlassCard {
                            WatchDepartureRow(departure: departure)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .watchGlassScreen()
        .navigationTitle("Stop")
        .task(id: stop.id) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await model.stationBoard(for: stop)
            try Task.checkCancellation()
            departures = loaded
        } catch is CancellationError {
            return
        } catch {
            departures = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct WatchDepartureRow: View {
    let departure: WatchStationDeparture

    private var displayLine: String {
        let line = departure.line.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? departure.mode.capitalized : line
    }

    private var displayPlatform: String? {
        guard let platform = departure.platform else { return nil }
        let cleaned = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(spacing: 3) {
                Text(departure.departure.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.bold).monospacedDigit())
                if let delay = departure.delayMinutes, delay > 0 {
                    Text("+\(delay)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 40, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    WatchVehicleDot(mode: departure.mode, diameter: 6)
                    Text(displayLine)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
                Text(departure.destination)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 2)
            if let platform = displayPlatform {
                Text(platform)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}
