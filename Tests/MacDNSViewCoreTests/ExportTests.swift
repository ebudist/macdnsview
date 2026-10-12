import Foundation
import Testing
@testable import MacDNSViewCore

private let rows = [
    Row(index: 1, target: "example.com", type: .mx, name: "mail.example.com", address: "", data: "preference 10",
        section: .answer, ttl: 300, server: "1.1.1.1", error: nil, order: []),
    Row(index: 2, target: "example.com", type: .txt, name: "example.com", address: "", data: "say \"hi\", then\tgo",
        section: .answer, ttl: 60, server: "1.1.1.1", error: nil, order: []),
    Row(index: 3, target: "nope.invalid", type: .a, name: "nope.invalid", address: "", data: "NXDOMAIN",
        section: nil, ttl: nil, server: "1.1.1.1", error: "NXDOMAIN", order: []),
]

@Test func csvQuotesOnlyWhatNeedsIt() {
    #expect(export(rows, as: .csv) == """
    Index,Target,Type,Name,Address,Data,Section,TTL,Server
    1,example.com,MX,mail.example.com,,preference 10,Answer,300,1.1.1.1
    2,example.com,TXT,example.com,,"say ""hi"", then\tgo",Answer,60,1.1.1.1
    3,nope.invalid,A,nope.invalid,,NXDOMAIN,,,1.1.1.1

    """)
}

@Test func tsvFlattensTabs() {
    let lines = export(rows, as: .tsv).split(separator: "\n")
    #expect(lines[0] == "Index\tTarget\tType\tName\tAddress\tData\tSection\tTTL\tServer")
    #expect(lines[2] == "2\texample.com\tTXT\texample.com\t\tsay \"hi\", then go\tAnswer\t60\t1.1.1.1")
}

@Test func tableAlignsColumns() {
    let lines = export(Array(rows.prefix(1)), as: .table).split(separator: "\n")
    #expect(lines == [
        "Index  Target       Type  Name              Address  Data           Section  TTL  Server",
        "1      example.com  MX    mail.example.com           preference 10  Answer   300  1.1.1.1",
    ])
}

@Test func jsonKeepsEveryKeyOnEveryObject() throws {
    let parsed = try JSONSerialization.jsonObject(with: Data(export(rows, as: .json).utf8)) as! [[String: Any]]
    #expect(parsed.count == 3)
    #expect(Set(parsed[2].keys) == ["index", "target", "type", "name", "address", "data", "section", "ttl", "server", "error"])
    #expect(parsed[2]["error"] as? String == "NXDOMAIN")
    #expect(parsed[2]["ttl"] is NSNull)
    #expect(parsed[0]["ttl"] as? Int == 300)
    #expect(parsed[1]["data"] as? String == "say \"hi\", then\tgo")
}

@Test func htmlEscapesAndMarksErrors() {
    let html = export(rows, as: .html)
    #expect(html.contains("<meta charset=\"utf-8\">"))
    #expect(html.contains("<td>say &quot;hi&quot;, then\tgo</td>"))
    #expect(html.contains("<tr class=\"error\"><td>3</td>"))
    #expect(!html.contains("\"hi\""))
}
