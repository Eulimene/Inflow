import CryptoKit
import Darwin
import Foundation
import Security
import SwiftUI

struct MarkdownRestorationState: Equatable, Sendable {
    let selectedUTF16Location: Int
    let selectedUTF16Length: Int
    let viewModeRawValue: String
    let verticalScrollOffset: Double
}

struct DocumentRecoveryTransfer: Equatable, Sendable {
    let sourceRecordID: UUID
    let targetRecordID: UUID
    let lineageID: UUID
    let sourceEpoch: UInt64
    let targetEpoch: UInt64
    let committedContentHash: Data?
}

extension MarkdownDocument {
    mutating func adoptRecoveryCommittedSave(_ envelope: SaveEnvelope) {
        guard envelope.hasValidHash,
              envelope.operation == .automatic
                || envelope.operation == .save
                || envelope.operation == .saveAs
        else {
            return
        }
        openedFileData = envelope.bytes
    }
}

enum DocumentRecoveryDiskRelationship: Equatable, Sendable {
    case sameAsRecovery
    case sameAsCommittedBase
    case divergedOrUnknown
}

struct DocumentRecoveryRecord: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    let lineageID: UUID?
    let epoch: UInt64?
    let revision: UInt64?
    let contentHash: Data?
    let committedContentHash: Data?
    let transferSourceRecordID: UUID?
    let transferTargetRecordID: UUID?
    let claimedAt: Date?
    let text: String
    let originalURL: URL?
    let originalBookmark: Data?
    let hasUTF8BOM: Bool
    let lineEndingRawValue: UInt8
    let requiresLineEndingChoice: Bool
    let selectedUTF16Location: Int
    let selectedUTF16Length: Int
    let viewModeRawValue: String
    let verticalScrollOffset: Double
    let updatedAt: Date

    init(
        id: UUID,
        document: MarkdownDocument,
        originalURL: URL?,
        selectedUTF16Range: NSRange,
        viewMode: EditorViewMode,
        verticalScrollOffset: Double,
        updatedAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        if let transfer = document.recoveryTransfer {
            lineageID = transfer.lineageID
            epoch = transfer.targetEpoch
            transferSourceRecordID = transfer.sourceRecordID
            committedContentHash = transfer.committedContentHash
        } else {
            lineageID = id
            epoch = 1
            transferSourceRecordID = nil
            committedContentHash = document.openedFileData.map(Self.hash)
        }
        revision = 1
        text = document.text
        contentHash = Self.hash(
            (try? document.encodedFileData()) ?? Data(document.text.utf8)
        )
        transferTargetRecordID = nil
        claimedAt = nil
        self.originalURL = originalURL
        originalBookmark = try? originalURL?.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        hasUTF8BOM = document.properties.hasUTF8BOM
        lineEndingRawValue = document.properties.lineEnding.rawValue
        requiresLineEndingChoice = document.properties.requiresLineEndingChoice
        selectedUTF16Location = selectedUTF16Range.location
        selectedUTF16Length = selectedUTF16Range.length
        viewModeRawValue = viewMode.rawValue
        self.verticalScrollOffset = verticalScrollOffset
        self.updatedAt = updatedAt
    }

    var displayName: String {
        originalURL?.lastPathComponent ?? "未命名文档"
    }

    func restoredDocument(transfer suppliedTransfer: DocumentRecoveryTransfer? = nil) throws
        -> MarkdownDocument
    {
        try validate()
        guard let lineEnding = MarkdownLineEnding(rawValue: lineEndingRawValue) else {
            throw DocumentRecoveryError.invalidRecord
        }
        let transfer = suppliedTransfer ?? DocumentRecoveryTransfer(
            sourceRecordID: id,
            targetRecordID: UUID(),
            lineageID: effectiveLineageID,
            sourceEpoch: effectiveEpoch,
            targetEpoch: effectiveEpoch &+ 1,
            committedContentHash: committedContentHash
        )
        return MarkdownDocument(
            text: text,
            properties: MarkdownFileProperties(
                hasUTF8BOM: hasUTF8BOM,
                lineEnding: lineEnding,
                requiresLineEndingChoice: requiresLineEndingChoice
            ),
            restorationState: MarkdownRestorationState(
                selectedUTF16Location: selectedUTF16Location,
                selectedUTF16Length: selectedUTF16Length,
                viewModeRawValue: viewModeRawValue,
                verticalScrollOffset: verticalScrollOffset
            ),
            recoveryTransfer: transfer
        )
    }

    func validate() throws {
        guard (1 ... Self.currentSchemaVersion).contains(schemaVersion),
              MarkdownLineEnding(rawValue: lineEndingRawValue) != nil,
              EditorViewMode(rawValue: viewModeRawValue) != nil,
              selectedUTF16Location >= 0,
              selectedUTF16Length >= 0,
              selectedUTF16Location <= text.utf16.count,
              selectedUTF16Length <= text.utf16.count - selectedUTF16Location,
              verticalScrollOffset.isFinite,
              verticalScrollOffset >= 0,
              originalURL == nil || originalURL?.isFileURL == true
        else {
            throw DocumentRecoveryError.invalidRecord
        }
        if schemaVersion == Self.currentSchemaVersion {
            guard let lineageID,
                  let epoch, epoch > 0,
                  let revision, revision > 0,
                  let contentHash,
                  contentHash.count == SHA256.byteCount,
                  contentHash == Self.hash(encodedDocumentData),
                  committedContentHash == nil
                    || committedContentHash?.count == SHA256.byteCount,
                  transferTargetRecordID == nil || claimedAt != nil,
                  lineageID != UUID.zero
            else {
                throw DocumentRecoveryError.invalidRecord
            }
        }
    }

    var effectiveLineageID: UUID { lineageID ?? id }
    var effectiveEpoch: UInt64 { epoch ?? 1 }
    var effectiveRevision: UInt64 { revision ?? 1 }
    var recoveryContentIdentity: Data { contentHash ?? Self.hash(encodedDocumentData) }

    func relationship(toDiskData data: Data) -> DocumentRecoveryDiskRelationship {
        let diskHash = Self.hash(data)
        if diskHash == contentHash {
            return .sameAsRecovery
        }
        if let committedContentHash, diskHash == committedContentHash {
            return .sameAsCommittedBase
        }
        return .divergedOrUnknown
    }

    func migrated() -> Self {
        guard schemaVersion != Self.currentSchemaVersion
                || lineageID == nil
                || epoch == nil
                || revision == nil
                || contentHash == nil
        else {
            return self
        }
        return replacing(
            revision: effectiveRevision,
            transferTargetRecordID: transferTargetRecordID,
            claimedAt: claimedAt,
            updatedAt: updatedAt
        )
    }

    func nextRevision(after previous: Self?) -> Self {
        let next = max(effectiveRevision, previous?.effectiveRevision ?? 0) &+ 1
        return replacing(
            revision: next,
            transferTargetRecordID: transferTargetRecordID,
            claimedAt: claimedAt,
            updatedAt: updatedAt
        )
    }

    func claimed(by targetRecordID: UUID, at date: Date) -> Self {
        replacing(
            revision: effectiveRevision &+ 1,
            transferTargetRecordID: targetRecordID,
            claimedAt: date,
            updatedAt: date
        )
    }

    private func replacing(
        revision: UInt64,
        transferTargetRecordID: UUID?,
        claimedAt: Date?,
        updatedAt: Date
    ) -> Self {
        Self(
            schemaVersion: Self.currentSchemaVersion,
            id: id,
            lineageID: effectiveLineageID,
            epoch: effectiveEpoch,
            revision: revision,
            contentHash: Self.hash(encodedDocumentData),
            committedContentHash: committedContentHash,
            transferSourceRecordID: transferSourceRecordID,
            transferTargetRecordID: transferTargetRecordID,
            claimedAt: claimedAt,
            text: text,
            originalURL: originalURL,
            originalBookmark: originalBookmark,
            hasUTF8BOM: hasUTF8BOM,
            lineEndingRawValue: lineEndingRawValue,
            requiresLineEndingChoice: requiresLineEndingChoice,
            selectedUTF16Location: selectedUTF16Location,
            selectedUTF16Length: selectedUTF16Length,
            viewModeRawValue: viewModeRawValue,
            verticalScrollOffset: verticalScrollOffset,
            updatedAt: updatedAt
        )
    }

    private init(
        schemaVersion: Int,
        id: UUID,
        lineageID: UUID?,
        epoch: UInt64?,
        revision: UInt64?,
        contentHash: Data?,
        committedContentHash: Data?,
        transferSourceRecordID: UUID?,
        transferTargetRecordID: UUID?,
        claimedAt: Date?,
        text: String,
        originalURL: URL?,
        originalBookmark: Data?,
        hasUTF8BOM: Bool,
        lineEndingRawValue: UInt8,
        requiresLineEndingChoice: Bool,
        selectedUTF16Location: Int,
        selectedUTF16Length: Int,
        viewModeRawValue: String,
        verticalScrollOffset: Double,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.lineageID = lineageID
        self.epoch = epoch
        self.revision = revision
        self.contentHash = contentHash
        self.committedContentHash = committedContentHash
        self.transferSourceRecordID = transferSourceRecordID
        self.transferTargetRecordID = transferTargetRecordID
        self.claimedAt = claimedAt
        self.text = text
        self.originalURL = originalURL
        self.originalBookmark = originalBookmark
        self.hasUTF8BOM = hasUTF8BOM
        self.lineEndingRawValue = lineEndingRawValue
        self.requiresLineEndingChoice = requiresLineEndingChoice
        self.selectedUTF16Location = selectedUTF16Location
        self.selectedUTF16Length = selectedUTF16Length
        self.viewModeRawValue = viewModeRawValue
        self.verticalScrollOffset = verticalScrollOffset
        self.updatedAt = updatedAt
    }

    private var encodedDocumentData: Data {
        guard let lineEnding = MarkdownLineEnding(rawValue: lineEndingRawValue),
              let data = try? MarkdownCodec.encode(
                  text,
                  properties: MarkdownFileProperties(
                      hasUTF8BOM: hasUTF8BOM,
                      lineEnding: lineEnding,
                      requiresLineEndingChoice: requiresLineEndingChoice
                  )
              )
        else {
            return Data(text.utf8)
        }
        return data
    }

    private static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

enum DocumentRecoveryFileAccess {
    static func withResolvedURL<Result>(
        for record: DocumentRecoveryRecord,
        _ body: (URL) throws -> Result
    ) throws -> Result? {
        guard record.originalURL != nil else { return nil }

        let url: URL
        if let bookmark = record.originalBookmark {
            var isStale = false
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } else if let originalURL = record.originalURL {
            url = originalURL
        } else {
            return nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }
}

enum DocumentRecoveryError: Error, Equatable, LocalizedError, Sendable {
    case unavailableStorage
    case unavailableKey
    case invalidRecord
    case quotaExceeded
    case staleClaim
    case cannotWrite
    case cannotRemove

    var errorDescription: String? {
        switch self {
        case .unavailableStorage:
            "恢复保护目录暂时不可用。"
        case .unavailableKey:
            "恢复保护密钥暂时不可用。"
        case .invalidRecord:
            "恢复内容的结构无法验证。"
        case .quotaExceeded:
            "恢复保护已达本机容量上限；不会删除其他文档的唯一恢复副本。"
        case .staleClaim:
            "恢复交接状态已改变，旧恢复项仍保留。"
        case .cannotWrite:
            "无法更新恢复保护内容。"
        case .cannotRemove:
            "无法完成恢复内容的处置。"
        }
    }
}

enum DocumentRecoveryReconcileOutcome: Equatable, Sendable {
    case stored
    case removedBecauseSaved
    case removedBecauseEmpty
}

struct DocumentRecoveryLoadResult: Equatable, Sendable {
    let records: [DocumentRecoveryRecord]
    let quarantinedRecordCount: Int
}

protocol DocumentRecoveryKeyProviding: Sendable {
    func loadKey() throws -> SymmetricKey?
    func createKey() throws -> SymmetricKey
    func removeKey() throws
}

final class KeychainDocumentRecoveryKeyProvider: DocumentRecoveryKeyProviding,
    @unchecked Sendable
{
    private let service = "com.inflow.desktop.recovery"
    private let account = "recovery-envelope-v1"

    func loadKey() throws -> SymmetricKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw DocumentRecoveryError.unavailableKey
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw DocumentRecoveryError.unavailableKey
        }
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem, let existing = try loadKey() {
                return existing
            }
            throw DocumentRecoveryError.unavailableKey
        }
        return key
    }

    func removeKey() throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DocumentRecoveryError.unavailableKey
        }
    }
}

final class FixedDocumentRecoveryKeyProvider: DocumentRecoveryKeyProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var key: SymmetricKey?

    init(keyData: Data = Data(repeating: 0xA5, count: 32)) {
        key = SymmetricKey(data: keyData)
    }

    func loadKey() throws -> SymmetricKey? {
        lock.withLock { key }
    }

    func createKey() throws -> SymmetricKey {
        lock.withLock {
            if let key { return key }
            let created = SymmetricKey(size: .bits256)
            key = created
            return created
        }
    }

    func removeKey() throws {
        lock.withLock { key = nil }
    }
}

private struct EncryptedRecoveryEnvelope: Codable {
    static let formatVersion = 1

    let formatVersion: Int
    let recordID: UUID
    let plaintextLength: Int
    let keyIdentifier: Data
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    var authenticatedHeader: Data {
        Data("INFLOW-RECOVERY\u{0}\(formatVersion)\u{0}\(recordID.uuidString)\u{0}\(plaintextLength)"
            .utf8) + keyIdentifier
    }
}

private enum DurableRecoveryWriter {
    static func replace(_ data: Data, at targetURL: URL) throws {
        let directory = targetURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".recovery-\(UUID().uuidString).tmp"
        )
        let descriptor: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw DocumentRecoveryError.cannotWrite }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        var writeFailed = false
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count <= 0 {
                    if errno == EINTR { continue }
                    writeFailed = true
                    return
                }
                offset += count
            }
        }
        guard !writeFailed, fsync(descriptor) == 0 else {
            throw DocumentRecoveryError.cannotWrite
        }
        let renameStatus = temporaryURL.withUnsafeFileSystemRepresentation { source in
            targetURL.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return rename(source, target)
            }
        }
        guard renameStatus == 0 else { throw DocumentRecoveryError.cannotWrite }
        shouldRemoveTemporary = false
        try synchronizeDirectory(directory)
    }

    @discardableResult
    static func removeIfPresent(at targetURL: URL) throws -> Bool {
        errno = 0
        let status = targetURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return unlink(path)
        }
        if status != 0 {
            if errno == ENOENT { return false }
            throw DocumentRecoveryError.cannotRemove
        }
        try synchronizeDirectory(targetURL.deletingLastPathComponent())
        return true
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let directoryDescriptor = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else { throw DocumentRecoveryError.cannotWrite }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw DocumentRecoveryError.cannotWrite
        }
    }
}

#if DEBUG
/// Xcode's default local build is ad-hoc signed, so its designated requirement
/// changes whenever the executable is rebuilt. Giving that changing identity
/// access to the production recovery item makes Keychain ask for the login
/// password on nearly every developer run. Debug recovery therefore uses its
/// own random, mode-0600 file key inside its isolated recovery directory.
final class DevelopmentDocumentRecoveryKeyProvider: DocumentRecoveryKeyProviding,
    @unchecked Sendable
{
    private let keyURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(keyURL: URL, fileManager: FileManager = .default) {
        self.keyURL = keyURL
        self.fileManager = fileManager
    }

    func loadKey() throws -> SymmetricKey? {
        try lock.withLock { try loadKeyWithoutLock() }
    }

    func createKey() throws -> SymmetricKey {
        try lock.withLock {
            if let existing = try loadKeyWithoutLock() { return existing }
            do {
                try fileManager.createDirectory(
                    at: keyURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let key = SymmetricKey(size: .bits256)
                let bytes = key.withUnsafeBytes { Data($0) }
                try DurableRecoveryWriter.replace(bytes, at: keyURL)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: keyURL.path
                )
                return key
            } catch {
                throw DocumentRecoveryError.unavailableKey
            }
        }
    }

    func removeKey() throws {
        try lock.withLock {
            do {
                _ = try DurableRecoveryWriter.removeIfPresent(at: keyURL)
            } catch {
                throw DocumentRecoveryError.unavailableKey
            }
        }
    }

    private func loadKeyWithoutLock() throws -> SymmetricKey? {
        var metadata = stat()
        errno = 0
        let descriptor = keyURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw DocumentRecoveryError.unavailableKey
        }
        defer { close(descriptor) }
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size == 32
        else {
            throw DocumentRecoveryError.unavailableKey
        }
        var bytes = Data(count: 32)
        let didReadAll = bytes.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count <= 0 {
                    if count < 0, errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard didReadAll else { throw DocumentRecoveryError.unavailableKey }
        return SymmetricKey(data: bytes)
    }
}
#endif

enum DocumentRecoveryRuntimeProfile: Equatable {
    case production
    case development
    case automatedTest
}

enum DocumentRecoveryRuntime {
    static func profile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = _isDebugAssertConfiguration()
    ) -> DocumentRecoveryRuntimeProfile {
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        {
            return .automatedTest
        }
        return isDebugBuild ? .development : .production
    }

    @MainActor
    static func makeCoordinator(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> DocumentRecoveryCoordinator {
        switch profile(environment: environment) {
        case .production:
            return DocumentRecoveryCoordinator(fileManager: fileManager)
        case .automatedTest:
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("InflowTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("Recovery", isDirectory: true)
            return DocumentRecoveryCoordinator(
                rootURL: root,
                fileManager: fileManager,
                keyProvider: FixedDocumentRecoveryKeyProvider()
            )
        case .development:
#if DEBUG
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            let root = base
                .appendingPathComponent("Inflow", isDirectory: true)
                .appendingPathComponent("DevelopmentRecovery", isDirectory: true)
            return DocumentRecoveryCoordinator(
                rootURL: root,
                fileManager: fileManager,
                keyProvider: DevelopmentDocumentRecoveryKeyProvider(
                    keyURL: root.appendingPathComponent(".development-recovery-key"),
                    fileManager: fileManager
                )
            )
#else
            return DocumentRecoveryCoordinator(fileManager: fileManager)
#endif
        }
    }
}

private struct ClosedRecoverySessionMarker: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let recordID: UUID
    let generation: UInt64
}

/// Serializes the only state transition that may retire a live recovery head.
/// A clean close writes a durable tombstone but deliberately leaves the encrypted
/// head in place. Reactivation durably removes the tombstone before it returns.
/// Startup cleanup can therefore never observe "head deleted, replacement pending".
private final class DocumentRecoverySessionGate: @unchecked Sendable {
    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var activeGenerations: [UUID: UInt64] = [:]

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func markActive(_ id: UUID, generation: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        try DurableRecoveryWriter.removeIfPresent(at: markerURL(id))
        activeGenerations[id] = generation
    }

    func markClosedIfCurrent(_ id: UUID, generation: UInt64) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGenerations[id] == generation else { return false }
        try ensureDirectory()
        let marker = ClosedRecoverySessionMarker(
            schemaVersion: ClosedRecoverySessionMarker.schemaVersion,
            recordID: id,
            generation: generation
        )
        let url = markerURL(id)
        try DurableRecoveryWriter.replace(try JSONEncoder.sorted.encode(marker), at: url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        activeGenerations.removeValue(forKey: id)
        return true
    }

    /// Deletes a cleanly closed head in two durable stages. The tombstone is
    /// removed only after the head unlink has reached the parent directory, so a
    /// crash between the stages simply retries the same convergence on next load.
    func consumeClosedHeadIfPresent(_ id: UUID, headURL: URL) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGenerations[id] == nil,
              let marker = try readMarker(id),
              marker.schemaVersion == ClosedRecoverySessionMarker.schemaVersion,
              marker.recordID == id,
              marker.generation > 0
        else {
            return false
        }
        try DurableRecoveryWriter.removeIfPresent(at: headURL)
        try DurableRecoveryWriter.removeIfPresent(at: markerURL(id))
        return true
    }

    func removeMarker(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try DurableRecoveryWriter.removeIfPresent(at: markerURL(id))
    }

    func reset() {
        lock.lock()
        activeGenerations.removeAll()
        lock.unlock()
    }

    private func readMarker(_ id: UUID) throws -> ClosedRecoverySessionMarker? {
        let url = markerURL(id)
        var metadata = stat()
        errno = 0
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw DocumentRecoveryError.cannotRemove
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= 4_096
        else {
            return nil
        }
        return try? JSONDecoder().decode(
            ClosedRecoverySessionMarker.self,
            from: Data(contentsOf: url)
        )
    }

    private func markerURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("closed")
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = rootURL
            try mutableRoot.setResourceValues(values)
        } catch {
            throw DocumentRecoveryError.unavailableStorage
        }
    }
}

actor DocumentRecoveryStore {
    enum Limits {
        static let recordBytes = 64 * 1_024 * 1_024
        // The encrypted envelope is JSON and its ciphertext is base64 encoded.
        // Keep this distinct from the plaintext JSON limit so a valid maximum
        // record is never misclassified as corrupt merely due to encoding overhead.
        static let encryptedRecordBytes = maximumEncryptedBytes(
            forPlaintextBytes: recordBytes
        )
        static let totalBytes = 512 * 1_024 * 1_024
        static let quarantineRetention: TimeInterval = 7 * 24 * 60 * 60

        static func maximumEncryptedBytes(forPlaintextBytes count: Int) -> Int {
            let base64Ciphertext = ((count + 2) / 3) * 4
            // Older JSONEncoder output may escape every `/` in a base64 string
            // as `\/`. Accept that strict worst case plus fixed envelope fields.
            // New writes use `.withoutEscapingSlashes`, but the reader must not
            // quarantine a valid maximum-sized record produced by an older build.
            return base64Ciphertext * 2 + 64 * 1_024
        }
    }

    nonisolated let rootURL: URL
    private let retentionInterval: TimeInterval
    private let quarantineRetentionInterval: TimeInterval
    private let totalByteLimit: Int
    private let fileManager: FileManager
    private let keyProvider: any DocumentRecoveryKeyProviding
    private nonisolated let sessionGate: DocumentRecoverySessionGate
    private let beforeReconcileCommit: (@Sendable (DocumentRecoveryRecord) async -> Void)?
    private let beforeTransferConsumption: (@Sendable (UUID, UUID) throws -> Void)?
    private let beforeLegacyQuarantineWrite: (@Sendable () throws -> Void)?

    init(
        rootURL: URL,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        quarantineRetentionInterval: TimeInterval = Limits.quarantineRetention,
        totalByteLimit: Int = Limits.totalBytes,
        keyProvider: (any DocumentRecoveryKeyProviding)? = nil,
        beforeReconcileCommit: (@Sendable (DocumentRecoveryRecord) async -> Void)? = nil,
        beforeTransferConsumption: (@Sendable (UUID, UUID) throws -> Void)? = nil,
        beforeLegacyQuarantineWrite: (@Sendable () throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.retentionInterval = retentionInterval
        self.quarantineRetentionInterval = quarantineRetentionInterval
        self.totalByteLimit = totalByteLimit
        fileManager = .default
        self.keyProvider = keyProvider ?? KeychainDocumentRecoveryKeyProvider()
        sessionGate = DocumentRecoverySessionGate(rootURL: rootURL)
        self.beforeReconcileCommit = beforeReconcileCommit
        self.beforeTransferConsumption = beforeTransferConsumption
        self.beforeLegacyQuarantineWrite = beforeLegacyQuarantineWrite
    }

    nonisolated func markSessionActive(_ id: UUID, generation: UInt64) throws {
        try sessionGate.markActive(id, generation: generation)
    }

    func markSessionClosed(_ id: UUID, generation: UInt64) throws -> Bool {
        try sessionGate.markClosedIfCurrent(id, generation: generation)
    }

    func reconcile(_ input: DocumentRecoveryRecord, now: Date = Date()) async throws
        -> DocumentRecoveryReconcileOutcome
    {
        let record = input.migrated()
        try record.validate()
        try ensureDirectory()
        let key = try availableKey()
        await beforeReconcileCommit?(record)

        if record.originalURL == nil, record.text.isEmpty {
            try removeIfPresent(record.id)
            return .removedBecauseEmpty
        }
        if try diskContainsExactDocument(record) {
            try removeIfPresent(record.id)
            if let source = record.transferSourceRecordID {
                try validateTransferSource(source, for: record)
                try removeIfPresent(source)
            }
            return .removedBecauseSaved
        }

        try write(record, using: key, now: now)
        if let source = record.transferSourceRecordID {
            try consumeTransferredSource(source, afterPersisting: record)
        }
        return .stored
    }

    func claim(
        _ input: DocumentRecoveryRecord,
        targetRecordID: UUID,
        now: Date = Date()
    ) throws -> DocumentRecoveryTransfer {
        try ensureDirectory()
        let key = try availableKey()
        let current = try readRecord(id: input.id, using: key).migrated()
        try current.validate()
        guard current.effectiveLineageID == input.effectiveLineageID,
              current.effectiveEpoch == input.effectiveEpoch,
              current.effectiveRevision == input.effectiveRevision
        else {
            throw DocumentRecoveryError.staleClaim
        }
        let claimed = current.claimed(by: targetRecordID, at: now)
        try write(claimed, using: key, now: now)
        return DocumentRecoveryTransfer(
            sourceRecordID: current.id,
            targetRecordID: targetRecordID,
            lineageID: current.effectiveLineageID,
            sourceEpoch: current.effectiveEpoch,
            targetEpoch: current.effectiveEpoch &+ 1,
            committedContentHash: current.committedContentHash
        )
    }

    func load(now: Date = Date()) throws -> DocumentRecoveryLoadResult {
        try ensureDirectory()
        try purgeOldQuarantine(now: now)
        try purgeClosedSessionHeads()
        var quarantined = 0
        let encryptedURLs = try contents().filter { $0.pathExtension == "recovery" }
        let key: SymmetricKey
        if let existing = try keyProvider.loadKey() {
            key = existing
        } else {
            for url in encryptedURLs {
                if quarantine(url, reason: "key-lost", now: now) { quarantined += 1 }
            }
            key = try keyProvider.createKey()
        }

        var records: [DocumentRecoveryRecord] = []
        for url in try contents() where url.pathExtension == "recovery" {
            do {
                let record = try decryptRecord(at: url, using: key).migrated()
                try record.validate()
                if now.timeIntervalSince(record.updatedAt) > retentionInterval {
                    try removeIfPresent(record.id)
                } else if try diskContainsExactDocument(record) {
                    try removeIfPresent(record.id)
                } else {
                    records.append(record)
                }
            } catch {
                if quarantine(url, reason: "corrupt", now: now) { quarantined += 1 }
            }
        }

        for legacyURL in try contents() where legacyURL.pathExtension == "json" {
            do {
                let legacy = try JSONDecoder().decode(
                    DocumentRecoveryRecord.self,
                    from: Data(contentsOf: legacyURL)
                ).migrated()
                try legacy.validate()
                if now.timeIntervalSince(legacy.updatedAt) <= retentionInterval,
                   try !diskContainsExactDocument(legacy)
                {
                    try write(legacy, using: key, now: now)
                    records.removeAll { $0.id == legacy.id }
                    records.append(legacy)
                }
                try fileManager.removeItem(at: legacyURL)
            } catch {
                if try quarantineLegacyPlaintext(
                    legacyURL,
                    reason: "legacy-corrupt",
                    using: key,
                    now: now
                ) {
                    quarantined += 1
                }
            }
        }

        records = reconcileDurableTransfers(in: records)
        records.sort { left, right in
            if left.updatedAt == right.updatedAt {
                return left.id.uuidString < right.id.uuidString
            }
            return left.updatedAt > right.updatedAt
        }
        return DocumentRecoveryLoadResult(
            records: records,
            quarantinedRecordCount: quarantined
        )
    }

    private func reconcileDurableTransfers(
        in records: [DocumentRecoveryRecord]
    ) -> [DocumentRecoveryRecord] {
        var recordsByID: [UUID: DocumentRecoveryRecord] = [:]
        for record in records {
            if let existing = recordsByID[record.id], isNewer(existing, than: record) {
                continue
            }
            recordsByID[record.id] = record
        }

        var consumedSourceIDs = Set<UUID>()
        for target in recordsByID.values {
            guard let sourceID = target.transferSourceRecordID,
                  let source = recordsByID[sourceID],
                  source.transferTargetRecordID == target.id,
                  source.effectiveLineageID == target.effectiveLineageID,
                  source.effectiveEpoch &+ 1 == target.effectiveEpoch
            else {
                continue
            }
            consumedSourceIDs.insert(sourceID)
            // The target was authenticated and read from its durable file. Failure to
            // unlink an obsolete source must not expose two active heads; a later load
            // or quota pass can retry the idempotent removal.
            try? removeIfPresent(sourceID)
        }

        return recordsByID.values.filter { !consumedSourceIDs.contains($0.id) }
    }

    func remove(_ id: UUID) throws {
        try ensureDirectory()
        try removeIfPresent(id)
    }

    func removeAll() throws {
        try ensureDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        for url in urls {
            try removeURL(url)
        }
        sessionGate.reset()
        try keyProvider.removeKey()
    }

    private func write(
        _ record: DocumentRecoveryRecord,
        using key: SymmetricKey,
        now: Date
    ) throws {
        let plaintext = try JSONEncoder.sorted.encode(record)
        guard plaintext.count <= Limits.recordBytes else {
            throw DocumentRecoveryError.quotaExceeded
        }
        let encrypted = try encryptedEnvelopeData(
            plaintext,
            recordID: record.id,
            using: key
        )
        try reclaimReplaceableStorage(
            beforeWriting: record,
            encryptedSize: encrypted.count,
            using: key,
            now: now
        )
        guard try projectedTotalBytes(replacing: record.id, with: encrypted.count)
                <= totalByteLimit
        else {
            throw DocumentRecoveryError.quotaExceeded
        }
        let url = recordURL(record.id)
        try DurableRecoveryWriter.replace(encrypted, at: url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func encryptedEnvelopeData(
        _ plaintext: Data,
        recordID: UUID,
        using key: SymmetricKey
    ) throws -> Data {
        let keyIdentifier = key.withUnsafeBytes { bytes in
            Data(SHA256.hash(data: Data(bytes))).prefix(16)
        }
        let provisional = EncryptedRecoveryEnvelope(
            formatVersion: EncryptedRecoveryEnvelope.formatVersion,
            recordID: recordID,
            plaintextLength: plaintext.count,
            keyIdentifier: Data(keyIdentifier),
            nonce: Data(),
            ciphertext: Data(),
            tag: Data()
        )
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: provisional.authenticatedHeader
        )
        return try JSONEncoder.sorted.encode(
            EncryptedRecoveryEnvelope(
                formatVersion: provisional.formatVersion,
                recordID: provisional.recordID,
                plaintextLength: provisional.plaintextLength,
                keyIdentifier: provisional.keyIdentifier,
                nonce: sealed.nonce.withUnsafeBytes { Data($0) },
                ciphertext: sealed.ciphertext,
                tag: sealed.tag
            )
        )
    }

    private func decryptRecord(at url: URL, using key: SymmetricKey) throws
        -> DocumentRecoveryRecord
    {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= Limits.encryptedRecordBytes
        else {
            throw DocumentRecoveryError.invalidRecord
        }
        let encrypted = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard encrypted.count <= Limits.encryptedRecordBytes else {
            throw DocumentRecoveryError.invalidRecord
        }
        let envelope = try JSONDecoder().decode(EncryptedRecoveryEnvelope.self, from: encrypted)
        guard envelope.formatVersion == EncryptedRecoveryEnvelope.formatVersion,
              envelope.plaintextLength >= 0,
              envelope.plaintextLength <= Limits.recordBytes,
              envelope.nonce.count == 12,
              envelope.tag.count == 16
        else {
            throw DocumentRecoveryError.invalidRecord
        }
        let expectedKeyIdentifier = key.withUnsafeBytes { bytes in
            Data(Data(SHA256.hash(data: Data(bytes))).prefix(16))
        }
        guard envelope.keyIdentifier == expectedKeyIdentifier else {
            throw DocumentRecoveryError.unavailableKey
        }
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        let plaintext = try AES.GCM.open(
            box,
            using: key,
            authenticating: envelope.authenticatedHeader
        )
        guard plaintext.count == envelope.plaintextLength else {
            throw DocumentRecoveryError.invalidRecord
        }
        let record = try JSONDecoder().decode(DocumentRecoveryRecord.self, from: plaintext)
        guard record.id == envelope.recordID else {
            throw DocumentRecoveryError.invalidRecord
        }
        return record
    }

    private func readRecord(id: UUID, using key: SymmetricKey) throws
        -> DocumentRecoveryRecord
    {
        try decryptRecord(at: recordURL(id), using: key)
    }

    private func consumeTransferredSource(
        _ sourceID: UUID,
        afterPersisting target: DocumentRecoveryRecord
    ) throws {
        let key = try availableKey()
        let durableTarget = try readRecord(id: target.id, using: key)
        guard durableTarget.effectiveLineageID == target.effectiveLineageID,
              durableTarget.effectiveEpoch == target.effectiveEpoch,
              durableTarget.transferSourceRecordID == sourceID
        else {
            throw DocumentRecoveryError.staleClaim
        }
        try beforeTransferConsumption?(sourceID, target.id)
        try validateTransferSource(sourceID, for: durableTarget)
        try removeIfPresent(sourceID)
    }

    private func validateTransferSource(
        _ sourceID: UUID,
        for target: DocumentRecoveryRecord
    ) throws {
        let sourceURL = recordURL(sourceID)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        let key = try availableKey()
        let source = try readRecord(id: sourceID, using: key).migrated()
        try source.validate()
        guard source.transferTargetRecordID == target.id,
              source.effectiveLineageID == target.effectiveLineageID,
              source.effectiveEpoch &+ 1 == target.effectiveEpoch
        else {
            throw DocumentRecoveryError.staleClaim
        }
    }

    private func diskContainsExactDocument(_ record: DocumentRecoveryRecord) throws -> Bool {
        guard record.originalURL != nil,
              let lineEnding = MarkdownLineEnding(rawValue: record.lineEndingRawValue),
              !record.requiresLineEndingChoice
        else {
            return false
        }
        guard let expected = try? MarkdownCodec.encode(
            record.text,
            properties: MarkdownFileProperties(
                hasUTF8BOM: record.hasUTF8BOM,
                lineEnding: lineEnding
            )
        ), let disk = try? DocumentRecoveryFileAccess.withResolvedURL(
            for: record,
            { try Data(contentsOf: $0, options: [.mappedIfSafe]) }
        ) else {
            return false
        }
        return disk == expected
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = rootURL
            try mutableRoot.setResourceValues(values)
        } catch {
            throw DocumentRecoveryError.unavailableStorage
        }
    }

    private func availableKey() throws -> SymmetricKey {
        if let key = try keyProvider.loadKey() { return key }
        let encrypted = try contents().filter { $0.pathExtension == "recovery" }
        for url in encrypted { _ = quarantine(url, reason: "key-lost") }
        return try keyProvider.createKey()
    }

    private func contents() throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DocumentRecoveryError.unavailableStorage
        }
    }

    private func purgeClosedSessionHeads() throws {
        for markerURL in try contents() where markerURL.pathExtension == "closed" {
            guard let id = UUID(
                uuidString: markerURL.deletingPathExtension().lastPathComponent
            ) else {
                continue
            }
            _ = try sessionGate.consumeClosedHeadIfPresent(
                id,
                headURL: recordURL(id)
            )
        }
    }

    private struct StoredRecoveryHead {
        let url: URL
        let record: DocumentRecoveryRecord
    }

    /// Reclamation is deliberately conservative and ordered. Temporary files and
    /// expired quarantine are never recovery heads. Expired or disk-redundant
    /// records go next. Only then may an older head be removed when a newer durable
    /// head for the same lineage already exists. The newest durable head for every
    /// lineage is never a quota victim.
    private func reclaimReplaceableStorage(
        beforeWriting incoming: DocumentRecoveryRecord,
        encryptedSize: Int,
        using key: SymmetricKey,
        now: Date
    ) throws {
        try purgeTemporaryFiles()
        try purgeOldQuarantine(now: now)
        try purgeReplaceableLegacyRecords(now: now, using: key)
        let heads = try purgeExpiredAndRedundantHeads(
            excluding: incoming.id,
            using: key,
            now: now
        )
        guard try projectedTotalBytes(replacing: incoming.id, with: encryptedSize)
                > totalByteLimit
        else {
            return
        }

        var newestByLineage: [UUID: StoredRecoveryHead] = [:]
        for head in heads {
            let lineage = head.record.effectiveLineageID
            if let existing = newestByLineage[lineage],
               !isNewer(head.record, than: existing.record)
            {
                continue
            }
            newestByLineage[lineage] = head
        }
        let protectedHeadIDs = Set(newestByLineage.values.map(\.record.id))
        let superseded = heads
            .filter { !protectedHeadIDs.contains($0.record.id) }
            .sorted { left, right in
                if left.record.updatedAt != right.record.updatedAt {
                    return left.record.updatedAt < right.record.updatedAt
                }
                if left.record.effectiveEpoch != right.record.effectiveEpoch {
                    return left.record.effectiveEpoch < right.record.effectiveEpoch
                }
                if left.record.effectiveRevision != right.record.effectiveRevision {
                    return left.record.effectiveRevision < right.record.effectiveRevision
                }
                return left.record.id.uuidString < right.record.id.uuidString
            }

        for candidate in superseded {
            try removeURL(candidate.url)
            if try projectedTotalBytes(replacing: incoming.id, with: encryptedSize)
                <= totalByteLimit
            {
                return
            }
        }
    }

    private func purgeExpiredAndRedundantHeads(
        excluding incomingID: UUID,
        using key: SymmetricKey,
        now: Date
    ) throws -> [StoredRecoveryHead] {
        var retained: [StoredRecoveryHead] = []
        for url in try contents() where url.pathExtension == "recovery" {
            guard url.standardizedFileURL != recordURL(incomingID).standardizedFileURL else {
                continue
            }
            do {
                let record = try decryptRecord(at: url, using: key).migrated()
                try record.validate()
                let isExpired = now.timeIntervalSince(record.updatedAt) > retentionInterval
                let isDiskRedundant = try diskContainsExactDocument(record)
                if isExpired || isDiskRedundant {
                    try removeURL(url)
                } else {
                    retained.append(StoredRecoveryHead(url: url, record: record))
                }
            } catch {
                _ = quarantine(url, reason: "corrupt", now: now)
            }
        }
        return retained
    }

    private func purgeReplaceableLegacyRecords(now: Date, using key: SymmetricKey) throws {
        for url in try contents() where url.pathExtension == "json" {
            do {
                let record = try JSONDecoder().decode(
                    DocumentRecoveryRecord.self,
                    from: Data(contentsOf: url)
                ).migrated()
                try record.validate()
                let isExpired = now.timeIntervalSince(record.updatedAt) > retentionInterval
                let isDiskRedundant = try diskContainsExactDocument(record)
                if isExpired || isDiskRedundant {
                    try removeURL(url)
                }
            } catch {
                _ = try quarantineLegacyPlaintext(
                    url,
                    reason: "legacy-corrupt",
                    using: key,
                    now: now
                )
            }
        }
    }

    private func purgeTemporaryFiles() throws {
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in urls where url.lastPathComponent.hasPrefix(".recovery-")
            && url.pathExtension == "tmp"
        {
            try removeURL(url)
        }
    }

    private func isNewer(
        _ candidate: DocumentRecoveryRecord,
        than existing: DocumentRecoveryRecord
    ) -> Bool {
        if candidate.effectiveEpoch != existing.effectiveEpoch {
            return candidate.effectiveEpoch > existing.effectiveEpoch
        }
        if candidate.effectiveRevision != existing.effectiveRevision {
            return candidate.effectiveRevision > existing.effectiveRevision
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.id.uuidString > existing.id.uuidString
    }

    private func projectedTotalBytes(replacing id: UUID, with newSize: Int) throws -> Int {
        let target = recordURL(id).standardizedFileURL
        return try managedStorageBytes(in: rootURL, excluding: target, startingAt: newSize)
    }

    private func managedStorageBytes(
        in directory: URL,
        excluding target: URL,
        startingAt initial: Int
    ) throws -> Int {
        var total = initial
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: []
        )
        for url in urls {
            if url.standardizedFileURL == target { continue }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                total = try managedStorageBytes(
                    in: url,
                    excluding: target,
                    startingAt: total
                )
            } else if values.isRegularFile == true {
                let size = max(0, values.fileSize ?? 0)
                let (sum, overflow) = total.addingReportingOverflow(size)
                total = overflow ? Int.max : sum
            }
        }
        return total
    }

    private func recordURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("recovery")
    }

    private func removeIfPresent(_ id: UUID) throws {
        try DurableRecoveryWriter.removeIfPresent(at: recordURL(id))
        try sessionGate.removeMarker(id)
    }

    private func removeURL(_ url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw DocumentRecoveryError.cannotRemove
        }
    }

    @discardableResult
    private func quarantine(_ url: URL, reason: String, now: Date = Date()) -> Bool {
        do {
            let directory = try ensureQuarantineDirectory()
            let destination = directory.appendingPathComponent(
                "\(url.lastPathComponent).\(reason).\(UUID().uuidString)"
            )
            try fileManager.moveItem(at: url, to: destination)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600, .modificationDate: now],
                ofItemAtPath: destination.path
            )
            return true
        } catch {
            return false
        }
    }

    private func quarantineLegacyPlaintext(
        _ url: URL,
        reason: String,
        using key: SymmetricKey,
        now: Date
    ) throws -> Bool {
        var destination: URL?
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= Limits.recordBytes
            else {
                throw DocumentRecoveryError.invalidRecord
            }
            let plaintext = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard plaintext.count <= Limits.recordBytes else {
                throw DocumentRecoveryError.invalidRecord
            }

            let directory = try ensureQuarantineDirectory()
            let quarantineURL = directory
                .appendingPathComponent("legacy-\(reason)-\(UUID().uuidString)")
                .appendingPathExtension("quarantine")
            destination = quarantineURL
            let encrypted = try encryptedEnvelopeData(
                plaintext,
                recordID: UUID(),
                using: key
            )
            try beforeLegacyQuarantineWrite?()
            try DurableRecoveryWriter.replace(encrypted, at: quarantineURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600, .modificationDate: now],
                ofItemAtPath: quarantineURL.path
            )
            var valuesToSet = URLResourceValues()
            valuesToSet.isExcludedFromBackup = true
            var mutableDestination = quarantineURL
            try mutableDestination.setResourceValues(valuesToSet)
            try removeURL(url)
            return true
        } catch {
            // A legacy record that cannot be decoded is never retained as plaintext.
            // If encrypted isolation itself fails, remove the unusable plaintext and
            // any partial encrypted destination. A removal failure remains visible to
            // the coordinator as degraded protection rather than silently persisting it.
            if let destination, fileManager.fileExists(atPath: destination.path) {
                try? removeURL(destination)
            }
            try removeUnusableLegacyPlaintext(url)
            return false
        }
    }

    private func removeUnusableLegacyPlaintext(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory != true else {
            throw DocumentRecoveryError.invalidRecord
        }
        try removeURL(url)
    }

    private func ensureQuarantineDirectory() throws -> URL {
        let directory = rootURL.appendingPathComponent("Quarantine", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(values)
            return directory
        } catch {
            throw DocumentRecoveryError.unavailableStorage
        }
    }

    private func purgeOldQuarantine(now: Date) throws {
        let directory = rootURL.appendingPathComponent("Quarantine", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        for url in urls {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > quarantineRetentionInterval {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

@MainActor
final class DocumentRecoveryCoordinator: ObservableObject {
    @Published private(set) var recoveredRecords: [DocumentRecoveryRecord] = []
    @Published private(set) var protectionErrorMessage: String?
    @Published private(set) var isLoaded = false

    private struct ActiveSession {
        var latestRecord: DocumentRecoveryRecord
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let store: DocumentRecoveryStore?
    private let intervalNanoseconds: UInt64
    private var activeSessions: [UUID: ActiveSession] = [:]
    private var sessionGenerations: [UUID: UInt64] = [:]
    private var pendingCloseTasks: [UUID: Task<Void, Never>] = [:]
    private var clearedContentIdentities: [UUID: Data] = [:]
    private var loadTask: Task<Void, Never>?
    private var hasClaimedAutomaticPresentation = false
    private var isDegradedProtectionWarningDismissed = false

    init(
        rootURL: URL? = nil,
        intervalNanoseconds: UInt64 = 5_000_000_000,
        fileManager: FileManager = .default,
        keyProvider: (any DocumentRecoveryKeyProviding)? = nil,
        beforeReconcileCommit: (@Sendable (DocumentRecoveryRecord) async -> Void)? = nil
    ) {
        self.intervalNanoseconds = intervalNanoseconds
        if let rootURL {
            store = DocumentRecoveryStore(
                rootURL: rootURL,
                keyProvider: keyProvider,
                beforeReconcileCommit: beforeReconcileCommit
            )
            return
        }

        do {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            store = DocumentRecoveryStore(
                rootURL: applicationSupport
                    .appendingPathComponent("Inflow", isDirectory: true)
                    .appendingPathComponent("Recovery", isDirectory: true),
                keyProvider: keyProvider,
                beforeReconcileCommit: beforeReconcileCommit
            )
        } catch {
            store = nil
            protectionErrorMessage = Self.degradedProtectionMessage
        }
    }

    func loadIfNeeded() async {
        if isLoaded { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadRecords()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func update(_ record: DocumentRecoveryRecord) {
        pendingCloseTasks.removeValue(forKey: record.id)?.cancel()
        if let clearedIdentity = clearedContentIdentities[record.id] {
            guard record.recoveryContentIdentity != clearedIdentity else { return }
            clearedContentIdentities.removeValue(forKey: record.id)
        }
        if var existing = activeSessions[record.id] {
            existing.latestRecord = record.nextRevision(after: existing.latestRecord)
            activeSessions[record.id] = existing
            return
        }

        let id = record.id
        var generation = (sessionGenerations[id] ?? 0) &+ 1
        if generation == 0 { generation = 1 }
        guard let store else {
            showDegradedProtectionWarning()
            return
        }
        do {
            try store.markSessionActive(id, generation: generation)
        } catch {
            showDegradedProtectionWarning()
            return
        }
        sessionGenerations[id] = generation
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.intervalNanoseconds)
                } catch {
                    return
                }
                await self.flush(id)
            }
        }
        activeSessions[id] = ActiveSession(
            latestRecord: record,
            generation: generation,
            task: task
        )
    }

    func flush(_ id: UUID) async {
        guard let store else {
            showDegradedProtectionWarning()
            return
        }

        while let session = activeSessions[id] {
            let record = session.latestRecord
            do {
                _ = try await store.reconcile(record)
                if let sourceID = record.transferSourceRecordID {
                    recoveredRecords.removeAll { $0.id == sourceID }
                }
                isDegradedProtectionWarningDismissed = false
                protectionErrorMessage = nil
            } catch {
                showDegradedProtectionWarning()
                return
            }

            guard let current = activeSessions[id] else { return }
            guard current.generation == session.generation,
                  current.latestRecord == record
            else {
                continue
            }
            return
        }
    }

    func close(_ id: UUID) {
        guard let closedSession = activeSessions.removeValue(forKey: id) else { return }
        closedSession.task.cancel()
        clearedContentIdentities.removeValue(forKey: id)
        pendingCloseTasks.removeValue(forKey: id)?.cancel()
        guard let store else {
            showDegradedProtectionWarning()
            return
        }
        let closingGeneration = closedSession.generation
        pendingCloseTasks[id] = Task { @MainActor [weak self, store] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.sessionGenerations[id] == closingGeneration,
                  self.activeSessions[id] == nil
            else {
                return
            }
            let didMarkClosed: Bool
            do {
                didMarkClosed = try await store.markSessionClosed(
                    id,
                    generation: closingGeneration
                )
            } catch {
                didMarkClosed = false
                self.showDegradedProtectionWarning()
            }

            if let active = self.activeSessions[id], active.generation != closingGeneration {
                return
            }
            guard self.sessionGenerations[id] == closingGeneration,
                  self.activeSessions[id] == nil
            else {
                return
            }
            if !didMarkClosed {
                self.showDegradedProtectionWarning()
            }
            self.pendingCloseTasks.removeValue(forKey: id)
        }
    }

    func discard(_ record: DocumentRecoveryRecord) async {
        guard let store else {
            protectionErrorMessage = Self.degradedProtectionMessage
            return
        }
        do {
            try await store.remove(record.id)
            recoveredRecords.removeAll { $0.id == record.id }
        } catch {
            protectionErrorMessage = "未能放弃所选恢复内容；内容仍保留在恢复中心。"
        }
    }

    func removeAllRecoveryContent() async throws {
        guard let store else { throw DocumentRecoveryError.unavailableStorage }
        let priorClearedContentIdentities = clearedContentIdentities
        let suspendedRecords = activeSessions.values.map(\.latestRecord)
        for session in activeSessions.values { session.task.cancel() }
        for task in pendingCloseTasks.values { task.cancel() }
        activeSessions.removeAll()
        pendingCloseTasks.removeAll()
        sessionGenerations.removeAll()
        for record in suspendedRecords {
            clearedContentIdentities[record.id] = record.recoveryContentIdentity
        }
        do {
            try await store.removeAll()
        } catch {
            clearedContentIdentities = priorClearedContentIdentities
            for record in suspendedRecords { update(record) }
            throw error
        }
        recoveredRecords.removeAll()
        hasClaimedAutomaticPresentation = false
        isDegradedProtectionWarningDismissed = false
        protectionErrorMessage = nil
    }

    func claimForRestoration(_ record: DocumentRecoveryRecord) async throws
        -> MarkdownDocument
    {
        guard let store else { throw DocumentRecoveryError.unavailableStorage }
        let targetID = UUID()
        let transfer = try await store.claim(record, targetRecordID: targetID)
        let document = try record.restoredDocument(transfer: transfer)
        recoveredRecords.removeAll { $0.id == record.id }
        return document
    }

    func retryProtection() async {
        isDegradedProtectionWarningDismissed = false
        guard let store else {
            protectionErrorMessage = Self.degradedProtectionMessage
            return
        }
        do {
            _ = try await store.load()
            protectionErrorMessage = nil
        } catch {
            protectionErrorMessage = Self.degradedProtectionMessage
        }
    }

    func continueWritingWithoutProtection() {
        isDegradedProtectionWarningDismissed = true
        protectionErrorMessage = nil
    }

    func claimAutomaticPresentation() -> Bool {
        guard isLoaded,
              !recoveredRecords.isEmpty,
              !hasClaimedAutomaticPresentation
        else {
            return false
        }
        hasClaimedAutomaticPresentation = true
        return true
    }

    private func loadRecords() async {
        guard let store else {
            showDegradedProtectionWarning()
            isLoaded = true
            return
        }
        do {
            let result = try await store.load()
            recoveredRecords = result.records
            if result.quarantinedRecordCount > 0 {
                protectionErrorMessage =
                    "有 \(result.quarantinedRecordCount) 项恢复内容无法验证，已保留但不会自动打开。你仍可正常保存 Markdown。"
            } else {
                protectionErrorMessage = nil
            }
        } catch {
            showDegradedProtectionWarning()
        }
        isLoaded = true
    }

    private func showDegradedProtectionWarning() {
        guard !isDegradedProtectionWarningDismissed else { return }
        protectionErrorMessage = Self.degradedProtectionMessage
    }

    static let degradedProtectionMessage =
        "你仍可以手动保存 Markdown 文件。在保护恢复前，请避免关闭未保存文档。"
}
