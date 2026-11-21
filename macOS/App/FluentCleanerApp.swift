import CleanerCore
import Combine
import Foundation
import SwiftUI

@main
@MainActor
struct FluentCleanerApp: App {
    var body: some Scene {
        Window("FluentCleaner", id: "cleaner") {
            CleanerView()
        }
        .defaultSize(width: 940, height: 620)
    }
}

// Use ObservableObject + @StateObject instead of @State: in the macOS 27 SDK,
// @State is a SwiftUIMacros macro whose plugin ships only with full Xcode and
// is unavailable in standalone Command Line Tools.
@MainActor
private final class CleanerViewModel: ObservableObject {
    @Published var selectedCategories: Set<CleanupCategory> = [.temporaryFiles]
    @Published var plan: CleanupPlan?
    @Published var report: CleanupReport?
    @Published var work: Work?
    @Published var showsConfirmation = false

    private let cleaner = Cleaner()

    var emptyMessage: String {
        if let report {
            let deleted = "Deleted \(itemCount(report.deleted)) (\(formatBytes(report.deletedBytes)))."
            guard report.skipped > 0 else { return deleted }
            return deleted + "\nSkipped \(itemCount(report.skipped)) that changed, disappeared, or couldn’t be removed."
        }
        if plan != nil { return "No eligible files found." }
        return "Select locations and scan to preview files."
    }

    func setSelected(_ selected: Bool, for category: CleanupCategory) {
        if selected {
            selectedCategories.insert(category)
        } else {
            selectedCategories.remove(category)
        }
        plan = nil
        report = nil
    }

    func scan() {
        guard work == nil, !selectedCategories.isEmpty else { return }
        let categories = selectedCategories
        let cleaner = self.cleaner
        plan = nil
        report = nil
        work = .scanning
        Task {
            self.plan = await Task.detached(priority: .userInitiated) { cleaner.scan(categories) }.value
            self.work = nil
        }
    }

    func delete(_ approvedPlan: CleanupPlan) {
        guard work == nil, !approvedPlan.files.isEmpty else { return }
        let cleaner = self.cleaner
        plan = nil
        work = .deleting
        Task {
            self.report = await Task.detached(priority: .userInitiated) { cleaner.clean(approvedPlan) }.value
            self.work = nil
        }
    }

    enum Work: String {
        case scanning = "Scanning selected locations…"
        case deleting = "Deleting confirmed files…"
    }
}

@MainActor
private struct CleanerView: View {
    @StateObject private var model = CleanerViewModel()

    var body: some View {
        HStack(spacing: 0) {
            locations
            Divider()
            results
        }
        .frame(minWidth: 720, minHeight: 430)
        .alert("Permanently delete these files?", isPresented: $model.showsConfirmation, presenting: model.plan) { approvedPlan in
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Delete Files", role: .destructive) { model.delete(approvedPlan) }
        } message: { approvedPlan in
            Text("\(itemCount(approvedPlan.files.count)) (\(formatBytes(approvedPlan.bytes))) from the scan will be permanently deleted. This can’t be undone.")
        }
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cleanup Locations")
                .font(.headline)

            ForEach(CleanupCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(category.rawValue, isOn: selection(for: category))
                    Text("Last modified over \(category.minimumAgeInDays) days ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }

            Spacer()
            Button("Scan") { model.scan() }
                .disabled(model.selectedCategories.isEmpty || model.work != nil)
        }
        .padding(20)
        .frame(width: 233, alignment: .leading)
        .background(.regularMaterial)
        .disabled(model.work != nil)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cleanup Preview")
                .font(.title2.weight(.semibold))
                .padding(20)
            Divider()

            if let work = model.work {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(work.rawValue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.plan, !plan.files.isEmpty {
                Table(plan.files) {
                    TableColumn("Path") { file in
                        Text(file.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.path)
                    }
                    TableColumn("Category") { file in
                        Text(file.category.rawValue)
                    }
                    .width(125)
                    TableColumn("Size") { file in
                        Text(formatBytes(file.bytes))
                            .monospacedDigit()
                    }
                    .width(80)
                }
            } else {
                Text(model.emptyMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if let plan = model.plan, !plan.files.isEmpty {
                        Text("\(itemCount(plan.files.count)) · \(formatBytes(plan.bytes))")
                    }
                    if let plan = model.plan, plan.unreadableLocations > 0 {
                        Text("Some locations couldn’t be read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Review Deletion…") { model.showsConfirmation = true }
                    .disabled(model.work != nil || model.plan?.files.isEmpty != false)
            }
            .padding(16)
        }
    }

    private func selection(for category: CleanupCategory) -> Binding<Bool> {
        let model = model
        return Binding {
            model.selectedCategories.contains(category)
        } set: { selected in
            model.setSelected(selected, for: category)
        }
    }
}

private func itemCount(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "file" : "files")"
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
