import AppKit
import Combine
import Foundation
import ObjectiveC

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
final class SecurityScopedDocumentLease: NSObject {
    let url: URL
    private var isActive: Bool
    private let stopAccess: (URL) -> Void

    init(url: URL, stopAccess: @escaping (URL) -> Void) {
        self.url = url
        isActive = true
        self.stopAccess = stopAccess
    }

    func invalidate() {
        guard isActive else { return }
        isActive = false
        stopAccess(url)
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }
}

@MainActor
enum SecurityScopedDocumentLeaseRegistry {
    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    static func retainActiveAccess(
        to url: URL,
        for document: NSDocument,
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        objc_setAssociatedObject(
            document,
            &associationKey,
            SecurityScopedDocumentLease(url: url, stopAccess: stopAccess),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func releaseAccess(for document: NSDocument) {
        objc_setAssociatedObject(
            document,
            &associationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func activeURL(for document: NSDocument) -> URL? {
        (objc_getAssociatedObject(document, &associationKey) as? SecurityScopedDocumentLease)?.url
    }
}

enum MarkdownOpenPreflight: Equatable, Sendable {
    case supported
    case unsupportedEncoding(originalData: Data)

    static func inspect(_ data: Data) throws -> Self {
        do {
            _ = try MarkdownCodec.decode(data)
            return .supported
        } catch MarkdownCodecError.invalidUTF8 {
            return .unsupportedEncoding(originalData: data)
        }
    }
}

actor MarkdownOpenPreflightWorker {
    func inspect(_ url: URL) throws -> MarkdownOpenPreflight {
        let data = try Data(contentsOf: url)
        return try MarkdownOpenPreflight.inspect(data)
    }
}

enum UnsupportedEncodingRecoveryCopyError: Error, Equatable, LocalizedError {
    case sourceDestinationConflict
    case targetChanged
    case cannotCopy

    var errorDescription: String? {
        switch self {
        case .sourceDestinationConflict:
            "请选择其他位置。复制原文件不会覆盖源文件。"
        case .targetChanged:
            "确认后，复制目标已被创建或修改。本次没有写入，请重新选择。"
        case .cannotCopy:
            "未能安全复制原文件。源文件没有被修改。"
        }
    }
}

enum UnsupportedEncodingRecoveryCopy {
    static func write(
        originalData: Data,
        sourceURL: URL,
        targetURL: URL,
        expectedTarget: HTMLExportTargetSnapshot,
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        guard sourceURL.standardizedFileURL != targetURL.standardizedFileURL,
              !referencesSameExistingFile(sourceURL, targetURL)
        else {
            throw UnsupportedEncodingRecoveryCopyError.sourceDestinationConflict
        }
        do {
            try HTMLExportFileWriter.write(
                originalData,
                to: targetURL,
                expectedTarget: expectedTarget,
                beforeCommit: beforeCommit
            )
        } catch HTMLExportTargetError.targetChanged {
            throw UnsupportedEncodingRecoveryCopyError.targetChanged
        } catch {
            throw UnsupportedEncodingRecoveryCopyError.cannotCopy
        }
    }

    private static func referencesSameExistingFile(_ first: URL, _ second: URL) -> Bool {
        var firstMetadata = stat()
        var secondMetadata = stat()
        let firstStatus: Int32 = first.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &firstMetadata)
        }
        let secondStatus: Int32 = second.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &secondMetadata)
        }
        return firstStatus == 0
            && secondStatus == 0
            && firstMetadata.st_dev == secondMetadata.st_dev
            && firstMetadata.st_ino == secondMetadata.st_ino
    }
}

@MainActor
enum UnsupportedEncodingRecoveryUI {
    static let title = "不支持这个文件的编码"
    static let message = "Inflow 不会猜测编码或覆盖原文件。"
    static let showInFinderTitle = "在 Finder 中显示"
    static let copyOriginalTitle = "复制原文件…"
    static let cancelTitle = "取消"

    static func present(
        sourceURL: URL,
        originalData: Data,
        attachedTo window: NSWindow?
    ) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: showInFinderTitle)
        alert.addButton(withTitle: copyOriginalTitle)
        alert.addButton(withTitle: cancelTitle)

        switch await response(to: alert, attachedTo: window) {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
        case .alertSecondButtonReturn:
            await copyOriginalFile(
                sourceURL: sourceURL,
                originalData: originalData,
                attachedTo: window
            )
        default:
            break
        }
    }

    private static func copyOriginalFile(
        sourceURL: URL,
        originalData: Data,
        attachedTo window: NSWindow?
    ) async {
        let panel = NSSavePanel()
        panel.title = copyOriginalTitle
        panel.prompt = "复制"
        panel.message = "保存原始字节的完整副本；Inflow 不会转换编码。"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        guard await response(to: panel, attachedTo: window) == .OK,
              let targetURL = panel.url
        else {
            return
        }

        do {
            let expectedTarget = try HTMLExportTargetSnapshot.capture(targetURL)
            try UnsupportedEncodingRecoveryCopy.write(
                originalData: originalData,
                sourceURL: sourceURL,
                targetURL: targetURL,
                expectedTarget: expectedTarget
            )
        } catch {
            let failure = NSAlert(error: error)
            failure.alertStyle = .warning
            _ = await response(to: failure, attachedTo: window)
        }
    }

    private static func response(
        to alert: NSAlert,
        attachedTo window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func response(
        to panel: NSSavePanel,
        attachedTo window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard let window else { return panel.runModal() }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

@MainActor
enum DocumentWindowReusePolicy {
    static func reusableBlankDocument(from candidates: [NSDocument]) -> NSDocument? {
        candidates.first { document in
            document.fileURL == nil && !document.isDocumentEdited
        }
    }

    static func reusableBlankDocument(
        from candidates: [NSDocument],
        behavior: MarkdownOpenBehavior
    ) -> NSDocument? {
        guard behavior == .reuseBlankWindow else { return nil }
        return reusableBlankDocument(from: candidates)
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
    private var storedRecords: [RecentDocumentRecord] = []
    private let capacity: () -> Int
    private let openBehavior: () -> MarkdownOpenBehavior
    private let bookmarkData: (URL) -> Data?
    private let systemSynchronizer: ([RecentDocumentEntry]) -> Void
    private let openPreflightWorker = MarkdownOpenPreflightWorker()
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
        replaceStoredRecords(with: persistence.load(), synchronizeSystem: false)
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
        var records = storedRecords
        records.removeAll { $0.exactPath == identity }
        records.insert(
            RecentDocumentRecord(exactPath: identity, bookmark: bookmarkData(exactURL)),
            at: 0
        )
        replaceStoredRecords(with: records, synchronizeSystem: true)
    }

    func refresh() {
        replaceStoredRecords(with: persistence.load(), synchronizeSystem: false)
    }

    func applyCapacity() {
        publishVisibleEntries(synchronizeSystem: true)
    }

    func remove(_ entry: RecentDocumentEntry) {
        replaceStoredRecords(
            with: storedRecords.filter { $0.exactPath != entry.id },
            synchronizeSystem: true
        )
    }

    func clear() {
        replaceStoredRecords(with: [], synchronizeSystem: true)
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

    func openExternalDocuments(_ urls: [URL]) {
        let supportedURLs = Self.supportedExternalDocumentURLs(from: urls)
        let reusableDocument = reusableBlankDocument()
        for (index, url) in supportedURLs.enumerated() {
            open(url, reusableDocument: index == 0 ? reusableDocument : nil)
        }
    }

    func openDocumentFromFolder(_ url: URL) {
        guard Self.supportedExternalDocumentURLs(from: [url]).count == 1 else { return }
        open(
            url,
            reusableDocument: DocumentWindowReusePolicy.reusableBlankDocument(
                from: DocumentWindowReusePolicy.orderedDocumentCandidates
            )
        )
    }

    static func supportedExternalDocumentURLs(from urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            switch url.pathExtension.lowercased() {
            case "md", "markdown": return true
            default: return false
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
        Task { @MainActor [weak self] in
            guard let self else {
                if accessed { url.stopAccessingSecurityScopedResource() }
                return
            }
            do {
                switch try await openPreflightWorker.inspect(url) {
                case .supported:
                    openVerifiedDocument(
                        url,
                        reusableDocument: reusableDocument,
                        securityScopeIsActive: accessed
                    )
                case let .unsupportedEncoding(originalData):
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    await UnsupportedEncodingRecoveryUI.present(
                        sourceURL: url,
                        originalData: originalData,
                        attachedTo: NSApp.keyWindow ?? NSApp.mainWindow
                    )
                }
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                NSDocumentController.shared.presentError(error)
            }
        }
    }

    private func openVerifiedDocument(
        _ url: URL,
        reusableDocument: NSDocument?,
        securityScopeIsActive: Bool
    ) {
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { [weak self] document, wasAlreadyOpen, error in
            if let error {
                if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
                NSDocumentController.shared.presentError(error)
                return
            }
            guard let self, let document else {
                if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
                return
            }
            if securityScopeIsActive {
                SecurityScopedDocumentLeaseRegistry.retainActiveAccess(
                    to: url,
                    for: document
                )
            }
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

    private func replaceStoredRecords(
        with records: [RecentDocumentRecord],
        synchronizeSystem: Bool
    ) {
        storedRecords = Array(
            normalized(records).prefix(RecentDocumentPolicy.capacityRange.upperBound)
        )
        persistence.save(storedRecords)
        publishVisibleEntries(synchronizeSystem: synchronizeSystem)
    }

    private func publishVisibleEntries(synchronizeSystem: Bool) {
        let visibleRecords = storedRecords.prefix(
            RecentDocumentPolicy.clampCapacity(capacity())
        )
        entries = visibleRecords.map(RecentDocumentEntry.init(record:))
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
