import Foundation
import XCTest
@testable import CleanerCore

final class UninstalledAppTests: XCTestCase {
    private let manager = FileManager.default
    private let now = Date()
    private var workspace: URL!
    private var home: URL!
    private var applications: URL!
    private var launchAgents: URL!
    private var discoveryPaths: AppDiscoveryPaths!
    private var cleaner: Cleaner!

    override func setUpWithError() throws {
        #if os(macOS)
        let tempDirectory = URL(fileURLWithPath: try XCTUnwrap(Cleaner.userTemporaryDirectory()), isDirectory: true)
        #else
        let tempDirectory = manager.temporaryDirectory.resolvingSymlinksInPath()
        #endif
        workspace = tempDirectory.appendingPathComponent("FluentCleanerUninstalledTests-\(UUID().uuidString)")
        home = workspace.appendingPathComponent("home")
        applications = workspace.appendingPathComponent("Applications")
        launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        for dir in [home!, applications!, launchAgents!] {
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        discoveryPaths = AppDiscoveryPaths(
            primaryApplicationDirectories: [applications.path],
            secondaryBundleDirectories: [],
            launchAgentDirectories: [launchAgents.path],
            extraProtectedBundleIdentifiers: []
        )
        cleaner = Cleaner.uninstalledAppCleaner(homePath: home.path, discoveryPaths: discoveryPaths)
    }

    override func tearDownWithError() throws {
        if let workspace { try manager.removeItem(at: workspace) }
    }

    func testUninstalledAppTracesCleansOnlyOrphanedThirdPartyBundles() throws {
        // Installed apps (direct, nested folder, nested login item, symlinked cask, and launch agent)
        try writeAppBundle(at: applications.appendingPathComponent("Installed.app"), bundleID: "com.acme.Installed")
        try writeAppBundle(
            at: applications.appendingPathComponent("Utilities/Tool.app"),
            bundleID: "org.example.Tool",
            nestedLoginItemBundleID: "org.example.ToolHelper"
        )
        let caskTarget = workspace.appendingPathComponent("Caskroom/Linked.app")
        try writeAppBundle(at: caskTarget, bundleID: "io.cask.Linked")
        try manager.createSymbolicLink(
            at: applications.appendingPathComponent("Linked.app"),
            withDestinationURL: caskTarget
        )
        try writeLaunchAgent(
            named: "net.daemon.Agent.plist",
            label: "net.daemon.Agent",
            associatedBundleIDs: ["net.daemon.Companion"]
        )

        // Orphaned third-party app traces across all supported Library locations
        let orphanPref = try writeFile("Library/Preferences/com.oldvendor.OldApp.plist")
        let orphanSavedState = try writeFile("Library/Saved Application State/com.oldvendor.OldApp.savedState/window_1.data")
        let orphanCache = try writeFile("Library/Caches/com.oldvendor.OldApp/cache.bin")
        let orphanSupport = try writeFile("Library/Application Support/com.oldvendor.OldApp/state.db")
        let orphanContainer = try writeFile("Library/Containers/io.removed.SandboxApp/Data/tmp.dat")
        let orphanHttpDir = try writeFile("Library/HTTPStorages/com.oldvendor.OldApp/httpstorages.sqlite")
        let orphanHttpCookies = try writeFile("Library/HTTPStorages/com.oldvendor.OldApp.binarycookies")
        let orphanWebKit = try writeFile("Library/WebKit/com.oldvendor.OldApp/WebsiteData/db")
        let orphanLogDir = try writeFile("Library/Logs/com.oldvendor.OldApp/app.log")
        let orphanLogFile = try writeFile("Library/Logs/com.oldvendor.OldApp.log")

        // Traces that MUST be preserved
        let installedPref = try writeFile("Library/Preferences/com.acme.Installed.plist")
        let installedHelperPref = try writeFile("Library/Preferences/com.acme.Installed.helper.plist")
        let nestedLoginItemCache = try writeFile("Library/Caches/org.example.ToolHelper/data.bin")
        let symlinkedAppSupport = try writeFile("Library/Application Support/io.cask.Linked/db")
        let agentSupport = try writeFile("Library/Application Support/net.daemon.Agent/state")
        let companionPref = try writeFile("Library/Preferences/net.daemon.Companion.plist")
        let applePref = try writeFile("Library/Preferences/com.apple.Safari.plist")
        let appGroupData = try writeFile("Library/Application Support/group.com.oldvendor.shared/data")
        let selfPref = try writeFile("Library/Preferences/com.fluentcleaner.macos.plist")
        let plainFolder = try writeFile("Library/Application Support/AddressBook/contacts.db")
        let vendorFolder = try writeFile("Library/Application Support/Google/Chrome/Default/Bookmarks")
        let nonBundleFilename = try writeFile("Library/Logs/foo.bar.bak.log")

        let plan = cleaner.scan([.uninstalledAppTraces], now: now)
        XCTAssertEqual(plan.unreadableLocations, 0)
        XCTAssertEqual(
            Set(plan.files.map(\.path)),
            [
                orphanPref.path, orphanSavedState.path, orphanCache.path, orphanSupport.path,
                orphanContainer.path, orphanHttpDir.path, orphanHttpCookies.path,
                orphanWebKit.path, orphanLogDir.path, orphanLogFile.path,
            ]
        )

        let report = cleaner.clean(plan)
        XCTAssertEqual(report.deleted, 10)
        XCTAssertEqual(report.skipped, 0)
        for preserved in [
            installedPref, installedHelperPref, nestedLoginItemCache, symlinkedAppSupport,
            agentSupport, companionPref, applePref, appGroupData, selfPref,
            plainFolder, vendorFolder, nonBundleFilename,
        ] {
            XCTAssertTrue(manager.fileExists(atPath: preserved.path), "Expected preserved file: \(preserved.path)")
        }
    }

    func testUninstalledAppDetectionRefreshesDynamicallyBetweenScans() throws {
        let appURL = applications.appendingPathComponent("Temporary.app")
        try writeAppBundle(at: appURL, bundleID: "dev.sample.Temporary")
        let trace = try writeFile("Library/Preferences/dev.sample.Temporary.plist")

        XCTAssertTrue(cleaner.scan([.uninstalledAppTraces], now: now).files.isEmpty)

        try manager.removeItem(at: appURL)

        let plan = cleaner.scan([.uninstalledAppTraces], now: now)
        XCTAssertEqual(plan.files.map(\.path), [trace.path])
    }

    func testUninstalledAppScannerFailsClosedWhenApplicationDirectoriesAreUnreadable() throws {
        let trace = try writeFile("Library/Preferences/com.oldvendor.OldApp.plist")
        let unreadableDiscovery = AppDiscoveryPaths(
            primaryApplicationDirectories: [workspace.appendingPathComponent("MissingApplications").path],
            secondaryBundleDirectories: [],
            launchAgentDirectories: [],
            extraProtectedBundleIdentifiers: []
        )
        let failClosedCleaner = Cleaner.uninstalledAppCleaner(
            homePath: home.path,
            discoveryPaths: unreadableDiscovery
        )

        let plan = failClosedCleaner.scan([.uninstalledAppTraces], now: now)
        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertEqual(plan.unreadableLocations, 1)
        XCTAssertTrue(manager.fileExists(atPath: trace.path))
    }

    func testBundleIdentifierValidation() {
        XCTAssertTrue(isThirdPartyBundleIdentifier("com.vendor.App"))
        XCTAssertTrue(isThirdPartyBundleIdentifier("org.mozilla.firefox.helper"))
        XCTAssertTrue(isThirdPartyBundleIdentifier("io.github.user-1.my_app"))

        XCTAssertFalse(isThirdPartyBundleIdentifier("com.apple.Safari"))
        XCTAssertFalse(isThirdPartyBundleIdentifier("group.com.vendor.shared"))
        XCTAssertFalse(isThirdPartyBundleIdentifier("com.fluentcleaner.macos"))
        XCTAssertFalse(isThirdPartyBundleIdentifier("Google"))
        XCTAssertFalse(isThirdPartyBundleIdentifier("notes.txt"))
        XCTAssertFalse(isThirdPartyBundleIdentifier("foo.bar.baz"))
        XCTAssertFalse(isThirdPartyBundleIdentifier(".com.vendor.app"))
        XCTAssertFalse(isThirdPartyBundleIdentifier("com..app"))
    }

    private func writeAppBundle(
        at appURL: URL,
        bundleID: String,
        nestedLoginItemBundleID: String? = nil
    ) throws {
        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        try writePlist(["CFBundleIdentifier": bundleID], to: infoPlist)
        if let nestedLoginItemBundleID {
            let helperPlist = appURL.appendingPathComponent(
                "Contents/Library/LoginItems/Helper.app/Contents/Info.plist"
            )
            try writePlist(["CFBundleIdentifier": nestedLoginItemBundleID], to: helperPlist)
        }
    }

    private func writeLaunchAgent(
        named filename: String,
        label: String,
        associatedBundleIDs: [String]
    ) throws {
        let plistURL = launchAgents.appendingPathComponent(filename)
        try writePlist(
            [
                "Label": label,
                "AssociatedBundleIdentifiers": associatedBundleIDs,
            ],
            to: plistURL
        )
    }

    private func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url)
    }

    @discardableResult
    private func writeFile(_ relativePath: String) throws -> URL {
        let file = home.appendingPathComponent(relativePath)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: file)
        return file
    }
}
