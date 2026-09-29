import SwiftUI

/// Root of the app.
///
/// v1.0's single export form now lives in `ExportView`, unchanged, reachable from Today and from
/// Settings. The tabs around it are the v1.1 planner and logger.
struct ContentView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults

    @Binding var seedError: String?

    @State private var logger: RunLoggerModel?

    var body: some View {
        TabView {
            NavigationStack {
                if let logger {
                    HomeView(logger: logger)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Today", systemImage: "figure.run") }

            NavigationStack {
                if let logger {
                    PlannedWorkoutListView(logger: logger)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Plans", systemImage: "list.bullet.rectangle") }

            NavigationStack {
                if let logger {
                    HistoryView(logger: logger)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("History", systemImage: "calendar") }

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            if logger == nil {
                logger = RunLoggerModel(store: store, defaults: defaults)
            }
        }
        // The logger database failing to open, or first-run seeding failing, would otherwise be
        // invisible — the app would just quietly have no shoes and no saved logs.
        .alert("Run logger unavailable",
               isPresented: .constant(store.containerError != nil),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(store.containerError ?? "") })
        .alert("Setup problem",
               isPresented: Binding(get: { seedError != nil },
                                    set: { if !$0 { seedError = nil } }),
               actions: { Button("OK", role: .cancel) { seedError = nil } },
               message: { Text(seedError ?? "") })
    }
}
