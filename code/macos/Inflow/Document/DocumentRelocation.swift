import Foundation

enum MarkdownReferenceKind: String, Sendable {
    case link
    case image

    var displayName: String {
        switch self {
        case .link: "链接"
        case .image: "图片"
        }
    }
}

struct MarkdownReference: Equatable, Sendable {
    let kind: MarkdownReferenceKind
    let target: String
    /// End-exclusive UTF-8 byte range of the complete parsed reference.
    let sourceUTF8Range: Range<Int>
}

enum MarkdownReferenceError: Error, LocalizedError {
    case invalidCoreResult
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .invalidCoreResult: "Markdown 引用扫描结果无效。"
        case .coreFailure: "暂时无法检查 Markdown 中的链接和图片。"
        }
    }
}

enum MarkdownReferenceScanner {
    static func references(in markdown: String) throws -> [MarkdownReference] {
        guard InflowCoreBridge.isCompatible else {
            throw MarkdownReferenceError.coreFailure
        }

        let utf8 = Data(markdown.utf8)
        let result: InflowReferenceResult = utf8.withUnsafeBytes { buffer in
            inflow_document_references(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        defer {
            inflow_owned_references_free(result.references.data, result.references.length)
            inflow_owned_bytes_free(
                result.target_text_utf8.data,
                result.target_text_utf8.length
            )
        }

        guard result.status == INFLOW_STATUS_OK else {
            throw MarkdownReferenceError.coreFailure
        }
        guard let count = Int(exactly: result.references.length),
              count == 0 || result.references.data != nil,
              let targetCount = Int(exactly: result.target_text_utf8.length),
              targetCount == 0 || result.target_text_utf8.data != nil
        else {
            throw MarkdownReferenceError.invalidCoreResult
        }

        let targets = targetCount == 0
            ? Data()
            : Data(bytes: result.target_text_utf8.data!, count: targetCount)
        let rawReferences = UnsafeBufferPointer(
            start: result.references.data,
            count: count
        )

        return try rawReferences.map { raw in
            let kind: MarkdownReferenceKind
            switch raw.kind {
            case UInt8(INFLOW_REFERENCE_KIND_LINK): kind = .link
            case UInt8(INFLOW_REFERENCE_KIND_IMAGE): kind = .image
            default: throw MarkdownReferenceError.invalidCoreResult
            }

            guard let start = Int(exactly: raw.target_start),
                  let length = Int(exactly: raw.target_length),
                  let sourceStart = Int(exactly: raw.source_start),
                  let sourceEnd = Int(exactly: raw.source_end)
            else {
                throw MarkdownReferenceError.invalidCoreResult
            }
            let (end, overflow) = start.addingReportingOverflow(length)
            guard !overflow, start >= 0, end <= targets.count,
                  sourceStart >= 0, sourceStart <= sourceEnd,
                  sourceEnd <= utf8.count,
                  MarkdownSourceRange.navigationTarget(
                      forUTF8Range: sourceStart..<sourceEnd,
                      in: markdown
                  ) != nil,
                  let target = String(data: targets[start..<end], encoding: .utf8)
            else {
                throw MarkdownReferenceError.invalidCoreResult
            }
            return MarkdownReference(
                kind: kind,
                target: target,
                sourceUTF8Range: sourceStart..<sourceEnd
            )
        }
    }
}

enum RelativeResourceDirectoryPolicy {
    static func hasRelativeResources(in markdown: String) -> Bool {
        guard let references = try? MarkdownReferenceScanner.references(in: markdown) else {
            return false
        }
        return hasRelativeResources(in: references)
    }

    static func hasRelativeResources(in references: [MarkdownReference]) -> Bool {
        references.contains { isRelativeResourceTarget($0.target) }
    }

    static func isRelativeResourceTarget(_ target: String) -> Bool {
        guard !target.isEmpty,
              !target.hasPrefix("#"),
              !target.hasPrefix("/"),
              URL(string: target)?.scheme == nil
        else {
            return false
        }
        return true
    }
}

enum DocumentRelocationImpact: String, Sendable {
    case unchanged
    case changed
    case unavailable

    var displayName: String {
        switch self {
        case .unchanged: "仍指向同一资源"
        case .changed: "将指向其他位置"
        case .unavailable: "新位置不可用"
        }
    }
}

private enum RelocationResourceSnapshot: Equatable, Sendable {
    case missing
    case regular(HTMLExportTargetSnapshot)
    case other(isDirectory: Bool, modificationDate: Date?, size: UInt64?)

    static func capture(_ url: URL) throws -> Self {
        do {
            return .regular(try HTMLExportTargetSnapshot.capture(url))
        } catch HTMLExportTargetError.unsupportedTarget {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ])
            return .other(
                isDirectory: values.isDirectory == true,
                modificationDate: values.contentModificationDate,
                size: values.fileSize.map(UInt64.init)
            )
        } catch HTMLExportTargetError.cannotInspect {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw DocumentRelocationError.cannotInspect
            }
            return .missing
        }
    }

    var exists: Bool {
        switch self {
        case .missing: false
        case .regular(let snapshot): snapshot.isExistingTarget
        case .other: true
        }
    }
}

struct DocumentRelocationItem: Identifiable, Sendable {
    let id: UUID
    let reference: MarkdownReference
    let originalURL: URL?
    let relocatedURL: URL
    let impact: DocumentRelocationImpact
    fileprivate let originalSnapshot: RelocationResourceSnapshot?
    fileprivate let relocatedSnapshot: RelocationResourceSnapshot

    fileprivate init(
        reference: MarkdownReference,
        originalURL: URL?,
        relocatedURL: URL,
        impact: DocumentRelocationImpact,
        originalSnapshot: RelocationResourceSnapshot?,
        relocatedSnapshot: RelocationResourceSnapshot
    ) {
        id = UUID()
        self.reference = reference
        self.originalURL = originalURL
        self.relocatedURL = relocatedURL
        self.impact = impact
        self.originalSnapshot = originalSnapshot
        self.relocatedSnapshot = relocatedSnapshot
    }
}

struct DocumentRelocationPlan: Identifiable, Sendable {
    let id: UUID
    let sourceData: Data
    let sourceURL: URL?
    let targetURL: URL
    let targetSnapshot: HTMLExportTargetSnapshot
    let items: [DocumentRelocationItem]

    var changedCount: Int { items.count { $0.impact == .changed } }
    var unavailableCount: Int { items.count { $0.impact == .unavailable } }
    var unchangedCount: Int { items.count { $0.impact == .unchanged } }
    var hasRisk: Bool { changedCount > 0 || unavailableCount > 0 }
}

enum DocumentRelocationError: Error, LocalizedError {
    case staleDecision
    case targetOpen
    case cannotInspect

    var errorDescription: String? {
        switch self {
        case .staleDecision: "文档或目标已变化。请重新检查后再继续。"
        case .targetOpen: "这个文件已在 Inflow 中打开。请切换到该窗口，或选择其他位置。"
        case .cannotInspect: "无法安全检查目标或相关资源，未保存任何内容。"
        }
    }
}

struct DocumentResourceIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func capture(_ url: URL) -> Self? {
        var metadata = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return stat(path, &metadata)
        }
        guard status == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return Self(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }
}

enum DocumentRelocationAnalyzer {
    static func plan(
        markdown: String,
        sourceData: Data,
        sourceURL: URL?,
        targetURL: URL
    ) throws -> DocumentRelocationPlan {
        let sourceDirectory = sourceURL?.standardizedFileURL.deletingLastPathComponent()
        let targetDirectory = targetURL.standardizedFileURL.deletingLastPathComponent()
        let targetSnapshot: HTMLExportTargetSnapshot
        do {
            targetSnapshot = try HTMLExportTargetSnapshot.capture(targetURL)
        } catch {
            throw DocumentRelocationError.cannotInspect
        }

        let references = try MarkdownReferenceScanner.references(in: markdown)
        let items = try references.compactMap { reference -> DocumentRelocationItem? in
            guard let path = relativePath(from: reference.target) else { return nil }
            let oldURL = sourceDirectory?.appendingPathComponent(path).standardizedFileURL
            let newURL = targetDirectory.appendingPathComponent(path).standardizedFileURL
            let oldSnapshot = try oldURL.map(RelocationResourceSnapshot.capture)
            let newSnapshot = try RelocationResourceSnapshot.capture(newURL)
            let impact: DocumentRelocationImpact
            if oldURL == newURL {
                impact = .unchanged
            } else if newSnapshot.exists {
                impact = .changed
            } else {
                impact = .unavailable
            }
            return DocumentRelocationItem(
                reference: reference,
                originalURL: oldURL,
                relocatedURL: newURL,
                impact: impact,
                originalSnapshot: oldSnapshot,
                relocatedSnapshot: newSnapshot
            )
        }

        return DocumentRelocationPlan(
            id: UUID(),
            sourceData: sourceData,
            sourceURL: sourceURL?.standardizedFileURL,
            targetURL: targetURL.standardizedFileURL,
            targetSnapshot: targetSnapshot,
            items: items
        )
    }

    static func verify(
        _ plan: DocumentRelocationPlan,
        currentData: Data,
        currentSourceURL: URL?
    ) throws {
        guard currentData == plan.sourceData,
              currentSourceURL?.standardizedFileURL == plan.sourceURL,
              (try? HTMLExportTargetSnapshot.capture(plan.targetURL)) == plan.targetSnapshot
        else {
            throw DocumentRelocationError.staleDecision
        }
        guard resourcesAreCurrent(plan) else {
            throw DocumentRelocationError.staleDecision
        }
    }

    static func resourcesAreCurrent(_ plan: DocumentRelocationPlan) -> Bool {
        for item in plan.items {
            let originalMatches: Bool
            if let originalURL = item.originalURL {
                originalMatches = (try? RelocationResourceSnapshot.capture(originalURL))
                    == item.originalSnapshot
            } else {
                originalMatches = item.originalSnapshot == nil
            }
            guard originalMatches,
                  (try? RelocationResourceSnapshot.capture(item.relocatedURL))
                    == item.relocatedSnapshot
            else {
                return false
            }
        }
        return true
    }

    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if let leftIdentity = DocumentResourceIdentity.capture(lhs),
           let rightIdentity = DocumentResourceIdentity.capture(rhs)
        {
            return leftIdentity == rightIdentity
        }
        return lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func relativePath(from target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("//"),
              !trimmed.hasPrefix("/")
        else {
            return nil
        }
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            return nil
        }
        let withoutFragment = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init)
            ?? trimmed
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init)
            ?? withoutFragment
        guard !withoutQuery.isEmpty else { return nil }
        return withoutQuery.removingPercentEncoding ?? withoutQuery
    }
}
