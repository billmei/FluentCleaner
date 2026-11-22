import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct AppDiscoveryPaths: Sendable {
    let primaryApplicationDirectories: [String]
    let secondaryBundleDirectories: [String]
    let launchAgentDirectories: [String]
    let extraProtectedBundleIdentifiers: Set<String>

    static func macOSDefaults(homePath: String) -> AppDiscoveryPaths {
        var extraProtected: Set<String> = []
        if let selfIdentifier = Bundle.main.bundleIdentifier?.lowercased() {
            extraProtected.insert(selfIdentifier)
        }
        return AppDiscoveryPaths(
            primaryApplicationDirectories: [
                "/Applications",
                "/System/Applications",
                "/System/Cryptexes/App/System/Applications",
                "/System/Library/CoreServices",
                homePath + "/Applications",
            ],
            secondaryBundleDirectories: [
                "/Library/PreferencePanes",
                homePath + "/Library/PreferencePanes",
                "/Library/QuickLook",
                homePath + "/Library/QuickLook",
                "/Library/Screen Savers",
                homePath + "/Library/Screen Savers",
                "/Library/Input Methods",
                homePath + "/Library/Input Methods",
            ],
            launchAgentDirectories: [
                homePath + "/Library/LaunchAgents",
                "/Library/LaunchAgents",
                "/Library/LaunchDaemons",
            ],
            extraProtectedBundleIdentifiers: extraProtected
        )
    }
}

struct InstalledAppIndex: Sendable {
    let bundleIdentifiers: Set<String>

    static func discover(from paths: AppDiscoveryPaths) -> InstalledAppIndex? {
        var identifiers: Set<String> = paths.extraProtectedBundleIdentifiers
        var readablePrimaryDirectories = 0

        for directory in paths.primaryApplicationDirectories {
            if collectBundles(in: URL(fileURLWithPath: directory, isDirectory: true), maxDepth: 2, into: &identifiers) {
                readablePrimaryDirectories += 1
            }
        }

        // Fail closed if no primary application directory could be read.
        guard readablePrimaryDirectories > 0 else {
            return nil
        }

        for directory in paths.secondaryBundleDirectories {
            _ = collectBundles(in: URL(fileURLWithPath: directory, isDirectory: true), maxDepth: 1, into: &identifiers)
        }

        for directory in paths.launchAgentDirectories {
            collectLaunchLabels(in: URL(fileURLWithPath: directory, isDirectory: true), into: &identifiers)
        }

        return InstalledAppIndex(bundleIdentifiers: identifiers)
    }

    func isInstalled(_ candidate: String) -> Bool {
        let normalized = candidate.lowercased()
        if bundleIdentifiers.contains(normalized) {
            return true
        }
        for installed in bundleIdentifiers {
            if normalized.hasPrefix(installed + ".") || installed.hasPrefix(normalized + ".") {
                return true
            }
        }
        return false
    }
}

extension Cleaner {
    static func uninstalledAppTraceRootPaths(homePath: String) -> [String] {
        let library = homePath + "/Library"
        return [
            library + "/Preferences",
            library + "/Saved Application State",
            library + "/Caches",
            library + "/Application Support",
            library + "/Containers",
            library + "/HTTPStorages",
            library + "/WebKit",
            library + "/Logs",
        ]
    }

    static func resolveUninstalledAppTraceTargets(
        homePath: String,
        discoveryPaths: AppDiscoveryPaths
    ) -> TargetResolution {
        guard let index = InstalledAppIndex.discover(from: discoveryPaths) else {
            return TargetResolution(targets: [], unreadableLocations: 1)
        }

        let library = homePath + "/Library"
        let isOrphan: @Sendable (String) -> Bool = { candidate in
            isThirdPartyBundleIdentifier(candidate) && !index.isInstalled(candidate)
        }

        let targets: [CleanupTarget] = [
            // ~/Library/Preferences/<bundleID>.plist
            CleanupTarget(
                category: .uninstalledAppTraces,
                rootPath: library + "/Preferences",
                maxDepth: 1,
                shouldDescend: { _ in false },
                shouldIncludeFile: { components in
                    guard components.count == 1,
                          let bundleID = stripSuffix(".plist", from: components[0]) else {
                        return false
                    }
                    return isOrphan(bundleID)
                }
            ),

            // ~/Library/Saved Application State/<bundleID>.savedState/*
            CleanupTarget(
                category: .uninstalledAppTraces,
                rootPath: library + "/Saved Application State",
                shouldDescend: { components in
                    guard let first = components.first,
                          let bundleID = stripSuffix(".savedState", from: first) else {
                        return false
                    }
                    return isOrphan(bundleID)
                },
                shouldIncludeFile: { components in
                    guard components.count >= 2,
                          let bundleID = stripSuffix(".savedState", from: components[0]) else {
                        return false
                    }
                    return isOrphan(bundleID)
                }
            ),

            // ~/Library/Caches/<bundleID>/*
            directoryBundleTarget(rootPath: library + "/Caches", isOrphan: isOrphan),

            // ~/Library/Application Support/<bundleID>/*
            directoryBundleTarget(rootPath: library + "/Application Support", isOrphan: isOrphan),

            // ~/Library/Containers/<bundleID>/*
            directoryBundleTarget(rootPath: library + "/Containers", isOrphan: isOrphan),

            // ~/Library/WebKit/<bundleID>/*
            directoryBundleTarget(rootPath: library + "/WebKit", isOrphan: isOrphan),

            // ~/Library/HTTPStorages/<bundleID>/* and <bundleID>.binarycookies
            CleanupTarget(
                category: .uninstalledAppTraces,
                rootPath: library + "/HTTPStorages",
                shouldDescend: { components in
                    guard let first = components.first else { return false }
                    return isOrphan(first)
                },
                shouldIncludeFile: { components in
                    guard let first = components.first else { return false }
                    if components.count == 1 {
                        guard let bundleID = stripSuffix(".binarycookies", from: first) else { return false }
                        return isOrphan(bundleID)
                    }
                    return isOrphan(first)
                }
            ),

            // ~/Library/Logs/<bundleID>/* and <bundleID>.log
            CleanupTarget(
                category: .uninstalledAppTraces,
                rootPath: library + "/Logs",
                shouldDescend: { components in
                    guard let first = components.first else { return false }
                    return isOrphan(first)
                },
                shouldIncludeFile: { components in
                    guard let first = components.first else { return false }
                    if components.count == 1 {
                        guard let bundleID = stripSuffix(".log", from: first) else { return false }
                        return isOrphan(bundleID)
                    }
                    return isOrphan(first)
                }
            ),
        ]

        return TargetResolution(targets: targets)
    }

    static func uninstalledAppCleaner(
        homePath: String,
        discoveryPaths: AppDiscoveryPaths,
        owner: uid_t = geteuid()
    ) -> Cleaner {
        let allowed: [CleanupCategory: Set<String>] = [
            .uninstalledAppTraces: Set(uninstalledAppTraceRootPaths(homePath: homePath)),
        ]
        return Cleaner(
            allowedRoots: allowed,
            targetResolver: { category in
                guard category == .uninstalledAppTraces else { return TargetResolution(targets: []) }
                return resolveUninstalledAppTraceTargets(homePath: homePath, discoveryPaths: discoveryPaths)
            },
            owner: owner
        )
    }
}

private func directoryBundleTarget(
    rootPath: String,
    isOrphan: @escaping @Sendable (String) -> Bool
) -> CleanupTarget {
    CleanupTarget(
        category: .uninstalledAppTraces,
        rootPath: rootPath,
        shouldDescend: { components in
            guard let first = components.first else { return false }
            return isOrphan(first)
        },
        shouldIncludeFile: { components in
            guard components.count >= 2 else { return false }
            return isOrphan(components[0])
        }
    )
}

private func stripSuffix(_ suffix: String, from value: String) -> String? {
    guard value.hasSuffix(suffix), value.count > suffix.count else { return nil }
    return String(value.dropLast(suffix.count))
}

// MARK: - Bundle ID validation

private let reverseDNSTLDs: Set<String> = [
    "com", "org", "net", "io", "app", "dev", "co", "me", "ai", "edu", "gov", "mil",
    "info", "biz", "tv", "cc", "gg", "sh", "so", "to", "uk", "de", "fr", "jp", "cn",
    "ca", "au", "nl", "ch", "se", "no", "fi", "dk", "eu", "es", "it", "pl", "ru",
    "br", "in", "kr", "nz", "at", "be", "cz", "ie", "sg", "tw", "hk", "us", "xyz",
    "tech", "software", "cloud", "tools", "design", "studio", "digital", "media",
    "games", "works", "labs", "one", "pro", "page", "site", "online", "world",
]

private let protectedBundlePrefixes = [
    "com.apple.",
    "apple.",
    "group.",
    "systemgroup.",
    "com.fluentcleaner.",
]

func isThirdPartyBundleIdentifier(_ candidate: String) -> Bool {
    let lower = candidate.lowercased()
    for prefix in protectedBundlePrefixes where lower.hasPrefix(prefix) {
        return false
    }

    let segments = lower.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count >= 3 else { return false }

    guard reverseDNSTLDs.contains(String(segments[0])) else { return false }

    for (index, segment) in segments.enumerated() {
        guard !segment.isEmpty else { return false }
        if index == 1 {
            guard let firstScalar = segment.unicodeScalars.first, isASCIIAlphanumeric(firstScalar) else {
                return false
            }
        }
        for scalar in segment.unicodeScalars {
            guard isASCIIAlphanumeric(scalar) || scalar == "-" || scalar == "_" else {
                return false
            }
        }
    }
    return true
}

private func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return (value >= 0x30 && value <= 0x39)
        || (value >= 0x41 && value <= 0x5A)
        || (value >= 0x61 && value <= 0x7A)
}

// MARK: - Bundle & LaunchAgent discovery

private let bundleExtensions: Set<String> = [
    "app", "appex", "prefpane", "qlgenerator", "saver", "xpc",
    "bundle", "plugin", "kext", "systemextension", "framework",
]

private let nestedBundleSubpaths = [
    "Contents/Library/LoginItems",
    "Contents/Applications",
    "Contents/PlugIns",
    "Contents/XPCServices",
    "Contents/Helpers",
    "Contents/Frameworks",
]

@discardableResult
private func collectBundles(in directory: URL, maxDepth: Int, into identifiers: inout Set<String>) -> Bool {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else {
        return false
    }

    for entry in entries {
        let ext = entry.pathExtension.lowercased()
        if bundleExtensions.contains(ext) {
            recordBundle(at: entry, inspectNested: ext == "app", into: &identifiers)
            continue
        }

        guard maxDepth > 1 else { continue }
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isDirectory == true && values?.isSymbolicLink != true {
            _ = collectBundles(in: entry, maxDepth: maxDepth - 1, into: &identifiers)
        }
    }
    return true
}

private func recordBundle(at bundleURL: URL, inspectNested: Bool, into identifiers: inout Set<String>) {
    let plistCandidates = [
        bundleURL.appendingPathComponent("Contents/Info.plist"),
        bundleURL.appendingPathComponent("Info.plist"),
    ]
    for plistURL in plistCandidates {
        if let dict = readPropertyListDictionary(at: plistURL),
           let identifier = dict["CFBundleIdentifier"] as? String {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty {
                identifiers.insert(trimmed)
            }
            break
        }
    }

    guard inspectNested else { return }
    let manager = FileManager.default
    for subpath in nestedBundleSubpaths {
        let nestedDir = bundleURL.appendingPathComponent(subpath, isDirectory: true)
        guard let children = try? manager.contentsOfDirectory(
            at: nestedDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }
        for child in children where bundleExtensions.contains(child.pathExtension.lowercased()) {
            recordBundle(at: child, inspectNested: false, into: &identifiers)
        }
    }
}

private func collectLaunchLabels(in directory: URL, into identifiers: inout Set<String>) {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    for entry in entries where entry.pathExtension.lowercased() == "plist" {
        guard let dict = readPropertyListDictionary(at: entry) else { continue }
        if let label = dict["Label"] as? String {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty {
                identifiers.insert(trimmed)
            }
        }
        if let single = dict["AssociatedBundleIdentifiers"] as? String {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty {
                identifiers.insert(trimmed)
            }
        } else if let multiple = dict["AssociatedBundleIdentifiers"] as? [String] {
            for item in multiple {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty {
                    identifiers.insert(trimmed)
                }
            }
        }
    }
}

private func readPropertyListDictionary(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
        return nil
    }
    return plist as? [String: Any]
}
