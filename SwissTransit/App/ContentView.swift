import SwiftUI
import TransitCore
import UIKit

/// A stable SwiftUI identity. The sheet observer supplies its measured height
/// through UIKit's resolver, which can be invalidated without replacing it.
private struct PanelRestingDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        // A floating landscape sheet reports the *wide* side as its maximum,
        // so 42% of that is the whole short side and the card fills the screen.
        // Size a landscape rest to a bottom bar; portrait keeps the half-sheet.
        if context.verticalSizeClass == .compact {
            return min(160, context.maxDetentValue * 0.38)
        }
        return context.maxDetentValue * 0.42
    }
}

/// Same identity in portrait and landscape; only the height moves. A `.height(100)`
/// detent swapped for `.height(84)` on rotation is a different detent, and UIKit
/// then complains it is not in the set.
private struct CompactPillDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        context.maxDetentValue < 500 ? FollowPill.landscapeHeight : RidePill.height
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var menuMotion: Animation? { reduceMotion ? nil : MenuMotion.animation }
    /// Remembered, like everything else on the settings sheets: a map opened
    /// on Satellite and found back on Standard is the app forgetting. `@AppStorage`
    /// rather than `Settings` because this is view state and never reaches the
    /// model — the key is spelled to match the namespace all the same.
    // Retired Light/Dark raw values fall back to Standard as well.
    @AppStorage("setting.basemap") private var basemap: Basemap = .standard
    @State private var showSettings = false
    @State private var showMapSettings = false
    @State private var showFleetLegend = false
    @State private var routeVehiclesHidden = false

    private var viewingRoute: Bool {
        if case .line = model.selection { return true }
        return false
    }
    /// `-openSheet offline` pushes the Offline page once Settings is up.
    @State private var openSettingsOffline = false
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

    /// The heights the one sheet stands at, named rather than measured.
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
    ///
    /// `immersive` is the other compact height, and only the fullscreen control
    /// puts the sheet there. Swiping the expanded vehicle card down must not
    /// land on it — that swipe just closes the card — so the detent is in the
    /// set only while the sheet is already standing on it. Pulling *up* from
    /// there is the vehicle panel again, still following; pulling *down* is
    /// letting go of the train. See `FollowPill`.
    private enum Stand { case offer, immersive, resting, large }

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
    /// The binding goes false before UIKit finishes. Keep that interval explicit
    /// so a new selection waits for the old presentation's completion callback.
    @State private var detailDismissalRevision: UInt64?
    @State private var dismissingOfferID: String?
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
    /// The compact follow height has to be in the sheet's set *before* it is
    /// selected. Adding a detent and naming it in the same update is the
    /// "Cannot set selected sheet detent" complaint, and UIKit then keeps the
    /// card at its resting height with the pill's contents floating in the
    /// middle of it. Offered first, selected on the next turn.
    @State private var immersiveDetentOffered = false

    /// Window size, so a rotation is visible even if the size class has not
    /// caught up. Used to keep a board on screen while the sheet is swapped
    /// for the full-screen view.
    @State private var viewport: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                // Do not create the Mapbox view while the packed data is still
                // loading. `makeUIView` runs on the main thread and, on a
                // Debug iPhone, that first layout was 36 s in front of
                // `start()` — the curtain said "Reading" while Mapbox started
                // and the timetable had not been opened yet.
                if !model.isLoading {
                    TransitMap(model: model, basemap: basemap, showsUserLocation: !hidesMapChrome,
                               showsVehicles: !viewingRoute || !routeVehiclesHidden,
                               showsCompass: !hidesMapChrome)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                if !hidesMapChrome {
                    VStack(spacing: 8) {
                        MapSearchHeader(
                            model: model,
                            showingLegend: fleetLegendPresentation(inDetail: false),
                            openLegend: { showFleetLegend = true },
                            openSettings: { showSettings = true }
                        )
                        Spacer()
                        // Separate glass regions keep a search transition from
                        // recompositing a container spanning the entire map.
                        LiquidGlassContainer {
                            VStack(spacing: 8) {
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
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, bottomInset(in: proxy.size.height))
                    .animation(menuMotion, value: model.selection == .none)
                    .animation(menuMotion, value: model.rides.offeringID)
                    .transition(.opacity)
                }

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

                if model.showDiagnostics, !landscapeBoardMenu {
                    VStack {
                        Spacer()
                        FrameReadout(model: model)
                            .padding(.horizontal, 12)
                            // Clear of the Mapbox logo and the attribution,
                            // which are not ours to cover. Full screen follow
                            // puts the pill on that same edge, so lift over it
                            // rather than hiding the readout with the chrome.
                            .padding(.bottom, chromeHidden ? pillHeight + 16 : 34)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if landscapeBoardMenu {
                    // Full-screen view, not a sheet. A landscape sheet on
                    // iPhone is a page card, so the board is just a layer.
                    DetailSheet(model: model, expanded: true, dismiss: closeSheet,
                                background: .menuSurface)
                        .ignoresSafeArea()
                }
            }
            .animation(menuMotion, value: hidesMapChrome)
            .onAppear { viewport = proxy.size }
            .onChange(of: proxy.size) { _, size in
                viewport = size
                if phoneIsLandscape { applyLandscapeStand() }
            }
        }
        .onChange(of: chromeHidden) { _, hidden in
            model.prefersHighFrameRate = hidden
        }
        .onAppear {
            // `-openSheet offline` / `-openSheet settings` opens straight into a
            // sheet, so a screenshot of one is a command rather than a sequence
            // of taps nobody can repeat.
            switch UserDefaults.standard.string(forKey: "openSheet") {
            case "offline":
                openSettingsOffline = true
                showSettings = true
            case "settings": showSettings = true
            case "map": showMapSettings = true
            default: break
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { openSettingsOffline = false }) {
            SettingsSheet(model: model, basemap: basemap, openOffline: openSettingsOffline)
                .keepBottomSheet()
        }
        // Short, so most of the map is still on screen while the slider under
        // your thumb is changing it.
        .sheet(isPresented: $showMapSettings) {
            MapSettingsSheet(model: model, basemap: $basemap)
                .presentationDetents([.height(470)])
                .keepBottomSheet()
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
        }
        .onChange(of: model.selectionRevision) { _, _ in
            reconcileDetailPresentation()
        }
        // Full screen follow is a vehicle card. A tap that opens a station or
        // a line instead has to give that panel its height back, or the new
        // contents are a list stuffed into a hundred points.
        .onChange(of: model.selection) { old, selection in
            if !viewingRoute, routeVehiclesHidden {
                routeVehiclesHidden = false
                model.onSetVehiclesVisible?(true)
            }
            guard detailDismissalRevision == nil else { return }
            if stand == .immersive {
                if case .vehicle = selection { return }
                withAnimation(menuMotion) { stand = .resting }
                return
            }
            // A live board rewrite is the same panel, not a rotation. Only a
            // change of *kind* — station to train, or the other way — should
            // move the landscape sheet between full screen and the resting card.
            guard compactHeightClass, Self.isBoard(old) != Self.isBoard(selection) else { return }
            applyLandscapeStand()
        }
        // Compact-height (iPhone landscape) otherwise promotes every sheet to
        // a full-screen cover. Re-assert the height we actually want once the
        // size class flips: the follow/ride pill stays a pill, a vehicle card
        // stays the resting overview, a station board may fill the screen.
        .onChange(of: verticalSizeClass) { _, _ in
            applyLandscapeStand()
        }
        // A tap on bare map closes the panel, and it closes it the same way
        // Done does: dismiss first, clear the selection from `onDismiss`. The
        // model asks rather than clearing the selection itself, because
        // clearing it is what wedged the main thread. See `requestDismiss`.
        .onChange(of: model.dismissRequests) { _, _ in
            // A tap on bare map is how the expanded card closes. Full screen
            // follow has already put that card away: the map is what is being
            // watched, so a miss must not steal the train. The pill's own
            // swipe is the way out.
            if stand == .immersive { return }
            if detailSheetPresented { closeSheet() }
        }
        // A new offer opens the sheet at its smallest height. Nothing else
        // moves: if a panel is already up, the offer waits for it to close.
        .onChange(of: model.rides.offeringID) { _, _ in presentOffer() }
        .onChange(of: otherSheetUp) { _, _ in reconcileDetailPresentation() }
        .onChange(of: mapCovered) { _, covered in model.mapObscured = covered }
        // The fit can be withdrawn from under a standing bar — a tunnel long
        // enough, a train that turns out to be the one on the next track. The
        // sheet is showing the bar and the bar has lost its subject, so it goes
        // rather than standing there empty. A panel open over it is untouched:
        // whatever is in it was asked for by name.
        .onChange(of: offerStanding) { _, standing in
            guard !standing, stand == .offer else { return }
            dismissDetailSheet()
        }
        .sheet(isPresented: detailPresentation, onDismiss: detailDidDismiss) {
            sheetBody
                .popover(isPresented: fleetLegendPresentation(inDetail: true)) {
                    fleetLegend
                        .presentationCompactAdaptation(.popover)
                }
                // UIKit only writes the selected detent after the pull ends.
                // Listen to that same native pan without adding a competing
                // gesture, so the real panel can render under the finger.
                .background {
                    SheetPullObserver(
                        active: (stand == .offer && offerStanding) || stand == .immersive,
                        restingHeight: measuredRestingHeight,
                        capsule: compactPillStanding,
                        pillHeight: pillHeight,
                        pulledUp: beginOfferPull,
                        ended: finishOfferPull,
                        interactionBegan: model.beginPanelInteraction,
                        interactionEnded: model.endPanelInteraction,
                        transitionBegan: model.beginPanelTransition,
                        transitionEnded: model.endPanelTransition
                    )
                }
                .onAppear { model.settlePanelPresentation() }
                .onDisappear { model.endPanelInteraction() }
                .presentationDetents(detents, selection: standing)
                .presentationCornerRadius(
                    compactPillStanding ? pillHeight : SheetPullObserver.cardCornerRadius
                )
                .keepBottomSheet()
                // Do not set `presentationBackground`. On iOS 26 that opts the
                // sheet out of Liquid Glass and paints a flat material, which
                // is the opaque card that hid the map. The system glass is the
                // blur; lists hide their own opaque fill so it can show through.
                .presentationBackgroundInteraction(.enabled(upThrough: resting))
                .presentationDragIndicator(.visible)
                // Following a link puts the sheet back down, and so does Back.
                //
                // Nothing needs to watch `panelFold` any more: the standing
                // detent *is* `resting`, so a panel reporting a new height moves
                // the sheet and the selection together rather than leaving the
                // second to catch up with the first.
                .onChange(of: model.navigations) { _, _ in
                    guard detailDismissalRevision == nil else { return }
                    stand = compactHeightClass && isBoardSelection ? .large : .resting
                }
                // Leaving the offer's height by any means — a drag, a flick, a
                // tap on the row — is "yes, that is my train". The panel it
                // grows into is the one a tap on the train would have opened,
                // and the camera goes to find it. See `AppModel.openOffer`.
                // And coming back down to it is the other direction of the
                // same gesture: the sheet has returned to its floor, so the
                // panel it was showing is over. Clearing the selection here
                // rather than dismissing the sheet is what makes a collapse
                // land on the bar instead of on bare map.
                //
                // Leaving the follow bar is the other compact height's version
                // of the same pull, with the opposite contract: the vehicle
                // stays selected, because the camera is still following it.
                .onChange(of: stand) { was, now in
                    guard detailDismissalRevision == nil else { return }
                    model.settlePanelPresentation()
                    if now != .offer {
                        offerPullSettlement?.cancel()
                        offerPullSettlement = nil
                        offerPullingOpen = false
                    }
                    if now != .immersive { immersiveDetentOffered = false }
                    model.followLockLow = now == .immersive
                    if now == .offer, model.selection != .none { model.selection = .none }
                    guard was == .offer, now != .offer, model.selection == .none else { return }
                    model.openOffer()
                }
        }
    }

    /// The offer, the follow bar, or whatever the last tap selected.
    ///
    /// One sheet, three contents. A tap swaps them when the detent changes; a pull
    /// swaps them as soon as the native sheet gesture has moved far enough to
    /// be unambiguous, so the panel lays itself out during the expansion rather
    /// than appearing only after the finger lets go.
    @ViewBuilder private var sheetBody: some View {
        // No `selection == .none` here. The selection is cleared *by* arriving
        // at this height rather than before it, and requiring it first meant
        // the frame in which the sheet reached its floor still had the panel in
        // it — a full-height list crammed into a hundred points, for one frame,
        // every time somebody pushed the sheet down.
        if landscapeBoardMenu {
            Color.clear
        } else if stand == .offer, !offerPullingOpen, let offer = model.rides.offering {
            RidePill(
                offer: offer,
                open: { withAnimation(menuMotion) { stand = .resting } },
                dismiss: dismissDetailSheet
            )
        } else if stand == .immersive, !offerPullingOpen,
                  let vehicle = model.departingVehicle ?? model.selectedVehicle {
            FollowPill(
                vehicle: vehicle,
                now: model.clock.nowSeconds(),
                expand: { withAnimation(menuMotion) { stand = .resting } },
                dismiss: dismissDetailSheet
            )
        } else if model.selection != .none {
            DetailSheet(model: model, expanded: stand == .large) { closeSheet() }
        } else {
            Color.clear
        }
    }

    /// iPhone landscape. Sheets otherwise become full-screen covers.
    private var compactHeightClass: Bool { verticalSizeClass == .compact }

    /// iPhone on its side. Size class can lag a frame behind rotation, so the
    /// window size is enough — a short wide viewport is a phone in landscape,
    /// not an iPad.
    private var phoneIsLandscape: Bool {
        compactHeightClass
            || (viewport.height > 0 && viewport.height < 500 && viewport.width > viewport.height)
    }

    /// A station or platform board, which is allowed to fill the landscape sheet.
    private var isBoardSelection: Bool { Self.isBoard(model.selection) }

    /// Landscape station board: a fullscreen view rather than a sheet.
    private var landscapeBoardMenu: Bool {
        phoneIsLandscape
            && isBoardSelection
            && model.selection != .none
            && stand != .offer
            && stand != .immersive
    }

    private static func isBoard(_ selection: Selection) -> Bool {
        switch selection {
        case .station, .platform: return true
        default: return false
        }
    }

    /// Compact-height rotation otherwise fills the screen. Keep pills and
    /// vehicle cards at their compact heights; a board may stand at `.large`.
    private func applyLandscapeStand() {
        guard phoneIsLandscape, detailDismissalRevision == nil else { return }
        if stand == .offer || stand == .immersive { return }
        if isBoardSelection {
            stand = .large
        } else if stand == .large {
            stand = .resting
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

    /// Settings and the map controls are nothing to do with the offer, but they
    /// are sheets, and one view presents one sheet at a time. An offer that
    /// arrived under an open Settings used to be swallowed — the flag was set,
    /// nothing appeared, and it never asked again.
    private var otherSheetUp: Bool { showSettings || showMapSettings || showFleetLegend }

    /// Present above the active card. A popover owned by the background map
    /// can otherwise replace that card or fail during its transition.
    private func fleetLegendPresentation(inDetail: Bool) -> Binding<Bool> {
        Binding(
            get: { showFleetLegend && detailSheetPresented == inDetail },
            set: { showFleetLegend = $0 }
        )
    }

    private var fleetLegend: some View {
        VehicleLegend(activity: FeedActivity(model: model), hiddenModes: model.hiddenModes,
                      onToggleMode: { model.toggleHidden($0) })
    }

    /// The sheets that take the whole screen, as opposed to the one that does
    /// not. The map settings sheet is 470 points precisely so the map stays
    /// visible while a slider is changing it — slowing *that* map down would be
    /// slowing down the one thing the sheet exists to let you watch. The other
    /// two cover it, as does the detail sheet at its large detent, and a covered
    /// map does not need thirty frames a second.
    /// See `AppModel.mapObscured`.
    private var mapCovered: Bool {
        showSettings || landscapeBoardMenu || (detailSheetPresented && stand == .large)
    }

    /// The sheet, and only when the panel is actually in one.
    ///
    /// A landscape board is a layer over the map instead, so no sheet is
    /// presented behind it — which is the whole of what used to go wrong with
    /// one that was presented and hidden. UIKit dims what a sheet covers with
    /// a view of its own, outside the presentation and so out of reach of
    /// anything that hides it; a sheet nobody presented has nothing to dim,
    /// nothing to re-place under a scrolling list, and no card to pull.
    private var detailPresentation: Binding<Bool> {
        Binding(
            get: { detailSheetPresented && !landscapeBoardMenu },
            set: { presented in
                // Rotating a board into the full-screen view takes the sheet
                // away. That is a swap, not Done.
                if !presented, !landscapeBoardMenu, !keepingBoardThroughRotation {
                    dismissDetailSheet()
                }
            }
        )
    }

    /// Device has already turned, even if the sheet dismissed before SwiftUI
    /// published the compact size class.
    private var keepingBoardThroughRotation: Bool {
        isBoardSelection && (phoneIsLandscape || UIDevice.current.orientation.isLandscape)
    }

    private func cancelCompactTransition() {
        offerPullSettlement?.cancel()
        offerPullSettlement = nil
        offerPullingOpen = false
        immersiveDetentOffered = false
    }

    private func reconcileDetailPresentation() {
        guard detailDismissalRevision == nil else { return }
        if model.selection != .none {
            guard !otherSheetUp else { return }
            if stand == .offer, !offerPullingOpen { stand = .resting }
            if phoneIsLandscape, isBoardSelection,
               stand != .offer, stand != .immersive {
                stand = .large
            }
            detailSheetPresented = true
        } else if detailSheetPresented, stand != .offer {
            dismissDetailSheet()
        } else {
            presentOffer()
        }
    }

    private func dismissDetailSheet() {
        guard detailSheetPresented, detailDismissalRevision == nil else { return }
        detailDismissalRevision = model.selectionRevision
        dismissingOfferID = stand == .offer ? model.rides.offeringID : nil
        cancelCompactTransition()
        model.beginPanelDismissal()
        detailSheetPresented = false
        // Nothing was presented, so no dismissal callback is coming. The menu
        // closes here instead, by the same steps `onDismiss` would take.
        if landscapeBoardMenu { detailDidDismiss() }
    }

    private func detailDidDismiss() {
        // Rotating into landscape takes the sheet away and puts the board up
        // in its place. A close comes through `dismissDetailSheet`, which has
        // set the revision first.
        if keepingBoardThroughRotation, detailDismissalRevision == nil { return }
        let newerSelection = detailDismissalRevision.map {
            model.selectionRevision != $0 && model.selection != .none
        } ?? false
        cancelCompactTransition()
        if let dismissingOfferID, dismissingOfferID == model.rides.offeringID,
           !newerSelection { model.rides.dismiss() }
        if !newerSelection { model.selection = .none }
        stand = .resting
        model.followLockLow = false
        detailSheetPresented = false
        dismissingOfferID = nil
        model.finishPanelDismissal()
        // Let SwiftUI retire the old sheet before asking it to present again.
        // Keep the dismissal gate closed through this final run-loop turn.
        DispatchQueue.main.async {
            detailDismissalRevision = nil
            reconcileDetailPresentation()
        }
    }

    /// Put the offer up, if there is one and there is room for it.
    private func presentOffer() {
        guard offerAvailable, !detailSheetPresented, detailDismissalRevision == nil,
              !otherSheetUp else { return }
        offerPullSettlement?.cancel()
        offerPullSettlement = nil
        offerPullingOpen = false
        stand = .offer
        detailSheetPresented = true
    }

    /// Start answering the pull before UIKit has chosen its destination detent.
    private func beginOfferPull() {
        guard !offerPullingOpen else { return }
        if stand == .immersive {
            // The vehicle is already selected — full screen follow never
            // cleared it — so the panel can render under the finger without
            // asking the model to open anything.
            offerPullSettlement?.cancel()
            offerPullSettlement = nil
            offerPullingOpen = true
            return
        }
        guard stand == .offer, model.selection == .none, offerStanding else { return }
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
        // Done and a tap on bare map close the expanded card. They must not
        // land on the follow bar — only the fullscreen control puts the sheet
        // there — and they must not fire while the bar is already up: that
        // state has its own swipe down.
        guard stand != .immersive, detailDismissalRevision == nil else { return }
        _ = model.beginSelectionInteraction()
        cancelCompactTransition()
        if landscapeBoardMenu {
            // The menu is not a sheet and has no floor to land on: Done puts
            // it away outright rather than dropping it onto a ride bar.
            dismissDetailSheet()
            return
        }
        guard offerStanding else {
            dismissDetailSheet()
            return
        }
        // Selection is cleared by the detent watcher once the sheet is
        // already showing the bar. Clearing it here left one frame of
        // DetailSheet with nothing in it — the "Nothing selected" flash.
        withAnimation(menuMotion) { stand = .offer }
    }

    /// Hide the map chrome and shrink the vehicle card to its next-stop line.
    ///
    /// Following stays on. The camera is already chasing the train; this only
    /// gets the buttons out of the picture. The sheet's own pull is how the
    /// chrome comes back — up to keep watching, down to let go.
    private func enterImmersive() {
        guard model.isFollowingVehicle, detailSheetPresented,
              detailDismissalRevision == nil else { return }
        offerPullSettlement?.cancel()
        offerPullSettlement = nil
        offerPullingOpen = false
        // Offer the compact height first, then select it. Same-update add-and-
        // select is ignored and the card stays at resting — a tall empty sheet
        // with the pill's line of text in the middle of it.
        immersiveDetentOffered = true
        let revision = model.selectionRevision
        DispatchQueue.main.async {
            guard immersiveDetentOffered, detailSheetPresented,
                  detailDismissalRevision == nil, model.isFollowingVehicle,
                  model.selectionRevision == revision else { return }
            withAnimation(menuMotion) { stand = .immersive }
        }
    }

    /// The buttons over the map, gone while the follow bar has the bottom of
    /// the screen. Restored the moment the sheet leaves that height — including
    /// mid-pull, so the controls fade in under the same finger that is opening
    /// the panel.
    private var chromeHidden: Bool {
        stand == .immersive && !offerPullingOpen
    }

    /// Follow hides the chrome so the map is the picture. A landscape board
    /// that fills the short side covers the map, so the same buttons would
    /// sit on top of the list — hide them there too. Compass follows this,
    /// the frame readout does not.
    private var hidesMapChrome: Bool {
        chromeHidden || landscapeBoardMenu || (compactHeightClass && stand == .large)
    }

    /// The heights this sheet is offered: two, unless there is a compact bar
    /// to stand on — the ride offer, or the follow pill. Those two share one
    /// height, so they are one detent, and which contents it has is `stand`.
    /// The compact height is in the set only while the sheet should be able
    /// to land there: always for a live offer, and for the follow pill only
    /// once fullscreen has offered it. Leaving it out of the resting card's
    /// set is what makes a downward swipe close the panel rather than shrink
    /// it into the follow bar.
    private var detents: Set<PresentationDetent> {
        if stand == .immersive || immersiveDetentOffered {
            return [Self.compactDetent, resting, .large]
        }
        return offerStanding ? [Self.compactDetent, resting, .large] : [resting, .large]
    }

    /// Constant identity, so it is the same value in the set and in the
    /// selection. The height itself follows the size class — see `CompactPillDetent`.
    private static let compactDetent = PresentationDetent.custom(CompactPillDetent.self)

    private var pillHeight: CGFloat {
        compactHeightClass ? FollowPill.landscapeHeight : RidePill.height
    }

    /// The compact ride/follow bar, whose ends should be semicircles.
    private var compactPillStanding: Bool {
        stand == .offer || stand == .immersive
    }

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
                case .offer: return offerStanding ? Self.compactDetent : resting
                case .immersive: return Self.compactDetent
                case .resting: return resting
                }
            },
            set: { picked in
                guard detailDismissalRevision == nil, detents.contains(picked) else { return }
                if picked == .large {
                    // Compact-height rotation often names `.large` because the
                    // sheet no longer matches a 100-point detent. A real pull
                    // is already tracked; ignore the rest so a pill stays a pill.
                    if (stand == .offer || stand == .immersive), !offerPullingOpen {
                        return
                    }
                    stand = .large
                }
                else if picked == Self.compactDetent {
                    // One height, two meanings. Fullscreen follow owns it
                    // while that detent has been offered; otherwise it is
                    // the ride bar.
                    stand = (stand == .immersive || immersiveDetentOffered)
                        ? .immersive : .offer
                }
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
    private var resting: PresentationDetent { .custom(PanelRestingDetent.self) }

    private var measuredRestingHeight: CGFloat? {
        guard model.panelFold.isFinite, model.panelFold > 40 else { return nil }
        let cap: CGFloat = compactHeightClass ? 180 : 620
        let chrome = compactHeightClass ? Self.landscapeChrome : Self.chrome
        return min(model.panelFold + chrome, cap)
    }

    private static let chrome: CGFloat = 85
    /// Nothing, and that is measured rather than assumed. A landscape card
    /// hides the navigation bar, the grabber floats over the content instead
    /// of above it, and the strip UIKit keeps for the home indicator is drawn
    /// below the height a detent asks for rather than out of it — so the
    /// height the card measured is the height the detent wants. The 52 points
    /// this used to add were 52 points of blank under the last line.
    private static let landscapeChrome: CGFloat = 0

    /// The same number as `resting`, in points, for laying out around the sheet.
    private func restingHeight(in screen: CGFloat) -> CGFloat {
        guard model.panelFold > 40 else {
            return compactHeightClass ? min(160, screen * 0.38) : screen * 0.42
        }
        let cap: CGFloat = compactHeightClass ? 180 : 620
        let chrome = compactHeightClass ? Self.landscapeChrome : Self.chrome
        return min(model.panelFold + chrome, cap)
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
            sheet = pillHeight + 10
        } else if detailSheetPresented, stand == .immersive {
            sheet = pillHeight + 10
        } else if compactHeightClass, stand == .large {
            // The board fills the short side. Leave the locate and fullscreen
            // controls on the bottom edge rather than lifting them over a
            // sheet that already covers the map.
            sheet = 0
        } else if model.selection != .none {
            sheet = restingHeight(in: height) + 10
        } else {
            sheet = 0
        }
        return sheet + 16
    }

    /// Locate on the right, where every map on this phone puts it; full screen
    /// follow opposite it, at the same height, and only while the camera is
    /// actually chasing a vehicle. The two are different questions — where the
    /// map *is*, and whether the buttons should stay out of the way while it
    /// stays there — so they do not share a capsule.
    private var mapControls: some View {
        HStack(alignment: .bottom) {
            if viewingRoute {
                Button {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { routeVehiclesHidden.toggle() }
                    model.onSetVehiclesVisible?(!routeVehiclesHidden)
                } label: {
                    Image(systemName: routeVehiclesHidden ? "eye.slash" : "eye")
                }
                .buttonStyle(MapPillControlStyle())
                .padding(.vertical, 4)
                .liquidGlass(in: Circle(), interactive: true)
                .accessibilityIdentifier("Route transport visibility")
                .accessibilityLabel(routeVehiclesHidden ? "Show all transport" : "Hide all transport")
                .accessibilityValue(routeVehiclesHidden ? "Hidden" : "Visible")
                .transition(.scale.combined(with: .opacity))
            } else if model.isFollowingVehicle, stand != .immersive {
                Button { enterImmersive() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(MapPillControlStyle())
                .padding(.vertical, 4)
                .liquidGlass(in: Circle(), interactive: true)
                .accessibilityLabel("Watch this service full screen")
                .accessibilityHint("Hides the buttons and shrinks the vehicle card to the next stop")
                .transition(.scale.combined(with: .opacity))
            }
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
            .buttonStyle(MapPillControlStyle())
            .padding(.vertical, 4)
            .liquidGlass(in: Capsule(), interactive: true)
        }
        .animation(menuMotion, value: model.isFollowingVehicle)
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

/// Owns search observation and animation so opening the field does not
/// invalidate ContentView and its Mapbox representable.
private struct MapSearchHeader: View {
    @Bindable var model: AppModel
    @Binding var showingLegend: Bool
    var openLegend: () -> Void
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var menuMotion: Animation? { reduceMotion ? nil : MenuMotion.animation }

    /// The row across the top, or the search field it becomes.
    ///
    /// One or the other rather than both. The header is already four controls
    /// wide on the narrowest phone this runs on, and a fifth that expands into
    /// a field has nowhere to expand *to* — so opening search takes the row,
    /// and Cancel gives it back.
    var body: some View {
        LiquidGlassContainer {
            if model.isSearching {
                SearchBar(model: model)
            } else {
                controls
            }
        }
        .frame(minHeight: 44, alignment: .top)
        .padding(.top, 4)
        .animation(reduceMotion ? nil : SearchBar.expansionAnimation, value: model.isSearching)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            StatusPill(model: model, showingLegend: $showingLegend, openLegend: openLegend)
            Spacer(minLength: 0)
            Button {
                model.isSearching = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.mapControl)
            .accessibilityLabel("Search for a stop or a service")
            Button {
                withAnimation(menuMotion) { model.showTimeControl.toggle() }
            } label: {
                Image(systemName: model.showTimeControl ? "clock.fill" : "clock")
            }
            .buttonStyle(.mapControl)
            .foregroundStyle(model.showTimeControl ? Color.accentColor : .primary)
            Button(action: openSettings) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.mapControl)
        }
    }
}

struct StatusPill: View {
    @Bindable var model: AppModel
    @Binding var showingLegend: Bool
    var openLegend: () -> Void

    var body: some View {
        StatusPillButton(summary: summary, statusColor: statusColor,
                         showingLegend: $showingLegend, openLegend: openLegend) {
            VehicleLegend(
                activity: FeedActivity(model: model),
                hiddenModes: model.hiddenModes,
                onToggleMode: { model.toggleHidden($0) }
            )
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
    @Binding var showingLegend: Bool
    var openLegend: () -> Void
    @ViewBuilder var legend: () -> Legend

    var body: some View {
        Button(action: openLegend) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(summary)
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .liquidGlass(in: Capsule(), interactive: true)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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
    @Previewable @State var showingLegend = false
    StatusPillButton(summary: "7919 Vehicles", statusColor: .green,
                     showingLegend: $showingLegend, openLegend: { showingLegend = true }) { VehicleLegend() }
        .padding()
        .preferredColorScheme(.dark)
}

/// A control that reads as part of the map rather than part of a form.
struct MapControlStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.44, weight: .semibold))
            .frame(width: size, height: size)
            .liquidGlass(in: Circle(), interactive: true)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct MapPillControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 23, weight: .semibold))
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
            .background {
                Circle().fill(.primary.opacity(configuration.isPressed ? 0.10 : 0))
                    .padding(4)
            }
            .scaleEffect(configuration.isPressed ? 1.12 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == MapControlStyle {
    static var mapControl: MapControlStyle { MapControlStyle() }
}

extension View {
    /// iPhone landscape is a compact-height size class, and a sheet's default
    /// there is a full-screen cover. Stay a bottom sheet so a pill stays a
    /// pill and the map stays on screen.
    func keepBottomSheet() -> some View {
        presentationCompactAdaptation(.sheet)
    }

}

/// Reads the sheet presentation controller's existing pan gesture.
///
/// Adding a SwiftUI `DragGesture` here would make it compete with the system
/// sheet for the same touch. This zero-impact view instead adds itself as one
/// more target of the recogniser UIKit already owns, so detent physics,
/// scrolling and dismissal remain entirely native.
private struct SheetPullObserver: UIViewRepresentable {
    /// Radius of a resting or large card. The compact bar uses half its own
    /// height instead, so the left and right ends are semicircles.
    static let cardCornerRadius: CGFloat = 38

    var active: Bool
    var restingHeight: CGFloat?
    /// Landscape `.large` cards: pin the presented view to the container so
    /// the glass goes edge to edge instead of sitting as a centred page card.
    var fillsContainer: Bool = false
    /// Compact ride/follow bar: join the top and bottom corners into a stadium.
    var capsule: Bool = false
    var pillHeight: CGFloat = RidePill.height
    var pulledUp: () -> Void
    var ended: () -> Void
    var interactionBegan: () -> Void
    var interactionEnded: () -> Void
    var transitionBegan: () -> UUID
    var transitionEnded: (UUID) -> Void

    func makeUIView(context: Context) -> ObservationView {
        let view = ObservationView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ObservationView, context: Context) {
        let chromeChanged = view.capsule != capsule
            || view.pillHeight != pillHeight
            || view.fillsContainer != fillsContainer
        view.active = active
        view.restingHeight = restingHeight
        view.fillsContainer = fillsContainer
        view.capsule = capsule
        view.pillHeight = pillHeight
        view.pulledUp = pulledUp
        view.ended = ended
        view.interactionBegan = interactionBegan
        view.interactionEnded = interactionEnded
        view.transitionBegan = transitionBegan
        view.transitionEnded = transitionEnded
        view.installWhenReady()
        if fillsContainer || chromeChanged {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            // SwiftUI reapplies page sizing after this pass. Pin again
            // once that layout has settled.
            DispatchQueue.main.async { [weak view] in
                view?.setNeedsLayout()
                view?.layoutIfNeeded()
            }
        }
    }

    static func dismantleUIView(_ view: ObservationView, coordinator: ()) {
        view.removeObservations()
    }

    @MainActor
    final class ObservationView: UIView {
        /// Compact height plus the home-indicator extra an edge-attached
        /// detent adds. Taller than this is already a card, so keep 38 pt
        /// corners rather than a stadium that grows with the finger.
        private static let pillHeightSlack: CGFloat = 56

        var active = false
        var restingHeight: CGFloat?
        var fillsContainer = false
        var capsule = false
        var pillHeight: CGFloat = RidePill.height
        private var appliedHeight: CGFloat?
        private weak var sizedSheet: UISheetPresentationController?
        private var measuredDetent: UISheetPresentationController.Detent?
        var pulledUp: () -> Void = {}
        var ended: () -> Void = {}
        var interactionBegan: () -> Void = {}
        var interactionEnded: () -> Void = {}
        var transitionBegan: () -> UUID = { UUID() }
        var transitionEnded: (UUID) -> Void = { _ in }
        private weak var observedTransition: AnyObject?

        private var pans: [UIPanGestureRecognizer] = []
        private var openedThisPull = false
        /// Background interaction lets the map receive gestures while the
        /// compact sheet is up. Its pinch also changes the centroid of UIKit's
        /// presentation pan, so observing translation alone can mistake map
        /// zooming for a pull on the sheet and swap the compact offer for a
        /// full board at the 100-point detent. A real sheet pull begins inside
        /// this sheet and uses one finger; the map zoom does neither.
        private weak var trackingPan: UIPanGestureRecognizer?
        private var installationQueued = false
        private var registeredTraitChanges = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            registerTraitChangesIfNeeded()
            installWhenReady()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installWhenReady()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyEdgeAttachment()
            applyPresentedFrame()
        }

        private func registerTraitChangesIfNeeded() {
            guard !registeredTraitChanges else { return }
            registeredTraitChanges = true
            registerForTraitChanges(
                [UITraitVerticalSizeClass.self]
            ) { (view: ObservationView, _) in
                view.installWhenReady()
            }
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
            configurePresentation()
            observePresentationTransition()
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

        /// Keep SwiftUI's identifier and selection, but resolve the height from
        /// this sheet's current measurement. Custom SwiftUI detent contexts do
        /// not propagate changing custom environment values on every OS.
        private final class DetentContext: NSObject, UISheetPresentationControllerDetentResolutionContext {
            let containerTraitCollection: UITraitCollection
            let maximumDetentValue: CGFloat
            init(traits: UITraitCollection, height: CGFloat) {
                containerTraitCollection = traits
                maximumDetentValue = height
            }
        }

        private func restingDetent(in sheet: UISheetPresentationController) -> UISheetPresentationController.Detent? {
            // SwiftUI supplies a Set: its native array order is not an identity.
            // Resolve heights before choosing the card, never resize the pill.
            let context = DetentContext(traits: traitCollection,
                height: max(300, window?.bounds.height ?? 800))
            return sheet.detents.filter {
                $0.identifier != .large && ($0.resolvedValue(in: context) ?? 0) > RidePill.height + 20
            }.max { ($0.resolvedValue(in: context) ?? 0) < ($1.resolvedValue(in: context) ?? 0) }
        }

        private func configurePresentation() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                   let sheet = controller.presentationController as? UISheetPresentationController {
                    applyEdgeAttachment(to: sheet)
                    updateRestingDetent(on: sheet)
                    return
                }
                responder = current.next
            }
        }

        private func applyEdgeAttachment() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                   let sheet = controller.presentationController as? UISheetPresentationController {
                    applyEdgeAttachment(to: sheet)
                    return
                }
                responder = current.next
            }
        }

        /// iPhone landscape is regular-width + compact-height, so the default
        /// sheet is an iPad-style centred page card. Stay edge-attached so it
        /// is a bottom sheet; when the board fills the screen, also feed the
        /// container size as `preferredContentSize` so the glass is not a card.
        private func applyEdgeAttachment(to sheet: UISheetPresentationController) {
            let fill = fillsContainer
                || (traitCollection.verticalSizeClass == .compact
                    && sheet.selectedDetentIdentifier == .large)
            sheet.prefersEdgeAttachedInCompactHeight = true
            if #available(iOS 17.0, *) {
                sheet.prefersPageSizing = false
            }
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = fill
            // Not `nil`. The system's own answer rounds a floating card's
            // bottom corners about half as far as its top ones, which on a
            // card that clears the bottom of the screen reads as two different
            // shapes joined down the middle. This is also the line that used
            // to undo `presentationCornerRadius` every time the sheet laid
            // itself out, so the radius has to be said here or not at all.
            //
            // The compact bar is a stadium: the top and bottom corners meet
            // so the ends are semicircles. A card keeps 38 pt, matching the
            // system's top corners.
            let radius = cornerRadius(for: sheet, fill: fill)
            sheet.preferredCornerRadius = radius
            applyPresentedCorners(on: sheet, fill: fill, radius: radius)
            if fill, let container = sheet.containerView {
                sheet.presentedViewController.preferredContentSize = container.bounds.size
            }
            if #available(iOS 27.0, *) {
                // Automatic placement on iOS 27 centres a page-sized card.
                // Clearing the source keeps edge-attachment at the bottom.
                sheet.preferredPlacement = .automatic
            }
            sheet.sourceView = nil
        }

        /// Compact bar: a stadium. Card: 38 pt. Full-screen: square.
        ///
        /// Ask for the whole height, not half: a continuous corner curve at
        /// exactly half-height still leaves a flat, which is the rounded
        /// rectangle the compact bar was drawing. UIKit clamps this to a
        /// stadium.
        private func cornerRadius(for sheet: UISheetPresentationController, fill: Bool) -> CGFloat {
            if fill { return 0 }
            let height = sheet.presentedView?.bounds.height ?? 0
            if capsule, height <= pillHeight + Self.pillHeightSlack {
                return max(height, pillHeight)
            }
            return SheetPullObserver.cardCornerRadius
        }

        /// iOS 26's glass follows `preferredCornerRadius`, but a continuous
        /// curve at exactly half-height can still leave a flat on the ends.
        /// `capsule()` is the shape that joins those corners into semicircles.
        /// Applied to the presented view and any same-height wrapper between
        /// it and the container, because the glass is not always the hosted
        /// view itself.
        private func applyPresentedCorners(
            on sheet: UISheetPresentationController, fill: Bool, radius: CGFloat
        ) {
            guard #available(iOS 26.0, *) else { return }
            let config: UICornerConfiguration
            if fill {
                config = .uniformCorners(radius: .fixed(0))
            } else if capsule, radius > SheetPullObserver.cardCornerRadius {
                config = .capsule()
            } else {
                config = .uniformCorners(
                    radius: .fixed(SheetPullObserver.cardCornerRadius)
                )
            }
            let height = sheet.presentedView?.bounds.height ?? 0
            var view: UIView? = sheet.presentedView
            while let current = view, current !== sheet.containerView {
                if height < 1 || abs(current.bounds.height - height) < 2 {
                    current.cornerConfiguration = config
                }
                view = current.superview
            }
        }

        /// iOS 27's automatic placement can still leave a page-sized card after
        /// the flags above. Pin the presented view to the container so
        /// two-column boards and train cards are not clipped.
        private func applyPresentedFrame() {
            guard traitCollection.verticalSizeClass == .compact else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                   let sheet = controller.presentationController as? UISheetPresentationController,
                   let presented = sheet.presentedView,
                   let container = sheet.containerView {
                    var frame = presented.frame
                    if fillsContainer {
                        let bounds = container.bounds
                        sheet.presentedViewController.preferredContentSize = bounds.size
                        guard abs(frame.width - bounds.width) > 1
                            || abs(frame.height - bounds.height) > 1
                            || abs(frame.minX) > 1
                            || abs(frame.minY) > 1 else { return }
                        presented.frame = bounds
                    } else {
                        let width = container.bounds.width
                        guard abs(frame.width - width) > 1 || abs(frame.minX) > 1 else { return }
                        frame.origin.x = 0
                        frame.size.width = width
                        presented.frame = frame
                    }
                    return
                }
                responder = current.next
            }
        }

        private func updateRestingDetent(on sheet: UISheetPresentationController) {
            guard let resting = restingDetent(in: sheet) else { return }
            if sizedSheet !== sheet {
                sizedSheet = sheet
                measuredDetent = nil
            }
            let needsResolver = measuredDetent !== resting
            if needsResolver {
                let detent = UISheetPresentationController.Detent.custom(identifier: resting.identifier) { [weak self] context in
                    min(self?.restingHeight ?? context.maximumDetentValue * 0.42,
                        context.maximumDetentValue)
                }
                measuredDetent = detent
                sheet.detents = sheet.detents.map { $0 === resting ? detent : $0 }
            }
            if needsResolver || appliedHeight != restingHeight {
                appliedHeight = restingHeight
                sheet.invalidateDetents()
            }
        }

        private func observePresentationTransition() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                   let coordinator = controller.transitionCoordinator {
                    guard observedTransition !== coordinator as AnyObject else { return }
                    observedTransition = coordinator as AnyObject
                    let token = transitionBegan()
                    let completed = transitionEnded
                    // Native presentations can outlast the settling estimate.
                    // Keep the opening target and live publishers held until
                    // UIKit actually finishes, including an interrupted opening.
                    if !coordinator.animate(alongsideTransition: nil, completion: { _ in completed(token) }) {
                        completed(token)
                    }
                    return
                }
                responder = current.next
            }
        }

        @objc private func observe(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                // Ancestor pans share one touch. Only its owner may release
                // the hold that keeps live data out of the moving sheet.
                guard trackingPan == nil, pan.numberOfTouches == 1,
                      bounds.contains(pan.location(in: self)) else { return }
                trackingPan = pan
                openedThisPull = false
                interactionBegan()
            case .changed:
                let movement = pan.translation(in: window)
                guard active, trackingPan === pan, pan.numberOfTouches == 1,
                      !openedThisPull,
                      movement.y < -12,
                      abs(movement.y) > abs(movement.x)
                else { return }
                openedThisPull = true
                pulledUp()
            case .ended, .cancelled, .failed:
                guard trackingPan === pan else { return }
                interactionEnded()
                if openedThisPull { ended() }
                openedThisPull = false
                trackingPan = nil
            default:
                break
            }
        }

        func removeObservations() {
            if trackingPan != nil { interactionEnded() }
            for pan in pans {
                pan.removeTarget(self, action: #selector(observe(_:)))
            }
            pans.removeAll()
            openedThisPull = false
            trackingPan = nil
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
            if stats.queue.followPoint.sent > 0 || stats.queue.fleet.sent > 0
                || stats.queue.followWagons.sent > 0 {
                row(
                    "queue",
                    queueLine(stats.queue),
                    warn: stats.queue.followPoint.p50 > 17
                        || stats.queue.followWagons.p50 > 17
                )
            }
            row("map", "\(stats.stops) stops · \(stats.tracks) runs")
            if stats.routePathPoints > 0 {
                row(
                    "route",
                    stats.drawnRoutePoints == stats.routePathPoints
                        ? "\(stats.routePathPoints) pts"
                        : "\(stats.drawnRoutePoints) / \(stats.routePathPoints) pts",
                    warn: stats.drawnRoutePoints > 2_000
                )
            }
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

    /// How late follow / fleet GeoJSON writes land, in milliseconds. `n/m` is
    /// load events against stamps — a large gap is Mapbox coalescing patches.
    private func queueLine(_ queue: GeoJSONQueueProbe.Snapshot) -> String {
        func band(_ name: String, _ b: GeoJSONQueueProbe.Band) -> String? {
            guard b.sent > 0 else { return nil }
            return String(
                format: "%@ %.0f/%.0fms %d/%d",
                name, b.p50, b.p95, b.landed, b.sent
            )
        }
        return [
            band("fp", queue.followPoint),
            band("fw", queue.followWagons),
            band("fv", queue.fleet),
            band("fs", queue.followShape),
            band("vs", queue.vehicleShapes),
        ].compactMap { $0 }.joined(separator: " · ")
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
