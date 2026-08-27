import Foundation

/// The formation service, and the shape its answers arrive in.
///
/// One request per train, cached, because the answer changes about as often as
/// the train is re-marshalled — which for the great majority of runs is never.
/// The service publishes `lastUpdate` with each response and the realtime half
/// of it can revise during the day, so the cache is held for minutes rather
/// than for the day.
public actor FormationService {
    /// Both halves of the answer in one call. The stop-based half carries the
    /// short string and the sectors; the vehicle-based half carries the seats,
    /// the wheelchair spaces and the vehicle numbers. They are the same request
    /// and there is no reason to make it twice.
    static let full = OTDClient.API(
        path: "/formation/v2/formations_full", perMinute: FormationService.perMinute, perDay: 20000,
        accept: "application/json"
    )

    /// The subscription's published rate: fifty calls a minute, twenty thousand
    /// a day. Applied here rather than discovered by being refused, because a
    /// `429 Rate Limit Exceeded` costs the panel its drawing and looks exactly
    /// like a train that has no formation.
    ///
    /// The figure is worth trusting rather than guessing at: the cookbook says
    /// five, the subscription says fifty, and a burst of about fifty is where a
    /// 429 actually appeared — for every path including `/health`.
    static let perMinute = 50

    /// The realtime half on its own, which is the half that draws the train.
    ///
    /// `formations_full` needs the rolling-stock register to agree with the
    /// realtime system, and where it does not it refuses the whole request —
    /// "Was not able to find CUS Formation with appropriate From/To to match
    /// against FOS", HTTP 400, no formation at all. That is not a rare corner:
    /// it is every ICE, and the ICE is precisely the train somebody wants a
    /// coach number for. The realtime system knows the formation perfectly well
    /// — sectors, coach numbers, the dining car — so when the combined call
    /// refuses, this asks for that half alone and draws the train without the
    /// seat counts.
    static let stopBased = OTDClient.API(
        path: "/formation/v2/formations_stop_based", perMinute: FormationService.perMinute, perDay: 20000,
        accept: "application/json"
    )

    public enum Answer: Sendable, Equatable {
        case formation(TrainFormation)
        /// The service has nothing for this train — a bus, a company outside
        /// the eleven, or a train nobody filed a formation for. A silence, and
        /// the panel says nothing rather than apologising.
        case none
        /// Something went wrong that is worth saying out loud.
        case failed(String)
    }

    private let client: OTDClient
    private var cache: [FormationKey: (answer: Answer, at: Date)] = [:]
    private var inFlight: [FormationKey: Task<Answer, Never>] = [:]
    /// Where answers are kept between launches, once a caller names a place.
    private var store: URL?

    /// How long an answer stands before it is asked for again.
    ///
    /// Fifteen minutes rather than four. The map now asks about the trains in
    /// view on its own, so the answer to "what is this train made of" is
    /// usually already in hand by the time somebody taps it — and at four
    /// minutes that work was thrown away and paid for twice, which on a fifty
    /// a minute budget is the difference between covering a screenful and
    /// covering half of one. What goes stale in that window is the realtime
    /// half: a track change, a coach shut late. Fifteen minutes is short enough
    /// that a re-marshalling is picked up within a stop or two and long enough
    /// that a tap after a sweep costs nothing.
    static let ttl: TimeInterval = 900

    /// Keep answers on disk as well as in memory.
    ///
    /// Same window, so nothing is served from disk that would not still be
    /// served from memory — the only thing this adds is surviving a launch,
    /// which matters because the first thing the map does on opening is ask
    /// about everything on screen again.
    public func keepAnswers(in directory: URL) {
        store = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        prune(directory)
    }

    /// Throw away anything too old to be served, so the directory does not grow
    /// by a few hundred files a day for ever.
    private func prune(_ directory: URL) {
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if modified == nil || modified! < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func file(for key: FormationKey) -> URL? {
        store?.appendingPathComponent(
            "\(key.operatorCode.rawValue)-\(key.trainNumber)-\(key.operationDate).json"
        )
    }

    /// The answer kept on disk, if it is still inside the window.
    private func held(_ key: FormationKey) -> Answer? {
        guard let file = file(for: key),
              let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate,
              Date().timeIntervalSince(modified) < Self.ttl,
              let data = try? Data(contentsOf: file)
        else { return nil }
        // An empty file is how a silence is recorded: the service answered, and
        // what it said was nothing. Worth keeping — re-asking about a train it
        // has never heard of is the commonest way to spend the budget on
        // nothing at all.
        guard !data.isEmpty else { return Answer.none }
        guard let decoded = try? JSONDecoder().decode(FormationResponse.self, from: data),
              let formation = decoded.digest()
        else { return nil }
        return .formation(formation)
    }

    private func keep(_ data: Data, for key: FormationKey) {
        guard let file = file(for: key) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public init(token: String?) {
        client = OTDClient(token: token)
    }

    public var isConfigured: Bool {
        get async { await client.isConfigured }
    }

    /// Slots per minute kept back for whoever is actually waiting.
    ///
    /// The map learns the formations of the trains in view by asking about them
    /// in the background, which can fill a fifty-a-minute window on its own. A
    /// panel opened while that is happening would then be refused — and a
    /// refusal is indistinguishable, on screen, from a train the service has
    /// nothing for. So background work stops short of the limit and leaves this
    /// much for the foreground.
    static let foregroundReserve = 14

    /// What this train is made of, from the cache where possible.
    ///
    /// `background` marks a request nobody is waiting for: it is answered from
    /// the cache like any other, but it will not spend the last of the minute's
    /// budget, and it gives up rather than queueing behind a full window.
    public func formation(for key: FormationKey, background: Bool = false) async -> Answer {
        if let held = cache[key], Date().timeIntervalSince(held.at) < Self.ttl {
            return held.answer
        }
        // Two panels asking at once — which happens every time a vehicle is
        // re-read while the first request is still open — is one request.
        if let running = inFlight[key] { return await running.value }

        // Anything a previous run — or a previous sweep — already asked about.
        // Checked before the budget, so a train whose answer is on disk costs
        // nothing whether or not there is room to ask about it.
        if let kept = held(key) {
            cache[key] = (kept, Date())
            return kept
        }

        if background, await client.headroom(Self.full) <= Self.foregroundReserve {
            return .failed("leaving room for the foreground")
        }

        let task = Task<(Answer, Data?), Never> { [client] in
            await Self.fetch(key: key, client: client)
        }
        inFlight[key] = Task { await task.value.0 }
        let (answer, body) = await task.value
        inFlight[key] = nil

        // Written for a silence too, as an empty file — see `held`.
        switch answer {
        case .formation: if let body { keep(body, for: key) }
        case .none: keep(Data(), for: key)
        case .failed: break
        }

        // A silence is cached, and deliberately: a train the service does not
        // know about is not going to start knowing about it in the thirty
        // seconds a panel stays open, and re-asking on every re-read spends the
        // quota on a silence.
        //
        // A *failure* is not. Being throttled says nothing about the train, and
        // remembering it for four minutes would turn one burst into four
        // minutes of blank panels for trains the service could have answered.
        if case .failed = answer {} else { cache[key] = (answer, Date()) }
        return answer
    }

    private static func fetch(key: FormationKey, client: OTDClient) async -> (Answer, Data?) {
        var items = URLComponents()
        items.queryItems = [
            URLQueryItem(name: "evu", value: key.operatorCode.rawValue),
            URLQueryItem(name: "operationDate", value: key.operationDate),
            URLQueryItem(name: "trainNumber", value: String(key.trainNumber)),
        ]
        let query = items.percentEncodedQuery ?? ""

        do {
            return try await ask(full, query: query, client: client)
        } catch let failure as OTDClient.Failure {
            switch failure {
            // A refusal to reconcile the two sources, which the realtime half
            // alone is not subject to. Worth the second call: it is the
            // difference between a drawing and nothing for a whole class of
            // train.
            case .http(400):
                return (try? await ask(stopBased, query: query, client: client)) ?? (.none, nil)
            // 404 is the service's way of saying it has no realtime data for
            // this train, which is the ordinary case for most of the fleet.
            case .http(404), .noToken: return (.none, nil)
            // Throttled, or asked to wait longer than a panel will stay open.
            // Not an answer about this train, so it is not remembered as one —
            // see `formation(for:)`, which declines to cache these.
            case .http(429), .wouldWait, .quotaExhausted:
                return (.failed(failure.description), nil)
            default: return (.failed(failure.description), nil)
            }
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }

    private static func ask(
        _ api: OTDClient.API, query: String, client: OTDClient
    ) async throws -> (Answer, Data?) {
        let data = try await client.fetch(api, query: query)
        let decoded = try JSONDecoder().decode(FormationResponse.self, from: data)
        guard let formation = decoded.digest() else { return (.none, data) }
        return (.formation(formation), data)
    }
}

// MARK: - The wire format

/// The response, transcribed field for field, and then reduced to something
/// worth drawing.
///
/// Every property is optional. The service is explicit that the vehicle-based
/// half only appears when every source had what it needed, and that the
/// realtime half can be missing entirely — so a train with a stop list and no
/// short string, or a short string and no seat counts, is a normal answer
/// rather than a malformed one.
struct FormationResponse: Decodable {
    var lastUpdate: String?
    var trainMetaInformation: TrainMeta?
    var formations: [Formation]?
    var formationsAtScheduledStops: [StopFormation]?
    var relationships: [Relationship]?

    struct TrainMeta: Decodable {
        var trainNumber: Int?
        var toCode: String?
        var runs: String?
    }

    struct Formation: Decodable {
        var metaInformation: Meta?
        var formationVehicles: [Vehicle]?

        struct Meta: Decodable {
            var length: Double?
            var numberAxis: Int?
            var numberSeats: Int?
            var numberVehicles: Int?
        }
    }

    struct Vehicle: Decodable {
        var position: Int?
        var number: Int?
        var vehicleIdentifier: Identifier?
        var vehicleProperties: Properties?
        var formationVehicleAtScheduledStops: [VehicleStop]?

        struct Identifier: Decodable {
            var evn: String?
            var typeCodeName: String?
        }

        struct Properties: Decodable {
            var length: Double?
            var number1class: Int?
            var number2class: Int?
            var numberBeds: Int?
            var numberBikeHooks: Int?
            var numberRestaurantSpace: Int?
            var lowFloorTrolley: Bool?
            var climated: Bool?
            var closed: Bool?
            var accessibilityProperties: Accessibility?
        }

        struct Accessibility: Decodable {
            var numberWheelchairSpaces: Int?
            var wheelchairToilet: Bool?
        }

        struct VehicleStop: Decodable {
            var stopPoint: StopPoint?
            var sectors: String?
            var track: String?
            var accessToPreviousVehicle: Bool?
        }
    }

    struct StopFormation: Decodable {
        var scheduledStop: ScheduledStop?
        var formationShort: Short?

        struct Short: Decodable {
            var formationShortString: String?
            var vehicleGoals: [Goal]?
        }

        struct Goal: Decodable {
            var fromVehicleAtPosition: Int?
            var toVehicleAtPosition: Int?
            var destinationStopPoint: StopPoint?
        }
    }

    struct ScheduledStop: Decodable {
        var stopPoint: StopPoint?
        var stopTime: StopTime?
        var track: String?
        var stopType: String?
        var stopModifications: Int?
    }

    struct StopPoint: Decodable {
        var uic: Int?
        var name: String?
    }

    struct StopTime: Decodable {
        var arrivalTime: String?
        var departureTime: String?
    }

    struct Relationship: Decodable {
        var vehicleRelationshipDetails: Details?
        var advancedJourneyInformation1: Journey?
        /// The second working a relationship names, which only a separation
        /// has. Both halves of a splitting train are here, and the one the
        /// reader is not standing in is as often this field as the first — see
        /// `TrainFormation.Relationship.others`.
        var advancedJourneyInformation2: Journey?

        struct Details: Decodable {
            var relationshipType: String?
            /// Whether the other working is the one before this point or the
            /// one after it — `V` for before, `N` for after. A separate field
            /// from `relationshipType`, and easy to conflate with it: both are
            /// single letters and the two vocabularies do not overlap.
            var direction: String?
            var stopPoint: StopPoint?
        }

        struct Journey: Decodable {
            var trainMetaInformation: TrainMeta?
            var journeyMetaInformation: JourneyMeta?
        }

        struct JourneyMeta: Decodable {
            /// The other working's Swiss Journey ID, in the same spelling the
            /// realtime feed keys its journeys by. That is what makes the other
            /// half of a splitting train findable rather than guessable: a
            /// train number alone would have to be searched for, and two
            /// services leaving one station at one minute are not rare.
            var SJYID: String?
        }
    }
}

extension FormationResponse {
    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainTimestamps = ISO8601DateFormatter()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return timestamps.date(from: text) ?? plainTimestamps.date(from: text)
    }

    /// Everything the panel needs, and nothing it does not.
    ///
    /// Returns nil where there is no train to draw at all, which is the answer
    /// for a train number the service accepted and knows nothing about.
    func digest() -> TrainFormation? {
        let formation = formations?.first
        // Every orientation the response carries, not merely the first of them.
        // See `vehicles(for:)`.
        let lists = (formations ?? []).map { $0.formationVehicles ?? [] }
        guard let stops = formationsAtScheduledStops, !stops.isEmpty else { return nil }

        var out: [FormationAtStop] = []
        for stop in stops {
            let scheduled = stop.scheduledStop
            // An international working carries its foreign legs as stops with
            // every field null — ICE 377 is fifteen of those before Basel Bad
            // Bf. A stop with no name is not a stop this can draw or match.
            guard let name = scheduled?.stopPoint?.name, !name.isEmpty else { continue }

            // The short string is the better source: it is the only one that
            // says what kind of vehicle each one is, and it is present for
            // nearly every stop of every train the service carries.
            let uic = scheduled?.stopPoint?.uic

            // Parsed once and kept twice. The padding is not a vehicle and has
            // no business in a drawing of the train, but it is the only thing
            // that says which sectors lie beyond it — so it travels alongside.
            let filed = FormationShortString.parse(stop.formationShort?.formationShortString ?? "")
            var coaches = filed.filter { $0.kind != .fictitious }

            // Which way round the train is standing *here*.
            let vehicles = Self.vehicles(for: coaches, among: lists)

            if coaches.isEmpty {
                // No realtime string for this stop — the origin of a run
                // sometimes has none. Fall back to the vehicle list, which has
                // no types but does have the sectors.
                coaches = vehicles.enumerated().compactMap { position, vehicle in
                    guard let at = vehicle.stop(uic: uic) else { return nil }
                    var coach = Coach(position: vehicle.position ?? position + 1, kind: .classless)
                    coach.sector = FormationResponse.usable(at.sectors)
                    return coach
                }
            }

            // Both halves are now ordered from the front of the train as it
            // stands here, so they join on position.
            for i in coaches.indices {
                guard let vehicle = vehicles.first(where: { $0.position == coaches[i].position })
                    ?? vehicles[safe: coaches[i].position - 1]
                else { continue }
                coaches[i].apply(vehicle, at: vehicle.stop(uic: uic))
            }

            let sectors = orderedSectors(of: coaches)
            out.append(FormationAtStop(
                stopName: name,
                uic: scheduled?.stopPoint?.uic ?? 0,
                track: Self.usable(scheduled?.track),
                arrival: Self.date(scheduled?.stopTime?.arrivalTime),
                departure: Self.date(scheduled?.stopTime?.departureTime),
                coaches: coaches,
                sectors: sectors,
                // A goal with no name is still a goal. The service sends the
                // UIC always and the name only sometimes, and dropping the
                // nameless ones left a splitting train with one portion — which
                // reads as a train that does not split.
                portions: (stop.formationShort?.vehicleGoals ?? []).compactMap { goal in
                    guard let from = goal.fromVehicleAtPosition,
                          let to = goal.toVehicleAtPosition
                    else { return nil }
                    return FormationAtStop.Portion(
                        destination: Self.usable(goal.destinationStopPoint?.name),
                        destinationUIC: goal.destinationStopPoint?.uic,
                        fromPosition: from, toPosition: to
                    )
                },
                padded: filed
            ))
        }

        return TrainFormation(
            trainNumber: trainMetaInformation?.trainNumber ?? 0,
            operatorCode: trainMetaInformation?.toCode ?? "",
            runs: TrainFormation.RunState(rawValue: trainMetaInformation?.runs ?? "J") ?? .runs,
            totalLength: formation?.metaInformation?.length,
            totalSeats: formation?.metaInformation?.numberSeats,
            vehicleCount: formation?.metaInformation?.numberVehicles,
            axleCount: formation?.metaInformation?.numberAxis,
            lastUpdate: Self.date(lastUpdate),
            stops: out,
            relationships: (relationships ?? []).compactMap { relation in
                guard let raw = relation.vehicleRelationshipDetails?.relationshipType,
                      let kind = TrainFormation.Relationship.Kind(rawValue: raw)
                else { return nil }
                let details = relation.vehicleRelationshipDetails
                let named = [
                    relation.advancedJourneyInformation1,
                    relation.advancedJourneyInformation2,
                ].compactMap { journey -> TrainFormation.Working? in
                    guard let journey else { return nil }
                    let number = journey.trainMetaInformation?.trainNumber
                    let id = journey.journeyMetaInformation?.SJYID
                    guard number != nil || id != nil else { return nil }
                    return TrainFormation.Working(trainNumber: number, journeyID: id)
                }
                return TrainFormation.Relationship(
                    kind: kind,
                    direction: details?.direction.flatMap(
                        TrainFormation.Relationship.Direction.init(rawValue:)
                    ),
                    stopName: details?.stopPoint?.name,
                    stopUIC: details?.stopPoint?.uic,
                    others: named
                )
            }
        )
    }

    /// The vehicle list that describes the train the way round it is standing
    /// at this stop.
    ///
    /// The response carries `formations` **once per orientation**, not once per
    /// train, and the entries are each other reversed: for IC 966 one lists the
    /// Re 460 at position 1 and the `Bt4-K` driving trailer at position 12, the
    /// other the same twelve vehicles the other way about. Nothing in either
    /// says which is which — the sectors under `formationVehicleAtScheduledStops`
    /// are positional, so they are identical in both.
    ///
    /// Taking `formations.first` and joining on position is therefore right up
    /// to the point where the train reverses and wrong after it. IC 61 reverses
    /// at Bern: from Bern onward the short string ran `2:20 … LK` while the
    /// first vehicle list still ran `Re460 … Bt4-K`, so every coach was given
    /// the identity of the coach at the *other* end of the train. The leading
    /// vehicle — really the driving trailer — came through named `Re460`,
    /// 18.5 m long and carrying the locomotive's seat counts, and because
    /// `isDrivingStock("Re460")` is false it lost its cab: the map drew the
    /// front of every reversed IC as a plain coach with a flat end, which is
    /// the "IC trains have no nose cone" report.
    ///
    /// The short string settles it. It prints the reservation number of each
    /// vehicle in the order they stand *here*, and those numbers are painted on
    /// the coach and so do not turn round with the train. Score each orientation
    /// by how many of them land on the vehicle the join would give them, and
    /// take the best. A train with one orientation, or a stop whose string
    /// carries no numbers, scores nothing either way and keeps the first list —
    /// which is what this did before.
    static func vehicles(for coaches: [Coach], among lists: [[Vehicle]]) -> [Vehicle] {
        guard lists.count > 1 else { return lists.first ?? [] }
        var best = lists[0]
        var bestScore = -1
        for list in lists {
            var score = 0
            for coach in coaches {
                guard let printed = coach.number else { continue }
                let vehicle = list.first { $0.position == coach.position }
                    ?? list[safe: coach.position - 1]
                if vehicle?.number == printed { score += 1 }
            }
            if score > bestScore {
                bestScore = score
                best = list
            }
        }
        return best
    }

    /// The sectors the train reaches, in the order it occupies them.
    ///
    /// Not sorted. The letters run up the platform in one fixed direction and
    /// the train is listed front-first, so the order they appear in *is* which
    /// way the train is pointing — and sorting it into A, B, C would throw away
    /// the one thing that says so.
    private func orderedSectors(of coaches: [Coach]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for sector in coaches.compactMap(\.sector) where !seen.contains(sector) {
            seen.insert(sector)
            out.append(sector)
        }
        return out
    }

    /// The service writes "N/A" where it has no track or no sector, which is a
    /// string and not a value.
    static func usable(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text != "N/A" else { return nil }
        return text
    }
}

private extension FormationResponse.Vehicle {
    /// Where this vehicle stands at one stop.
    ///
    /// Looked up by station rather than by index, and that is not a nicety. The
    /// two halves of the response are not the same length: a coach that joins
    /// the train partway has only the stops it is actually on — the Glacier
    /// Express is filed with five stops and its coaches with four — so the
    /// n-th entry of one list is not the n-th stop of the other.
    func stop(uic: Int?) -> VehicleStop? {
        guard let uic else { return nil }
        return formationVehicleAtScheduledStops?.first { $0.stopPoint?.uic == uic }
    }
}

private extension Coach {
    mutating func apply(
        _ vehicle: FormationResponse.Vehicle, at stop: FormationResponse.Vehicle.VehicleStop?
    ) {
        // The vehicle list numbers coaches for reservation; the short string
        // carries the same number and usually agrees. Where only one of them
        // has it, take it.
        if number == nil, let printed = vehicle.number, printed != 0 { number = printed }
        if sector == nil { sector = FormationResponse.usable(stop?.sectors) }
        // `accessToPreviousVehicle` is deliberately not read, and the name is
        // why it was tried. It does not mean "the gangway in front of this
        // vehicle is blocked": the service sets it false for *either* bracket
        // in the short string, whichever side the vehicle carries it on. On IC
        // 715 — two IC2000 sets coupled — it is false at positions 1, 8, 9 and
        // 16: the two outer ends of the whole train as well as the real join in
        // the middle. Read as "no way forward" it puts a barrier across the back
        // of every train, between the last coach and the one before it, where
        // there is nothing but the end of the train and a walk-through that
        // works perfectly well.
        //
        // The short string says the same thing without the ambiguity, because
        // `(` and `)` are distinct there and `FormationShortString` keeps them
        // apart. That is the only source used.

        evn = vehicle.vehicleIdentifier?.evn
        typeName = vehicle.vehicleIdentifier?.typeCodeName

        guard let properties = vehicle.vehicleProperties else { return }
        seatsFirst = properties.number1class
        seatsSecond = properties.number2class
        beds = properties.numberBeds
        bicycleHooks = properties.numberBikeHooks
        lowFloor = properties.lowFloorTrolley
        airConditioned = properties.climated
        length = properties.length
        wheelchairSpaces = properties.accessibilityProperties?.numberWheelchairSpaces
        wheelchairToilet = properties.accessibilityProperties?.wheelchairToilet
        if properties.closed == true { status.insert(.closed) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
