import Foundation

extension Cleaner {
    static func recentFileListTargets(homePath: String) -> [CleanupTarget] {
        let library = homePath + "/Library"

        return [
            // macOS Shared File Lists (Recent Documents, Applications, Servers, Hosts, and per-app recent docs)
            CleanupTarget(
                category: .recentFileLists,
                rootPath: library + "/Application Support/com.apple.sharedfilelist",
                maxDepth: 2,
                shouldDescend: { components in
                    components == [applicationRecentDocumentsDirectory]
                },
                shouldIncludeFile: shouldIncludeSharedFileList
            ),

            // Legacy macOS recent-item preference files
            CleanupTarget(
                category: .recentFileLists,
                rootPath: library + "/Preferences",
                maxDepth: 1,
                shouldDescend: { _ in false },
                shouldIncludeFile: shouldIncludeLegacyRecentPlist
            ),
        ]
    }
}

private let applicationRecentDocumentsDirectory = "com.apple.LSSharedFileList.ApplicationRecentDocuments"

private let topLevelRecentSharedFilePrefixes = [
    "com.apple.LSSharedFileList.RecentDocuments.sfl",
    "com.apple.LSSharedFileList.RecentApplications.sfl",
    "com.apple.LSSharedFileList.RecentServers.sfl",
    "com.apple.LSSharedFileList.RecentHosts.sfl",
]

@Sendable
private func shouldIncludeSharedFileList(_ components: [String]) -> Bool {
    if components.count == 1 {
        return isTopLevelRecentSharedFileList(components[0])
    }
    if components.count == 2 && components[0] == applicationRecentDocumentsDirectory {
        return isSharedFileListFile(components[1])
    }
    return false
}

@Sendable
private func shouldIncludeLegacyRecentPlist(_ components: [String]) -> Bool {
    guard components.count == 1 else { return false }
    let name = components[0]
    if name == "com.apple.recentitems.plist" {
        return true
    }
    let suffix = ".LSSharedFileList.plist"
    return name.hasSuffix(suffix) && name.count > suffix.count
}

private func isTopLevelRecentSharedFileList(_ name: String) -> Bool {
    for prefix in topLevelRecentSharedFilePrefixes where name.hasPrefix(prefix) {
        let version = name.dropFirst(prefix.count)
        return version.allSatisfy(\.isASCII) && version.allSatisfy(\.isNumber)
    }
    return false
}

private func isSharedFileListFile(_ name: String) -> Bool {
    guard let range = name.range(of: ".sfl", options: .backwards),
          range.lowerBound > name.startIndex else {
        return false
    }
    let version = name[range.upperBound...]
    return version.allSatisfy(\.isASCII) && version.allSatisfy(\.isNumber)
}
