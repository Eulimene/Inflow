import AppKit
import Foundation
import ObjectiveC.runtime
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let inflowMarkdown = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}

enum MarkdownDocumentCapabilityTier: Equatable, Sendable {
    case full
    case sourceOnly
}

enum MarkdownDocumentSizePolicy {
    static func tier(for _: Int) -> MarkdownDocumentCapabilityTier {
        .full
    }

    static func validatedTierForOpening(byteCount _: Int) throws
        -> MarkdownDocumentCapabilityTier
    {
        .full
    }
}

enum ManualSaveDocumentHostPolicyError: Error, LocalizedError {
    case unsupportedHost
    case cannotOverrideFrameworkPolicy

    var errorDescription: String? {
        switch self {
        case .unsupportedHost:
            "无法确认当前文档的手动保存宿主。"
        case .cannotOverrideFrameworkPolicy:
            "无法关闭系统文档宿主的自动保存；为避免未确认写入，当前文档已保持只读。"
        }
    }
}

/// Applies Inflow's explicit-save and disposable-draft contract to the concrete
/// `NSDocument` class created by SwiftUI's `DocumentGroup`.
///
/// `FileDocument` does not expose these AppKit class policies. Merely setting
/// `NSDocumentController.autosavingDelay` to zero disables periodic autosaves,
/// but AppKit will still silently autosave a named, edited document while it is
/// closing when the host class opts into autosaving in place. Inflow therefore
/// disables those automatic-save policies and replaces only the inherited close
/// review on the concrete host. Closing checkpoints the latest text to the
/// temporary draft directory before retiring its live recovery session. Explicit Save continues through Inflow's
/// guarded native save path.
///
/// This compatibility boundary is intentionally fail closed. If the host no
/// longer supports the selectors or the runtime result cannot be verified, the
/// editor remains read-only instead of risking an unconfirmed write.
@MainActor
enum ManualSaveDocumentHostPolicy {
    private enum ProcessState {
        case unconfigured
        case configured(ObjectIdentifier)
        case failed
    }

    private static var processState = ProcessState.unconfigured
    private static let swiftUIBundleIdentifier = "com.apple.SwiftUI"

    /// The runtime override is installed on the concrete SwiftUI document
    /// class, so every later document scene in this process can enter its
    /// editor immediately without flashing the one-time preparation screen.
    static var isProcessConfigured: Bool {
        if case .configured = processState { return true }
        return false
    }

    static func apply(to document: NSDocument) throws {
        let documentClass: NSDocument.Type = type(of: document)
        let classID = ObjectIdentifier(documentClass)

        switch processState {
        case .failed:
            throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
        case let .configured(configuredID):
            guard configuredID == classID,
                  hasManualSaveFlags(documentClass),
                  hasDisposableDraftClosePolicy(documentClass)
            else {
                processState = .failed
                throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
            }
            return
        case .unconfigured:
            break
        }

        do {
            guard ObjectIdentifier(documentClass) != ObjectIdentifier(NSDocument.self),
                  Bundle(for: documentClass).bundleIdentifier == swiftUIBundleIdentifier,
                  inheritsDefaultCloseAndSaveLifecycle(documentClass),
                  !concreteMetaclassDefinesAutomaticSavePolicy(documentClass),
                  automaticSaveFlagsMatch(
                      runtimeAutomaticSaveFlags(documentClass),
                      inPlace: true,
                      drafts: true,
                      versions: true
                  )
            else {
                throw ManualSaveDocumentHostPolicyError.unsupportedHost
            }
            try installManualSaveFlags(on: documentClass)
            try installDisposableDraftClosePolicy(on: documentClass)
            guard hasManualSaveFlags(documentClass),
                  hasDisposableDraftClosePolicy(documentClass)
            else {
                throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
            }
            processState = .configured(classID)
        } catch {
            processState = .failed
            throw error
        }
    }

    /// Isolated test seam for validating the runtime override without mutating
    /// the process-wide production state or depending on a private SwiftUI type.
    static func applyForTesting(to document: NSDocument) throws {
        let documentClass: NSDocument.Type = type(of: document)
        if hasManualSaveFlags(documentClass),
           hasDisposableDraftClosePolicy(documentClass)
        {
            return
        }
        guard ObjectIdentifier(documentClass) != ObjectIdentifier(NSDocument.self),
              automaticSaveFlagsMatch(
                  runtimeAutomaticSaveFlags(documentClass),
                  inPlace: true,
                  drafts: true,
                  versions: true
              )
        else {
            throw ManualSaveDocumentHostPolicyError.unsupportedHost
        }
        try installManualSaveFlags(on: documentClass)
        try installDisposableDraftClosePolicy(on: documentClass)
        guard hasManualSaveFlags(documentClass),
              hasDisposableDraftClosePolicy(documentClass)
        else {
            throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
        }
    }

    static func hasDisposableDraftClosePolicy(
        _ documentClass: NSDocument.Type
    ) -> Bool {
        guard let hostMethod = class_getInstanceMethod(
                  documentClass,
                  #selector(NSDocument.canClose(withDelegate:shouldClose:contextInfo:))
              ),
              let baseMethod = class_getInstanceMethod(
                  NSDocument.self,
                  #selector(NSDocument.canClose(withDelegate:shouldClose:contextInfo:))
              )
        else {
            return false
        }
        return method_getImplementation(hostMethod) != method_getImplementation(baseMethod)
    }

    private static func installManualSaveFlags(on documentClass: NSDocument.Type) throws {
        // Preserve AppKit's valid policy combinations throughout installation:
        // version preservation must be disabled before in-place autosaving.
        let selectors = [
            #selector(getter: NSDocument.preservesVersions),
            #selector(getter: NSDocument.autosavesDrafts),
            #selector(getter: NSDocument.autosavesInPlace),
        ]
        for selector in selectors {
            try installDisabledClassFlag(selector, on: documentClass)
            guard runtimeBooleanClassProperty(selector, on: documentClass) == false else {
                throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
            }
        }
    }

    private static func installDisposableDraftClosePolicy(
        on documentClass: NSDocument.Type
    ) throws {
        let selector = #selector(
            NSDocument.canClose(withDelegate:shouldClose:contextInfo:)
        )
        guard let targetMethod = class_getInstanceMethod(documentClass, selector),
              let typeEncoding = method_getTypeEncoding(targetMethod)
        else {
            throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
        }

        let closeWithoutReview: @convention(block) (
            NSDocument,
            AnyObject,
            Selector?,
            UnsafeMutableRawPointer?
        ) -> Void = { document, delegate, callbackSelector, contextInfo in
            let approved = TemporaryDocumentDrafts.approveClose(owner: document)
            if approved { document.updateChangeCount(.changeCleared) }
            guard let callbackSelector,
                  let callbackMethod = class_getInstanceMethod(
                      type(of: delegate),
                      callbackSelector
                  )
            else {
                return
            }
            typealias Callback = @convention(c) (
                AnyObject,
                Selector,
                NSDocument,
                Bool,
                UnsafeMutableRawPointer?
            ) -> Void
            let callback = unsafeBitCast(
                method_getImplementation(callbackMethod),
                to: Callback.self
            )
            callback(delegate, callbackSelector, document, approved, contextInfo)
        }
        let implementation = imp_implementationWithBlock(closeWithoutReview)
        guard class_addMethod(documentClass, selector, implementation, typeEncoding) else {
            imp_removeBlock(implementation)
            if !hasDisposableDraftClosePolicy(documentClass) {
                throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
            }
            return
        }
    }

    static func hasManualSaveFlags(_ documentClass: NSDocument.Type) -> Bool {
        automaticSaveFlagsMatch(
            runtimeAutomaticSaveFlags(documentClass),
            inPlace: false,
            drafts: false,
            versions: false
        )
            && !documentClass.autosavesInPlace
            && !documentClass.autosavesDrafts
            && !documentClass.preservesVersions
    }

    static func runtimeAutomaticSaveFlags(
        _ documentClass: NSDocument.Type
    ) -> (inPlace: Bool, drafts: Bool, versions: Bool)? {
        guard let inPlace = runtimeBooleanClassProperty(
                  #selector(getter: NSDocument.autosavesInPlace),
                  on: documentClass
              ),
              let drafts = runtimeBooleanClassProperty(
                  #selector(getter: NSDocument.autosavesDrafts),
                  on: documentClass
              ),
              let versions = runtimeBooleanClassProperty(
                  #selector(getter: NSDocument.preservesVersions),
                  on: documentClass
              )
        else {
            return nil
        }
        return (inPlace, drafts, versions)
    }

    private static func automaticSaveFlagsMatch(
        _ flags: (inPlace: Bool, drafts: Bool, versions: Bool)?,
        inPlace: Bool,
        drafts: Bool,
        versions: Bool
    ) -> Bool {
        guard let flags else { return false }
        return flags.inPlace == inPlace
            && flags.drafts == drafts
            && flags.versions == versions
    }

    private static func inheritsDefaultCloseAndSaveLifecycle(
        _ documentClass: NSDocument.Type
    ) -> Bool {
        let selectors = [
            #selector(NSDocument.canClose(withDelegate:shouldClose:contextInfo:)),
            #selector(NSDocument.save(withDelegate:didSave:contextInfo:)),
            #selector(
                NSDocument.autosave(
                    withImplicitCancellability:completionHandler:
                )
            ),
        ]
        return selectors.allSatisfy { selector in
            guard let hostMethod = class_getInstanceMethod(documentClass, selector),
                  let baseMethod = class_getInstanceMethod(NSDocument.self, selector)
            else {
                return false
            }
            return method_getImplementation(hostMethod) == method_getImplementation(baseMethod)
        }
    }

    private static func concreteMetaclassDefinesAutomaticSavePolicy(
        _ documentClass: NSDocument.Type
    ) -> Bool {
        guard let metaclass = object_getClass(documentClass) else { return true }
        let selectors: Set<Selector> = [
            #selector(getter: NSDocument.preservesVersions),
            #selector(getter: NSDocument.autosavesDrafts),
            #selector(getter: NSDocument.autosavesInPlace),
        ]
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(metaclass, &count) else {
            return false
        }
        defer { free(methods) }
        return (0 ..< Int(count)).contains { index in
            selectors.contains(method_getName(methods[index]))
        }
    }

    private static func installDisabledClassFlag(
        _ selector: Selector,
        on documentClass: NSDocument.Type
    ) throws {
        guard let metaclass = object_getClass(documentClass),
              let targetMethod = class_getClassMethod(documentClass, selector),
              let typeEncoding = method_getTypeEncoding(targetMethod)
        else {
            throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
        }

        let disabled: @convention(block) (AnyObject) -> Bool = { _ in false }
        let implementation = imp_implementationWithBlock(disabled)
        guard class_addMethod(metaclass, selector, implementation, typeEncoding) else {
            imp_removeBlock(implementation)
            throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
        }
    }

    private static func runtimeBooleanClassProperty(
        _ selector: Selector,
        on documentClass: NSDocument.Type
    ) -> Bool? {
        guard let method = class_getClassMethod(documentClass, selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Bool
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(documentClass, selector)
    }
}

struct MarkdownDocument: FileDocument, Sendable {
    static let readableContentTypes: [UTType] = [.inflowMarkdown]
    static let writableContentTypes: [UTType] = [.inflowMarkdown]

    var text: String {
        didSet {
            capabilityTier = MarkdownDocumentSizePolicy.tier(for: text.utf8.count)
        }
    }
    var properties: MarkdownFileProperties
    private(set) var capabilityTier: MarkdownDocumentCapabilityTier
    var restorationState: MarkdownRestorationState?
    var recoveryTransfer: DocumentRecoveryTransfer?
    var recoveryPlaceholder: RecoveryDraftPlaceholder?
    var initialHeadingFragment: String?
    var openedFileData: Data?
    let writeGuard: MarkdownWriteGuard

    init(
        text: String = "",
        properties: MarkdownFileProperties = .newDocument,
        restorationState: MarkdownRestorationState? = nil,
        recoveryTransfer: DocumentRecoveryTransfer? = nil,
        recoveryPlaceholder: RecoveryDraftPlaceholder? = nil,
        initialHeadingFragment: String? = nil,
        openedFileData: Data? = nil,
        writeGuard: MarkdownWriteGuard = MarkdownWriteGuard()
    ) {
        self.text = text
        self.properties = properties
        capabilityTier = MarkdownDocumentSizePolicy.tier(for: text.utf8.count)
        self.restorationState = restorationState
        self.recoveryTransfer = recoveryTransfer
        self.recoveryPlaceholder = recoveryPlaceholder
        self.initialHeadingFragment = initialHeadingFragment
        self.openedFileData = openedFileData
        self.writeGuard = writeGuard
    }

    init(fileData: Data) throws {
        let tier = try MarkdownDocumentSizePolicy.validatedTierForOpening(
            byteCount: fileData.count
        )
        let decoded = try PerformanceTrace.measure("file.decode", bytes: fileData.count) {
            try MarkdownCodec.decode(fileData)
        }
        text = decoded.text
        properties = decoded.properties
        capabilityTier = tier
        restorationState = nil
        recoveryTransfer = nil
        recoveryPlaceholder = nil
        initialHeadingFragment = nil
        openedFileData = fileData
        writeGuard = MarkdownWriteGuard()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(fileData: data)
    }

    func encodedFileData() throws -> Data {
        guard recoveryPlaceholder == nil else { throw RecoveryPlaceholderSaveError.notLoaded }
        return try MarkdownCodec.encode(text, properties: properties)
    }

    mutating func chooseLineEnding(_ lineEnding: MarkdownLineEnding) {
        properties.lineEnding = lineEnding
        properties.requiresLineEndingChoice = false
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try fileWrapper(existingFile: configuration.existingFile)
    }

    /// Shared by the `FileDocument` conformance and lifecycle regression tests so
    /// tests exercise the exact wrapper-construction path AppKit invokes.
    func fileWrapper(existingFile: FileWrapper?) throws -> FileWrapper {
        let currentData = try encodedFileData()
        let data = try writeGuard.fileDocumentSerializationData(fallback: currentData)
        try writeGuard.authorize(
            existingFile: existingFile,
            proposedData: data
        )
        return FileWrapper(regularFileWithContents: data)
    }
}

enum RecoveryPlaceholderSaveError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "草稿尚未载入，请等待内容显示后再保存。" }
}

enum MarkdownDocumentModificationProjection {
    /// A single byte-level definition feeds AppKit, project tabs and the folder
    /// tree. `NSTextView.string` and individual views never invent dirty state.
    static func isModified(_ document: MarkdownDocument) -> Bool {
        guard document.recoveryPlaceholder == nil else { return false }
        guard let current = try? document.encodedFileData() else { return true }
        return current != (document.openedFileData ?? Data())
    }
}

/// A last synchronous checkpoint before AppKit is allowed to close a document.
/// These files are drafts; they never replace the user's original Markdown file.
struct TemporaryDocumentDraftStore: Sendable {
    let rootURL: URL

    static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Inflow/SessionDrafts", isDirectory: true)
    }

    func write(_ record: DocumentRecoveryRecord) throws {
        try record.validate()
        let manager = FileManager.default
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let url = rootURL.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func records() throws -> [DocumentRecoveryRecord] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                let record = try JSONDecoder().decode(DocumentRecoveryRecord.self, from: Data(contentsOf: $0))
                try record.validate()
                return record
            }
    }

    func remove(_ id: UUID) throws {
        let url = rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// A one-time explanation at the first close of unsaved content. A cancelled
/// close does not acknowledge it; successful draft protection happens first.
@MainActor
final class DraftCloseDisclosure {
    private let defaults: UserDefaults
    private let present: () -> Bool
    private let acknowledgementKey = "hasAcknowledgedDraftOnlyClose"
    private var isPresenting = false

    init(defaults: UserDefaults = .standard, present: @escaping () -> Bool = {
        makeAlert().runModal() == .alertFirstButtonReturn
    }) {
        self.defaults = defaults
        self.present = present
    }

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "关闭文档不会保存到原文件"
        alert.informativeText = "未保存内容已保留为本机草稿，可在下次启动 Inflow 时恢复。要更新 Markdown 文件，请返回编辑后按 ⌘S。此说明确认后不再显示。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保留草稿并关闭")
        alert.addButton(withTitle: "返回编辑")
        _ = alert.window
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert
    }

    func approve(hasUnsavedContent: Bool) -> Bool {
        guard hasUnsavedContent, !defaults.bool(forKey: acknowledgementKey) else { return true }
        guard !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        guard present() else { return false }
        defaults.set(true, forKey: acknowledgementKey)
        return true
    }
}

@MainActor
enum TemporaryDocumentDrafts {
    private struct Provider {
        let owners: Set<ObjectIdentifier>
        let snapshot: () -> DocumentRecoveryRecord
        let isModified: () -> Bool
    }
    private static var providers: [UUID: Provider] = [:]
    private static var installed = false
    private(set) static var isTerminating = false
    private static var writtenSnapshots: [UUID: DocumentRecoveryRecord] = [:]
    static var store = TemporaryDocumentDraftStore(rootURL: TemporaryDocumentDraftStore.defaultRoot)
    static var closeDisclosure = DraftCloseDisclosure()

    static func register(_ id: UUID, owner: NSDocument?, windowOwner: NSDocument? = nil, isModified: @escaping () -> Bool, snapshot: @escaping () -> DocumentRecoveryRecord) {
        providers[id] = Provider(owners: Set([owner, windowOwner].compactMap { $0.map(ObjectIdentifier.init) }), snapshot: snapshot, isModified: isModified)
    }

    static func unregister(_ id: UUID) {
        providers.removeValue(forKey: id)
        writtenSnapshots.removeValue(forKey: id)
    }

    static func checkpoint(owner: NSDocument? = nil) throws {
        _ = try checkpointWithModificationState(owner: owner)
    }

    private static func checkpointWithModificationState(owner: NSDocument?) throws -> Bool {
        var hasUnsavedContent = false
        for provider in Array(providers.values) where owner == nil || owner.map({ provider.owners.contains(ObjectIdentifier($0)) }) == true {
            let record = provider.snapshot()
            if record.originalURL == nil && record.text.isEmpty {
                try store.remove(record.id)
                writtenSnapshots.removeValue(forKey: record.id)
                continue
            }
            hasUnsavedContent = provider.isModified() || hasUnsavedContent
            if let previous = writtenSnapshots[record.id], record.hasSameSnapshot(as: previous),
               FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent(record.id.uuidString + ".json").path) {
                continue
            }
            try store.write(record)
            writtenSnapshots[record.id] = record
        }
        return hasUnsavedContent
    }

    static func approveClose(owner: NSDocument? = nil) -> Bool {
        do {
            let hasUnsavedContent = try checkpointWithModificationState(owner: owner)
            let approved = closeDisclosure.approve(hasUnsavedContent: hasUnsavedContent)
            if !approved { cancelTermination() }
            return approved
        }
        catch {
            cancelTermination()
            NSApp.presentError(NSError(domain: "Inflow.DraftCheckpoint", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未能暂存未保存内容，已取消关闭或退出以保留编辑。", NSUnderlyingErrorKey: error]))
            return false
        }
    }

    static func approveTermination() -> Bool {
        isTerminating = approveClose()
        return isTerminating
    }

    static func cancelTermination() { isTerminating = false }

    /// AppKit's multi-document Quit review runs before individual canClose callbacks.
    static func installQuitReview() {
        guard !installed else { return }
        let controllerClass: AnyClass = type(of: NSDocumentController.shared)
        let selector = #selector(NSDocumentController.reviewUnsavedDocuments(withAlertTitle:cancellable:delegate:didReviewAllSelector:contextInfo:))
        guard let method = class_getInstanceMethod(controllerClass, selector), let encoding = method_getTypeEncoding(method) else { return }
        let review: @convention(block) (NSDocumentController, NSString?, Bool, AnyObject?, Selector?, UnsafeMutableRawPointer?) -> Void = {
            controller, _, _, delegate, callbackSelector, context in
            let approved = approveTermination()
            guard let delegate, let callbackSelector,
                  let callbackMethod = class_getInstanceMethod(type(of: delegate), callbackSelector) else { return }
            typealias Callback = @convention(c) (AnyObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?) -> Void
            let callback = unsafeBitCast(method_getImplementation(callbackMethod), to: Callback.self)
            callback(delegate, callbackSelector, controller, approved, context)
        }
        class_replaceMethod(controllerClass, selector, imp_implementationWithBlock(review), encoding)
        installed = true
    }
}
