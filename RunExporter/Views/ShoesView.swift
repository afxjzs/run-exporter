import SwiftUI
import SwiftData

/// Shoe profiles and mileage (spec §18).
struct ShoesView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.modelContext) private var context

    @Query(sort: \Shoe.displayName) private var shoes: [Shoe]

    let logger: RunLoggerModel

    @State private var editingShoe: Shoe?
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var shoePendingDeletion: Shoe?

    var body: some View {
        List {
            if shoes.isEmpty {
                Text("No shoes yet.").foregroundStyle(.secondary)
            }

            ForEach(shoes) { shoe in
                Button {
                    editingShoe = shoe
                } label: {
                    shoeRow(shoe)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { shoePendingDeletion = shoe } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { setDefault(shoe) } label: {
                        Label("Default", systemImage: "star")
                    }
                    .tint(.yellow)
                }
            }
        }
        .navigationTitle("Shoes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack { ShoeEditorView(shoe: nil) }
        }
        .sheet(item: $editingShoe) { shoe in
            NavigationStack { ShoeEditorView(shoe: shoe) }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
        // Deleting a shoe silently rewrites derived history: shoe mileage is computed from the run
        // logs assigned to it, so every total that mentioned this shoe changes. That is not
        // something a swipe should be able to do without saying so.
        .alert("Delete this shoe?",
               isPresented: Binding(get: { shoePendingDeletion != nil },
                                    set: { if !$0 { shoePendingDeletion = nil } })) {
            Button("Delete shoe", role: .destructive) {
                if let shoe = shoePendingDeletion { delete(shoe) }
                shoePendingDeletion = nil
            }
            Button("Keep it", role: .cancel) { shoePendingDeletion = nil }
        } message: {
            Text(shoeDeleteMessage)
        }
    }

    /// Built as an annotated `String` rather than inline in a `Text(...)` — see
    /// `PlannedWorkout.deleteConsequenceMessage` for why that shape is avoided in this project.
    private var shoeDeleteMessage: String {
        guard let shoe = shoePendingDeletion else { return "" }
        let name: String = shoe.displayName
        let removed: String = "\"\(name)\" will be removed."
        return removed
            + " The runs you logged with it are kept, but they lose their shoe assignment, so"
            + " mileage totals will change. If you have just stopped wearing it, tap the shoe and"
            + " turn on Retired instead — that keeps the history."
    }

    private func shoeRow(_ shoe: Shoe) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(shoe.displayName).font(.headline)
                if shoe.isDefault {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
                if shoe.isRetired {
                    Text("RETIRED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            Text(String(format: "%.1f mi total", logger.totalMileage(for: shoe)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let first = shoe.firstUseDate {
                Text("First used \(Display.dayFormatter.string(from: first))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setDefault(_ shoe: Shoe) {
        for other in shoes where other.id != shoe.id { other.isDefault = false }
        shoe.isDefault = true
        shoe.updatedAt = Date()
        defaults.defaultShoeID = shoe.id
        if let error = store.save() { errorMessage = error }
    }

    /// Deleting a shoe leaves its run logs intact but unassigned — the runs happened, and losing
    /// them because a shoe was thrown away would be worse than an empty shoe column.
    private func delete(_ shoe: Shoe) {
        let shoeID = shoe.id
        let descriptor = FetchDescriptor<RunLog>(predicate: #Predicate { $0.shoeID == shoeID })
        switch store.fetch(descriptor) {
        case .success(let logs):
            for log in logs { log.shoeID = nil }
        case .failure(let error):
            // Refuse rather than press on. Deleting the shoe when its logs could not be read would
            // leave every one of them pointing at a shoe that no longer exists — and the previous
            // version of this code did exactly that, reporting nothing.
            errorMessage = "Could not read the runs assigned to this shoe, so it was not deleted: "
                + "\(error.message) Nothing was changed."
            return
        }
        if defaults.defaultShoeID == shoeID { defaults.defaultShoeID = nil }
        context.delete(shoe)
        if let error = store.save() { errorMessage = error }
    }
}

struct ShoeEditorView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allShoes: [Shoe]

    let shoe: Shoe?

    @State private var brand = ""
    @State private var model = ""
    @State private var displayName = ""
    @State private var firstUseDate = Date()
    @State private var hasFirstUse = true
    @State private var startingMileage = ""
    @State private var isRetired = false
    @State private var isDefault = false
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Shoe") {
                TextField("Brand", text: $brand)
                TextField("Model", text: $model)
                TextField("Display name", text: $displayName)
                    .onAppear {
                        if displayName.isEmpty {
                            displayName = "\(brand) \(model)"
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
            }

            Section("Use") {
                Toggle("Record first use date", isOn: $hasFirstUse)
                if hasFirstUse {
                    DatePicker("First used", selection: $firstUseDate, displayedComponents: .date)
                }
                TextField("Starting mileage (mi)", text: $startingMileage)
                    .keyboardType(.decimalPad)
                Toggle("Default shoe", isOn: $isDefault)
                Toggle("Retired", isOn: $isRetired)
            }

            Section("Notes") {
                TextField("Optional", text: $notes, axis: .vertical).lineLimit(2...5)
            }
        }
        .navigationTitle(shoe == nil ? "Add Shoe" : "Edit Shoe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!isValid)
            }
        }
        .onAppear(perform: loadOnce)
        .alert("Could not save",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadOnce() {
        guard !didLoad, let shoe else { didLoad = true; return }
        didLoad = true
        brand = shoe.brand
        model = shoe.model
        displayName = shoe.displayName
        if let first = shoe.firstUseDate {
            firstUseDate = first
            hasFirstUse = true
        } else {
            hasFirstUse = false
        }
        startingMileage = shoe.startingMileage == 0 ? "" : String(shoe.startingMileage)
        isRetired = shoe.isRetired
        isDefault = shoe.isDefault
        notes = shoe.notes ?? ""
    }

    private func save() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? "\(brand) \(model)".trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedName

        // An unparseable mileage is rejected rather than silently becoming 0, which would
        // understate the shoe's life.
        var mileage = 0.0
        let trimmedMileage = startingMileage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMileage.isEmpty {
            guard let parsed = Double(trimmedMileage), parsed.isFinite, parsed >= 0 else {
                errorMessage = "\"\(trimmedMileage)\" is not a valid starting mileage. "
                    + "Enter a number of miles, or leave it blank."
                return
            }
            mileage = parsed
        }

        let target: Shoe
        if let shoe {
            target = shoe
        } else {
            target = Shoe(brand: brand, model: model, displayName: resolvedName)
            context.insert(target)
        }

        target.brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        target.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        target.displayName = resolvedName
        target.firstUseDate = hasFirstUse ? firstUseDate : nil
        target.startingMileage = mileage
        target.retiredDate = isRetired ? (target.retiredDate ?? Date()) : nil
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        target.updatedAt = Date()

        if isDefault {
            for other in allShoes where other.id != target.id { other.isDefault = false }
            defaults.defaultShoeID = target.id
        } else if defaults.defaultShoeID == target.id {
            defaults.defaultShoeID = nil
        }
        target.isDefault = isDefault

        if let error = store.save() {
            errorMessage = error
            return
        }
        dismiss()
    }
}
