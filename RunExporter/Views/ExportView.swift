import SwiftUI

/// The HealthKit export screen.
///
/// Laid out so Export is on screen as it opens: the range, the button, and Health access only when
/// it still needs granting. Everything adjustable sits in a collapsed Options row whose label says
/// what is set, so a changed setting is visible while folded. The explanations that used to sit
/// under each control are in Settings → About exports.
struct ExportView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults

    @StateObject private var viewModel = ExportViewModel()
    @State private var showOptions = false

    var body: some View {
        Form {
            rangeSection
            exportSection
            permissionSection
            optionsSection
            statusSection
        }
        .navigationTitle("Export Data")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(viewModel.isExporting)
        .onAppear {
            viewModel.attachLogger(store: store, defaults: defaults)
            viewModel.showInitialProblem()
        }
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

    /// What will be exported, in words; the dates themselves when the range is dates.
    @ViewBuilder
    private var rangeSection: some View {
        Section("Exporting") {
            switch viewModel.rangeChoice {
            case .lastWorkouts:
                Text(lastWorkoutsText)
                    .font(.headline)
            case .dates:
                DatePicker("Start", selection: $viewModel.startDate, displayedComponents: .date)
                    .onChange(of: viewModel.startDate) { _, _ in viewModel.persistStartDate() }
                DatePicker("End", selection: $viewModel.endDate,
                           displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    private var lastWorkoutsText: String {
        "Last \(viewModel.lastWorkoutCount) workouts"
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
        } footer: {
            // Granted is one quiet line; anything else gets its own section below.
            if viewModel.isHealthAvailable && viewModel.permissionRequested {
                Label("Health access", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        if !viewModel.isHealthAvailable {
            Section("Health Access") {
                Label("HealthKit not available on this device", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        } else if !viewModel.permissionRequested {
            Section("Health Access") {
                Button {
                    viewModel.requestHealthAccess()
                } label: {
                    Label("Grant Health Access", systemImage: "heart.text.square")
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showOptions) {
                Picker("Range", selection: $viewModel.rangeChoice) {
                    Text("Last workouts").tag(ExportViewModel.RangeChoice.lastWorkouts)
                    Text("Date range").tag(ExportViewModel.RangeChoice.dates)
                }
                .onChange(of: viewModel.rangeChoice) { _, _ in viewModel.persistRange() }
                if viewModel.rangeChoice == .lastWorkouts {
                    Stepper(lastWorkoutsText, value: $viewModel.lastWorkoutCount,
                            in: ExportRange.workoutCountRange)
                        .onChange(of: viewModel.lastWorkoutCount) { _, _ in viewModel.persistRange() }
                }
                Picker("Records", selection: $viewModel.exportMode) {
                    ForEach(ExportMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Include workout weather", isOn: $viewModel.includeWeather)
                Toggle("Include GPS routes", isOn: $viewModel.includeRoutes)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Options")
                    Text(optionsSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// What the folded Options row is set to, so nothing changed hides behind the fold.
    private var optionsSummary: String {
        var parts: [String] = []
        parts.append(viewModel.exportMode.displayName)
        parts.append(viewModel.includeWeather ? "Weather" : "No weather")
        parts.append(viewModel.includeRoutes ? "Routes" : "No routes")
        return parts.joined(separator: " · ")
    }

    /// Only once something has happened; "Ready" told nobody anything.
    @ViewBuilder
    private var statusSection: some View {
        if viewModel.statusMessage != "Ready" {
            Section("Status") {
                Text(viewModel.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    private var errorBinding: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil },
                set: { newValue in if !newValue { viewModel.errorMessage = nil } })
    }
}
