import Foundation

/// An RFC 4180 reader, as banks actually write the format: quoted fields may hold commas,
/// doubled quotes and newlines; rows end in LF, CRLF or a lone CR; a UTF-8 byte-order
/// mark is dropped. A blank line comes back as `[""]` so row positions stay true to the
/// file — a recipe skips it, the mapping sheet shows it.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false        // inside a quoted field
        var rowOpen = false       // anything read since the last row break

        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = []; rowOpen = false }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 }
                    else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true; rowOpen = true
                case ",": endField(); rowOpen = true
                case "\r":
                    endRow()
                    if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                case "\n": endRow()
                default: field.unicodeScalars.append(c); rowOpen = true
                }
            }
            i += 1
        }
        if rowOpen || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
