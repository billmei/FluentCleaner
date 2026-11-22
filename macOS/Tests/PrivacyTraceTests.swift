import Foundation
import XCTest
@testable import CleanerCore

final class PrivacyTraceTests: XCTestCase {
    private let manager = FileManager.default
    private let now = Date()
    private var workspace: URL!
    private var home: URL!
    private var userCache: URL!
    private var cleaner: Cleaner!

    override func setUpWithError() throws {
        #if os(macOS)
        let tempDirectory = URL(fileURLWithPath: try XCTUnwrap(Cleaner.userTemporaryDirectory()), isDirectory: true)
        #else
        let tempDirectory = manager.temporaryDirectory.resolvingSymlinksInPath()
        #endif
        workspace = tempDirectory.appendingPathComponent("FluentCleanerPrivacyTests-\(UUID().uuidString)")
        home = workspace.appendingPathComponent("home")
        userCache = workspace.appendingPathComponent("darwin-cache")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: userCache, withIntermediateDirectories: true)
        cleaner = Cleaner(targets: Cleaner.privacyTraceTargets(
            homePath: home.path,
            userCacheDirectory: userCache.path
        ))
    }

    override func tearDownWithError() throws {
        if let workspace { try manager.removeItem(at: workspace) }
    }

    func testPrivacyTracesCleansQuarantineQuickLookSavedStateAndHttpCookiesWhilePreservingUnrelatedFiles() throws {
        let quarantine = try writeFile("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2", under: home)
        let quarantineWal = try writeFile("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2-wal", under: home)
        let quickLook = try writeFile("com.apple.QuickLook.thumbnailcache/thumbnails.data", under: userCache)
        let savedWindow = try writeFile("Library/Saved Application State/com.apple.Preview.savedState/window_1.data", under: home)
        let hsts = try writeFile("Library/Cookies/HSTS.plist", under: home)
        let appHttpDb = try writeFile("Library/HTTPStorages/com.example.App/httpstorages.sqlite", under: home)
        let appCookies = try writeFile("Library/HTTPStorages/com.example.App.binarycookies", under: home)

        let finderPrefs = try writeFile("Library/Preferences/com.apple.finder.plist", under: home)
        let nestedPref = try writeFile("Library/Preferences/ByHost/com.apple.LaunchServices.QuarantineEventsV2", under: home)
        let browserCookies = try writeFile("Library/Cookies/Cookies.binarycookies", under: home)
        let nonSavedState = try writeFile("Library/Saved Application State/notes.txt", under: home)
        let httpOther = try writeFile("Library/HTTPStorages/com.example.App/config.plist", under: home)

        let plan = cleaner.scan([.privacyTraces], now: now)
        XCTAssertEqual(plan.unreadableLocations, 0)
        XCTAssertEqual(
            Set(plan.files.map(\.path)),
            [
                quarantine.path, quarantineWal.path, quickLook.path, savedWindow.path,
                hsts.path, appHttpDb.path, appCookies.path,
            ]
        )

        let report = cleaner.clean(plan)
        XCTAssertEqual(report.deleted, 7)
        XCTAssertEqual(report.skipped, 0)
        for preserved in [finderPrefs, nestedPref, browserCookies, nonSavedState, httpOther] {
            XCTAssertTrue(manager.fileExists(atPath: preserved.path))
        }
    }

    func testMissingUserCacheDirectoryReportsUnreadableWithoutBlockingOtherPrivacyTargets() throws {
        let quarantine = try writeFile("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2", under: home)
        let partialCleaner = Cleaner(targets: Cleaner.privacyTraceTargets(
            homePath: home.path,
            userCacheDirectory: nil
        ))

        let plan = partialCleaner.scan([.privacyTraces], now: now)
        XCTAssertEqual(plan.unreadableLocations, 1)
        XCTAssertEqual(plan.files.map(\.path), [quarantine.path])
    }

    #if os(macOS)
    func testUserCacheDirectoryResolvesCanonicalDarwinCachePath() throws {
        let cacheDirectory = try XCTUnwrap(Cleaner.userCacheDirectory())
        XCTAssertTrue(cacheDirectory.hasPrefix("/private/var/folders/"))
        XCTAssertTrue(cacheDirectory.hasSuffix("/C"))
    }
    #endif

    @discardableResult
    private func writeFile(_ relativePath: String, under directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(relativePath)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: file)
        return file
    }
}
