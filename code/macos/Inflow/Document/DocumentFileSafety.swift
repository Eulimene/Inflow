import CryptoKit
import Foundation

enum MarkdownWriteGuardError: Error, Equatable, LocalizedError, Sendable {
    case externalChange
    case deletedTarget
    case readOnlyTarget
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .externalChange:
            "文件已在其他位置更改。为避免覆盖，自动保存已暂停。"
        case .deletedTarget:
            "原文件已从磁盘删除。Inflow 不会自动重建它。"
        case .readOnlyTarget:
            "原文件当前不可写。原文件和当前编辑均未被丢弃。"
        case .targetChanged:
            "文档或目标已变化。请重新检查后再继续。"
        }
    }
}

/// Immutable bytes and expectations for one native document save request.
///
/// `FileDocument` creates a FileWrapper; it does not own AppKit's eventual safe-write
/// transaction.  This envelope therefore freezes what Inflow asked AppKit to save and
/// lets the completion path acknowledge only those exact bytes.  It deliberately does
/// not claim control over AppKit's final replacement operation.
struct SaveEnvelope: Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case automatic
        case save
        case saveAs
        case saveCopy
    }

    enum TargetExpectation: Equatable, Sendable {
        case absent
        case exact(HTMLExportTargetSnapshot)

        static func capture(_ url: URL) throws -> Self {
            let snapshot = try HTMLExportTargetSnapshot.capture(url)
            return snapshot.isExistingTarget ? .exact(snapshot) : .absent
        }

        func isCurrent(at url: URL) -> Bool {
            guard let current = try? HTMLExportTargetSnapshot.capture(url) else {
                return false
            }
            switch self {
            case .absent:
                return !current.isExistingTarget
            case let .exact(expected):
                return current == expected
            }
        }
    }

    let nonce: UUID
    let revision: UInt64
    let bytes: Data
    let contentHash: Data
    let sourceURL: URL?
    let targetURL: URL
    let targetExpectation: TargetExpectation
    let operation: Operation

    init(
        nonce: UUID = UUID(),
        revision: UInt64,
        bytes: Data,
        sourceURL: URL?,
        targetURL: URL,
        targetExpectation: TargetExpectation,
        operation: Operation
    ) {
        self.nonce = nonce
        self.revision = revision
        self.bytes = bytes
        contentHash = Data(SHA256.hash(data: bytes))
        self.sourceURL = sourceURL?.standardizedFileURL
        self.targetURL = targetURL.standardizedFileURL
        self.targetExpectation = targetExpectation
        self.operation = operation
    }

    var hasValidHash: Bool {
        contentHash == Data(SHA256.hash(data: bytes))
    }
}

final class MarkdownWriteGuard: @unchecked Sendable {
    struct Observation {
        let baselineData: Data?
        let committedAutomaticEnvelope: SaveEnvelope?
    }

    private struct RelocationAuthorization {
        let targetURL: URL
        let targetSnapshot: HTMLExportTargetSnapshot
        let targetData: Data?
        let proposedData: Data
        let additionalValidation: @Sendable () -> Bool
    }

    private let lock = NSLock()
    private var currentURL: URL?
    private var baselineData: Data?
    private var preparedEnvelope: SaveEnvelope?
    private var pendingEnvelopes: [UUID: SaveEnvelope] = [:]
    private var confirmedAutomaticEnvelopeAwaitingObservation: SaveEnvelope?
    private var lastObservedAutomaticRevision: UInt64 = 0
    private var committedRelocationBaselines: [URL: Data] = [:]
    private var nextAutomaticRevision: UInt64 = 1
    private var relocationAuthorization: RelocationAuthorization?

    func configure(url: URL?, baselineData: Data?) {
        lock.lock()
        let normalizedURL = url?.standardizedFileURL
        let isExpectedRelocation = normalizedURL.map { target in
            preparedEnvelope?.targetURL == target
                || pendingEnvelopes.values.contains { $0.targetURL == target }
                || committedRelocationBaselines[target] != nil
        } ?? false
        currentURL = normalizedURL
        self.baselineData = baselineData
        if let normalizedURL, isExpectedRelocation {
            if preparedEnvelope?.targetURL != normalizedURL {
                preparedEnvelope = nil
            }
            pendingEnvelopes = pendingEnvelopes.filter {
                $0.value.targetURL == normalizedURL
            }
            if confirmedAutomaticEnvelopeAwaitingObservation?.targetURL != normalizedURL {
                confirmedAutomaticEnvelopeAwaitingObservation = nil
            }
            committedRelocationBaselines.removeValue(forKey: normalizedURL)
        } else {
            preparedEnvelope = nil
            pendingEnvelopes.removeAll()
            confirmedAutomaticEnvelopeAwaitingObservation = nil
            lastObservedAutomaticRevision = 0
            committedRelocationBaselines.removeAll()
        }
        relocationAuthorization = nil
        lock.unlock()
    }

    func prepare(_ envelope: SaveEnvelope) throws {
        guard envelope.hasValidHash,
              envelope.targetExpectation.isCurrent(at: envelope.targetURL)
        else {
            throw MarkdownWriteGuardError.targetChanged
        }
        lock.lock()
        preparedEnvelope = envelope
        nextAutomaticRevision = max(nextAutomaticRevision, envelope.revision &+ 1)
        lock.unlock()
    }

    func cancel(_ nonce: UUID) {
        lock.lock()
        if preparedEnvelope?.nonce == nonce {
            preparedEnvelope = nil
        }
        pendingEnvelopes.removeValue(forKey: nonce)
        lock.unlock()
    }

    /// Returns the bytes frozen for the native save currently in flight.  A
    /// `FileDocument` value can continue changing while AppKit asks an older save
    /// operation for its wrapper, so serialization must not re-read that value.
    func fileDocumentSerializationData(fallback currentData: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let preparedEnvelope else { return currentData }
        guard preparedEnvelope.hasValidHash else {
            throw MarkdownWriteGuardError.targetChanged
        }
        return preparedEnvelope.bytes
    }

    func authorizeRelocation(
        to targetURL: URL,
        targetSnapshot: HTMLExportTargetSnapshot,
        proposedData: Data,
        additionalValidation: @escaping @Sendable () -> Bool = { true }
    ) throws {
        let capturedTarget = try HTMLExportTargetSnapshot.captureContents(targetURL)
        guard capturedTarget.snapshot == targetSnapshot,
              additionalValidation()
        else {
            throw MarkdownWriteGuardError.targetChanged
        }
        lock.lock()
        relocationAuthorization = RelocationAuthorization(
            targetURL: targetURL.standardizedFileURL,
            targetSnapshot: targetSnapshot,
            targetData: capturedTarget.data,
            proposedData: proposedData,
            additionalValidation: additionalValidation
        )
        lock.unlock()
    }

    func cancelRelocationAuthorization() {
        lock.lock()
        relocationAuthorization = nil
        lock.unlock()
    }

    func authorize(existingFile: FileWrapper?, proposedData: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let existingData = existingFile?.regularFileContents

        if let authorization = relocationAuthorization,
           authorization.proposedData == proposedData,
           existingData == authorization.targetData
                || (!authorization.targetSnapshot.isExistingTarget && existingData == nil)
        {
            guard (try? HTMLExportTargetSnapshot.capture(authorization.targetURL))
                    == authorization.targetSnapshot,
                  authorization.additionalValidation()
            else {
                relocationAuthorization = nil
                throw MarkdownWriteGuardError.targetChanged
            }
            try stageEnvelope(
                proposedData: proposedData,
                targetURL: authorization.targetURL,
                operation: preparedEnvelope?.operation ?? .saveAs
            )
            return
        }

        guard let currentURL, let baselineData else { return }

        let diskData = try? HTMLExportTargetSnapshot.captureContents(currentURL).data
        if let committed = adoptPendingAutomaticEnvelopeMatching(diskData) {
            rememberConfirmedAutomaticEnvelope(committed)
        }
        let effectiveBaseline = self.baselineData ?? baselineData
        // FileDocument may provide either the coordinated current bytes or its
        // last read wrapper for an in-place save. Treat both as the current
        // document; only a demonstrably different target is considered Save As.
        let isNormalSave = existingData == diskData || existingData == effectiveBaseline

        if diskData == proposedData {
            self.baselineData = proposedData
            pendingEnvelopes.removeAll()
            return
        }

        if diskData == effectiveBaseline {
            if isNormalSave,
               !FileManager.default.isWritableFile(atPath: currentURL.path)
            {
                throw MarkdownWriteGuardError.readOnlyTarget
            }
            if isNormalSave {
                try stageEnvelope(
                    proposedData: proposedData,
                    targetURL: currentURL,
                    operation: .automatic
                )
            }
            return
        }

        // A different existing wrapper (or no wrapper while the current URL still
        // exists) identifies Save As. It must stay available as the safe exit from
        // a conflict, while an ordinary in-place save remains blocked.
        if !isNormalSave {
            return
        }
        if diskData == nil {
            throw FileManager.default.fileExists(atPath: currentURL.path)
                ? MarkdownWriteGuardError.readOnlyTarget
                : MarkdownWriteGuardError.deletedTarget
        }
        throw MarkdownWriteGuardError.externalChange
    }

    func observe(diskData: Data?) -> Observation {
        lock.lock()
        defer { lock.unlock() }
        if let committed = adoptPendingAutomaticEnvelopeMatching(diskData) {
            rememberConfirmedAutomaticEnvelope(committed)
        }
        let committed = confirmedAutomaticEnvelopeAwaitingObservation
        if let committed {
            lastObservedAutomaticRevision = max(
                lastObservedAutomaticRevision,
                committed.revision
            )
            confirmedAutomaticEnvelopeAwaitingObservation = nil
        }
        return Observation(
            baselineData: baselineData,
            committedAutomaticEnvelope: committed
        )
    }

    func commit(_ envelope: SaveEnvelope, diskData: Data?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard envelope.hasValidHash,
              diskData == envelope.bytes,
              pendingEnvelopes[envelope.nonce] == envelope
                    || preparedEnvelope == envelope
        else {
            return false
        }
        if currentURL == envelope.targetURL {
            baselineData = envelope.bytes
        } else if envelope.operation == .saveAs {
            committedRelocationBaselines[envelope.targetURL] = envelope.bytes
        }
        pendingEnvelopes = pendingEnvelopes.filter { $0.value.revision > envelope.revision }
        if preparedEnvelope?.nonce == envelope.nonce {
            preparedEnvelope = nil
        }
        if let unobserved = confirmedAutomaticEnvelopeAwaitingObservation,
           unobserved.targetURL == envelope.targetURL,
           unobserved.revision <= envelope.revision
        {
            confirmedAutomaticEnvelopeAwaitingObservation = nil
        }
        return true
    }

    func candidateBaseline(for url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let normalized = url.standardizedFileURL
        if let committed = committedRelocationBaselines[normalized] {
            return committed
        }
        if let preparedEnvelope, preparedEnvelope.targetURL == normalized {
            return preparedEnvelope.bytes
        }
        return pendingEnvelopes.values
            .filter { $0.targetURL == normalized }
            .max(by: { $0.revision < $1.revision })?
            .bytes
    }

    func adopt(_ data: Data) {
        lock.lock()
        baselineData = data
        pendingEnvelopes.removeAll()
        preparedEnvelope = nil
        confirmedAutomaticEnvelopeAwaitingObservation = nil
        lock.unlock()
    }

    private func stageEnvelope(
        proposedData: Data,
        targetURL: URL,
        operation: SaveEnvelope.Operation
    ) throws {
        let envelope: SaveEnvelope
        if let preparedEnvelope {
            guard preparedEnvelope.bytes == proposedData,
                  preparedEnvelope.targetURL == targetURL.standardizedFileURL,
                  preparedEnvelope.targetExpectation.isCurrent(at: targetURL)
            else {
                throw MarkdownWriteGuardError.targetChanged
            }
            envelope = preparedEnvelope
        } else {
            envelope = SaveEnvelope(
                revision: nextAutomaticRevision,
                bytes: proposedData,
                sourceURL: currentURL,
                targetURL: targetURL,
                targetExpectation: try .capture(targetURL),
                operation: operation
            )
            nextAutomaticRevision &+= 1
        }
        pendingEnvelopes[envelope.nonce] = envelope
    }

    @discardableResult
    private func adoptPendingAutomaticEnvelopeMatching(_ diskData: Data?) -> SaveEnvelope? {
        guard let diskData,
              let committed = pendingEnvelopes.values
                .filter({
                    $0.operation == .automatic
                        && $0.bytes == diskData
                        && $0.hasValidHash
                })
                .max(by: { $0.revision < $1.revision })
        else {
            return nil
        }
        baselineData = committed.bytes
        pendingEnvelopes = pendingEnvelopes.filter { $0.value.revision > committed.revision }
        if preparedEnvelope?.nonce == committed.nonce {
            preparedEnvelope = nil
        }
        return committed
    }

    private func rememberConfirmedAutomaticEnvelope(_ envelope: SaveEnvelope) {
        guard envelope.operation == .automatic,
              envelope.revision > lastObservedAutomaticRevision
        else {
            return
        }
        if let awaiting = confirmedAutomaticEnvelopeAwaitingObservation,
           awaiting.revision >= envelope.revision
        {
            return
        }
        confirmedAutomaticEnvelopeAwaitingObservation = envelope
    }
}

struct DocumentDiskInspection: Sendable {
    let data: Data?
    let exists: Bool
    let isWritable: Bool
}

struct DocumentReloadEnvelope: Sendable {
    let nonce: UUID
    let url: URL
    let sourceLocalData: Data
    let diskData: Data
    let decoded: DecodedMarkdown
}

actor DocumentFileSafetyWorker {
    func inspect(_ url: URL) -> DocumentDiskInspection {
        let fileManager = FileManager.default
        guard let captured = try? HTMLExportTargetSnapshot.captureContents(url),
              captured.snapshot.isExistingTarget,
              let data = captured.data
        else {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
            if exists {
                return DocumentDiskInspection(
                    data: nil,
                    exists: true,
                    isWritable: fileManager.isWritableFile(atPath: url.path)
                )
            }
            return DocumentDiskInspection(data: nil, exists: false, isWritable: false)
        }
        return DocumentDiskInspection(
            data: data,
            exists: true,
            isWritable: fileManager.isWritableFile(atPath: url.path)
        )
    }

    func verify(_ expected: Data?, at url: URL) throws -> DocumentDiskInspection {
        let inspection = inspect(url)
        guard inspection.data == expected else {
            throw DocumentFileSafetyError.staleDecision
        }
        return inspection
    }

    func saveCopy(
        _ data: Data,
        to targetURL: URL,
        expectedTarget: HTMLExportTargetSnapshot
    ) throws {
        try HTMLExportFileWriter.write(
            data,
            to: targetURL,
            expectedTarget: expectedTarget
        )
    }

}

enum DocumentFileSafetyError: Error, Equatable, LocalizedError, Sendable {
    case staleDecision
    case saveCompletionMismatch
    case invalidDiskDocument

    var errorDescription: String? {
        switch self {
        case .staleDecision:
            "文档或磁盘内容已再次变化。之前的确认已失效，请重新比较。"
        case .saveCompletionMismatch:
            "系统报告保存完成，但磁盘字节与本次保存快照不一致。当前编辑仍保持未保存状态。"
        case .invalidDiskDocument:
            "当前磁盘版本不是可验证的 UTF-8 Markdown，因此无法重新载入。"
        }
    }
}

struct DocumentFileConflictSnapshot: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let baselineData: Data
    let baselineText: String
    let localData: Data
    let localText: String
    let diskData: Data?
    let diskText: String?
    let diskExists: Bool
    let localHasChanges: Bool

    init(
        url: URL,
        baselineData: Data,
        baselineText: String,
        localData: Data,
        localText: String,
        diskData: Data?,
        diskText: String?,
        diskExists: Bool
    ) {
        id = UUID()
        self.url = url
        self.baselineData = baselineData
        self.baselineText = baselineText
        self.localData = localData
        self.localText = localText
        self.diskData = diskData
        self.diskText = diskText
        self.diskExists = diskExists
        localHasChanges = localData != baselineData
    }

    func hasSameFacts(as other: DocumentFileConflictSnapshot) -> Bool {
        url.standardizedFileURL == other.url.standardizedFileURL
            && baselineData == other.baselineData
            && localData == other.localData
            && diskData == other.diskData
            && diskExists == other.diskExists
    }
}

enum DocumentFileSafetyState {
    case safe
    case readOnly(URL)
    case changed(DocumentFileConflictSnapshot)
    case deleted(DocumentFileConflictSnapshot)

    var conflictSnapshot: DocumentFileConflictSnapshot? {
        switch self {
        case let .changed(snapshot), let .deleted(snapshot): snapshot
        case .safe, .readOnly: nil
        }
    }

    var blocksEditing: Bool {
        if case .readOnly = self { return true }
        return false
    }

    /// The exact disk snapshot whose recovery action must create a sibling file.
    /// A new snapshot ID means the user must make a new directory-access decision.
    var directoryMutationSnapshotID: DocumentFileConflictSnapshot.ID? {
        switch self {
        case let .changed(snapshot) where snapshot.localHasChanges:
            snapshot.id
        case let .deleted(snapshot):
            snapshot.id
        case .safe, .readOnly, .changed:
            nil
        }
    }
}

@MainActor
final class DocumentFileSafetySession: ObservableObject {
    @Published private(set) var state: DocumentFileSafetyState = .safe
    @Published private(set) var automaticSaveCommit: SaveEnvelope?

    private let worker: DocumentFileSafetyWorker
    private let intervalNanoseconds: UInt64
    private var configuredURL: URL?
    private var baselineData: Data?
    private var baselineText = ""
    private var currentData: Data?
    private var currentText = ""
    private var observedRevisionData: Data?
    private var currentRevision: UInt64 = 0
    private var writeGuard: MarkdownWriteGuard?
    private var monitorTask: Task<Void, Never>?
    private var inspectionGeneration = 0

    var hasUncommittedChanges: Bool {
        currentData != baselineData
    }

    init(
        worker: DocumentFileSafetyWorker = DocumentFileSafetyWorker(),
        intervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.worker = worker
        self.intervalNanoseconds = intervalNanoseconds
    }

    func update(document: MarkdownDocument, fileURL: URL?) {
        currentText = document.text
        currentData = try? document.encodedFileData()
        if currentData != observedRevisionData {
            currentRevision &+= 1
            observedRevisionData = currentData
        }
        writeGuard = document.writeGuard

        let normalizedURL = fileURL?.standardizedFileURL
        if normalizedURL != configuredURL {
            configuredURL = normalizedURL
            guard let normalizedURL else {
                baselineData = nil
                baselineText = ""
                document.writeGuard.configure(url: nil, baselineData: nil)
                stopMonitoring()
                state = .safe
                return
            }

            // A first Save As may publish its new fileURL before AppKit invokes
            // completion. Prefer the prepared envelope even for the first named
            // URL so edits made while the panel/save is in flight never become the
            // committed baseline by accident.
            let initialData = document.writeGuard.candidateBaseline(for: normalizedURL)
                ?? document.openedFileData
                ?? currentData
            baselineData = initialData
            baselineText = initialData.flatMap { try? MarkdownCodec.decode($0).text }
                ?? document.text
            document.writeGuard.configure(url: normalizedURL, baselineData: initialData)
            state = .safe
            startMonitoring()
            scheduleInspection()
        } else if normalizedURL != nil, monitorTask == nil {
            startMonitoring()
            scheduleInspection()
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        inspectionGeneration &+= 1
    }

    /// Performs the same observation used by the periodic monitor and is also the
    /// synchronization point for callers that must immediately consume a native
    /// automatic-save completion.
    func inspectNow() async {
        guard let url = configuredURL else { return }
        inspectionGeneration &+= 1
        let generation = inspectionGeneration
        let inspection = await worker.inspect(url)
        guard generation == inspectionGeneration,
              url == configuredURL
        else {
            return
        }
        apply(inspection, at: url)
    }

    func prepareReload(_ snapshot: DocumentFileConflictSnapshot) async throws
        -> DocumentReloadEnvelope
    {
        _ = try requireCurrentData(matching: snapshot)
        let inspection = try await worker.verify(snapshot.diskData, at: snapshot.url)
        _ = try requireCurrentData(matching: snapshot)
        guard inspection.exists,
              let data = inspection.data,
              let decoded = try? MarkdownCodec.decode(data)
        else {
            throw DocumentFileSafetyError.invalidDiskDocument
        }
        return DocumentReloadEnvelope(
            nonce: UUID(),
            url: snapshot.url,
            sourceLocalData: snapshot.localData,
            diskData: data,
            decoded: decoded
        )
    }

    func commitReload(_ envelope: DocumentReloadEnvelope) async throws
        -> (data: Data, decoded: DecodedMarkdown)
    {
        let inspection = try await worker.verify(envelope.diskData, at: envelope.url)
        guard configuredURL == envelope.url.standardizedFileURL,
              inspection.exists,
              currentData == envelope.sourceLocalData || currentData == envelope.diskData
        else {
            throw DocumentFileSafetyError.staleDecision
        }
        adoptBaseline(envelope.diskData, text: envelope.decoded.text)
        scheduleInspection()
        return (envelope.diskData, envelope.decoded)
    }

    func reload(_ snapshot: DocumentFileConflictSnapshot) async throws
        -> (data: Data, decoded: DecodedMarkdown)
    {
        let envelope = try await prepareReload(snapshot)
        return try await commitReload(envelope)
    }

    func saveCopy(
        _ data: Data,
        to targetURL: URL,
        expectedTarget: HTMLExportTargetSnapshot
    ) async throws {
        guard let currentData, currentData == data else {
            throw DocumentFileSafetyError.staleDecision
        }
        try await worker.saveCopy(
            data,
            to: targetURL,
            expectedTarget: expectedTarget
        )
    }

    func prepareSave(
        document: MarkdownDocument,
        sourceURL: URL?,
        targetURL: URL,
        targetExpectation: SaveEnvelope.TargetExpectation,
        operation: SaveEnvelope.Operation
    ) throws -> SaveEnvelope {
        guard let data = try? document.encodedFileData(),
              data == currentData
        else {
            throw DocumentFileSafetyError.staleDecision
        }
        let envelope = SaveEnvelope(
            revision: currentRevision,
            bytes: data,
            sourceURL: sourceURL,
            targetURL: targetURL,
            targetExpectation: targetExpectation,
            operation: operation
        )
        try document.writeGuard.prepare(envelope)
        return envelope
    }

    func prepareConfirmedOverwrite(
        document: MarkdownDocument,
        snapshot: DocumentFileConflictSnapshot
    ) async throws -> SaveEnvelope {
        _ = try requireCurrentData(matching: snapshot)
        let inspection = try await worker.verify(snapshot.diskData, at: snapshot.url)
        _ = try requireCurrentData(matching: snapshot)
        guard inspection.exists else {
            throw DocumentFileSafetyError.staleDecision
        }
        let targetSnapshot = try HTMLExportTargetSnapshot.capture(snapshot.url)
        guard targetSnapshot.isExistingTarget else {
            throw DocumentFileSafetyError.staleDecision
        }
        _ = try await worker.verify(snapshot.diskData, at: snapshot.url)
        return try prepareSave(
            document: document,
            sourceURL: snapshot.url,
            targetURL: snapshot.url,
            targetExpectation: .exact(targetSnapshot),
            operation: .save
        )
    }

    func cancelSave(_ envelope: SaveEnvelope) {
        writeGuard?.cancel(envelope.nonce)
    }

    func commitSave(_ envelope: SaveEnvelope) async throws {
        let inspection = await worker.inspect(envelope.targetURL)
        guard inspection.exists, inspection.data == envelope.bytes else {
            throw DocumentFileSafetyError.saveCompletionMismatch
        }
        guard envelope.operation == .save || envelope.operation == .saveAs else {
            writeGuard?.cancel(envelope.nonce)
            return
        }
        guard writeGuard?.commit(envelope, diskData: inspection.data) == true else {
            throw DocumentFileSafetyError.saveCompletionMismatch
        }
        if configuredURL == envelope.targetURL {
            baselineData = envelope.bytes
            baselineText = (try? MarkdownCodec.decode(envelope.bytes).text) ?? baselineText
            state = inspection.isWritable ? .safe : .readOnly(envelope.targetURL)
        }
        scheduleInspection()
    }

    private func requireCurrentData(matching snapshot: DocumentFileConflictSnapshot) throws
        -> Data
    {
        guard configuredURL == snapshot.url.standardizedFileURL,
              let currentData,
              currentData == snapshot.localData
        else {
            throw DocumentFileSafetyError.staleDecision
        }
        return currentData
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.intervalNanoseconds)
                } catch {
                    return
                }
                self.scheduleInspection()
            }
        }
    }

    private func scheduleInspection() {
        guard let url = configuredURL else { return }
        inspectionGeneration &+= 1
        let generation = inspectionGeneration
        Task { [weak self, worker] in
            let inspection = await worker.inspect(url)
            guard let self,
                  generation == self.inspectionGeneration,
                  url == self.configuredURL
            else {
                return
            }
            self.apply(inspection, at: url)
        }
    }

    private func apply(_ inspection: DocumentDiskInspection, at url: URL) {
        if let observation = writeGuard?.observe(diskData: inspection.data) {
            if let observedBaseline = observation.baselineData,
               observedBaseline != baselineData
            {
                baselineData = observedBaseline
                baselineText = (try? MarkdownCodec.decode(observedBaseline).text) ?? baselineText
            }
            if let committed = observation.committedAutomaticEnvelope,
               committed.nonce != automaticSaveCommit?.nonce
            {
                automaticSaveCommit = committed
            }
        }
        guard let baselineData, let currentData else {
            state = inspection.exists && !inspection.isWritable ? .readOnly(url) : .safe
            return
        }

        if inspection.data == currentData {
            adoptBaseline(currentData, text: currentText)
            state = inspection.isWritable ? .safe : .readOnly(url)
            return
        }
        if inspection.data == baselineData {
            state = inspection.isWritable ? .safe : .readOnly(url)
            return
        }

        let diskText = inspection.data.flatMap { try? MarkdownCodec.decode($0).text }
        let snapshot = DocumentFileConflictSnapshot(
            url: url,
            baselineData: baselineData,
            baselineText: baselineText,
            localData: currentData,
            localText: currentText,
            diskData: inspection.data,
            diskText: diskText,
            diskExists: inspection.exists
        )
        if let existing = state.conflictSnapshot,
           existing.hasSameFacts(as: snapshot)
        {
            return
        }
        state = inspection.exists ? .changed(snapshot) : .deleted(snapshot)
    }

    private func adoptBaseline(_ data: Data, text: String) {
        baselineData = data
        baselineText = text
        writeGuard?.adopt(data)
        state = .safe
    }
}
