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

    static func group(
        _ entries: [BoardEntry],
        by time: (BoardEntry) -> Timestamp = { $0.departure }
    ) -> [DepartureGroup] {
        var groups: [DepartureGroup] = []
        for entry in entries.sorted(by: { time($0) < time($1) }) {
            if let index = groups.firstIndex(where: { $0.first.sameService(as: entry) }) {
                groups[index].entries.append(entry)
            } else {
                groups.append(DepartureGroup(id: "", entries: [entry]))
            }
        }
        return groups.map { group in
            var entries = group.entries
            entries.sort { time($0) < time($1) }
            return DepartureGroup(id: id(for: entries), entries: entries)
        }
    }

    /// A normal board keeps every occurrence in chronological order. Cadence
    /// belongs to the service, so retain it even when a feed only annotated one
    /// of its departures.
    static func ungroup(
        _ groups: [DepartureGroup], by time: (BoardEntry) -> Timestamp
    ) -> [DepartureGroup] {
        groups.flatMap { group in
            let cadence = group.entries.compactMap(\.typicalIntervalMinutes).first
            return group.entries.map { entry in
                var entry = entry
                if entry.typicalIntervalMinutes == nil { entry.typicalIntervalMinutes = cadence }
                return DepartureGroup(id: entry.eventID, entries: [entry])
            }
        }.sorted { time($0.first) < time($1.first) }
    }

    /// Stable across live refreshes. `groups.count` and the first journey's id
    /// made every later row a new identity when one service appeared or left,
    /// which is why the station board shuffled without a pattern.
    static func id(for entries: [BoardEntry]) -> String {
        let entry = entries[0]
        let line = Journey.publishedLine(entry.line, mode: entry.mode)
        var dest = ""
        for name in entries.compactMap(\.to) {
            let key = destKey(name)
            if dest.isEmpty || key.count < dest.count || (key.count == dest.count && key < dest) {
                dest = key
            }
        }
        return "\(entry.mode.rawValue)|\(line)|\(dest)|\(entry.stop ?? "")"
    }

    /// Shortest folded form, so `Weissenbühl` and `Bern, Weissenbühl` share an
    /// id the same way `sameService` groups them.
    private static func destKey(_ name: String) -> String {
        func fold(_ value: String) -> String {
            value.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US")
            ).filter { $0.isLetter || $0.isNumber }
        }
        let full = fold(name)
        let local = fold(StopNaming.localDestination(name))
        if !local.isEmpty, local.count < full.count { return local }
        return full
    }
}

/// The widest thing the right-hand side of a board has to hold.
///
/// Measured from the rows actually on screen rather than given a number, so
/// every row ends where every other row ends whatever is in them — and so a
/// slot the board never fills costs no width at all. A stop with no platforms
/// reserves nothing for one; a board where nothing is late reserves nothing
/// for a delay. Within the space this reserves the row packs what it has
/// against the clock, so the slots it does not use fall off its left rather
/// than opening a gap in its middle. See `BoardRow.lateColumns`.
struct BoardColumns {
    /// The widest platform label present, or nil where no row has one.
    var platform: String?
    /// The widest delay label present, or nil where nothing is late.
    var delay: String?
    /// The widest "in 4 min" the section currently reads.
    var relative: String
    /// Whether any row is running, and so whether a dot is reserved for at all.
    var showsDot: Bool

    init(_ entries: [BoardEntry], now: Timestamp, showing: BoardRow.Showing) {
        // Widest by rendered length rather than by value: "10" is wider than
        // "9" but "C" is not wider than "7", and counting characters is the
        // closest a layout can get without measuring glyphs.
        // Measured on what is drawn, not on what the feed sent: the column
        // reserves room for "13", not for the "13D-F" it came from.
        platform = entries.compactMap { Format.platform($0.platform) }.max { $0.count < $1.count }
        delay = entries.compactMap { Format.delay($0.delay, mode: $0.mode) }.max { $0.count < $1.count }
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
    /// Lines that serve this stop with nothing on the board of their own, so
    /// the panel answers what runs through here and not only what is running.
    var serving: [ServingLine] = []
    var isLoading = false
    /// Landscape hides the navigation bar, so Done lives in the heading.
    var dismiss: (() -> Void)? = nil

    /// Decide from the first nonempty board, then preserve the user’s choices.
    @State private var shown: Set<Mode>?
    @State private var groupingOverride: Bool?

    var body: some View {
        BoardContent(
            model: model, title: title, subtitle: subtitle, now: now,
            entries: entries, isLoading: isLoading, dismiss: dismiss,
            data: BoardPresentation(entries: entries, serving: serving, now: now,
                                    shown: shown, groupingOverride: groupingOverride),
            shown: $shown, groupingOverride: $groupingOverride
        )
    }
}

/// Prepare the timetable before SwiftUI asks its lazy list for rows. None of
/// these scans, service comparisons or column measurements belong in a row
/// builder: List can call those repeatedly while scrolling and counting rows.
private struct BoardPresentation {
    let upcoming: [BoardEntry]
    let present: [Mode]
    let counts: [Mode: Int]
    let openingSelection: Set<Mode>
    let nothingSelected: Bool
    let groupDepartures: Bool
    let servingShown: [ServingLine]
    let departures: [BoardDay]
    let arrivals: [BoardDay]

    init(entries: [BoardEntry], serving: [ServingLine], now: Timestamp,
         shown: Set<Mode>?, groupingOverride: Bool?) {
        let upcoming = entries.filter { $0.isUpcoming(at: now) }
        self.upcoming = upcoming
        counts = upcoming.reduce(into: [:]) { $0[$1.mode, default: 0] += 1 }
        let present = Array(counts.keys).sorted { $0.drawOrder > $1.drawOrder }
        self.present = present
        // Railway stations open with trains; other modes remain one tap away.
        let opening: Set<Mode> = present.contains(.train) ? [.train] : Set(present)
        openingSelection = opening
        let selection = shown ?? opening
        nothingSelected = present.count > 1 && selection.isEmpty
        let visible = present.count > 1
            ? upcoming.filter { selection.contains($0.mode) } : upcoming
        // A mode without a live chip must keep its serving lines visible.
        servingShown = present.count > 1
            ? serving.filter { selection.contains($0.mode) || !present.contains($0.mode) } : serving

        // Automatic grouping considers the whole board, before mode/day filters.
        let grouped: Bool
        if let groupingOverride {
            grouped = groupingOverride
        } else {
            var services: [BoardEntry] = []
            for entry in upcoming where !entry.terminates {
                guard !services.contains(where: { $0.sameService(as: entry) }) else { continue }
                services.append(entry)
                if services.count > 2 { break }
            }
            grouped = !services.isEmpty && services.count <= 2
        }
        groupDepartures = grouped
        departures = BoardDay.prepare(visible.filter { !$0.terminates },
                                      now: now, showing: .departure, grouped: grouped)
        arrivals = BoardDay.prepare(visible.filter { !$0.originates && $0.arrival >= Clock.displayMinute(now) },
                                    now: now, showing: .arrival, grouped: grouped)
    }
}

private struct BoardDay: Identifiable {
    let id: Date
    let title: String
    let isFuture: Bool
    let groups: [DepartureGroup]
    let columns: BoardColumns

    static func prepare(_ entries: [BoardEntry], now: Timestamp,
                        showing: BoardRow.Showing, grouped: Bool) -> [BoardDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now)))
        let time: (BoardEntry) -> Timestamp = showing == .departure ? { $0.departure } : { $0.arrival }
        let days = Dictionary(grouping: entries) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: Double(time($0))))
        }
        return days.keys.sorted().map { day in
            let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
            let services = DepartureGroup.group(days[day] ?? [], by: time)
            let rows = grouped ? services : DepartureGroup.ungroup(services, by: time)
            return BoardDay(
                id: day,
                title: offset == 0 ? "Today" : offset == 1 ? "Tomorrow" : Format.day(day),
                isFuture: offset > 0,
                groups: rows,
                columns: BoardColumns(rows.map(\.first), now: now, showing: showing)
            )
        }
    }
}

/// A flat list gives List one cell per identifier, including disclosed times.
/// A conditional nested ForEach makes it build every service to count its rows.
private struct BoardDisplayRow: Identifiable {
    let id: String
    let entry: BoardEntry
    let group: DepartureGroup?
    let expansionID: String
}

private struct BoardContent: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var model: AppModel
    let title: String
    let subtitle: String?
    let now: Timestamp
    let entries: [BoardEntry]
    let isLoading: Bool
    let dismiss: (() -> Void)?
    let data: BoardPresentation
    @Binding var shown: Set<Mode>?
    @Binding var groupingOverride: Bool?
    // Disclosure and scroll state stay below the timetable preparation boundary.
    @State private var expanded: Set<String> = []
    @State private var dayExpansion: [String: Bool] = [:]
    @State private var scrolledUnder = false

    private var upcoming: [BoardEntry] { data.upcoming }
    private var present: [Mode] { data.present }
    private var openingSelection: Set<Mode> { data.openingSelection }
    private var nothingSelected: Bool { data.nothingSelected }
    private var groupDepartures: Bool { data.groupDepartures }
    private var servingShown: [ServingLine] { data.servingShown }
    private var departures: [BoardDay] { data.departures }
    private var arrivals: [BoardDay] { data.arrivals }
    private func count(_ mode: Mode) -> Int { data.counts[mode, default: 0] }

    /// Empty of everything a board would draw, still waiting on the first
    /// answer. A one-row inset list draws as a lone capsule; the spinner
    /// belongs in the sheet, not in a section.
    private var waitingForBoard: Bool {
        entries.isEmpty && isLoading
            && model.stopAlerts.isEmpty && servingShown.isEmpty && model.stopWorks.isEmpty
    }

    /// Side by side on iPhone landscape, where the sheet is short and wide.
    private var usesColumns: Bool { verticalSizeClass == .compact }

    var body: some View {
        // The list survives loading and empty results. Replacing it with a
        // spinner discards its scroll position and rebuilds every visible cell.
        boardList
        .overlay {
            if waitingForBoard {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading departures")
                    .menuAppearance()
            }
        }
        .menuAnimation(value: waitingForBoard)
        // Hidden following times and revised delays are not row insertions.
        // Animating their updates at the list root made every cell participate.
        .menuAnimation(value: departures.flatMap { $0.groups.map(\.id) })
        .menuAnimation(value: arrivals.flatMap { $0.groups.map(\.id) })
        .menuAnimation(value: servingShown.map(\.id))
        .menuAnimation(value: model.stopAlerts.map(\.id))
        .menuAnimation(value: model.stopWorks.map(\.id))
        .navigationTitle(usesColumns ? "" : title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if shown == nil, !entries.isEmpty { shown = openingSelection } }
        .onChange(of: entries.isEmpty) { _, empty in
            if !empty, shown == nil { shown = openingSelection }
        }
    }

    private var boardList: some View {
        Group {
            if usesColumns {
                wideBoard
            } else {
                stackedBoard
            }
        }
    }

    private var stackedBoard: some View {
        List {
            disruptionSection
            filterEmptySection
            if !departures.isEmpty {
                daySections(departures, showing: .departure)
            }
            if !arrivals.isEmpty {
                daySections(arrivals, showing: .arrival)
            }
            servingSection
            worksSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .boardListAnimation(expanded: expanded, dayExpansion: dayExpansion, shown: shown)
        // Observe only the list; the inset adds the mode chips' own scroll view.
        .modifier(ScrolledUnder { scrolledUnder = $0 })
        .safeAreaInset(edge: .top) {
            if usesColumns {
                landscapeHeader
            } else if hasHeader {
                header
            }
        }
    }

    /// Departures and arrivals as two lists, sharing the heading. Landscape
    /// (and iPad) have the width; stacked they bury arrivals under a long
    /// departure list.
    private var wideBoard: some View {
        VStack(spacing: 0) {
            landscapeHeader
            HStack(spacing: 0) {
                boardColumn(gutter: .trailing) {
                    disruptionSection
                    if departures.isEmpty && !waitingForBoard {
                        emptyColumn(.departure)
                    } else {
                        daySections(departures, showing: .departure)
                    }
                }
                Divider()
                boardColumn(gutter: .leading) {
                    if arrivals.isEmpty && !waitingForBoard {
                        emptyColumn(.arrival)
                    } else {
                        daySections(arrivals, showing: .arrival)
                    }
                    servingSection
                    worksSection
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.menuSurface)
        .boardListAnimation(expanded: expanded, dayExpansion: dayExpansion, shown: shown)
    }

    /// How far a column's rows stand off the divider between them. A plain
    /// list insets its rows by a few points, which is the outer margin of a
    /// full-width board and nothing at all against a rule down the middle —
    /// the times ended up touching it. Added as safe area rather than as a
    /// frame inset so the rows and their separators move together and the
    /// scroll indicator stays on the column's own edge.
    private static let columnGutter: CGFloat = 20

    private func boardColumn<Content: View>(gutter: Edge.Set,
                                            @ViewBuilder content: () -> Content) -> some View {
        List {
            content()
                .listRowBackground(Color.menuSurface)
        }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.menuSurface)
            .safeAreaPadding(gutter, Self.columnGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func emptyColumn(_ showing: BoardRow.Showing) -> some View {
        Section {
            Text(nothingSelected ? "Nothing selected." : showing == .departure ? "No departures." : "No arrivals.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            sectionHeading(showing)
        }
    }

    @ViewBuilder
    private var disruptionSection: some View {
        // First on the board, above even the "no data" line: a closed stop
        // is the reason a board is empty at least as often as the hour is.
        if !model.stopAlerts.isEmpty {
            Section("Disruptions") {
                ForEach(model.stopAlerts) { situation in
                    DisruptionRow(situation: situation)
                        .listRowBackground(Situation.alertBackground)
                }
            }
            .id("disruptions")
        }
    }

    @ViewBuilder
    private var filterEmptySection: some View {
        if departures.isEmpty && arrivals.isEmpty && !entries.isEmpty {
            // Every row filtered away. Said plainly, because a board that
            // has just gone blank at a tap reads as broken rather than as
            // empty on purpose.
            Section {
                Text(emptyBoardMessage)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .id("filtered-empty")
        }
    }

    /// Why the board is blank.
    private var emptyBoardMessage: String {
        if nothingSelected { return "Nothing selected." }
        if upcoming.isEmpty { return "No upcoming departures or arrivals." }
        return "Nothing on the board with those transport types."
    }

    @ViewBuilder
    private var servingSection: some View {
        // What else serves this stop.
        //
        // The relations know which lines call at a stop regardless of the
        // hour, which is why tapping the track beside a stop at three in the
        // morning answers and tapping the stop itself did not. Nothing about
        // that difference was real — the track asked the relations and the
        // board asked the fleet — and this closes it. Kept under the board
        // rather than over it, and holding only the lines with nothing on
        // that board, so it reads as what it is: the rest of the answer,
        // after the live one.
        if !servingShown.isEmpty {
            Section("Lines through here") {
                ForEach(servingShown) { line in
                    ServingRow(model: model, line: line)
                }
            }
            .id("serving")
        }
    }

    @ViewBuilder
    private var worksSection: some View {
        // Last on the board, for the same reason it is last on the vehicle
        // panel: a stop displaced for the autumn is worth knowing and is
        // never what somebody opened a departure board to find out.
        if !model.stopWorks.isEmpty {
            Section("Planned works") {
                ForEach(model.stopWorks) { situation in
                    DisruptionRow(situation: situation, prominent: false)
                }
            }
            .id("works")
        }
    }

    /// Whether anything is actually shown above the board.
    private var hasHeader: Bool { subtitle != nil || present.count > 1 }

    /// Landscape: station name, mode chips, Done — one row. The navigation
    /// bar is hidden, so this is the only chrome the board has.
    private var landscapeHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.canGoBack {
                Button { model.goBack() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                        Text("Back")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("Station name")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            if present.count > 1 {
                boardControls
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 8)
            }
            if let dismiss {
                landscapeDone(dismiss)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.menuSurface)
    }

    @ViewBuilder
    private func landscapeDone(_ dismiss: @escaping () -> Void) -> some View {
        if #available(iOS 26.0, *) {
            Button("Done", action: dismiss)
                .fontWeight(.medium)
                .buttonStyle(.glass)
        } else {
            Button("Done", action: dismiss)
                .fontWeight(.medium)
        }
    }

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
            if present.count > 1 { boardControls }
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
                .menuAnimation(value: scrolledUnder)
        }
    }

    private var boardControls: some View {
        ZStack(alignment: .trailing) {
            ModeChips(
                present: present,
                shown: Binding(
                    get: { shown ?? openingSelection },
                    set: { shown = $0 }
                ),
                count: count,
                trailingInset: 54
            )
            .accessibilityIdentifier("Vehicle filters")
            groupingButton
        }
        .frame(height: 44)
    }

    private func sectionHeading(_ showing: BoardRow.Showing) -> some View {
        HStack {
            Text(showing == .departure ? "Departures" : "Arrivals")
            Spacer()
            // With no mode chips, keep the control on the first board heading.
            if present.count <= 1, !entries.isEmpty,
               showing == .departure || (!usesColumns && departures.isEmpty) {
                groupingButton
            }
        }
    }

    private var groupingButton: some View {
        Button {
            groupingOverride = !groupDepartures
        } label: {
            // Match the caption line height and padding of the mode chips.
            Text(" ")
                .font(.caption.weight(.medium))
                .frame(width: 26)
                .overlay {
                    Image(systemName: groupDepartures ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 13, height: 13)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(groupDepartures ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)))
                .foregroundStyle(groupDepartures ? Color.accentColor : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Board grouping")
        .accessibilityLabel("Group departures")
        .accessibilityValue(groupDepartures ? "On" : "Off")
        .accessibilityHint(groupDepartures ? "Show every departure separately" : "Combine later departures of the same service")
        .accessibilityAddTraits(groupDepartures ? [.isSelected] : [])
    }

    /// Split occurrences by their displayed event date before regrouping
    /// services, so tomorrow's times cannot leak into today's disclosure.
    @ViewBuilder
    private func daySections(_ days: [BoardDay], showing: BoardRow.Showing) -> some View {
        ForEach(days) { day in
            let kind = showing == .departure ? "departures" : "arrivals"
            let key = "\(self.title)|\(kind)|\(day.id.timeIntervalSince1970)"
            let isExpanded = !day.isFuture || (dayExpansion[key] ?? (day.id == days.first?.id))
            let title = day.title
            Section {
                Group {
                    if day.isFuture {
                        Button {
                            dayExpansion[key] = !isExpanded
                        } label: {
                            HStack {
                                Text(title)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title) \(kind)")
                        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    } else {
                        Text(title)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
                .listRowSeparator(.hidden)

                if isExpanded {
                    rows(day.groups, columns: day.columns, showing: showing, dayID: key)
                }
            } header: {
                if day.id == days.first?.id {
                    sectionHeading(showing)
                }
            }
            .id(key)
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
    private func rows(_ displayed: [DepartureGroup], columns: BoardColumns,
                      showing: BoardRow.Showing, dayID: String) -> some View {
        let displayedRows = displayed.flatMap { group -> [BoardDisplayRow] in
            let expansionID = "\(dayID)|\(group.id)"
            var rows = [BoardDisplayRow(id: "head|\(group.id)", entry: group.first,
                                        group: group, expansionID: expansionID)]
            if groupDepartures && expanded.contains(expansionID) {
                rows += group.following.map {
                    BoardDisplayRow(id: "following|\($0.eventID)", entry: $0,
                                    group: nil, expansionID: expansionID)
                }
            }
            return rows
        }
        ForEach(displayedRows) { row in
            Button {
                model.select(journey: row.entry)
            } label: {
                if let group = row.group {
                    BoardRow(
                        entry: row.entry, now: now, showing: showing,
                        following: groupDepartures ? group.entries.count - 1 : 0,
                        frequencyMinutes: showing == .departure
                            ? group.entries.compactMap(\.typicalIntervalMinutes).first : nil,
                        columns: columns,
                        isExpanded: expanded.contains(row.expansionID),
                        toggle: groupDepartures ? { toggle(row.expansionID) } : nil
                    )
                } else {
                    FollowingRow(entry: row.entry, now: now, showing: showing)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Station service")
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                watchAction(row.entry, showing: showing)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                routeMapAction(row.entry)
            }
            .accessibilityAction(named: watchLabel(showing)) {
                pin(row.entry, showing: showing)
            }
            .contextMenu {
                Button {
                    pin(row.entry, showing: showing)
                } label: {
                    Label(watchLabel(showing), systemImage: "clock.badge")
                }
            }
        }
    }

    private func routeMapAction(_ entry: BoardEntry) -> some View {
        Button {
            Task { await model.openRoute(entry: entry) }
        } label: {
            Image(systemName: "map")
        }
        .tint(.blue)
        .accessibilityLabel("Route map")
    }

    private func watchAction(_ entry: BoardEntry, showing: BoardRow.Showing) -> some View {
        Button {
            pin(entry, showing: showing)
        } label: {
            Image(systemName: "clock.badge")
        }
        .tint(.orange)
        .accessibilityLabel(watchLabel(showing))
        .accessibilityIdentifier("Watch service")
    }

    private func watchLabel(_ showing: BoardRow.Showing) -> String {
        showing == .departure ? "Watch departure" : "Watch arrival"
    }

    private func pin(_ entry: BoardEntry, showing: BoardRow.Showing) {
        Task {
            await model.liveActivities.watch(
                entry: entry, station: title, showing: showing, now: now
            )
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

private extension View {
    func boardListAnimation(
        expanded: Set<String>,
        dayExpansion: [String: Bool],
        shown: Set<Mode>?
    ) -> some View {
        // Keep disclosure motion on the list so sibling rows move together.
        self
            .menuAnimation(value: expanded)
            .menuAnimation(value: dayExpansion)
            .menuAnimation(value: shown)
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
    var trailingInset: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(present, id: \.self) { mode in
                    let on = shown.contains(mode)
                    Button {
                        // All off is allowed. Switching off the last chip used
                        // to switch the rest back on, which answers a gesture
                        // nobody made; the board now empties and says so, and
                        // the chips are still there to switch one back on.
                        if on { shown.remove(mode) } else { shown.insert(mode) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode.symbol)
                                .font(.caption2.weight(.semibold))
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(mode.color)
                                .frame(width: 13, height: 13)
                                .opacity(on ? 1 : 0.45)
                                .accessibilityHidden(true)
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
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.label), \(count(mode))")
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.trailing, trailingInset)
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
                .foregroundStyle(Format.delay(entry.delay, mode: entry.mode) == nil ? Color.primary : Format.delayColor)
            if let platform = Format.platform(entry.platform) {
                Text(platform).font(.caption2).foregroundStyle(.secondary)
            }
            if let delay = Format.delay(entry.delay, mode: entry.mode) {
                Text(delay).font(.caption2.monospacedDigit()).foregroundStyle(Format.delayColor)
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
    var frequencyMinutes: Int? = nil
    /// What the right-hand columns of this section have to hold, so this row
    /// reserves the same width as every other one.
    var columns: BoardColumns = BoardColumns([], now: 0, showing: .departure)
    var isExpanded: Bool = false
    var toggle: (() -> Void)?

    /// The same caption line in both modes, even when no cadence is known.
    /// The disclosure must not add padding or another line to the row.
    private var frequencyLine: some View {
        HStack(spacing: 5) {
            Text(frequencyMinutes.map { TimetableCadence.intervalDescription($0) } ?? " ")
                .font(.caption2)
            if following > 0, toggle != nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }

    /// The running dot, the platform badge and the delay, side by side.
    ///
    /// Drawn once hidden to reserve the widest set the section holds, and once
    /// for real. Both go through the same builder so the reservation cannot
    /// drift from what lands on top of it. Top-aligned, because these used to
    /// be three children of the row's own top-aligned stack and should still
    /// hang from the same line as the destination and the clock.
    private func lateColumns(
        dot: Bool, platform: String?, delay: String?, filled: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if dot {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
            }
            if let platform {
                Text(platform)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(
                        Color.secondary.opacity(filled ? 0.18 : 0),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            if let delay {
                Text(delay)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Format.delayColor)
            }
        }
    }

    var body: some View {
        // Top-aligned, so the line badge and the time sit on the same line
        // whatever hangs below them. Centred, a row with a disclosure under the
        // badge would push its own destination and time half a line down and no
        // two rows would agree.
        HStack(alignment: .top, spacing: 10) {
            // The line column is a fixed width so the destinations line up; a
            // board of two-digit bus routes should not shift when an IR65
            // arrives on it.
            LineBadge(line: entry.line, mode: entry.mode)
                .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                // Wrap only when the destination exhausts the available width.
                Text(showing == .departure ? (entry.to ?? "—") : entry.from)
                    .font(.callout)
                    .lineLimit(2)
                if let stop = entry.stop {
                    // "Bern, Bollwerk" is a five-minute walk from platform 7.
                    Text(stop).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if following > 0, let toggle {
                    Button(action: toggle) {
                        frequencyLine.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide later times" : "Show \(following) later times")
                    .accessibilityValue(frequencyMinutes.map { TimetableCadence.intervalDescription($0) } ?? "")
                } else {
                    frequencyLine.accessibilityHidden(frequencyMinutes == nil)
                }
            }
            // Give the name all remaining width; a separate Spacer can leave
            // unused space beside a destination that has already wrapped.
            .frame(maxWidth: .infinity, alignment: .leading)

            // The dot, the platform and the delay share one reserved block
            // rather than holding a column each, and everything in it is
            // pushed against the clock. A column each meant a row that is on
            // time, or not yet running, paid for the space anyway and left a
            // hole in the middle of itself — three ragged gaps and a badge
            // marooned on the far side of them. Packed to the right, each row
            // says what it has, ending where every other row ends.
            //
            // The block still holds the width of the widest set in the
            // *section*, not the widest in this row, so the rows end together
            // and a board with no platforms and nothing late gives the space
            // back to the destination. Reserved by an invisible copy of that
            // set rather than by a point value: it costs no measurement pass
            // and it follows the type size, which a hard-coded width does not.
            if columns.showsDot || columns.platform != nil || columns.delay != nil {
                ZStack(alignment: .topTrailing) {
                    lateColumns(
                        dot: columns.showsDot, platform: columns.platform,
                        delay: columns.delay, filled: false
                    )
                    .hidden()
                    lateColumns(
                        dot: columns.showsDot && entry.running,
                        platform: columns.platform.flatMap { _ in Format.platform(entry.platform) },
                        delay: columns.delay.flatMap { _ in
                            Format.delay(entry.delay, mode: entry.mode)
                        },
                        filled: true
                    )
                }
                // Keep metadata at its natural width so the destination gets
                // the remaining space without compressing the platform or time.
                .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.time(showing == .departure ? entry.departure : entry.arrival))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Format.delay(entry.delay, mode: entry.mode) == nil ? Color.primary : Format.delayColor)
                ZStack(alignment: .trailing) {
                    Text(columns.relative).hidden()
                    Text(Format.relative(showing == .departure ? entry.departure : entry.arrival, from: now))
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            .fixedSize(horizontal: true, vertical: false)
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
    private var headline: String {
        StopNaming.displayRoute(RouteNaming.trim(line.headline, ref: line.ref))
    }

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
                    if !headline.isEmpty {
                        Text(headline).font(.callout).lineLimit(1).foregroundStyle(.primary)
                    }
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
            Section("Lines on this track") {
                // Tappable for the same reason the serving rows are: the row
                // says a line uses this track and names where it runs between,
                // and the relation it was read out of can say the rest.
                ForEach(lines, id: \.id) { line in
                    let mode = Mode(osmRoute: line.mode)
                    let ref = line.ref ?? ""
                    let route = StopNaming.displayRoute(RouteNaming.trim(
                        RouteNaming.headline(name: line.name, from: line.from, to: line.to) ?? "",
                        ref: ref
                    ))
                    Button {
                        Task { await model.openRoute(relation: line.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                LineBadge(line: ref.isEmpty ? "—" : ref, mode: mode)
                                Text(line.mode.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(line.stops) stops")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            if !route.isEmpty {
                                Text(route)
                                    .font(.callout).lineLimit(2).foregroundStyle(.primary)
                            }
                            if let operatorName = line.operatorName {
                                Text(operatorName).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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
