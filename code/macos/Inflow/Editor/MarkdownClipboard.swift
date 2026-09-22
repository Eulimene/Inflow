import AppKit
import Foundation

/// Clipboard HTML is parsed as inert data. No WebView, script, stylesheet or
/// external entity participates in converting a paste into Markdown.
enum MarkdownClipboardCodec {
    static func markdown(fromHTML html: String) -> String? {
        let inert = html.replacingOccurrences(of: #"(?is)<!DOCTYPE\s+html\s*>"#, with: "", options: .regularExpression)
        guard html.utf8.count <= 1_000_000,
              !inert.localizedCaseInsensitiveContains("<!ENTITY"),
              !inert.localizedCaseInsensitiveContains("<!DOCTYPE"),
              let document = try? XMLDocument(xmlString: inert, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement() else { return nil }
        return render(root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escaped(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_[]~".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func target(_ text: String?) -> String? {
        guard let text, !text.isEmpty, !text.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else { return nil }
        if let scheme = URL(string: text)?.scheme?.lowercased(), !["https", "http", "file", "mailto"].contains(scheme) { return nil }
        return "<" + text.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
    }

    private static func render(_ node: XMLNode, depth: Int = 0) -> String {
        guard depth < 64 else { return escaped(node.stringValue ?? "") }
        if node.kind == .text {
            return escaped((node.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
        }
        guard let element = node as? XMLElement else { return "" }
        let name = (element.name ?? "").lowercased()
        if ["head", "script", "style", "iframe", "object", "embed", "form", "input", "noscript"].contains(name) { return "" }
        let children = element.children ?? []
        let content = children.map { render($0, depth: depth + 1) }.joined()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "p", "div", "section", "article": return trimmed.isEmpty ? "" : trimmed + "\n\n"
        case "br": return "\n"
        case "strong", "b": return trimmed.isEmpty ? content : "**" + trimmed + "**"
        case "em", "i": return trimmed.isEmpty ? content : "*" + trimmed + "*"
        case "del", "s", "strike": return trimmed.isEmpty ? content : "~~" + trimmed + "~~"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return String(repeating: "#", count: Int(name.suffix(1)) ?? 1) + " " + trimmed + "\n\n"
        case "blockquote": return trimmed.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "ul", "ol":
            return children.compactMap { $0 as? XMLElement }.filter { $0.name?.lowercased() == "li" }.enumerated().map { index, item in
                let body = render(item, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                let marker = name == "ol" ? "\(index + 1). " : "- "
                return marker + body.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: marker.count))
            }.joined(separator: "\n") + "\n\n"
        case "pre":
            let code = (element.stringValue ?? "").trimmingCharacters(in: .newlines)
            let fence = String(repeating: "`", count: max(3, code.split(whereSeparator: { $0 != "`" }).map(\.count).max().map { $0 + 1 } ?? 3))
            return fence + "\n" + code + "\n" + fence + "\n\n"
        case "code":
            let code = (element.stringValue ?? "").replacingOccurrences(of: "\n", with: " ")
            let fence = String(repeating: "`", count: max(1, code.split(whereSeparator: { $0 != "`" }).map(\.count).max().map { $0 + 1 } ?? 1))
            return fence + " " + code + " " + fence
        case "a":
            guard let url = target(element.attribute(forName: "href")?.stringValue) else { return content }
            return "[" + trimmed + "](" + url + ")"
        case "img":
            let alt = escaped(element.attribute(forName: "alt")?.stringValue ?? "图片")
            guard let url = target(element.attribute(forName: "src")?.stringValue) else { return alt }
            return "![" + alt + "](" + url + ")"
        case "table":
            let rows = ((try? element.nodes(forXPath: ".//tr")) ?? []).compactMap { $0 as? XMLElement }.map { row in
                (row.children ?? []).compactMap { $0 as? XMLElement }.filter { ["th", "td"].contains($0.name?.lowercased() ?? "") }.map {
                    render($0, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
                }
            }.filter { !$0.isEmpty }
            guard let first = rows.first else { return content }
            let count = rows.map(\.count).max() ?? first.count
            func row(_ cells: [String]) -> String { "| " + (cells + Array(repeating: "", count: count - cells.count)).joined(separator: " | ") + " |" }
            return ([row(first), row(Array(repeating: "---", count: count))] + rows.dropFirst().map(row)).joined(separator: "\n") + "\n\n"
        default: return content
        }
    }
}


/// Quoted TSV preserves tabs and line breaks inside cells when copying to spreadsheets.
enum TableClipboard {
    static func encode(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { value in
                value.contains(where: { "\t\n\r\"".contains($0) })
                    ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> [[String]] {
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], value = ""
        var quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"", quoted {
                if index + 1 < characters.count, characters[index + 1] == "\"" {
                    value.append("\""); index += 1
                } else { quoted = false }
            } else if character == "\"", value.isEmpty { quoted = true }
            else if character == "\t", !quoted { row.append(value); value = "" }
            else if character == "\n", !quoted { row.append(value); rows.append(row); row = []; value = "" }
            else { value.append(character) }
            index += 1
        }
        if !row.isEmpty || !value.isEmpty || rows.isEmpty { row.append(value); rows.append(row) }
        return rows
    }
}
