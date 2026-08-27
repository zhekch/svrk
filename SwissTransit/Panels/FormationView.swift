import SwiftUI
import TransitCore

/// The train itself, drawn: which coaches are on it, in what order, and where
/// each one will stop on the platform.
///
/// Front of the train at the left, always, because the formation service lists
/// vehicles from the front — see the note in `Formation.swift` for how that was
/// established rather than assumed. The arrow above the drawing says so out
/// loud, since a train drawn left-to-right and *travelling* left is the one
/// thing about this picture a reader could get backwards.
///
/// The sector letters under it are the part that actually gets used. A twenty
/// coach train is four hundred metres of platform, and "coach 5, sector C" is
/// the difference between a comfortable walk and a run. Which is why the
/// station at the top is tappable: the coaches do not change along the run, but
/// the sectors they stand in change at every stop, and the stop a reader wants
/// is not always the one the panel opened on.
struct FormationView: View {
    let formation: TrainFormation
    /// The stop the panel is already talking about, and where the picker opens.
    let stop: FormationAtStop
    /// Where the train is going, named on the direction arrow.
    let destination: String?
    /// The vehicle's own calls and the line it runs on, which is what puts the
    /// train at a *place* on the platform rather than merely on it. Both come
    /// off the snapshot the panel is already showing; see `PlatformPlacement`.
    var stops: [Call] = []
    var geometry: JourneyGeometry?
    /// The platform strip for a stop, by DIDOK number and track. A closure
    /// because the index lives behind the fleet actor and this view is not the
    /// place to know that.
    var stripFor: (@Sendable (Int, String?) async -> PlatformStrip?)?
    /// The coach a tap has opened. Nil until something is tapped, and it stays
    /// in a card under the drawing rather than opening a sheet: what is in
    /// coach 9 is a footnote to the picture, not a place to navigate to.
    @State private var opened: Int?
    /// The stop the reader picked, as an index into `formation.stops`. Nil
    /// until they pick one, which is what makes `stop` the default without
    /// having to copy it into state and keep it in step.
    @State private var chosen: Int?
    /// How wide the panel is, so a train shorter than it can be drawn to fill
    /// it. Zero until the first layout pass, which draws at natural size.
    @State private var panelWidth: CGFloat = 0
    /// The platform under this stop, once it has been looked up. Nil while it
    /// loads and for every stop that has no strip — most bus stops, and any
    /// station OpenStreetMap has not drawn.
    @State private var strip: PlatformStrip?

    private static let wagonHeight: CGFloat = 50
    /// The inset a grouped list gives its own rows, put back by hand.
    private static let margin: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading.padding(.horizontal, Self.margin)

            // The row this sits in is full-bleed (see `VehiclePanel`) and the
            // margin is put back inside the scroll view instead. A four hundred
            // metre train is wider than any phone, and a drawing that runs off
            // the edge of the screen reads as continuing; one that stops short
            // of a margin reads as the whole train.
            // The train and the platform share one drawing and one scale, so
            // the sector the third coach stands in and the staircase ninety
            // metres behind it are the same picture rather than two that have
            // to be read against each other.
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Where the train splits, the one arrow becomes one per
                        // half: which coaches go to Brig and which to Zweisimmen is
                        // the whole question at a stop like Spiez, and a single
                        // "toward Brig" over a train where half of it is not going
                        // to Brig is worse than saying nothing.
                        // The train is pushed along by a spacer rather than by
                        // `offset`, and it carries the scroll anchor itself.
                        // An offset moves pixels and not layout, so a scroll
                        // view asked to reach an offset view goes to where the
                        // view still *is* — the far left — and the train stays
                        // off the right-hand edge, which is exactly what it did.
                        HStack(alignment: .top, spacing: 0) {
                            Color.clear.frame(width: trainOffset, height: 1)
                            VStack(alignment: .leading, spacing: 6) {
                                if portionRuns.count > 1 { portionBar } else { directionBar }
                                train
                            }
                            .id(Self.trainAnchor)
                        }
                        platformBand
                    }
                    .padding(.vertical, 2)
                }
                .contentMargins(.horizontal, Self.margin, for: .scrollContent)
                // Reached on every change that moves it: the platform arrives
                // after the card is already on screen, and the train's place on
                // it is not known until it does.
                .onChange(of: trainOffset) { _, _ in showTrain(scroller) }
                .onChange(of: shown.uic) { _, _ in showTrain(scroller) }
                .onAppear { showTrain(scroller) }
            }

            if let opened, let coach = shown.coaches.first(where: { $0.position == opened }) {
                detail(of: coach).padding(.horizontal, Self.margin)
            }
            notes.padding(.horizontal, Self.margin)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { panelWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in panelWidth = width }
            }
        }
        .animation(.snappy(duration: 0.22), value: opened)
        .animation(.snappy(duration: 0.22), value: chosen)
        .sensoryFeedback(.selection, trigger: opened)
        .sensoryFeedback(.selection, trigger: chosen)
        // The panel can move on to the next stop underneath us — the train
        // leaves, and the card starts talking about somewhere else. A choice
        // made about the old stop should not survive that.
        .onChange(of: stop.uic) { chosen = nil; opened = nil }
        .task(id: "\(shown.uic)|\(shown.track ?? "")") {
            strip = await stripFor?(shown.uic, shown.track)
        }
    }

    /// Bring the train back into view.
    ///
    /// On the next turn of the run loop rather than now: during a layout pass
    /// the scroll view has not yet placed the anchor, and scrolling to a view
    /// it has not placed does nothing at all — which is how a card opened on
    /// four hundred metres of empty platform with the train off the edge.
    private func showTrain(_ scroller: ScrollViewProxy) {
        DispatchQueue.main.async {
            scroller.scrollTo(Self.trainAnchor, anchor: .leading)
        }
    }

    // MARK: - Which stop

    /// The stops the drawing can say anything about.
    ///
    /// A stop whose vehicles did not resolve is not offered: picking it would
    /// empty the picture, and an option that blanks the thing it is attached to
    /// is worse than one that is not there.
    private var choices: [Int] {
        formation.stops.indices.filter { !formation.stops[$0].isEmpty }
    }

    private var shownIndex: Int? {
        if let chosen, formation.stops.indices.contains(chosen) { return chosen }
        return formation.stops.firstIndex { $0.uic == stop.uic && $0.track == stop.track }
            ?? formation.stops.firstIndex { $0.uic == stop.uic }
    }

    private var shown: FormationAtStop {
        shownIndex.map { formation.stops[$0] } ?? stop
    }

    private var selection: Binding<Int> {
        Binding(
            get: { shownIndex ?? choices.first ?? 0 },
            set: { chosen = $0; opened = nil }
        )
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Baselines, not centres. "Track 2" is a caption next to a
            // subheadline, and centring the two boxes floats the smaller one
            // above the line the station name sits on.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stopControl
                if let track = shown.track {
                    Text("Track \(track)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let clock = times {
                    Text(clock).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// The station name — the heading it already was, which happens to open the
    /// rest of the run when you tap it.
    ///
    /// Deliberately undecorated. A capsule with a chevron in it announces a
    /// control and turns the one word that says *where this drawing is* into a
    /// widget; the name is the heading, and the menu is what it does.
    @ViewBuilder
    private var stopControl: some View {
        if choices.count > 1 {
            // The name is the control, but only as a hit target. A menu's own
            // label is lifted off the card and morphed into the menu as it
            // opens, and again on the way back — so a heading that is the label
            // drifts every time the list is opened, and the drawing reads as
            // rearranging itself when nothing has changed. The label here is a
            // clear rectangle laid over the name: the system animates that,
            // which is nothing, and the word stays where it was written.
            Text(shown.stopName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
                .overlay {
                    Menu {
                        Picker("Stop", selection: selection) {
                            ForEach(choices, id: \.self) { index in
                                Text(menuLabel(formation.stops[index])).tag(index)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Stop: \(shown.stopName). Choose another stop on this train."
                    )
                }
        } else {
            Text(shown.stopName).font(.subheadline.weight(.semibold))
        }
    }

    private func menuLabel(_ stop: FormationAtStop) -> String {
        var line = stop.stopName
        if let time = stop.arrival ?? stop.departure {
            line += "  ·  \(Self.clock.string(from: time))"
        }
        if let track = stop.track { line += "  ·  Track \(track)" }
        return line
    }

    private var times: String? {
        let arrival = shown.arrival.map { Self.clock.string(from: $0) }
        let departure = shown.departure.map { Self.clock.string(from: $0) }
        // Compared as printed rather than as dates: a stop booked to arrive at
        // 02:24:10 and leave at 02:24:40 is two different instants and one
        // minute, and "arr 02:24 · dep 02:24" says the same thing twice.
        if let arrival, arrival == departure { return "arr & dep \(arrival)" }
        var parts: [String] = []
        if let arrival { parts.append("arr \(arrival)") }
        if let departure { parts.append("dep \(departure)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        return formatter
    }()

    /// The train in one line of numbers. Length is the one people underestimate:
    /// four hundred metres is most of a platform.
    private var summary: String? {
        var parts: [String] = []
        let coaches = shown.coaches.count { $0.kind.carriesPassengers }
        if coaches > 0 { parts.append("\(coaches) \(coaches == 1 ? "coach" : "coaches")") }
        if let length = formation.totalLength, length > 0 {
            parts.append("\(Int(length.rounded())) m")
        }
        if let seats = formation.totalSeats, seats > 0 { parts.append("\(seats) seats") }
        // Said once in words, so the row of letters under the drawing reads as
        // the platform it is rather than as a caption nobody explained.
        if let first = shown.sectors.first, let last = shown.sectors.last {
            parts.append(shown.sectors.count == 1
                ? "sector \(first)" : "sectors \(first)–\(last)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Direction

    private var directionBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 8))
            Text(destination.map { "toward \($0)" } ?? "direction of travel")
                .font(.caption2.weight(.semibold))
            Capsule()
                .frame(height: 1.5)
                .frame(maxWidth: .infinity)
                .opacity(0.4)
        }
        .foregroundStyle(.tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Direction of travel is to the left. The front of the train is drawn first."
        )
    }

    /// One portion of a splitting train, measured against the drawing.
    ///
    /// The widths come out of `layout`, which is the same list the coaches are
    /// drawn from — so a heading sits over its own half rather than over an
    /// estimate of where that half is.
    private struct PortionRun {
        let destination: String
        let width: CGFloat
        /// The gap before this group, which is the join the two halves part at.
        let leading: CGFloat
    }

    /// What to call a portion whose destination the service named only by
    /// number and the register could not put a name to.
    ///
    /// The train's own destination, because the portion that goes unnamed is
    /// the one carrying on to the far end of the run — a foreign station, which
    /// is exactly the case the service leaves blank. Better a name that is
    /// right nearly always than a portion drawn with a dash over it.
    private func name(of portion: FormationAtStop.Portion) -> String? {
        portion.destination ?? destination
    }

    private var portionRuns: [PortionRun] {
        guard shown.portions.count > 1 else { return [] }
        let placed = layout
        var out: [PortionRun] = []
        for portion in shown.portions {
            guard let destination = name(of: portion) else { continue }
            let members = placed.indices.filter {
                let position = placed[$0].coach.position
                return position >= portion.fromPosition && position <= portion.toPosition
            }
            guard let first = members.first else { continue }
            var width: CGFloat = 0
            for (offset, index) in members.enumerated() {
                if offset > 0 { width += placed[index].gap }
                width += placed[index].spec.width
            }
            out.append(PortionRun(
                destination: destination,
                width: width,
                leading: out.isEmpty ? 0 : placed[first].gap
            ))
        }
        return out
    }

    /// A direction arrow per half, each over the coaches it speaks for.
    private var portionBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(portionRuns.enumerated()), id: \.offset) { _, run in
                if run.leading > 0 { Color.clear.frame(width: run.leading, height: 1) }
                HStack(spacing: 4) {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 7))
                    Text("Direction \(run.destination)")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        // The name gets the room it needs and the rule takes
                        // what is left. Both are flexible otherwise, and a
                        // greedy rule shortened "Zweisimmen" to "Zwe…" over the
                        // three coaches that are the ones going there.
                        .layoutPriority(1)
                    Capsule()
                        .frame(height: 1.5)
                        .frame(maxWidth: .infinity)
                        .opacity(0.4)
                }
                .foregroundStyle(.tint)
                // Held to the width of its own half. A long station name over a
                // two-coach portion truncates rather than running on over the
                // half next to it and labelling the wrong coaches.
                .frame(width: run.width, alignment: .leading)
                .clipped()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "This train splits. "
                + portionRuns.map { "Coaches toward \($0.destination)." }.joined(separator: " ")
        )
    }

    // MARK: - The train

    /// One vehicle, placed: what to draw and how much room to leave in front.
    private struct Placed {
        let coach: Coach
        let spec: WagonSpec
        /// The gap ahead of this vehicle. Zero for the leading one.
        let gap: CGFloat
        let blocked: Bool
    }

    /// The whole train worked out once — widths, cabs, markings, gaps — so the
    /// drawing and the sector bands underneath it are laid out from the same
    /// numbers and cannot drift apart.
    private var naturalLayout: [Placed] {
        let coaches = shown.coaches
        // A gangway that cannot be walked through is worth the room, because on
        // a train that splits it is the difference between the half that goes
        // where you are going and the half that does not. Read from either side
        // of the join: the service states it twice and does not always state it
        // twice consistently.
        let blocked = coaches.indices.map { index in
            index > 0
                && (coaches[index].noAccessForward || coaches[index - 1].noAccessBackward)
        }
        return coaches.indices.map { index in
            // A join with no way through is where two units are coupled, and
            // the ends of a unit are driving cabs. So the cab is not only drawn
            // at the two ends of the train: a six-car regional service made of
            // two threes has four of them, and drawing the middle pair square
            // made one train out of what is plainly two.
            let cabFront = index == 0 || blocked[index]
            let cabBack = index == coaches.count - 1
                || (index + 1 < blocked.count && blocked[index + 1])
            return Placed(
                coach: coaches[index],
                spec: WagonSpec(
                    coach: coaches[index], cabFront: cabFront, cabBack: cabBack,
                    stripe: Self.stripe(of: coaches, at: index)
                ),
                gap: index == 0 ? 0 : (blocked[index] ? 15 : 4),
                blocked: blocked[index]
            )
        }
    }

    /// Which end of a coach the yellow band runs along.
    ///
    /// A coach that is first class throughout carries it end to end and there
    /// is nothing to decide. A `12` — half of each — is the whole question, and
    /// the service does not answer it: the short string says the coach has two
    /// classes in it and nothing about which end.
    ///
    /// It is answerable anyway, because first class on a Swiss train is never
    /// scattered. The coaches carrying it sit together and a `12` sits at the
    /// end of that block with its first-class half facing it — that is what
    /// makes the first-class part of a train one continuous stretch of platform
    /// rather than two pieces with a second-class carriage between them. So the
    /// band goes on the end nearest the nearest other coach with first class in
    /// it.
    ///
    /// Any other such coach, not only a full-first one. Two `12`s side by side
    /// are the commonest first-class block there is, and looking only for a `1`
    /// found nothing on a train that has none — so both bands were drawn on the
    /// leading half, with half a coach of second class between them and the
    /// stretch they mark broken in two. Each now turns its band towards the
    /// other.
    ///
    /// With no other first-class coach anywhere on the train there is nothing
    /// to face and the leading half is drawn, which is where it was always
    /// drawn.
    static func stripe(of coaches: [Coach], at index: Int) -> WagonSpec.Stripe {
        let stripe = coaches[index].kind.stripe
        guard stripe == .leadingHalf else { return stripe }

        func distanceToFirstClass(_ range: any Sequence<Int>) -> Int? {
            for i in range where coaches[i].kind.stripe != .none { return abs(i - index) }
            return nil
        }
        let ahead = distanceToFirstClass(stride(from: index - 1, through: 0, by: -1))
        let behind = distanceToFirstClass((index + 1)..<coaches.count)

        switch (ahead, behind) {
        case let (ahead?, behind?): return ahead <= behind ? .leadingHalf : .trailingHalf
        case (_?, nil): return .leadingHalf
        case (nil, _?): return .trailingHalf
        case (nil, nil): return .leadingHalf
        }
    }

    /// The train at natural size where it is longer than the panel, stretched
    /// to fill the panel where it is shorter.
    ///
    /// A four-coach regional service drawn to scale left half the card empty,
    /// and an empty half reads as a train that has been cut off rather than one
    /// that is simply short. Scale is not what this drawing is for — the sector
    /// letters and the order of the coaches are — and the stretched shape is
    /// closer to a real vehicle in profile than the squat one it replaces.
    ///
    /// Only the vehicles take the extra room. Stretching the gaps too widened
    /// the join between two coupled units into a hole in the middle of the
    /// train, which is the one gap that has to read as a coupling.
    ///
    /// And only up to `fill`. Three coaches stretched across a phone are a
    /// train; two are a pair of shipping containers, and one is a wall. The
    /// stretch is capped at a third of the panel per vehicle, so a three-car
    /// unit fills the card and anything shorter keeps the proportions that say
    /// it is short.
    private var layout: [Placed] {
        let base = naturalLayout
        guard !base.isEmpty else { return base }
        let gaps = base.reduce(0) { $0 + $1.gap }
        let bodies = base.reduce(0) { $0 + $1.spec.width }
        let room = (panelWidth - 2 * Self.margin) * Self.fill(base.count) - gaps
        guard bodies > 0, room > bodies else { return base }
        let scale = room / bodies
        return base.map { placed in
            var spec = placed.spec
            // Down rather than nearest: a rounding that lands a point over the
            // panel gives a train that fills it a scroll bar to nowhere.
            spec.width = (spec.width * scale).rounded(.down)
            return Placed(
                coach: placed.coach, spec: spec, gap: placed.gap, blocked: placed.blocked
            )
        }
    }

    /// How much of the panel a train of `count` vehicles may be stretched to
    /// fill: a third of it each, and never more than all of it.
    private static func fill(_ count: Int) -> CGFloat {
        min(1, CGFloat(count) / 3)
    }

    private var train: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(layout.enumerated()), id: \.element.coach.position) { _, placed in
                if placed.gap > 0 { gangway(width: placed.gap, blocked: placed.blocked) }
                VStack(spacing: 3) {
                    WagonView(
                        spec: placed.spec,
                        height: Self.wagonHeight,
                        isSelected: opened == placed.coach.position
                    )
                    caption(placed)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(placed.coach))
                .accessibilityAddTraits(.isButton)
                .onTapGesture {
                    opened = opened == placed.coach.position ? nil : placed.coach.position
                }
            }
        }
    }

    /// What is written under one vehicle: the number painted on its side, and
    /// the pictograms for what is on board.
    ///
    /// Under rather than inside, now that the box holds only the class. The
    /// number is what a seat reservation names, and the pictograms are what
    /// decide which coach you walk to.
    private func caption(_ placed: Placed) -> some View {
        HStack(spacing: 3) {
            if isNumbered {
                Text(placed.coach.number.map(String.init) ?? " ")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(
                        opened == placed.coach.position
                            ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                    )
            }
            ForEach(placed.coach.wagonGlyphs.prefix(3), id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: placed.spec.width, height: 13)
    }

    /// Whether any coach carries a number, and so whether the strip under the
    /// drawing that holds them is worth its height at all. A regional unit is
    /// not numbered for reservation, and an empty line under every coach is a
    /// row of nothing.
    private var isNumbered: Bool { shown.coaches.contains { $0.number != nil } }


    /// The space between two vehicles — nothing at all, unless it cannot be
    /// walked through, in which case it is worth saying so.
    private func gangway(width: CGFloat, blocked: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if blocked {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.secondary)
                    .position(x: width / 2, y: Self.wagonHeight * 0.44)
            }
        }
        .frame(width: width, height: Self.wagonHeight)
        .accessibilityHidden(!blocked)
        .accessibilityLabel("no way through")
    }

    // MARK: - The platform

    /// Which of the vehicle's own calls this stop is.
    ///
    /// Matched by name, which is the only thing the two halves share: the
    /// formation service numbers its stops by DIDOK and the snapshot's calls
    /// carry a SLOID, and the panel already joins them this way in
    /// `formationStop`.
    private var vehicleStopIndex: Int? {
        stops.firstIndex {
            $0.name.compare(shown.stopName, options: .caseInsensitive) == .orderedSame
        }
    }

    /// How long the train is, in metres.
    ///
    /// The service's own figure where it gives one. Where it does not — which
    /// is every train whose combined request was refused, see `FormationService`
    /// — it is recovered from the drawing instead: `WagonSpec.width` is real
    /// metres times `Wagon.pointsPerMetre` wherever the rolling-stock register
    /// knew the vehicle, so dividing it back out returns what went in. The
    /// natural layout is used and not `layout`, because `layout` stretches a
    /// short train to fill the card and a stretched train is not 180 m long.
    private var trainMetres: Double {
        if let length = formation.totalLength, length > 0 { return length }
        let real = naturalLayout.filter { $0.coach.kind != .fictitious }
        guard !real.isEmpty else { return 0 }
        let bodies = real.reduce(0.0) { $0 + Double($1.spec.width) / Double(Wagon.pointsPerMetre) }
        return bodies + Double(real.count - 1) * VehicleLayout.couplerGap
    }

    private var stripSpan: StripSpan? {
        guard let strip, let index = vehicleStopIndex, trainMetres > 0 else { return nil }
        return PlatformPlacement.place(
            stops: stops, geometry: geometry, at: index, length: trainMetres, on: strip
        )
    }

    // MARK: - The platform drawing

    static let trainAnchor = "formation.train"
    private static let sectorHeight: CGFloat = 14
    private static let markerSize: CGFloat = 13
    /// Two rows for the ways off, because Zürich's platform 10 has a staircase,
    /// a lift and an escalator inside five percent of its length and one row
    /// drew them on top of each other. Stacking is vertical only: moving a
    /// marker sideways would move it away from where it is, which is the one
    /// thing this drawing may not do.
    private static let markerRowCount = 2

    /// Points per metre, for everything drawn against the platform.
    ///
    /// Taken from the train rather than chosen, so the two cannot disagree: the
    /// train is drawn at whatever width reads well — stretched, where it is
    /// short — and the platform is then drawn at *that* scale. A 470 m platform
    /// under a 256 m train is therefore 1.8 times the train's width, which is
    /// the whole point and is why this scrolls.
    private var scale: CGFloat {
        guard trainMetres > 0, drawnTrainWidth > 0 else { return 0 }
        return drawnTrainWidth / CGFloat(trainMetres)
    }

    private var drawnTrainWidth: CGFloat {
        layout.reduce(0) { $0 + $1.gap + $1.spec.width }
    }

    /// The platform's true length in points, or nothing where no platform is
    /// mapped — most bus stops, and any station OpenStreetMap has not drawn.
    private var platformWidth: CGFloat {
        guard let strip, scale > 0, strip.length > 0 else { return 0 }
        return CGFloat(strip.length) * scale
    }

    /// A nominal vehicle length, for the padding — which says how *many*
    /// coach-lengths of platform lie beyond the train and never how long they
    /// are. The train's own average is the closest thing to an answer.
    private var nominalCoachWidth: CGFloat {
        guard !layout.isEmpty else { return 0 }
        return layout.reduce(0) { $0 + $1.spec.width } / CGFloat(layout.count)
    }

    private struct SectorRun {
        var sector: String?
        var width: CGFloat
        /// Whether the train actually stands in this stretch.
        var occupied: Bool
    }

    /// Every sector the platform has, not merely the ones the train reaches.
    ///
    /// Walked over the formation *as filed*, padding included: `@D,F,F,F@C,F`
    /// is three coach-lengths of D and one of C, and the `F`s are the platform
    /// the train does not cover. Runs the train stands in take the tint; the
    /// rest are lettered and left plain, which is what somebody walking to
    /// sector A needs to see.
    private var platformSectors: [SectorRun] {
        let filed = shown.padded
        guard !filed.isEmpty else { return [] }
        var out: [SectorRun] = []
        var index = 0
        for coach in filed {
            let width: CGFloat
            let occupied: Bool
            if coach.kind == .fictitious {
                width = nominalCoachWidth
                occupied = false
            } else {
                width = index < layout.count
                    ? layout[index].spec.width + layout[index].gap
                    : nominalCoachWidth
                index += 1
                occupied = true
            }
            if let last = out.last, last.sector == coach.sector {
                out[out.count - 1].width += width
                out[out.count - 1].occupied = last.occupied || occupied
            } else {
                out.append(SectorRun(sector: coach.sector, width: width, occupied: occupied))
            }
        }
        return out
    }

    /// Lettered platform lying ahead of the train.
    private var paddingBeforeTrain: CGFloat {
        var width: CGFloat = 0
        for coach in shown.padded {
            guard coach.kind == .fictitious else { break }
            width += nominalCoachWidth
        }
        return width
    }

    /// Where the train's nose sits, in points from the left end of the drawing.
    ///
    /// From the platform where the train could be placed on one, so a train two
    /// thirds of the way along a platform is drawn two thirds of the way along
    /// it. Otherwise from the padding alone, which at least says how much
    /// platform is in front of it.
    private var trainOffset: CGFloat {
        guard scale > 0 else { return 0 }
        if let strip, let span = stripSpan, strip.length > 0 {
            return max(0, CGFloat(span.lower * strip.length) * scale)
        }
        return paddingBeforeTrain
    }

    /// Where the lettered stretch begins, which is not where the platform does:
    /// the sectors are anchored to the train and run outwards from it.
    private var sectorOffset: CGFloat {
        max(0, trainOffset - paddingBeforeTrain)
    }

    private var contentWidth: CGFloat {
        let lettered = sectorOffset + platformSectors.reduce(0) { $0 + $1.width }
        return max(max(platformWidth, lettered), trainOffset + drawnTrainWidth)
    }

    @ViewBuilder private var platformBand: some View {
        if scale > 0, !platformSectors.isEmpty || platformWidth > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    sectorRow
                    ForEach(Array(markerRows.enumerated()), id: \.offset) { _, placed in
                        marker(placed.point, at: placed.x, row: placed.row)
                    }
                }
                .frame(
                    width: contentWidth,
                    height: Self.sectorHeight + markerBandHeight,
                    alignment: .topLeading
                )

                if let strip, strip.length > 0 {
                    Text("\(Int(strip.length.rounded())) m platform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, sectorOffset)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenPlatform)
        }
    }

    /// The platform in words, for anyone not looking at it.
    ///
    /// The one thing a screen reader cannot take from this drawing is the
    /// drawing, so this is the drawing: how long the platform is, which sectors
    /// the train reaches, and what is where along it. Distances are metres from
    /// the near end, because that is the unit the platform is signed in.
    private var spokenPlatform: String {
        var parts: [String] = []
        if let strip, strip.length > 0 {
            parts.append("Platform \(Int(strip.length.rounded())) metres")
        }
        let standing = platformSectors.filter(\.occupied).compactMap(\.sector)
        if !standing.isEmpty {
            parts.append("train in \(standing.count == 1 ? "sector" : "sectors") \(standing.joined(separator: ", "))")
        }
        let empty = platformSectors.filter { !$0.occupied }.compactMap(\.sector)
        if !empty.isEmpty { parts.append("also \(empty.joined(separator: ", "))") }
        if let strip {
            for point in strip.access.sorted(by: { $0.fraction < $1.fraction }) {
                let at = Int((point.fraction * strip.length).rounded())
                parts.append("\(PlatformStripView.name(point.kind)) at \(at) metres")
            }
        }
        return parts.joined(separator: ", ")
    }

    private var markerBandHeight: CGFloat {
        CGFloat(Self.markerRowCount) * Self.markerSize
    }

    /// Platform ahead of the lettered stretch, and behind it.
    ///
    /// A platform is longer than the part anybody has lettered, and the rest is
    /// still platform you can stand on — so it is drawn as the same line with
    /// no letter on it.
    private var leadingPlain: CGFloat { min(sectorOffset, max(platformWidth, 0)) }

    private var trailingPlain: CGFloat {
        let lettered = sectorOffset + platformSectors.reduce(0) { $0 + $1.width }
        return max(0, platformWidth - lettered)
    }

    /// The platform: one hairline, broken by the letter of each sector.
    ///
    /// A rule and a letter, which is what the drawing under the train always
    /// was — now run the length of the real platform instead of the length of
    /// the train, so the sectors the train does *not* reach are on it too.
    private var sectorRow: some View {
        HStack(spacing: 0) {
            if leadingPlain > 0 {
                rule.frame(width: leadingPlain, height: Self.sectorHeight)
            }
            ForEach(Array(platformSectors.enumerated()), id: \.offset) { _, run in
                HStack(spacing: 5) {
                    rule
                    Text(run.sector ?? "–")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(run.occupied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .fixedSize()
                    rule
                }
                .frame(width: max(run.width, 1), height: Self.sectorHeight)
                // Where one sector ends the next begins, and on a real platform
                // that boundary is painted on the ground. Without it the letters
                // float over one unbroken line and say nothing about how far a
                // sector reaches — which is the question somebody told to stand
                // in B is actually asking.
                .overlay(alignment: .leading) { tick }
                .overlay(alignment: .trailing) { tick }
            }
            if trailingPlain > 0 {
                rule.frame(width: trailingPlain, height: Self.sectorHeight)
            }
        }
    }

    /// The ways off the platform, each where it really is.
    private var markerRows: [(point: AccessPoint, x: CGFloat, row: Int)] {
        guard let strip, platformWidth > 0 else { return [] }
        var out: [(point: AccessPoint, x: CGFloat, row: Int)] = []
        var lastX = [CGFloat](repeating: -.infinity, count: Self.markerRowCount)
        for point in strip.access.sorted(by: { $0.fraction < $1.fraction }) {
            let x = CGFloat(point.fraction) * platformWidth
            var row = 0
            while row < Self.markerRowCount - 1, x - lastX[row] < Self.markerSize { row += 1 }
            lastX[row] = x
            out.append((point, x, row))
        }
        return out
    }

    /// Under the line rather than over it.
    ///
    /// The line is the platform and the train stands on the other side of it,
    /// so the ways *off* belong on the near side — and a glyph above the line
    /// sat between the train and the platform it is standing at, which read as
    /// something on the track.
    private func marker(_ point: AccessPoint, at x: CGFloat, row: Int) -> some View {
        Image(systemName: PlatformStripView.symbol(point.kind))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: Self.markerSize, height: Self.markerSize)
            .offset(
                x: x - Self.markerSize / 2,
                y: Self.sectorHeight + CGFloat(row) * Self.markerSize
            )
    }

    private var tick: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 1, height: 7)
    }

    private var rule: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Footnotes

    /// One coach, said in full. Everything but the class comes from the
    /// rolling-stock register rather than the realtime feed, so it is
    /// frequently absent — and the card simply gets shorter when it is.
    private func detail(of coach: Coach) -> some View {
        var parts: [String] = []
        if let sector = coach.sector { parts.append("sector \(sector)") }
        if let seats = coach.seatsFirst, seats > 0 { parts.append("\(seats) seats 1st") }
        if let seats = coach.seatsSecond, seats > 0 { parts.append("\(seats) seats 2nd") }
        if let beds = coach.beds, beds > 0 { parts.append("\(beds) berths") }
        if let spaces = coach.wheelchairSpaces, spaces > 0 {
            parts.append("\(spaces) wheelchair \(spaces == 1 ? "space" : "spaces")")
        }
        if coach.wheelchairToilet == true { parts.append("accessible WC") }
        if let hooks = coach.bicycleHooks, hooks > 0 { parts.append("\(hooks) bike hooks") }
        if coach.lowFloor == true { parts.append("low floor") }
        if let length = coach.length, length > 0 { parts.append("\(Int(length.rounded())) m") }
        if let type = coach.typeName, !type.isEmpty { parts.append(type) }

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coach.number.map { "Coach \($0)" } ?? coach.kind.spokenName)
                    .font(.footnote.weight(.semibold))
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                opened = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    @ViewBuilder
    private var notes: some View {
        // A train that splits is two trains, and which half you are standing in
        // decides where you end up.
        if shown.portions.count > 1 {
            ForEach(Array(shown.portions.enumerated()), id: \.offset) { _, portion in
                if let goal = name(of: portion) {
                    Label(
                        "Coaches \(portion.fromPosition)–\(portion.toPosition) to \(goal)",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        if shown.coaches.contains(where: \.isClosed) {
            Label("Dashed coaches are closed", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func spoken(_ coach: Coach) -> String {
        var parts = [coach.kind.spokenName]
        if let number = coach.number { parts.append("coach \(number)") }
        if let sector = coach.sector { parts.append("sector \(sector)") }
        if coach.isClosed { parts.append("closed") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - From a coach to a drawing

private extension WagonSpec {
    /// What one vehicle looks like.
    ///
    /// Everything but the two ends and the yellow band is read straight off the
    /// coach; which ends carry a cab, and which end the band runs along, are
    /// worked out from the train around it — see `layout` and
    /// `FormationView.stripe(of:at:)`. A locomotive is the exception, and is
    /// given cabs wherever it stands, since it has them whether or not it is
    /// leading.
    init(coach: Coach, cabFront: Bool, cabBack: Bool, stripe: Stripe) {
        let role = coach.kind.wagonRole
        let loco = role == .locomotive
        self.init(
            role: role,
            width: Wagon.width(metres: coach.length) ?? role.defaultWidth,
            cabFront: loco || cabFront,
            cabBack: loco || cabBack,
            stripe: stripe,
            plate: coach.kind.plate,
            symbol: coach.kind.symbol,
            doubleDeck: VehicleLayoutStore.isDoubleDeck(coach.typeName),
            isClosed: coach.isClosed
        )
    }
}

private extension WagonRole {
    /// What to draw a vehicle at when the register does not know its length.
    ///
    /// A locomotive is short and a coach is long, which is most of what the
    /// real number would have told us anyway.
    var defaultWidth: CGFloat {
        switch self {
        case .locomotive: return 56
        case .van: return 66
        case .coach: return 84
        }
    }
}

private extension CoachKind {
    var wagonRole: WagonRole {
        switch self {
        case .locomotive: return .locomotive
        case .luggage: return .van
        default: return .coach
        }
    }

    /// The yellow marking, where the vehicle carries one.
    ///
    /// First class throughout is a band end to end; a coach that is half of
    /// each carries it over the first-class half only. Which half that is comes
    /// from the coaches on either side rather than from here — `.leadingHalf`
    /// is the request for half a band, and `FormationView.stripe(of:at:)`
    /// decides which end it goes on.
    var stripe: WagonSpec.Stripe {
        switch self {
        case .first: return .full
        case .mixed, .diningFirst: return .leadingHalf
        default: return .none
        }
    }

    /// The class number written inside the box.
    var plate: String? {
        switch self {
        case .first, .diningFirst: return "1"
        // A family coach is a second-class coach with a play area in it, and
        // now that the balloon has moved down under the drawing with the rest
        // of the pictograms, the class is what the body has left to say. `FA`
        // is its own code in the feed rather than a `2`, so it needs saying
        // here — without it the one coach a family is looking for is the only
        // empty box on the train.
        case .second, .diningSecond, .family: return "2"
        case .mixed: return "1·2"
        case .parked: return "×"
        default: return nil
        }
    }

    /// The glyph drawn inside the body, beside the class number where there is
    /// one and instead of it where there is not.
    ///
    /// `W1` and `W2` are dining cars *with* a class — a bistro at one end of an
    /// ordinary second-class coach — and they were falling through to `nil`,
    /// which drew the restaurant on an IC as a plain `2` with nothing to say
    /// there was food on the train. The service does carry them; only the
    /// drawing did not.
    var symbol: String? {
        switch self {
        case .restaurant, .diningFirst, .diningSecond: return "fork.knife"
        case .sleeper, .couchette: return "bed.double.fill"
        // The family coach's balloon is deliberately not here. It is drawn
        // under the vehicle with the bicycles and the prams — see
        // `wagonGlyphs` — because that row is where a reader already looks to
        // find out what is on board, and a glyph inside the body and the same
        // glyph underneath are two places to check for one fact.
        case .luggage: return "suitcase.fill"
        // Not the locomotive: the pantograph on its roof already says what it
        // is, and a bolt under the pantograph is the same word twice.
        default: return nil
        }
    }

    var spokenName: String {
        switch self {
        case .first: return "First class"
        case .second: return "Second class"
        case .mixed: return "First and second class"
        case .couchette: return "Couchette car"
        case .family: return "Family coach"
        case .sleeper: return "Sleeping car"
        case .restaurant: return "Restaurant car"
        case .diningFirst: return "Dining and first class"
        case .diningSecond: return "Dining and second class"
        case .locomotive: return "Locomotive"
        case .luggage: return "Luggage van"
        case .fictitious: return "Empty platform"
        case .classless: return "Coach"
        case .parked: return "Parked coach"
        }
    }
}

private extension Coach {
    /// The pictograms written under the vehicle, in the order they earn the
    /// room. Three fit.
    ///
    /// A wheelchair space first: it is the one that decides whether the train
    /// is usable at all rather than merely more pleasant.
    var wagonGlyphs: [String] {
        var out: [String] = []
        // The balloon leads on the coach that *is* the family coach. It used
        // to be drawn inside the body, where nothing could crowd it out; down
        // here it has to earn its place among three, and on the one vehicle it
        // names it earns it first. A coach that merely carries a family zone
        // keeps it where it was — behind the two that decide whether the train
        // can be used at all.
        let familyCoach = kind == .family
        if familyCoach { out.append("balloon.2.fill") }
        if offers.contains(.wheelchairSpaces) || (wheelchairSpaces ?? 0) > 0 {
            out.append("figure.roll")
        }
        if offers.contains(.bicycleHooks) || offers.contains(.bicycleHooksReserved)
            || (bicycleHooks ?? 0) > 0 {
            out.append("bicycle")
        }
        if offers.contains(.businessZone) { out.append("briefcase.fill") }
        if offers.contains(.familyZone), !familyCoach { out.append("balloon.2.fill") }
        if offers.contains(.pramPlatform) { out.append("stroller.fill") }
        // Low floor is deliberately not here. Whole regional fleets are low
        // floor throughout, and a glyph under every coach of the train marks
        // nothing out — it is in the card a tap opens instead.
        return out
    }
}

#Preview("Formation") {
    func at(_ name: String, _ track: String, _ sectors: [String], _ short: String, _ minute: Int) -> FormationAtStop {
        var position = 0
        let coaches = FormationShortString.parse(short)
            .filter { $0.kind != .fictitious }
            .map { coach -> Coach in
                position += 1
                var copy = coach
                copy.position = position
                copy.length = coach.kind == .locomotive ? 18.5 : 26.4
                return copy
            }
        return FormationAtStop(
            stopName: name, uic: 8500000 + minute, track: track,
            arrival: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60),
            departure: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60 + 120),
            coaches: coaches, sectors: sectors, portions: []
        )
    }

    let short = "@A,[LK,-1,1@B,1:3#VR;NF,%WR:4#BHP;NF@C,12:5#BHP;NF,2:6#VR;KW;NF@D,2:7#VR;KW;NF,2):8#KW;NF]"

    return List {
        Section("Formation") {
            FormationView(
                formation: TrainFormation(
                    trainNumber: 715, operatorCode: "SBBP", runs: .runs,
                    totalLength: 201.2, totalSeats: 612, vehicleCount: 8, axleCount: 32,
                    lastUpdate: nil,
                    stops: [
                        at("Genève", "3", ["A", "B", "C"], short, 0),
                        at("Lausanne", "5", ["A", "B", "C", "D"], short, 40),
                        at("Fribourg", "2", ["B", "C", "D"], short, 80),
                        at("Bern", "9", ["C", "D"], short, 110),
                    ],
                    relationships: []
                ),
                stop: at("Lausanne", "5", ["A", "B", "C", "D"], short, 40),
                destination: "Bern"
            )
            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
        }
    }
    .preferredColorScheme(.dark)
}
