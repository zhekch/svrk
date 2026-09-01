import Observation
import SwiftUI

struct WatchStopBoardView: View {
    let stop: WatchTransitStop
    @Bindable var model: WatchTransitModel
    private let initialDepartures: [WatchStationDeparture]?

    @State private var entries: [WatchStationDeparture] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(
        stop: WatchTransitStop,
        model: WatchTransitModel,
        initialDepartures: [WatchStationDeparture]? = nil
    ) {
        self.stop = stop
        self.model = model
        self.initialDepartures = initialDepartures
        _entries = State(initialValue: initialDepartures ?? [])
        _isLoading = State(initialValue: initialDepartures == nil)
    }

    var body: some View {
        List {
            WatchGlassCard {
                HStack(spacing: 8) {
                    Image(systemName: "building.columns.fill")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stop.name)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
            .watchBoardListRow()

            if isLoading {
                WatchGlassCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .watchBoardListRow()
            } else if entries.isEmpty {
                WatchGlassCard {
                    VStack(spacing: 7) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(errorMessage ?? "No upcoming services")
                            .font(.caption)
                            .foregroundStyle(
                                errorMessage == nil ? Color.secondary : Color.orange
                            )
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .watchBoardListRow()
            } else {
                if !groupedDepartures.isEmpty {
                    Section {
                        ForEach(groupedDepartures) { group in
                            departureCard(for: group)
                                .watchBoardListRow()
                        }
                    } header: {
                        Label("Departures", systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if !groupedArrivals.isEmpty {
                    Section {
                        ForEach(groupedArrivals) { group in
                            departureCard(for: group)
                                .watchBoardListRow()
                        }
                    } header: {
                        Label("Arrivals", systemImage: "arrow.down.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .watchGlassScreen()
        .navigationTitle("Stop")
        .task(id: stop.id) {
            guard initialDepartures == nil else { return }
            await load()
        }
    }

    private var groupedDepartures: [WatchDepartureGroup] {
        grouped(
            entries.filter { !$0.terminates },
            showing: .departure
        )
    }

    private var groupedArrivals: [WatchDepartureGroup] {
        grouped(
            entries.filter { !$0.originates },
            showing: .arrival
        )
    }

    private func grouped(
        _ entries: [WatchStationDeparture],
        showing: WatchBoardShowing
    ) -> [WatchDepartureGroup] {
        struct Key: Hashable {
            var mode: String
            var line: String
            var place: String
        }

        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US")
                )
        }

        var buckets: [Key: [WatchStationDeparture]] = [:]
        var order: [Key] = []
        for departure in entries.sorted(by: {
            $0.eventTime(showing: showing) < $1.eventTime(showing: showing)
        }) {
            let key = Key(
                mode: normalized(departure.mode),
                line: normalized(departure.line),
                place: normalized(departure.place(showing: showing))
            )
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(departure)
        }
        return order.compactMap { key in
            guard let grouped = buckets[key], !grouped.isEmpty else { return nil }
            return WatchDepartureGroup(
                id: "\(showing.rawValue)|\(key.mode)|\(key.line)|\(key.place)",
                departures: grouped,
                showing: showing
            )
        }
    }

    private func departureCard(for group: WatchDepartureGroup) -> some View {
        Group {
            if let vehicle = group.primary.vehicle {
                NavigationLink(value: WatchRoute.stationVehicle(vehicle)) {
                    WatchGlassCard {
                        WatchDepartureRow(
                            departure: group.primary,
                            showing: group.showing,
                            frequencyText: group.frequencyDescription
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens vehicle details")
            } else {
                WatchGlassCard {
                    WatchDepartureRow(
                        departure: group.primary,
                        showing: group.showing,
                        frequencyText: group.frequencyDescription
                    )
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            NavigationLink(value: WatchRoute.stationTimes(group)) {
                Label("Times", systemImage: "clock.fill")
            }
            .tint(.cyan)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let vehicle = group.mapVehicle {
                NavigationLink(value: WatchRoute.stationVehicleRoute(vehicle)) {
                    Label("Map", systemImage: "map.fill")
                }
                .tint(.blue)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await model.stationBoard(for: stop)
            try Task.checkCancellation()
            entries = loaded
        } catch is CancellationError {
            return
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct WatchDepartureTimesView: View {
    let group: WatchDepartureGroup

    var body: some View {
        List {
            WatchGlassCard {
                VStack(alignment: .leading, spacing: 5) {
                    WatchDepartureLineBadge(
                        line: group.primary.line.isEmpty
                            ? group.primary.mode.capitalized
                            : group.primary.line,
                        mode: group.primary.mode
                    )
                    Text(group.primary.place(showing: group.showing))
                        .font(.headline)
                        .lineLimit(2)
                    Text(group.frequencyDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .watchBoardListRow()

            ForEach(group.departures.sorted(by: {
                $0.eventTime(showing: group.showing)
                    < $1.eventTime(showing: group.showing)
            })) { departure in
                if let vehicle = departure.vehicle {
                    NavigationLink(value: WatchRoute.stationVehicle(vehicle)) {
                        WatchGlassCard {
                            WatchDepartureRow(
                                departure: departure,
                                showing: group.showing
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .watchBoardListRow()
                } else {
                    WatchGlassCard {
                        WatchDepartureRow(
                            departure: departure,
                            showing: group.showing
                        )
                    }
                    .watchBoardListRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .watchGlassScreen()
        .navigationTitle("Times")
    }
}

private struct WatchDepartureRow: View {
    let departure: WatchStationDeparture
    var showing: WatchBoardShowing = .departure
    var frequencyText: String? = nil

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
                Text(
                    departure.eventTime(showing: showing).formatted(
                        date: .omitted,
                        time: .shortened
                    )
                )
                    .font(.headline.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 49, alignment: .leading)

                WatchDepartureLineBadge(line: displayLine, mode: departure.mode)
                Spacer(minLength: 2)
                if let platform = displayPlatform {
                    ViewThatFits(in: .horizontal) {
                        Text(platform)
                            .lineLimit(1)
                            .fixedSize()
                        Text(platform.replacingOccurrences(of: "/", with: "/\n"))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize()
                    }
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

                    destination(frequencyText: frequencyText)
                }
            } else {
                // With no delay there is no second time column to align. Give
                // the destination the full card width, like the iOS board.
                destination(frequencyText: frequencyText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func destination(frequencyText: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(departure.place(showing: showing))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let frequencyText {
                Text(frequencyText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private extension View {
    func watchBoardListRow() -> some View {
        listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
            .listRowBackground(Color.clear)
    }
}

#if DEBUG
@MainActor
private struct WatchStopBoardPreviewHost: View {
    @State private var model = WatchPreviewData.model()

    var body: some View {
        WatchStopBoardView(
            stop: WatchPreviewData.zurichHB,
            model: model,
            initialDepartures: WatchPreviewData.stationDepartures
        )
    }
}

#Preview("Station Overview") {
    WatchStopBoardPreviewHost()
}

#Preview("Departure Times") {
    WatchDepartureTimesView(group: WatchPreviewData.departureGroup)
}
#endif
