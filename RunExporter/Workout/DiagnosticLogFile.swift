import Foundation

/// An append-only text file in the app's Documents folder, for diagnostics that must be readable
/// off the phone without anyone reading a screen:
///
///     xcrun devicectl device copy from --device <phone> --domain-type appDataContainer \
///       --domain-identifier is.doug.runexporter --source Documents/<name> --destination <local>
///
/// Built after an on-screen watch log was cleared by accident mid-investigation and took the
/// evidence with it. One entry per line; a newline inside an entry is flattened so a reader never
/// counts one event as two. A failed write **throws** — a diagnostic file that silently stops
/// recording would repeat that loss invisibly.
struct DiagnosticLogFile {
    let url: URL

    /// A file in this app's Documents folder.
    static func inDocuments(named name: String) -> DiagnosticLogFile? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return DiagnosticLogFile(url: documents.appendingPathComponent(name))
    }

    func append(_ line: String) throws {
        let flattened = line.replacingOccurrences(of: "\n", with: " ⏎ ")
        let data = Data((flattened + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }   // Closing after a successful write; the write's own error is thrown.
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}
