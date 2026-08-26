import Foundation
import SwiftUI

struct MarkdownRestorationState: Equatable, Sendable {
    let selectedUTF16Location: Int
    let selectedUTF16Length: Int
    let viewModeRawValue: String
    let verticalScrollOffset: Double
}

struct DocumentRecoveryRecord: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
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
        text = document.text
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

    func restoredDocument() throws -> MarkdownDocument {
        try validate()
        guard let lineEnding = MarkdownLineEnding(rawValue: lineEndingRawValue) else {
            throw DocumentRecoveryError.invalidRecord
        }
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
            )
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
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
    }
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
    case invalidRecord
    case cannotWrite
    case cannotRemove

    var errorDescription: String? {
        switch self {
        case .unavailableStorage:
            "恢复保护目录暂时不可用。"
        case .invalidRecord:
            "恢复内容的结构无法验证。"
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

actor DocumentRecoveryStore {
    nonisolated let rootURL: URL
    private let retentionInterval: TimeInterval
    private let fileManager = FileManager.default

    init(
        rootURL: URL,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.rootURL = rootURL
        self.retentionInterval = retentionInterval
    }

    func reconcile(_ record: DocumentRecoveryRecord) throws
        -> DocumentRecoveryReconcileOutcome
    {
        try record.validate()
        try ensureDirectory()

        if record.originalURL == nil, record.text.isEmpty {
            try removeIfPresent(record.id)
            return .removedBecauseEmpty
        }
        if try diskContainsExactDocument(record) {
            try removeIfPresent(record.id)
            return .removedBecauseSaved
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(record)
            try data.write(to: recordURL(record.id), options: .atomic)
        } catch let error as DocumentRecoveryError {
            throw error
        } catch {
            throw DocumentRecoveryError.cannotWrite
        }
        return .stored
    }

    func load(now: Date = Date()) throws -> DocumentRecoveryLoadResult {
        try ensureDirectory()
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DocumentRecoveryError.unavailableStorage
        }

        let decoder = JSONDecoder()
        var records: [DocumentRecoveryRecord] = []
        var quarantined = 0
        for url in urls where url.pathExtension == "json" {
            do {
                let record = try decoder.decode(
                    DocumentRecoveryRecord.self,
                    from: Data(contentsOf: url)
                )
                try record.validate()
                if now.timeIntervalSince(record.updatedAt) > retentionInterval {
                    try fileManager.removeItem(at: url)
                } else if try diskContainsExactDocument(record) {
                    try fileManager.removeItem(at: url)
                } else {
                    records.append(record)
                }
            } catch {
                quarantined += 1
                quarantine(url)
            }
        }

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

    func remove(_ id: UUID) throws {
        try ensureDirectory()
        try removeIfPresent(id)
    }

    private func diskContainsExactDocument(_ record: DocumentRecoveryRecord) throws -> Bool {
        guard record.originalURL != nil,
              let lineEnding = MarkdownLineEnding(rawValue: record.lineEndingRawValue),
              !record.requiresLineEndingChoice
        else {
            return false
        }

        let expected: Data
        do {
            expected = try MarkdownCodec.encode(
                record.text,
                properties: MarkdownFileProperties(
                    hasUTF8BOM: record.hasUTF8BOM,
                    lineEnding: lineEnding
                )
            )
        } catch {
            return false
        }
        guard let disk = try? DocumentRecoveryFileAccess.withResolvedURL(
            for: record,
            { try Data(contentsOf: $0, options: [.mappedIfSafe]) }
        ) else {
            return false
        }
        return disk == expected
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw DocumentRecoveryError.unavailableStorage
        }
    }

    private func recordURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func removeIfPresent(_ id: UUID) throws {
        let url = recordURL(id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw DocumentRecoveryError.cannotRemove
        }
    }

    private func quarantine(_ url: URL) {
        let destination = url
            .deletingPathExtension()
            .appendingPathExtension("corrupt-(UUID().uuidString)")
        try? fileManager.moveItem(at: url, to: destination)
    }
}

@MainActor
final class DocumentRecoveryCoordinator: ObservableObject {
    @Published private(set) var recoveredRecords: [DocumentRecoveryRecord] = []
    @Published private(set) var protectionErrorMessage: String?
    @Published private(set) var isLoaded = false

    private struct ActiveSession {
        var latestRecord: DocumentRecoveryRecord
        let task: Task<Void, Never>
    }

    private let store: DocumentRecoveryStore?
    private let intervalNanoseconds: UInt64
    private var activeSessions: [UUID: ActiveSession] = [:]
    private var loadTask: Task<Void, Never>?
    private var hasClaimedAutomaticPresentation = false
    private var isDegradedProtectionWarningDismissed = false

    init(
        rootURL: URL? = nil,
        intervalNanoseconds: UInt64 = 5_000_000_000,
        fileManager: FileManager = .default
    ) {
        self.intervalNanoseconds = intervalNanoseconds
        if let rootURL {
            store = DocumentRecoveryStore(rootURL: rootURL)
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
                    .appendingPathComponent("Recovery", isDirectory: true)
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
        if var existing = activeSessions[record.id] {
            existing.latestRecord = record
            activeSessions[record.id] = existing
            return
        }

        let id = record.id
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
        activeSessions[id] = ActiveSession(latestRecord: record, task: task)
    }

    func flush(_ id: UUID) async {
        guard let record = activeSessions[id]?.latestRecord,
              let store
        else {
            if store == nil {
                showDegradedProtectionWarning()
            }
            return
        }
        do {
            _ = try await store.reconcile(record)
            if activeSessions[id] == nil {
                try await store.remove(id)
            }
            isDegradedProtectionWarningDismissed = false
            protectionErrorMessage = nil
        } catch {
            showDegradedProtectionWarning()
        }
    }

    func close(_ id: UUID) {
        activeSessions.removeValue(forKey: id)?.task.cancel()
        removeRecoveryFileImmediately(id)
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

    private func removeRecoveryFileImmediately(_ id: UUID) {
        guard let rootURL = store?.rootURL else { return }
        let url = rootURL.appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
        try? FileManager.default.removeItem(at: url)
    }

    private func showDegradedProtectionWarning() {
        guard !isDegradedProtectionWarningDismissed else { return }
        protectionErrorMessage = Self.degradedProtectionMessage
    }

    static let degradedProtectionMessage =
        "你仍可以手动保存 Markdown 文件。在保护恢复前，请避免关闭未保存文档。"
}
