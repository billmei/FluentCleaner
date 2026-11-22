import Foundation
import XCTest
@testable import CleanerCore

final class RecentFileListTests: XCTestCase {
    private let manager = FileManager.default
    private let now = Date()
    private var home: URL!
    private var cleaner: Cleaner!

    override func setUpWithError() throws {
        #if os(macOS)
        let tempDirectory = URL(fileURLWithPath: try XCTUnwrap(Cleaner.userTemporaryDirectory()), isDirectory: true)
        #else
        let tempDirectory = manager.temporaryDirectory.resolvingSymlinksInPath()
        #endif
        home = tempDirectory.appendingPathComponent("FluentCleanerRecentTests-\(UUID().uuidString)")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        cleaner = Cleaner(targets: Cleaner.recentFileListTargets(homePath: home.path))
    }

    override func tearDownWithError() throws {
        if let home { try manager.removeItem(at: home) }
    }

    func testRecentFileListsCleansSharedFileListsAndLegacyPlistsWhilePreservingFavoritesAndLoginItems() throws {
        let shared = "Library/Application Support/com.apple.sharedfilelist"
        let recentDocs = try writeFile("\(shared)/com.apple.LSSharedFileList.RecentDocuments.sfl3")
        let recentApps = try writeFile("\(shared)/com.apple.LSSharedFileList.RecentApplications.sfl2")
        let recentServers = try writeFile("\(shared)/com.apple.LSSharedFileList.RecentServers.sfl")
        let recentHosts = try writeFile("\(shared)/com.apple.LSSharedFileList.RecentHosts.sfl4")
        let appRecentPreview = try writeFile(
            "\(shared)/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.preview.sfl3"
        )
        let legacyRecentItems = try writeFile("Library/Preferences/com.apple.recentitems.plist")
        let legacyAppRecent = try writeFile("Library/Preferences/com.apple.TextEdit.LSSharedFileList.plist")

        let favorites = try writeFile("\(shared)/com.apple.LSSharedFileList.FavoriteItems.sfl3")
        let favoriteVolumes = try writeFile("\(shared)/com.apple.LSSharedFileList.FavoriteVolumes.sfl3")
        let loginItems = try writeFile("\(shared)/com.apple.LSSharedFileList.SessionLoginItems.sfl3")
        let iCloudItems = try writeFile("\(shared)/com.apple.LSSharedFileList.iCloudItems.sfl3")
        let backupFile = try writeFile("\(shared)/com.apple.LSSharedFileList.RecentDocuments.sfl3.bak")
        let nestedJunk = try writeFile(
            "\(shared)/com.apple.LSSharedFileList.ApplicationRecentDocuments/nested/com.apple.preview.sfl3"
        )
        let finderPrefs = try writeFile("Library/Preferences/com.apple.finder.plist")
        let quarantine = try writeFile("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
        let bareSuffix = try writeFile("Library/Preferences/.LSSharedFileList.plist")

        let plan = cleaner.scan([.recentFileLists], now: now)
        XCTAssertEqual(plan.unreadableLocations, 0)
        XCTAssertEqual(
            Set(plan.files.map(\.path)),
            [
                recentDocs.path, recentApps.path, recentServers.path, recentHosts.path,
                appRecentPreview.path, legacyRecentItems.path, legacyAppRecent.path,
            ]
        )

        let report = cleaner.clean(plan)
        XCTAssertEqual(report.deleted, 7)
        XCTAssertEqual(report.skipped, 0)
        for preserved in [
            favorites, favoriteVolumes, loginItems, iCloudItems, backupFile,
            nestedJunk, finderPrefs, quarantine, bareSuffix,
        ] {
            XCTAssertTrue(manager.fileExists(atPath: preserved.path))
        }
    }

    @discardableResult
    private func writeFile(_ relativePath: String) throws -> URL {
        let file = home.appendingPathComponent(relativePath)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: file)
        return file
    }
}
