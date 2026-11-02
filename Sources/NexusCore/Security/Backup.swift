import Foundation
#if canImport(CryptoKit) && canImport(CommonCrypto)
import CommonCrypto
import CryptoKit
#endif

// MARK: - Backup archive (task 18)
//
// File layout of a `.uibackup` file:
//   "UIBE1" | salt (16) | PBKDF2 iterations (UInt32 BE) | AES-GCM combined box (nonce 12 + ciphertext + tag 16)
// The plaintext is a `BackupArchive`:
//   "UIBA1" | manifest length (UInt32 BE) | manifest JSON | file bytes back to back

public enum BackupError: Error, Equatable, LocalizedError {
    case notABackup, unsupportedVersion, corrupt, unsafePath(String), wrongPassword, cryptoUnavailable

    public var errorDescription: String? {
        switch self {
        case .notABackup: return "This file isn't a Unified Inbox backup."
        case .unsupportedVersion: return "This backup was made by a newer version of the app."
        case .corrupt: return "The backup is damaged."
        case .unsafePath(let p): return "The backup contains an unsafe path: \(p)"
        case .wrongPassword: return "Wrong password, or the backup was modified."
        case .cryptoUnavailable: return "Encryption isn't available on this system."
        }
    }
}

public struct BackupManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int
    }
    public var version = 1
    public var created: Date
    public var appVersion: String
    public var entries: [Entry]
}

public enum BackupArchive {
    static let magic = Data("UIBA1".utf8)

    /// Relative paths only, no "..", no hidden components that could escape the folder.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    public static func pack(_ files: [String: Data], created: Date = Date(), appVersion: String = "") throws -> Data {
        let paths = files.keys.sorted()
        for p in paths where !isSafe(p) { throw BackupError.unsafePath(p) }
        let manifest = BackupManifest(created: created, appVersion: appVersion,
                                      entries: paths.map { .init(path: $0, size: files[$0]!.count) })
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .sortedKeys
        let json = try enc.encode(manifest)
        var out = magic
        out.append(uint32: UInt32(json.count))
        out.append(json)
        for p in paths { out.append(files[p]!) }
        return out
    }

    public static func unpack(_ data: Data) throws -> (manifest: BackupManifest, files: [String: Data]) {
        guard data.count >= magic.count + 4, data.prefix(magic.count) == magic else { throw BackupError.notABackup }
        var offset = data.startIndex + magic.count
        guard let len = data.readUInt32(at: offset) else { throw BackupError.corrupt }
        offset += 4
        guard offset + Int(len) <= data.endIndex else { throw BackupError.corrupt }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let manifest = try? dec.decode(BackupManifest.self, from: data[offset..<(offset + Int(len))]) else { throw BackupError.corrupt }
        guard manifest.version <= 1 else { throw BackupError.unsupportedVersion }
        offset += Int(len)
        var files: [String: Data] = [:]
        for e in manifest.entries {
            guard isSafe(e.path) else { throw BackupError.unsafePath(e.path) }
            guard e.size >= 0, offset + e.size <= data.endIndex else { throw BackupError.corrupt }
            files[e.path] = Data(data[offset..<(offset + e.size)])
            offset += e.size
        }
        guard offset == data.endIndex else { throw BackupError.corrupt }
        return (manifest, files)
    }

    /// Every regular file under `folder` (relative paths), skipping names in `excluding` and hidden files.
    public static func collect(from folder: URL, excluding: Set<String> = []) -> [String: Data] {
        let base = folder.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: Data] = [:]
        while let url = e.nextObject() as? URL {
            if excluding.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            out[String(full.dropFirst(base.count + 1))] = data
        }
        return out
    }

    /// Writes files into `folder`, creating subfolders. Paths are re-checked.
    public static func write(_ files: [String: Data], to folder: URL) throws {
        let fm = FileManager.default
        for (path, data) in files {
            guard isSafe(path) else { throw BackupError.unsafePath(path) }
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Staged restore
// Restoring over a live database is unsafe, so a restore is unpacked into a staging folder and swapped in
// at the next launch, before anything opens the data files.

public enum StagedRestore {
    public static func stagingFolder(for base: URL) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + ".restore", isDirectory: true)
    }

    public static func stage(_ files: [String: Data], for base: URL) throws {
        let staging = stagingFolder(for: base)
        try? FileManager.default.removeItem(at: staging)
        try BackupArchive.write(files, to: staging)
    }

    public static func hasPending(for base: URL) -> Bool {
        FileManager.default.fileExists(atPath: stagingFolder(for: base).path)
    }

    /// Moves the current folder aside (`<name>.before-restore`, replacing an older one) and the staged
    /// copy into place. Returns true if a restore was applied.
    @discardableResult
    public static func applyPending(for base: URL) throws -> Bool {
        let fm = FileManager.default
        let staging = stagingFolder(for: base)
        guard fm.fileExists(atPath: staging.path) else { return false }
        let previous = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + ".before-restore", isDirectory: true)
        try? fm.removeItem(at: previous)
        if fm.fileExists(atPath: base.path) { try fm.moveItem(at: base, to: previous) }
        try fm.moveItem(at: staging, to: base)
        return true
    }
}

// MARK: - Encryption

public enum BackupCrypto {
    static let magic = Data("UIBE1".utf8)
    public static let defaultIterations: UInt32 = 210_000

    public static var isAvailable: Bool {
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        return true
        #else
        return false
        #endif
    }

    /// Parses the header without decrypting. Returns (salt, iterations, sealed box bytes).
    public static func parseHeader(_ data: Data) throws -> (salt: Data, iterations: UInt32, box: Data) {
        guard data.count > magic.count + 16 + 4 + 28, data.prefix(magic.count) == magic else { throw BackupError.notABackup }
        let s = data.startIndex + magic.count
        let salt = Data(data[s..<(s + 16)])
        guard let iterations = data.readUInt32(at: s + 16), iterations > 0 else { throw BackupError.corrupt }
        return (salt, iterations, Data(data[(s + 20)...]))
    }

    public static func header(salt: Data, iterations: UInt32) -> Data {
        var h = magic
        h.append(salt)
        h.append(uint32: iterations)
        return h
    }

    #if canImport(CryptoKit) && canImport(CommonCrypto)
    public static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let keyLength = 32
        var key = [UInt8](repeating: 0, count: keyLength)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                          saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &key, keyLength)
        guard status == Int32(kCCSuccess) else { throw BackupError.cryptoUnavailable }
        return SymmetricKey(data: key)
    }

    public static func encrypt(_ plain: Data, password: String, iterations: UInt32 = defaultIterations) throws -> Data {
        // 16 random bytes from the system CSPRNG (via CryptoKit).
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let head = header(salt: salt, iterations: iterations)
        // The header is authenticated too, so salt / iteration tampering is detected.
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: head).combined else { throw BackupError.cryptoUnavailable }
        return head + combined
    }

    public static func decrypt(_ data: Data, password: String) throws -> Data {
        let (salt, iterations, box) = try parseHeader(data)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: header(salt: salt, iterations: iterations))
        } catch {
            throw BackupError.wrongPassword
        }
    }
    #endif
}

// MARK: - App lock policy

/// When the app should ask for Touch ID / password again.
public struct LockPolicy: Codable, Equatable, Sendable {
    public var enabled = false
    /// Lock after the app has been in the background this long. 0 = every time it's left.
    public var lockAfterMinutes: Double = 5
    public var lockOnSleep = true
    public var lockOnScreenLock = true
    public init() {}

    public enum Event: Sendable { case appActivated(lastActive: Date?), systemSleep, screenLocked, launch }

    public func shouldLock(on event: Event, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        switch event {
        case .launch: return true
        case .systemSleep: return lockOnSleep
        case .screenLocked: return lockOnScreenLock
        case .appActivated(let last):
            guard let last else { return true }
            return now.timeIntervalSince(last) >= lockAfterMinutes * 60
        }
    }
}

// MARK: - Data helpers

extension Data {
    mutating func append(uint32 v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    func readUInt32(at i: Index) -> UInt32? {
        guard i >= startIndex, i + 4 <= endIndex else { return nil }
        return self[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
