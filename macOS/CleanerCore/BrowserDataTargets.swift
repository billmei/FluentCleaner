import Foundation

extension Cleaner {
    static func browserDataTargets(homePath: String) -> [CleanupTarget] {
        let library = homePath + "/Library"
        let appSupport = library + "/Application Support"
        let caches = library + "/Caches"

        var targets: [CleanupTarget] = [
            // Safari
            CleanupTarget(
                category: .browserData,
                rootPath: library + "/Safari",
                shouldDescend: shouldDescendSafariDirectory,
                shouldIncludeFile: shouldIncludeSafariFile
            ),
            CleanupTarget(
                category: .browserData,
                rootPath: library + "/Cookies",
                maxDepth: 1,
                shouldDescend: { _ in false },
                shouldIncludeFile: { $0 == ["Cookies.binarycookies"] }
            ),
            CleanupTarget(
                category: .browserData,
                rootPath: library + "/Containers/com.apple.Safari/Data/Library/Cookies",
                maxDepth: 1,
                shouldDescend: { _ in false },
                shouldIncludeFile: { $0 == ["Cookies.binarycookies"] }
            ),
            CleanupTarget(
                category: .browserData,
                rootPath: library + "/Containers/com.apple.Safari/Data/Library/Caches"
            ),
            CleanupTarget(
                category: .browserData,
                rootPath: caches + "/com.apple.Safari"
            ),

            // Firefox
            CleanupTarget(
                category: .browserData,
                rootPath: appSupport + "/Firefox/Profiles",
                shouldDescend: shouldDescendFirefoxProfileData,
                shouldIncludeFile: shouldIncludeFirefoxProfileDataFile
            ),
            CleanupTarget(
                category: .browserData,
                rootPath: caches + "/Firefox/Profiles",
                shouldDescend: shouldDescendFirefoxProfileCache,
                shouldIncludeFile: shouldIncludeFirefoxProfileCacheFile
            ),
        ]

        // Chromium-based browsers with multi-profile directories (Default, Profile *)
        let profiledChromiumBrowsers = [
            "Google/Chrome",
            "Google/Chrome Beta",
            "Google/Chrome Canary",
            "BraveSoftware/Brave-Browser",
            "Microsoft Edge",
            "Arc/User Data",
            "Vivaldi",
            "Chromium",
        ]
        for relative in profiledChromiumBrowsers {
            targets.append(CleanupTarget(
                category: .browserData,
                rootPath: appSupport + "/" + relative,
                shouldDescend: shouldDescendProfiledChromiumDirectory,
                shouldIncludeFile: shouldIncludeProfiledChromiumFile
            ))
        }

        // Opera stores its default profile directly inside its Application Support folder.
        targets.append(CleanupTarget(
            category: .browserData,
            rootPath: appSupport + "/com.operasoftware.Opera",
            shouldDescend: shouldDescendChromiumProfile,
            shouldIncludeFile: shouldIncludeChromiumProfileFile
        ))

        let chromiumCacheBrowsers = [
            "Google/Chrome",
            "Google/Chrome Beta",
            "Google/Chrome Canary",
            "BraveSoftware/Brave-Browser",
            "Microsoft Edge",
            "Arc",
            "Vivaldi",
            "Chromium",
            "com.operasoftware.Opera",
        ]
        for relative in chromiumCacheBrowsers {
            targets.append(CleanupTarget(
                category: .browserData,
                rootPath: caches + "/" + relative
            ))
        }

        return targets
    }
}

// MARK: - Safari

private let safariDirectFiles: Set<String> = [
    "History.db",
    "History.db-lock",
    "History.db-shm",
    "History.db-wal",
    "Downloads.plist",
    "LastSession.plist",
    "RecentlyClosedTabs.plist",
    "TopSites.plist",
    "SearchDescriptions.plist",
    "WebpageIcons.db",
    "WebpageIcons.db-shm",
    "WebpageIcons.db-wal",
]

private let safariRecursiveDirectories: Set<String> = [
    "Favicon Cache",
    "Touch Icons Cache",
    "Template Icons",
    "LocalStorage",
    "Databases",
]

@Sendable
private func shouldDescendSafariDirectory(_ components: [String]) -> Bool {
    guard let first = components.first else { return false }
    return safariRecursiveDirectories.contains(first)
}

@Sendable
private func shouldIncludeSafariFile(_ components: [String]) -> Bool {
    guard let first = components.first else { return false }
    if components.count == 1 {
        return safariDirectFiles.contains(first)
    }
    return safariRecursiveDirectories.contains(first)
}

// MARK: - Chromium

private let chromiumDirectFiles: Set<String> = [
    "History",
    "History-journal",
    "History Provider Cache",
    "Visited Links",
    "Top Sites",
    "Top Sites-journal",
    "Shortcuts",
    "Shortcuts-journal",
    "Network Action Predictor",
    "Network Action Predictor-journal",
    "Cookies",
    "Cookies-journal",
    "Current Session",
    "Current Tabs",
    "Last Session",
    "Last Tabs",
    "Favicons",
    "Favicons-journal",
    "QuotaManager",
    "QuotaManager-journal",
    "Reporting and NEL",
    "Reporting and NEL-journal",
    "Trust Tokens",
    "Trust Tokens-journal",
    "Network Persistent State",
    "TransportSecurity",
]

private let chromiumNetworkFiles: Set<String> = [
    "Cookies",
    "Cookies-journal",
    "Trust Tokens",
    "Trust Tokens-journal",
    "Reporting and NEL",
    "Reporting and NEL-journal",
    "Network Persistent State",
    "TransportSecurity",
]

private let chromiumRecursiveDirectories: Set<String> = [
    "Sessions",
    "Local Storage",
    "Session Storage",
    "IndexedDB",
    "GPUCache",
    "Code Cache",
    "Cache",
    "DawnCache",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "Shared Dictionary",
    "blob_storage",
    "File System",
]

private func isChromiumProfileDirectory(_ name: String) -> Bool {
    name == "Default"
        || name == "Guest Profile"
        || name == "System Profile"
        || name.hasPrefix("Profile ")
}

@Sendable
private func shouldDescendProfiledChromiumDirectory(_ components: [String]) -> Bool {
    guard let profile = components.first, isChromiumProfileDirectory(profile) else { return false }
    if components.count == 1 { return true }
    return shouldDescendChromiumProfile(Array(components.dropFirst()))
}

@Sendable
private func shouldIncludeProfiledChromiumFile(_ components: [String]) -> Bool {
    guard let profile = components.first, isChromiumProfileDirectory(profile), components.count >= 2 else {
        return false
    }
    return shouldIncludeChromiumProfileFile(Array(components.dropFirst()))
}

@Sendable
private func shouldDescendChromiumProfile(_ subpath: [String]) -> Bool {
    guard let first = subpath.first else { return false }
    if first == "Network" {
        return subpath.count == 1
    }
    if first == "Service Worker" {
        if subpath.count == 1 { return true }
        return subpath[1] == "CacheStorage" || subpath[1] == "ScriptCache"
    }
    return chromiumRecursiveDirectories.contains(first)
}

@Sendable
private func shouldIncludeChromiumProfileFile(_ subpath: [String]) -> Bool {
    guard let first = subpath.first else { return false }
    if subpath.count == 1 {
        return chromiumDirectFiles.contains(first)
    }
    if first == "Network" {
        return subpath.count == 2 && chromiumNetworkFiles.contains(subpath[1])
    }
    if first == "Service Worker" {
        return subpath.count >= 3 && (subpath[1] == "CacheStorage" || subpath[1] == "ScriptCache")
    }
    return chromiumRecursiveDirectories.contains(first)
}

// MARK: - Firefox

// Note: places.sqlite stores both browsing history and bookmarks, so it is intentionally excluded.
private let firefoxDirectFiles: Set<String> = [
    "cookies.sqlite",
    "cookies.sqlite-wal",
    "cookies.sqlite-shm",
    "formhistory.sqlite",
    "formhistory.sqlite-wal",
    "formhistory.sqlite-shm",
    "sessionstore.jsonlz4",
    "webappsstore.sqlite",
    "webappsstore.sqlite-wal",
    "webappsstore.sqlite-shm",
    "favicons.sqlite",
    "favicons.sqlite-wal",
    "favicons.sqlite-shm",
    "SiteSecurityServiceState.txt",
    "AlternateServices.txt",
    "content-prefs.sqlite",
    "content-prefs.sqlite-wal",
    "content-prefs.sqlite-shm",
]

private let firefoxRecursiveDirectories: Set<String> = [
    "sessionstore-backups",
    "saved-telemetry-pings",
]

private let firefoxCacheDirectories: Set<String> = [
    "cache2",
    "startupCache",
    "thumbnails",
    "safebrowsing",
]

@Sendable
private func shouldDescendFirefoxProfileData(_ components: [String]) -> Bool {
    if components.count == 1 { return true }
    let subpath = Array(components.dropFirst())
    guard let first = subpath.first else { return false }
    if firefoxRecursiveDirectories.contains(first) {
        return true
    }
    if first == "datareporting" {
        return subpath.count == 1 || subpath[1] == "archived"
    }
    if first == "storage" {
        if subpath.count == 1 { return true }
        guard subpath[1] == "default" else { return false }
        if subpath.count == 2 { return true }
        return subpath[2].hasPrefix("http")
    }
    return false
}

@Sendable
private func shouldIncludeFirefoxProfileDataFile(_ components: [String]) -> Bool {
    guard components.count >= 2 else { return false }
    let subpath = Array(components.dropFirst())
    guard let first = subpath.first else { return false }
    if subpath.count == 1 {
        return firefoxDirectFiles.contains(first)
    }
    if firefoxRecursiveDirectories.contains(first) {
        return true
    }
    if first == "datareporting" {
        return subpath.count >= 3 && subpath[1] == "archived"
    }
    if first == "storage" {
        return subpath.count >= 4 && subpath[1] == "default" && subpath[2].hasPrefix("http")
    }
    return false
}

@Sendable
private func shouldDescendFirefoxProfileCache(_ components: [String]) -> Bool {
    if components.count == 1 { return true }
    guard components.count >= 2 else { return false }
    return firefoxCacheDirectories.contains(components[1])
}

@Sendable
private func shouldIncludeFirefoxProfileCacheFile(_ components: [String]) -> Bool {
    guard components.count >= 3 else { return false }
    return firefoxCacheDirectories.contains(components[1])
}
