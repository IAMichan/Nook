import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Reads and rewrites the stat data in a Git index file (`.git/index`, version 2 or 3, SHA-1 repositories).
///
/// A worktree cloned from a cached checkout holds the right files, but every inode and change time differs from what the
/// cached index recorded, so Git would read every file again on the first `git status`. Writing each file's own stat data
/// into the index makes the checkout look as if Git had written it. Foundation only, so it is tested on its own.
enum GitIndexStat {
    /// What `lstat` says about one file, as far as the index keeps it.
    struct FileStat: Equatable, Sendable {
        var ctimeSeconds: UInt32
        var ctimeNanoseconds: UInt32
        var mtimeSeconds: UInt32
        var mtimeNanoseconds: UInt32
        var device: UInt32
        var inode: UInt32
        var uid: UInt32
        var gid: UInt32
        var size: UInt32
    }

    /// One index entry: where its stat data sits in the file and what it records.
    struct Entry: Equatable, Sendable {
        var path: String
        var mode: UInt32
        var offset: Int
        var stat: FileStat

        /// A regular file or a symbolic link: the kinds whose stat data Git compares (a gitlink is a submodule).
        var hasFileStat: Bool {
            let type = mode & 0o170000
            return type == 0o100000 || type == 0o120000
        }
    }

    enum Problem: Error, Equatable {
        /// Not an index Nook can rewrite (version 4 compresses paths, a SHA-256 repository has longer ids).
        case unsupported
        case truncated
        /// A file differs from what the index recorded for it (`verify`), or is missing.
        case changed(String)
    }

    static let signature: [UInt8] = Array("DIRC".utf8)
    private static let hashLength = 20

    /// The entries of an index, in order.
    static func entries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 + hashLength, Array(bytes[0..<4]) == signature else { throw Problem.unsupported }
        let version = word(bytes, 4)
        guard version == 2 || version == 3 else { throw Problem.unsupported }
        let count = Int(word(bytes, 8))
        var result: [Entry] = []
        result.reserveCapacity(count)
        var offset = 12
        let end = bytes.count - hashLength
        for _ in 0..<count {
            guard offset + 62 <= end else { throw Problem.truncated }
            let flags = UInt16(bytes[offset + 60]) << 8 | UInt16(bytes[offset + 61])
            let extended = flags & 0x4000 != 0
            if extended, version < 3 { throw Problem.unsupported }
            let nameStart = offset + (extended ? 64 : 62)
            guard nameStart <= end else { throw Problem.truncated }
            var nameEnd = nameStart
            while nameEnd < end, bytes[nameEnd] != 0 { nameEnd += 1 }
            guard nameEnd < end else { throw Problem.truncated }
            let path = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            let stat = FileStat(ctimeSeconds: word(bytes, offset), ctimeNanoseconds: word(bytes, offset + 4),
                                mtimeSeconds: word(bytes, offset + 8), mtimeNanoseconds: word(bytes, offset + 12),
                                device: word(bytes, offset + 16), inode: word(bytes, offset + 20),
                                uid: word(bytes, offset + 28), gid: word(bytes, offset + 32), size: word(bytes, offset + 36))
            result.append(Entry(path: path, mode: word(bytes, offset + 24), offset: offset, stat: stat))
            // The entry is padded with 1 to 8 NULs to a multiple of eight bytes.
            let length = (nameStart - offset) + (nameEnd - nameStart)
            offset += (length + 8) & ~7
        }
        return result
    }

    /// The index with each file's stat data replaced by `stat(path)` (nil leaves the entry as it was), and a new checksum.
    /// With `verify`, a file whose size or modification time differs from the recorded one is refused: the files must be
    /// the ones the index was written for.
    static func restated(_ data: Data, verify: Bool, stat: (String) -> FileStat?) throws -> Data {
        var bytes = [UInt8](data)
        for entry in try entries(data) where entry.hasFileStat {
            guard let now = stat(entry.path) else {
                if verify { throw Problem.changed(entry.path) }
                continue
            }
            if verify, now.size != entry.stat.size || now.mtimeSeconds != entry.stat.mtimeSeconds
                || now.mtimeNanoseconds != entry.stat.mtimeNanoseconds {
                throw Problem.changed(entry.path)
            }
            let fields: [(Int, UInt32)] = [(0, now.ctimeSeconds), (4, now.ctimeNanoseconds), (8, now.mtimeSeconds),
                                           (12, now.mtimeNanoseconds), (16, now.device), (20, now.inode),
                                           (28, now.uid), (32, now.gid), (36, now.size)]
            for (at, value) in fields { put(&bytes, entry.offset + at, value) }
        }
        let body = bytes[0..<(bytes.count - hashLength)]
        let checksum = try sha1(Data(body))
        bytes.replaceSubrange((bytes.count - hashLength)..<bytes.count, with: checksum)
        return Data(bytes)
    }

    /// `lstat` of `root/path` in the index's terms; nil when the file is missing.
    static func lstat(root: String, path: String) -> FileStat? {
        var info = stat()
        guard Darwin.lstat(root + "/" + path, &info) == 0 else { return nil }
        return FileStat(ctimeSeconds: UInt32(truncatingIfNeeded: info.st_ctimespec.tv_sec),
                        ctimeNanoseconds: UInt32(truncatingIfNeeded: info.st_ctimespec.tv_nsec),
                        mtimeSeconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec),
                        mtimeNanoseconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec),
                        device: UInt32(truncatingIfNeeded: info.st_dev), inode: UInt32(truncatingIfNeeded: info.st_ino),
                        uid: info.st_uid, gid: info.st_gid, size: UInt32(truncatingIfNeeded: info.st_size))
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func put(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        bytes[at] = UInt8(value >> 24 & 0xff)
        bytes[at + 1] = UInt8(value >> 16 & 0xff)
        bytes[at + 2] = UInt8(value >> 8 & 0xff)
        bytes[at + 3] = UInt8(value & 0xff)
    }

    private static func sha1(_ data: Data) throws -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(Insecure.SHA1.hash(data: data))
        #else
        throw Problem.unsupported
        #endif
    }
}
