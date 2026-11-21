import CleanerCore
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

@MainActor
private struct CleanerView: View {
    @State private var selectedCategories: Set<CleanupCategory> = [.temporaryFiles]
    @State private var plan: CleanupPlan?
    @State private var report: CleanupReport?
    @State private var work: Work?
    @State private var showsConfirmation = false

    private let cleaner = Cleaner()

    var body: some View {
        HStack(spacing: 0) {
            locations
            Divider()
            results
        }
        .frame(minWidth: 720, minHeight: 430)
        .alert("Permanently delete these files?", isPresented: $showsConfirmation, presenting: plan) { approvedPlan in
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Delete Files", role: .destructive) { delete(approvedPlan) }
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
            Button("Scan", action: scan)
                .disabled(selectedCategories.isEmpty || work != nil)
        }
        .padding(20)
        .frame(width: 233, alignment: .leading)
        .background(.regularMaterial)
        .disabled(work != nil)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cleanup Preview")
                .font(.title2.weight(.semibold))
                .padding(20)
            Divider()

            if let work {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(work.rawValue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan, !plan.files.isEmpty {
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
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if let plan, !plan.files.isEmpty {
                        Text("\(itemCount(plan.files.count)) · \(formatBytes(plan.bytes))")
                    }
                    if let plan, plan.unreadableLocations > 0 {
                        Text("Some locations couldn’t be read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Review Deletion…") { showsConfirmation = true }
                    .disabled(work != nil || plan?.files.isEmpty != false)
            }
            .padding(16)
        }
    }

    private var emptyMessage: String {
        if let report {
            let deleted = "Deleted \(itemCount(report.deleted)) (\(formatBytes(report.deletedBytes)))."
            guard report.skipped > 0 else { return deleted }
            return deleted + "\nSkipped \(itemCount(report.skipped)) that changed, disappeared, or couldn’t be removed."
        }
        if plan != nil { return "No eligible files found." }
        return "Select locations and scan to preview files."
    }

    private func selection(for category: CleanupCategory) -> Binding<Bool> {
        Binding {
            selectedCategories.contains(category)
        } set: { selected in
            if selected {
                selectedCategories.insert(category)
            } else {
                selectedCategories.remove(category)
            }
            plan = nil
            report = nil
        }
    }

    private func scan() {
        guard work == nil, !selectedCategories.isEmpty else { return }
        let categories = selectedCategories
        let cleaner = cleaner
        plan = nil
        report = nil
        work = .scanning
        Task {
            plan = await Task.detached(priority: .userInitiated) { cleaner.scan(categories) }.value
            work = nil
        }
    }

    private func delete(_ approvedPlan: CleanupPlan) {
        guard work == nil, !approvedPlan.files.isEmpty else { return }
        let cleaner = cleaner
        plan = nil
        work = .deleting
        Task {
            report = await Task.detached(priority: .userInitiated) { cleaner.clean(approvedPlan) }.value
            work = nil
        }
    }

    private enum Work: String {
        case scanning = "Scanning selected locations…"
        case deleting = "Deleting confirmed files…"
    }
}

private func itemCount(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "file" : "files")"
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
