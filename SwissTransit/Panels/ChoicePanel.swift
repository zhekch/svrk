import SwiftUI
import UIKit
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
    /// What opening it selects. Place identity is resolved before the list is
    /// built; its departures load only if the user opens that place.
    let selection: Selection
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    /// The infrastructure mode where this choice is a stop or station.
    /// Vehicles have no value; keeping it explicit avoids inferring railway
    /// status from an icon or from whichever departures happen to be listed.
    let rail: Bool?
    /// Metres from the tap to whatever was drawn. What the list is sorted by.
    let distance: Double
    var badge: String? = nil
    var destination: String? = nil
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
        let name = [snapshot.isTurningAround ? nil : snapshot.category, snapshot.displayLine]
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
            subtitle: snapshot.displayDestination.map { "to \($0)" },
            symbol: snapshot.mode.symbol,
            tint: snapshot.mode.color,
            rail: nil,
            distance: distance,
            badge: snapshot.displayLine.isEmpty ? nil : snapshot.displayLine,
            destination: snapshot.displayDestination
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
            rail: rail,
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
            rail: board.rail,
            distance: distance
        )
    }
}

extension TapChoice {
    var menuTitle: String {
        switch selection {
        case let .platform(board):
            if board.stationOnly { return board.name }
            let noun = board.rail ? "Platform" : "Stop"
            if let code = board.code, !code.isEmpty { return "\(noun) \(code)" }
            if let assigned = board.assigned { return "\(noun) \(assigned)" }
            return noun
        case .vehicle:
            return destination ?? title
        default:
            return title
        }
    }

    /// Native menus accept an image per action. Keep the line's colour and
    /// number in that image, leaving the single text line for its destination.
    @MainActor var menuImage: UIImage? {
        guard let badge else { return UIImage(systemName: symbol) }
        let font = UIFont.systemFont(ofSize: 15, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let text = badge as NSString
        let measured = text.size(withAttributes: attributes)
        let size = CGSize(width: max(26, measured.width + 10), height: 26)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(tint).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
            text.draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2),
                      withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// Native popover fallback for iOS 17.0–17.3, before controls could open their
/// primary menu programmatically. Current systems use UIButton's UIMenu.
final class MapChoicePopover: UITableViewController, UIPopoverPresentationControllerDelegate {
    private let options: [TapChoice]
    private let choose: (TapChoice) -> Void

    init(options: [TapChoice], choose: @escaping (TapChoice) -> Void) {
        self.options = options
        self.choose = choose
        super.init(style: .plain)
        modalPresentationStyle = .popover
        popoverPresentationController?.delegate = self
        tableView.rowHeight = 48
        tableView.tableFooterView = UIView()
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { options.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let option = options[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = option.menuTitle
        cell.textLabel?.numberOfLines = 1
        cell.imageView?.image = option.menuImage
        cell.imageView?.tintColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { choose(options[indexPath.row]) }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
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
        .scrollContentBackground(.hidden)
        .menuAnimation(value: options.map(\.id))
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
