//
//  RunExporterWatchApp.swift
//  RunExporterWatch Watch App
//
//  Created by Douglas Rogers on 8/8/26.
//

import HealthKit
import SwiftUI
import WatchKit

@main
struct RunExporterWatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate

    init() {
        // First thing on every launch, before any UI — a launch in the background shows up here
        // even if nobody ever opens the app.
        WatchEventLog.shared.record("process started, build \(WatchBuildInfo.label)")
        WatchLogForwarder.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Receives the phone's `HKHealthStore.startWatchApp(toHandle:)`. The system launches or wakes this
/// app and calls `handle(_:)` with the configuration the phone built — watchOS 7+, so legal on the
/// watchOS 10 Series 5 (checked against `WKApplication.h`, see docs/WATCHOS_RECORDER_PLAN.md).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchEventLog.shared.record("didFinishLaunching")
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        // Recorded synchronously, before any await, so the arrival is on disk even if what follows
        // stalls or the app is closed.
        WatchEventLog.shared.record("handle(workoutConfiguration) called, activity \(workoutConfiguration.activityType.rawValue)")
        Task { @MainActor in
            await WatchWorkoutController.shared.start(configuration: workoutConfiguration, origin: .phone)
        }
    }

    /// Called if the app crashed or was closed while a workout session was running.
    func handleActiveWorkoutRecovery() {
        WatchEventLog.shared.record("handleActiveWorkoutRecovery called")
    }
}
