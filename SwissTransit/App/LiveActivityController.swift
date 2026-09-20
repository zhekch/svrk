import ActivityKit
import BackgroundTasks
import Foundation
import OSLog
import TransitActivity
import TransitCore
import UIKit

/// Pins a departure or an arrival as a Live Activity, and keeps its delay
/// honest after the app leaves the screen.
///
/// On iOS 18+, the system renders the minute countdown independently of this
/// process. App updates switch to "now" at the event minute; the stale date
/// is a best-effort fallback while suspended. Polls refresh delays/platforms
/// and maintain the legacy iOS 17 countdown. Delay and
/// platform come from one OJP trip-info document for the watched run only.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    static let refreshTaskID = "com.kexts.swisstransit.live-activity"

    private var fleet: Fleet?
    private var loads: LoadService?
    private var clock: Clock?
    private var dataMode: () -> TransitDataMode = {
        Settings.choice("dataMode", or: .all)
    }
    private var pollTask: Task<Void, Never>?
    private var minuteTimer: DispatchSourceTimer?
    private var delayTask: Task<Void, Never>?
    private var dismissTasks: [String: Task<Void, Never>] = [:]
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// Stay up this long after the printed event minute, then dismiss.
    private static let linger: TimeInterval = 60
    /// Stop lists kept for the session so an arrival watch can name where the
    /// vehicle currently is without asking the fleet, which is suspended.
    private var stopsByWatch: [String: [Call]] = [:]
    /// OJP refs resolved after the activity has already started. Attributes
    /// are frozen at `Activity.request`, so a later journey id lives here.
    private var resolved: [String: ResolvedWatch] = [:]
    private static let log = Logger(
        subsystem: "com.kexts.swisstransit", category: "live-activity"
    )

    private init() {}

    /// Register the refresh identifier. Must run in `App.init`, before the
    /// system can deliver a launch for a task — which is a cold start with no
    /// `AppModel` yet.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskID, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await LiveActivityController.shared.performBackgroundRefresh(refresh)
            }
        }
    }

    func configure(
        fleet: Fleet,
        loads: LoadService,
        clock: Clock,
        dataMode: @escaping () -> TransitDataMode
    ) {
        self.fleet = fleet
        self.loads = loads
        self.clock = clock
        self.dataMode = dataMode
        adoptSystemActivities()
        if hasActive { startPolling() }
    }

    var hasActive: Bool {
        !Activity<TripActivityAttributes>.activities.isEmpty
    }

    // MARK: - Starting

    /// Request the activity from the swipe, then fill OJP refs in the
    /// background. Waiting on the fleet actor first is how a pin could sit
    /// behind a SIRI reconcile until the user had locked the phone — at
    /// which point `Activity.request` is refused.
    func watch(
        entry: BoardEntry,
        station: String,
        showing: BoardRow.Showing,
        now: Timestamp
    ) async {
        let kind: TripWatchKind = showing == .departure ? .departure : .arrival
        let event = showing == .departure ? entry.departure : entry.arrival
        let delay = max(0, entry.delay ?? 0)
        let scheduledStamp = scheduledTime(event: event, delayMinutes: delay)
        let watchID = Self.id(
            kind: kind, journey: entry.id, station: station, event: scheduledStamp
        )
        let day = LoadService.Key.day(of: entry.runIdentity?.scheduledDeparture ?? event)
        let stopRef = Self.stopRef(from: entry)
        let journeyRef = Self.publishedRef(from: entry)
        let line = Journey.publishedLine(entry.line, mode: entry.mode)
        let platform = Format.platform(entry.platform) ?? entry.platform
        let started = await start(
            attributes: TripActivityAttributes(
                kind: kind,
                line: line.isEmpty ? "ext" : line,
                mode: entry.mode.rawValue,
                station: station,
                destination: entry.to ?? "",
                watchID: watchID,
                journeyRef: journeyRef,
                day: day,
                stopRef: stopRef,
                bookedPlatform: platform
            ),
            state: Self.stamp(
                TripActivityAttributes.ContentState(
                    expected: Date(timeIntervalSince1970: TimeInterval(event)),
                    scheduled: Date(timeIntervalSince1970: TimeInterval(scheduledStamp)),
                    delayMinutes: delay,
                    platform: platform,
                    cancelled: false
                ),
                bookedPlatform: platform
            )
        )
        guard started else { return }
        Task { [weak self] in
            await self?.enrichWatch(
                entry: entry, station: station, kind: kind, event: event,
                watchID: watchID, now: now
            )
        }
    }

    func watchArrival(vehicle: VehicleSnapshot, stop: Call, now: Timestamp) async {
        await watchCall(vehicle: vehicle, stop: stop, now: now, kind: .arrival)
    }

    func watchDeparture(vehicle: VehicleSnapshot, stop: Call, now: Timestamp) async {
        await watchCall(vehicle: vehicle, stop: stop, now: now, kind: .departure)
    }

    private func watchCall(
        vehicle: VehicleSnapshot, stop: Call, now: Timestamp, kind: TripWatchKind
    ) async {
        let expectedStamp = kind == .departure ? stop.dep : stop.displayedArrival
        let scheduledStamp = kind == .departure
            ? Self.scheduledDeparture(of: stop)
            : Self.scheduledArrival(of: stop)
        let watchID = Self.id(
            kind: kind, journey: vehicle.id, station: stop.name, event: scheduledStamp
        )
        stopsByWatch[watchID] = vehicle.stops

        let journeyRef = Self.publishedRef(from: vehicle)
        let day = LoadService.Key.day(
            of: vehicle.stops.first?.sched ?? vehicle.stops.first?.dep ?? now
        )
        let presence = kind == .arrival ? Self.presence(of: vehicle, at: now) : nil
        let line = Journey.publishedLine(vehicle.displayLine, mode: vehicle.mode)
        let platform = Format.platform(stop.platform) ?? stop.platform
        let started = await start(
            attributes: TripActivityAttributes(
                kind: kind,
                line: line.isEmpty ? "ext" : line,
                mode: vehicle.mode.rawValue,
                station: stop.name,
                destination: vehicle.displayDestination ?? vehicle.to ?? "",
                watchID: watchID,
                journeyRef: journeyRef,
                day: day,
                stopRef: stop.ref,
                bookedPlatform: platform
            ),
            state: Self.stamp(
                TripActivityAttributes.ContentState(
                    expected: Date(timeIntervalSince1970: TimeInterval(expectedStamp)),
                    scheduled: Date(timeIntervalSince1970: TimeInterval(scheduledStamp)),
                    delayMinutes: max(0, stop.delay ?? vehicle.delay ?? 0),
                    platform: platform,
                    cancelled: stop.cancelled || vehicle.cancelled,
                    currentStop: presence?.name,
                    atCurrentStop: presence?.atStop ?? false
                ),
                bookedPlatform: platform
            )
        )
        guard started else { return }
        Task { [weak self] in
            await self?.enrichArrival(vehicle: vehicle, stop: stop, watchID: watchID)
        }
    }

    @discardableResult
    private func start(
        attributes: TripActivityAttributes,
        state: TripActivityAttributes.ContentState
    ) async -> Bool {
        let content = ActivityContent(
            state: state,
            staleDate: TripActivityFormat.countdownEnd(state.expected),
            relevanceScore: 100
        )
        if let existing = Activity<TripActivityAttributes>.activities.first(
            where: { $0.attributes.watchID == attributes.watchID }
        ) {
            await existing.update(content)
            persist(attributes)
            startPolling()
            scheduleDismissal(existing)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        }
        if !ActivityAuthorizationInfo().areActivitiesEnabled {
            Self.log.error("live activities are disabled")
        }
        do {
            let activity = try Activity.request(attributes: attributes, content: content)
            persist(attributes)
            startPolling()
            scheduleDismissal(activity)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        } catch {
            Self.log.error(
                "live activity did not start: \(error.localizedDescription, privacy: .public)"
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    private func enrichWatch(
        entry: BoardEntry,
        station: String,
        kind: TripWatchKind,
        event: Timestamp,
        watchID: String,
        now: Timestamp
    ) async {
        guard isLive(watchID), let fleet else { return }

        var journeyRef: String?
        var day: String?
        var stopRef: String?
        var currentStop: String?
        var atCurrentStop = false

        if let snapshot = await fleet.journey(
            id: entry.id, at: event, boardDeparture: entry.departure
        ) {
            guard isLive(watchID) else { return }
            stopsByWatch[watchID] = snapshot.stops
            if let handle = await fleet.journeyRef(for: snapshot.id) {
                journeyRef = handle.ref
                day = handle.day
            } else if let ref = snapshot.journeyRef, !ref.isEmpty {
                journeyRef = ref
            }
            if let match = Self.matchingCall(
                in: snapshot.stops, station: station, event: event, kind: kind
            ), let ref = match.ref, !ref.isEmpty {
                stopRef = ref
            }
            if kind == .arrival {
                let presence = Self.presence(of: snapshot, at: now)
                currentStop = presence.name
                atCurrentStop = presence.atStop
            }
        } else if let handle = await fleet.journeyRef(for: entry.id) {
            journeyRef = handle.ref
            day = handle.day
        }

        guard isLive(watchID) else { return }
        remember(watchID: watchID, journeyRef: journeyRef, day: day, stopRef: stopRef)

        if kind == .arrival, let currentStop,
           let activity = liveActivity(watchID) {
            var state = activity.content.state
            state.currentStop = currentStop
            state.atCurrentStop = atCurrentStop
            state = Self.stamp(state, bookedPlatform: activity.attributes.bookedPlatform)
            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: TripActivityFormat.countdownEnd(state.expected),
                    relevanceScore: 80
                )
            )
        }
        kickDelayFetch(background: false)
    }

    private func enrichArrival(
        vehicle: VehicleSnapshot, stop: Call, watchID: String
    ) async {
        guard isLive(watchID), let fleet else { return }
        var journeyRef = Self.publishedRef(from: vehicle)
        var day: String?
        if let handle = await fleet.journeyRef(for: vehicle.id) {
            journeyRef = handle.ref
            day = handle.day
        }
        guard isLive(watchID) else { return }
        remember(watchID: watchID, journeyRef: journeyRef, day: day, stopRef: stop.ref)
        kickDelayFetch(background: false)
    }

    private func isLive(_ watchID: String) -> Bool {
        liveActivity(watchID) != nil
    }

    private func liveActivity(_ watchID: String) -> Activity<TripActivityAttributes>? {
        Activity<TripActivityAttributes>.activities.first {
            $0.attributes.watchID == watchID
        }
    }

    static func publishedRef(from entry: BoardEntry) -> String? {
        entry.runIdentity?.publishedJourneyRef
            ?? BoardRunIdentity.publishedJourneyRef(id: entry.id)
    }

    static func publishedRef(from vehicle: VehicleSnapshot) -> String? {
        if let ref = vehicle.journeyRef, !ref.isEmpty { return ref }
        return BoardRunIdentity.publishedJourneyRef(id: vehicle.id)
    }

    // MARK: - Refresh

    func enteredForeground() {
        adoptSystemActivities()
        if hasActive { startPolling() }
    }

    func enteredBackground() {
        // Refresh live data while background time remains. The iOS 18+
        // countdown does not depend on these wakeups. "now" and dismissal
        // still need a content/lifecycle update, or the system's stale fallback.
        guard hasActive else { return }
        scheduleNextBackgroundRefresh()
        let task = UIApplication.shared.beginBackgroundTask(withName: "live-activity-refresh") { [weak self] in
            self?.endBackgroundTask()
        }
        backgroundTask = task
        Task {
            await pushRemaining()
            await fetchDelays(background: true)
            scheduleNextBackgroundRefresh()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Remaining minutes first, on the clock minute, never waiting on OJP.
    /// A hung trip-info request used to stall the countdown for several minutes.
    private func startPolling() {
        pollTask?.cancel()
        minuteTimer?.cancel()
        minuteTimer = nil
        guard hasActive else { return }
        pollTask = Task { [weak self] in
            await self?.pushRemaining()
            self?.kickDelayFetch(background: false)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + TripActivityFormat.secondsUntilNextMinute(),
            repeating: 60,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.hasActive else { return }
                await self.pushRemaining()
                self.kickDelayFetch(background: false)
            }
        }
        timer.resume()
        minuteTimer = timer
    }

    private func kickDelayFetch(background: Bool) {
        delayTask?.cancel()
        delayTask = Task { [weak self] in
            await self?.fetchDelays(background: background)
        }
    }

    private func scheduleNextBackgroundRefresh() {
        guard hasActive else { return }
        let minute = Date(
            timeIntervalSinceNow: TripActivityFormat.secondsUntilNextMinute()
        )
        let endAt = Activity<TripActivityAttributes>.activities
            .map { Self.dismissesAt($0.content.state.expected) }
            .filter { $0 > Date() }
            .min()
        scheduleRefresh(at: [minute, endAt].compactMap { $0 }.min() ?? minute)
    }

    private func performBackgroundRefresh(_ task: BGAppRefreshTask) async {
        scheduleNextBackgroundRefresh()
        let work = Task { [weak self] in
            await self?.pushRemaining()
            self?.startPolling()
            await self?.fetchDelays(background: true)
        }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
        scheduleNextBackgroundRefresh()
    }

    private func scheduleRefresh(after seconds: TimeInterval) {
        scheduleRefresh(at: Date(timeIntervalSinceNow: seconds))
    }

    private func scheduleRefresh(at date: Date) {
        guard hasActive else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = date
        try? BGTaskScheduler.shared.submit(request)
    }

    static func dismissesAt(_ expected: Date) -> Date {
        TripActivityFormat.countdownEnd(expected).addingTimeInterval(linger)
    }

    private func scheduleDismissal(_ activity: Activity<TripActivityAttributes>) {
        let id = activity.attributes.watchID
        dismissTasks[id]?.cancel()
        let fire = Self.dismissesAt(activity.content.state.expected)
        dismissTasks[id] = Task { [weak self] in
            let wait = fire.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            // Dismissal must not wait for a trip-info network request.
            await self?.refreshAll(force: false, background: true, fetchDelays: false)
        }
    }

    /// Rewrite remaining minutes from the wall clock. No network.
    func pushRemaining() async {
        await refreshAll(force: false, background: false, fetchDelays: false)
        scheduleNextBackgroundRefresh()
    }

    func fetchDelays(background: Bool) async {
        await refreshAll(force: true, background: background, fetchDelays: true)
    }

    func refreshAll(force: Bool, background: Bool, fetchDelays: Bool = true) async {
        let activities = Activity<TripActivityAttributes>.activities
        guard !activities.isEmpty else {
            clearPersisted()
            return
        }
        let loads = self.loads ?? LoadService(token: Secrets.ojpToken)
        let now = clock?.nowSeconds() ?? Timestamp(Date().timeIntervalSince1970)
        let allowNetwork = fetchDelays && dataMode() != .off
        for activity in activities {
            if Task.isCancelled { return }
            await refresh(
                activity,
                loads: loads,
                now: now,
                force: force,
                background: background,
                allowNetwork: allowNetwork
            )
        }
        if !hasActive {
            pollTask?.cancel()
            pollTask = nil
            delayTask?.cancel()
            delayTask = nil
            minuteTimer?.cancel()
            minuteTimer = nil
        }
    }

    private func refresh(
        _ activity: Activity<TripActivityAttributes>,
        loads: LoadService,
        now: Timestamp,
        force: Bool,
        background: Bool,
        allowNetwork: Bool
    ) async {
        var state = activity.content.state
        let attributes = activity.attributes
        let previous = state
        let handle = self.handle(for: attributes)

        if allowNetwork, let handle {
            let key = LoadService.Key(journeyID: handle.ref, day: handle.day)
            _ = await loads.load(
                for: key, background: background, maxAge: force ? 0 : 60
            )
            if let timing = await loads.timing(for: key) {
                if let next = Self.apply(
                    timing,
                    to: attributes,
                    stopRef: handle.stopRef,
                    current: state,
                    now: now
                ) {
                    state = next
                }
                if attributes.kind == .arrival, !timing.calls.isEmpty {
                    stopsByWatch[attributes.watchID] = timing.calls
                }
            }
        }

        if attributes.kind == .arrival {
            if allowNetwork, let snapshot = await liveSnapshot(for: attributes, at: now) {
                let presence = Self.presence(of: snapshot, at: now)
                state.currentStop = presence.name
                state.atCurrentStop = presence.atStop
                if let stop = Self.matchingCall(
                    in: snapshot.stops,
                    station: attributes.station,
                    event: Timestamp(state.scheduled.timeIntervalSince1970),
                    kind: .arrival
                ) {
                    state.expected = Date(timeIntervalSince1970: TimeInterval(stop.displayedArrival))
                    state.delayMinutes = max(0, stop.delay ?? snapshot.delay ?? state.delayMinutes)
                    if let platform = Format.platform(stop.platform) ?? stop.platform {
                        state.platform = platform
                    }
                    state.cancelled = stop.cancelled || snapshot.cancelled
                }
            } else if let stops = stopsByWatch[attributes.watchID] {
                let presence = Self.presence(of: stops, at: now)
                state.currentStop = presence.name
                state.atCurrentStop = presence.atStop
            }
        }

        state = Self.stamp(state, bookedPlatform: attributes.bookedPlatform)

        if state.cancelled || Date() >= Self.dismissesAt(state.expected) {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
            forget(attributes.watchID)
            return
        }

        let content = ActivityContent(
            state: state,
            staleDate: TripActivityFormat.countdownEnd(state.expected),
            relevanceScore: 80
        )
        if let alert = Self.changeAlert(
            from: previous, to: state, attributes: attributes
        ) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await activity.update(content, alertConfiguration: alert)
        } else {
            await activity.update(content)
        }
        scheduleDismissal(activity)
    }

    /// Keep the legacy countdown payload and the orange platform flag current.
    /// iOS 18+ views count from `expected` using the system clock instead.
    static func stamp(
        _ state: TripActivityAttributes.ContentState, bookedPlatform: String?
    ) -> TripActivityAttributes.ContentState {
        var next = state
        next.remainingMinutes = TripActivityFormat.remainingMinutes(until: next.expected)
        next.platformChanged = platformsDiffer(bookedPlatform, next.platform)
        return next
    }

    static func platformsDiffer(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return (Format.platform(a) ?? a) != (Format.platform(b) ?? b)
    }

    /// An island alert (and, on a phone, a haptic) when the delay grows or
    /// the platform is not the one that was booked.
    static func changeAlert(
        from previous: TripActivityAttributes.ContentState,
        to next: TripActivityAttributes.ContentState,
        attributes: TripActivityAttributes
    ) -> AlertConfiguration? {
        let delayNow = TripActivityFormat.delayText(
            minutes: next.delayMinutes, mode: attributes.mode
        )
        let delayBefore = TripActivityFormat.delayText(
            minutes: previous.delayMinutes, mode: attributes.mode
        )
        let delayWorsened = next.delayMinutes > previous.delayMinutes && delayNow != nil
        let delayAppeared = delayNow != nil && delayBefore == nil
        let quayMoved = platformsDiffer(previous.platform, next.platform)

        var bits: [String] = []
        if quayMoved, let platform = next.platform {
            bits.append(TripActivityFormat.platformPhrase(kind: attributes.kind, platform: platform))
        }
        if delayWorsened || delayAppeared, let delayNow {
            bits.append("\(delayNow) · \(TripActivityFormat.clock(next.expected))")
        }
        guard !bits.isEmpty else { return nil }

        let title: String
        if quayMoved, delayWorsened || delayAppeared {
            title = "\(attributes.line) changed"
        } else if quayMoved {
            title = "\(attributes.line) platform change"
        } else {
            title = "\(attributes.line) delayed"
        }
        return AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: title),
            body: LocalizedStringResource(stringLiteral: bits.joined(separator: " · ")),
            sound: .default
        )
    }

    private func liveSnapshot(
        for attributes: TripActivityAttributes, at now: Timestamp
    ) async -> VehicleSnapshot? {
        guard let fleet, let handle = handle(for: attributes) else { return nil }
        return await fleet.journey(id: handle.ref, at: now)
    }

    // MARK: - Timing → state

    static func apply(
        _ timing: JourneyTiming,
        to attributes: TripActivityAttributes,
        stopRef: String? = nil,
        current: TripActivityAttributes.ContentState,
        now: Timestamp
    ) -> TripActivityAttributes.ContentState? {
        var next = current
        if timing.cancelled { next.cancelled = true }

        let planned = Timestamp(current.scheduled.timeIntervalSince1970)
        let match = matchingTiming(
            timing, stopRef: stopRef ?? attributes.stopRef, planned: planned
        )
        if let match {
            let expectedStamp: Timestamp?
            switch attributes.kind {
            case .departure: expectedStamp = match.expectedDeparture ?? match.expectedArrival
            case .arrival: expectedStamp = match.expectedArrival ?? match.expectedDeparture
            }
            if let expectedStamp {
                let incoming = Date(timeIntervalSince1970: TimeInterval(expectedStamp))
                if TripActivityFormat.shouldAcceptLiveTime(current: current.expected, incoming: incoming) {
                    next.expected = incoming
                }
            }
            let seconds: Int?
            switch attributes.kind {
            case .departure: seconds = match.departureDelay ?? match.arrivalDelay
            case .arrival: seconds = match.arrivalDelay ?? match.departureDelay
            }
            if let minutes = SiriParser.reportableDelay(seconds) {
                next.delayMinutes = max(0, minutes)
            }
            if let quay = match.expectedQuay, !quay.isEmpty {
                next.platform = Format.platform(quay) ?? quay
            }
            if match.cancelled { next.cancelled = true }
        }

        if attributes.kind == .arrival, !timing.calls.isEmpty {
            let presence = presence(of: timing.calls, at: now)
            next.currentStop = presence.name
            next.atCurrentStop = presence.atStop
        }
        return next
    }

    private static func matchingTiming(
        _ timing: JourneyTiming, stopRef: String?, planned: Timestamp
    ) -> CallTiming? {
        if let stopRef, let exact = timing.byStop[stopRef] { return exact }
        if let stopRef {
            let station = StopRegister.stationOf(stopRef)
            let candidates = timing.byStop.filter { StopRegister.stationOf($0.key) == station }
            if candidates.count == 1 { return candidates.first?.value }
            if let close = candidates.values.first(where: { abs($0.planned - planned) < 90 }) {
                return close
            }
        }
        return timing.byStop.values.first { abs($0.planned - planned) < 60 }
    }

    static func presence(of vehicle: VehicleSnapshot, at now: Timestamp) -> (name: String, atStop: Bool) {
        presence(of: vehicle.stops, at: now, index: vehicle.index, moving: vehicle.moving)
    }

    static func presence(of stops: [Call], at now: Timestamp) -> (name: String, atStop: Bool) {
        let index = stops.lastIndex { now >= $0.arr && now <= $0.dep && !$0.cancelled }
            ?? stops.lastIndex { $0.dep <= now }
        return presence(of: stops, at: now, index: index ?? 0, moving: index == nil || (index.map { now > stops[$0].dep } ?? true))
    }

    private static func presence(
        of stops: [Call], at now: Timestamp, index: Int, moving: Bool
    ) -> (name: String, atStop: Bool) {
        if !moving, stops.indices.contains(index) {
            let stop = stops[index]
            if !StopNaming.isTechnical(stop.name), !stop.cancelled {
                return (stop.name, true)
            }
        }
        if let next = Positioning.nextStopIndex(stops, at: now) {
            return (stops[next].name, false)
        }
        if stops.indices.contains(index), !StopNaming.isTechnical(stops[index].name) {
            return (stops[index].name, !moving)
        }
        return (stops.last?.name ?? "", false)
    }

    static func matchingCall(
        in stops: [Call], station: String, event: Timestamp, kind: TripWatchKind
    ) -> Call? {
        func same(_ name: String) -> Bool {
            StopNaming.sameBoardDestination(name, station)
        }
        let named = stops.filter { same($0.name) }
        if named.count == 1 { return named[0] }
        let close = named.min { a, b in
            let aTime = kind == .departure ? a.dep : a.displayedArrival
            let bTime = kind == .departure ? b.dep : b.displayedArrival
            return abs(aTime - event) < abs(bTime - event)
        }
        if let close, abs((kind == .departure ? close.dep : close.displayedArrival) - event) < 180 {
            return close
        }
        // Never fall back to a different station. The Bern–Spiez numbered
        // leg of an RE1 does not call at Frutigen; picking Spiez because it
        // is the nearest time replaced "Arrival to Frutigen 20:25" with
        // Spiez 20:10.
        return nil
    }

    static func scheduledArrival(of stop: Call) -> Timestamp {
        if let planned = stop.scheduledArrival { return planned }
        if let sched = stop.sched {
            let dwell = max(0, stop.dep - stop.arr)
            return sched - dwell
        }
        if let delay = stop.delay, delay > 0 { return stop.arr - delay * 60 }
        return stop.arr
    }

    static func scheduledDeparture(of stop: Call) -> Timestamp {
        if let sched = stop.sched { return sched }
        if let delay = stop.delay, delay > 0 { return stop.dep - delay * 60 }
        return stop.dep
    }

    private func scheduledTime(event: Timestamp, delayMinutes: Int) -> Timestamp {
        delayMinutes > 0 ? event - delayMinutes * 60 : event
    }

    private static func stopRef(from entry: BoardEntry) -> String? {
        guard let station = entry.runIdentity?.station, !station.hasPrefix("name:") else {
            return nil
        }
        return station
    }

    static func id(kind: TripWatchKind, journey: String, station: String, event: Timestamp) -> String {
        "\(kind.rawValue)|\(journey)|\(station)|\(event)"
    }

    // MARK: - Persistence

    /// Enough to ask OJP again after a cold background launch, when `AppModel`
    /// has not yet handed us its `LoadService`.
    private struct StoredWatch: Codable {
        var watchID: String
        var journeyRef: String?
        var day: String
        var stopRef: String?
    }

    private struct ResolvedWatch {
        var journeyRef: String?
        var day: String
        var stopRef: String?
    }

    private struct WatchHandle {
        var ref: String
        var day: String
        var stopRef: String?
    }

    private static let storageKey = "liveActivity.watches"

    /// Prefer a ref resolved after start over the frozen activity attributes.
    private func handle(for attributes: TripActivityAttributes) -> WatchHandle? {
        func valid(_ ref: String?) -> String? {
            guard let ref, !ref.isEmpty else { return nil }
            return ref
        }
        if let overlay = resolved[attributes.watchID], let ref = valid(overlay.journeyRef) {
            return WatchHandle(
                ref: ref,
                day: overlay.day.isEmpty ? attributes.day : overlay.day,
                stopRef: overlay.stopRef ?? attributes.stopRef
            )
        }
        if let ref = valid(attributes.journeyRef) {
            return WatchHandle(ref: ref, day: attributes.day, stopRef: attributes.stopRef)
        }
        return nil
    }

    private func persist(_ attributes: TripActivityAttributes) {
        let overlay = resolved[attributes.watchID]
        remember(
            watchID: attributes.watchID,
            journeyRef: overlay?.journeyRef ?? attributes.journeyRef,
            day: overlay?.day ?? attributes.day,
            stopRef: overlay?.stopRef ?? attributes.stopRef
        )
    }

    private func remember(
        watchID: String,
        journeyRef: String? = nil,
        day: String? = nil,
        stopRef: String? = nil
    ) {
        var current = resolved[watchID] ?? ResolvedWatch(day: day ?? "")
        if let journeyRef, !journeyRef.isEmpty { current.journeyRef = journeyRef }
        if let day, !day.isEmpty { current.day = day }
        if let stopRef, !stopRef.isEmpty { current.stopRef = stopRef }
        resolved[watchID] = current

        var stored = loadPersisted()
        if let index = stored.firstIndex(where: { $0.watchID == watchID }) {
            if let journeyRef, !journeyRef.isEmpty { stored[index].journeyRef = journeyRef }
            if let day, !day.isEmpty { stored[index].day = day }
            if let stopRef, !stopRef.isEmpty { stored[index].stopRef = stopRef }
        } else {
            stored.append(StoredWatch(
                watchID: watchID,
                journeyRef: current.journeyRef,
                day: current.day,
                stopRef: current.stopRef
            ))
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func forget(_ watchID: String) {
        dismissTasks[watchID]?.cancel()
        dismissTasks[watchID] = nil
        stopsByWatch[watchID] = nil
        resolved[watchID] = nil
        var stored = loadPersisted()
        stored.removeAll { $0.watchID == watchID }
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func clearPersisted() {
        for task in dismissTasks.values { task.cancel() }
        dismissTasks.removeAll()
        pollTask?.cancel()
        pollTask = nil
        delayTask?.cancel()
        delayTask = nil
        minuteTimer?.cancel()
        minuteTimer = nil
        stopsByWatch.removeAll()
        resolved.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func loadPersisted() -> [StoredWatch] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([StoredWatch].self, from: data)
        else { return [] }
        return stored
    }

    private func adoptSystemActivities() {
        let live = Set(Activity<TripActivityAttributes>.activities.map(\.attributes.watchID))
        var stored = loadPersisted()
        stored.removeAll { !live.contains($0.watchID) }
        resolved = resolved.filter { live.contains($0.key) }
        for activity in Activity<TripActivityAttributes>.activities {
            if !stored.contains(where: { $0.watchID == activity.attributes.watchID }) {
                let overlay = resolved[activity.attributes.watchID]
                stored.append(StoredWatch(
                    watchID: activity.attributes.watchID,
                    journeyRef: overlay?.journeyRef ?? activity.attributes.journeyRef,
                    day: overlay?.day ?? activity.attributes.day,
                    stopRef: overlay?.stopRef ?? activity.attributes.stopRef
                ))
            }
        }
        for item in stored {
            if resolved[item.watchID] == nil {
                resolved[item.watchID] = ResolvedWatch(
                    journeyRef: item.journeyRef,
                    day: item.day,
                    stopRef: item.stopRef
                )
            }
        }
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
