import SwiftUI
import TransitCore

// What to do when the finger landed on more than one thing.
//
// A map at platform zoom is layered: a train stands on a track, at a platform,
// inside a station, next to a bus at a kerb, and all five of those are drawn
// within a few points of each other. `AppModel.handleTap` has always had to
// choose one of them, and choosing well is genuinely hard — the ordering there
// is a decade of small corrections about whether a plate beats a stop dot and
// whether a station beats the rails it stands on, each one right about the tap
// that provoked it.
//
// The honest answer is that the tap is ambiguous and the person who made it
// knows which thing they meant. So where several things are genuinely under the
// finger, they are all offered and the ranking becomes a suggestion — the first
// row — rather than a verdict. Where only one thing is there, nothing changes:
// no list, no extra tap.
//
// Picking a row goes through `AppModel.push`, so Back returns to the list. That
// matters more than it sounds: the reason to offer a choice at all is that the
// first guess might be wrong, and being able to say "no, the other one" without
// finding the marker on the map again is the whole value of it.

/// One thing that was under a tap.
struct TapChoice: Identifiable {
    /// What sort of thing it is, which decides how much claim it has on a
    /// touch that also landed on something else.
    enum Kind {
        case vehicle
        /// A point you aim at: a kerb plate, a stop dot, a station.
        case marker
        /// A shape you are merely standing *on* — a drawn platform slab, the
        /// blob over a station. It answers because the touch was inside it,
        /// which is true of most of the screen at platform zoom, so it is never
        /// evidence that a tap was meant for it rather than for the vehicle
        /// standing in it.
        case area
    }

    let id: String
    let kind: Kind
    /// What opening it selects. Boards are resolved before the list is built —
    /// a row that cannot answer is a row that should not have been offered.
    let selection: Selection
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    /// Metres from the tap to whatever was drawn. What the list is sorted by.
    let distance: Double
}

extension TapChoice: Equatable {
    /// On identity alone.
    ///
    /// The payload is a `Selection`, which for a station carries a whole
    /// departure board — and `AppModel.selection` is compared on every write,
    /// several times a second, to decide whether anything changed. Comparing
    /// half a dozen boards element by element to answer a question the id
    /// already answers is work for nothing.
    static func == (a: TapChoice, b: TapChoice) -> Bool { a.id == b.id }
}

extension TapChoice {
    static func vehicle(_ snapshot: VehicleSnapshot, distance: Double) -> TapChoice {
        let name = [snapshot.category, snapshot.line]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        // "S 12" rather than "S S12": the feed files a line both ways round and
        // a category that is already the start of the line is not worth saying
        // twice.
        let title: String
        if name.count == 2, name[1].uppercased().hasPrefix(name[0].uppercased()) {
            title = name[1]
        } else {
            title = name.joined(separator: " ")
        }
        return TapChoice(
            id: "vehicle:\(snapshot.id)",
            kind: .vehicle,
            selection: .vehicle(snapshot.id),
            title: title.isEmpty ? snapshot.mode.label : title,
            subtitle: snapshot.to.map { "to \($0)" },
            symbol: snapshot.mode.symbol,
            tint: snapshot.mode.color,
            distance: distance
        )
    }

    static func station(_ board: StationBoard, rail: Bool, distance: Double) -> TapChoice {
        TapChoice(
            id: "station:\(board.id)",
            kind: .marker,
            selection: .station(board),
            title: board.name,
            subtitle: rail ? "Station" : "Stop",
            symbol: rail ? "building.columns.fill" : "mappin.circle.fill",
            tint: .secondary,
            distance: distance
        )
    }

    static func platform(_ board: PlatformBoard, kind: Kind, distance: Double) -> TapChoice {
        let subtitle: String
        if board.stationOnly {
            subtitle = "Whole station's departures"
        } else if let code = board.code, !code.isEmpty {
            subtitle = "\(board.rail ? "Platform" : "Stop") \(code)"
        } else if let assigned = board.assigned {
            subtitle = "\(board.rail ? "Platform" : "Stop") \(assigned) (auto generated)"
        } else {
            subtitle = board.rail ? "Platform" : "Stop"
        }
        return TapChoice(
            id: "platform:\(board.shape ?? board.id)",
            kind: kind,
            selection: .platform(board),
            title: board.name,
            subtitle: subtitle,
            symbol: "signpost.right.fill",
            tint: .secondary,
            distance: distance
        )
    }
}

/// The list itself: one row per thing, nearest first.
struct ChoicePanel: View {
    @Bindable var model: AppModel
    let options: [TapChoice]

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button { model.choose(option) } label: { row(option) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("\(options.count) things here")
            } footer: {
                Text("Tapped between several things. Pick one — Back returns to this list.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What did you mean?")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ option: TapChoice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: option.symbol)
                .font(.body)
                .foregroundStyle(option.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle = option.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
