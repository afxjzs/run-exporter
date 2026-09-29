import Foundation

/// A real CSV writer with RFC 4180 escaping. UTF-8 preserved by the caller when encoding to Data.
struct CSVWriter {
    private var lines: [String] = []
    let columns: [String]

    init(columns: [String]) {
        self.columns = columns
        lines.append(Self.encodeRow(columns))
    }

    mutating func addRow(_ values: [String]) {
        // Defensive: pad/truncate to column count so the CSV stays rectangular.
        var row = values
        if row.count < columns.count {
            row.append(contentsOf: Array(repeating: "", count: columns.count - row.count))
        } else if row.count > columns.count {
            row = Array(row.prefix(columns.count))
        }
        lines.append(Self.encodeRow(row))
    }

    /// Full CSV text with a trailing newline.
    var text: String {
        lines.joined(separator: "\r\n") + "\r\n"
    }

    var data: Data {
        Data(text.utf8)
    }

    // MARK: - Escaping

    static func encodeRow(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// Quote a field if it contains comma, double-quote, newline, or carriage return.
    /// Escape embedded quotes by doubling them.
    static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
        guard needsQuoting else { return field }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
