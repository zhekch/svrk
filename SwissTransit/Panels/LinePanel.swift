import SwiftUI
import TransitCore

/// A route on the main map, with the ordered stops as navigation links.
struct LinePanel: View {
    @Bindable var model: AppModel
    let line: RouteLine

    /// The name without the label the badge already carries.
    ///
    /// The same trim `ServingRow` makes, for the same reason: OSM names a
    /// relation `Tram 8: Zoo → Hardturm`, and beside a badge reading **8** the
    /// first two words are said twice.
    private var headline: String {
        StopNaming.displayRoute(RouteNaming.trim(line.headline, ref: line.ref))
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    LineBadge(line: line.ref.isEmpty ? line.mode.label : line.ref,
                              mode: line.mode)
                    VStack(alignment: .leading, spacing: 2) {
                        if let to = line.to, !to.isEmpty {
                            Text(to).font(.headline)
                        } else if !headline.isEmpty {
                            Text(headline).font(.headline)
                        }
                        if let from = line.from {
                            Text("from \(from)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("Route endpoints")
            }

            if line.stops.isEmpty {
                Section {
                    // Two different failures, and the reader can tell them
                    // apart by looking at the map: a line drawn with no list
                    // means the route is mapped and its calls could not be
                    // named, and no line at all means the relation carries no
                    // usable path.
                    Text("The mapped route lists no stops this app can name.")
                        .font(.callout)
                }
            } else {
                Section("\(line.stops.count) Stops") {
                    ForEach(line.stops) { stop in
                        Button {
                            Task { await model.selectStation(stop: stop) }
                        } label: {
                            row(stop)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(StopNaming.display(stop.name))
                        .accessibilityIdentifier("Route stop")
                    }
                }
            }

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .menuAnimation(value: line.stops.map(\.id))
        .accessibilityIdentifier("Route stops")
        .navigationTitle(line.ref.isEmpty ? line.mode.label : line.ref)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ stop: RouteStop) -> some View {
        HStack(spacing: 10) {
            marker(stop)
            Text(StopNaming.display(stop.name))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// The ends filled, everything between them open.
    ///
    /// The vehicle panel's column means *how far along* and is read against a
    /// clock. Nothing is running here, so there is no progress to show and a
    /// column of identical beads would be decoration. What it can honestly say
    /// is which two of these are the ends of the line.
    private func marker(_ stop: RouteStop) -> some View {
        let terminus = stop.id == 0 || stop.id == line.stops.count - 1
        return ZStack {
            Circle()
                .strokeBorder(line.mode.color, lineWidth: 1.5)
                .frame(width: 11, height: 11)
            if terminus {
                Circle().fill(line.mode.color).frame(width: 5, height: 5)
            }
        }
    }
}
