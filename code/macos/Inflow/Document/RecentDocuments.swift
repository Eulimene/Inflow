import AppKit
import Combine
import Foundation

enum MarkdownOpenBehavior: String, CaseIterable, Identifiable, Sendable {
    case newWindow
    case reuseBlankWindow

    var id: Self { self }

    var label: String {
        switch self {
        case .newWindow: "始终在新窗口打开"
        case .reuseBlankWindow: "复用当前空白窗口"
        }
    }
}

enum RecentDocumentPolicy {
    static let capacityKey = "preferences.documents.recentCapacity"
    static let openBehaviorKey = "preferences.documents.openBehavior"
    static let recordsKey = "documents.recent.records.v1"
    static let capacityRange = 5 ... 50
    static let defaultCapacity = 20

    static func capacity(in defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: capacityKey) as? NSNumber else {
            return defaultCapacity
        }
        return clampCapacity(stored.intValue)
    }

    static func openBehavior(in defaults: UserDefaults = .standard) -> MarkdownOpenBehavior {
        guard let rawValue = defaults.string(forKey: openBehaviorKey),
              let behavior = MarkdownOpenBehavior(rawValue: rawValue)
        else {
            return .newWindow
        }
        return behavior
    }

    static func clampCapacity(_ value: Int) -> Int {
        min(max(value, capacityRange.lowerBound), capacityRange.upperBound)
    }
}

struct RecentDocumentRecord: Codable, Equatable, Sendable {
    let exactPath: String
    let bookmark: Data?
}

@MainActor
protocol RecentDocumentPersistence: AnyObject {
    func load() -> [RecentDocumentRecord]
    func save(_ records: [RecentDocumentRecord])
}

@MainActor
final class UserDefaultsRecentDocumentPersistence: RecentDocumentPersistence {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = RecentDocumentPolicy.recordsKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [RecentDocumentRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentDocumentRecord].self, from: data)) ?? []
    }

    func save(_ records: [RecentDocumentRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

struct RecentDocumentEntry: Identifiable, Equatable, Sendable {
    let record: RecentDocumentRecord

    var id: String { record.exactPath }
    var url: URL { URL(fileURLWithPath: record.exactPath).standardizedFileURL }
    var displayName: String { url.lastPathComponent }
    var directoryPath: String { url.deletingLastPathComponent().path }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: record.exactPath) }

    static func identity(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

@MainActor
enum DocumentWindowReusePolicy {
    static func reusableBlankDocument(
        from candidates: [NSDocument],
        behavior: MarkdownOpenBehavior
    ) -> NSDocument? {
        guard behavior == .reuseBlankWindow else { return nil }
        return candidates.first { document in
            document.fileURL == nil && !document.isDocumentEdited
        }
    }

    static var orderedDocumentCandidates: [NSDocument] {
        var seen = Set<ObjectIdentifier>()
        let ordered = NSApp.orderedWindows.compactMap { window in
            window.windowController?.document as? NSDocument
        } + NSDocumentController.shared.documents
        return ordered.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

@MainActor
final class RecentDocumentsController: NSObject, ObservableObject {
    @Published private(set) var entries: [RecentDocumentEntry] = []

    private let persistence: RecentDocumentPersistence
    private let capacity: () -> Int
    private let openBehavior: () -> MarkdownOpenBehavior
    private let bookmarkData: (URL) -> Data?
    private let systemSynchronizer: ([RecentDocumentEntry]) -> Void
    private var applicationObservers: [AnyCancellable] = []
    private var isMenuIntegrationInstalled = false

    init(
        persistence: RecentDocumentPersistence = UserDefaultsRecentDocumentPersistence(),
        capacity: @escaping () -> Int = { RecentDocumentPolicy.capacity() },
        openBehavior: @escaping () -> MarkdownOpenBehavior = {
            RecentDocumentPolicy.openBehavior()
        },
        bookmarkData: @escaping (URL) -> Data? = { url in
            try? url.bookmarkData(options: .withSecurityScope)
        },
        systemSynchronizer: @escaping ([RecentDocumentEntry]) -> Void = { entries in
            NSDocumentController.shared.clearRecentDocuments(nil)
            for entry in entries.reversed() where entry.isAvailable {
                NSDocumentController.shared.noteNewRecentDocumentURL(entry.url)
            }
        }
    ) {
        self.persistence = persistence
        self.capacity = capacity
        self.openBehavior = openBehavior
        self.bookmarkData = bookmarkData
        self.systemSynchronizer = systemSynchronizer
        super.init()
        replace(with: normalized(persistence.load()), synchronizeSystem: false)
    }

    func installMenuIntegration() {
        isMenuIntegrationInstalled = true
        applicationObservers = [
            NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.configureFileMenu() }
                },
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.configureFileMenu() }
                },
        ]
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.configureFileMenu()
        }
    }

    func note(_ url: URL) {
        guard url.isFileURL else { return }
        let exactURL = url.standardizedFileURL
        let identity = RecentDocumentEntry.identity(for: exactURL)
        var records = entries.map(\.record)
        records.removeAll { $0.exactPath == identity }
        records.insert(
            RecentDocumentRecord(exactPath: identity, bookmark: bookmarkData(exactURL)),
            at: 0
        )
        replace(with: records, synchronizeSystem: true)
    }

    func refresh() {
        replace(with: normalized(persistence.load()), synchronizeSystem: false)
    }

    func applyCapacity() {
        replace(with: entries.map(\.record), synchronizeSystem: true)
    }

    func remove(_ entry: RecentDocumentEntry) {
        replace(
            with: entries.map(\.record).filter { $0.exactPath != entry.id },
            synchronizeSystem: true
        )
    }

    func clear() {
        replace(with: [], synchronizeSystem: true)
    }

    @objc private func openRecentMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = entries.first(where: { $0.id == id }),
              let url = exactAuthorizedURL(for: entry.record)
        else {
            configureFileMenu()
            return
        }
        open(url, reusableDocument: reusableBlankDocument())
    }

    @objc private func openDocumentMenuItem(_: Any?) {
        chooseDocumentToOpen()
    }

    func chooseDocumentToOpen() {
        let reusableDocument = reusableBlankDocument()
        NSDocumentController.shared.beginOpenPanel { [weak self] urls in
            guard let self, let urls else { return }
            for (index, url) in urls.enumerated() {
                self.open(url, reusableDocument: index == 0 ? reusableDocument : nil)
            }
        }
    }

    @objc private func clearRecentMenuItem(_: Any?) {
        clear()
    }

    func configureFileMenu() {
        guard let fileMenu = locateFileMenu() else { return }
        if let openItem = fileMenu.items.first(where: {
            $0.action == #selector(NSDocumentController.openDocument(_:))
        }) {
            openItem.target = self
            openItem.action = #selector(openDocumentMenuItem(_:))
        }

        let recentItem = locateRecentItem(in: fileMenu) ?? insertRecentItem(in: fileMenu)
        recentItem.title = "打开最近"
        recentItem.isEnabled = !entries.isEmpty
        let submenu = recentItem.submenu ?? NSMenu(title: "打开最近")
        submenu.removeAllItems()

        let duplicateNames = Dictionary(grouping: entries, by: \.displayName)
        for entry in entries {
            let title: String
            if !entry.isAvailable {
                title = "\(entry.displayName)（原位置不可用）"
            } else if duplicateNames[entry.displayName, default: []].count > 1 {
                title = "\(entry.displayName) — \(entry.url.deletingLastPathComponent().lastPathComponent)"
            } else {
                title = entry.displayName
            }
            let item = NSMenuItem(
                title: title,
                action: entry.isAvailable ? #selector(openRecentMenuItem(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            item.toolTip = entry.record.exactPath
            item.isEnabled = entry.isAvailable
            submenu.addItem(item)
        }

        if !entries.isEmpty {
            submenu.addItem(.separator())
        }
        let clearItem = NSMenuItem(
            title: "清除最近记录",
            action: #selector(clearRecentMenuItem(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = !entries.isEmpty
        submenu.addItem(clearItem)
        recentItem.submenu = submenu
    }

    static func exactResolvedURL(
        for record: RecentDocumentRecord,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        resolveBookmark: (Data) -> URL? = { data in
            var stale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
    ) -> URL? {
        guard fileExists(record.exactPath) else { return nil }
        let exactURL = URL(fileURLWithPath: record.exactPath).standardizedFileURL
        guard let bookmark = record.bookmark else { return exactURL }
        guard let resolved = resolveBookmark(bookmark)?.standardizedFileURL,
              RecentDocumentEntry.identity(for: resolved) == record.exactPath
        else {
            return nil
        }
        return resolved
    }

    private func exactAuthorizedURL(for record: RecentDocumentRecord) -> URL? {
        Self.exactResolvedURL(for: record)
    }

    private func open(_ url: URL, reusableDocument: NSDocument?) {
        let accessed = url.startAccessingSecurityScopedResource()
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { [weak self] document, wasAlreadyOpen, error in
            if accessed { url.stopAccessingSecurityScopedResource() }
            if let error {
                NSDocumentController.shared.presentError(error)
                return
            }
            guard let self, document != nil else { return }
            self.note(url)
            if !wasAlreadyOpen,
               let reusableDocument,
               reusableDocument !== document
            {
                reusableDocument.close()
            }
        }
    }

    private func reusableBlankDocument() -> NSDocument? {
        DocumentWindowReusePolicy.reusableBlankDocument(
            from: DocumentWindowReusePolicy.orderedDocumentCandidates,
            behavior: openBehavior()
        )
    }

    private func replace(with records: [RecentDocumentRecord], synchronizeSystem: Bool) {
        let retained = Array(normalized(records).prefix(RecentDocumentPolicy.clampCapacity(capacity())))
        entries = retained.map(RecentDocumentEntry.init(record:))
        persistence.save(retained)
        if synchronizeSystem {
            systemSynchronizer(entries)
        }
        if isMenuIntegrationInstalled {
            configureFileMenu()
        }
    }

    private func normalized(_ records: [RecentDocumentRecord]) -> [RecentDocumentRecord] {
        var identities = Set<String>()
        return records.compactMap { record in
            let path = URL(fileURLWithPath: record.exactPath).standardizedFileURL.path
            guard identities.insert(path).inserted else { return nil }
            return RecentDocumentRecord(exactPath: path, bookmark: record.bookmark)
        }
    }

    private func locateFileMenu() -> NSMenu? {
        NSApp.mainMenu?.items.lazy.compactMap(\.submenu).first { menu in
            menu.items.contains { item in
                item.action == #selector(NSDocumentController.openDocument(_:))
                    || item.action == #selector(openDocumentMenuItem(_:))
            }
        }
    }

    private func locateRecentItem(in fileMenu: NSMenu) -> NSMenuItem? {
        fileMenu.items.first { item in
            item.title == "打开最近"
                || item.submenu?.items.contains(where: {
                    $0.action == #selector(NSDocumentController.clearRecentDocuments(_:))
                        || $0.action == #selector(clearRecentMenuItem(_:))
                }) == true
        }
    }

    private func insertRecentItem(in fileMenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: "打开最近", action: nil, keyEquivalent: "")
        let openIndex = fileMenu.items.firstIndex { $0.action == #selector(openDocumentMenuItem(_:)) }
            ?? 0
        fileMenu.insertItem(item, at: min(openIndex + 1, fileMenu.items.count))
        return item
    }
}
