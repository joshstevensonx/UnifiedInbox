import Foundation

// MARK: - File tools (feature spec §3.3): large files, Downloads cleanup, duplicates.
// Everything here only reads; deleting (moving to Trash) is done by the app after the user confirms.

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var size: Int64
    public var modified: Date
    public var isDirectory: Bool

    public init(path: String, size: Int64, modified: Date, isDirectory: Bool = false) {
        self.path = path; self.size = size; self.modified = modified; self.isDirectory = isDirectory
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }
}

/// Cooperative cancellation + progress for long scans.
public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var _visited = 0
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public var visited: Int { lock.lock(); defer { lock.unlock() }; return _visited }
    func tick() { lock.lock(); _visited += 1; lock.unlock() }
}

public enum FileScanner {
    /// Folders that are slow, huge or not the user's files.
    public static let skippedNames: Set<String> = [".Trash", "Library", ".git", "node_modules", ".build", "DerivedData", ".cache"]

    /// Regular files under `root` (recursively, not following symlinks, skipping hidden files and `skippedNames`).
    /// `packagesAsFiles`: treat bundles such as `.app` as one entry with their total size.
    public static func files(under root: URL, skipping: Set<String> = skippedNames, packagesAsFiles: Bool = true,
                             control: ScanControl? = nil) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .totalFileAllocatedSizeKey, .contentModificationDateKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var out: [FileEntry] = []
        while let url = e.nextObject() as? URL {
            if control?.isCancelled == true { break }
            control?.tick()
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if skipping.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                if packagesAsFiles, v.isPackage == true {
                    e.skipDescendants()
                    out.append(FileEntry(path: url.path, size: directorySize(url), modified: v.contentModificationDate ?? .distantPast, isDirectory: true))
                }
                continue
            }
            guard v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            out.append(FileEntry(path: url.path, size: size, modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
                                                     options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let u = e.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// The `limit` largest entries of at least `minSize` bytes, largest first.
    public static func largest(_ files: [FileEntry], minSize: Int64, limit: Int = 200) -> [FileEntry] {
        Array(files.filter { $0.size >= minSize }.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }.prefix(limit))
    }

    /// Only the direct children of `folder` (files and folders, folders with their total size). Used for Downloads.
    public static func children(of folder: URL) -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: keys), v.isSymbolicLink != true else { return nil }
            let dir = v.isDirectory == true
            let size = dir ? directorySize(u) : Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            return FileEntry(path: u.path, size: size, modified: v.contentModificationDate ?? .distantPast, isDirectory: dir)
        }
    }
}

// MARK: Downloads cleanup

public enum FileCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case installers, archives, images, videos, audio, documents, code, folders, other
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .installers: return "Installers"
        case .archives: return "Archives"
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .code: return "Code & data"
        case .folders: return "Folders"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .installers: return "shippingbox"
        case .archives: return "archivebox"
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "waveform"
        case .documents: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .folders: return "folder"
        case .other: return "questionmark.square.dashed"
        }
    }

    public static func of(_ f: FileEntry) -> FileCategory {
        if f.isDirectory && f.fileExtension != "app" { return .folders }
        switch f.fileExtension {
        case "dmg", "pkg", "mpkg", "app", "iso", "exe", "msi": return .installers
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return .archives
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg", "raw", "psd": return .images
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return .videos
        case "mp3", "m4a", "wav", "aiff", "flac", "aac", "ogg": return .audio
        case "pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "txt", "rtf", "md", "csv", "epub": return .documents
        case "json", "xml", "html", "js", "ts", "py", "swift", "sh", "sql", "ics", "vcf": return .code
        default: return .other
        }
    }
}

public struct CleanupGroup: Identifiable, Equatable, Sendable {
    public var id: FileCategory { category }
    public var category: FileCategory
    public var files: [FileEntry]
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum DownloadsCleanup {
    /// Groups files by category (largest group first); files sorted oldest first within each group.
    public static func groups(_ files: [FileEntry]) -> [CleanupGroup] {
        Dictionary(grouping: files, by: FileCategory.of)
            .map { CleanupGroup(category: $0.key, files: $0.value.sorted { $0.modified < $1.modified }) }
            .sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.category.rawValue < $1.category.rawValue }
    }

    /// Suggested for removal: installers and archives older than `installerDays`, anything older than `otherDays`.
    public static func suggestions(_ files: [FileEntry], now: Date = Date(), installerDays: Int = 7, otherDays: Int = 90) -> [FileEntry] {
        files.filter { f in
            let age = now.timeIntervalSince(f.modified) / 86_400
            switch FileCategory.of(f) {
            case .installers, .archives: return age >= Double(installerDays)
            default: return age >= Double(otherDays)
            }
        }
        .sorted { $0.size > $1.size }
    }
}

// MARK: Duplicates

public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public var id: String { files.first?.path ?? "" }
    public var files: [FileEntry]
    public var size: Int64 { files.first?.size ?? 0 }
    /// Space freed by keeping one copy.
    public var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

public enum DuplicateFinder {
    /// Byte-identical files. Size → hash of the first 64 KB → full hash → byte comparison, so only
    /// true duplicates are reported. Files smaller than `minSize` are ignored. Largest waste first.
    public static func find(_ files: [FileEntry], minSize: Int64 = 1, control: ScanControl? = nil) -> [DuplicateGroup] {
        let bySize = Dictionary(grouping: files.filter { !$0.isDirectory && $0.size >= minSize }, by: \.size).values.filter { $0.count > 1 }
        var groups: [DuplicateGroup] = []
        for sameSize in bySize {
            if control?.isCancelled == true { break }
            let byHead = Dictionary(grouping: sameSize) { hash($0.path, limit: 65_536) }.filter { $0.key != nil }.values.filter { $0.count > 1 }
            for candidates in byHead {
                let byFull = candidates[0].size <= 65_536
                    ? [candidates]   // whole file already hashed
                    : Array(Dictionary(grouping: candidates) { hash($0.path, limit: nil) }.filter { $0.key != nil }.values)
                for bucket in byFull where bucket.count > 1 {
                    // Confirm byte-for-byte against the first file (hash collisions are possible).
                    var remaining = bucket
                    while remaining.count > 1 {
                        let first = remaining.removeFirst()
                        let same = remaining.filter { sameContents(first.path, $0.path) }
                        remaining.removeAll { s in same.contains(s) }
                        if !same.isEmpty {
                            groups.append(DuplicateGroup(files: ([first] + same).sorted { $0.modified < $1.modified }))
                        }
                    }
                }
            }
        }
        return groups.sorted { $0.wasted != $1.wasted ? $0.wasted > $1.wasted : $0.id < $1.id }
    }

    /// FNV-1a 64-bit hash of the file (or its first `limit` bytes). nil if unreadable.
    public static func hash(_ path: String, limit: Int?) -> UInt64? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = h.readData(ofLength: min(1 << 20, remaining))
            if chunk.isEmpty { break }
            for b in chunk { hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3 }
            remaining -= chunk.count
        }
        return hash
    }

    public static func sameContents(_ a: String, _ b: String) -> Bool {
        guard let ha = FileHandle(forReadingAtPath: a), let hb = FileHandle(forReadingAtPath: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        while true {
            let da = ha.readData(ofLength: 1 << 20), db = hb.readData(ofLength: 1 << 20)
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }

    /// Which copy to keep: the oldest (original) by default, or the newest.
    public static func filesToRemove(_ g: DuplicateGroup, keepNewest: Bool = false) -> [FileEntry] {
        let sorted = g.files.sorted { $0.modified < $1.modified }
        return keepNewest ? Array(sorted.dropLast()) : Array(sorted.dropFirst())
    }
}
