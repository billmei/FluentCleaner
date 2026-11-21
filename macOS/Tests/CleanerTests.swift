import Foundation
import XCTest
@testable import CleanerCore

final class CleanerTests: XCTestCase {
    private let manager = FileManager.default
    private let now = Date()
    private var workspace: URL!
    private var temporary: URL!
    private var caches: URL!
    private var reports: URL!
    private var cleaner: Cleaner!

    override func setUpWithError() throws {
        workspace = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FluentCleanerTests-\(UUID().uuidString)")
        temporary = workspace.appendingPathComponent("temporary")
        caches = workspace.appendingPathComponent("caches")
        reports = workspace.appendingPathComponent("reports")
        let directories: [URL] = [temporary, caches, reports]
        for directory in directories {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        cleaner = Cleaner(roots: [
            .temporaryFiles: temporary.path, .applicationCaches: caches.path, .diagnosticReports: reports.path,
        ])
    }

    override func tearDownWithError() throws {
        if let workspace { try manager.removeItem(at: workspace) }
    }

    func testScanIsReadOnlyAndUsesSelectedCategoriesAndAgeLimits() throws {
        let oldTemp = try writeFile("nested/.old.tmp", under: temporary, age: 8)
        let recentTemp = try writeFile("recent.tmp", under: temporary, age: 6)
        let oldCache = try writeFile("old.cache", under: caches, age: 31)
        let recentCache = try writeFile("recent.cache", under: caches, age: 29)
        let oldReport = try writeFile("old.ips", under: reports, age: 31)
        let recentReport = try writeFile("recent.ips", under: reports, age: 29)

        XCTAssertTrue(cleaner.scan([], now: now).files.isEmpty)
        let plan = cleaner.scan([.temporaryFiles, .diagnosticReports], now: now)
        XCTAssertEqual(plan.unreadableLocations, 0)
        XCTAssertEqual(Set(plan.files.map(\.path)), [oldTemp.path, oldReport.path])
        XCTAssertEqual(plan.bytes, 8)
        for file in [oldTemp, recentTemp, oldCache, recentCache, oldReport, recentReport] {
            XCTAssertTrue(manager.fileExists(atPath: file.path))
        }
        let cachePlan = cleaner.scan([.applicationCaches], now: now)
        XCTAssertEqual(cachePlan.files.map(\.path), [oldCache.path])
    }

    func testCleanupOnlyDeletesUnchangedFilesFromThePreview() throws {
        let unchanged = try writeFile("unchanged.tmp", under: temporary, age: 9)
        let changed = try writeFile("changed.tmp", under: temporary, age: 9)
        let replacement = try writeFile("replacement.tmp", under: temporary, age: 9)
        let missing = try writeFile("missing.tmp", under: temporary, age: 9)
        let plan = cleaner.scan([.temporaryFiles], now: now)
        XCTAssertEqual(plan.files.count, 4)

        try Data("edited".utf8).write(to: changed)
        try manager.removeItem(at: replacement)
        try writeFile("replacement.tmp", under: temporary, age: 9)
        try manager.removeItem(at: missing)
        let new = try writeFile("new.tmp", under: temporary, age: 9)

        let result = cleaner.clean(plan)
        XCTAssertEqual(result.deleted, 1)
        XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(result.deletedBytes, 4)
        XCTAssertFalse(manager.fileExists(atPath: unchanged.path))
        for file in [changed, replacement, new] {
            XCTAssertTrue(manager.fileExists(atPath: file.path))
        }
        XCTAssertEqual(cleaner.clean(plan).deleted, 0)
    }

    func testScanSkipsSymbolicLinksAndHardLinks() throws {
        let outside = try writeFile("outside/keep.tmp", under: workspace, age: 45)
        try manager.createSymbolicLink(at: temporary.appendingPathComponent("file-link"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: temporary.appendingPathComponent("dir-link"),
                                       withDestinationURL: outside.deletingLastPathComponent())
        try manager.linkItem(at: outside, to: temporary.appendingPathComponent("hard-link"))

        let plan = cleaner.scan([.temporaryFiles], now: now)
        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertTrue(manager.fileExists(atPath: outside.path))
    }

    func testScanRejectsASymbolicLinkInTheRootPath() throws {
        let outside = try writeFile("outside/subdirectory/keep.tmp", under: workspace, age: 45)
        let link = temporary.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: workspace.appendingPathComponent("outside"))
        let aliasedRoot = Cleaner(roots: [.temporaryFiles: link.appendingPathComponent("subdirectory").path])

        let plan = aliasedRoot.scan([.temporaryFiles], now: now)
        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertEqual(plan.unreadableLocations, 1)
        XCTAssertTrue(manager.fileExists(atPath: outside.path))
    }

    func testCleanupDoesNotFollowAnAncestorReplacedWithASymbolicLink() throws {
        let file = try writeFile("nested/keep.tmp", under: temporary, age: 9)
        let directory = file.deletingLastPathComponent()
        let movedDirectory = workspace.appendingPathComponent("moved")
        let plan = cleaner.scan([.temporaryFiles], now: now)
        XCTAssertEqual(plan.files.count, 1)

        try manager.moveItem(at: directory, to: movedDirectory)
        try manager.createSymbolicLink(at: directory, withDestinationURL: movedDirectory)

        let result = cleaner.clean(plan)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(manager.fileExists(atPath: movedDirectory.appendingPathComponent(file.lastPathComponent).path))
    }

    func testCleanupRejectsAReplacedRoot() throws {
        let path = "keep.tmp"
        let file = try writeFile(path, under: temporary, age: 9)
        let movedRoot = workspace.appendingPathComponent("moved-root")
        let plan = cleaner.scan([.temporaryFiles], now: now)
        XCTAssertEqual(plan.files.count, 1)

        try manager.moveItem(at: temporary, to: movedRoot)
        try writeFile(path, under: temporary, age: 9)

        let result = cleaner.clean(plan)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(manager.fileExists(atPath: file.path))
    }

    @discardableResult
    private func writeFile(_ path: String, under directory: URL, age: Int) throws -> URL {
        let file = directory.appendingPathComponent(path)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: file)
        let modified = now.addingTimeInterval(-Double(age) * 86_400)
        try manager.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return file
    }
}
