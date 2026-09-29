import AppKit
import SwiftUI

struct RecoveryDraftPlaceholder: Identifiable, Equatable, Sendable {
    let id: UUID
    let targetID: UUID
    let locations: [URL]
    let title: String
}

enum RecoveryStartupPhase: Equatable {
    case queued, loading, ready, opened, unnecessary
    case failed(String)
}

struct PreparedStartupDraft: Sendable {
    let record: DocumentRecoveryRecord
    let document: MarkdownDocument
}

/// Called only from detached tasks. Discovery reads filenames/metadata, never
/// Markdown bodies. Each subsequent read is independent, so a selected tab can
/// bypass a slow background read without queuing behind the entire workspace.
struct RecoveryStartupLoader: Sendable {
    let recoveryRoot: URL
    let temporaryRoot: URL?
    let witness: DocumentProcessWitness?

    func discover() throws -> [RecoveryDraftPlaceholder] {
        let manager = FileManager.default
        let liveIDs = Set(witness?.liveClaims().flatMap(\.recoveryIDs) ?? [])
        var locations: [UUID: [URL]] = [:]
        var modified: [UUID: Date] = [:]
        for root in [recoveryRoot, temporaryRoot].compactMap({ $0 }) {
            guard manager.fileExists(atPath: root.path) else { continue }
            for file in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                try Task.checkCancellation()
                guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !liveIDs.contains(id) else { continue }
                if root == recoveryRoot && manager.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".closed").path) { continue }
                locations[id, default: []].append(file)
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                modified[id] = max(modified[id] ?? .distantPast, date)
            }
        }
        return locations.keys.sorted {
            let left = modified[$0] ?? .distantPast, right = modified[$1] ?? .distantPast
            return left == right ? $0.uuidString < $1.uuidString : left > right
        }.enumerated().map { offset, id in
            RecoveryDraftPlaceholder(id: id, targetID: UUID(), locations: locations[id] ?? [], title: "恢复草稿 \(offset + 1)")
        }
    }

    private func read(_ file: URL) throws -> DocumentRecoveryRecord {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= DocumentRecoveryStore.Limits.recordBytes else { throw DocumentRecoveryError.invalidRecord }
        let data = try Data(contentsOf: file)
        guard data.count <= DocumentRecoveryStore.Limits.recordBytes else { throw DocumentRecoveryError.invalidRecord }
        let record = try JSONDecoder().decode(DocumentRecoveryRecord.self, from: data)
        try record.validate()
        return record
    }

    func prepare(_ placeholder: RecoveryDraftPlaceholder) throws -> PreparedStartupDraft? {
        try Task.checkCancellation()
        if witness?.isLiveRecovery(placeholder.id) == true { return nil }
        var records: [DocumentRecoveryRecord] = []
        for file in placeholder.locations {
            if let record = try? read(file), record.id == placeholder.id { records.append(record) }
        }
        guard let record = records.max(by: { $0.updatedAt < $1.updatedAt }) else { throw DocumentRecoveryError.invalidRecord }
        if let target = record.transferTargetRecordID {
            if witness?.isLiveRecovery(target) == true { return nil }
            if let targetRecord = try? read(recoveryRoot.appendingPathComponent(target.uuidString + ".json")),
               targetRecord.transferSourceRecordID == record.id { return nil }
        }
        if record.originalURL == nil && record.text.isEmpty { return nil }
        let transfer = DocumentRecoveryTransfer(sourceRecordID: record.id, targetRecordID: placeholder.targetID,
            lineageID: record.effectiveLineageID, sourceEpoch: record.effectiveEpoch,
            targetEpoch: record.effectiveEpoch &+ 1, committedContentHash: record.committedContentHash)
        let document = try record.restoredDocument(transfer: transfer)
        if record.originalURL != nil,
           let disk = try? DocumentRecoveryFileAccess.withResolvedURL(for: record, { try Data(contentsOf: $0) }),
           disk == (try? document.encodedFileData()) { return nil }
        try Task.checkCancellation()
        return PreparedStartupDraft(record: record, document: document)
    }

    func removeImportedCheckpoint(matching record: DocumentRecoveryRecord) throws {
        guard let temporaryRoot else { return }
        let file = temporaryRoot.appendingPathComponent(record.id.uuidString + ".json")
        // Keep a checkpoint that changed after we read it.
        guard let current = try? read(file), current == record else { return }
        try FileManager.default.removeItem(at: file)
    }
}

@MainActor
struct RecoveryPlaceholderView: View {
    @Binding var document: MarkdownDocument
    let placeholder: RecoveryDraftPlaceholder
    @ObservedObject var coordinator: DocumentRecoveryCoordinator
    @State private var window: NSWindow?
    @State private var isInstalling = false

    private var phase: RecoveryStartupPhase { coordinator.startupPhases[placeholder.id] ?? .queued }

    var body: some View {
        VStack(spacing: 12) {
            if case .failed(let message) = phase {
                Image(systemName: "doc.badge.ellipsis").font(.largeTitle)
                Text("暂未载入草稿")
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("重试") { coordinator.retryStartupDraft(placeholder); installIfSelected() }
            } else if phase == .unnecessary {
                Text("这份草稿无需继续载入")
                Text("可以关闭此标签页。").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text(phase == .ready ? "草稿已就绪" : "正在后台载入草稿…")
                Text("可以继续使用其他标签页。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .background(DocumentWindowResolver { resolved in
            if window !== resolved {
                window = resolved
                coordinator.attachStartupWindow(resolved, placeholder: placeholder)
                installIfSelected()
            }
            return true
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
            guard let window, event.object as? NSWindow === window else { return }
            installIfSelected()
        }
        .onChange(of: phase) { _, _ in installIfSelected() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
            if let window, event.object as? NSWindow === window { coordinator.dismissStartupDraft(placeholder.id) }
        }
    }

    private func installIfSelected() {
        guard !isInstalling, window?.isKeyWindow == true, document.recoveryPlaceholder?.id == placeholder.id else { return }
        switch phase { case .failed, .unnecessary, .opened: return; default: break }
        isInstalling = true
        Task { @MainActor in
            defer { isInstalling = false }
            guard let restored = await coordinator.materializeStartupDraft(placeholder),
                  window?.isKeyWindow == true, document.recoveryPlaceholder?.id == placeholder.id else { return }
            document = restored
            coordinator.completeStartupDraft(placeholder.id)
        }
    }
}
