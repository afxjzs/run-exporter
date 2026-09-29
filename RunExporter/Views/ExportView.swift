import SwiftUI

/// The HealthKit export screen.
///
/// This is v1.0's `ContentView`, moved here with its body unchanged so the export flow the user
/// already relies on behaves exactly as before. The only addition is `attachLogger`, which lets
/// the same ZIP carry the subjective columns and files.
struct ExportView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults

    @StateObject private var viewModel = ExportViewModel()

    var body: some View {
        Form {
            dateRangeSection
            exportModeSection
            additionalDataSection
            permissionSection
            exportSection
            statusSection
        }
        .navigationTitle("Export Data")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(viewModel.isExporting)
        .onAppear { viewModel.attachLogger(store: store, defaults: defaults) }
        .sheet(item: $viewModel.shareItem, onDismiss: { viewModel.shareFinished() }) { item in
            ShareSheet(items: [item.url]) {
                viewModel.dismissShare()
            }
        }
        .alert("Something went wrong",
               isPresented: errorBinding,
               actions: { Button("OK", role: .cancel) { viewModel.errorMessage = nil } },
               message: { Text(viewModel.errorMessage ?? "") })
    }

    // MARK: - Sections

    private var dateRangeSection: some View {
        Section("Date Range") {
            DatePicker("Start", selection: $viewModel.startDate, displayedComponents: .date)
                .onChange(of: viewModel.startDate) { _, _ in viewModel.persistStartDate() }
            DatePicker("End", selection: $viewModel.endDate, displayedComponents: [.date, .hourAndMinute])
            Text("End defaults to now each time you open the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var exportModeSection: some View {
        Section("Export Mode") {
            Picker("Mode", selection: $viewModel.exportMode) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Text(viewModel.exportMode == .workoutWindowsOnly
                 ? "Records limited to ±\(ExportMode.workoutWindowBufferMinutes) min around each workout. Smaller export."
                 : "All requested records across the whole date range.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var additionalDataSection: some View {
        Section("Additional Data") {
            Toggle("Include workout weather", isOn: $viewModel.includeWeather)
            Toggle("Include GPS routes", isOn: $viewModel.includeRoutes)
            Toggle("Include walking workouts", isOn: $viewModel.includeWalking)
                .onChange(of: viewModel.includeWalking) { _, _ in
                    viewModel.persistIncludeWalking()
                }
            Text(walkingFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(additionalDataFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var walkingFootnote: String {
        viewModel.includeWalking
            ? "Walking workouts are included everywhere — export, the \"needs a log\" list and "
              + "History. This setting is remembered."
            : "Only running workouts are read, here and in the rest of the app. The export still "
              + "records how many walks were skipped, so a reader can tell filtering from an "
              + "empty week. Note a run/walk session is occasionally recorded as \"Outdoor Walk\" "
              + "— turn this on if one goes missing."
    }

    private var additionalDataFootnote: String {
        switch (viewModel.includeWeather, viewModel.includeRoutes) {
        case (true, true):
            return "Weather comes from the workout's own Health metadata — no internet lookup. "
                 + "Routes come from HealthKit and reveal where you run, so treat the export as sensitive."
        case (true, false):
            return "Weather comes from the workout's own Health metadata — no internet lookup. "
                 + "No GPS route data will be read or written."
        case (false, true):
            return "Weather columns will be blank. Routes come from HealthKit and reveal where "
                 + "you run, so treat the export as sensitive."
        case (false, false):
            return "Weather columns will be blank and no GPS route data will be read or written. "
                 + "The export still records that both were switched off."
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        Section("Health Access") {
            if !viewModel.isHealthAvailable {
                Label("HealthKit not available on this device", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            } else if viewModel.permissionRequested {
                Label("Health Access Granted", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                Text("If some data is missing, re-check permissions in the Health app under Sharing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    viewModel.requestHealthAccess()
                } label: {
                    Label("Grant Health Access", systemImage: "heart.text.square")
                }
            }
        }
    }

    private var exportSection: some View {
        Section {
            Button(action: viewModel.export) {
                HStack {
                    Spacer()
                    if viewModel.isExporting {
                        ProgressView()
                        Text(viewModel.progressText.isEmpty ? "Exporting…" : viewModel.progressText)
                            .padding(.leading, 8)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .disabled(viewModel.isExporting || !viewModel.isHealthAvailable)
        }
    }

    private var statusSection: some View {
        Section("Status") {
            Text(viewModel.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var errorBinding: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil },
                set: { newValue in if !newValue { viewModel.errorMessage = nil } })
    }
}
