import SwiftUI
import TransitCore

/// One line, whole.
///
/// The end of a chain of questions the app could already start and not finish.
/// A stop's board says an RE1 to Bern calls here; the "lines running through
/// here" list says so even when nothing is running; and until now both stopped
/// there. This is where it goes — every stop in order, and the run itself drawn
/// on the map behind the sheet.
///
/// It comes from the mapped routes rather than from the timetable, and the
/// panel says so at the bottom rather than pretending otherwise. That is also
/// why there are no times on it: a relation describes a line, not a working, so
/// it knows the order of the stops and nothing whatever about the hour.
struct LinePanel: View {
    @Bindable var model: AppModel
    let line: RouteLine

    /// The name without the label the badge already carries.
    ///
    /// The same trim `ServingRow` makes, for the same reason: OSM names a
    /// relation `Tram 8: Zoo → Hardturm`, and beside a badge reading **8** the
    /// first two words are said twice.
    private var headline: String { RouteNaming.trim(line.headline, ref: line.ref) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    LineBadge(line: line.ref.isEmpty ? line.mode.label : line.ref,
                              mode: line.mode)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline).font(.callout)
                        if let operatorName = line.operatorName {
                            Text(operatorName).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 2)
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
                    }
                }
            }

            Section {
                Text("""
                From the mapped routes rather than from the timetable, so it \
                answers at any hour — and shows one direction of the line as it \
                is mapped, with no times.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(line.ref.isEmpty ? line.mode.label : line.ref)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ stop: RouteStop) -> some View {
        HStack(spacing: 10) {
            marker(stop)
            Text(stop.name)
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

/// Naming a relation for a reader, in one place because two panels do it.
enum RouteNaming {
    /// `Tram 8: Zoo → Hardturm` beside a badge reading **8** is `Zoo → Hardturm`.
    ///
    /// Only where the part before the colon really is the label — within a
    /// couple of words of it — so a name that happens to contain a colon for
    /// some other reason is left exactly as it was mapped.
    static func trim(_ headline: String, ref: String) -> String {
        let withoutRef: String
        guard !ref.isEmpty, let colon = headline.firstIndex(of: ":") else {
            return arrows(in: headline)
        }
        let prefix = headline[..<colon]
        guard prefix.hasSuffix(ref), prefix.count <= ref.count + 14 else {
            return arrows(in: headline)
        }
        withoutRef = headline[headline.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        return arrows(in: withoutRef)
    }

    /// OSM route names commonly carry the ASCII `=>`. Use the actual arrow the
    /// rest of the app uses, without changing either endpoint's spelling.
    private static func arrows(in headline: String) -> String {
        headline
            .replacingOccurrences(of: " => ", with: " → ")
            .replacingOccurrences(of: "=>", with: " → ")
    }
}
