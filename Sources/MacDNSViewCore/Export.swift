import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case table, csv, tsv, json, html
}

extension Row {
    public static let columns = ["Index", "Target", "Type", "Name", "Address", "Data", "Section", "TTL", "Server"]

    public var fields: [String] {
        [String(index), target, type.description, name, address, data, section?.rawValue ?? "", ttl.map(String.init) ?? "", server]
    }
}

public func export(_ rows: [Row], as format: ExportFormat) -> String {
    switch format {
    case .table: table(rows)
    case .csv: delimited(rows, separator: ",", escape: csvField)
    case .tsv: delimited(rows, separator: "\t") { $0.replacing(/[\t\r\n]/, with: " ") }
    case .json: json(rows)
    case .html: html(rows)
    }
}

private func delimited(_ rows: [Row], separator: String, escape: (String) -> String) -> String {
    ([Row.columns] + rows.map(\.fields))
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
private func table(_ rows: [Row]) -> String {
    let lines = [Row.columns] + rows.map { $0.fields.map { $0.count > 60 ? $0.prefix(57) + "..." : $0 } }
    let widths = Row.columns.indices.map { column in lines.map { $0[column].count }.max() ?? 0 }
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

    // Keep nulls in the output so every object has the same keys.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(target, forKey: .target)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(address, forKey: .address)
        try c.encode(data, forKey: .data)
        try c.encode(section, forKey: .section)
        try c.encode(ttl, forKey: .ttl)
        try c.encode(server, forKey: .server)
        try c.encode(error, forKey: .error)
    }

    enum CodingKeys: String, CodingKey { case index, target, type, name, address, data, section, ttl, server, error }
}

private func json(_ rows: [Row]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let objects = rows.map {
        JSONRow(index: $0.index, target: $0.target, type: $0.type.description, name: $0.name, address: $0.address,
                data: $0.data, server: $0.server, section: $0.section?.rawValue, ttl: $0.ttl, error: $0.error)
    }
    // Encoding plain strings and integers cannot fail.
    return String(decoding: try! encoder.encode(objects), as: UTF8.self) + "\n"
}

private func html(_ rows: [Row]) -> String {
    func escape(_ s: String) -> String {
        s.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&quot;")
    }
    let header = Row.columns.map { "<th>\($0)</th>" }.joined()
    let body = rows.map { row in
        "<tr\(row.error != nil ? " class=\"error\"" : "")>" + row.fields.map { "<td>\(escape($0))</td>" }.joined() + "</tr>\n"
    }.joined()
    return """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>MacDNSView results</title>
    <style>body{font:13px -apple-system,sans-serif}table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:3px 6px;text-align:left}tr.error{color:#b00}</style>
    </head><body>
    <table>
    <tr>\(header)</tr>
    \(body)</table>
    </body></html>

    """
}
