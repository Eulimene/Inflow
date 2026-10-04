import AppKit
import Combine
import Foundation
import ObjectiveC
import UniformTypeIdentifiers

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

enum DocumentSecurityScopePolicy {
    static func shouldStartFileScopedAccess(
        hasProjectAuthorization: Bool
    ) -> Bool {
        !hasProjectAuthorization
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
    struct Inspection: Sendable {
        let preflight: MarkdownOpenPreflight
        let authorizedData: Data?
    }

    func inspect(
        _ url: URL,
        authorization: ProjectDocumentOpenAuthorization? = nil
    ) throws -> Inspection {
        let data: Data
        if let authorization {
            guard authorization.targetURL.standardizedFileURL == url.standardizedFileURL,
                  authorization.isCurrent()
            else {
                throw DocumentOpenError.targetChanged
            }
            do {
                data = try PreviewLocalFileReader.read(
                    url,
                    expected: authorization.snapshot
                ).data
            } catch let error as PreviewLocalFileError {
                switch error {
                case .tooLarge:
                    throw DocumentOpenError.tooLarge
                case .missing, .unavailable:
                    throw DocumentOpenError.fileUnavailable
                case .notRegularFile, .unsafeContent:
                    throw DocumentOpenError.unsupportedTarget
                case .changedDuringRead:
                    throw DocumentOpenError.targetChanged
                }
            } catch {
                throw DocumentOpenError.fileUnavailable
            }
        } else {
            data = try Data(contentsOf: url)
        }
        return Inspection(
            preflight: try MarkdownOpenPreflight.inspect(data),
            authorizedData: authorization == nil ? nil : data
        )
    }
}

@MainActor
enum AuthorizedMarkdownDocumentOpener {
    private typealias Completion = @MainActor (
        Result<OpenedDocumentResult, Error>
    ) -> Void

    private struct PendingRequest {
        let data: Data
        let authorization: ProjectDocumentOpenAuthorization
        let documentController: NSDocumentController
        let completion: Completion
    }

    private static var pendingByRepresentedPath: [String: [PendingRequest]] = [:]

    static func open(
        from data: Data,
        authorization: ProjectDocumentOpenAuthorization,
        documentController: NSDocumentController = .shared,
        completion: @escaping @MainActor (
            Result<OpenedDocumentResult, Error>
        ) -> Void
    ) {
        let representedPath = authorization.targetURL.standardizedFileURL.path
        let request = PendingRequest(
            data: data,
            authorization: authorization,
            documentController: documentController,
            completion: completion
        )
        if pendingByRepresentedPath[representedPath] != nil {
            pendingByRepresentedPath[representedPath]?.append(request)
            return
        }
        pendingByRepresentedPath[representedPath] = [request]
        startNextOpen(representedPath: representedPath)
    }

    private static func startNextOpen(representedPath: String) {
        guard let request = pendingByRepresentedPath[representedPath]?.first else {
            pendingByRepresentedPath.removeValue(forKey: representedPath)
            return
        }
        let originalURL = request.authorization.targetURL
        let snapshot = request.authorization.snapshot
        let typeName = UTType.inflowMarkdown.identifier
        let stagingURL: URL
        do {
            // `reopenDocument` distinguishes the represented URL from the
            // contents URL. The pending registry above serializes concurrent
            // requests by the original path while SwiftUI reads only
            // descriptor-frozen bytes from this app-owned randomized copy.
            stagingURL = try SafePreviewOpenStore.materialize(
                FrozenPreviewLocalFile(data: request.data, snapshot: snapshot),
                extension: originalURL.pathExtension
            )
        } catch {
            finishCurrentOpen(
                representedPath: representedPath,
                result: .failure(error)
            )
            return
        }
        // Protect the copy before handing it to AppKit. The callback may be
        // delayed indefinitely, and periodic maintenance must not race the
        // native document while it is still consuming this URL.
        guard SafePreviewOpenStore.protectManagedCopy(at: stagingURL) else {
            SafePreviewOpenStore.discardManagedCopy(at: stagingURL)
            finishCurrentOpen(
                representedPath: representedPath,
                result: .failure(PreviewLocalFileError.unavailable)
            )
            return
        }
        request.documentController.reopenDocument(
            for: originalURL,
            withContentsOf: stagingURL,
            display: false
        ) { document, wasAlreadyOpen, error in
            if let error {
                SafePreviewOpenStore.discardManagedCopy(at: stagingURL)
                finishCurrentOpen(
                    representedPath: representedPath,
                    result: .failure(error)
                )
                return
            }
            guard let document else {
                SafePreviewOpenStore.discardManagedCopy(at: stagingURL)
                finishCurrentOpen(
                    representedPath: representedPath,
                    result: .failure(DocumentOpenError.unsupportedTarget)
                )
                return
            }
            if !wasAlreadyOpen {
                // AppKit adopts `withContentsOf` as the document's autosaved
                // contents and removes it when the document closes. Keep the
                // immutable copy alive for that ownership window and only let
                // startup/periodic maintenance remove abandoned copies.
                document.fileType = typeName
                document.fileModificationDate = snapshot.modificationDate
                document.updateChangeCount(.changeCleared)
                NativeDocumentLoadedFileRegistry.register(
                    document,
                    authorization: request.authorization
                )
            } else {
                SafePreviewOpenStore.discardManagedCopy(at: stagingURL)
                if !NativeDocumentLoadedFileRegistry.canFocusAlreadyOpen(
                    document,
                    authorization: request.authorization,
                    documentController: request.documentController
                ) {
                    finishCurrentOpen(
                        representedPath: representedPath,
                        result: .failure(DocumentOpenError.targetChanged)
                    )
                    return
                }
            }
            finishCurrentOpen(
                representedPath: representedPath,
                result: .success(
                    OpenedDocumentResult(
                        document: document,
                        wasAlreadyOpen: wasAlreadyOpen,
                        receipt: ProjectDocumentOpenReceipt(
                            authorization: request.authorization,
                            expectedData: request.data
                        )
                    )
                )
            )
        }
    }

    private static func finishCurrentOpen(
        representedPath: String,
        result: Result<OpenedDocumentResult, Error>
    ) {
        guard var pending = pendingByRepresentedPath[representedPath],
              !pending.isEmpty
        else {
            pendingByRepresentedPath.removeValue(forKey: representedPath)
            return
        }
        let completed = pending.removeFirst()
        // Keep an empty sentinel while invoking the callback so a re-entrant
        // request queues behind this transaction instead of starting another
        // native open before ownership and cleanup have settled.
        pendingByRepresentedPath[representedPath] = pending
        completed.completion(result)
        if pendingByRepresentedPath[representedPath]?.isEmpty == true {
            pendingByRepresentedPath.removeValue(forKey: representedPath)
            return
        }

        // AppKit does not reliably coalesce two back-to-back
        // `reopenDocument` calls. Reuse the first result ourselves, but only
        // after its callback has returned: that callback is allowed to close
        // the document, in which case the next request must perform a fresh
        // native open rather than receive an already-closed shared object.
        if case let .success(opened) = result,
           let next = pendingByRepresentedPath[representedPath]?.first,
           next.documentController.documents.contains(where: {
               $0 === opened.document
           }),
           NativeDocumentLoadedFileRegistry.matches(
               opened.document,
               authorization: next.authorization
           )
        {
            finishCurrentOpen(
                representedPath: representedPath,
                result: .success(
                    OpenedDocumentResult(
                        document: opened.document,
                        wasAlreadyOpen: true,
                        receipt: ProjectDocumentOpenReceipt(
                            authorization: next.authorization,
                            expectedData: next.data
                        )
                    )
                )
            )
            return
        }
        startNextOpen(representedPath: representedPath)
    }
}

@MainActor
private final class NativeDocumentLoadedFileRecord: NSObject {
    let resolvedURL: URL
    let projectIdentity: FolderProjectDirectoryIdentity
    let snapshot: PreviewLocalFileSnapshot

    init(
        resolvedURL: URL,
        projectIdentity: FolderProjectDirectoryIdentity,
        snapshot: PreviewLocalFileSnapshot
    ) {
        self.resolvedURL = resolvedURL
        self.projectIdentity = projectIdentity
        self.snapshot = snapshot
    }
}

/// Distinguishes a document whose managed identity failed verification from a
/// document that has never participated in a project-authorized open. A nil
/// association is intentionally reserved for the latter (and for a successful
/// Save As outside the original project).
@MainActor
private final class NativeDocumentLoadedFileInvalidation: NSObject {}

@MainActor
enum NativeDocumentLoadedFileRegistry {
    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    static func register(
        _ document: NSDocument,
        authorization: ProjectDocumentOpenAuthorization
    ) {
        objc_setAssociatedObject(
            document,
            &associationKey,
            NativeDocumentLoadedFileRecord(
                resolvedURL: authorization.resolvedTargetURL,
                projectIdentity: authorization.projectIdentity,
                snapshot: authorization.snapshot
            ),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func matches(
        _ document: NSDocument,
        authorization: ProjectDocumentOpenAuthorization
    ) -> Bool {
        guard let representedURL = document.fileURL,
              let resolvedRepresentedURL = FolderProjectPathBoundary.resolvedURL(
                  representedURL,
                  within: authorization.projectRoot
              ),
              resolvedRepresentedURL == authorization.resolvedTargetURL
        else {
            return false
        }
        guard let record = objc_getAssociatedObject(
            document,
            &associationKey
        ) as? NativeDocumentLoadedFileRecord else {
            return false
        }
        return record.resolvedURL == authorization.resolvedTargetURL
            && record.projectIdentity == authorization.projectIdentity
            && record.snapshot == authorization.snapshot
    }

    static func representsTarget(
        _ document: NSDocument,
        authorization: ProjectDocumentOpenAuthorization,
        documentController: NSDocumentController = .shared
    ) -> Bool {
        guard documentController.documents.contains(where: { $0 === document }),
              let representedURL = document.fileURL,
              let resolvedRepresentedURL = FolderProjectPathBoundary.resolvedURL(
                  representedURL,
                  within: authorization.projectRoot
              )
        else {
            return false
        }
        return resolvedRepresentedURL == authorization.resolvedTargetURL
    }

    static func canFocusAlreadyOpen(
        _ document: NSDocument,
        authorization: ProjectDocumentOpenAuthorization,
        documentController: NSDocumentController = .shared
    ) -> Bool {
        guard representsTarget(
            document,
            authorization: authorization,
            documentController: documentController
        ) else {
            return false
        }
        let association = objc_getAssociatedObject(
            document,
            &associationKey
        )
        if association is NativeDocumentLoadedFileRecord {
            return matches(document, authorization: authorization)
        }
        // Unknown non-nil state is also rejected so a future registry value
        // cannot accidentally inherit the ordinary-document fast path.
        return association == nil
    }

    static func focusableDocument(
        authorization: ProjectDocumentOpenAuthorization,
        excluding excludedDocument: NSDocument? = nil,
        documentController: NSDocumentController = .shared
    ) -> NSDocument? {
        documentController.documents.first { document in
            document !== excludedDocument
                && canFocusAlreadyOpen(
                    document,
                    authorization: authorization,
                    documentController: documentController
                )
        }
    }

    /// Refreshes a project document's trusted identity only after the caller's
    /// save/reload transaction has committed, then independently verifies the
    /// same expected bytes through a descriptor before publishing the record.
    /// A failed refresh is conservative: the document remains open but can no
    /// longer satisfy a project fast path until it is safely reopened.
    @discardableResult
    static func refreshAfterVerifiedWrite(
        _ document: NSDocument,
        targetURL: URL,
        expectedData: Data
    ) -> Bool {
        guard let record = objc_getAssociatedObject(
            document,
            &associationKey
        ) as? NativeDocumentLoadedFileRecord else {
            return false
        }
        guard let representedURL = document.fileURL,
              representedURL.standardizedFileURL == targetURL.standardizedFileURL
        else {
            invalidate(document)
            return false
        }

        guard let authorization = ProjectDocumentOpenAuthorization.capture(
                  targetURL: representedURL,
                  projectRoot: record.projectIdentity.resolvedURL
              )
        else {
            if isLexicallyContained(
                representedURL,
                in: record.projectIdentity.resolvedURL
            ) {
                // A path still spelled inside the original project but now
                // resolving outside it is a boundary failure, not Save As.
                invalidate(document)
            } else {
                // A successful Save As to a visibly different location leaves
                // project management and becomes an ordinary native document.
                clear(document)
            }
            return false
        }

        guard authorization.projectIdentity == record.projectIdentity,
              let frozen = try? PreviewLocalFileReader.read(
                  representedURL,
                  expected: authorization.snapshot
              ),
              frozen.data == expectedData,
              authorization.isCurrent()
        else {
            invalidate(document)
            return false
        }
        register(document, authorization: authorization)
        return true
    }

    static func clear(_ document: NSDocument) {
        objc_setAssociatedObject(
            document,
            &associationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Keeps an already managed document aligned with a ctime-only identity
    /// refresh without turning an ordinary native window into project state.
    static func refreshManagedRegistration(
        _ document: NSDocument,
        authorization: ProjectDocumentOpenAuthorization
    ) {
        guard objc_getAssociatedObject(
            document,
            &associationKey
        ) is NativeDocumentLoadedFileRecord else {
            return
        }
        register(document, authorization: authorization)
    }

    private static func invalidate(_ document: NSDocument) {
        objc_setAssociatedObject(
            document,
            &associationKey,
            NativeDocumentLoadedFileInvalidation(),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func isLexicallyContained(
        _ candidateURL: URL,
        in rootURL: URL
    ) -> Bool {
        guard candidateURL.isFileURL, rootURL.isFileURL else { return false }
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func matchingDocument(
        authorization: ProjectDocumentOpenAuthorization,
        excluding excludedDocument: NSDocument? = nil,
        documentController: NSDocumentController = .shared
    ) -> NSDocument? {
        documentController.documents.first { document in
            document !== excludedDocument
                && matches(document, authorization: authorization)
        }
    }
}

enum DocumentOpenError: Error, LocalizedError {
    case unsupportedTarget
    case unsupportedEncoding
    case tooLarge
    case fileUnavailable
    case targetChanged
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            "只能在 Inflow 中编辑 .md 或 .markdown 文件。"
        case .unsupportedEncoding:
            "这个文件不是可编辑的 UTF-8 Markdown。"
        case .tooLarge:
            "这个 Markdown 文件过大，当前版本无法安全打开。原文件没有被修改。"
        case .fileUnavailable:
            "当前无法读取这个 Markdown 文件。请检查访问权限或文件是否仍然可用。"
        case .targetChanged:
            "目标文件或项目边界在打开期间发生了变化。为避免读取错误内容，本次没有打开。"
        case .cancelled:
            "已取消切换。"
        case .timedOut:
            "打开文档等待超时，已取消本次项目切换。"
        }
    }
}

@MainActor
struct OpenedDocumentResult {
    let document: NSDocument
    let wasAlreadyOpen: Bool
    let receipt: ProjectDocumentOpenReceipt?

    init(
        document: NSDocument,
        wasAlreadyOpen: Bool,
        receipt: ProjectDocumentOpenReceipt? = nil
    ) {
        self.document = document
        self.wasAlreadyOpen = wasAlreadyOpen
        self.receipt = receipt
    }
}

/// Serializes a document close decision without closing the document until the
/// caller has successfully opened its replacement. Production document hosts
/// approve disposable drafts directly; the delegate boundary remains useful
/// for custom hosts and deterministic tests.
@MainActor
final class DocumentCloseAuthorization: NSObject {
    private static var pending: [ObjectIdentifier: DocumentCloseAuthorization] = [:]

    static var hasPendingRequests: Bool {
        removeReleasedRequests()
        return !pending.isEmpty
    }

    private weak var document: NSDocument?
    private let completion: (Bool) -> Void

    private init(document: NSDocument, completion: @escaping (Bool) -> Void) {
        self.document = document
        self.completion = completion
    }

    static func request(
        for document: NSDocument?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let document else {
            completion(true)
            return
        }

        removeReleasedRequests()
        let documentID = ObjectIdentifier(document)
        guard pending[documentID] == nil else {
            // A native close review is already attached to this document. A
            // second project click must not replace its delegate/completion and
            // accidentally allow two switches after one decision.
            completion(false)
            return
        }

        guard document.isDocumentEdited else {
            completion(true)
            return
        }

        let authorization = DocumentCloseAuthorization(
            document: document,
            completion: completion
        )
        pending[documentID] = authorization
        document.canClose(
            withDelegate: authorization,
            shouldClose: #selector(document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    private static func removeReleasedRequests() {
        pending = pending.filter { $0.value.document != nil }
    }

    @objc private func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo _: UnsafeMutableRawPointer?
    ) {
        Self.pending.removeValue(forKey: ObjectIdentifier(document))
        completion(shouldClose)
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

enum DocumentOpenTargetKind: Equatable, Sendable {
    case markdownFile
    case projectDirectory
}

enum DocumentOpenRouteBlankToken: Equatable, Sendable {
    case reusableBlankWindow
}

enum DocumentOpenRouteAction: Equatable, Sendable {
    case focusExistingFile(URL)
    case openFile(URL, reuseBlank: DocumentOpenRouteBlankToken?)
    case focusExistingProject(URL)
    case openProject(URL, reuseBlank: DocumentOpenRouteBlankToken?)

    var url: URL {
        switch self {
        case let .focusExistingFile(url),
             let .openFile(url, _),
             let .focusExistingProject(url),
             let .openProject(url, _):
            url
        }
    }

    var reuseBlank: DocumentOpenRouteBlankToken? {
        switch self {
        case let .openFile(_, token), let .openProject(_, token): token
        case .focusExistingFile, .focusExistingProject: nil
        }
    }
}

enum DocumentOpenRouteRejectionReason: Equatable, Sendable {
    case unsupportedTarget
    case mixedFilesAndDirectories
    case multipleDirectories
}

struct DocumentOpenRouteRejection: Equatable, Sendable {
    let url: URL
    let reason: DocumentOpenRouteRejectionReason
}

struct DocumentOpenRoutePlan: Equatable, Sendable {
    let actions: [DocumentOpenRouteAction]
    let rejections: [DocumentOpenRouteRejection]
}

enum DocumentOpenRouter {
    typealias TargetClassifier = (URL) -> DocumentOpenTargetKind?

    static func plan(
        inputURLs: [URL],
        openedDocumentURLs: [URL],
        openedProjectURLs: [URL],
        hasReusableBlankWindow: Bool,
        classifyTarget: TargetClassifier = { supportedTargetKind(for: $0) }
    ) -> DocumentOpenRoutePlan {
        struct Candidate {
            let inputIndex: Int
            let url: URL
            let pathIdentity: String
            let kind: DocumentOpenTargetKind
        }
        enum InputIdentity: Hashable {
            case supportedFilePath(String)
            case unsupportedFilePath(String)
            case other(String)
        }

        var seenInputs = Set<InputIdentity>()
        var candidates: [Candidate] = []
        var indexedRejections: [(Int, DocumentOpenRouteRejection)] = []

        for (index, inputURL) in inputURLs.enumerated() {
            guard inputURL.isFileURL else {
                let identity = InputIdentity.other(inputURL.absoluteString)
                guard seenInputs.insert(identity).inserted else { continue }
                indexedRejections.append((
                    index,
                    DocumentOpenRouteRejection(
                        url: inputURL,
                        reason: .unsupportedTarget
                    )
                ))
                continue
            }

            let url = normalizedFileURL(inputURL)
            guard let kind = classifyTarget(url) else {
                guard seenInputs.insert(.unsupportedFilePath(url.path)).inserted else {
                    continue
                }
                indexedRejections.append((
                    index,
                    DocumentOpenRouteRejection(
                        url: url,
                        reason: .unsupportedTarget
                    )
                ))
                continue
            }
            let pathIdentity = canonicalPathIdentity(for: url)
            guard seenInputs.insert(.supportedFilePath(pathIdentity)).inserted else {
                continue
            }
            candidates.append(
                Candidate(
                    inputIndex: index,
                    url: url,
                    pathIdentity: pathIdentity,
                    kind: kind
                )
            )
        }

        let files = candidates.filter { $0.kind == .markdownFile }
        let directories = candidates.filter { $0.kind == .projectDirectory }
        let supportedCandidates: [Candidate]
        if !files.isEmpty, !directories.isEmpty {
            supportedCandidates = files
            indexedRejections.append(contentsOf: directories.map {
                (
                    $0.inputIndex,
                    DocumentOpenRouteRejection(
                        url: $0.url,
                        reason: .mixedFilesAndDirectories
                    )
                )
            })
        } else if directories.count > 1 {
            supportedCandidates = []
            indexedRejections.append(contentsOf: directories.map {
                (
                    $0.inputIndex,
                    DocumentOpenRouteRejection(
                        url: $0.url,
                        reason: .multipleDirectories
                    )
                )
            })
        } else {
            supportedCandidates = candidates
        }

        let openedDocuments = canonicalPathSet(openedDocumentURLs)
        let openedProjects = canonicalPathSet(openedProjectURLs)
        var blankTokenIsAvailable = hasReusableBlankWindow
        var actions: [DocumentOpenRouteAction] = []
        actions.reserveCapacity(supportedCandidates.count)

        for candidate in supportedCandidates {
            switch candidate.kind {
            case .markdownFile where openedDocuments.contains(candidate.pathIdentity):
                actions.append(.focusExistingFile(candidate.url))
            case .projectDirectory where openedProjects.contains(candidate.pathIdentity):
                actions.append(.focusExistingProject(candidate.url))
            case .markdownFile:
                let token: DocumentOpenRouteBlankToken? = blankTokenIsAvailable
                    ? .reusableBlankWindow
                    : nil
                blankTokenIsAvailable = false
                actions.append(.openFile(candidate.url, reuseBlank: token))
            case .projectDirectory:
                let token: DocumentOpenRouteBlankToken? = blankTokenIsAvailable
                    ? .reusableBlankWindow
                    : nil
                blankTokenIsAvailable = false
                actions.append(.openProject(candidate.url, reuseBlank: token))
            }
        }

        return DocumentOpenRoutePlan(
            actions: actions,
            rejections: indexedRejections
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        )
    }

    static func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    static func canonicalPathIdentity(for url: URL) -> String {
        normalizedFileURL(url)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func supportedTargetKind(for url: URL) -> DocumentOpenTargetKind? {
        guard url.isFileURL else { return nil }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue
        {
            return .projectDirectory
        }
        if url.hasDirectoryPath {
            return .projectDirectory
        }
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdownFile
        default: return nil
        }
    }

    private static func canonicalPathSet(_ urls: [URL]) -> Set<String> {
        Set(urls.lazy.filter(\.isFileURL).map { canonicalPathIdentity(for: $0) })
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
    private let recordsOpenedDocuments: Bool
    private let reusableBlankDocumentFilter: (NSDocument) -> Bool
    private let failureRecorder: (LocalFailureCategory, LocalFailureCode) -> Void
    private let openedProjectURLs: @MainActor () -> [URL]
    private let focusExistingProject: @MainActor (URL) -> Void
    private let openProject: @MainActor (URL, NSDocument?) -> Void
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
        },
        recordsOpenedDocuments: Bool = true,
        reusableBlankDocumentFilter: @escaping (NSDocument) -> Bool = { _ in true },
        failureRecorder: @escaping (LocalFailureCategory, LocalFailureCode) -> Void = { _, _ in },
        openedProjectURLs: @escaping @MainActor () -> [URL] = { [] },
        focusExistingProject: @escaping @MainActor (URL) -> Void = { _ in },
        openProject: @escaping @MainActor (URL, NSDocument?) -> Void = { _, _ in }
    ) {
        self.persistence = persistence
        self.capacity = capacity
        self.openBehavior = openBehavior
        self.bookmarkData = bookmarkData
        self.systemSynchronizer = systemSynchronizer
        self.recordsOpenedDocuments = recordsOpenedDocuments
        self.reusableBlankDocumentFilter = reusableBlankDocumentFilter
        self.failureRecorder = failureRecorder
        self.openedProjectURLs = openedProjectURLs
        self.focusExistingProject = focusExistingProject
        self.openProject = openProject
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
        guard recordsOpenedDocuments else { return }
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
        storedRecords = Array(
            storedRecords.prefix(RecentDocumentPolicy.clampCapacity(capacity()))
        )
        persistence.save(storedRecords)
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
        openExternalDocuments([url])
    }

    @objc private func openDocumentMenuItem(_: Any?) {
        chooseDocumentToOpen()
    }

    func chooseDocumentToOpen() {
        NSDocumentController.shared.beginOpenPanel { [weak self] urls in
            guard let self, let urls else { return }
            self.openExternalDocuments(urls)
        }
    }

    func chooseProjectToOpen(
        attachedTo window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow
    ) {
        let panel = NSOpenPanel()
        panel.title = "打开项目"
        panel.message = "选择一个普通文件夹。Inflow 不会导入、复制或重组其中内容。"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.openExternalDocuments([url])
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    @discardableResult
    func openExternalDocuments(_ urls: [URL]) -> DocumentOpenRoutePlan {
        let reusableDocument = reusableBlankDocument()
        let plan = DocumentOpenRouter.plan(
            inputURLs: urls,
            openedDocumentURLs: NSDocumentController.shared.documents.compactMap(\.fileURL),
            openedProjectURLs: openedProjectURLs(),
            hasReusableBlankWindow: reusableDocument != nil
        )
        for action in plan.actions {
            switch action {
            case let .focusExistingFile(url):
                focusExistingDocument(at: url)
            case let .openFile(url, token):
                open(
                    url,
                    reusableDocument: token == nil ? nil : reusableDocument
                )
            case let .focusExistingProject(url):
                focusExistingProject(url)
            case let .openProject(url, token):
                openProject(url, token == nil ? nil : reusableDocument)
            }
        }
        return plan
    }

    func openDocumentFromFolder(_ url: URL) {
        openDocumentFromFolderDetailed(
            url,
            presentsErrors: true
        ) { _ in }
    }

    func openDocumentFromFolder(
        _ url: URL,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        openDocumentFromFolderDetailed(url) { result in
            completion(result.map { _ in () })
        }
    }

    func openDocumentFromFolderDetailed(
        _ url: URL,
        authorization: ProjectDocumentOpenAuthorization? = nil,
        display: Bool = true,
        presentsErrors: Bool = false,
        completion: @escaping @MainActor (Result<OpenedDocumentResult, Error>) -> Void
    ) {
        guard Self.supportedExternalDocumentURLs(from: [url]).count == 1 else {
            completion(.failure(DocumentOpenError.unsupportedTarget))
            return
        }
        open(
            url,
            reusableDocument: nil,
            authorization: authorization,
            display: display,
            presentsErrors: presentsErrors,
            completion: completion
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

        // The personal milestone routes Open through Inflow's deduplicating
        // open router, but deliberately leaves macOS's own Open Recent menu
        // alone instead of presenting an Inflow-managed history.
        guard recordsOpenedDocuments else { return }

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

    private func open(
        _ url: URL,
        reusableDocument: NSDocument?,
        authorization: ProjectDocumentOpenAuthorization? = nil,
        display: Bool = true,
        presentsErrors: Bool = true,
        completion: @escaping @MainActor (Result<OpenedDocumentResult, Error>) -> Void = { _ in }
    ) {
        let trace = PerformanceTrace.begin("file.open")
        let originalCompletion = completion
        let completion: @MainActor (Result<OpenedDocumentResult, Error>) -> Void = { result in
            if case .success = result { trace?.end() } else { trace?.end("failed") }
            originalCompletion(result)
        }
        // A project authorization is backed by the retained security-scoped
        // lease for the user-selected root. Starting a second lease on the
        // child file can update Finder's last-used metadata (and therefore
        // ctime) after the click snapshot was frozen, making a safe file look
        // as though it changed before preflight even reads it.
        let accessed = DocumentSecurityScopePolicy.shouldStartFileScopedAccess(
            hasProjectAuthorization: authorization != nil
        )
            && url.startAccessingSecurityScopedResource()
        Task { @MainActor [weak self] in
            guard let self else {
                if accessed { url.stopAccessingSecurityScopedResource() }
                trace?.end("cancelled")
                return
            }
            await PerformanceTrace.$parentID.withValue(trace?.id ?? PerformanceTrace.parentID) {
                do {
                    let inspection = try await PerformanceTrace.measureAsync("file.preflight") {
                        try await openPreflightWorker.inspect(url, authorization: authorization)
                    }
                    switch inspection.preflight {
                    case .supported:
                        openVerifiedDocument(
                            url,
                            reusableDocument: reusableDocument,
                            authorization: authorization,
                            authorizedData: inspection.authorizedData,
                            display: display,
                            presentsErrors: presentsErrors,
                            securityScopeIsActive: accessed,
                            completion: completion
                        )
                    case let .unsupportedEncoding(originalData):
                        if accessed { url.stopAccessingSecurityScopedResource() }
                        failureRecorder(.opening, .unsupportedEncoding)
                        completion(.failure(DocumentOpenError.unsupportedEncoding))
                        if presentsErrors {
                            await UnsupportedEncodingRecoveryUI.present(
                                sourceURL: url,
                                originalData: originalData,
                                attachedTo: NSApp.keyWindow ?? NSApp.mainWindow
                            )
                        }
                    }
                } catch {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    failureRecorder(.opening, .fileUnavailable)
                    completion(.failure(error))
                    if presentsErrors {
                        NSDocumentController.shared.presentError(error)
                    }
                }
            }
        }
    }

    private func openVerifiedDocument(
        _ url: URL,
        reusableDocument: NSDocument?,
        authorization: ProjectDocumentOpenAuthorization?,
        authorizedData: Data?,
        display: Bool,
        presentsErrors: Bool,
        securityScopeIsActive: Bool,
        completion: @escaping @MainActor (Result<OpenedDocumentResult, Error>) -> Void
    ) {
        guard authorization?.isCurrent() != false else {
            if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
            completion(.failure(DocumentOpenError.targetChanged))
            return
        }
        if let authorization, let authorizedData {
            openAuthorizedDocument(
                url,
                reusableDocument: reusableDocument,
                authorization: authorization,
                data: authorizedData,
                display: display,
                presentsErrors: presentsErrors,
                securityScopeIsActive: securityScopeIsActive,
                completion: completion
            )
            return
        }
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: display
        ) { [weak self] document, wasAlreadyOpen, error in
            if let error {
                if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
                self?.failureRecorder(.opening, .fileUnavailable)
                completion(.failure(error))
                if presentsErrors {
                    NSDocumentController.shared.presentError(error)
                }
                return
            }
            guard let self, let document else {
                if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
                self?.failureRecorder(.opening, .fileUnavailable)
                completion(.failure(DocumentOpenError.unsupportedTarget))
                return
            }
            guard authorization?.isCurrent() != false else {
                if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
                if !wasAlreadyOpen,
                   !document.isDocumentEdited,
                   document.windowControllers.allSatisfy({ $0.window?.isVisible != true })
                {
                    document.close()
                }
                self.failureRecorder(.opening, .fileUnavailable)
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            self.finishSuccessfulOpen(
                document,
                wasAlreadyOpen: wasAlreadyOpen,
                receipt: nil,
                url: url,
                reusableDocument: reusableDocument,
                securityScopeIsActive: securityScopeIsActive,
                completion: completion
            )
        }
    }

    private func openAuthorizedDocument(
        _ url: URL,
        reusableDocument: NSDocument?,
        authorization: ProjectDocumentOpenAuthorization,
        data: Data,
        display: Bool,
        presentsErrors: Bool,
        securityScopeIsActive: Bool,
        completion: @escaping @MainActor (Result<OpenedDocumentResult, Error>) -> Void
    ) {
        let documentController = NSDocumentController.shared
        guard authorization.isCurrent() else {
            if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
            failureRecorder(.opening, .fileUnavailable)
            completion(.failure(DocumentOpenError.targetChanged))
            return
        }
        if let existing = NativeDocumentLoadedFileRegistry.focusableDocument(
            authorization: authorization,
            documentController: documentController
        ) {
            guard authorization.isCurrent() else {
                if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
                failureRecorder(.opening, .fileUnavailable)
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            if display {
                existing.showWindows()
                existing.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            guard let currentAuthorization = authorization.refreshedAfterVerifiedRead(
                expectedData: data
            ) else {
                if securityScopeIsActive { url.stopAccessingSecurityScopedResource() }
                failureRecorder(.opening, .fileUnavailable)
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            NativeDocumentLoadedFileRegistry.refreshManagedRegistration(
                existing,
                authorization: currentAuthorization
            )
            finishSuccessfulOpen(
                existing,
                wasAlreadyOpen: true,
                receipt: ProjectDocumentOpenReceipt(
                    authorization: currentAuthorization,
                    expectedData: data
                ),
                url: url,
                reusableDocument: reusableDocument,
                securityScopeIsActive: securityScopeIsActive,
                completion: completion
            )
            return
        }
        AuthorizedMarkdownDocumentOpener.open(
            from: data,
            authorization: authorization,
            documentController: documentController
        ) { [weak self] result in
            guard let self else {
                if securityScopeIsActive {
                    url.stopAccessingSecurityScopedResource()
                }
                if case let .success(opened) = result, !opened.wasAlreadyOpen {
                    opened.document.close()
                }
                return
            }
            guard case let .success(opened) = result else {
                if securityScopeIsActive {
                    url.stopAccessingSecurityScopedResource()
                }
                self.failureRecorder(.opening, .fileUnavailable)
                if case let .failure(error) = result {
                    completion(.failure(error))
                    if presentsErrors {
                        documentController.presentError(error)
                    }
                }
                return
            }
            guard let currentAuthorization = authorization.refreshedAfterVerifiedRead(
                expectedData: data
            ) else {
                if securityScopeIsActive {
                    url.stopAccessingSecurityScopedResource()
                }
                if !opened.wasAlreadyOpen { opened.document.close() }
                self.failureRecorder(.opening, .fileUnavailable)
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            if opened.wasAlreadyOpen {
                guard NativeDocumentLoadedFileRegistry.canFocusAlreadyOpen(
                    opened.document,
                    authorization: currentAuthorization,
                    documentController: documentController
                ) else {
                    if securityScopeIsActive {
                        url.stopAccessingSecurityScopedResource()
                    }
                    self.failureRecorder(.opening, .fileUnavailable)
                    completion(.failure(DocumentOpenError.targetChanged))
                    return
                }
            } else {
                NativeDocumentLoadedFileRegistry.register(
                    opened.document,
                    authorization: currentAuthorization
                )
            }
            if display {
                if opened.document.windowControllers.isEmpty {
                    opened.document.makeWindowControllers()
                }
                opened.document.showWindows()
                opened.document.windowControllers.first?.window?
                    .makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            guard let displayedAuthorization = currentAuthorization.refreshedAfterVerifiedRead(
                expectedData: data
            ) else {
                if securityScopeIsActive {
                    url.stopAccessingSecurityScopedResource()
                }
                if !opened.wasAlreadyOpen { opened.document.close() }
                self.failureRecorder(.opening, .fileUnavailable)
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            if opened.wasAlreadyOpen {
                NativeDocumentLoadedFileRegistry.refreshManagedRegistration(
                    opened.document,
                    authorization: displayedAuthorization
                )
            } else {
                NativeDocumentLoadedFileRegistry.register(
                    opened.document,
                    authorization: displayedAuthorization
                )
            }
            self.finishSuccessfulOpen(
                opened.document,
                wasAlreadyOpen: opened.wasAlreadyOpen,
                receipt: ProjectDocumentOpenReceipt(
                    authorization: displayedAuthorization,
                    expectedData: data
                ),
                url: url,
                reusableDocument: reusableDocument,
                securityScopeIsActive: securityScopeIsActive,
                completion: completion
            )
        }
    }

    private func finishSuccessfulOpen(
        _ document: NSDocument,
        wasAlreadyOpen: Bool,
        receipt: ProjectDocumentOpenReceipt?,
        url: URL,
        reusableDocument: NSDocument?,
        securityScopeIsActive: Bool,
        completion: @escaping @MainActor (Result<OpenedDocumentResult, Error>) -> Void
    ) {
        if securityScopeIsActive {
            SecurityScopedDocumentLeaseRegistry.retainActiveAccess(
                to: url,
                for: document
            )
        }
        note(url)
        if !wasAlreadyOpen,
           let reusableDocument,
           reusableDocument !== document,
           // The preflight and document construction are asynchronous. Consume
           // the selected blank only if it is still fully reusable at commit.
           self.reusableBlankDocument() === reusableDocument
        {
            reusableDocument.close()
        }
        completion(
            .success(
                OpenedDocumentResult(
                    document: document,
                    wasAlreadyOpen: wasAlreadyOpen,
                    receipt: receipt
                )
            )
        )
    }

    private func reusableBlankDocument() -> NSDocument? {
        DocumentWindowReusePolicy.reusableBlankDocument(
            from: DocumentWindowReusePolicy.orderedDocumentCandidates.filter(
                reusableBlankDocumentFilter
            ),
            behavior: openBehavior()
        )
    }

    private func focusExistingDocument(at url: URL) {
        let identity = DocumentOpenRouter.canonicalPathIdentity(for: url)
        guard let document = NSDocumentController.shared.documents.first(where: {
            guard let fileURL = $0.fileURL else { return false }
            return DocumentOpenRouter.canonicalPathIdentity(for: fileURL) == identity
        }) else {
            return
        }
        document.showWindows()
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func replaceStoredRecords(
        with records: [RecentDocumentRecord],
        synchronizeSystem: Bool
    ) {
        storedRecords = Array(
            normalized(records).prefix(RecentDocumentPolicy.clampCapacity(capacity()))
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
        enum Identity: Hashable {
            case resource(DocumentResourceIdentity)
            case path(String)
        }
        var identities = Set<Identity>()
        return records.compactMap { record in
            let path = URL(fileURLWithPath: record.exactPath).standardizedFileURL.path
            let url = URL(fileURLWithPath: path)
            let identity = DocumentResourceIdentity.capture(url)
                .map(Identity.resource) ?? .path(path)
            guard identities.insert(identity).inserted else { return nil }
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
