import Foundation

extension Cleaner {
    static func privacyTraceTargets(homePath: String, userCacheDirectory: String?) -> [CleanupTarget] {
        let library = homePath + "/Library"
        let quickLookPath = userCacheDirectory.map { $0 + "/com.apple.QuickLook.thumbnailcache" }

        return [
            // macOS download quarantine database (records URLs of downloaded files)
            CleanupTarget(
                category: .privacyTraces,
                rootPath: library + "/Preferences",
                maxDepth: 1,
                shouldDescend: { _ in false },
                shouldIncludeFile: { components in
                    components.count == 1 && quarantineEventFiles.contains(components[0])
                }
            ),

            // QuickLook cached previews and thumbnails of viewed documents
            CleanupTarget(
                category: .privacyTraces,
                rootPath: quickLookPath,
                missingRootIsUnreadable: userCacheDirectory == nil
            ),

            // Saved window snapshots and session state for apps
            CleanupTarget(
                category: .privacyTraces,
                rootPath: library + "/Saved Application State",
                shouldDescend: { components in
                    components.first?.hasSuffix(".savedState") == true
                },
                shouldIncludeFile: { components in
                    components.count >= 2 && components[0].hasSuffix(".savedState")
                }
            ),

            // System HSTS host cache
            CleanupTarget(
                category: .privacyTraces,
                rootPath: library + "/Cookies",
                maxDepth: 1,
                shouldDescend: { _ in false },
                shouldIncludeFile: { $0 == ["HSTS.plist"] }
            ),

            // Per-app NSURLSession HTTP cookie and HSTS databases
            CleanupTarget(
                category: .privacyTraces,
                rootPath: library + "/HTTPStorages",
                maxDepth: 2,
                shouldDescend: { $0.count == 1 },
                shouldIncludeFile: shouldIncludeHTTPStorageFile
            ),
        ]
    }
}

private let quarantineEventFiles: Set<String> = [
    "com.apple.LaunchServices.QuarantineEventsV2",
    "com.apple.LaunchServices.QuarantineEventsV2-wal",
    "com.apple.LaunchServices.QuarantineEventsV2-shm",
]

private let httpStorageFiles: Set<String> = [
    "httpstorages.sqlite",
    "httpstorages.sqlite-wal",
    "httpstorages.sqlite-shm",
]

@Sendable
private func shouldIncludeHTTPStorageFile(_ components: [String]) -> Bool {
    guard let last = components.last else { return false }
    if components.count == 1 {
        return last.hasSuffix(".binarycookies")
    }
    if components.count == 2 {
        return httpStorageFiles.contains(last) || last.hasSuffix(".binarycookies")
    }
    return false
}
