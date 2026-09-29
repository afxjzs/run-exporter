import CoreLocation
import Foundation
import HealthKit
import Observation

/// Runs the watch's workout session and mirrors it to the iPhone (`docs/WATCHOS_RECORDER_PLAN.md`,
/// plan of record).
///
/// The phone decides, the watch records. This type makes no decisions about the workout: it starts
/// the session when told, shows the phase the phone sends, measures what its sensors see, marks each
/// boundary in the workout, and saves or discards when told.
///
/// - `endWorkout` **discards** — the link test screen, and a run abandoned on the phone.
/// - `finishWorkout(executionID:)` **saves** the workout with the GPS route, tagged with the phone's
///   execution id so the phone can join to it by id instead of by start time.
@MainActor
@Observable
final class WatchWorkoutController: NSObject {

    /// One instance, because the app delegate (a phone launch) and the screen (a local start) must
    /// both reach the same session.
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
    private(set) var lastPingAt: Date?
    private(set) var statusesSent = 0
    /// Every failure lands here verbatim, and in the saved event log. Nothing on this path fails
    /// quietly.
    private(set) var lastError: String? {
        didSet {
            if let lastError { WatchEventLog.shared.record("ERROR: \(lastError)") }
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
    /// The GPS route, in words: recording and how many points, or why not.
    private(set) var routeStatus = "off" {
        didSet { WatchEventLog.shared.record("route: \(routeStatus)") }
    }
    private(set) var routePoints = 0
    /// What happened when the workout was saved: its id and the route, or the error.
    private(set) var saveResult: String? {
        didSet { if let saveResult { WatchEventLog.shared.record("save: \(saveResult)") } }
    }

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

    /// Asks for everything a run needs, from the foreground, where a permission sheet can appear.
    /// A launch from the phone may arrive in the background, where a sheet has nowhere to show.
    func prepareHealthAccess() async {
        locationManager.delegate = locationBridge
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        healthAccess = "asking"
        do {
            try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
            healthAccess = "answered"
        } catch {
            healthAccess = "failed"
            lastError = "HealthKit authorization failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Start

    func start(configuration: HKWorkoutConfiguration, origin: WatchWorkoutOrigin) async {
        if origin == .phone {
            launchReceivedAt = Date()
        }
        guard !isRunning else {
            lastError = "Ignored a start from the \(origin.rawValue): a session is already running."
            return
        }
        lastError = nil
        saveResult = nil

        step = "checking Health access"
        let status: HKAuthorizationRequestStatus
        do {
            status = try await store.statusForAuthorizationRequest(toShare: Self.shareTypes, read: Self.readTypes)
        } catch {
            step = "stopped"
            lastError = "Could not check Health access: \(error.localizedDescription)"
            return
        }
        WatchEventLog.shared.record("Health access status at launch: \(status.rawValue) (1 = would prompt, 2 = granted)")
        switch status {
        case .unnecessary:
            break
        case .shouldRequest:
            step = "stopped"
            lastError = "Health access not granted yet. Open RunExporterWatch, allow Health access, "
                + "then start again from the phone."
            return
        case .unknown:
            step = "stopped"
            lastError = "HealthKit could not say whether access has been granted."
            return
        @unknown default:
            step = "stopped"
            lastError = "HealthKit returned an unknown authorization status (\(status.rawValue))."
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
            pace = PaceTracker(start: now)
        } catch {
            step = "stopped"
            lastError = "Could not start the workout session: \(error.localizedDescription)"
            session = nil
            builder = nil
            return
        }

        startRoute()
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
        routePoints = 0
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
                self.routePoints += usable.count
                self.routeStatus = "recording, \(self.routePoints) points"
            } catch {
                self.lastError = "Could not add GPS points to the route: \(error.localizedDescription)"
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

    /// Ends the session and **discards** the workout: the link test, and a run abandoned on the phone.
    func end() {
        guard isRunning, let session, let builder else { return }
        stopRoute()
        routeBuilder?.discard()
        routeBuilder = nil
        openSegment = nil
        stopSession(session, at: Date())
        step = "ended, discarded"
        Task {
            do {
                try await builder.endCollection(at: Date())
                builder.discardWorkout()
            } catch {
                self.lastError = "Ending data collection failed: \(error.localizedDescription)"
            }
        }
        self.session = nil
        self.builder = nil
    }

    /// Ends the session and **saves** the workout with its route, tagged with the phone's execution
    /// id. Every outcome is recorded in `saveResult` and the event log, which reaches the phone.
    func finish(executionID: UUID) {
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
        self.session = nil
        self.builder = nil

        Task {
            do {
                try await builder.endCollection(at: now)
                try await builder.addMetadata([WorkoutMetadataKeys.executionID: executionID.uuidString])
                guard let workout = try await builder.finishWorkout() else {
                    // HKWorkoutBuilder.h: nil with no error means it saved but cannot be read while
                    // the device is locked — and the route needs the workout object to attach to.
                    routeBuilder?.discard()
                    self.saveResult = "saved, but not readable while locked; the GPS route could not be attached"
                    self.step = "saved without route"
                    return
                }
                // No `finishRoute` here. A route builder taken from `seriesBuilder(for:)` is finished
                // BY the workout builder — calling it ourselves failed on 2026-09-29 with "This route
                // builder is attached to a workout builder and will be finished with the workout
                // builder". What this can honestly report is how many points went in; whether they
                // reached Health is checked from the phone, which reads routes for its export.
                let route: String
                if routeBuilder == nil {
                    route = "no route (\(self.routeStatus))"
                } else if self.routePoints == 0 {
                    route = "no GPS points were collected"
                } else {
                    route = "\(self.routePoints) GPS points handed to HealthKit with the workout"
                }
                self.saveResult = "workout \(workout.uuid.uuidString), \(route)"
                self.step = "saved"
            } catch {
                routeBuilder?.discard()
                self.saveResult = "FAILED: \(error.localizedDescription)"
                self.step = "save failed"
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
                    lastPingAt = now
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

    private static func name(for state: HKWorkoutSessionState) -> String {
        switch state {
        case .notStarted: return "not started"
        case .running: return "running"
        case .ended: return "ended"
        case .paused: return "paused"
        case .prepared: return "prepared"
        case .stopped: return "stopped"
        @unknown default: return "unknown (\(state.rawValue))"
        }
    }
}

/// Carries HealthKit's callbacks, which arrive on framework threads, to the main actor. `owner` is
/// written once in `init`, before HealthKit holds the bridge, and every read hops straight back to
/// the main actor — the same reasoning as `SessionDelegateBridge` in `BackgroundExecutionProbe.swift`.
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
