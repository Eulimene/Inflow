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

/// Applies the personal milestone's manual-save contract to the concrete
/// `NSDocument` class created by SwiftUI's `DocumentGroup`.
///
/// `FileDocument` does not expose these AppKit class policies. Merely setting
/// `NSDocumentController.autosavingDelay` to zero disables periodic autosaves,
/// but AppKit will still silently autosave a named, edited document while it is
/// closing when the host class opts into autosaving in place. The personal
/// build therefore installs false implementations for the three *public*
/// `NSDocument` class selectors on the concrete host class before editing is
/// enabled. AppKit's standard Save / Don't Save / Cancel review then owns close
/// and termination, while explicit Save continues through Inflow's guarded
/// native save path.
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

    static func apply(to document: NSDocument) throws {
        let documentClass: NSDocument.Type = type(of: document)
        let classID = ObjectIdentifier(documentClass)

        switch processState {
        case .failed:
            throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
        case let .configured(configuredID):
            guard configuredID == classID, hasManualSaveFlags(documentClass) else {
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
            guard hasManualSaveFlags(documentClass) else {
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
        if hasManualSaveFlags(documentClass) {
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
        guard hasManualSaveFlags(documentClass) else {
            throw ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
        }
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

struct MarkdownDocument: FileDocument {
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
    var initialHeadingFragment: String?
    var openedFileData: Data?
    let writeGuard: MarkdownWriteGuard

    init(
        text: String = "",
        properties: MarkdownFileProperties = .newDocument,
        restorationState: MarkdownRestorationState? = nil,
        recoveryTransfer: DocumentRecoveryTransfer? = nil,
        initialHeadingFragment: String? = nil,
        openedFileData: Data? = nil,
        writeGuard: MarkdownWriteGuard = MarkdownWriteGuard()
    ) {
        self.text = text
        self.properties = properties
        capabilityTier = MarkdownDocumentSizePolicy.tier(for: text.utf8.count)
        self.restorationState = restorationState
        self.recoveryTransfer = recoveryTransfer
        self.initialHeadingFragment = initialHeadingFragment
        self.openedFileData = openedFileData
        self.writeGuard = writeGuard
    }

    init(fileData: Data) throws {
        let tier = try MarkdownDocumentSizePolicy.validatedTierForOpening(
            byteCount: fileData.count
        )
        let decoded = try MarkdownCodec.decode(fileData)
        text = decoded.text
        properties = decoded.properties
        capabilityTier = tier
        restorationState = nil
        recoveryTransfer = nil
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
        try MarkdownCodec.encode(text, properties: properties)
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
