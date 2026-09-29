import Foundation
import Compression

/// A small, dependency-free standard ZIP writer.
///
/// Produces a conventional ZIP (local file headers + central directory + EOCD) using DEFLATE
/// (method 8) via Apple's Compression framework, falling back to STORED (method 0) when
/// compression would not help. The output is readable by macOS Archive Utility, Windows,
/// Python's `zipfile`, and file-upload consumers — no proprietary Apple Archive format.
enum ZipService {

    struct Entry {
        let path: String   // relative path inside the zip, e.g. "folder/file.csv"
        let data: Data
        let modified: Date // modification timestamp for the zip entry
    }

    enum ZipError: Error { case compressionFailed }

    /// Zip the contents of `folderURL` (recursively) into `destinationURL`.
    /// Entries are stored relative to `folderURL`'s parent, so the top folder is preserved.
    /// - Parameter entryDate: applied as the modification timestamp for **every** entry, so all
    ///   entries agree with each other and with the export's `export_created_at`. If nil, each
    ///   file's on-disk modification date is used instead.
    static func zipFolder(at folderURL: URL, to destinationURL: URL, entryDate: Date? = nil) throws {
        let fm = FileManager.default
        let baseName = folderURL.lastPathComponent
        var entries: [Entry] = []

        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: folderURL,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadUnknown)
        }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values.isDirectory == true { continue }
            let data = try Data(contentsOf: fileURL)
            let modified = entryDate ?? values.contentModificationDate ?? Date()
            // Relative path including the top folder name.
            let relative = baseName + "/" + relativePath(of: fileURL, under: folderURL)
            entries.append(Entry(path: relative, data: data, modified: modified))
        }

        let archive = try build(entries: entries.sorted { $0.path < $1.path })
        try archive.write(to: destinationURL, options: .atomic)
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        let tail = urlComponents.dropFirst(baseComponents.count)
        return tail.joined(separator: "/")
    }

    // MARK: - ZIP construction

    static func build(entries: [Entry]) throws -> Data {
        var output = Data()
        var central = Data()

        for entry in entries {
            let (dosTime, dosDate) = dosDateTime(from: entry.modified)
            let nameBytes = Array(entry.path.utf8)
            let crc = crc32(entry.data)
            let uncompressedSize = UInt32(entry.data.count)

            let (method, payload) = compress(entry.data)
            let compressedSize = UInt32(payload.count)
            let localHeaderOffset = UInt32(output.count)

            // Local file header
            var local = Data()
            local.appendLE(UInt32(0x04034b50))   // signature
            local.appendLE(UInt16(20))           // version needed
            local.appendLE(UInt16(0))            // flags
            local.appendLE(method)               // compression method
            local.appendLE(dosTime)
            local.appendLE(dosDate)
            local.appendLE(crc)
            local.appendLE(compressedSize)
            local.appendLE(uncompressedSize)
            local.appendLE(UInt16(nameBytes.count))
            local.appendLE(UInt16(0))            // extra length
            local.append(contentsOf: nameBytes)
            output.append(local)
            output.append(payload)

            // Central directory header
            central.appendLE(UInt32(0x02014b50)) // signature
            central.appendLE(UInt16(20))         // version made by
            central.appendLE(UInt16(20))         // version needed
            central.appendLE(UInt16(0))          // flags
            central.appendLE(method)
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(compressedSize)
            central.appendLE(uncompressedSize)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))          // extra length
            central.appendLE(UInt16(0))          // comment length
            central.appendLE(UInt16(0))          // disk number start
            central.appendLE(UInt16(0))          // internal attrs
            central.appendLE(UInt32(0))          // external attrs
            central.appendLE(localHeaderOffset)
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(output.count)
        let centralSize = UInt32(central.count)
        output.append(central)

        // End of central directory record
        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))        // signature
        eocd.appendLE(UInt16(0))                 // disk number
        eocd.appendLE(UInt16(0))                 // disk with central directory
        eocd.appendLE(UInt16(entries.count))     // entries on this disk
        eocd.appendLE(UInt16(entries.count))     // total entries
        eocd.appendLE(centralSize)
        eocd.appendLE(centralOffset)
        eocd.appendLE(UInt16(0))                 // comment length
        output.append(eocd)

        return output
    }

    /// Convert a Date into MS-DOS (time, date) fields used by ZIP local/central headers.
    /// DOS epoch is 1980; seconds have 2-second resolution. Values are clamped to the
    /// representable range so tools like `unzip -l` always show a valid date.
    ///
    /// Bit layout — time: hour 15-11, minute 10-5, second/2 4-0.
    ///              date: year-1980 15-9, month 8-5, day 4-0.
    static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let year = max(1980, min(2107, c.year ?? 1980))
        let month = max(1, min(12, c.month ?? 1))
        let day = max(1, min(31, c.day ?? 1))
        let hour = max(0, min(23, c.hour ?? 0))
        let minute = max(0, min(59, c.minute ?? 0))
        let second = max(0, min(59, c.second ?? 0))

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        // Day occupies bits 4-0, so the month field starts at bit 5. Shifting by 4 overlapped
        // the two, which reported the wrong month (and, for some days, the wrong day).
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    /// Returns (method, payload). method 8 = DEFLATE, method 0 = STORED.
    private static func compress(_ data: Data) -> (UInt16, Data) {
        if data.isEmpty { return (0, data) }
        if let deflated = deflate(data), deflated.count < data.count {
            return (8, deflated)
        }
        return (0, data)
    }

    /// Raw DEFLATE stream (no zlib header/trailer) — exactly what ZIP method 8 requires.
    /// Apple's COMPRESSION_ZLIB emits a raw DEFLATE stream.
    private static func deflate(_ data: Data) -> Data? {
        let dstCapacity = data.count + 64 * 1024
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_encode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        dst.removeSubrange(written..<dst.count)
        return dst
    }

    // MARK: - CRC32 (IEEE 802.3, as ZIP requires)

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                let idx = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = crcTable[idx] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
