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

    public var id: Self { self }

    public var minimumAgeInDays: Int {
        switch self {
        case .temporaryFiles: return 7
        case .applicationCaches, .diagnosticReports: return 30
        }
    }
}

public struct CleanupFile: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let category: CleanupCategory
    public let bytes: Int64

    fileprivate let rootPath: String
    fileprivate let relativePath: [String]
    fileprivate let fingerprint: FileFingerprint
}

public struct CleanupPlan: Sendable {
    public let files: [CleanupFile]
    public let unreadableLocations: Int
    public let bytes: Int64

    fileprivate let rootIdentities: [String: FileIdentity]
}

public struct CleanupReport: Sendable {
    public fileprivate(set) var deleted = 0
    public fileprivate(set) var skipped = 0
    public fileprivate(set) var deletedBytes: Int64 = 0
}

public struct Cleaner: Sendable {
    private let roots: [CleanupCategory: String]
    private let owner: uid_t

    init(roots: [CleanupCategory: String], owner: uid_t = geteuid()) {
        self.roots = roots
        self.owner = owner
    }

    #if os(macOS)
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [CleanupCategory: String] = [
            .applicationCaches: home.appendingPathComponent("Library/Caches").path,
            .diagnosticReports: home.appendingPathComponent("Library/Logs/DiagnosticReports").path,
        ]
        roots[.temporaryFiles] = Self.userTemporaryDirectory()
        self.init(roots: roots)
    }

    static func userTemporaryDirectory() -> String? {
        let key = Int32(_CS_DARWIN_USER_TEMP_DIR)
        let length = confstr(key, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        let written = buffer.withUnsafeMutableBufferPointer { confstr(key, $0.baseAddress, $0.count) }
        guard written > 0, written <= length else { return nil }

        // macOS may spell the system-managed /private/var directory as /var.
        let components = String(cString: buffer).split(separator: "/").map(String.init)
        let path = "/" + components.joined(separator: "/")
        let canonicalPath = path.hasPrefix("/var/folders/") ? "/private" + path : path
        guard canonicalPath.hasPrefix("/private/var/folders/"), components.last == "T" else { return nil }
        return canonicalPath
    }
    #endif

    public func scan(_ categories: Set<CleanupCategory>, now: Date = Date()) -> CleanupPlan {
        var files: [CleanupFile] = []
        var rootIdentities: [String: FileIdentity] = [:]
        var unreadableLocations = 0

        for category in CleanupCategory.allCases where categories.contains(category) {
            guard let path = roots[category] else {
                unreadableLocations += 1
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

            rootIdentities[path] = FileIdentity(info)
            let cutoff = now.addingTimeInterval(-Double(category.minimumAgeInDays) * 86_400)
            scanDirectory(root, rootPath: path, relativePath: [], category: category,
                          device: info.st_dev, cutoff: cutoff, files: &files, unreadable: &unreadableLocations)
        }
        files.sort { $0.path < $1.path }
        return CleanupPlan(files: files, unreadableLocations: unreadableLocations,
                           bytes: files.reduce(0) { $0 + $1.bytes }, rootIdentities: rootIdentities)
    }

    /// Apply the previously displayed plan after the user confirms it.
    public func clean(_ plan: CleanupPlan) -> CleanupReport {
        var report = CleanupReport()
        for file in plan.files {
            guard roots[file.category] == file.rootPath,
                  let rootIdentity = plan.rootIdentities[file.rootPath],
                  deleteFile(file, rootIdentity: rootIdentity) else {
                report.skipped += 1
                continue
            }
            report.deleted += 1
            report.deletedBytes += file.bytes
        }
        return report
    }

    private func scanDirectory(_ fd: Int32, rootPath: String, relativePath: [String], category: CleanupCategory,
                               device: dev_t, cutoff: Date, files: inout [CleanupFile], unreadable: inout Int) {
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
                scanDirectory(child, rootPath: rootPath, relativePath: components, category: category,
                              device: device, cutoff: cutoff, files: &files, unreadable: &unreadable)
            case mode_t(S_IFREG):
                let fingerprint = FileFingerprint(info)
                guard info.st_nlink == 1, fingerprint.modifiedDate < cutoff else { continue }
                files.append(CleanupFile(path: rootPath + "/" + components.joined(separator: "/"),
                                         category: category, bytes: Int64(info.st_size), rootPath: rootPath,
                                         relativePath: components, fingerprint: fingerprint))
            default:
                continue
            }
        }
    }

    private func deleteFile(_ file: CleanupFile, rootIdentity: FileIdentity) -> Bool {
        var fd = openRoot(file.rootPath)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, FileIdentity(info) == rootIdentity else { return false }

        for component in file.relativePath.dropLast() {
            let child = openat(fd, component, directoryOpenFlags)
            guard child >= 0 else { return false }
            close(fd)
            fd = child
            guard fstat(fd, &info) == 0, info.st_dev == rootIdentity.device, info.st_uid == owner else { return false }
        }

        guard let name = file.relativePath.last, fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1, info.st_uid == owner,
              FileFingerprint(info) == file.fingerprint else { return false }

        return unlinkat(fd, name, 0) == 0
    }
}

private let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

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

private struct FileIdentity: Equatable, Sendable {
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
