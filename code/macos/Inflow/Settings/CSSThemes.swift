import AppKit
import Foundation
import CryptoKit

/// All authored style values live beside the theme CSS resources. Swift only adapts them.
enum ThemeStyleResources {
    static func css(_ name: String) -> String {
        (try? String(contentsOf: ThemeCatalog.bundledDirectory.appendingPathComponent("Base/" + name + ".css"), encoding: .utf8)) ?? ""
    }
    static func styles(_ name: String) -> NativeCSSStyles { NativeCSSStyles(css: css(name)) }
    static let defaults = styles("default")
    static let defaultCSS = css("default")
}

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
        styles = NativeCSSStyles(css: ThemeStyleResources.defaultCSS + "\n" + css)
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
    static let code = Self(id: "code", label: "代码优先（旧版）", css: ThemeStyleResources.css("legacy-code"))
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

    // Fingerprints of the first shipped CSS files, before install manifests existed.
    private static let legacyBuiltinHashes: [String: String] = [
        "github": "47140fe0d826b6b2345c5356abb68296494c473be98ed1d21f33a1190809e123",
        "gothic": "6907fc471c3f8e650432c62b665a32aea5075929a2ae0f7e286548304c19d9b3",
        "newsprint": "72433f8d1860486685f4d6a2e39901775d7d2c9e43e39bbffc34b8330f2cd584",
        "night": "cccd00ee1e34332050b8d5f0c7200538bb86322c3f4fc9746b29f8e6200838c1",
        "pixyll": "d7307318c0842e29239fd1f047179b064034e70b4d7213b5e71b0b8155ce0eef",
        "whitey": "c8408c39172635cfc7a9395a79e9b771852af8b83f4825ab1adb42db510d7350",
    ]
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    let directory: URL
    func load(previousThemes: [PreviewTheme] = []) throws -> (themes: [PreviewTheme], issues: [String]) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent(".builtin-versions.json")
        let installed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))) ?? [:]
        var versions = installed
        for theme in PreviewTheme.allCases {
            let file = directory.appendingPathComponent(theme.rawValue + ".css")
            let bundled = Data(theme.css.utf8)
            let current = try? Data(contentsOf: file)
            let hash = current.map(Self.fingerprint)
            let isUnmodified = hash != nil && (hash == installed[theme.id] || hash == Self.legacyBuiltinHashes[theme.id])
            if !fm.fileExists(atPath: file.path) || isUnmodified {
                if current != bundled { try bundled.write(to: file, options: .atomic) }
                versions[theme.id] = Self.fingerprint(bundled)
            } else if current == bundled {
                versions[theme.id] = Self.fingerprint(bundled)
            }
        }
        if versions != installed {
            try JSONEncoder().encode(versions).write(to: manifestURL, options: .atomic)
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
                let theme = PreviewTheme(id: id, label: label, css: css)
                guard theme.styles.isValid else { throw ThemeError.invalidFile }
                themes.append(theme)
                if styles.hasUnsupportedRules { issues.append("\(file.lastPathComponent)：包含当前主题规范未支持的 CSS 规则") }
            } catch {
                issues.append("\(file.lastPathComponent)：无法读取有效 CSS，暂时跳过")
                if let fallback = (previousThemes + PreviewTheme.allCases).first(where: { $0.rawValue + ".css" == file.lastPathComponent }) { themes.append(fallback) }
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

/// Platform projection of a Rust-compiled immutable theme. No CSS parsing here.
struct NativeCSSStyles: Hashable, Sendable {
    typealias Rule = CoreThemeSnapshot.Rule
    let snapshot: CoreThemeSnapshot
    var rules: [Rule] { snapshot.rules }
    var isValid: Bool { snapshot.isValid }
    var hasUnsupportedRules: Bool { snapshot.hasUnsupportedRules }
    var diagnostics: [CoreThemeSnapshot.Diagnostic] { snapshot.diagnostics }

    init(css: String) {
        snapshot = (try? EditorEnginePresentation.compileTheme(css)) ?? .unavailable
        NativeThemeColorCache.shared.include(snapshot.colors)
    }

    func hasDeclarations(on element: String) -> Bool { !(snapshot.values[element]?.isEmpty ?? true) }

    func value(_ property: String, on element: String = "body") -> String? {
        snapshot.values[element]?[property]
    }

    func length(_ property: String, on element: String = "body", relativeTo size: CGFloat = 16, rootSize: CGFloat? = nil) -> CGFloat? {
        snapshot.lengths[element]?[property]?.used(font: Double(size), root: Double(rootSize ?? size), percentageBasis: Double(size)).map { CGFloat($0) }
    }

    @MainActor
    func font(on element: String = "body", size: CGFloat, fallback: NSFont) -> NSFont {
        guard let families = snapshot.fonts[element] else { return fallback }
        let fonts: [NSFont] = families.compactMap { name in
            if ["monospace", "ui-monospace"].contains(name) { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
            if ["serif", "ui-serif"].contains(name), let descriptor = fallback.fontDescriptor.withDesign(.serif) { return NSFont(descriptor: descriptor, size: size) }
            if ["sans-serif", "system-ui", "-apple-system"].contains(name) { return NSFont.systemFont(ofSize: size) }
            return NSFont(name: name, size: size)
        }
        guard let first = fonts.first else { return fallback }
        // Preserve the CSS fallback chain for Chinese glyphs as well as Latin text.
        let descriptor = first.fontDescriptor.addingAttributes([.cascadeList: fonts.dropFirst().map(\.fontDescriptor)])
        return NSFont(descriptor: descriptor, size: size) ?? first
    }

    @MainActor
    static func font(_ font: NSFont, bold: Bool) -> NSFont {
        Self.font(font, trait: .boldFontMask, enabled: bold)
    }

    @MainActor
    static func font(_ font: NSFont, trait: NSFontTraitMask, enabled: Bool = true) -> NSFont {
        let manager = NSFontManager.shared
        let converted = enabled ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
        guard let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] else { return converted }
        let fallback = cascade.compactMap { descriptor -> NSFontDescriptor? in
            guard let member = NSFont(descriptor: descriptor, size: font.pointSize) else { return nil }
            return (enabled ? manager.convert(member, toHaveTrait: trait) : manager.convert(member, toNotHaveTrait: trait)).fontDescriptor
        }
        return NSFont(descriptor: converted.fontDescriptor.addingAttributes([.cascadeList: fallback]), size: font.pointSize) ?? converted
    }

    func metric(_ name: String) -> CGFloat { length("--inflow-" + name) ?? 0 }
    func token(_ name: String) -> CGFloat { length("--md-" + name) ?? 0 }

    func headingDividerWidth(level: Int) -> CGFloat {
        max(0, min(8, length("--md-divider-height", on: "h\(level)") ?? length("border-bottom-width", on: "h\(level)") ?? 0))
    }

    static func colorHex(_ value: String?) -> String? {
        guard let value else { return nil }
        return NativeThemeColorCache.shared.color(value)
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
            ("--md-comment", \.comment), ("--md-tag", \.tag), ("--md-warning", \.warning),
            ("--md-selection-background", \.selectionBackground), ("--md-selection-text", \.selectionText),
            ("--md-selection-overlay", \.selectionOverlay)
        ]
        for (token, key) in tokens { if let color = Self.colorHex(value(token)) { palette[keyPath: key] = color } }
        let properties: [(String, String, String?, WritableKeyPath<MarkdownRenderPalette, String>)] = [
            ("body", "background-color", "--bg-color", \.canvas), ("body", "color", "--text-color", \.text),
            ("h1", "color", nil, \.heading), ("a", "color", "--primary-color", \.accent),
            ("blockquote", "color", nil, \.secondaryText), ("blockquote", "border-left-color", nil, \.quoteBar),
            ("pre", "background-color", nil, \.subtleSurface), ("code", "background-color", nil, \.inlineCode),
            ("th", "background-color", nil, \.mutedSurface),
            ("td", "border-color", nil, \.border), ("tr:nth-child(even)", "background-color", nil, \.tableStripe),
            ("tr:nth-child(2n)", "background-color", nil, \.tableStripe),
            ("::selection", "background-color", "--select-text-bg-color", \.selectionBackground),
            ("::selection", "color", nil, \.selectionText)
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

/// Small host-object cache; CSS color interpretation belongs exclusively to Rust.
private final class NativeThemeColorCache: @unchecked Sendable {
    static let shared = NativeThemeColorCache()
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func include(_ colors: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        for (source, color) in colors where source.utf8.count <= 256 {
            if values.count >= 256 { values.removeAll(keepingCapacity: true) }
            values[source] = color
        }
    }
    func color(_ value: String) -> String? {
        guard value.utf8.count <= 256 else { return nil }
        lock.lock()
        let cached = values[value]
        lock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }
        let result = EditorEnginePresentation.color(value)
        lock.lock()
        if values.count >= 256 { values.removeAll(keepingCapacity: true) }
        values[value] = result ?? ""
        lock.unlock()
        return result
    }
}
