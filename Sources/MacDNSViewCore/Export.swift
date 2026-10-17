import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case table, csv, tsv, json, html
}

extension Row {
    public static let columns = ["Index", "Target", "Type", "Name", "Address", "Data", "Section", "TTL", "Server", "Time (ms)", "Validated", "Differs"]

    public var fields: [String] {
        [String(index), target, type.description, name, address, data, section?.rawValue ?? "", ttl.map(String.init) ?? "", server,
         time.map(String.init) ?? "", yesNo(validated), yesNo(differs)]
    }

    private func yesNo(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "" }

    public func with(data: String) -> Row {
        var row = self
        row.data = data
        return row
    }
}

public func export(_ rows: [Row], as format: ExportFormat, columns: [Int] = Array(Row.columns.indices)) -> String {
    let header = columns.map { Row.columns[$0] }
    let lines = rows.map { row in columns.map { row.fields[$0] } }
    return switch format {
    case .table: table(header, lines)
    case .csv: delimited(header, lines, separator: ",", escape: csvField)
    case .tsv: delimited(header, lines, separator: "\t") { $0.replacing(/[\t\r\n]/, with: " ") }
    case .json: json(rows, columns: columns)
    case .html: html(header, lines, errors: rows.map { $0.error != nil })
    }
}

public func export(header: [String], lines: [[String]], as format: ExportFormat) -> String {
    switch format {
    case .table: return table(header, lines)
    case .csv: return delimited(header, lines, separator: ",", escape: csvField)
    case .tsv: return delimited(header, lines, separator: "\t") { $0.replacing(/[\t\r\n]/, with: " ") }
    case .html: return html(header, lines, errors: lines.map { _ in false })
    case .json:
        let objects = lines.map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(objects)) ?? Data(), as: UTF8.self) + "\n"
    }
}

private func delimited(_ header: [String], _ lines: [[String]], separator: String, escape: (String) -> String) -> String {
    ([header] + lines)
        .map { $0.map(escape).joined(separator: separator) + "\n" }
        .joined()
}

// RFC 4180: quote a field that holds a comma, quote, or line break, and double its quotes.
private func csvField(_ field: String) -> String {
    guard field.contains(where: { ",\"\r\n".contains($0) }) else { return field }
    return "\"" + field.replacing("\"", with: "\"\"") + "\""
}

// ponytail: widths count Characters, so CJK text misaligns by its double width; fine for DNS data.
// Cells over 60 characters are cut so one long SPF record cannot widen the whole table; other formats stay whole.
private func table(_ header: [String], _ rows: [[String]]) -> String {
    let lines = [header] + rows.map { $0.map { $0.count > 60 ? $0.prefix(57) + "..." : $0 } }
    let widths = header.indices.map { column in lines.map { $0[column].count }.max() ?? 0 }
    return lines.map { fields in
        zip(fields, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
            .replacing(/\ +$/, with: "") + "\n"
    }.joined()
}

private struct JSONRow: Encodable {
    let index: Int
    let target, type, name, address, data, server: String
    let section: String?
    let ttl: UInt32?
    let error: String?
    let time: Int?
    let validated: Bool?
    let differs: Bool?
    let keys: Set<CodingKeys>

    // Keep nulls in the output so every object has the same keys.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put(_ value: some Encodable, _ key: CodingKeys) throws { if keys.contains(key) { try c.encode(value, forKey: key) } }
        try put(index, .index)
        try put(target, .target)
        try put(type, .type)
        try put(name, .name)
        try put(address, .address)
        try put(data, .data)
        try put(section, .section)
        try put(ttl, .ttl)
        try put(server, .server)
        try c.encode(error, forKey: .error)
        try put(time, .time)
        try put(validated, .validated)
        try put(differs, .differs)
    }

    enum CodingKeys: String, CodingKey { case index, target, type, name, address, data, section, ttl, server, error, time = "time_ms", validated, differs }

    static let columnKeys: [CodingKeys] = [.index, .target, .type, .name, .address, .data, .section, .ttl, .server, .time, .validated, .differs]
}

private func json(_ rows: [Row], columns: [Int]) -> String {
    let keys = Set(columns.map { JSONRow.columnKeys[$0] })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let objects = rows.map {
        JSONRow(index: $0.index, target: $0.target, type: $0.type.description, name: $0.name, address: $0.address,
                data: $0.data, server: $0.server, section: $0.section?.rawValue, ttl: $0.ttl, error: $0.error, time: $0.time, validated: $0.validated, differs: $0.differs, keys: keys)
    }
    // Encoding plain strings and integers cannot fail.
    return String(decoding: try! encoder.encode(objects), as: UTF8.self) + "\n"
}

private func html(_ header: [String], _ rows: [[String]], errors: [Bool]) -> String {
    func escape(_ s: String) -> String {
        s.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&quot;")
    }
    let head = header.map { "<th>\(escape($0))</th>" }.joined()
    let body = zip(rows, errors).map { fields, error in
        "<tr\(error ? " class=\"error\"" : "")>" + fields.map { "<td>\(escape($0))</td>" }.joined() + "</tr>\n"
    }.joined()
    return """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>MacDNSView results</title>
    <style>body{font:13px -apple-system,sans-serif}table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:3px 6px;text-align:left}tr.error{color:#b00}</style>
    </head><body>
    <table>
    <tr>\(head)</tr>
    \(body)</table>
    </body></html>

    """
}
