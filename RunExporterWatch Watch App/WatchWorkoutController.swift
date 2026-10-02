import CoreLocation
import Foundation
import HealthKit
import Observation
import WatchKit

/// Runs the watch's workout session and mirrors it to the iPhone (`docs/WATCHOS_RECORDER_PLAN.md`,
/// plan of record).
///
/// The phone decides, the watch records. This type makes no decisions about the workout: it starts
/// the session when told, shows the phase the phone sends, measures what its sensors see, marks each
/// boundary in the workout, and saves or discards when told.
///
/// - `endWorkout` **discards** — a run abandoned on the phone.
/// - `finishWorkout(executionID:)` **saves** the workout with the GPS route, tagged with the phone's
///   execution id so the phone can join to it by id instead of by start time — or untagged when the
///   phone has no id, and it joins by start time.
@MainActor
@Observable
final class WatchWorkoutController: NSObject {

    /// One instance, because the app delegate (a phone launch) and the screens (which show and can
    /// end the session) must both reach the same session.
    static let shared = WatchWorkoutController()

    private static let statusInterval: TimeInterval = 5


    // MARK: - Observable state, all of it shown on the watch

    private(set) var isRunning = false
    private(set) var origin: WatchWorkoutOrigin?
    private(set) var startedAt: Date?
    private(set) var sessionState = "not started"
    private(set) var mirroring = "not started" {
        didSet { WatchEventLog.shared.record("iPhone link: \(mirroring)") }
    }
    private(set) var heartRate: Double?
    private(set) var pingsAnswered = 0
    private(set) var statusesSent = 0
    /// Every failure lands here verbatim, and in the saved event log. Nothing on this path fails
    /// quietly.
    private(set) var lastError: String? {
        didSet {
            if let lastError {
                WatchEventLog.shared.record("\(WatchLogMarkers.errorPrefix)\(lastError)")
            }
        }
    }

    /// When the phone's `startWatchApp` last reached this app's code — set before anything else can
    /// fail, so "never arrived" and "arrived and stalled" are told apart.
    private(set) var launchReceivedAt: Date?
    /// The last thing `start` got to.
    private(set) var step = "idle" {
        didSet { WatchEventLog.shared.record("step: \(step)") }
    }
    private(set) var healthAccess = "not asked yet" {
        didSet { WatchEventLog.shared.record("Health access request: \(healthAccess)") }
    }

    /// The phase the phone last sent, on this watch's clock. Nil until the first arrives.
    private(set) var phaseClock: PhaseClock?
    /// Leg pace, current mile split and total distance, from this watch's distance readings.
    private(set) var pace = PaceTracker(start: Date())
    /// The GPS route, in words: whether it is recording, or why not.
    ///
    /// Every assignment logs, so assign only when the answer changes kind — see the note where
    /// points arrive.
    private(set) var routeStatus = "off" {
        didSet { WatchEventLog.shared.record("route: \(routeStatus)") }
    }
    /// What happened to this run's GPS points: stored, and refused. Not observed: it is read only
    /// inside this type, to build the save line. Observed, it redrew the watch on every GPS batch.
    @ObservationIgnored private var routeTally = RouteTally()
    /// The Health sheet in flight, so a second ask waits on it instead of raising another.
    @ObservationIgnored private var accessRequest: Task<Void, Never>?
    /// What happened when the workout was saved: its id and the route, or the error.
    private(set) var saveResult: String? {
        didSet { if let saveResult { WatchEventLog.shared.record("save: \(saveResult)") } }
    }

    /// How the session ended, for the run screen. Nil while a session runs.
    enum Outcome: Equatable {
        case saving, saved, savedWithoutRoute, savedWithIncompleteRoute, notSaved, discarded
    }
    private(set) var outcome: Outcome?
    /// When the session stopped. The run screen freezes its clock here: after the first real outdoor
    /// run the screen kept counting the open cooldown up after the save, and read as a workout still
    /// going.
    private(set) var endedAt: Date?

    /// One list, used both when asking up front and when checking at launch, so the two cannot
    /// drift apart — the first link test stalled when the link asked for a type the probe never had.
    /// `workoutRoute` is shared so the GPS route can be saved with the workout.
    private static let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.heartRate),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
    ]

    /// Location points worse than this are left out of the route; they zigzag and inflate distance.
    private static let maximumRouteAccuracyMeters = 50.0

    // MARK: - Machinery

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private let locationManager = CLLocationManager()
    /// The phase segment in progress, closed into a workout event at the next boundary.
    @ObservationIgnored private var openSegment: (phase: WatchPhase, start: Date)?
    @ObservationIgnored private lazy var bridge = WatchSessionBridge(owner: self)
    @ObservationIgnored private lazy var locationBridge = WatchLocationBridge(owner: self)

    // MARK: - Permissions

    /// Asks for whatever is unanswered, every time the app comes on screen — where a permission
    /// sheet can appear. A launch from the phone may arrive in the background, where it cannot.
    ///
    /// Called on every activation, not once per process: a Watch reinstall resets Health access,
    /// and a process that first started in the background had already spent its one ask where no
    /// sheet could show.
    func prepareHealthAccess() async {
        locationManager.delegate = locationBridge
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        guard let access = await readHealthAccess() else { return }
        if access.shouldAskOnScreen {
            await askForHealthAccess()
        } else {
            healthAccess = Self.describe(access)
        }
    }

    /// Both of HealthKit's answers, or nil after reporting why they could not be read.
    private func readHealthAccess() async -> WatchHealthAccess? {
        let request: WatchHealthAccess.Request
        do {
            switch try await store.statusForAuthorizationRequest(toShare: Self.shareTypes, read: Self.readTypes) {
            case .shouldRequest: request = .unanswered
            case .unnecessary: request = .answered
            case .unknown: request = .unknown
            @unknown default: request = .unknown
            }
        } catch {
            healthAccess = "failed"
            lastError = "Could not check Health access: \(error.localizedDescription)"
            return nil
        }
        let access = WatchHealthAccess(request: request,
                                       workouts: sharing(HKObjectType.workoutType()),
                                       routes: sharing(HKSeriesType.workoutRoute()))
        WatchEventLog.shared.record(access.logLine)
        return access
    }

    private func sharing(_ type: HKObjectType) -> WatchHealthAccess.Sharing {
        switch store.authorizationStatus(for: type) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Shows the Health sheet. One request at a time: the screen and a phone launch can both want
    /// to ask, and the second waits on the first rather than raising another sheet.
    private func askForHealthAccess() async {
        if let accessRequest { return await accessRequest.value }
        let request = Task { @MainActor in
            healthAccess = "asking"
            do {
                try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
                if let access = await readHealthAccess() { healthAccess = Self.describe(access) }
            } catch {
                healthAccess = "failed"
                lastError = "HealthKit authorization failed: \(error.localizedDescription)"
            }
        }
        accessRequest = request
        await request.value
        accessRequest = nil
    }

    /// The idle screen's one-word answer. "answered" alone said nothing about a route left off.
    private static func describe(_ access: WatchHealthAccess) -> String {
        switch access.request {
        case .unknown: return "could not be checked"
        case .unanswered: return "not granted yet"
        case .answered:
            switch access.launchDecision(canShowSheet: false) {
            case .start: return "granted"
            case .startWithoutRoute: return "granted, but Workout Routes is off"
            case .stop, .ask: return "Workouts is off"
            }
        }
    }

    // MARK: - Start

    func start(configuration: HKWorkoutConfiguration, origin: WatchWorkoutOrigin) async {
        // Every start is a phone launch — the watch's own screens never start a session.
        launchReceivedAt = Date()
        guard !isRunning else {
            lastError = "Ignored a start from the \(origin.rawValue): a session is already running."
            return
        }
        lastError = nil
        saveResult = nil

        step = "checking Health access"
        guard var access = await readHealthAccess() else {
            step = "stopped"
            return
        }
        var decision = access.launchDecision(canShowSheet: WKApplication.shared().applicationState == .active)
        if decision == .ask {
            // The screen is on, so the sheet can appear here rather than stopping the launch. The
            // phone accepts the session even after its 15 s timeout (`WatchLink.attach`), so taking
            // longer than that to tap Allow does not lose the run.
            step = "asking for Health access"
            await askForHealthAccess()
            guard let answered = await readHealthAccess() else {
                step = "stopped"
                return
            }
            access = answered
            // Never ask twice: a dismissed sheet stops the launch.
            decision = access.launchDecision(canShowSheet: false)
        }
        let recordRoute: Bool
        switch decision {
        case .start:
            recordRoute = true
        case .startWithoutRoute(let reason):
            recordRoute = false
            routeStatus = "no GPS route: \(reason)"
        case .stop(let reason):
            step = "stopped"
            lastError = reason
            return
        case .ask:
            // Unreachable: the second decision cannot show a sheet. Stopped and said, not assumed.
            step = "stopped"
            lastError = "Health access is still unanswered after asking. Open RunExporterWatch and allow it."
            return
        }

        step = "starting session"
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                         workoutConfiguration: configuration)
            session.delegate = bridge
            builder.delegate = bridge
            self.session = session
            self.builder = builder

            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)

            self.origin = origin
            startedAt = now
            isRunning = true
            sessionState = "running"
            pingsAnswered = 0
            statusesSent = 0
            heartRate = nil
            phaseClock = nil
            openSegment = nil
            outcome = nil
            endedAt = nil
            pace = PaceTracker(start: now)
            // Here, not in `startRoute`: a run that records no route still needs a fresh tally, or
            // it would report the last run's points as its own.
            routeTally = RouteTally()
        } catch {
            step = "stopped"
            lastError = "Could not start the workout session: \(error.localizedDescription)"
            session = nil
            builder = nil
            return
        }

        if recordRoute { startRoute() }
        step = "connecting to iPhone"
        await startMirroring()
    }

    /// A failure here leaves the workout running — it is still a valid local session — but the
    /// screen says plainly that the phone is not connected.
    private func startMirroring() async {
        guard let session else { return }
        mirroring = "connecting…"
        do {
            try await session.startMirroringToCompanionDevice()
            mirroring = "connected"
            step = "running"
            startStatusTimer()
            sendStatus()
        } catch {
            mirroring = "failed"
            step = "running, not connected"
            lastError = "Could not mirror to the iPhone: \(error.localizedDescription)"
        }
    }

    // MARK: - GPS route

    /// Location updates continue while the workout session keeps this app running (stage 2
    /// measured that it does). `allowsBackgroundLocationUpdates` is deliberately NOT set: without the
    /// "location" background mode, CLLocationManager.h calls setting it "a fatal error".
    private func startRoute() {
        guard let builder else { return }
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .notDetermined:
            routeStatus = "no GPS: location permission not asked yet — open the app once"
            return
        case .denied, .restricted:
            routeStatus = "no GPS: location access is off for this app"
            return
        @unknown default:
            routeStatus = "no GPS: unknown location permission (\(locationManager.authorizationStatus.rawValue))"
            return
        }
        guard let routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder else {
            routeStatus = "no GPS: HealthKit gave no route builder"
            return
        }
        self.routeBuilder = routeBuilder
        locationManager.delegate = locationBridge
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.startUpdatingLocation()
        routeStatus = "waiting for GPS"
    }

    private func stopRoute() {
        locationManager.stopUpdatingLocation()
    }

    fileprivate func locationsArrived(_ locations: [CLLocation]) {
        guard isRunning, let routeBuilder else { return }
        let usable = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= Self.maximumRouteAccuracyMeters
        }
        guard !usable.isEmpty else { return }
        Task {
            do {
                try await routeBuilder.insertRouteData(usable)
                self.routeTally.recordInserted(usable.count)
                // Set once, when recording starts — not on every batch. `routeStatus` has one
                // reader, `WatchRunView`, and it draws the string only when it does NOT begin
                // "recording", so the count in it was never shown to anyone; the tally is what
                // the save line reports. Assigning here ran this property's `didSet` at roughly
                // 1 Hz, and that `didSet` writes the whole log array to UserDefaults and queues one
                // `WCSession.transferUserInfo` per line — on the order of 1,800 of each in a
                // half-hour run, on a Series 5 that is also recording the workout.
                if !self.routeStatus.hasPrefix("recording") { self.routeStatus = "recording" }
            } catch {
                // The same cost as above, on the failure path: a refusal is usually every batch.
                // The first is logged and shown; the rest are counted and reported at the save.
                if let first = self.routeTally.recordRefusal(error.localizedDescription) {
                    self.lastError = "Could not add GPS points to the route: \(first). "
                        + "Further refusals are counted, not logged."
                    self.routeStatus = "GPS points refused by HealthKit: \(first)"
                }
            }
        }
    }

    fileprivate func locationFailed(_ message: String) {
        routeStatus = "GPS error: \(message)"
    }

    fileprivate func locationAuthorizationChanged(_ status: CLAuthorizationStatus) {
        WatchEventLog.shared.record("location permission: \(status.rawValue)")
    }

    // MARK: - Phases from the phone

    private func handlePhase(_ anchor: PhaseAnchor) {
        let clock = PhaseClock(anchor: anchor, receivedAt: Date())
        let previous = phaseClock?.anchor
        phaseClock = clock

        // A boundary is a different phase or leg. Re-sends of the same phase — on connect, a pause
        // toggling — are not, and must not split a segment. (Restarting a phase in place is not
        // detected as a boundary: a known, rare gap.)
        let isBoundary = previous.map { $0.phase != anchor.phase || $0.legNumber != anchor.legNumber } ?? true
        if isBoundary {
            let start = clock.phaseStartedAt
            closeSegment(at: start)
            openSegment = (anchor.phase, start)
            if anchor.phase == .run {
                pace.beginLeg(at: start)
            }
            WatchEventLog.shared.record("phase: \(anchor.phase.rawValue)"
                + (anchor.legNumber.map { " leg \($0)" } ?? ""))
        }

        // The phone's pause is the workout's pause, so a stop is not recorded as running time.
        if let session {
            if anchor.isPaused, session.state == .running {
                session.pause()
            } else if !anchor.isPaused, session.state == .paused {
                session.resume()
            }
        }
    }

    /// Writes the phase segment in progress into the workout, ending at `end`.
    private func closeSegment(at end: Date) {
        guard let segment = openSegment, let builder else { return }
        openSegment = nil
        guard end > segment.start else { return }
        let event = HKWorkoutEvent(type: .segment,
                                   dateInterval: DateInterval(start: segment.start, end: end),
                                   metadata: [WorkoutMetadataKeys.phase: segment.phase.rawValue])
        Task {
            do {
                try await builder.addWorkoutEvents([event])
            } catch {
                self.lastError = "Could not mark the \(segment.phase.rawValue) phase in the workout: "
                    + error.localizedDescription
            }
        }
    }

    // MARK: - End

    /// Ends the session and **discards** the workout: a run abandoned on the phone, or End on the
    /// watch's own link screen.
    func end() {
        guard isRunning, let session, let builder else {
            // Not an error — the phone can ask twice, or ask after the watch has already finished.
            // Logged rather than dropped, because "the phone said end and nothing happened" is
            // otherwise invisible from either side. Same reasoning as the skipped-launch line in
            // `WatchLink.launchWatchWorkout`.
            WatchEventLog.shared.record("endWorkout ignored: no session is running")
            return
        }
        stopRoute()
        routeBuilder?.discard()
        routeBuilder = nil
        openSegment = nil
        // One moment, read once. `finish(executionID:)` already does this; here the two `Date()`
        // calls sat either side of a `Task` boundary, so the second was read whenever that ran.
        // The workout is discarded, so nothing reached Health either way — but two clocks for one
        // event is how a later reader learns the wrong lesson from this code.
        let now = Date()
        stopSession(session, at: now)
        step = "ended, discarded"
        outcome = .discarded
        Task {
            do {
                try await builder.endCollection(at: now)
                builder.discardWorkout()
            } catch {
                self.lastError = "Ending data collection failed: \(error.localizedDescription)"
            }
        }
        self.session = nil
        self.builder = nil
    }

    /// Ends the session and **saves** the workout with its route, tagged with the phone's execution
    /// id when the phone has one; untagged otherwise, and the phone joins it by start time. Every
    /// outcome is recorded in `saveResult` and the event log, which reaches the phone.
    func finish(executionID: UUID?) {
        guard isRunning, let session, let builder else {
            lastError = "Asked to save a workout, but none is running."
            return
        }
        let now = Date()
        closeSegment(at: now)
        stopRoute()
        let routeBuilder = self.routeBuilder
        self.routeBuilder = nil
        stopSession(session, at: now)
        step = "saving"
        outcome = .saving
        self.session = nil
        self.builder = nil

        Task {
            do {
                try await builder.endCollection(at: now)
                if let executionID {
                    try await builder.addMetadata([WorkoutMetadataKeys.executionID: executionID.uuidString])
                }
                guard let workout = try await builder.finishWorkout() else {
                    // HKWorkoutBuilder.h: nil with no error means it saved but cannot be read while
                    // the device is locked — and the route needs the workout object to attach to.
                    routeBuilder?.discard()
                    self.saveResult = "saved, but not readable while locked; the GPS route could not be attached"
                    self.step = "saved without route"
                    self.outcome = .savedWithoutRoute
                    return
                }
                // No `finishRoute` here. A route builder taken from `seriesBuilder(for:)` is finished
                // BY the workout builder — calling it ourselves failed on 2026-09-29 with "This route
                // builder is attached to a workout builder and will be finished with the workout
                // builder". What this can honestly report is how many points went in; whether they
                // reached Health is checked from the phone, which reads routes for its export.
                //
                // Every route short of complete is an orange outcome. "No GPS points were collected"
                // once drew as a clean save while HealthKit had refused every point of the run.
                let tally = self.routeTally
                let refused = tally.firstRefusal.map {
                    ", \(tally.refusedBatches) batch(es) refused by HealthKit (\($0))"
                } ?? ""
                let route: String
                let outcome: Outcome
                if routeBuilder == nil {
                    route = "no route (\(self.routeStatus))"
                    outcome = .savedWithoutRoute
                } else {
                    switch tally.result {
                    case .none:
                        route = "no GPS points stored\(refused)"
                        outcome = .savedWithoutRoute
                    case .incomplete:
                        route = "\(tally.pointsInserted) GPS points stored\(refused): the route has gaps"
                        outcome = .savedWithIncompleteRoute
                    case .complete:
                        route = "\(tally.pointsInserted) GPS points handed to HealthKit with the workout"
                        outcome = .saved
                    }
                }
                let tag = executionID == nil ? ", untagged (the phone had no execution id)" : ""
                self.saveResult = "workout \(workout.uuid.uuidString)\(tag), \(route)"
                self.step = "saved"
                self.outcome = outcome
            } catch {
                routeBuilder?.discard()
                self.saveResult = "FAILED: \(error.localizedDescription)"
                self.step = "save failed"
                self.outcome = .notSaved
                self.lastError = "Saving the workout failed: \(error.localizedDescription)"
            }
        }
    }

    private func stopSession(_ session: HKWorkoutSession, at date: Date) {
        statusTimer?.invalidate()
        statusTimer = nil
        session.stopActivity(with: date)
        session.end()
        isRunning = false
        endedAt = date
    }

    // MARK: - Talking to the phone

    private func startStatusTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.statusInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func sendStatus() {
        guard let startedAt, let origin else { return }
        send(.status(WatchStatus(sentAt: Date(), sessionStartedAt: startedAt,
                                 heartRate: heartRate, origin: origin))) { [weak self] in
            self?.statusesSent += 1
        }
    }

    private func send(_ message: WatchLinkMessage, onSent: (() -> Void)? = nil) {
        guard let session else { return }
        let data: Data
        do {
            data = try WatchLinkCodec.encode(message)
        } catch {
            lastError = "Could not encode a message for the phone: \(error.localizedDescription)"
            return
        }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
                onSent?()
            } catch {
                self.lastError = "Sending to the phone failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Callbacks, already on the main actor

    fileprivate func received(_ batch: [Data]) {
        for data in batch {
            do {
                switch try WatchLinkCodec.decode(data) {
                case let .ping(id, _):
                    let now = Date()
                    pingsAnswered += 1
                    send(.pong(id: id, watchReceivedAt: now))
                case .endWorkout:
                    end()
                case let .phaseBegan(anchor):
                    handlePhase(anchor)
                case let .finishWorkout(executionID):
                    finish(executionID: executionID)
                case .pong, .status:
                    lastError = "The phone sent a message only the watch should send."
                }
            } catch {
                lastError = "Could not read a message from the phone: \(error.localizedDescription)"
            }
        }
    }

    fileprivate func sessionChanged(to state: HKWorkoutSessionState) {
        sessionState = Self.name(for: state)
        WatchEventLog.shared.record("session: \(sessionState)")
        if state == .ended && isRunning {
            lastError = "The system ended the workout session."
            end()
        }
    }

    fileprivate func sessionFailed(_ error: Error) {
        lastError = "Workout session failed: \(error.localizedDescription)"
        sessionState = "failed"
    }

    fileprivate func mirroringDisconnected(_ error: Error?) {
        mirroring = "disconnected"
        statusTimer?.invalidate()
        statusTimer = nil
        if let error {
            lastError = "Lost the iPhone: \(error.localizedDescription)"
        }
    }

    fileprivate func heartRateUpdated(_ bpm: Double) {
        heartRate = bpm
    }

    fileprivate func distanceUpdated(totalMeters: Double, at date: Date) {
        let rejectedBefore = pace.rejectedReadings
        pace.record(totalMeters: totalMeters, at: date)
        if pace.rejectedReadings > rejectedBefore {
            WatchEventLog.shared.record("distance reading went backwards and was ignored (\(pace.rejectedReadings) so far)")
        }
    }

    /// Shared with the phone, so both devices' logs spell a state the same way.
    private static func name(for state: HKWorkoutSessionState) -> String {
        WatchLogMarkers.name(for: state)
    }
}

/// Carries HealthKit's callbacks, which arrive on framework threads, to the main actor. `owner` is
/// written once in `init`, before HealthKit holds the bridge, and every read hops straight back to
/// the main actor. (The stage 2 probe used the same pattern; it was removed in the 2026-09-29
/// clean-out.)
private final class WatchSessionBridge: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated(unsafe) private weak var owner: WatchWorkoutController?

    init(owner: WatchWorkoutController) {
        self.owner = owner
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor [weak owner] in owner?.sessionChanged(to: toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.sessionFailed(error) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor [weak owner] in owner?.received(data) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor [weak owner] in owner?.mirroringDisconnected(error) }
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Read here, on HealthKit's thread, so only plain values cross to the main actor.
        let heartRateType = HKQuantityType(.heartRate)
        if collectedTypes.contains(heartRateType),
           let quantity = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity() {
            let bpm = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
            Task { @MainActor [weak owner] in owner?.heartRateUpdated(bpm) }
        }
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        if collectedTypes.contains(distanceType),
           let statistics = workoutBuilder.statistics(for: distanceType),
           let sum = statistics.sumQuantity() {
            let meters = sum.doubleValue(for: .meter())
            let date = statistics.endDate
            Task { @MainActor [weak owner] in owner?.distanceUpdated(totalMeters: meters, at: date) }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

/// Carries Core Location's callbacks to the main actor. Same pattern as `WatchSessionBridge`.
private final class WatchLocationBridge: NSObject, CLLocationManagerDelegate {
    nonisolated(unsafe) private weak var owner: WatchWorkoutController?

    init(owner: WatchWorkoutController) {
        self.owner = owner
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak owner] in owner?.locationsArrived(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak owner] in owner?.locationFailed(message) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak owner] in owner?.locationAuthorizationChanged(status) }
    }
}
