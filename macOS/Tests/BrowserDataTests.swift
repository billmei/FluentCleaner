import Foundation
import XCTest
@testable import CleanerCore

final class BrowserDataTests: XCTestCase {
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
        home = tempDirectory.appendingPathComponent("FluentCleanerBrowserTests-\(UUID().uuidString)")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        cleaner = Cleaner(targets: Cleaner.browserDataTargets(homePath: home.path))
    }

    override func tearDownWithError() throws {
        if let home { try manager.removeItem(at: home) }
    }

    func testSafariCleansHistoryCookiesSessionsAndCachesWhilePreservingBookmarks() throws {
        let history = try writeFile("Library/Safari/History.db")
        let downloads = try writeFile("Library/Safari/Downloads.plist")
        let favicon = try writeFile("Library/Safari/Favicon Cache/site.ico")
        let localStorage = try writeFile("Library/Safari/LocalStorage/https_example.com.localstorage")
        let cookies = try writeFile("Library/Cookies/Cookies.binarycookies")
        let containerCookies = try writeFile("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        let containerCache = try writeFile("Library/Containers/com.apple.Safari/Data/Library/Caches/cache.db")
        let cache = try writeFile("Library/Caches/com.apple.Safari/Webpage Previews/preview.png")

        let bookmarks = try writeFile("Library/Safari/Bookmarks.plist")
        let cloudTabs = try writeFile("Library/Safari/CloudTabs.db")
        let extensionFile = try writeFile("Library/Safari/Extensions/blocker.safariextz")
        let hsts = try writeFile("Library/Cookies/HSTS.plist")

        let plan = cleaner.scan([.browserData], now: now)
        XCTAssertEqual(plan.unreadableLocations, 0)
        XCTAssertEqual(
            Set(plan.files.map(\.path)),
            [
                history.path, downloads.path, favicon.path, localStorage.path,
                cookies.path, containerCookies.path, containerCache.path, cache.path,
            ]
        )

        let report = cleaner.clean(plan)
        XCTAssertEqual(report.deleted, 8)
        XCTAssertEqual(report.skipped, 0)
        for preserved in [bookmarks, cloudTabs, extensionFile, hsts] {
            XCTAssertTrue(manager.fileExists(atPath: preserved.path))
        }
    }

    func testChromiumCleansHistoryCookiesSessionsAndStorageWhilePreservingBookmarksAndLogins() throws {
        let chromeHistory = try writeFile("Library/Application Support/Google/Chrome/Default/History")
        let chromeCookies = try writeFile("Library/Application Support/Google/Chrome/Default/Network/Cookies")
        let chromeSession = try writeFile("Library/Application Support/Google/Chrome/Profile 1/Sessions/Session_1")
        let chromeStorage = try writeFile("Library/Application Support/Google/Chrome/Profile 1/Local Storage/leveldb/0001.ldb")
        let chromeSW = try writeFile("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/idx")
        let chromeCache = try writeFile("Library/Caches/Google/Chrome/Default/Cache/data_0")
        let operaHistory = try writeFile("Library/Application Support/com.operasoftware.Opera/History")

        let bookmarks = try writeFile("Library/Application Support/Google/Chrome/Default/Bookmarks")
        let logins = try writeFile("Library/Application Support/Google/Chrome/Default/Login Data")
        let prefs = try writeFile("Library/Application Support/Google/Chrome/Default/Preferences")
        let webData = try writeFile("Library/Application Support/Google/Chrome/Default/Web Data")
        let localState = try writeFile("Library/Application Support/Google/Chrome/Local State")
        let extensionData = try writeFile("Library/Application Support/Google/Chrome/Default/Extensions/abc/manifest.json")
        let swDatabase = try writeFile("Library/Application Support/Google/Chrome/Default/Service Worker/Database/0001.log")

        let plan = cleaner.scan([.browserData], now: now)
        XCTAssertEqual(plan.unreadableLocations, 0)
        XCTAssertEqual(
            Set(plan.files.map(\.path)),
            [
                chromeHistory.path, chromeCookies.path, chromeSession.path,
                chromeStorage.path, chromeSW.path, chromeCache.path, operaHistory.path,
            ]
        )

        let report = cleaner.clean(plan)
        XCTAssertEqual(report.deleted, 7)
        XCTAssertEqual(report.skipped, 0)
        for preserved in [bookmarks, logins, prefs, webData, localState, extensionData, swDatabase] {
            XCTAssertTrue(manager.fileExists(atPath: preserved.path))
        }
    }

    func testFirefoxPreservesBookmarksAndPasswordsWhileCleaningCookiesSessionsAndSiteStorage() throws {
        let profile = "Library/Application Support/Firefox/Profiles/abc123.default-release"
        let cookies = try writeFile("\(profile)/cookies.sqlite")
        let formHistory = try writeFile("\(profile)/formhistory.sqlite")
        let session = try writeFile("\(profile)/sessionstore.jsonlz4")
        let backupSession = try writeFile("\(profile)/sessionstore-backups/recovery.jsonlz4")
        let telemetry = try writeFile("\(profile)/datareporting/archived/ping.jsonlz4")
        let siteStorage = try writeFile("\(profile)/storage/default/https+++example.com/ls/data.sqlite")
        let diskCache = try writeFile("Library/Caches/Firefox/Profiles/abc123.default-release/cache2/entries/item")

        let placesBookmarks = try writeFile("\(profile)/places.sqlite")
        let logins = try writeFile("\(profile)/logins.json")
        let keys = try writeFile("\(profile)/key4.db")
        let prefs = try writeFile("\(profile)/prefs.js")
        let extensionStorage = try writeFile("\(profile)/storage/default/moz-extension+++1234/idb/data.sqlite")
        let datareportingState = try writeFile("\(profile)/datareporting/state.json")

        let plan = cleaner.scan([.browserData], now: now)
        XCTAssertEqual(plan.unreadableLocations, 0)
        XCTAssertEqual(
            Set(plan.files.map(\.path)),
            [
                cookies.path, formHistory.path, session.path, backupSession.path,
                telemetry.path, siteStorage.path, diskCache.path,
            ]
        )

        let report = cleaner.clean(plan)
        XCTAssertEqual(report.deleted, 7)
        XCTAssertEqual(report.skipped, 0)
        for preserved in [placesBookmarks, logins, keys, prefs, extensionStorage, datareportingState] {
            XCTAssertTrue(manager.fileExists(atPath: preserved.path))
        }
    }

    func testBrowserCacheDeduplicatesWithAppCachesCategory() throws {
        let staleBrowserCache = try writeFile("Library/Caches/Google/Chrome/Default/Cache/old.bin", age: 40)
        let combinedCleaner = Cleaner(targets: Cleaner.browserDataTargets(homePath: home.path) + [
            CleanupTarget(
                category: .applicationCaches,
                rootPath: home.appendingPathComponent("Library/Caches").path,
                minimumAgeInDays: 30
            ),
        ])

        let plan = combinedCleaner.scan([.browserData, .applicationCaches], now: now)
        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(plan.files.first?.path, staleBrowserCache.path)
        XCTAssertEqual(plan.files.first?.category, .browserData)

        let report = combinedCleaner.clean(plan)
        XCTAssertEqual(report.deleted, 1)
        XCTAssertEqual(report.skipped, 0)
    }

    @discardableResult
    private func writeFile(_ relativePath: String, age: Int = 0) throws -> URL {
        let file = home.appendingPathComponent(relativePath)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: file)
        if age > 0 {
            let modified = now.addingTimeInterval(-Double(age) * 86_400)
            try manager.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        return file
    }
}
