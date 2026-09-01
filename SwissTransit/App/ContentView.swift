import SwiftUI
import TransitCore
import UIKit

struct ContentView: View {
    @Bindable var model: AppModel
    /// Remembered, like everything else on the settings sheets: a map opened
    /// on Satellite and found back on Dark is the app forgetting. `@AppStorage`
    /// rather than `Settings` because this is view state and never reaches the
    /// model — the key is spelled to match the namespace all the same.
    @AppStorage("setting.basemap") private var basemap: Basemap = .dark
    @State private var showSettings = false
    @State private var showMapSettings = false
    @State private var showOffline = false
    /// Which of the sheet's heights it is standing at, so a panel opening
    /// another panel can put it back down. See `AppModel.navigations`.
    ///
    /// The standing height itself is deliberately not kept here. That is
    /// `resting`, which moves with the card the panel measures, and a `@State`
    /// holding a copy of it is always one update behind: the body handed UIKit
    /// the new set of detents while the selection still named the old height,
    /// which is "Cannot set selected sheet detent if it is not included in
    /// supported sheet detents" — logged in pairs on every measurement — and a
    /// write back through the binding to repair it. Two extra sheet updates for
    /// every change to the card, and a card that changes as a train arrives and
    /// leaves is enough of them to keep the navigation bar inside the sheet
    /// being invalidated while it is trying to lay out. Derived instead, so the
    /// selection is a member of the set by construction and the two move in the
    /// same pass.
    /// `-expandSheet 1` opens the sheet at full height, so a screenshot of a
    /// panel's lower sections is a command rather than a drag nobody can
    /// repeat. The same family as `-selectVehicle`, and for the same reason.
    @State private var stand: Stand =
        UserDefaults.standard.bool(forKey: "expandSheet") ? .large : .resting

    /// The three heights the one sheet stands at, named rather than measured.
    ///
    /// `offer` is the nearby context — see `RidePill` — and it is a detent of *this*
    /// sheet rather than a badge of its own. That is the only arrangement in
    /// which the pull that opens the offer is the sheet's own gesture: one
    /// element, three heights, and the finger free to stop between them.
    ///
    /// It is also the sheet's *floor* for as long as the ride lasts, rather
    /// than a rung it leaves behind on the way up. Every way of closing the
    /// panel — the drag, Done, Back, a tap on bare map — comes to rest here,
    /// and only a swipe down from here takes the sheet off the screen. A ride
    /// that ended when the panel closed made the app forget, between one
    /// gesture and the next, the one thing it had worked out for itself.
    private enum Stand { case offer, resting, large }

    /// Whether the loading curtain is still in the hierarchy. It outlives
    /// `model.isLoading` by the length of the fade, then unmounts — a material
    /// left mounted forever is a backdrop filter the map pays for every frame.
    @State private var curtainMounted = true
    /// Deliberately independent from `model.selection`.  Pressing Done used to
    /// clear the selection immediately, which replaced a vehicle panel with
    /// the empty panel while the custom-detent sheet was being dismissed.  That
    /// made the sheet repeatedly relayout against live map updates and could
    /// leave the main thread stuck in the presentation feedback loop.
    @State private var detailSheetPresented = false
    /// True from the moment the live-ride sheet starts moving upwards, rather
    /// than from the later moment UIKit commits its next detent.
    ///
    /// `PresentationDetent`'s selection binding is intentionally discrete: it
    /// changes after the finger lets go.  The panel is much more useful if it
    /// can spend that drag building its rows and fetching the selected service,
    /// so the sheet's own pan is observed below and this state swaps the content
    /// while the gesture is still in flight.
    @State private var offerPullingOpen = false
    @State private var offerPullSettlement: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                TransitMap(model: model, basemap: basemap)
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    header
                    Spacer()
                    // Above the time control rather than below it. The control
                    // comes and goes, and a button that slid down the screen
                    // whenever it was dismissed is a button a thumb has to look
                    // for; this way it keeps one place and the control opens
                    // underneath it.
                    mapControls
                    if model.showTimeControl {
                        TimeControl(model: model)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, bottomInset(in: proxy.size.height))
                .animation(.snappy(duration: 0.25), value: model.selection == .none)
                .animation(.snappy(duration: 0.3), value: model.rides.offeringID)

                // Kept in the hierarchy for the length of its own fade rather
                // than removed the instant `isLoading` flips. A `.transition`
                // could not do this: the backdrop is a `Material`, and SwiftUI
                // takes a material in or out whole — there is no ramp to
                // animate, so the blur vanished in one frame. Fading the view
                // *while it is still mounted* is what makes the map sharpen
                // gradually, because the blur thins as the material thins.
                if curtainMounted {
                    LoadingCurtain(boot: model.boot)
                        .opacity(model.isLoading ? 1 : 0)
                        .allowsHitTesting(model.isLoading)
                        .animation(.easeInOut(duration: 0.7), value: model.isLoading)
                        .onChange(of: model.isLoading) { _, loading in
                            guard !loading else { return }
                            Task {
                                try? await Task.sleep(for: .milliseconds(750))
                                curtainMounted = false
                            }
                        }
                }

                if model.showDiagnostics {
                    VStack {
                        Spacer()
                        FrameReadout(model: model)
                            .padding(.horizontal, 12)
                            // Clear of the Mapbox logo and the attribution,
                            // which are not ours to cover.
                            .padding(.bottom, 34)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            // `-openSheet offline` / `-openSheet settings` opens straight into a
            // sheet, so a screenshot of one is a command rather than a sequence
            // of taps nobody can repeat.
            switch UserDefaults.standard.string(forKey: "openSheet") {
            case "offline": showOffline = true
            case "settings": showSettings = true
            case "map": showMapSettings = true
            default: break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
        // Short, so most of the map is still on screen while the slider under
        // your thumb is changing it.
        .sheet(isPresented: $showMapSettings) {
            MapSettingsSheet(model: model, basemap: $basemap)
                .presentationDetents([.height(470)])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
        }
        .sheet(isPresented: $showOffline) {
            OfflineSheet(model: model)
        }
        .onChange(of: model.selection != .none) { _, hasSelection in
            // Map taps open the sheet.  Dismissal, including Done, clears the
            // selection from `onDismiss` so its contents remain stable for the
            // entire UIKit transition.
            if hasSelection {
                // A tap on the map while the offer is standing takes the sheet
                // up to the panel. The two cannot both have the bottom of the
                // screen, and the tap is the newer answer — but the offer is
                // not *refused*, so it comes back if Done closes the panel.
                if stand == .offer, !offerPullingOpen { stand = .resting }
                detailSheetPresented = true
            } else if detailSheetPresented, stand != .offer {
                // Keep programmatic clears behaving like a normal dismissal —
                // unless the sheet has come down to the offer's own height, in
                // which case clearing the selection is what *put* it there and
                // dismissing would undo the landing.
                detailSheetPresented = false
            }
        }
        // A tap on bare map closes the panel, and it closes it the same way
        // Done does: dismiss first, clear the selection from `onDismiss`. The
        // model asks rather than clearing the selection itself, because
        // clearing it is what wedged the main thread. See `requestDismiss`.
        .onChange(of: model.dismissRequests) { _, _ in
            if detailSheetPresented { closeSheet() }
        }
        // A new offer opens the sheet at its smallest height. Nothing else
        // moves: if a panel is already up, the offer waits for it to close.
        .onChange(of: model.rides.offeringID) { _, _ in presentOffer() }
        .onChange(of: otherSheetUp) { _, _ in presentOffer() }
        .onChange(of: mapCovered) { _, covered in model.mapObscured = covered }
        // The fit can be withdrawn from under a standing bar — a tunnel long
        // enough, a train that turns out to be the one on the next track. The
        // sheet is showing the bar and the bar has lost its subject, so it goes
        // rather than standing there empty. A panel open over it is untouched:
        // whatever is in it was asked for by name.
        .onChange(of: offerStanding) { _, standing in
            guard !standing, stand == .offer else { return }
            detailSheetPresented = false
        }
        .sheet(isPresented: $detailSheetPresented, onDismiss: {
            offerPullSettlement?.cancel()
            offerPullSettlement = nil
            offerPullingOpen = false
            // Off the bottom from the bar's own height, which is the one
            // gesture that retires a ride: not my train, or I know, stop
            // telling me. Every *other* way out of the sheet lands on the bar
            // instead — see `closeSheet` and the detent watcher below — so this
            // is reached only by a deliberate swipe down on the bar itself.
            if stand == .offer { model.rides.dismiss() }
            model.selection = .none
            // A sheet always opens at its resting height. `stand` is the
            // sheet's own state and nothing was clearing it, so pulling one
            // panel up to full height and pressing Done left it set — and the
            // *next* vehicle tapped opened over the whole map, which is the one
            // thing a map sheet must never do.
            stand = .resting
            // Anything else that took the sheet off the screen while a ride
            // was still live — a hard flick from full height, a panel opened
            // over the bar and then closed — gives the bar the bottom of the
            // screen back. Refusing it above is what stops this: `offering` is
            // nil by the time it is read.
            if model.rides.offering != nil {
                stand = .offer
                detailSheetPresented = true
            }
        }) {
            sheetBody
                // UIKit only writes the selected detent after the pull ends.
                // Listen to that same native pan without adding a competing
                // gesture, so the real panel can render under the finger.
                .background {
                    SheetPullObserver(
                        active: stand == .offer && offerStanding,
                        pulledUp: beginOfferPull,
                        ended: finishOfferPull
                    )
                }
                .presentationDetents(detents, selection: standing)
                .presentationBackgroundInteraction(.enabled(upThrough: resting))
                .presentationDragIndicator(.visible)
                // Following a link puts the sheet back down, and so does Back.
                //
                // Nothing needs to watch `panelFold` any more: the standing
                // detent *is* `resting`, so a panel reporting a new height moves
                // the sheet and the selection together rather than leaving the
                // second to catch up with the first.
                .onChange(of: model.navigations) { _, _ in stand = .resting }
                // Leaving the offer's height by any means — a drag, a flick, a
                // tap on the row — is "yes, that is my train". The panel it
                // grows into is the one a tap on the train would have opened,
                // and the camera goes to find it. See `AppModel.openOffer`.
                // And coming back down to it is the other direction of the
                // same gesture: the sheet has returned to its floor, so the
                // panel it was showing is over. Clearing the selection here
                // rather than dismissing the sheet is what makes a collapse
                // land on the bar instead of on bare map.
                .onChange(of: stand) { was, now in
                    if now != .offer {
                        offerPullSettlement?.cancel()
                        offerPullSettlement = nil
                        offerPullingOpen = false
                    }
                    if now == .offer, model.selection != .none { model.selection = .none }
                    guard was == .offer, now != .offer, model.selection == .none else { return }
                    model.openOffer()
                }
        }
    }

    /// The offer, or whatever the last tap selected.
    ///
    /// One sheet, two contents. A tap swaps them when the detent changes; a pull
    /// swaps them as soon as the native sheet gesture has moved far enough to
    /// be unambiguous, so the panel lays itself out during the expansion rather
    /// than appearing only after the finger lets go.
    @ViewBuilder private var sheetBody: some View {
        // No `selection == .none` here. The selection is cleared *by* arriving
        // at this height rather than before it, and requiring it first meant
        // the frame in which the sheet reached its floor still had the panel in
        // it — a full-height list crammed into a hundred points, for one frame,
        // every time somebody pushed the sheet down.
        if stand == .offer, !offerPullingOpen, let offer = model.rides.offering {
            RidePill(
                offer: offer,
                open: { withAnimation(.snappy(duration: 0.3)) { stand = .resting } },
                dismiss: { detailSheetPresented = false }
            )
        } else {
            DetailSheet(model: model) { closeSheet() }
        }
    }

    /// Whether there is a live ride for the sheet to stand on.
    ///
    /// Not "an offer nobody has answered yet": taking the offer no longer
    /// retires it, so this stays true underneath the panel it opened and the
    /// bar's height stays in the sheet's set the whole time. That is what makes
    /// a downward drag land on the bar — a detent the sheet already has — and
    /// what makes the *next* downward drag, from the bar, a dismissal.
    private var offerStanding: Bool { model.rides.offering != nil }

    /// Whether there is an offer standing with nothing on top of it, which is
    /// the only state the sheet may put itself up in.
    private var offerAvailable: Bool {
        model.selection == .none && offerStanding
    }

    /// Settings, the map controls and the download panel are nothing to do with
    /// the offer, but they are sheets, and one view presents one sheet at a
    /// time. An offer that arrived under an open Settings used to be swallowed
    /// — the flag was set, nothing appeared, and it never asked again.
    private var otherSheetUp: Bool { showSettings || showMapSettings || showOffline }

    /// The sheets that take the whole screen, as opposed to the one that does
    /// not. The map settings sheet is 470 points precisely so the map stays
    /// visible while a slider is changing it — slowing *that* map down would be
    /// slowing down the one thing the sheet exists to let you watch. The other
    /// two cover it, as does the detail sheet at its large detent, and a covered
    /// map does not need thirty frames a second.
    /// See `AppModel.mapObscured`.
    private var mapCovered: Bool {
        showSettings || showOffline || (detailSheetPresented && stand == .large)
    }

    /// Put the offer up, if there is one and there is room for it.
    private func presentOffer() {
        guard offerAvailable, !detailSheetPresented, !otherSheetUp else { return }
        offerPullSettlement?.cancel()
        offerPullSettlement = nil
        offerPullingOpen = false
        stand = .offer
        detailSheetPresented = true
    }

    /// Start answering the pull before UIKit has chosen its destination detent.
    private func beginOfferPull() {
        guard stand == .offer, !offerPullingOpen,
              model.selection == .none, offerStanding
        else { return }
        offerPullSettlement?.cancel()
        offerPullSettlement = nil
        offerPullingOpen = true
        model.openOffer()
    }

    /// A short pull can snap back to the live bar without changing the selected
    /// detent. Give UIKit's settling animation time to decide; if it remained at
    /// `.offer`, put the offer back and undo the speculative selection.
    private func finishOfferPull() {
        guard offerPullingOpen else { return }
        offerPullSettlement?.cancel()
        offerPullSettlement = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, offerPullingOpen else { return }
            offerPullSettlement = nil
            guard stand == .offer else {
                offerPullingOpen = false
                return
            }
            offerPullingOpen = false
            if model.selection != .none { model.selection = .none }
        }
    }

    /// Close whatever the sheet is showing.
    ///
    /// Down to the bar where there is a ride to stand on, and off the screen
    /// where there is not. Done, Back's last step and a tap on bare map all
    /// come through here, so all three agree with the drag: the way out of the
    /// panel is the floor, and the way out of the *floor* is a swipe down.
    private func closeSheet() {
        guard offerStanding else {
            detailSheetPresented = false
            return
        }
        withAnimation(.snappy(duration: 0.3)) { stand = .offer }
        model.selection = .none
    }

    /// The heights this sheet is offered: two, unless there is an offer to
    /// make, in which case the offer's own height is the first of three.
    private var detents: Set<PresentationDetent> {
        offerStanding ? [Self.offerDetent, resting, .large] : [resting, .large]
    }

    /// Constant, so it is the same value in the set and in the selection, and
    /// so it never moves the sheet. See `RidePill.height`.
    private static let offerDetent = PresentationDetent.height(RidePill.height)

    /// Where the sheet is standing, in terms of the detents it is offered.
    ///
    /// Read out of `stand` rather than stored, which is what keeps it inside
    /// the set it is chosen from however the card underneath it changes size.
    private var standing: Binding<PresentationDetent> {
        Binding(
            get: {
                switch stand {
                case .large: return .large
                // Falling back to `resting` rather than trusting `stand`: the
                // offer's height leaves the set the moment the offer is taken
                // or withdrawn, and a selection naming a detent that is no
                // longer offered is the "Cannot set selected sheet detent"
                // complaint and a write back through this binding to repair it.
                case .offer: return offerStanding ? Self.offerDetent : resting
                case .resting: return resting
                }
            },
            set: { picked in
                if picked == .large { stand = .large }
                else if picked == Self.offerDetent { stand = .offer }
                else { stand = .resting }
            }
        )
    }

    /// The height the sheet opens at.
    ///
    /// A vehicle panel measures its own summary and asks for exactly that, so
    /// the whole of "next stop" is on screen and the heading under it is not —
    /// pull up and the stop list is there. Everything else keeps the fraction:
    /// a departure board has no natural fold, it is a list all the way down.
    private var resting: PresentationDetent {
        // The only thing this rejects is a card that has not reported yet. It
        // used to demand 160 points, which a *moving* vehicle's card — no "at
        // this stop" block, no platform side — comes in just under, so a bus
        // silently fell back to the fraction and showed its stop list.
        //
        // Read off the fold alone and not off the selection, which is what
        // clears the fold. The two say the same thing while the sheet is open —
        // only a vehicle panel ever reports a height — and they part company at
        // exactly the wrong moment: Done sets the selection to `.none` while
        // the sheet is still on screen standing at `.height(fold + chrome)`.
        // That took the standing detent out of the set it was chosen from, and
        // a sheet whose selection is no longer offered picks a new one and
        // writes it back through the binding, mid-dismissal. See
        // `AppModel.refreshSelection`, which clears the fold for a board and
        // leaves it alone for `.none`.
        guard model.panelFold > 40 else { return .fraction(0.42) }
        // Clamped, so a panel that measures wrong on some future layout still
        // leaves a sheet that can be grabbed and a map that can be seen.
        return .height(min(model.panelFold + Self.chrome, 620))
    }

    /// The same number as `resting`, in points, for laying out around the sheet.
    private func restingHeight(in screen: CGFloat) -> CGFloat {
        guard model.panelFold > 40 else { return screen * 0.42 }
        return min(model.panelFold + Self.chrome, 620)
    }

    /// Everything above and below the card that the card cannot measure: the
    /// navigation bar the sheet opens with, the list's own margin above the
    /// first section, and the padding a grouped row draws inside itself.
    ///
    /// A constant because none of it varies with the panel — what varies is the
    /// card, and the card reports itself.
    /// Trimmed so the space under the card reads as the same margin it has at
    /// its sides rather than as a gap the sheet forgot to close.
    private static let chrome: CGFloat = 85

    /// The row across the top, or the search field it becomes.
    ///
    /// One or the other rather than both. The header is already four controls
    /// wide on the narrowest phone this runs on, and a fifth that expands into
    /// a field has nowhere to expand *to* — so opening search takes the row,
    /// and Cancel gives it back.
    private var header: some View {
        Group {
            if model.isSearching {
                SearchBar(model: model)
            } else {
                controls
            }
        }
        .padding(.top, 4)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            StatusPill(model: model)
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy(duration: 0.22)) { model.isSearching = true }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.mapControl)
            .accessibilityLabel("Search for a stop or a service")
            Button {
                withAnimation(.snappy(duration: 0.22)) { model.showTimeControl.toggle() }
            } label: {
                Image(systemName: model.showTimeControl ? "clock.fill" : "clock")
            }
            .buttonStyle(.mapControl)
            .foregroundStyle(model.showTimeControl ? Color.accentColor : .primary)
            Button { showOffline = true } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.mapControl)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.mapControl)
        }
    }

    /// Where you are — bottom right, where every map on this phone puts it.
    ///
    /// It used to sit under the header with the three buttons that change what
    /// the map *shows*, which is the wrong company: this one changes where the
    /// map *is*, and that is the same kind of thing as a pan. Bottom right is
    /// also where a thumb already is, and it leaves the top corner to the
    /// compass, which is anchored to the same safe area and used to land
    /// underneath the status chip.
    /// How far the locate button and the time control stand off the bottom.
    ///
    /// Lifted clear of the sheet, so the control does not spend most of its
    /// life underneath one — and lifted clear of the bottom edge either way. A
    /// 48 pt target flush against the home indicator is one the thumb shares
    /// with the system's own swipe, and flush against a sheet it is one it
    /// shares with the grab handle.
    private func bottomInset(in height: CGFloat) -> CGFloat {
        let sheet: CGFloat
        // The height the sheet is *standing at* first, and only then what it is
        // holding: a selection outlives the collapse to the bar by a frame, and
        // reading it first lifted the locate button over a panel that was on
        // its way to being a hundred points tall.
        if detailSheetPresented, stand == .offer {
            // The offer is a sheet now, so it takes the bottom of the screen
            // the way one does, and the locate button lifts over it.
            sheet = RidePill.height + 10
        } else if model.selection != .none {
            sheet = restingHeight(in: height) + 10
        } else {
            sheet = 0
        }
        return sheet + 16
    }

    /// The two buttons that belong to the map itself, in one slab.
    ///
    /// They are a pair rather than two controls that happen to be near each
    /// other: what the map looks like, and where the map is. Neither is about
    /// the *timetable*, which is what the row along the top is for — and this
    /// corner is where a thumb already is. One material capsule behind both,
    /// because two floating circles in a column read as a list that has lost
    /// its other items.
    private var mapControls: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Button { showMapSettings = true } label: {
                    Image(systemName: "map")
                }
                .accessibilityLabel("Map settings: basemap and the railway overlay")

                Button { model.onLocate?() } label: {
                    Image(systemName: locateIcon)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(locateTint)
                }
                .disabled(!model.hasLocationFix)
                .accessibilityLabel(locateLabel)
            }
            .buttonStyle(MapControlStackStyle())
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Hollow, filled, and filled with a road under it.
    ///
    /// The same three the phone's own map draws, in the same order, because the
    /// thumb pressing this has pressed that one — and the third is the only one
    /// of the three that has to say something a filled arrow cannot, which is
    /// that the map is now turning rather than just following.
    private var locateIcon: String {
        switch model.locateMode {
        case .unfocused: return "location"
        case .focused: return "location.fill"
        case .bearing: return "location.north.line.fill"
        }
    }

    /// Colour carries the one distinction the shape cannot: bearing lock is the
    /// state that keeps *turning* the map under you, so it is the state that is
    /// worth noticing out of the corner of an eye.
    private var locateTint: Color {
        guard model.hasLocationFix else { return .secondary }
        return model.locateMode == .bearing ? Color.accentColor : .primary
    }

    private var locateLabel: String {
        switch model.locateMode {
        case .unfocused: return "Centre on my location"
        case .focused: return "Following your location. Turn the map to face the way you are going"
        case .bearing: return "The map is facing the way you are going. Put it back to north"
        }
    }
}

/// The one thing worth saying before anything is drawn: what is loading.
///
/// A cold launch reads 59 MB of packed data and replays a stored snapshot, and
/// a blank screen with no explanation is indistinguishable from a broken app.
/// A bar and a line of text are enough to say otherwise; anything more is
/// decoration over a wait nobody asked for.
struct LoadingCurtain: View {
    var boot: BootProgress

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 14) {
                bar
                Text(boot.stage.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .id(boot.stage)
                    .transition(.opacity)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 340)
            .animation(.easeInOut(duration: 0.25), value: boot.stage)
        }
    }

    /// A blur over the map, not a picture of its own. The map behind this has
    /// nothing on it yet — no stops, no vehicles, in most cases not even a
    /// style — so the blur is there to put the bar on a surface, nothing more.
    private var backdrop: some View {
        Rectangle()
            .fill(.thinMaterial)
            .ignoresSafeArea()
    }

    /// A track and a fill. Every number is read off `AppModel.boot`, which is
    /// the same list of steps `start()` runs — nothing is invented to keep the
    /// bar moving.
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(6, proxy.size.width * boot.fraction))
            }
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.55), value: boot.fraction)
    }
}

#Preview("Loading") {
    LoadingCurtain(boot: BootProgress(stage: .drawing))
}

struct StatusPill: View {
    @Bindable var model: AppModel

    var body: some View {
        StatusPillButton(summary: summary, statusColor: statusColor) {
            VehicleLegend(activity: FeedActivity(model: model))
        }
    }

    /// What the pill says when there is nothing to count.
    ///
    /// "no fleet" was the whole vocabulary for three different situations — a
    /// snapshot still downloading, a token the app never had, and a stop
    /// register that failed to load — and it read as the last one in every
    /// case. The download says so, and the rest is in the panel behind a tap.
    private var summary: String {
        if model.isLoading { return "loading" }
        if model.status.journeys > 0 { return "\(model.status.vehicles) Vehicles" }
        if case .failed = model.progress.phase { return "no fleet" }
        return model.progress.isRunning ? model.progress.phase.label.lowercased() : "no fleet"
    }

    /// Four states rather than three.
    ///
    /// Green used to mean "there is a fleet", which is not the same as "the
    /// fleet is live": a refresh that was refused with a 429 left an hour-old
    /// snapshot on the map under a green dot saying live data was available.
    /// Orange is that case — something to draw, but the last attempt to bring
    /// it up to date failed.
    private var statusColor: Color {
        if model.dataMode == .off { return .gray }
        if model.isRefreshing { return .yellow }
        if case .failed = model.progress.phase { return model.status.journeys > 0 ? .orange : .red }
        return model.status.journeys > 0 ? .green : .red
    }
}

/// Kept separate from the live model so the interactive chip can be previewed
/// with representative data in Xcode.
private struct StatusPillButton<Legend: View>: View {
    let summary: String
    let statusColor: Color
    @ViewBuilder var legend: () -> Legend
    @State private var showingLegend = false

    var body: some View {
        Button {
            showingLegend = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(summary)
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live data and map legend")
        .popover(isPresented: $showingLegend) {
            legend()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The live model's version of what the legend shows.
///
/// Kept here rather than beside the view, so the view and its readout stay
/// free of the model and can be rendered — and checked — outside the app. See
/// `FeedActivity`.
extension FeedActivity {
    @MainActor
    init(model: AppModel) {
        self.init(
            progress: model.progress,
            status: model.status,
            dataMode: model.dataMode,
            interval: model.dataMode.refreshInterval,
            problems: model.loaded?.problems ?? [],
            limits: model.limits
        )
    }
}

#Preview("Vehicle-count chip") {
    StatusPillButton(summary: "7919 Vehicles", statusColor: .green) { VehicleLegend() }
        .padding()
        .preferredColorScheme(.dark)
}

/// One button of the stacked pair in the corner.
///
/// A square target inside a shared capsule rather than a circle of its own:
/// the background is drawn once, around both, so the two press independently
/// while reading as one control.
struct MapControlStackStyle: ButtonStyle {
    var size: CGFloat = 52

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// A control that reads as part of the map rather than part of a form.
struct MapControlStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.44, weight: .semibold))
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == MapControlStyle {
    static var mapControl: MapControlStyle { MapControlStyle() }
}

/// Reads the sheet presentation controller's existing pan gesture.
///
/// Adding a SwiftUI `DragGesture` here would make it compete with the system
/// sheet for the same touch. This zero-impact view instead adds itself as one
/// more target of the recogniser UIKit already owns, so detent physics,
/// scrolling and dismissal remain entirely native.
private struct SheetPullObserver: UIViewRepresentable {
    var active: Bool
    var pulledUp: () -> Void
    var ended: () -> Void

    func makeUIView(context: Context) -> ObservationView {
        let view = ObservationView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ObservationView, context: Context) {
        view.active = active
        view.pulledUp = pulledUp
        view.ended = ended
        view.installWhenReady()
    }

    static func dismantleUIView(_ view: ObservationView, coordinator: ()) {
        view.removeObservations()
    }

    @MainActor
    final class ObservationView: UIView {
        var active = false {
            didSet {
                if !active {
                    openedThisPull = false
                    beganInsideSheet = false
                }
            }
        }
        var pulledUp: () -> Void = {}
        var ended: () -> Void = {}

        private var pans: [UIPanGestureRecognizer] = []
        private var openedThisPull = false
        /// Background interaction lets the map receive gestures while the
        /// compact sheet is up. Its pinch also changes the centroid of UIKit's
        /// presentation pan, so observing translation alone can mistake map
        /// zooming for a pull on the sheet and swap the compact offer for a
        /// full board at the 100-point detent. A real sheet pull begins inside
        /// this sheet and uses one finger; the map zoom does neither.
        private var beganInsideSheet = false
        private var installationQueued = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installWhenReady()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installWhenReady()
        }

        /// The presentation wrapper and its recognisers are installed after
        /// SwiftUI's representable joins the hierarchy, hence the next-run-loop
        /// pass. Repeated calls are cheap and identity-checked.
        func installWhenReady() {
            guard window != nil, !installationQueued else { return }
            installationQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                installationQueued = false
                installOnAncestors()
            }
        }

        private func installOnAncestors() {
            var ancestor: UIView? = self
            while let view = ancestor {
                for case let pan as UIPanGestureRecognizer in view.gestureRecognizers ?? [] {
                    guard !pans.contains(where: { $0 === pan }) else { continue }
                    pan.addTarget(self, action: #selector(observe(_:)))
                    pans.append(pan)
                }
                ancestor = view.superview
            }
        }

        @objc private func observe(_ pan: UIPanGestureRecognizer) {
            guard active else { return }
            switch pan.state {
            case .began:
                openedThisPull = false
                beganInsideSheet = pan.numberOfTouches == 1
                    && bounds.contains(pan.location(in: self))
            case .changed:
                let movement = pan.translation(in: window)
                guard beganInsideSheet, pan.numberOfTouches == 1,
                      !openedThisPull,
                      movement.y < -12,
                      abs(movement.y) > abs(movement.x)
                else { return }
                openedThisPull = true
                pulledUp()
            case .ended, .cancelled, .failed:
                if openedThisPull { ended() }
                openedThisPull = false
                beganInsideSheet = false
            default:
                break
            }
        }

        func removeObservations() {
            for pan in pans {
                pan.removeTarget(self, action: #selector(observe(_:)))
            }
            pans.removeAll()
            openedThisPull = false
            beganInsideSheet = false
        }
    }
}

/// What the draw loop is doing, over the map.
///
/// Debug-only in intent and not in build configuration: the numbers that matter
/// — how many polygons a frame is pushing, what the frame rate actually is on a
/// real phone rather than a simulator — are exactly the ones that cannot be
/// measured from a desk. It is off by default and costs nothing when off, since
/// `AppModel` only fills `frameStats` while it is on.
private struct FrameReadout: View {
    /// The model, not the numbers.
    ///
    /// Reading `frameStats` where the readout is *built* would make it a
    /// dependency of `ContentView`'s body — and `TransitMap` is in that body,
    /// so every quarter-second sample would run `updateUIView`, which rebuilds
    /// every source on the map. A readout that made the map redraw four times a
    /// second to report how often the map redraws. Read here instead, and only
    /// this view invalidates.
    let model: AppModel

    private var stats: AppModel.FrameStats { model.frameStats }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Two different things, and one number for both was misleading:
            // the map renders at the display's rate whatever the model is
            // doing, so "fps 17" over a map dragging perfectly smoothly was
            // reporting the model and looking like a report about the screen.
            row("fps", String(format: "%.0f", stats.renderFps))
            row(
                "ticks",
                String(format: "%.0f / %.0f", stats.ticks, stats.targetTicks),
                warn: stats.ticks < stats.targetTicks * 0.75
            )
            row("drawn", "\(stats.vehicles) veh · \(stats.shapes) shaped · \(stats.parts) poly")
            // Where the tick's milliseconds go. `ticks` says the loop is
            // behind; only this says what it is behind on. The fleet figure is
            // wall clock across an await, so a large one there is the tick
            // queued behind other work on the fleet actor rather than the
            // query being slow. See `AppModel.FrameStats.TickCost`.
            row(
                "cost",
                String(
                    format: "%.0f ms · fleet %.0f · shape %.1f · push %.0f · rest %.1f",
                    stats.cost.total, stats.cost.fleet, stats.cost.shapes,
                    stats.cost.push, stats.cost.rest
                ),
                warn: stats.targetTicks > 0 && stats.cost.total > 1000 / stats.targetTicks
            )
            row("map", "\(stats.stops) stops · \(stats.tracks) runs")
            row("zoom", String(format: "%.2f · %.2f m/pt", stats.zoom, stats.metresPerPoint))
            row("at", String(format: "%.5f, %.5f", stats.centre.lat, stats.centre.lon))
            row(
                "learned",
                "\(stats.learnedTrains) trains · \(stats.learnedLines) lines"
                    + " · \(stats.asked) asked · \(stats.askRate)/min"
            )
            // Everything the app asks the network for, not one caller of one
            // interface. The `learned` row above counts background formation
            // lookups, which is a behaviour worth watching on its own and was
            // for a long time the only network figure here — so a refresh
            // pulling thirty megabytes of fleet feed showed up as nothing at
            // all. See `NetworkMeter`.
            row(
                "net",
                "\(stats.net.callsPerMinute)/min · \(rate(stats.net.wirePerMinute))"
                    + " · \(FeedActivity.bytes(stats.net.wire)) in \(stats.net.calls)",
                warn: stats.net.callsPerMinute > 40
            )
            // Which interfaces those calls went to. The platform counts its
            // rate limits per subscription, so a total that is comfortable can
            // still be one interface being hammered — and that is the shape of
            // every 429 this app has ever seen.
            if !stats.net.byInterface.isEmpty {
                row("apis", stats.net.byInterface.map { "\($0.name) \($0.calls)" }
                    .joined(separator: " · "))
            }
            row(
                "cpu",
                String(format: "%.0f%% · %.0f MB", stats.load.cpuPercent, stats.load.memoryMB),
                warn: stats.load.cpuPercent > 140
            )
            row("thermal state", thermal, warn: stats.load.thermal != .nominal)
            if !stats.selected.isEmpty {
                row("open", stats.selected, warn: stats.selected.hasSuffix("chord"))
            }
            row("ride", stats.ride)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The live power-related facts iOS exposes to the running app. Battery
    /// charge and Low Power Mode are named so neither reads as part of the
    /// categorical thermal state.
    private var thermal: String {
        var parts = [stats.load.thermal.label]
        if stats.load.lowPower { parts.append("low-power") }
        if let battery = stats.load.batteryPercent {
            parts.append(String(format: "batt %.0f%%", battery))
        }
        return parts.joined(separator: " · ")
    }

    /// Bytes a minute, written as a rate somebody can compare to a data plan.
    private func rate(_ perMinute: Int) -> String {
        perMinute == 0 ? "idle" : "\(FeedActivity.bytes(perMinute))/min"
    }

    private func row(_ name: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 82, alignment: .leading)
            Text(value).foregroundStyle(warn ? Color.orange : .white.opacity(0.92))
        }
    }
}
