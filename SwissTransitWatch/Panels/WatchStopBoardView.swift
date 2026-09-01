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
                            Text("All departures")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
        guard !cleaned.isEmpty else { return nil }

        // The station board needs the track to walk to, not the sector of the
        // platform where the train will stand: 12A-C -> 12, 4F-H -> 4. Keep
        // letter-only bus/tram bays because the letter is their whole identity.
        let digits = cleaned.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return cleaned }
        var suffix = cleaned.dropFirst(digits.count)
        if suffix.first == " " { suffix = suffix.dropFirst() }
        guard let first = suffix.first, first.isUppercase,
              suffix.allSatisfy({ $0.isUppercase || $0 == "-" || $0 == "\u{2013}" })
        else { return cleaned }
        return String(digits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(departure.departure.formatted(date: .omitted, time: .shortened))
                    .font(.headline.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 49, alignment: .leading)

                WatchDepartureLineBadge(line: displayLine, mode: departure.mode)
                Spacer(minLength: 2)
                if let platform = displayPlatform {
                    Text(platform)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }

            if let delay = departure.delayMinutes, delay > 0 {
                HStack(alignment: .top, spacing: 7) {
                    Text("+\(delay)")
                        .foregroundStyle(.orange)
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .frame(width: 49, height: 11, alignment: .leading)

                    Text(departure.destination)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
            } else {
                // With no delay there is no second time column to align. Give
                // the destination the full card width, like the iOS board.
                Text(departure.destination)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WatchDepartureLineBadge: View {
    let line: String
    let mode: String

    var body: some View {
        Text(line)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                WatchModeStyle.color(for: mode),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .foregroundStyle(.white)
    }
}
