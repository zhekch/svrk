import SwiftUI
import TransitCore

/// How tall the sheet has to be to show a panel's summary and nothing else.
///
/// The *height of the card*, not where its bottom lands. A position is measured
/// against the sheet, the sheet is sized from this number, and a preference that
/// depends on the size it determines is a cycle — SwiftUI says so out loud
/// ("a presentation preference is rapidly switching between values") and then
/// spends every frame relaying out the sheet, which is what made dragging the
/// card crawl. A height depends on nothing but the text in it.
struct PanelFoldKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One vehicle: what it is, where it is, and every call it makes.
struct VehiclePanel: View {
    @Bindable var model: AppModel
    let vehicle: VehicleSnapshot
    /// The working this vehicle arrived on, where the panel is showing the one
    /// it leaves as instead. Nil whenever the two are the same thing.
    var arrivedAs: VehicleSnapshot?
    /// The stop-time row that opened a scheduled (not currently running)
    /// service. Nil for an actual vehicle selected on the map.
    var boardDeparture: Timestamp? = nil

    /// Which half of a splitting train the stop list is following. Nil until
    /// the reader picks one, which is what makes the first direction the
    /// default without having to copy it into state and keep it in step.
    @State private var direction: String?

    private var now: Timestamp { model.clock.nowSeconds() }

    var body: some View {
        List {
            // One row rather than two, with its own rule between the halves:
            // the sheet opens exactly this tall, and a section that is one row
            // has one height to measure.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    Divider()
                    journeyAhead
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PanelFoldKey.self, value: proxy.size.height.rounded()
                        )
                    }
                )
            }

            // The train itself, between what it does next and the list of
            // everywhere it calls — which is where the question comes up. You
            // have read that it stops at Bern in four minutes; the next thing
            // you want is which end of the platform to be standing at.
            switch model.formationState {
            case .notApplicable:
                // Not a question the service answers about this vehicle, so it
                // is not one the panel raises.
                EmptyView()
            case .loading:
                Section("Formation") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking up the coaches…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            case let .ready(formation):
                if let stop = formationStop(of: formation) {
                    Section("Formation") {
                        FormationView(
                            formation: formation, stop: stop, destination: vehicle.to,
                            stops: vehicle.stops, geometry: vehicle.geometry,
                            stripFor: { [fleet = model.fleet] didok, track in
                                await fleet.platformStrip(didok: didok, track: track)
                            }
                        )
                        // Full bleed, so the train can run off the edge of the
                        // screen rather than stopping short of a margin. The
                        // margin is put back inside the view, around the words.
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                    }
                }
            case .unavailable:
                Section("Formation") {
                    // Said rather than left blank. This is a railway that does
                    // publish formations, so a reader who can see the coaches in
                    // the operator's own app is owed the difference between "we
                    // did not ask" and "we asked and there was nothing" — most
                    // often around midnight, when the realtime system has let go
                    // of yesterday and not yet filled in today.
                    Label(
                        "No formation published for this train right now.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            // Above the stop list, because a cancelled connection changes
            // whether the list is worth reading at all.
            if !model.vehicleAlerts.isEmpty {
                Section("Disruptions") {
                    ForEach(model.vehicleAlerts) { situation in
                        DisruptionRow(situation: situation)
                            .listRowBackground(Situation.alertBackground)
                    }
                }
            }

            if let parts = vehicle.parts, parts.count > 1 {
                Section("Runs as") {
                    // A renumbering shown rather than hidden. The feed files
                    // each numbered leg as its own journey; this vehicle is the
                    // join of them.
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        HStack {
                            LineBadge(line: part.line, mode: part.mode)
                            Text(part.from)
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(part.to ?? "—")
                        }
                        .font(.callout)
                    }
                }
            }

            // The count belongs on the heading of the list it counts, not in a
            // sentence about where the train started.
            Section {
                ForEach(rows) { row in
                    switch row.kind {
                    case let .call(stop, index):
                        CallRow(
                            stop: stop, index: index, vehicle: vehicle, now: now,
                            occupancy: model.vehicleLoad?.at(stop.ref)
                        )
                            .contentShape(Rectangle())
                            .onTapGesture { open(stop) }
                    case let .parting(text):
                        partingRow(text)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("\(callCount) Stops")
                    Spacer(minLength: 8)
                    if directions.count > 1 { directionPicker }
                }
                // The other headings on this panel are written, not shouted,
                // and a station name shouted in a picker is unreadable.
                .textCase(nil)
            }

            // Below the stop list. Works scheduled in August are background a
            // reader may want and never the first thing they need — and put at
            // the top they crowded out the thing that was.
            if !model.vehicleWorks.isEmpty {
                Section("Planned works") {
                    ForEach(model.vehicleWorks) { situation in
                        DisruptionRow(situation: situation, prominent: false)
                    }
                }
            }

            Section {
                geometryNote
            } header: {
                Text("Source")
            }
        }
        .listStyle(.insetGrouped)
        // A thumb's width of nothing above the line badge, which is what pushed
        // the next stop off the bottom of the sheet.
        .contentMargins(.top, 4, for: .scrollContent)
        .navigationTitle(vehicle.line)
        .navigationBarTitleDisplayMode(.inline)
        // A direction picked about one train should not survive the panel
        // moving on to another.
        .onChange(of: vehicle.id) { direction = nil }
    }

    // MARK: - Which way, for a train that splits

    /// One direction the reader can follow past the split.
    ///
    /// The reader's own half is one of these where there is one — a train that
    /// carries on past the parting is already showing those stops — and is
    /// simply absent where there is not: the S44 into Burgdorf *ends* at the
    /// parting, and both directions past it are other workings.
    private struct Direction: Identifiable {
        var id: String
        var label: String
        var coaches: ClosedRange<Int>?
        /// The calls from the parting onward. Empty for the reader's own half,
        /// whose calls are already in the vehicle's own list.
        var calls: [Call]
    }

    private var directions: [Direction] {
        guard let split, split.portions.count > 1 else { return [] }
        var out: [Direction] = []

        // The reader's own half first, so a train that carries on opens on the
        // stops it was opened to see.
        if let mine = vehicle.to, !Self.sameStop(mine, split.stopName) {
            let portion = split.portions.first {
                $0.destination.map { Self.sameStop($0, mine) } ?? false
            }
            out.append(Direction(
                id: "own", label: mine,
                coaches: portion.map { $0.fromPosition...max($0.fromPosition, $0.toPosition) },
                calls: []
            ))
        }
        for branch in model.selectedBranches where !branch.calls.isEmpty {
            out.append(Direction(
                id: branch.id, label: branch.destination ?? branch.splitAt,
                coaches: branch.coaches, calls: branch.calls
            ))
        }
        return out
    }

    private var chosen: Direction? {
        directions.first { $0.id == direction } ?? directions.first
    }

    /// A menu rather than a segmented control. "Sumiswald-Grünen" beside
    /// "Solothurn" in two equal segments is two truncated words; a menu gives
    /// the names the room they need and costs one tap.
    private var directionPicker: some View {
        Menu {
            Picker("Direction", selection: Binding(
                get: { chosen?.id ?? "" },
                set: { direction = $0 }
            )) {
                ForEach(directions) { option in
                    Text(option.coaches.map { "\(option.label) · coaches \($0.lowerBound)–\($0.upperBound)" }
                            ?? option.label)
                        .tag(option.id)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.caption2)
                Text(chosen?.label ?? "").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.caption.weight(.semibold))
            .textCase(nil)
        }
    }

    /// One row of the stop list: a call, or the line where the train comes
    /// apart.
    private struct StopRow: Identifiable {
        var id: String
        var kind: Kind
        enum Kind {
            case call(Call, Int)
            case parting(String)
        }
    }

    /// The stop list for whichever direction is being followed.
    ///
    /// Everything up to the parting is this train, whichever half you are in;
    /// after it, it is the half you picked. Where nothing is picked and nothing
    /// was found, it is simply the train's own calls — which is what it always
    /// was.
    private var rows: [StopRow] {
        let own = vehicle.stops.enumerated().map { index, stop in
            StopRow(id: "own.\(index).\(stop.key)", kind: .call(stop, index))
        }
        guard let split, split.portions.count > 1,
              let parting = vehicle.stops.firstIndex(where: {
                  Self.sameStop($0.name, split.stopName)
              })
        else { return own }

        let branch = chosen?.calls ?? []
        guard !branch.isEmpty else {
            // The reader's own half, or a split whose other workings the feed
            // could not be made to give up: the train's own calls, with a line
            // drawn where it comes apart.
            var out = Array(own[...parting])
            out.append(StopRow(id: "parting", kind: .parting(partingText)))
            out.append(contentsOf: own[(parting + 1)...])
            return out
        }

        // The parting station belongs to both halves and is listed by both, so
        // it is drawn once — and the line that says the train comes apart goes
        // *after* it, whichever half is being followed. Drawn before it, the
        // Zweisimmen list read as parting at Thun and the Brig list at Spiez,
        // which is the same train splitting in two different places.
        //
        // That one row is a merge of the two halves' accounts of the station.
        // Neither is complete on its own: the branch is a fresh working that
        // *begins* there, so it carries the departure and the sector the
        // followed half leaves from and no arrival and no "exit on the left" —
        // an origin has nobody getting off. The trunk carries both of those and
        // the wrong departure.
        let joined = branch.first.flatMap {
            Self.sameStop($0.name, split.stopName) ? $0 : nil
        }
        let onward = branch.enumerated().dropFirst(joined == nil ? 0 : 1).map { index, stop in
            StopRow(id: "branch.\(index).\(stop.key)", kind: .call(stop, index))
        }

        var out = Array(own[..<parting])
        out.append(StopRow(
            id: "parting.call",
            kind: .call(Self.merged(arriving: vehicle.stops[parting], leaving: joined), parting)
        ))
        out.append(StopRow(id: "parting", kind: .parting(partingText)))
        out.append(contentsOf: onward)
        return out
    }

    /// The parting station as one call: arriving on this train, leaving on the
    /// half being followed.
    private static func merged(arriving: Call, leaving: Call?) -> Call {
        guard let leaving else { return arriving }
        var out = arriving
        out.dep = max(arriving.arr, leaving.dep)
        // The sector the followed half stands in, where it has one of its own.
        // "3AB" is a more useful answer than "3" and it is the branch that
        // knows it.
        if leaving.platform != nil { out.platform = leaving.platform }
        if leaving.assigned != nil { out.assigned = leaving.assigned }
        if out.note == nil { out.note = leaving.note }
        return out
    }

    private var callCount: Int {
        rows.count { if case .call = $0.kind { return true } else { return false } }
    }

    private var partingText: String {
        guard let split else { return "The train splits here" }
        guard let coaches = chosen?.coaches else {
            return "The train splits at \(split.stopName)"
        }
        return "Coaches \(coaches.lowerBound)–\(coaches.upperBound) from here"
    }

    private func partingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 11)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
        }
        .listRowBackground(Color.orange.opacity(0.08))
    }

    /// Where this train parts company, and which coaches go where.
    ///
    /// From the formation rather than from the halves the feed could be made to
    /// give up: the coach goals say a train splits and where its portions are
    /// bound long before either half can be found as a journey, and half the
    /// splits in the country never name a journey at all.
    private var split: TrainFormation.Split? { model.formation?.split }

    /// The destinations of a split that this train's own heading does not
    /// already name.
    private var otherDestinations: [String] {
        (split?.portions ?? []).compactMap(\.destination).filter { destination in
            guard let mine = vehicle.to else { return true }
            return !Self.sameStop(mine, destination)
        }
    }

    /// Both destinations for a train that splits, one for a train that does not.
    ///
    /// A reader standing on the platform at Bern is looking at one train, and
    /// half of it is going somewhere the old heading never mentioned. Two names
    /// fit a heading; three do not, and where a train parts into more than the
    /// reader's own half plus one, the halves are left to the line under it.
    private var headline: String {
        guard let mine = vehicle.to else { return "—" }
        guard otherDestinations.count == 1 else { return mine }
        return "\(mine) / \(otherDestinations[0])"
    }

    /// The line under the heading that says a train parts, and what goes where.
    private var splitNote: String? {
        guard let split, split.portions.count > 1 else { return nil }
        let halves = split.portions.compactMap { portion -> String? in
            guard let destination = portion.destination else { return nil }
            return "coaches \(portion.fromPosition)–\(portion.toPosition) to \(destination)"
        }
        guard !halves.isEmpty else { return nil }
        return "Splits at \(split.stopName) — " + halves.joined(separator: ", ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LineBadge(line: vehicle.line, mode: vehicle.mode)
                Text(headline).font(.headline)
                Spacer()
                if let delay = Format.delay(vehicle.delay) {
                    Text(delay)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(vehicle.delay! > 0 ? .orange : .green)
                }
            }
            if let splitNote {
                // The map now draws every branch, and a heading naming one of
                // them over a picture with two lines in it is the panel and the
                // map disagreeing about what was tapped.
                Label(splitNote, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let arrivedAs, shouldShowArrivalAs(arrivedAs) {
                // Said out loud, because otherwise the panel simply *is* a
                // different train from the one that was tapped. A terminating
                // S6 is shown as the S52 it leaves as — which is the departure
                // anybody on that platform is waiting for — while the map keeps
                // its ring on the dot labelled S6, and with nothing joining the
                // two that reads as the wrong train, not as a turnback.
                Label(
                    "Arrived as \(arrivedAs.line) from \(arrivedAs.from)",
                    systemImage: "arrow.uturn.left"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !startsWhereItStands {
                // Left off where the train is standing at the station it
                // started from: "from Bern" directly above "AT THIS STOP ·
                // Bern" is the same word twice, and the second one is the one
                // carrying information.
                Text("from \(vehicle.from)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let operatorName = vehicle.operatorName {
                Text(vehicle.operatorFull ?? operatorName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if vehicle.cancelled {
                Label("Cancelled", systemImage: "xmark.octagon.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            // A run nobody can look up is exactly the one a passenger doubts,
            // so it says so rather than passing itself off as timetabled.
            if vehicle.extra {
                Label("Unscheduled service", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
            }
            // Cancelled *calls* on a run that is otherwise going ahead. Counted
            // here as well as struck through below, because the one row a
            // passenger needs is the one they will not scroll to.
            if !vehicle.cancelled, vehicle.stops.contains(where: \.cancelled) {
                Label(
                    Self.skippedSummary(vehicle.stops.filter(\.cancelled)),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
        }
    }

    /// "Does not stop at Clochatte", or a count once naming them all would be
    /// a paragraph rather than a label.
    static func skippedSummary(_ skipped: [Call]) -> String {
        switch skipped.count {
        case 1: return "Does not stop at \(skipped[0].name)"
        case 2: return "Does not stop at \(skipped[0].name) or \(skipped[1].name)"
        default: return "Does not stop at \(skipped.count) of its stops"
        }
    }

    /// Whether the train is standing at the station it starts from.
    private var startsWhereItStands: Bool {
        guard !vehicle.moving, vehicle.stops.indices.contains(vehicle.index) else { return false }
        return Self.sameStop(vehicle.stops[vehicle.index].name, vehicle.from)
    }

    /// A vehicle that came from the destination it is about to serve is simply
    /// continuing the same named route. Repeating that in the header adds no
    /// useful distinction (for example, "3 from Weissenbühl" above "3
    /// Weissenbühl").
    private func shouldShowArrivalAs(_ arrivedAs: VehicleSnapshot) -> Bool {
        guard let destination = vehicle.to else { return true }
        return !Self.sameStop(destination, arrivedAs.from)
    }

    /// Whether two names are one place written two ways.
    ///
    /// The feed does not agree with itself about punctuation. A bus whose
    /// origin is filed as "Bern Bahnhof" calls at "Bern, Bahnhof", and on an
    /// exact comparison one comma was enough to print "from Bern Bahnhof"
    /// directly above "AT THIS STOP · Bern, Bahnhof" — the line this test
    /// exists to suppress. Only separators are thrown away, so "Bern" and
    /// "Bern, Bahnhof" stay the different places they are.
    private static func sameStop(_ a: String, _ b: String) -> Bool {
        func key(_ name: String) -> String {
            name.lowercased()
                .split { $0 == "," || $0 == "." || $0.isWhitespace }
                .joined(separator: " ")
        }
        return key(a) == key(b)
    }

    /// What happens next, which is the whole of what this panel is for.
    ///
    /// It used to open with departure, arrival, stop count and speed. Three of
    /// those are written again in the call list a thumb's width below — the
    /// first line and the last line of it — and the fourth answers a question
    /// nobody standing on a platform is asking. What they are asking is where
    /// this thing stops next, when, and which side to stand on.
    @ViewBuilder
    private var journeyAhead: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The load the vehicle is carrying now, said once at the top. The
            // per-stop meters below show how it changes along the run; this is
            // the answer to "will I get a seat", which is the question somebody
            // opening the panel on a platform is actually asking.
            if let ahead = model.vehicleLoad?.ahead(of: vehicle.index, in: vehicle.stops) {
                OccupancySummary(occupancy: ahead)
            }
            if let index = boardDepartureIndex {
                let stop = vehicle.stops[index]
                block(
                    caption: "Departure",
                    trailing: nil,
                    stop: stop,
                    detail: "departs \(Format.time(stop.dep)) · \(when(stop.dep))",
                    side: nil
                )
                if index + 1 < vehicle.stops.count {
                    Divider()
                    let next = vehicle.stops[index + 1]
                    block(
                        caption: index + 1 == vehicle.stops.count - 1
                            ? "Terminal stop" : "Next stop",
                        trailing: nil,
                        stop: next,
                        detail: "arrives \(Format.time(next.arr)) · \(when(next.arr))",
                        side: vehicle.platformSide(at: index + 1)
                    )
                }
            } else if !vehicle.moving, vehicle.stops.indices.contains(vehicle.index) {
                block(
                    caption: atTerminus ? "Terminal stop" : "Currently at",
                    trailing: nil,
                    stop: vehicle.stops[vehicle.index],
                    detail: standingDetail,
                    side: nil
                )
            }
            if boardDepartureIndex == nil, let next = nextIndex {
                if !vehicle.moving { Divider() }
                let stop = vehicle.stops[next]
                block(
                    caption: next == vehicle.stops.count - 1 ? "Terminal stop" : "Next stop",
                    // The one number worth keeping from the old row, and this is
                    // where it belongs: beside the arrival it explains.
                    trailing: vehicle.moving ? "\(Int(vehicle.speed)) km/h" : nil,
                    stop: stop,
                    detail: "arrives \(Format.time(stop.arr)) · \(when(stop.arr))",
                    side: vehicle.platformSide(at: next)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One stop, said in full: what it is, which platform, when, which side.
    ///
    /// Tappable, like every other stop this panel names — the question a reader
    /// has next is what else calls there, and it was answerable from the list
    /// below but not from the one line about it above.
    private func block(
        caption: String, trailing: String?, stop: Call, detail: String, side: PlatformSide?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(caption.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(stop.name).font(.title3.weight(.semibold))
                Spacer(minLength: 6)
                PlatformChip(stop: stop)
            }
            Text(detail)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if let side {
                // The arrow sits on the side it is pointing at: leading it for a
                // left-hand exit, trailing it for a right-hand one, so the row
                // reads as the gesture it describes rather than as a label with
                // a fixed icon well.
                let arrow = Image(systemName: side == .left ? "arrow.left" : "arrow.right")
                HStack(spacing: 6) {
                    if side == .left { arrow }
                    Text(side == .left ? "Exit on the left" : "Exit on the right")
                    if side == .right { arrow }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(stop) }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the board for \(stop.name)")
    }

    /// The question a reader has next: this train stops there — what else does?
    private func open(_ stop: Call) {
        Task { await model.selectStation(call: stop) }
    }

    /// The stop the formation is drawn for: the one the card above it is
    /// already talking about.
    ///
    /// Matched by name rather than by index. The formation service lists a
    /// train's own stops, and the panel may be showing a run the feed filed as
    /// two numbered legs joined into one — so the two lists are the same
    /// journey and need not be the same length.
    private func formationStop(of formation: TrainFormation) -> FormationAtStop? {
        // Where it is standing, when it is standing: a train at a platform is
        // one a reader may be about to board, and the sectors that matter are
        // the ones under their feet. Once it is running, the next stop is the
        // next chance to get on. The same choice the card above makes.
        let wanted = vehicle.moving ? (nextIndex ?? vehicle.index) : vehicle.index
        if vehicle.stops.indices.contains(wanted),
           let match = formation.stop(named: vehicle.stops[wanted].name), !match.isEmpty {
            return match
        }
        // The train stands somewhere the formation service spells differently
        // from the stop register — or the panel is showing a leg the formation
        // does not cover. The drawing is still the right train, so rather than
        // drop it, it is shown for whichever of the train's stops is closest in
        // time to the one the card is about. Nearest in time and not simply the
        // first, because the first is the origin and the sectors there are a
        // different station's.
        guard vehicle.stops.indices.contains(wanted) else {
            return formation.stops.first { !$0.isEmpty }
        }
        let when = Date(timeIntervalSince1970: TimeInterval(vehicle.stops[wanted].arr))
        return formation.stops
            .filter { !$0.isEmpty }
            .min { a, b in a.distance(from: when) < b.distance(from: when) }
    }

    private var atTerminus: Bool { vehicle.index == vehicle.stops.count - 1 }

    /// Match the board row by its published departure, not by name: one
    /// journey may call at two stops with similar names, while this timestamp
    /// is the exact value the board was built from.
    private var boardDepartureIndex: Int? {
        guard let boardDeparture else { return nil }
        return vehicle.stops.firstIndex { $0.dep == boardDeparture }
    }

    private var nextIndex: Int? {
        // Standing at call `i` or running the leg out of it, the stop ahead is
        // the same one either way.
        let next = vehicle.index + 1
        return next < vehicle.stops.count ? next : nil
    }

    /// What the vehicle standing here is doing, in the fewest words that stay
    /// true.
    ///
    /// A train that has arrived and is booked out of the same platform later is
    /// neither running nor gone: it is standing there, and saying until when is
    /// the difference between a stale marker and a waiting train. The same is
    /// true of a run that simply ends: it holds the platform for
    /// `Positioning.terminusHold` before the marker is taken away.
    private var standingDetail: String {
        let stop = vehicle.stops[vehicle.index]
        if atTerminus {
            let arrived = "arrived \(Format.time(stop.arr))"
            let until = Positioning.standsUntil(
                mode: vehicle.mode, arrived: stop.arr, layover: vehicle.layover
            )
            // A layover is stored one second short of the next departure so
            // the two workings never overlap; display the departure itself.
            let shown = vehicle.layover == nil ? until : until + 1
            guard shown > stop.arr else { return arrived }
            return "\(arrived) · stands until \(Format.time(shown))"
        }
        return "departs \(Format.time(stop.dep)) · \(when(stop.dep))"
    }

    /// "in 4 min", "now", "2 min ago".
    ///
    /// The same words as `Format.relative`, which stops at an hour and prints a
    /// clock time instead: on a board that is right beside the time it replaces,
    /// and in a sentence it is a gap.
    private func when(_ stamp: Timestamp) -> String {
        let minutes = Int((Double(stamp - now) / 60).rounded())
        if minutes == 0 { return "now" }
        if minutes < 0 { return "\(-minutes) min ago" }
        if minutes < 60 { return "in \(minutes) min" }
        return "in \(minutes / 60) h \(minutes % 60) min"
    }

    /// The panel says which of the three sources is in play, because the
    /// difference is real: a mapped relation states which ways the vehicle uses,
    /// the rail graph infers them, and a straight line is a guess.
    @ViewBuilder
    private var geometryNote: some View {
        let geometry = vehicle.geometry
        let mapped = geometry?.legSources.count { $0 == .route } ?? 0
        let routed = geometry?.legSources.count { $0 == .graph } ?? 0
        let straight = geometry?.legSources.count { $0 == .chord } ?? 0
        let total = max(1, mapped + routed + straight)

        VStack(alignment: .leading, spacing: 8) {
            if geometry == nil {
                if boardDeparture != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading mapped route…")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No data yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                sourceRow("Mapped OSM route", mapped, total, .green,
                          "Full detail available.")
                if routed > 0 {
                    sourceRow("Auto routed", routed, total, .yellow,
                              "Inferred track.")
                }
                if straight > 0 {
                    sourceRow("Straight line", straight, total, .orange,
                              "Not possible to route.")
                }
                if let name = geometry?.routeName {
                    Text(name).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sourceRow(_ title: String, _ count: Int, _ total: Int, _ tint: Color, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text("\(count)/\(total) legs").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// One call in the list.
struct CallRow: View {
    let stop: Call
    let index: Int
    let vehicle: VehicleSnapshot
    let now: Timestamp
    /// How full the vehicle is expected to be leaving this stop, where OJP
    /// publishes a forecast for it. See `LoadService`.
    var occupancy: Occupancy? = nil

    /// Standing at this call, or the clock still inside the booked dwell.
    ///
    /// The clock alone is not enough at a terminus: arrival and departure are
    /// the same second, and the vehicle still stands there for
    /// `Positioning.terminusHold`. The snapshot already knows which call it
    /// is on.
    private var isHere: Bool {
        if !vehicle.moving, vehicle.index == index { return true }
        return now >= stop.arr && now <= stop.dep
    }
    private var isPast: Bool {
        if isHere { return false }
        return stop.dep < now
    }

    var body: some View {
        HStack(spacing: 10) {
            marker

            VStack(alignment: .leading, spacing: 1) {
                Text(stop.name)
                    .font(.callout)
                    .strikethrough(stop.cancelled, color: .red)
                    .foregroundStyle(nameColour)
                // Said in words as well as struck through: a strikethrough is
                // a style, and a style is not a statement — at a glance down a
                // column of thirty rows it reads as emphasis of some kind
                // rather than as "the bus will not be stopping here".
                if stop.cancelled {
                    Text("Cancelled").font(.caption2).foregroundStyle(.red)
                } else if stop.extra {
                    Text("Additional stop").font(.caption2).foregroundStyle(.teal)
                }
                if let note = Format.note(stop.note) {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if let level = occupancy?.worst {
                OccupancyMeter(level: level)
                    .padding(.trailing, 2)
            }

            PlatformChip(stop: stop)

            VStack(alignment: .trailing, spacing: 1) {
                Text(times)
                    .font(.callout.monospacedDigit())
                    // The time is the timetable's, and the timetable is what
                    // has been withdrawn; printed plainly it is a promise the
                    // vehicle will not keep.
                    .strikethrough(stop.cancelled, color: .red)
                    .foregroundStyle(stop.cancelled ? Color.secondary : .primary)
                if let delay = Format.delay(stop.delay) {
                    Text(delay)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Below this, a call is one moment and gets one time.
    ///
    /// A two-minute dwell is what every stop on a local service looks like once
    /// the timetable is rounded to the minute, so printing `15:14–15:16` down a
    /// whole column doubles the digits to say something that is true of nearly
    /// every row. A four-minute wait at a junction is different — that is a
    /// connection being held, and worth two times.
    private static let dwellWorthTwoTimes = 120

    /// Arrival and departure, as a board writes them: `13:55–14:02` where the
    /// vehicle really stands, and the departure alone where it does not.
    ///
    /// The departure rather than the arrival, because it is the one a passenger
    /// acts on: miss it and the train is gone.
    private var times: String {
        stop.dep - stop.arr <= Self.dwellWorthTwoTimes
            ? Format.time(stop.dep)
            : "\(Format.time(stop.arr))–\(Format.time(stop.dep))"
    }

    /// The dot lights up once the call is behind the vehicle.
    ///
    /// On the clock rather than on the feed's confirmation. SIRI marks a call
    /// *observed* when it reports the time the vehicle really left, as opposed
    /// to a forecast — a genuine distinction, but not the one being read here:
    /// most operators confirm little or nothing, so a run half an hour into its
    /// journey showed a single lit dot at the origin and nine dead ones behind
    /// times that had plainly already happened. How far along it is, is what the
    /// column is for, and the timetable answers that for every vehicle.
    private var marker: some View {
        ZStack {
            Circle()
                .strokeBorder(ringColor, lineWidth: isHere ? 3 : 1.5)
                .frame(width: 11, height: 11)
            if isPast || isHere {
                Circle()
                    .fill(ringColor)
                    .frame(width: 5, height: 5)
                    .shadow(color: ringColor.opacity(0.9), radius: 3)
            }
        }
    }

    private var nameColour: Color {
        if stop.cancelled { return .secondary }
        return isPast && !isHere ? .secondary : .primary
    }

    private var ringColor: Color {
        // A call that will not happen is not "still to come" and never becomes
        // "done"; the column's green-behind/grey-ahead reading does not apply
        // to it at all, so it is taken out of that scale rather than placed on
        // it wrongly.
        if stop.cancelled { return .red }
        if isHere { return .accentColor }
        if isPast { return .green }
        return .secondary.opacity(0.5)
    }
}

/// The platform a call is booked for, drawn as a sign.
struct PlatformChip: View {
    let stop: Call

    var body: some View {
        if let platform = stop.platform ?? stop.assigned {
            Text(platform)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                // A letter this map invented is not signage, so it is not
                // dressed up as one.
                .foregroundStyle(stop.platform == nil ? .secondary : .primary)
        }
    }
}

struct LineBadge: View {
    let line: String
    let mode: Mode

    var body: some View {
        Text(line)
            .font(.caption.weight(.bold))
            // One line, always. The line column on a board is a fixed width, so
            // a designation the length of `BN-M75` wrapped inside the plate and
            // took a second row of the badge with it — a two-storey chip beside
            // the one-storey ones, and a row half a line taller than its
            // neighbours. A real sign does not wrap; it sets the number
            // narrower.
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(mode.color, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.white)
    }
}

#Preview("Vehicle detail") {
    let now = Int(Date().timeIntervalSince1970)
    let stops = [
        Call(key: "bern", name: "Bern", lat: 46.9480, lon: 7.4390,
             platform: "10", precise: true, arr: now - 60, dep: now + 120, observed: true),
        Call(key: "zofingen", name: "Zofingen", lat: 47.2875, lon: 7.9456,
             platform: "2", precise: true, arr: now + 28 * 60, dep: now + 29 * 60)
    ]
    VehiclePanel(
        model: AppModel(),
        vehicle: VehicleSnapshot(
            id: "preview-ir15", mode: .train, category: "IR", line: "IR15",
            operatorName: "SBB", operatorFull: "Schweizerische Bundesbahnen SBB",
            to: "Luzern", from: "Genève", lon: 7.4390, lat: 46.9480,
            index: 0, stops: stops
        )
    )
    .preferredColorScheme(.dark)
}
