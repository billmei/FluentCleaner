import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case temporaryFiles = "Temporary files"
    case applicationCaches = "App caches"
    case diagnosticReports = "Diagnostic reports"
    case browserData = "Browser data"

    public var id: Self { self }

    public var minimumAgeInDays: Int? {
        switch self {
        case .temporaryFiles: return 7
        case .applicationCaches, .diagnosticReports: return 30
        case .browserData: return nil
        }
    }

    public var summary: String {
        switch self {
        case .temporaryFiles, .applicationCaches, .diagnosticReports:
            if let days = minimumAgeInDays {
                return "Last modified over \(days) days ago"
            }
            return ""
        case .browserData:
            return "History, cookies, sessions, caches, and site storage"
        }
    }

    public var isSelectedByDefault: Bool {
        self == .temporaryFiles
    }

    var scanPriority: Int {
        switch self {
        case .browserData: return 10
        case .temporaryFiles: return 50
        case .applicationCaches: return 60
        case .diagnosticReports: return 70
        }
    }
}

public struct CleanupFile: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let category: CleanupCategory
    public let bytes: Int64

    fileprivate let rootPath: String
    fileprivate let rootIdentity: FileIdentity
    fileprivate let relativePath: [String]
    fileprivate let fingerprint: FileFingerprint
}

public struct CleanupPlan: Sendable {
    public let files: [CleanupFile]
    public let unreadableLocations: Int
    public let bytes: Int64
}

public struct CleanupReport: Sendable {
    public fileprivate(set) var deleted = 0
    public fileprivate(set) var skipped = 0
    public fileprivate(set) var deletedBytes: Int64 = 0
}

struct CleanupTarget: Sendable {
    let category: CleanupCategory
    let rootPath: String?
    let minimumAgeInDays: Int?
    let missingRootIsUnreadable: Bool
    let maxDepth: Int?
    let shouldDescend: @Sendable ([String]) -> Bool
    let shouldIncludeFile: @Sendable ([String]) -> Bool

    init(
        category: CleanupCategory,
        rootPath: String?,
        minimumAgeInDays: Int? = nil,
        missingRootIsUnreadable: Bool = false,
        maxDepth: Int? = nil,
        shouldDescend: @escaping @Sendable ([String]) -> Bool = { _ in true },
        shouldIncludeFile: @escaping @Sendable ([String]) -> Bool = { _ in true }
    ) {
        self.category = category
        self.rootPath = rootPath.map(trimTrailingSlashes)
        self.minimumAgeInDays = minimumAgeInDays
        self.missingRootIsUnreadable = missingRootIsUnreadable
        self.maxDepth = maxDepth
        self.shouldDescend = shouldDescend
        self.shouldIncludeFile = shouldIncludeFile
    }
}

struct TargetResolution: Sendable {
    let targets: [CleanupTarget]
    let unreadableLocations: Int

    init(targets: [CleanupTarget], unreadableLocations: Int = 0) {
        self.targets = targets
        self.unreadableLocations = unreadableLocations
    }
}

public struct Cleaner: Sendable {
    private let allowedRoots: [CleanupCategory: Set<String>]
    private let targetResolver: @Sendable (CleanupCategory) -> TargetResolution
    private let owner: uid_t

    init(roots: [CleanupCategory: String], owner: uid_t = geteuid()) {
        let targets = CleanupCategory.allCases.map { category in
            CleanupTarget(
                category: category,
                rootPath: roots[category],
                minimumAgeInDays: category.minimumAgeInDays,
                missingRootIsUnreadable: true
            )
        }
        self.init(targets: targets, owner: owner)
    }

    init(targets: [CleanupTarget], owner: uid_t = geteuid()) {
        var byCategory: [CleanupCategory: [CleanupTarget]] = [:]
        var allowed: [CleanupCategory: Set<String>] = [:]
        for target in targets {
            byCategory[target.category, default: []].append(target)
            if let rootPath = target.rootPath {
                allowed[target.category, default: []].insert(rootPath)
            }
        }
        let grouped = byCategory
        self.init(allowedRoots: allowed, targetResolver: { category in
            TargetResolution(targets: grouped[category] ?? [])
        }, owner: owner)
    }

    init(
        allowedRoots: [CleanupCategory: Set<String>],
        targetResolver: @escaping @Sendable (CleanupCategory) -> TargetResolution,
        owner: uid_t = geteuid()
    ) {
        self.allowedRoots = allowedRoots.mapValues { Set($0.map(trimTrailingSlashes)) }
        self.targetResolver = targetResolver
        self.owner = owner
    }

    #if os(macOS)
    public init() {
        let homePath = trimTrailingSlashes(FileManager.default.homeDirectoryForCurrentUser.path)
        var targets: [CleanupTarget] = [
            CleanupTarget(
                category: .temporaryFiles,
                rootPath: Self.userTemporaryDirectory(),
                minimumAgeInDays: CleanupCategory.temporaryFiles.minimumAgeInDays,
                missingRootIsUnreadable: true
            ),
            CleanupTarget(
                category: .applicationCaches,
                rootPath: homePath + "/Library/Caches",
                minimumAgeInDays: CleanupCategory.applicationCaches.minimumAgeInDays
            ),
            CleanupTarget(
                category: .diagnosticReports,
                rootPath: homePath + "/Library/Logs/DiagnosticReports",
                minimumAgeInDays: CleanupCategory.diagnosticReports.minimumAgeInDays
            ),
        ]
        targets.append(contentsOf: Self.browserDataTargets(homePath: homePath))
        self.init(targets: targets)
    }

    static func userTemporaryDirectory() -> String? {
        userDarwinDirectory(Int32(_CS_DARWIN_USER_TEMP_DIR), expectedLeaf: "T")
    }

    static func userDarwinDirectory(_ key: Int32, expectedLeaf: String) -> String? {
        let length = confstr(key, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        let written = buffer.withUnsafeMutableBufferPointer { confstr(key, $0.baseAddress, $0.count) }
        guard written > 0, written <= length else { return nil }

        // macOS may spell the system-managed /private/var directory as /var.
        let components = String(cString: buffer).split(separator: "/").map(String.init)
        let path = "/" + components.joined(separator: "/")
        let canonicalPath = path.hasPrefix("/var/folders/") ? "/private" + path : path
        guard canonicalPath.hasPrefix("/private/var/folders/"), components.last == expectedLeaf else { return nil }
        return canonicalPath
    }
    #endif

    public func scan(_ categories: Set<CleanupCategory>, now: Date = Date()) -> CleanupPlan {
        var files: [CleanupFile] = []
        var seenIdentities: Set<FileIdentity> = []
        var unreadableLocations = 0

        let orderedCategories = CleanupCategory.allCases
            .filter { categories.contains($0) }
            .sorted { ($0.scanPriority, $0.rawValue) < ($1.scanPriority, $1.rawValue) }

        for category in orderedCategories {
            let resolution = targetResolver(category)
            unreadableLocations += resolution.unreadableLocations

            for target in resolution.targets {
                guard let path = target.rootPath else {
                    if target.missingRootIsUnreadable { unreadableLocations += 1 }
                    continue
                }
                let root = openRoot(path)
                guard root >= 0 else {
                    if errno != ENOENT { unreadableLocations += 1 }
                    continue
                }
                defer { close(root) }

                var info = stat()
                guard fstat(root, &info) == 0, info.st_uid == owner else {
                    unreadableLocations += 1
                    continue
                }

                let rootIdentity = FileIdentity(info)
                let cutoff = target.minimumAgeInDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
                scanDirectory(
                    root,
                    target: target,
                    rootPath: path,
                    rootIdentity: rootIdentity,
                    relativePath: [],
                    device: info.st_dev,
                    cutoff: cutoff,
                    files: &files,
                    seenIdentities: &seenIdentities,
                    unreadable: &unreadableLocations
                )
            }
        }
        files.sort { $0.path < $1.path }
        return CleanupPlan(
            files: files,
            unreadableLocations: unreadableLocations,
            bytes: files.reduce(0) { $0 + $1.bytes }
        )
    }

    /// Apply the previously displayed plan after the user confirms it.
    public func clean(_ plan: CleanupPlan) -> CleanupReport {
        var report = CleanupReport()
        for file in plan.files {
            guard allowedRoots[file.category]?.contains(file.rootPath) == true,
                  deleteFile(file) else {
                report.skipped += 1
                continue
            }
            report.deleted += 1
            report.deletedBytes += file.bytes
        }
        return report
    }

    private func scanDirectory(
        _ fd: Int32,
        target: CleanupTarget,
        rootPath: String,
        rootIdentity: FileIdentity,
        relativePath: [String],
        device: dev_t,
        cutoff: Date?,
        files: inout [CleanupFile],
        seenIdentities: inout Set<FileIdentity>,
        unreadable: inout Int
    ) {
        // fdopendir owns its descriptor. Keep the original for descriptor-relative lookups.
        let directoryFD = dup(fd)
        guard directoryFD >= 0 else {
            unreadable += 1
            return
        }
        guard let stream = fdopendir(directoryFD) else {
            close(directoryFD)
            unreadable += 1
            return
        }
        defer { closedir(stream) }

        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { unreadable += 1 }
                return
            }
            // Preserve the exact on-disk bytes when converting names for openat and unlinkat.
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingUTF8: $0) }
            }
            guard let name, name != ".", name != ".." else { continue }

            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { unreadable += 1 }
                continue
            }
            guard info.st_dev == device, info.st_uid == owner else { continue }

            let components = relativePath + [name]
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                if let maxDepth = target.maxDepth, components.count >= maxDepth {
                    continue
                }
                guard target.shouldDescend(components) else { continue }
                let child = openat(fd, name, directoryOpenFlags)
                guard child >= 0 else {
                    unreadable += 1
                    continue
                }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_uid == owner,
                      FileIdentity(opened) == FileIdentity(info) else {
                    unreadable += 1
                    continue
                }
                scanDirectory(
                    child,
                    target: target,
                    rootPath: rootPath,
                    rootIdentity: rootIdentity,
                    relativePath: components,
                    device: device,
                    cutoff: cutoff,
                    files: &files,
                    seenIdentities: &seenIdentities,
                    unreadable: &unreadable
                )
            case mode_t(S_IFREG):
                guard target.shouldIncludeFile(components) else { continue }
                let fingerprint = FileFingerprint(info)
                guard info.st_nlink == 1 else { continue }
                if let cutoff, fingerprint.modifiedDate >= cutoff { continue }
                guard seenIdentities.insert(fingerprint.identity).inserted else { continue }
                files.append(CleanupFile(
                    path: rootPath + "/" + components.joined(separator: "/"),
                    category: target.category,
                    bytes: Int64(info.st_size),
                    rootPath: rootPath,
                    rootIdentity: rootIdentity,
                    relativePath: components,
                    fingerprint: fingerprint
                ))
            default:
                continue
            }
        }
    }

    private func deleteFile(_ file: CleanupFile) -> Bool {
        var fd = openRoot(file.rootPath)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, FileIdentity(info) == file.rootIdentity else { return false }

        for component in file.relativePath.dropLast() {
            let child = openat(fd, component, directoryOpenFlags)
            guard child >= 0 else { return false }
            close(fd)
            fd = child
            guard fstat(fd, &info) == 0, info.st_dev == file.rootIdentity.device, info.st_uid == owner else { return false }
        }

        guard let name = file.relativePath.last, fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1, info.st_uid == owner,
              FileFingerprint(info) == file.fingerprint else { return false }

        return unlinkat(fd, name, 0) == 0
    }
}

private let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

private func trimTrailingSlashes(_ path: String) -> String {
    var result = path
    while result.count > 1 && result.hasSuffix("/") {
        result.removeLast()
    }
    return result
}

// Open every ancestor without following symlinks, including ones above the cleanup root.
private func openRoot(_ path: String) -> Int32 {
    let components = path.split(separator: "/")
    guard path.hasPrefix("/"), !components.isEmpty,
          components.allSatisfy({ $0 != "." && $0 != ".." }) else {
        errno = EINVAL
        return -1
    }

    var fd = open("/", directoryOpenFlags)
    guard fd >= 0 else { return -1 }
    for component in components {
        let next = openat(fd, String(component), directoryOpenFlags)
        let failure = errno
        close(fd)
        guard next >= 0 else {
            errno = failure
            return -1
        }
        fd = next
    }
    return fd
}

private struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

private struct FileFingerprint: Equatable, Sendable {
    let identity: FileIdentity
    let size: off_t
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var modifiedDate: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }

    init(_ info: stat) {
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        #endif
        identity = FileIdentity(info)
        size = info.st_size
        modifiedSeconds = Int64(modified.tv_sec)
        modifiedNanoseconds = Int64(modified.tv_nsec)
        changedSeconds = Int64(changed.tv_sec)
        changedNanoseconds = Int64(changed.tv_nsec)
    }
}
