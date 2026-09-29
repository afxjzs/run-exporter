import SwiftUI

@main
struct RunExporterApp: App {

    /// Created once for the app's lifetime and shared through the environment.
    @State private var store = LoggerStore()
    @State private var defaults = LoggerDefaults()
    @State private var audio = AudioCueEngine()
    /// Created with the app, not with a screen: it installs HealthKit's mirroring handler, which
    /// must be in place before the watch can hand this app its session.
    @State private var watchLink = WatchLink()

    /// A problem from first-run seeding. Shown rather than dropped — a failed seed means the
    /// default shoe silently would not exist.
    @State private var seedError: String?

    var body: some Scene {
        WindowGroup {
            ContentView(seedError: $seedError)
                .environment(store)
                .environment(defaults)
                .environment(audio)
                .environment(watchLink)
                .modelContainerIfAvailable(store)
                .task {
                    seedError = SeedInstallData.seedIfNeeded(store: store, defaults: defaults)
                    // At launch, not before starting a workout: a card stranded by the app being
                    // killed mid-run would otherwise sit on the Lock Screen with a clock that
                    // never stops. Doing this next to a workout start races it.
                    LiveActivityController().endActivitiesFromPreviousLaunch()
                }
        }
    }
}

private extension View {
    /// Attaches the store's container when there is one.
    ///
    /// `.modelContainer(_:)` cannot take an optional, and the app deliberately keeps running with
    /// no container so the pre-existing HealthKit export still works when the logger database
    /// fails to open.
    @ViewBuilder
    func modelContainerIfAvailable(_ store: LoggerStore) -> some View {
        if let container = store.container {
            self.modelContainer(container)
        } else {
            self
        }
    }
}
