import SwiftUI
import TransitCore

/// Several departures of the same service, as one row.
///
/// Grouped by line **and** destination **and** which stop it leaves from, not by
/// line alone. A short working that turns back early is a different service to
/// catch, and at a station like Zürich the same line leaves from the forecourt
/// and from the underground platforms, which are five minutes' walk apart.
struct DepartureGroup: Identifiable {
    var id: String
    var entries: [BoardEntry]

    var first: BoardEntry { entries[0] }
    /// The times after the next one, which is what the disclosure previews.
    var following: [BoardEntry] { Array(entries.dropFirst()) }

    static func group(_ entries: [BoardEntry]) -> [DepartureGroup] {
        var order: [String] = []
        var byKey: [String: [BoardEntry]] = [:]
        for entry in entries {
            let key = "\(entry.mode.rawValue)|\(entry.line)|\(entry.to ?? "")|\(entry.stop ?? "")"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(entry)
        }
        return order.map { DepartureGroup(id: $0, entries: byKey[$0] ?? []) }
    }
}

/// The widest thing each right-hand column of a board has to hold.
///
/// Measured from the rows actually on screen rather than given a number, so the
/// platform badges and the running dots line up down the section whatever is in
/// them — and so a column the board never fills costs no width at all. A stop
/// with no platforms reserves nothing for one; a board where nothing is late
/// reserves nothing for a delay.
struct BoardColumns {
    /// The widest platform label present, or nil where no row has one.
    var platform: String?
    /// The widest delay label present, or nil where nothing is late.
    var delay: String?
    /// The widest "in 4 min" the section currently reads.
    var relative: String
    /// Whether any row is running, and so whether the dot column exists.
    var showsDot: Bool

    init(_ entries: [BoardEntry], now: Timestamp, showing: BoardRow.Showing) {
        // Widest by rendered length rather than by value: "10" is wider than
        // "9" but "C" is not wider than "7", and counting characters is the
        // closest a layout can get without measuring glyphs.
        // Measured on what is drawn, not on what the feed sent: the column
        // reserves room for "13", not for the "13D-F" it came from.
        platform = entries.compactMap { Format.platform($0.platform) }.max { $0.count < $1.count }
        delay = entries.compactMap { Format.delay($0.delay) }.max { $0.count < $1.count }
        relative = entries
            .map { Format.relative(showing == .departure ? $0.departure : $0.arrival, from: now) }
            .max { $0.count < $1.count } ?? ""
        showsDot = entries.contains(where: \.running)
    }
}

/// A departure board.
///
/// Two questions, shown as two headed sections rather than one mixed list: what
/// leaves here, and what gets here. Each call carries both of its times, so a
/// through service is honestly on both, a terminating one is an arrival, and a
/// service starting here is a departure only.
struct BoardPanel: View {
    @Bindable var model: AppModel
    let title: String
    /// nil where the heading says nothing the title has not said already.
    let subtitle: String?
    let now: Timestamp
    let entries: [BoardEntry]
    /// Lines that serve this stop even when nothing is running, so an empty
    /// board still answers the question the map was asked.
    var serving: [ServingLine] = []

    /// Which groups are open.
    ///
    /// Held here rather than inside each row. A `@State` flag living in a row
    /// belongs to the row's *position* as much as to its identity, so a board
    /// that reorders — and a departure board reorders every time something
    /// leaves — hands an open flag to whichever service moved into the slot.
    /// That was half the flicker; the other half is below.
    @State private var expanded: Set<String> = []

    /// Whether the board has moved up under the heading.
    ///
    /// The heading's ground is only honest while something is passing behind
    /// it. At rest — which is how the sheet sits at its collapsed detent, and
    /// what both bug reports were of — there is nothing behind it to hide, and
    /// the slab of bar material is just a grey rectangle ruled across the top
    /// of a glass sheet.
    @State private var scrolledUnder = false

    /// Which modes are switched on. `nil` until the board is first seen, so the
    /// opening choice can be made from what the board actually holds.
    @State private var shown: Set<Mode>?

    /// The modes on this board, in the order they are drawn on the map — trains
    /// above trams above buses, which is also the order people look for them.
    private var present: [Mode] {
        Array(Set(entries.map(\.mode))).sorted { $0.drawOrder > $1.drawOrder }
    }

    private func count(_ mode: Mode) -> Int {
        entries.count { $0.mode == mode }
    }

    /// What to open with.
    ///
    /// Trains only, where a board has them. A big station's board is mostly
    /// buses — Bern runs 27 of them to 18 trains in the same hour — so opening
    /// it with everything on buries the departure most people came to look up.
    /// The chips are independent toggles rather than one exclusive choice, so
    /// adding the trams back is a single tap and both can be on at once.
    private var openingSelection: Set<Mode> {
        present.contains(.train) ? [.train] : Set(present)
    }

    private var visible: [BoardEntry] {
        // A bar is only drawn where there is something to choose between, and
        // where there is not, nothing may be filtered away.
        guard present.count > 1, let shown else { return entries }
        return entries.filter { shown.contains($0.mode) }
    }

    private var departures: [DepartureGroup] {
        DepartureGroup.group(visible.filter { !$0.terminates })
    }
    private var arrivals: [DepartureGroup] {
        DepartureGroup.group(visible.filter { !$0.originates })
    }

    var body: some View {
        List {
            // First on the board, above even the "no data" line: a closed stop
            // is the reason a board is empty at least as often as the hour is.
            if !model.stopAlerts.isEmpty {
                Section("Disruptions") {
                    ForEach(model.stopAlerts) { situation in
                        DisruptionRow(situation: situation)
                            .listRowBackground(Situation.alertBackground)
                    }
                }
            }

            if entries.isEmpty {
                Section {
                    // An empty board reads as "nothing runs here", which at a
                    // rural stop in the evening is simply false. Say which it is.
                    Text("No data available.")
                        .font(.callout)
                }
            }

            // What serves this stop, when nothing is on it.
            //
            // The relations know which lines call at a stop regardless of the
            // hour, which is why tapping the track beside a stop at three in the
            // morning answers and tapping the stop itself did not. Nothing about
            // that difference was real — the track asked the relations and the
            // board asked the fleet — and this closes it. It appears only where
            // the feed has nothing to say: with departures on screen the live
            // answer is the answer, and a second list derived another way beside
            // it is noise.
            if !serving.isEmpty {
                Section("Lines running through here") {
                    ForEach(serving) { line in
                        ServingRow(model: model, line: line)
                    }
                }
            }

            if departures.isEmpty && arrivals.isEmpty && !entries.isEmpty {
                // Every row filtered away. Said plainly, because a board that
                // has just gone blank at a tap reads as broken rather than as
                // empty on purpose.
                Section {
                    Text("Nothing on the board with those transport types.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if !departures.isEmpty {
                Section("Departures") {
                    rows(departures, showing: .departure)
                }
            }

            if !arrivals.isEmpty {
                Section("Arrivals") {
                    rows(arrivals, showing: .arrival)
                }
            }

            // Last on the board, for the same reason it is last on the vehicle
            // panel: a stop displaced for the autumn is worth knowing and is
            // never what somebody opened a departure board to find out.
            if !model.stopWorks.isEmpty {
                Section("Planned works") {
                    ForEach(model.stopWorks) { situation in
                        DisruptionRow(situation: situation, prominent: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // One animation, driven by the only thing that changes: which groups are
        // open. `withAnimation` inside the row animated the row's *own* height
        // while the list was separately re-laying itself out, and the two
        // fought — the jump and clip that read as a glitch.
        .animation(.snappy(duration: 0.28), value: expanded)
        .animation(.snappy(duration: 0.28), value: shown)
        .safeAreaInset(edge: .top) {
            // Nothing to head the board with — no subtitle, and one mode, which
            // is nothing to choose between — and then no heading at all. Left
            // in unconditionally the inset still drew its ground around empty
            // space: a bar of material captioning nothing.
            if hasHeader {
                header
            }
        }
        .modifier(ScrolledUnder { scrolledUnder = $0 })
        .onAppear { if shown == nil { shown = openingSelection } }
    }

    /// Whether anything is actually shown above the board.
    private var hasHeader: Bool { subtitle != nil || present.count > 1 }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Centred, directly under the navigation title it belongs to.
            // Ranged left it read as the first line of the board rather
            // than as the second line of the heading — "Platform C" sitting
            // alone above the departures, a caption with nothing to caption.
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if present.count > 1 {
                ModeChips(
                    present: present,
                    shown: Binding(
                        get: { shown ?? openingSelection },
                        set: { shown = $0 }
                    ),
                    count: count
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // The inset is *over* the list, not above it — that is what a safe area
        // inset is — so with the board scrolled up the rows would run straight
        // through the chips and the two sets of words be drawn on top of each
        // other. The bar material is the same one the navigation bar above it
        // uses, so while it is there the heading reads as one piece of chrome
        // rather than as a strip stuck to the top of the board.
        //
        // Faded rather than inserted: appearing and disappearing changes the
        // inset's own size, which re-lays out the list, which moves the scroll,
        // which is the loop this used to be pinned open to avoid.
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.6)
                }
                // Up past its own top edge, so nothing shows between it and
                // the navigation bar as the list moves underneath. Further up
                // than any bar is tall, rather than a measured amount: the
                // heading sits below a navigation bar whose height moves with
                // the detent, and 60 points cleared it at some heights and left
                // a strip of map showing above it at others. The sheet clips to
                // its own rounded top, so overshooting costs nothing and is the
                // only value that is right at every height.
                .padding(.top, -400)
                .ignoresSafeArea(edges: .horizontal)
                .opacity(scrolledUnder ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: scrolledUnder)
        }
    }

    /// The head row of each group, and — when it is open — the rest of its
    /// times as **sibling rows** rather than as content nested inside it.
    ///
    /// That is what makes the expansion smooth. Nested, the extra times grow one
    /// list row taller and the list animates a height change it did not ask for.
    /// As siblings they are ordinary insertions, which is the one thing a list
    /// animates well.
    @ViewBuilder
    private func rows(_ groups: [DepartureGroup], showing: BoardRow.Showing) -> some View {
        // Measured once for the section, so every row reserves the same width
        // and the columns line up down the list.
        let columns = BoardColumns(groups.map(\.first), now: now, showing: showing)
        ForEach(groups) { group in
            BoardRow(
                entry: group.first, now: now, showing: showing,
                following: group.following.count,
                columns: columns,
                isExpanded: expanded.contains(group.id),
                toggle: { toggle(group.id) }
            )
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.select(journey: group.first.id) } }

            if expanded.contains(group.id) {
                ForEach(group.following) { entry in
                    FollowingRow(entry: entry, now: now, showing: showing)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await model.select(journey: entry.id) } }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// Reports whether the scroll view has moved up under whatever is pinned over
/// its top edge.
///
/// At rest a scroll view sits at exactly minus its own top inset, so the two
/// summing to more than nothing is the whole test — and it holds however the
/// inset is sized, which matters here because the heading it is measuring
/// against is what sets that inset in the first place.
///
/// `onScrollGeometryChange` is iOS 18, and below it there is no way to ask a
/// `List` where it is without measuring from inside its own content — a probe
/// row, which in an inset-grouped list costs a section's worth of space it does
/// not use. So on iOS 17 the ground stays as it always was: always drawn.
private struct ScrolledUnder: ViewModifier {
    let report: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, under in
                report(under)
            }
        } else {
            content.onAppear { report(true) }
        }
    }
}

/// The mode chips above a board.
///
/// A stop outside a station serves one mode and needs no filter; a place like
/// Bern Bahnhof mixes trains, trams and buses on adjacent platforms, and there
/// the list is only useful once it can be narrowed. So the bar appears only
/// where there is actually something to choose between.
///
/// Independent toggles rather than one exclusive choice: at a station the
/// question is often "trains and trams, not the sixty buses", and that is two
/// taps rather than an impossible one.
struct ModeChips: View {
    let present: [Mode]
    @Binding var shown: Set<Mode>
    let count: (Mode) -> Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(present, id: \.self) { mode in
                    let on = shown.contains(mode)
                    Button {
                        // Never all off: switching off the last one leaves a
                        // board that says nothing and offers no way back except
                        // guessing which chip to press. Turning off the last
                        // turns the rest on, which is the only other reading of
                        // the gesture.
                        if on {
                            if shown.count == 1 { shown = Set(present) } else { shown.remove(mode) }
                        } else {
                            shown.insert(mode)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(mode.color)
                                .frame(width: 7, height: 7)
                                .opacity(on ? 1 : 0.45)
                            Text(mode.label)
                                .font(.caption.weight(.medium))
                            Text("\(count(mode))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(on ? mode.color.opacity(0.18) : Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            Capsule().strokeBorder(on ? mode.color.opacity(0.55) : .clear, lineWidth: 1)
                        )
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.label), \(count(mode))")
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
        }
        // The chips sit in a safe-area inset over a list, where a scroll view
        // with no room to scroll still swallows the gesture. Clipped to its own
        // height so it cannot.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// One of the later departures of a service already listed above.
struct FollowingRow: View {
    let entry: BoardEntry
    let now: Timestamp
    let showing: BoardRow.Showing

    var body: some View {
        HStack {
            Text(Format.time(showing == .departure ? entry.departure : entry.arrival))
                .font(.caption.monospacedDigit())
            if let platform = Format.platform(entry.platform) {
                Text(platform).font(.caption2).foregroundStyle(.secondary)
            }
            if let delay = Format.delay(entry.delay) {
                Text(delay).font(.caption2.monospacedDigit()).foregroundStyle(.orange)
            }
            Spacer()
            Text(Format.relative(showing == .departure ? entry.departure : entry.arrival, from: now))
                .font(.caption2).foregroundStyle(.secondary)
        }
        // Indented to sit under the destination, so the column of extra times
        // reads as belonging to the service above it.
        .padding(.leading, 56)
    }
}

struct BoardRow: View {
    enum Showing { case departure, arrival }

    let entry: BoardEntry
    let now: Timestamp
    let showing: Showing
    /// How many more of this service follow, and whether they are shown.
    var following: Int = 0
    /// What the right-hand columns of this section have to hold, so this row
    /// reserves the same width as every other one.
    var columns: BoardColumns = BoardColumns([], now: 0, showing: .departure)
    var isExpanded: Bool = false
    var toggle: (() -> Void)?

    var body: some View {
        // Top-aligned, so the line badge and the time sit on the same line
        // whatever hangs below them. Centred, a row with a disclosure under the
        // badge would push its own destination and time half a line down and no
        // two rows would agree.
        HStack(alignment: .top, spacing: 10) {
            // The line column is a fixed width so the destinations line up; a
            // board of two-digit bus routes should not shift when an IR65
            // arrives on it.
            //
            // The disclosure lives *inside* that column, under the badge. It
            // used to sit at the end of the row, where a two-character "+9" and
            // a three-character "+12" moved the clock: the one number on the
            // board somebody is actually reading was in a different place on
            // every line of it.
            VStack(alignment: .leading, spacing: 3) {
                LineBadge(line: entry.line, mode: entry.mode)
                if following > 0, let toggle {
                    // The chevron alone. The count beside it — "+9" — was a
                    // number nobody acts on: what is being asked is "is there
                    // another one", and the arrow already says yes. Reading it
                    // cost more than it was worth on every row of the board.
                    Button(action: toggle) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            // Nudged to where the row separator starts, so the
                            // one glyph hanging under the badge lines up with
                            // something rather than floating. Three points left
                            // it short of the line by about the width of the
                            // glyph's own side bearing, which reads as a stray
                            // arrow rather than as a column.
                            .padding(.leading, 5)
                            // Rotated rather than swapped for a second glyph:
                            // one image turning is continuous, and two images
                            // exchanged is a blink.
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 14, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide later times" : "Show \(following) later times")
                }
            }
            .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(showing == .departure ? (entry.to ?? "—") : entry.from)
                    .font(.callout)
                    .lineLimit(1)
                if let stop = entry.stop {
                    // "Bern, Bollwerk" is a five-minute walk from platform 7.
                    Text(stop).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // The right-hand columns each hold the width of the widest thing
            // in the *section*, not the widest thing in this row. Sized from
            // the data rather than from a constant, so the badges and the dots
            // line up down the board however long the platform labels are and
            // whatever the clock is currently reading — and so a board with no
            // platforms and nothing late gives the destination the space back.
            //
            // Reserved by an invisible copy of the widest string rather than by
            // a point value: it costs no measurement pass and it follows the
            // type size, which a hard-coded width does not.
            if columns.showsDot {
                Circle()
                    .fill(entry.running ? Color.green : .clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
            }
            if let widest = columns.platform {
                ZStack {
                    Text(widest).hidden()
                    Text(Format.platform(entry.platform) ?? "")
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    Color.secondary.opacity(entry.platform == nil ? 0 : 0.18),
                    in: RoundedRectangle(cornerRadius: 4)
                )
            }
            if let widest = columns.delay {
                ZStack(alignment: .trailing) {
                    Text(widest).hidden()
                    Text(Format.delay(entry.delay) ?? "")
                        .foregroundStyle((entry.delay ?? 0) > 0 ? .orange : .green)
                }
                .font(.caption.monospacedDigit())
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.time(showing == .departure ? entry.departure : entry.arrival))
                    .font(.callout.monospacedDigit())
                ZStack(alignment: .trailing) {
                    Text(columns.relative).hidden()
                    Text(Format.relative(showing == .departure ? entry.departure : entry.arrival, from: now))
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
    }
}

/// A line that calls at this stop, from the mapped routes rather than the feed.
///
/// Tappable, and that is most of what it is for. The row already names a line
/// and where it runs between; the question it provokes — *so where does it
/// actually go* — is answered by the same relation the row was built from, so
/// leaving it unanswered was a link the app was declining to follow. See
/// `AppModel.openRoute(relation:)`.
struct ServingRow: View {
    @Bindable var model: AppModel
    let line: ServingLine

    /// The name without the label the badge already carries.
    private var headline: String { RouteNaming.trim(line.headline, ref: line.ref) }

    var body: some View {
        Button {
            Task { await model.openRoute(relation: line.id) }
        } label: {
            HStack(spacing: 10) {
                Text(line.ref)
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 34)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(line.mode.color, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.callout).lineLimit(1).foregroundStyle(.primary)
                    if let operatorName = line.operatorName {
                        Text(operatorName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The lines that use a piece of track, running or not.
///
/// The relations know which ways they use regardless of what is on them, so a
/// tap on a line drawn plainly on the map always has an answer — even at half
/// past eleven at night when nothing is on it.
struct TrackPanel: View {
    @Bindable var model: AppModel
    let lines: [RelationStore.LineOnWay]

    var body: some View {
        List {
            Section {
                Text("Lines on this track.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Tappable for the same reason the serving rows are: the row says
            // a line uses this track and names where it runs between, and the
            // relation it was read out of can say the rest.
            ForEach(lines, id: \.id) { line in
                Button {
                    Task { await model.openRoute(relation: line.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(line.ref ?? "—")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                            Text(line.mode.replacingOccurrences(of: "_", with: " "))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(line.stops) stops")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Text(line.name ?? "\(line.from ?? "?") → \(line.to ?? "?")")
                            .font(.callout).lineLimit(2).foregroundStyle(.primary)
                        if let operatorName = line.operatorName {
                            Text(operatorName).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("This track")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Station board") {
    let now = Int(Date().timeIntervalSince1970)
    NavigationStack {
        BoardPanel(
            model: AppModel(), title: "Bern", subtitle: nil, now: now,
            entries: [
                BoardEntry(id: "ir15", mode: .train, line: "IR15", to: "Luzern", from: "Genève",
                           departure: now + 2 * 60, arrival: now - 3 * 60, platform: "10", running: true),
                BoardEntry(id: "s3", mode: .tram, line: "3", to: "Weissenbühl", from: "Ostermundigen",
                           departure: now + 6 * 60, arrival: now - 2 * 60, platform: "N", running: true),
                BoardEntry(id: "b10", mode: .bus, line: "10", to: "Köniz Schliern", from: "Bern Wankdorf",
                           departure: now + 12 * 60, arrival: now - 4 * 60, platform: "G", running: true)
            ]
        )
    }
    .preferredColorScheme(.dark)
}
