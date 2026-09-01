import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

enum PreviewLocalLinkKind: String, Equatable, Sendable {
    case markdown
    case image
    case pdf
    case attachment
}

enum PreviewLocalMarkdownPrompt {
    static let safeCopyMessage =
        "Inflow 会读取当前已确认的文件内容，并以未命名安全副本打开；"
        + "这个副本不会继续关联或写回原文件。有标题片段时会精确定位。"
    static let projectMessage =
        "确认后将在当前项目中切换到这份 Markdown 原文件，修改可由你手动保存回原路径。"
        + "当前文档有未保存修改时，切换前会询问保存、不保存或取消。"
    static let message = safeCopyMessage
    static let confirmTitle = "打开安全副本"

    static func message(for link: PreviewLocalLink) -> String {
        link.projectRoot == nil ? safeCopyMessage : projectMessage
    }

    static func confirmTitle(for link: PreviewLocalLink) -> String {
        link.projectRoot == nil ? "打开安全副本" : "在项目中打开"
    }
}

@MainActor
enum LinkedHeadingNavigationBroker {
    static let didRequestNavigation = Notification.Name(
        "Inflow.LinkedHeadingNavigationRequested"
    )

    private static var pendingFragments: [String: String] = [:]

    static func request(documentURL: URL, fragment: String?) {
        guard let fragment, !fragment.isEmpty else { return }
        let path = documentURL.standardizedFileURL.path
        pendingFragments[path] = fragment
        NotificationCenter.default.post(name: didRequestNavigation, object: path)
    }

    static func consume(for documentURL: URL) -> String? {
        pendingFragments.removeValue(forKey: documentURL.standardizedFileURL.path)
    }
}

struct PreviewLocalFileSnapshot: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    static func capture(_ url: URL) throws -> Self {
        var metadata = stat()
        errno = 0
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0 else {
            if errno == ENOENT {
                throw PreviewLocalFileError.missing
            }
            throw PreviewLocalFileError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw PreviewLocalFileError.notRegularFile
        }
        return Self(metadata: metadata)
    }

    fileprivate init(metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = metadata.st_ino
        generation = metadata.st_gen
        changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        size = metadata.st_size
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    }
}

enum PreviewLocalFileError: Error, Equatable, Sendable {
    case missing
    case unavailable
    case notRegularFile
    case unsafeContent
    case changedDuringRead
    case tooLarge
}

struct FrozenPreviewLocalFile: Equatable, Sendable {
    let data: Data
    let snapshot: PreviewLocalFileSnapshot
}

enum PreviewLocalFileReader {
    static let maximumBytes = 256 * 1_024 * 1_024

    static func read(
        _ url: URL,
        expected: PreviewLocalFileSnapshot,
        maximumBytes: Int = maximumBytes
    ) throws -> FrozenPreviewLocalFile {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw PreviewLocalFileError.unavailable }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              PreviewLocalFileSnapshot(metadata: before) == expected,
              before.st_size >= 0,
              before.st_size <= maximumBytes
        else {
            throw before.st_size > maximumBytes
                ? PreviewLocalFileError.tooLarge
                : PreviewLocalFileError.changedDuringRead
        }

        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PreviewLocalFileError.unavailable
            }
            guard result.count <= maximumBytes - count else {
                throw PreviewLocalFileError.tooLarge
            }
            result.append(contentsOf: buffer.prefix(count))
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              PreviewLocalFileSnapshot(metadata: after) == expected,
              result.count == Int(after.st_size)
        else {
            throw PreviewLocalFileError.changedDuringRead
        }
        return FrozenPreviewLocalFile(data: result, snapshot: expected)
    }
}

enum FrozenPreviewMarkdownDocument {
    static func make(data: Data, headingFragment: String?) throws -> MarkdownDocument {
        var document = try MarkdownDocument(fileData: data)
        document.openedFileData = nil
        document.initialHeadingFragment = headingFragment
        return document
    }
}

@MainActor
enum SafePreviewOpenStore {
    nonisolated static let retentionInterval: TimeInterval = 60 * 60
    nonisolated static let cleanupIntervalNanoseconds: UInt64 = 15 * 60 * 1_000_000_000

    private static let maintenance = SafePreviewOpenMaintenance()

    static func startMaintenance() {
        maintenance.start()
    }

    static func materialize(_ file: FrozenPreviewLocalFile, extension pathExtension: String)
        throws -> URL
    {
        startMaintenance()
        let root = try defaultRootURL()
        try prepareRoot(root)

        var target = root.appendingPathComponent(UUID().uuidString)
        if !pathExtension.isEmpty { target.appendPathExtension(pathExtension) }
        do {
            try file.data.write(to: target, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: target.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableTarget = target
            try mutableTarget.setResourceValues(values)
            return target
        } catch {
            unlinkManagedCopy(at: target)
            throw error
        }
    }

    fileprivate static func defaultRootURL() throws -> URL {
        try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Inflow", isDirectory: true)
        .appendingPathComponent("SafeOpen", isDirectory: true)
    }

    fileprivate static func prepareRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var metadata = stat()
        let status = root.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw PreviewLocalFileError.unavailable
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
    }

    @discardableResult
    fileprivate static func cleanupExpiredCopies(
        in root: URL,
        now: Date = Date(),
        retentionInterval: TimeInterval = retentionInterval
    ) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var removedCount = 0
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: stem) != nil else { continue }

            var metadata = stat()
            let status = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &metadata)
            }
            guard status == 0, metadata.st_mode & S_IFMT == S_IFREG else { continue }

            let modificationTime = Date(
                timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                    + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            guard now.timeIntervalSince(modificationTime) > retentionInterval else { continue }
            if unlinkManagedCopy(at: url) {
                removedCount += 1
            }
        }
        return removedCount
    }

    @discardableResult
    private static func unlinkManagedCopy(at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.unlink(path) == 0
        }
    }
}

@MainActor
final class SafePreviewOpenMaintenance {
    private let rootURL: URL?
    private let retentionInterval: TimeInterval
    private let intervalNanoseconds: UInt64
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    init(
        rootURL: URL? = nil,
        retentionInterval: TimeInterval = SafePreviewOpenStore.retentionInterval,
        intervalNanoseconds: UInt64 = SafePreviewOpenStore.cleanupIntervalNanoseconds
    ) {
        self.rootURL = rootURL
        self.retentionInterval = retentionInterval
        self.intervalNanoseconds = intervalNanoseconds
    }

    func start() {
        guard task == nil else { return }
        cleanupNow()

        let intervalNanoseconds = max(intervalNanoseconds, 1)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.cleanupNow()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }

    private func cleanupNow() {
        do {
            let root = try rootURL ?? SafePreviewOpenStore.defaultRootURL()
            try SafePreviewOpenStore.prepareRoot(root)
            SafePreviewOpenStore.cleanupExpiredCopies(
                in: root,
                retentionInterval: retentionInterval
            )
        } catch {
            // Maintenance is best effort. A later period or materialization retries it.
        }
    }
}

struct PreviewExternalLink: Equatable, Sendable {
    let url: URL
    let displayDestination: String
}

struct PreviewLocalLink: Equatable, Sendable {
    let url: URL
    let fragment: String?
    let kind: PreviewLocalLinkKind
    let snapshot: PreviewLocalFileSnapshot
    let projectRoot: URL?
}

enum PreviewLinkFailureReason: Equatable, Sendable {
    case noLongerInDocument
    case invalidTarget
    case unsupportedScheme
    case relativeTargetNeedsSavedDocument
    case outsideProject
    case missingHeading
    case missingLocalTarget
    case unavailableLocalTarget
    case unsafeLocalTarget
    case cannotOpen
}

struct PreviewLinkFailure: Equatable, Sendable {
    let reason: PreviewLinkFailureReason
    let safeTarget: String
    let expectedURL: URL?
}

enum PreviewLinkDestination: Equatable, Sendable {
    case currentDocument(fragment: String?)
    case external(PreviewExternalLink)
    case local(PreviewLocalLink)
    case blocked(PreviewLinkFailure)
}

struct PreviewLinkPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceUTF8: Data
    let target: String
    let destination: PreviewLinkDestination

    init(sourceUTF8: Data, target: String, destination: PreviewLinkDestination) {
        id = UUID()
        self.sourceUTF8 = sourceUTF8
        self.target = target
        self.destination = destination
    }
}

actor PreviewLinkWorker {
    func plan(
        markdown: String,
        target: String,
        documentURL: URL?,
        projectRoot: URL? = nil
    ) -> PreviewLinkPlan {
        PreviewLinkPlanner.plan(
            markdown: markdown,
            target: target,
            documentURL: documentURL,
            projectRoot: projectRoot
        )
    }
}

enum PreviewLinkPlanner {
    private static let maximumTargetBytes = 16 * 1_024

    static func plan(
        markdown: String,
        target: String,
        documentURL: URL?,
        projectRoot: URL? = nil
    ) -> PreviewLinkPlan {
        let sourceUTF8 = Data(markdown.utf8)
        let safeTarget = safeDisplayTarget(target)
        let decodedTarget = target.removingPercentEncoding
        guard target.utf8.count <= maximumTargetBytes,
              let decodedTarget,
              !target.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
              }),
              !decodedTarget.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
              })
        else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .invalidTarget,
                safeTarget: safeTarget
            )
        }
        guard containsExactLink(target, in: markdown) else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .noLongerInDocument,
                safeTarget: safeTarget
            )
        }

        if target.isEmpty {
            return PreviewLinkPlan(
                sourceUTF8: sourceUTF8,
                target: target,
                destination: .currentDocument(fragment: nil)
            )
        }
        if target.hasPrefix("#") {
            guard let fragment = decodedComponent(String(target.dropFirst())) else {
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .invalidTarget,
                    safeTarget: safeTarget
                )
            }
            return PreviewLinkPlan(
                sourceUTF8: sourceUTF8,
                target: target,
                destination: .currentDocument(fragment: fragment.isEmpty ? nil : fragment)
            )
        }

        if let components = URLComponents(string: target),
           let scheme = components.scheme?.lowercased()
        {
            switch scheme {
            case "http", "https":
                guard components.host?.isEmpty == false,
                      components.user == nil,
                      components.password == nil,
                      let url = components.url
                else {
                    return blocked(
                        sourceUTF8: sourceUTF8,
                        target: target,
                        reason: .invalidTarget,
                        safeTarget: safeTarget
                    )
                }
                return PreviewLinkPlan(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    destination: .external(
                        PreviewExternalLink(
                            url: url,
                            displayDestination: components.host ?? "默认浏览器"
                        )
                    )
                )
            default:
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .unsupportedScheme,
                    safeTarget: safeTarget
                )
            }
        }

        guard !target.hasPrefix("//"),
              let parts = localParts(target),
              !parts.path.isEmpty
        else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .invalidTarget,
                safeTarget: safeTarget
            )
        }
        let url: URL
        if parts.path.hasPrefix("/") {
            url = URL(fileURLWithPath: parts.path).standardizedFileURL
        } else {
            guard let documentURL else {
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .relativeTargetNeedsSavedDocument,
                    safeTarget: safeTarget
                )
            }
            url = URL(
                fileURLWithPath: parts.path,
                relativeTo: documentURL.deletingLastPathComponent()
            ).standardizedFileURL
        }
        let normalizedProjectRoot: URL?
        if let projectRoot {
            do {
                normalizedProjectRoot = try FolderProjectPathBoundary.normalizedProjectRoot(
                    projectRoot
                )
            } catch {
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .outsideProject,
                    safeTarget: safeTarget
                )
            }
            guard let normalizedProjectRoot,
                  FolderProjectPathBoundary.resolvedURL(
                      url,
                      within: normalizedProjectRoot
                  ) != nil,
                  documentURL.map({
                      FolderProjectPathBoundary.resolvedURL(
                          $0,
                          within: normalizedProjectRoot
                      ) != nil
                  }) ?? true
            else {
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .outsideProject,
                    safeTarget: safeTarget
                )
            }
        } else {
            normalizedProjectRoot = nil
        }

        return localPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            url: url,
            fragment: parts.fragment,
            documentURL: documentURL,
            projectRoot: normalizedProjectRoot
        )
    }

    static func isCurrent(_ plan: PreviewLinkPlan, markdown: String) -> Bool {
        plan.sourceUTF8 == Data(markdown.utf8)
            && containsExactLink(plan.target, in: markdown)
    }

    static func localTargetIsCurrent(_ link: PreviewLocalLink) -> Bool {
        if let projectRoot = link.projectRoot,
           FolderProjectPathBoundary.resolvedURL(link.url, within: projectRoot) == nil
        {
            return false
        }
        return (try? PreviewLocalFileSnapshot.capture(link.url)) == link.snapshot
    }

    private static func localPlan(
        sourceUTF8: Data,
        target: String,
        url: URL,
        fragment: String?,
        documentURL: URL?,
        projectRoot: URL?
    ) -> PreviewLinkPlan {
        if let documentURL,
           url.standardizedFileURL.path == documentURL.standardizedFileURL.path
        {
            return PreviewLinkPlan(
                sourceUTF8: sourceUTF8,
                target: target,
                destination: .currentDocument(fragment: fragment)
            )
        }

        let safeTarget = url.lastPathComponent.isEmpty ? "该本地目标" : url.lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let snapshot: PreviewLocalFileSnapshot
        do {
            snapshot = try PreviewLocalFileSnapshot.capture(url)
        } catch PreviewLocalFileError.missing {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .missingLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        } catch PreviewLocalFileError.notRegularFile {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .unsafeLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        } catch {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .unavailableLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        }

        let kind = localKind(for: url)
        if projectRoot != nil, kind == .attachment {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .unsupportedScheme,
                safeTarget: safeTarget
            )
        }
        do {
            switch kind {
            case .image:
                _ = try LocalImageValidator.load(at: url)
            case .pdf:
                guard let document = CGPDFDocument(url as CFURL),
                      document.numberOfPages > 0
                else {
                    throw PreviewLocalFileError.unsafeContent
                }
            case .markdown, .attachment:
                break
            }
            guard try PreviewLocalFileSnapshot.capture(url) == snapshot else {
                throw PreviewLocalFileError.unavailable
            }
        } catch {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .unsafeLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        }

        return PreviewLinkPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            destination: .local(
                PreviewLocalLink(
                    url: url,
                    fragment: fragment,
                    kind: kind,
                    snapshot: snapshot,
                    projectRoot: projectRoot
                )
            )
        )
    }

    private static func containsExactLink(_ target: String, in markdown: String) -> Bool {
        guard let references = try? MarkdownReferenceScanner.references(in: markdown) else {
            return false
        }
        let targetUTF8 = Data(target.utf8)
        return references.contains {
            $0.kind == .link && Data($0.target.utf8) == targetUTF8
        }
    }

    private static func localKind(for url: URL) -> PreviewLocalLinkKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "png", "jpg", "jpeg": .image
        case "pdf": .pdf
        default: .attachment
        }
    }

    private static func localParts(_ target: String) -> (path: String, fragment: String?)? {
        let beforeFragment: Substring
        let encodedFragment: Substring?
        if let hash = target.firstIndex(of: "#") {
            beforeFragment = target[..<hash]
            encodedFragment = target[target.index(after: hash)...]
        } else {
            beforeFragment = Substring(target)
            encodedFragment = nil
        }
        guard !beforeFragment.contains("?"),
              let path = decodedComponent(String(beforeFragment), permitsEmpty: false)
        else {
            return nil
        }
        let fragment: String?
        if let encodedFragment {
            guard let decoded = decodedComponent(String(encodedFragment)) else { return nil }
            fragment = decoded.isEmpty ? nil : decoded
        } else {
            fragment = nil
        }
        return (path, fragment?.isEmpty == true ? nil : fragment)
    }

    private static func decodedComponent(
        _ encoded: String?,
        permitsEmpty: Bool = true
    ) -> String? {
        guard let encoded else { return nil }
        guard permitsEmpty || !encoded.isEmpty,
              let decoded = encoded.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
              })
        else {
            return nil
        }
        return decoded.precomposedStringWithCanonicalMapping
    }

    private static func safeDisplayTarget(_ target: String) -> String {
        guard !target.isEmpty else { return "当前文档顶部" }
        if target.hasPrefix("#") {
            let fragment = String(target.dropFirst()).removingPercentEncoding ?? ""
            return fragment.isEmpty ? "当前文档顶部" : "标题“\(fragment.prefix(80))”"
        }
        if let components = URLComponents(string: target), let scheme = components.scheme {
            if scheme.lowercased() == "http" || scheme.lowercased() == "https" {
                return components.host ?? "网页链接"
            }
            if scheme.lowercased() == "mailto" { return "邮件链接" }
        }
        let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        let name = URL(fileURLWithPath: path.removingPercentEncoding ?? path).lastPathComponent
        return name.isEmpty ? "该链接" : String(name.prefix(120))
    }

    private static func blocked(
        sourceUTF8: Data,
        target: String,
        reason: PreviewLinkFailureReason,
        safeTarget: String,
        expectedURL: URL? = nil
    ) -> PreviewLinkPlan {
        PreviewLinkPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            destination: .blocked(
                PreviewLinkFailure(
                    reason: reason,
                    safeTarget: safeTarget,
                    expectedURL: expectedURL
                )
            )
        )
    }
}

enum HeadingIdentifier {
    static func base(for headingText: String) -> String {
        let normalized = headingText
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .precomposedStringWithCanonicalMapping
        var identifier = ""

        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                identifier.unicodeScalars.append(scalar)
            } else if scalar == "-" || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                guard !identifier.isEmpty, identifier.last != "-" else { continue }
                identifier.append("-")
            }
        }

        while identifier.last == "-" {
            identifier.removeLast()
        }
        return identifier.isEmpty ? "section" : identifier
    }

    static func identifiers(for headings: [DocumentHeading]) -> [String] {
        var duplicateCounts: [String: Int] = [:]
        return headings.map { heading in
            let base = base(for: heading.title)
            let duplicate = duplicateCounts[base, default: 0]
            duplicateCounts[base] = duplicate + 1
            return duplicate == 0 ? base : "\(base)-\(duplicate)"
        }
    }
}

enum PreviewHeadingAnchorResolver {
    static func heading(for fragment: String, in headings: [DocumentHeading]) -> DocumentHeading? {
        // URL policy decodes the raw fragment exactly once. This resolver accepts
        // only that decoded value and performs an exact match against generated IDs.
        for (heading, identifier) in zip(headings, HeadingIdentifier.identifiers(for: headings)) {
            if identifier == fragment {
                return heading
            }
        }
        return nil
    }
}

@MainActor
enum PreviewLinkAuthorization {
    static func chooseExactTarget(_ expectedURL: URL, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "重新授权链接目标"
        panel.message = "请选择同一文件。选择其他路径不会改写 Markdown 链接。"
        panel.prompt = "重新授权并打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = expectedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = expectedURL.lastPathComponent

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK,
              let chosen = panel.url,
              chosen.standardizedFileURL.path == expectedURL.standardizedFileURL.path
        else {
            return nil
        }
        return chosen
    }
}

struct PreviewLinkDecisionView: View {
    let plan: PreviewLinkPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onReveal: (URL) -> Void
    let onReauthorize: (URL) -> Void
    let onCopyTarget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityLabel("链接目标")
            }
            Spacer(minLength: 0)
            HStack {
                secondaryActions
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if showsConfirm {
                    Button(confirmTitle, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 250)
    }

    @ViewBuilder
    private var secondaryActions: some View {
        switch plan.destination {
        case let .local(link):
            Button("在 Finder 中显示") { onReveal(link.url) }
        case let .blocked(failure):
            if let url = failure.expectedURL,
               failure.reason == .missingLocalTarget
                    || failure.reason == .unavailableLocalTarget
            {
                Button("重新授权…") { onReauthorize(url) }
            } else if failure.reason == .unsupportedScheme
                || failure.reason == .invalidTarget
                || failure.reason == .outsideProject
                || failure.reason == .unsafeLocalTarget
                || failure.reason == .cannotOpen
            {
                Button("复制链接文本", action: onCopyTarget)
            }
        case .currentDocument, .external:
            EmptyView()
        }
    }

    private var title: String {
        switch plan.destination {
        case .external: "在 Inflow 外打开链接？"
        case let .local(link):
            link.kind == .attachment ? "这个附件只在 Finder 中显示" : "打开本地目标？"
        case .currentDocument: "定位当前文档"
        case let .blocked(failure):
            switch failure.reason {
            case .missingHeading, .missingLocalTarget, .unavailableLocalTarget:
                "找不到链接目标"
            case .noLongerInDocument: "预览链接已过期"
            case .invalidTarget, .unsupportedScheme, .unsafeLocalTarget, .cannotOpen,
                 .relativeTargetNeedsSavedDocument, .outsideProject:
                "为安全起见，未打开这个链接"
            }
        }
    }

    private var icon: String {
        switch plan.destination {
        case .external: "arrow.up.right.square"
        case let .local(link):
            switch link.kind {
            case .markdown: "doc.text"
            case .image: "photo"
            case .pdf: "doc.richtext"
            case .attachment: "paperclip"
            }
        case .currentDocument: "text.append"
        case .blocked: "exclamationmark.triangle"
        }
    }

    private var message: String {
        switch plan.destination {
        case let .external(link):
            "这是一次由你发起的外部操作。Inflow 不会上传正文；确认后只会把该链接交给\(link.displayDestination)。"
        case let .local(link):
            switch link.kind {
            case .markdown:
                PreviewLocalMarkdownPrompt.message(for: link)
            case .image, .pdf:
                "目标已校验为受支持的本地文件。确认后将交给系统默认应用。"
            case .attachment:
                "首发版不直接打开这种附件；可以在 Finder 中显示后再由你决定。"
            }
        case .currentDocument:
            "将在当前文档中定位，不会打开外部应用。"
        case let .blocked(failure):
            switch failure.reason {
            case .noLongerInDocument:
                "当前 Markdown 已不再包含你点击的链接，因此不会沿用旧预览结果。"
            case .invalidTarget, .unsupportedScheme:
                "链接类型不受支持或无法安全确认。"
            case .relativeTargetNeedsSavedDocument:
                "未命名文档没有可用于解析相对链接的目录。请先保存文档。"
            case .outsideProject:
                "链接目标在规范化并解析符号链接后不位于当前项目中，因此未读取或打开。"
            case .missingHeading:
                "当前目标文档中没有与\(failure.safeTarget)匹配的标题，因此未移动编辑位置。"
            case .missingLocalTarget:
                "\(failure.safeTarget)不存在、已被移动，或当前位置不可达。"
            case .unavailableLocalTarget:
                "\(failure.safeTarget)当前未授权或无法读取。重新授权时必须选择同一路径。"
            case .unsafeLocalTarget:
                "\(failure.safeTarget)不是可信的普通文件，或其内容与声明类型不一致。"
            case .cannotOpen:
                "系统未能打开\(failure.safeTarget)。当前 Markdown 和编辑位置保持不变。"
            }
        }
    }

    private var detail: String? {
        switch plan.destination {
        case let .external(link): link.url.absoluteString
        case let .local(link): link.url.lastPathComponent
        case let .blocked(failure): failure.safeTarget
        case .currentDocument: nil
        }
    }

    private var showsConfirm: Bool {
        switch plan.destination {
        case .external: true
        case let .local(link): link.kind != .attachment
        case .currentDocument, .blocked: false
        }
    }

    private var confirmTitle: String {
        switch plan.destination {
        case let .local(link) where link.kind == .markdown:
            PreviewLocalMarkdownPrompt.confirmTitle(for: link)
        case .external: "继续打开"
        default: "打开"
        }
    }
}
