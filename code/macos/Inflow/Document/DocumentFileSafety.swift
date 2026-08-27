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

final class MarkdownWriteGuard: @unchecked Sendable {
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
    private var pendingWriteData: Data?
    private var relocationAuthorization: RelocationAuthorization?

    func configure(url: URL?, baselineData: Data?) {
        lock.lock()
        currentURL = url?.standardizedFileURL
        self.baselineData = baselineData
        pendingWriteData = nil
        relocationAuthorization = nil
        lock.unlock()
    }

    func authorizeRelocation(
        to targetURL: URL,
        targetSnapshot: HTMLExportTargetSnapshot,
        proposedData: Data,
        additionalValidation: @escaping @Sendable () -> Bool = { true }
    ) throws {
        guard try HTMLExportTargetSnapshot.capture(targetURL) == targetSnapshot,
              additionalValidation()
        else {
            throw MarkdownWriteGuardError.targetChanged
        }
        let targetData = targetSnapshot.isExistingTarget
            ? try Data(contentsOf: targetURL, options: [.mappedIfSafe])
            : nil
        guard try HTMLExportTargetSnapshot.capture(targetURL) == targetSnapshot,
              additionalValidation()
        else {
            throw MarkdownWriteGuardError.targetChanged
        }
        lock.lock()
        relocationAuthorization = RelocationAuthorization(
            targetURL: targetURL.standardizedFileURL,
            targetSnapshot: targetSnapshot,
            targetData: targetData,
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
            return
        }

        guard let currentURL, let baselineData else { return }

        let diskData = try? Data(contentsOf: currentURL, options: [.mappedIfSafe])
        if let pendingWriteData, diskData == pendingWriteData {
            self.baselineData = pendingWriteData
            self.pendingWriteData = nil
        }
        let effectiveBaseline = self.baselineData ?? baselineData
        // FileDocument may provide either the coordinated current bytes or its
        // last read wrapper for an in-place save. Treat both as the current
        // document; only a demonstrably different target is considered Save As.
        let isNormalSave = existingData == diskData || existingData == effectiveBaseline

        if diskData == proposedData {
            self.baselineData = proposedData
            pendingWriteData = nil
            return
        }

        if diskData == effectiveBaseline {
            if isNormalSave,
               !FileManager.default.isWritableFile(atPath: currentURL.path)
            {
                throw MarkdownWriteGuardError.readOnlyTarget
            }
            if isNormalSave {
                pendingWriteData = proposedData
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

    func observe(diskData: Data?) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let pendingWriteData, diskData == pendingWriteData {
            baselineData = pendingWriteData
            self.pendingWriteData = nil
        }
        return baselineData
    }

    func adopt(_ data: Data) {
        lock.lock()
        baselineData = data
        pendingWriteData = nil
        lock.unlock()
    }
}

struct DocumentDiskInspection: Sendable {
    let data: Data?
    let exists: Bool
    let isWritable: Bool
}

actor DocumentFileSafetyWorker {
    func inspect(_ url: URL) -> DocumentDiskInspection {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
        guard exists else {
            return DocumentDiskInspection(data: nil, exists: false, isWritable: false)
        }
        return DocumentDiskInspection(
            data: try? Data(contentsOf: url, options: [.mappedIfSafe]),
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

    func overwrite(
        snapshot: DocumentFileConflictSnapshot,
        with localData: Data,
        now: Date = Date()
    ) throws -> URL {
        guard let diskData = snapshot.diskData else {
            throw DocumentFileSafetyError.diskUnavailable
        }
        _ = try verify(diskData, at: snapshot.url)

        let conflictURL = try availableConflictCopyURL(for: snapshot.url, now: now)
        let absentConflictTarget = try HTMLExportTargetSnapshot.capture(conflictURL)
        guard !absentConflictTarget.isExistingTarget else {
            throw DocumentFileSafetyError.staleDecision
        }
        try HTMLExportFileWriter.write(
            diskData,
            to: conflictURL,
            expectedTarget: absentConflictTarget
        )

        do {
            let currentTarget = try HTMLExportTargetSnapshot.capture(snapshot.url)
            guard currentTarget.isExistingTarget,
                  inspect(snapshot.url).data == diskData
            else {
                throw DocumentFileSafetyError.staleDecision
            }
            try HTMLExportFileWriter.write(
                localData,
                to: snapshot.url,
                expectedTarget: currentTarget
            )
        } catch {
            throw DocumentFileSafetyError.overwriteFailed(conflictCopy: conflictURL)
        }
        return conflictURL
    }

    func recreate(
        snapshot: DocumentFileConflictSnapshot,
        with localData: Data
    ) throws {
        let inspection = inspect(snapshot.url)
        guard !inspection.exists else {
            throw DocumentFileSafetyError.staleDecision
        }
        let expectedTarget = try HTMLExportTargetSnapshot.capture(snapshot.url)
        guard !expectedTarget.isExistingTarget,
              !inspect(snapshot.url).exists
        else {
            throw DocumentFileSafetyError.staleDecision
        }
        try HTMLExportFileWriter.write(
            localData,
            to: snapshot.url,
            expectedTarget: expectedTarget
        )
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

    private func availableConflictCopyURL(for originalURL: URL, now: Date) throws -> URL {
        let folder = originalURL.deletingLastPathComponent()
        let extensionName = originalURL.pathExtension
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = "\(stem) (冲突副本 \(formatter.string(from: now)))"

        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : "-\(index + 1)"
            var candidate = folder.appendingPathComponent(base + suffix)
            if !extensionName.isEmpty {
                candidate.appendPathExtension(extensionName)
            }
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw DocumentFileSafetyError.cannotCreateConflictCopy
    }
}

enum DocumentFileSafetyError: Error, Equatable, LocalizedError, Sendable {
    case staleDecision
    case diskUnavailable
    case invalidDiskDocument
    case cannotCreateConflictCopy
    case overwriteFailed(conflictCopy: URL)

    var errorDescription: String? {
        switch self {
        case .staleDecision:
            "文档或磁盘内容已再次变化。之前的确认已失效，请重新比较。"
        case .diskUnavailable:
            "当前磁盘版本无法读取，因此没有执行任何覆盖。"
        case .invalidDiskDocument:
            "当前磁盘版本不是可验证的 UTF-8 Markdown，因此无法重新载入。"
        case .cannotCreateConflictCopy:
            "无法为磁盘当前版本选择安全的冲突副本名称。"
        case let .overwriteFailed(conflictCopy):
            "已将磁盘当前版本保存为「\(conflictCopy.lastPathComponent)」，但写回当前编辑失败；原目标未被破坏。"
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

    private let worker: DocumentFileSafetyWorker
    private let intervalNanoseconds: UInt64
    private var configuredURL: URL?
    private var baselineData: Data?
    private var baselineText = ""
    private var currentData: Data?
    private var currentText = ""
    private var writeGuard: MarkdownWriteGuard?
    private var hasConfiguredNamedDocument = false
    private var monitorTask: Task<Void, Never>?
    private var inspectionGeneration = 0

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

            let initialData: Data?
            if hasConfiguredNamedDocument {
                initialData = currentData
            } else {
                initialData = document.openedFileData ?? currentData
            }
            hasConfiguredNamedDocument = true
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

    func reload(_ snapshot: DocumentFileConflictSnapshot) async throws
        -> (data: Data, decoded: DecodedMarkdown)
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
        adoptBaseline(data, text: decoded.text)
        scheduleInspection()
        return (data, decoded)
    }

    func overwrite(_ snapshot: DocumentFileConflictSnapshot) async throws -> URL {
        let localData = try requireCurrentData(matching: snapshot)
        let conflictURL = try await worker.overwrite(snapshot: snapshot, with: localData)
        _ = try requireCurrentData(matching: snapshot)
        adoptBaseline(localData, text: currentText)
        scheduleInspection()
        return conflictURL
    }

    func recreate(_ snapshot: DocumentFileConflictSnapshot) async throws {
        let localData = try requireCurrentData(matching: snapshot)
        try await worker.recreate(snapshot: snapshot, with: localData)
        _ = try requireCurrentData(matching: snapshot)
        adoptBaseline(localData, text: currentText)
        scheduleInspection()
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
        if let observedBaseline = writeGuard?.observe(diskData: inspection.data),
           observedBaseline != baselineData
        {
            baselineData = observedBaseline
            baselineText = (try? MarkdownCodec.decode(observedBaseline).text) ?? baselineText
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
