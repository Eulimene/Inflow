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

    var modificationDate: Date {
        Date(
            timeIntervalSince1970: TimeInterval(modificationSeconds)
                + TimeInterval(modificationNanoseconds) / 1_000_000_000
        )
    }

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

    /// The change time can move when AppKit attaches bookkeeping metadata to
    /// an otherwise unchanged document. Every identity and content-bearing
    /// field must still match before that new ctime can be accepted.
    fileprivate func hasSameFileAndContentMetadata(as other: Self) -> Bool {
        device == other.device
            && inode == other.inode
            && generation == other.generation
            && size == other.size
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
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

struct ProjectDocumentOpenAuthorization: Equatable, Sendable {
    let targetURL: URL
    let resolvedTargetURL: URL
    let projectRoot: URL
    let projectIdentity: FolderProjectDirectoryIdentity
    let snapshot: PreviewLocalFileSnapshot

    static func capture(targetURL: URL, projectRoot: URL) -> Self? {
        guard let projectIdentity = FolderProjectDirectoryIdentity.capture(projectRoot),
              let resolvedTargetURL = FolderProjectPathBoundary.resolvedURL(
                  targetURL,
                  within: projectRoot
              ),
              let snapshot = try? PreviewLocalFileSnapshot.capture(targetURL)
        else {
            return nil
        }
        return Self(
            targetURL: targetURL.standardizedFileURL,
            resolvedTargetURL: resolvedTargetURL,
            projectRoot: projectIdentity.resolvedURL,
            projectIdentity: projectIdentity,
            snapshot: snapshot
        )
    }

    func isCurrent() -> Bool {
        guard FolderProjectDirectoryIdentity.capture(projectRoot) == projectIdentity,
            let resolvedTarget = FolderProjectPathBoundary.resolvedURL(
            targetURL,
            within: projectRoot
        ),
            resolvedTarget == resolvedTargetURL,
            (try? PreviewLocalFileSnapshot.capture(targetURL)) == snapshot
        else {
            return false
        }
        return true
    }

    /// Re-establishes the exact snapshot after AppKit has created the native
    /// document. A ctime-only metadata update is accepted only when the path,
    /// project, inode, size, modification time, and descriptor-read bytes all
    /// still match the data authorized before opening.
    func refreshedAfterVerifiedRead(expectedData: Data) -> Self? {
        // Finder/AppKit can publish more than one last-used xattr update while
        // a native document is being constructed. Each update changes ctime
        // without changing the file object or its bytes. Retry only that exact
        // case; every attempt revalidates the path, stable content metadata,
        // and descriptor-read bytes, so replacement or content changes still
        // fail closed.
        for _ in 0 ..< 16 {
            guard let refreshed = Self.capture(
                      targetURL: targetURL,
                      projectRoot: projectRoot
                  ),
                  refreshed.projectIdentity == projectIdentity,
                  refreshed.resolvedTargetURL == resolvedTargetURL,
                  snapshot.hasSameFileAndContentMetadata(as: refreshed.snapshot)
            else {
                return nil
            }

            let frozen: FrozenPreviewLocalFile
            do {
                frozen = try PreviewLocalFileReader.read(
                    targetURL,
                    expected: refreshed.snapshot
                )
            } catch PreviewLocalFileError.changedDuringRead {
                guard let retrySnapshot = Self.capture(
                          targetURL: targetURL,
                          projectRoot: projectRoot
                      ),
                      retrySnapshot.projectIdentity == projectIdentity,
                      retrySnapshot.resolvedTargetURL == resolvedTargetURL,
                      snapshot.hasSameFileAndContentMetadata(
                          as: retrySnapshot.snapshot
                      )
                else {
                    return nil
                }
                continue
            } catch {
                return nil
            }

            guard frozen.data == expectedData,
                  let verifiedCurrent = Self.capture(
                      targetURL: targetURL,
                      projectRoot: projectRoot
                  ),
                  verifiedCurrent.projectIdentity == projectIdentity,
                  verifiedCurrent.resolvedTargetURL == resolvedTargetURL,
                  snapshot.hasSameFileAndContentMetadata(
                      as: verifiedCurrent.snapshot
                  )
            else {
                return nil
            }
            if verifiedCurrent.snapshot == refreshed.snapshot {
                return verifiedCurrent
            }
        }
        return nil
    }
}

/// Frozen content plus the most recently verified identity for one project
/// document open. AppKit can perform several ctime-only bookkeeping updates
/// while creating, showing, and activating a native document. Keeping the
/// frozen bytes lets each commit boundary accept only those benign metadata
/// updates while still rejecting replacement or content changes.
struct ProjectDocumentOpenReceipt: Equatable, Sendable {
    let authorization: ProjectDocumentOpenAuthorization
    let expectedData: Data

    static func capture(
        authorization: ProjectDocumentOpenAuthorization
    ) -> Self? {
        guard authorization.isCurrent(),
              let frozen = try? PreviewLocalFileReader.read(
                  authorization.targetURL,
                  expected: authorization.snapshot
              ),
              authorization.isCurrent()
        else {
            return nil
        }
        return Self(
            authorization: authorization,
            expectedData: frozen.data
        )
    }

    func refreshed() -> Self? {
        guard let refreshedAuthorization = authorization.refreshedAfterVerifiedRead(
            expectedData: expectedData
        ) else {
            return nil
        }
        return Self(
            authorization: refreshedAuthorization,
            expectedData: expectedData
        )
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
    private static var protectedManagedCopyPaths: Set<String> = []

    static func startMaintenance() {
        maintenance.start()
    }

    static func materialize(_ file: FrozenPreviewLocalFile, extension pathExtension: String)
        throws -> URL
    {
        try materialize(data: file.data, extension: pathExtension)
    }

    static func materialize(data: Data, extension pathExtension: String) throws -> URL {
        startMaintenance()
        let root = try defaultRootURL()
        try prepareRoot(root)

        var target = root.appendingPathComponent(UUID().uuidString)
        if !pathExtension.isEmpty { target.appendPathExtension(pathExtension) }
        do {
            try data.write(to: target, options: .withoutOverwriting)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableTarget = target
            try mutableTarget.setResourceValues(values)
            // Apply read-only permissions only after setting metadata. APFS
            // can reject the backup-exclusion xattr once the file is 0400.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: target.path
            )
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
    static func discardManagedCopy(at url: URL) -> Bool {
        guard isManagedCopy(url) else {
            return false
        }
        protectedManagedCopyPaths.remove(url.standardizedFileURL.path)
        return unlinkManagedCopy(at: url)
    }

    /// Keeps an AppKit-owned document contents copy out of periodic preview
    /// cleanup. `NSDocumentController.reopenDocument` retains this URL as its
    /// autosaved contents and removes it when the document closes or the copy
    /// becomes obsolete, so unlinking it in the open callback breaks that
    /// lifecycle.
    @discardableResult
    static func protectManagedCopy(at url: URL) -> Bool {
        guard isManagedCopy(url) else { return false }
        protectedManagedCopyPaths.insert(url.standardizedFileURL.path)
        return true
    }

    private static func isManagedCopy(_ url: URL) -> Bool {
        guard let root = try? defaultRootURL(),
              url.deletingLastPathComponent().standardizedFileURL
                  == root.standardizedFileURL,
              UUID(
                  uuidString: url.deletingPathExtension().lastPathComponent
              ) != nil
        else {
            return false
        }
        return true
    }

    @discardableResult
    fileprivate static func cleanupExpiredCopies(
        in root: URL,
        now: Date = Date(),
        retentionInterval: TimeInterval = retentionInterval,
        excluding excludedPaths: Set<String> = []
    ) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var removedCount = 0
        for url in urls {
            guard !excludedPaths.contains(url.standardizedFileURL.path) else {
                continue
            }
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

    fileprivate static func liveProtectedManagedCopyPaths() -> Set<String> {
        protectedManagedCopyPaths = protectedManagedCopyPaths.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        // AppKit may restore documents from autosaved contents before Inflow's
        // own opener has had a chance to rebuild its in-memory protection set.
        // Treat every live native document's managed autosave as protected as
        // well, including copies inherited from a previous process.
        for document in NSDocumentController.shared.documents {
            guard let url = document.autosavedContentsFileURL,
                  isManagedCopy(url),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                continue
            }
            protectedManagedCopyPaths.insert(url.standardizedFileURL.path)
        }
        return protectedManagedCopyPaths
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
    private let excludedPaths: () -> Set<String>
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    init(
        rootURL: URL? = nil,
        retentionInterval: TimeInterval = SafePreviewOpenStore.retentionInterval,
        intervalNanoseconds: UInt64 = SafePreviewOpenStore.cleanupIntervalNanoseconds,
        excludedPaths: @escaping () -> Set<String> = {
            SafePreviewOpenStore.liveProtectedManagedCopyPaths()
        }
    ) {
        self.rootURL = rootURL
        self.retentionInterval = retentionInterval
        self.intervalNanoseconds = intervalNanoseconds
        self.excludedPaths = excludedPaths
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
                retentionInterval: retentionInterval,
                excluding: excludedPaths()
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
    let expectedProjectRootIdentity: FolderProjectDirectoryIdentity?
}

enum PreviewLinkFailureReason: Equatable, Sendable {
    case noLongerInDocument
    case invalidTarget
    case unsupportedScheme
    case localTargetRequiresProject
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

/// A folder selected as a project is the user's authorization boundary for
/// Markdown navigation inside that exact directory identity. Valid internal
/// documents can therefore open directly; destinations that leave the root,
/// change identity, or are not Markdown keep the existing confirmation and
/// failure paths.
enum PreviewLinkActivationPolicy {
    static func opensWithoutConfirmation(_ plan: PreviewLinkPlan) -> Bool {
        guard case let .local(link) = plan.destination else { return false }
        return PreviewLinkPlanner.localTargetIsCurrent(link)
    }
}

actor PreviewLinkWorker {
    func plan(
        markdown: String,
        target: String,
        documentURL: URL?,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil
    ) -> PreviewLinkPlan {
        PreviewLinkPlanner.plan(
            markdown: markdown,
            target: target,
            documentURL: documentURL,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity
        )
    }
}

enum PreviewLinkPlanner {
    private static let maximumTargetBytes = 16 * 1_024

    static func plan(
        markdown: String,
        target: String,
        documentURL: URL?,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil
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
            case "file":
                guard components.host == nil
                        || components.host?.isEmpty == true
                        || components.host == "localhost",
                      components.user == nil,
                      components.password == nil,
                      let path = decodedComponent(
                          components.percentEncodedPath,
                          permitsEmpty: false
                      )
                else {
                    return blocked(
                        sourceUTF8: sourceUTF8,
                        target: target,
                        reason: .invalidTarget,
                        safeTarget: safeTarget
                    )
                }
                let fragment: String?
                if let encodedFragment = components.percentEncodedFragment {
                    guard let decodedFragment = decodedComponent(encodedFragment) else {
                        return blocked(
                            sourceUTF8: sourceUTF8,
                            target: target,
                            reason: .invalidTarget,
                            safeTarget: safeTarget
                        )
                    }
                    fragment = decodedFragment.isEmpty ? nil : decodedFragment
                } else {
                    fragment = nil
                }
                return resolvedLocalPlan(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    url: URL(fileURLWithPath: path).standardizedFileURL,
                    fragment: fragment,
                    documentURL: documentURL,
                    projectRoot: projectRoot,
                    expectedProjectRootIdentity: expectedProjectRootIdentity
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
        return resolvedLocalPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            url: url,
            fragment: parts.fragment,
            documentURL: documentURL,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity
        )
    }

    static func isCurrent(_ plan: PreviewLinkPlan, markdown: String) -> Bool {
        plan.sourceUTF8 == Data(markdown.utf8)
            && containsExactLink(plan.target, in: markdown)
    }

    static func localTargetIsCurrent(_ link: PreviewLocalLink) -> Bool {
        if let projectRoot = link.projectRoot {
            guard projectRootIsCurrent(
                projectRoot,
                expectedIdentity: link.expectedProjectRootIdentity
            ), FolderProjectPathBoundary.resolvedURL(
                link.url,
                within: projectRoot
            ) != nil else {
                return false
            }
        } else if link.expectedProjectRootIdentity != nil {
            return false
        }
        return (try? PreviewLocalFileSnapshot.capture(link.url)) == link.snapshot
    }

    private static func resolvedLocalPlan(
        sourceUTF8: Data,
        target: String,
        url: URL,
        fragment: String?,
        documentURL: URL?,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity?
    ) -> PreviewLinkPlan {
        let normalizedProjectRoot: URL?
        if let projectRoot {
            guard projectRootIsCurrent(
                projectRoot,
                expectedIdentity: expectedProjectRootIdentity
            ), let normalized = try? FolderProjectPathBoundary.normalizedProjectRoot(
                projectRoot
            ) else {
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .outsideProject,
                    safeTarget: safeDisplayTarget(target)
                )
            }
            // A project authorization makes in-root links directly editable.
            // Links outside that root remain valid local links and are handed
            // to Launch Services, just like a link opened from a browser.
            normalizedProjectRoot = FolderProjectPathBoundary.resolvedURL(
                url,
                within: normalized
            ) == nil ? nil : normalized
        } else {
            normalizedProjectRoot = nil
        }

        return localPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            url: url,
            fragment: fragment,
            documentURL: documentURL,
            projectRoot: normalizedProjectRoot,
            expectedProjectRootIdentity: normalizedProjectRoot == nil
                ? nil
                : expectedProjectRootIdentity
        )
    }

    private static func localPlan(
        sourceUTF8: Data,
        target: String,
        url: URL,
        fragment: String?,
        documentURL: URL?,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity?
    ) -> PreviewLinkPlan {
        guard projectRootIsCurrent(
            projectRoot,
            expectedIdentity: expectedProjectRootIdentity
        ) else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .outsideProject,
                safeTarget: safeDisplayTarget(target)
            )
        }
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
        guard projectRootIsCurrent(
            projectRoot,
            expectedIdentity: expectedProjectRootIdentity
        ) else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .outsideProject,
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
                    projectRoot: projectRoot,
                    expectedProjectRootIdentity: expectedProjectRootIdentity
                )
            )
        )
    }

    private static func projectRootIsCurrent(
        _ projectRoot: URL?,
        expectedIdentity: FolderProjectDirectoryIdentity?
    ) -> Bool {
        guard let expectedIdentity else { return true }
        guard let projectRoot else { return false }
        return FolderProjectDirectoryIdentity.capture(projectRoot) == expectedIdentity
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

struct PreviewLinkDecisionView: View {
    let plan: PreviewLinkPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onReveal: (URL) -> Void
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
            if failure.reason == .missingLocalTarget
                || failure.reason == .unavailableLocalTarget
                || failure.reason == .unsupportedScheme
                || failure.reason == .invalidTarget
                || failure.reason == .localTargetRequiresProject
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
                 .localTargetRequiresProject, .relativeTargetNeedsSavedDocument,
                 .outsideProject:
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
            case .localTargetRequiresProject:
                "独立单文件窗口不读取或打开本地路径链接。请通过项目入口打开所属目录后再操作。"
            case .relativeTargetNeedsSavedDocument:
                "未命名文档没有可用于解析相对链接的目录。请先保存文档。"
            case .outsideProject:
                "链接目标在规范化并解析符号链接后不位于当前项目中，因此未读取或打开。"
            case .missingHeading:
                "当前目标文档中没有与\(failure.safeTarget)匹配的标题，因此未移动编辑位置。"
            case .missingLocalTarget:
                "\(failure.safeTarget)不存在、已被移动，或当前位置不可达。"
            case .unavailableLocalTarget:
                "\(failure.safeTarget)已移动、发生变化或当前无法读取。请检查项目中的原路径后重试。"
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
