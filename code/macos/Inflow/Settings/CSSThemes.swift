import AppKit
import Foundation

/// Immutable CSS snapshot: changing a file never changes an export already in flight.
struct PreviewTheme: RawRepresentable, Hashable, Identifiable, Sendable, CaseIterable {
    let rawValue: String
    let label: String
    let css: String
    let styles: NativeCSSStyles
    var id: String { rawValue }
    // RawRepresentable's default equality compares only the identifier. CSS
    // content must participate so edits invalidate the native render snapshot.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue && lhs.label == rhs.label && lhs.css == rhs.css
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue); hasher.combine(label); hasher.combine(css)
    }

    init(id: String, label: String, css: String) {
        rawValue = id
        self.label = label
        self.css = css
        styles = NativeCSSStyles(css: css)
    }

    init?(rawValue: String) {
        let aliases = ["standard": "github", "longform": "newsprint"]
        let id = aliases[rawValue] ?? rawValue
        guard !id.isEmpty, id.count <= 100, !id.contains("/"), !id.contains("\\") else { return nil }
        if let builtin = Self.allCases.first(where: { $0.rawValue == id }) { self = builtin }
        else if id == "code" { self = .code }
        else if id == "highContrast" { self = .highContrast }
        else { self.init(id: id, label: Self.displayName(id), css: "") }
    }

    static let allCases: [Self] = ["github", "whitey", "night", "newsprint", "pixyll", "gothic"].map { id in
        let css = (try? String(contentsOf: ThemeCatalog.bundledDirectory.appendingPathComponent(id + ".css"), encoding: .utf8)) ?? ""
        return Self(id: id, label: id == "github" ? "GitHub" : id.capitalized, css: css)
    }
    static var standard: Self { allCases[0] }
    static var longform: Self { allCases[3] }
    // Retain old saved selections without adding legacy choices to the new menu.
    static let code = Self(id: "code", label: "代码优先（旧版）", css: "body { font-family: ui-monospace, Menlo, monospace; line-height: 1.58; }")
    static let highContrast = Self(id: "highContrast", label: "高对比度（旧版）", css: "")
    static func displayName(_ id: String) -> String { id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized }
    var safeStyleContent: String { css.replacingOccurrences(of: "<", with: "\\3C ") }
}

private final class ThemeBundleMarker: NSObject {}

struct ThemeCatalog {
    static var defaultDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("Inflow/Themes", isDirectory: true)
    }
    static let bundledDirectory: URL = {
        var bundle = Bundle(for: ThemeBundleMarker.self)
        var parent = bundle.bundleURL
        while bundle.url(forResource: "Themes", withExtension: nil) == nil && parent.path != "/" {
            parent.deleteLastPathComponent()
            if parent.pathExtension == "app", let host = Bundle(url: parent) { bundle = host; break }
        }
        return bundle.url(forResource: "Themes", withExtension: nil) ?? bundle.bundleURL.appendingPathComponent("Themes")
    }()

    let directory: URL
    func load() throws -> (themes: [PreviewTheme], issues: [String]) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in PreviewTheme.allCases {
            let file = directory.appendingPathComponent(theme.rawValue + ".css")
            if !fm.fileExists(atPath: file.path) {
                try fm.copyItem(at: Self.bundledDirectory.appendingPathComponent(theme.rawValue + ".css"), to: file)
            }
        }
        let guide = directory.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: guide.path) {
            try fm.copyItem(at: Self.bundledDirectory.appendingPathComponent("README.md"), to: guide)
        }
        var themes: [PreviewTheme] = []
        var issues: [String] = []
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension.lowercased() == "css" {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 262_144 else { throw ThemeError.invalidFile }
                let css = try String(contentsOf: file, encoding: .utf8)
                let styles = NativeCSSStyles(css: css)
                guard styles.isValid else { throw ThemeError.invalidFile }
                let id = file.deletingPathExtension().lastPathComponent
                guard PreviewTheme(rawValue: id) != nil else { throw ThemeError.invalidFile }
                let label = PreviewTheme.allCases.first(where: { $0.rawValue == id })?.label ?? PreviewTheme.displayName(id)
                themes.append(PreviewTheme(id: id, label: label, css: css))
                if styles.hasUnsupportedRules { issues.append("\(file.lastPathComponent)：部分 CSS 规则仅适用于 HTML 导出") }
            } catch {
                issues.append("\(file.lastPathComponent)：无法读取有效 CSS，暂时跳过")
                if let fallback = PreviewTheme.allCases.first(where: { $0.rawValue + ".css" == file.lastPathComponent }) { themes.append(fallback) }
            }
        }
        let order = PreviewTheme.allCases.map(\.rawValue)
        themes.sort {
            let left = order.firstIndex(of: $0.rawValue) ?? 100
            let right = order.firstIndex(of: $1.rawValue) ?? 100
            return left == right ? $0.label.localizedStandardCompare($1.label) == .orderedAscending : left < right
        }
        return (themes, issues)
    }
    enum ThemeError: Error { case invalidFile }
}

/// Deliberately bounded native bridge, not a browser CSS implementation.
/// Supports common element / #write selectors, variables and declaration cascade.
struct NativeCSSStyles: Hashable, Sendable {
    struct Rule: Hashable, Sendable {
        let selector: String
        let property: String
        let value: String
        let priority: Int
    }
    let rules: [Rule]
    let isValid: Bool
    let hasUnsupportedRules: Bool

    init(css: String) {
        let clean = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var result: [Rule] = []
        var header = "", body = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        var valid = true
        var unsupported = false
        let supported = Set([":root", "html", "body", "#write", "p", "h1", "h2", "h3", "h4", "h5", "h6", "a", "blockquote", "pre", "code", "table", "th", "td", "tr:nth-child(even)", "tr:nth-child(2n)", "strong", "em", "li", "ul", "ol", "hr"])
        for c in clean {
            if escaped { if depth > 0 { body.append(c) } else { header.append(c) }; escaped = false; continue }
            if c == "\\" { if depth > 0 { body.append(c) } else { header.append(c) }; escaped = true; continue }
            if let current = quote {
                if c == current { quote = nil }
                if depth > 0 { body.append(c) } else { header.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; if depth > 0 { body.append(c) } else { header.append(c) }; continue }
            if c == "{" { depth += 1; if depth > 1 { unsupported = true }; continue }
            if c == "}" {
                depth -= 1
                if depth < 0 { valid = false; break }
                if depth == 0 {
                    let selectors = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s*>?\s+"#, with: " ", options: .regularExpression) }
                    if !header.contains("@"), !body.contains("{") {
                        for selector in selectors {
                            let element = selector.hasPrefix("#write ") ? String(selector.dropFirst(7)) : selector
                            guard supported.contains(element) else { unsupported = true; continue }
                            for declaration in body.split(separator: ";") {
                                guard let colon = declaration.firstIndex(of: ":") else { continue }
                                let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                                let important = value.range(of: #"\s*!important\s*$"#, options: [.regularExpression, .caseInsensitive])
                                let stripped = important.map { String(value[..<$0.lowerBound]) } ?? value
                                let priority = (important == nil ? 0 : 1000) + (selector.contains("#write") ? 100 : selector == ":root" ? 10 : 1)
                                result.append(Rule(selector: selector, property: property, value: stripped, priority: priority))
                                if property == "margin" || property == "padding" {
                                    let parts = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                                    if (1...4).contains(parts.count) {
                                        let sides = [parts[0], parts.count > 1 ? parts[1] : parts[0], parts.count > 2 ? parts[2] : parts[0], parts.count > 3 ? parts[3] : parts.count > 1 ? parts[1] : parts[0]]
                                        for (side, value) in zip(["top", "right", "bottom", "left"], sides) {
                                            result.append(Rule(selector: selector, property: property + "-" + side, value: value, priority: priority))
                                        }
                                    }
                                }
                                if ["border", "border-left"].contains(property), let color = stripped.split(separator: " ").last {
                                    result.append(Rule(selector: selector, property: property + "-color", value: String(color), priority: priority))
                                }
                            }
                        }
                    } else { unsupported = true }
                    header = ""; body = ""
                } else { body.append("}") }
                continue
            }
            if depth > 0 { body.append(c) } else if c == ";" && header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") { unsupported = true; header = "" } else { header.append(c) }
        }
        rules = result
        isValid = valid && depth == 0 && quote == nil && !result.isEmpty
        hasUnsupportedRules = unsupported
    }

    func value(_ property: String, on element: String = "body") -> String? {
        let selectors: Set<String> = element == "body" ? [":root", "html", "body", "#write"] : [element, "#write " + element]
        guard let rule = rules.enumerated().filter({ selectors.contains($0.element.selector) && $0.element.property == property }).max(by: {
            let leftScope = ["body", "#write"].contains($0.element.selector) ? 1 : 0
            let rightScope = ["body", "#write"].contains($1.element.selector) ? 1 : 0
            if element == "body", leftScope != rightScope { return leftScope < rightScope }
            return $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority
        })?.element else { return nil }
        return resolve(rule.value)
    }

    private static let variableExpression = try? NSRegularExpression(pattern: #"var\(\s*(--[\w-]+)\s*(?:,\s*([^()]*))?\)"#)

    private func resolve(_ input: String, depth: Int = 0) -> String? {
        guard depth < 12 else { return nil }
        guard let expression = Self.variableExpression,
              let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let nameRange = Range(match.range(at: 1), in: input), let fullRange = Range(match.range, in: input) else { return input.contains("var(") ? nil : input }
        let name = String(input[nameRange])
        let variable = rules.enumerated().filter { [":root", "html", "body", "#write"].contains($0.element.selector) && $0.element.property == name }.max {
            $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority
        }?.element.value
        let fallback = Range(match.range(at: 2), in: input).map { String(input[$0]) }
        guard let replacement = variable ?? fallback else { return nil }
        return resolve(input.replacingCharacters(in: fullRange, with: replacement), depth: depth + 1)
    }

    func length(_ property: String, on element: String = "body", relativeTo size: CGFloat = 16) -> CGFloat? {
        guard let raw = value(property, on: element)?.lowercased() else { return nil }
        let units: [(String, CGFloat)] = [("rem", size), ("em", size), ("px", 1), ("pt", 1), ("%", size / 100)]
        for (unit, scale) in units where raw.hasSuffix(unit) {
            guard let number = Double(raw.dropLast(unit.count)), number.isFinite else { return nil }
            return CGFloat(number) * scale
        }
        return Double(raw).flatMap { $0.isFinite ? CGFloat($0) : nil }
    }

    @MainActor
    func font(on element: String = "body", size: CGFloat, fallback: NSFont) -> NSFont {
        guard let family = value("font-family", on: element) else { return fallback }
        for entry in family.split(separator: ",") {
            let name = entry.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            if ["monospace", "ui-monospace"].contains(name) { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
            if ["serif", "ui-serif"].contains(name), let descriptor = fallback.fontDescriptor.withDesign(.serif) { return NSFont(descriptor: descriptor, size: size) ?? fallback }
            if ["sans-serif", "system-ui", "-apple-system"].contains(name) { return NSFont.systemFont(ofSize: size) }
            if let font = NSFont(name: name, size: size) { return font }
        }
        return fallback
    }

    static func colorHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = ["white": "#ffffff", "black": "#000000", "red": "#ff0000", "blue": "#0000ff", "gray": "#808080", "grey": "#808080", "transparent": "#00000000"]
        if let named = names[text] { return named }
        if text.hasPrefix("#") {
            let hex = String(text.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), UInt32(hex, radix: 16) != nil else { return nil }
            return "#" + (hex.count <= 4 ? hex.map { "\($0)\($0)" }.joined() : hex)
        }
        if text.hasPrefix("rgb"), let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")") {
            let parts = text[text.index(after: start)..<end].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            var numbers: [Int] = []
            for (i, part) in parts.enumerated() {
                guard let number = Double(part.replacingOccurrences(of: "%", with: "")), number.isFinite else { return nil }
                let scale = part.hasSuffix("%") ? 2.55 : i == 3 ? 255.0 : 1.0
                numbers.append(Int(min(255, max(0, number * scale)).rounded()))
            }
            return "#" + numbers.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }
}

extension NativeCSSStyles {
    func applying(to base: MarkdownRenderPalette) -> MarkdownRenderPalette {
        var palette = base
        let tokens: [(String, WritableKeyPath<MarkdownRenderPalette, String>)] = [
            ("--md-canvas", \.canvas), ("--md-text", \.text), ("--md-heading", \.heading),
            ("--md-secondary", \.secondaryText), ("--md-accent", \.accent), ("--md-border", \.border),
            ("--md-quote-bar", \.quoteBar), ("--md-surface", \.subtleSurface), ("--md-surface-strong", \.mutedSurface),
            ("--md-table-stripe", \.tableStripe), ("--md-inline-code", \.inlineCode), ("--md-keyword", \.keyword),
            ("--md-type", \.type), ("--md-string", \.string), ("--md-number", \.number),
            ("--md-comment", \.comment), ("--md-tag", \.tag), ("--md-warning", \.warning)
        ]
        for (token, key) in tokens { if let color = Self.colorHex(value(token)) { palette[keyPath: key] = color } }
        let properties: [(String, String, String?, WritableKeyPath<MarkdownRenderPalette, String>)] = [
            ("body", "background-color", "--bg-color", \.canvas), ("body", "color", "--text-color", \.text),
            ("h1", "color", nil, \.heading), ("a", "color", "--primary-color", \.accent),
            ("blockquote", "color", nil, \.secondaryText), ("blockquote", "border-left-color", nil, \.quoteBar),
            ("pre", "background-color", nil, \.subtleSurface), ("code", "background-color", nil, \.inlineCode),
            ("th", "background-color", nil, \.mutedSurface),
            ("td", "border-color", nil, \.border), ("tr:nth-child(even)", "background-color", nil, \.tableStripe),
            ("tr:nth-child(2n)", "background-color", nil, \.tableStripe)
        ]
        for (element, property, fallback, key) in properties {
            let declaration = value(property, on: element)
                ?? (property == "background-color" ? value("background", on: element) : nil)
                ?? fallback.flatMap { value($0) }
            if let color = Self.colorHex(declaration) { palette[keyPath: key] = color }
        }
        return palette
    }

    static func color(_ css: String) -> NSColor? {
        guard let hex = colorHex(css)?.dropFirst(), let number = UInt32(hex, radix: 16) else { return nil }
        let alpha = hex.count == 8 ? CGFloat(number & 255) / 255 : 1
        let rgb = hex.count == 8 ? number >> 8 : number
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
}
