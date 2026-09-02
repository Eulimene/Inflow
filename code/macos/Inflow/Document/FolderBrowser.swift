import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

enum InflowLaunchPolicy {
    /// Launch directly into an editable untitled Markdown document. Creating
    /// the document does not present a file panel; the user chooses a path on
    /// the first explicit save.
    static let presentsEditableDocumentFirst = true
    /// The app delegate owns cold-launch document creation explicitly. Letting
    /// AppKit infer the launch action can route a document-based SwiftUI app to
    /// its Open panel on some launch paths.
    static let letsAppKitOpenUntitledDocument = false

    static func shouldCreateInitialDocument(
        hasReceivedExternalOpenRequest: Bool,
        hasOpenDocuments: Bool
    ) -> Bool {
        presentsEditableDocumentFirst
            && !hasReceivedExternalOpenRequest
            && !hasOpenDocuments
    }

    static func shouldFocusFreshUntitledDocument(
        fileURL: URL?,
        text: String,
        hasRestorationState: Bool,
        isEditable: Bool
    ) -> Bool {
        fileURL == nil
            && text.isEmpty
            && !hasRestorationState
            && isEditable
    }
}

enum FolderBrowserPolicy {
    static let recordKey = "documents.folderBrowser.record.v1"
    static let supportedExtensions: Set<String> = ["md", "markdown"]
    static let maximumFileCount = 20_000
}

/// Captures both the resolved path and the underlying directory object so a
/// user decision made against one project cannot be committed into a
/// same-named replacement directory.
struct FolderProjectDirectoryIdentity: Equatable, Sendable {
    let resolvedURL: URL
    let device: UInt64
    let inode: UInt64
    let generation: UInt32

    static func capture(_ url: URL) -> Self? {
        let resolvedURL = FolderProjectPathBoundary.normalizedResolvedURL(url)
        var metadata = stat()
        let result = resolvedURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard result == 0,
              metadata.st_mode & S_IFMT == S_IFDIR
        else { return nil }
        return Self(
            resolvedURL: resolvedURL,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            generation: metadata.st_gen
        )
    }

    func matches(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR
            && UInt64(metadata.st_dev) == device
            && UInt64(metadata.st_ino) == inode
            && metadata.st_gen == generation
    }
}

struct FolderBrowserRecord: Codable, Equatable, Sendable {
    let exactPath: String
    let bookmark: Data?
}

@MainActor
protocol FolderBrowserPersistence: AnyObject {
    func load() -> FolderBrowserRecord?
    func save(_ record: FolderBrowserRecord?)
}

@MainActor
final class UserDefaultsFolderBrowserPersistence: FolderBrowserPersistence {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = FolderBrowserPolicy.recordKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> FolderBrowserRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FolderBrowserRecord.self, from: data)
    }

    func save(_ record: FolderBrowserRecord?) {
        guard let record else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }
}

struct FolderMarkdownFile: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String

    var id: String { relativePath }
    var displayName: String { url.lastPathComponent }

    var parentPath: String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }
}

struct FolderProjectItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
    }

    let url: URL
    let relativePath: String
    let kind: Kind
    let children: [FolderProjectItem]?

    var id: String { relativePath }
    var displayName: String { url.lastPathComponent }
    var isDirectory: Bool { kind == .directory }
    var isMarkdown: Bool {
        kind == .file
            && FolderBrowserPolicy.supportedExtensions.contains(
                url.pathExtension.lowercased()
            )
    }

    var markdownFile: FolderMarkdownFile? {
        guard isMarkdown else { return nil }
        return FolderMarkdownFile(url: url, relativePath: relativePath)
    }

    init(
        url: URL,
        relativePath: String,
        kind: Kind,
        children: [FolderProjectItem]? = nil
    ) {
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
        self.children = kind == .directory ? (children ?? []) : nil
    }

    func item(withID id: String) -> FolderProjectItem? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let match = child.item(withID: id) { return match }
        }
        return nil
    }
}

enum FolderBrowserActivation {
    static func markdownURL(
        forSelectedItemID selectedItemID: String?,
        in items: [FolderProjectItem]
    ) -> URL? {
        guard let selectedItemID else { return nil }
        for item in items {
            if let match = item.item(withID: selectedItemID) {
                return match.markdownFile?.url
            }
        }
        return nil
    }
}

struct FolderContentSnapshot: Equatable, Sendable {
    let items: [FolderProjectItem]
    let markdownFiles: [FolderMarkdownFile]
}

struct FolderProjectOpenPreparation: Equatable, Sendable {
    let rootURL: URL
    let rootIdentity: FolderProjectDirectoryIdentity
    let snapshot: FolderContentSnapshot
}

enum FolderBrowserError: Error, Equatable, LocalizedError {
    case unavailable
    case tooManyMarkdownFiles(limit: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "这个文件夹当前不可读取。请重新选择文件夹并确认访问权限。"
        case let .tooManyMarkdownFiles(limit):
            "这个文件夹包含超过 \(limit) 个文件。为避免界面失去响应，本次没有载入。"
        }
    }
}

enum FolderProjectPathBoundary {
    static func normalizedResolvedURL(_ url: URL) -> URL {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func normalizedProjectRoot(
        _ rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard rootURL.isFileURL else { throw FolderBrowserError.unavailable }
        let root = normalizedResolvedURL(rootURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw FolderBrowserError.unavailable
        }
        return root
    }

    static func contains(_ candidateURL: URL, in rootURL: URL) -> Bool {
        guard candidateURL.isFileURL, rootURL.isFileURL else { return false }
        let root = normalizedResolvedURL(rootURL)
        let candidate = normalizedResolvedURL(candidateURL)
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func resolvedURL(_ candidateURL: URL, within rootURL: URL) -> URL? {
        let candidate = normalizedResolvedURL(candidateURL)
        return contains(candidate, in: rootURL) ? candidate : nil
    }

    static func relativeComponents(of candidateURL: URL, in rootURL: URL) -> [String]? {
        let root = normalizedResolvedURL(rootURL)
        let candidate = normalizedResolvedURL(candidateURL)
        guard contains(candidate, in: root) else { return nil }
        return Array(candidate.pathComponents.dropFirst(root.pathComponents.count))
    }
}

enum FolderContentScanner {
    /// Test-only observation point used to replace a directory after its
    /// no-follow metadata check and before `openat`. Production callers leave
    /// this nil. Keeping the hook as an argument avoids shared mutable state.
    typealias BeforeOpeningDirectory = (_ directoryURL: URL) throws -> Void

    static func scan(
        _ rootURL: URL,
        fileManager: FileManager = .default,
        maximumFileCount: Int = FolderBrowserPolicy.maximumFileCount
    ) throws -> [FolderMarkdownFile] {
        try snapshot(
            rootURL,
            fileManager: fileManager,
            maximumFileCount: maximumFileCount
        ).markdownFiles
    }

    static func scanTree(
        _ rootURL: URL,
        fileManager: FileManager = .default,
        maximumFileCount: Int = FolderBrowserPolicy.maximumFileCount
    ) throws -> [FolderProjectItem] {
        try snapshot(
            rootURL,
            fileManager: fileManager,
            maximumFileCount: maximumFileCount
        ).items
    }

    static func snapshot(
        _ rootURL: URL,
        fileManager: FileManager = .default,
        maximumFileCount: Int = FolderBrowserPolicy.maximumFileCount,
        expectedRootIdentity: FolderProjectDirectoryIdentity? = nil,
        beforeOpeningDirectory: BeforeOpeningDirectory? = nil
    ) throws -> FolderContentSnapshot {
        let root = try FolderProjectPathBoundary.normalizedProjectRoot(
            rootURL,
            fileManager: fileManager
        )
        guard let capturedRootIdentity = FolderProjectDirectoryIdentity.capture(root) else {
            throw FolderBrowserError.unavailable
        }
        let rootIdentity = expectedRootIdentity ?? capturedRootIdentity
        guard rootIdentity.resolvedURL == root else {
            throw FolderBrowserError.unavailable
        }

        try beforeOpeningDirectory?(root)
        let rootDescriptor = root.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else { throw FolderBrowserError.unavailable }
        defer { Darwin.close(rootDescriptor) }

        var openedRootMetadata = stat()
        guard Darwin.fstat(rootDescriptor, &openedRootMetadata) == 0,
              rootIdentity.matches(openedRootMetadata)
        else {
            throw FolderBrowserError.unavailable
        }

        var fileCount = 0
        var markdownFiles: [FolderMarkdownFile] = []

        func readDirectory(
            descriptor: Int32,
            directoryURL: URL,
            relativePath: String?
        ) throws
            -> [FolderProjectItem]
        {
            try Task.checkCancellation()
            let enumerationDescriptor = Darwin.fcntl(
                descriptor,
                F_DUPFD_CLOEXEC,
                0
            )
            guard enumerationDescriptor >= 0 else {
                throw FolderBrowserError.unavailable
            }
            guard let directoryStream = Darwin.fdopendir(enumerationDescriptor) else {
                Darwin.close(enumerationDescriptor)
                throw FolderBrowserError.unavailable
            }
            defer { Darwin.closedir(directoryStream) }

            var items: [FolderProjectItem] = []
            errno = 0
            while let entry = Darwin.readdir(directoryStream) {
                try Task.checkCancellation()
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(MAXNAMLEN) + 1
                    ) {
                        String(validatingCString: $0)
                    }
                }
                guard let name else {
                    throw FolderBrowserError.unavailable
                }
                guard name != ".", name != "..", !name.hasPrefix(".") else {
                    continue
                }

                var metadata = stat()
                let metadataResult = name.withCString { namePointer in
                    Darwin.fstatat(
                        descriptor,
                        namePointer,
                        &metadata,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard metadataResult == 0 else {
                    throw FolderBrowserError.unavailable
                }
                guard metadata.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }

                let fileType = metadata.st_mode & S_IFMT
                guard fileType != S_IFLNK else { continue }

                let itemRelativePath = [relativePath, name]
                    .compactMap { $0 }
                    .joined(separator: "/")
                let item = directoryURL
                    .appendingPathComponent(name, isDirectory: fileType == S_IFDIR)
                    .standardizedFileURL

                if fileType == S_IFDIR {
                    try beforeOpeningDirectory?(item)
                    let childDescriptor = name.withCString { namePointer in
                        Darwin.openat(
                            descriptor,
                            namePointer,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard childDescriptor >= 0 else {
                        throw FolderBrowserError.unavailable
                    }
                    defer { Darwin.close(childDescriptor) }

                    var openedChildMetadata = stat()
                    guard Darwin.fstat(childDescriptor, &openedChildMetadata) == 0,
                          openedChildMetadata.st_mode & S_IFMT == S_IFDIR,
                          openedChildMetadata.st_dev == metadata.st_dev,
                          openedChildMetadata.st_ino == metadata.st_ino
                    else {
                        throw FolderBrowserError.unavailable
                    }

                    let children = try readDirectory(
                        descriptor: childDescriptor,
                        directoryURL: item,
                        relativePath: itemRelativePath
                    )
                    items.append(
                        FolderProjectItem(
                            url: item,
                            relativePath: itemRelativePath,
                            kind: .directory,
                            children: children
                        )
                    )
                } else if fileType == S_IFREG {
                    fileCount += 1
                    guard fileCount <= maximumFileCount else {
                        throw FolderBrowserError.tooManyMarkdownFiles(
                            limit: maximumFileCount
                        )
                    }
                    let projectItem = FolderProjectItem(
                        url: item,
                        relativePath: itemRelativePath,
                        kind: .file
                    )
                    items.append(projectItem)
                    if let markdownFile = projectItem.markdownFile {
                        markdownFiles.append(markdownFile)
                    }
                }
            }
            guard errno == 0 else { throw FolderBrowserError.unavailable }
            return items.sorted(by: FolderProjectItem.projectOrder)
        }

        let items = try readDirectory(
            descriptor: rootDescriptor,
            directoryURL: root,
            relativePath: nil
        )
        guard FolderProjectDirectoryIdentity.capture(root) == rootIdentity else {
            throw FolderBrowserError.unavailable
        }
        markdownFiles.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return FolderContentSnapshot(items: items, markdownFiles: markdownFiles)
    }
}

private extension FolderProjectItem {
    static func projectOrder(_ lhs: FolderProjectItem, _ rhs: FolderProjectItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.relativePath < rhs.relativePath
    }
}

private actor FolderContentScanWorker {
    func scan(
        _ rootURL: URL,
        expectedRootIdentity: FolderProjectDirectoryIdentity
    ) throws -> FolderContentSnapshot {
        try FolderContentScanner.snapshot(
            rootURL,
            expectedRootIdentity: expectedRootIdentity
        )
    }
}

enum FolderBrowserState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

enum FolderBrowserSelection: Equatable, Sendable {
    case none
    case directory(URL)
    case file(URL)
}

struct FolderMarkdownCreationAuthorization: Equatable, Sendable {
    let projectIdentity: FolderProjectDirectoryIdentity
    let targetIdentity: FolderProjectDirectoryIdentity
}

enum FolderMarkdownCreationError: Error, Equatable, LocalizedError, Sendable {
    case projectUnavailable
    case invalidName
    case unsupportedExtension
    case targetDirectoryUnavailable
    case targetOutsideProject
    case alreadyExists(fileName: String)
    case cannotCreate(fileName: String)

    var title: String {
        switch self {
        case .invalidName, .unsupportedExtension:
            "无法使用这个文件名"
        case let .alreadyExists(fileName):
            "「\(fileName)」已经存在"
        case .targetOutsideProject:
            "不能在这个位置创建文件"
        case .projectUnavailable, .targetDirectoryUnavailable, .cannotCreate:
            "未能创建 Markdown 文件"
        }
    }

    var errorDescription: String? {
        switch self {
        case .projectUnavailable:
            "当前项目已不可用。没有创建新文件。"
        case .invalidName:
            "请输入不以点号开头且不含路径分隔符的名称。"
        case .unsupportedExtension:
            "请使用 .md 或 .markdown；未输入扩展名时 Inflow 会自动补充 .md。"
        case .targetDirectoryUnavailable:
            "目标文件夹已不存在、不可读取或不再是文件夹。没有创建新文件。"
        case .targetOutsideProject:
            "目标不在当前项目中，或解析文件夹链接后会离开项目。Inflow 没有创建或覆盖任何文件或目录。"
        case .alreadyExists:
            "Inflow 不会覆盖现有文件或文件夹。请使用其他名称。"
        case let .cannotCreate(fileName):
            "未能创建「\(fileName)」。没有创建新文件，项目中的现有文件或目录未被覆盖。"
        }
    }
}

enum FolderMarkdownCreationResult: Equatable, Sendable {
    case notCreated(FolderMarkdownCreationError)
    case createdAndOpened(FolderMarkdownFile)
    case createdButOpeningFailed(FolderMarkdownFile, reason: String)

    var createdFile: FolderMarkdownFile? {
        switch self {
        case .notCreated:
            nil
        case let .createdAndOpened(file), let .createdButOpeningFailed(file, _):
            file
        }
    }
}

typealias FolderDocumentOpenCompletion = @MainActor (Result<Void, Error>) -> Void
typealias FolderDocumentOpener = @MainActor (
    URL,
    @escaping FolderDocumentOpenCompletion
) -> Void

enum FolderMarkdownFileCreator {
    static func normalizedFileName(_ rawName: String) throws -> String {
        guard !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawName != ".",
              rawName != "..",
              !rawName.hasPrefix("."),
              !rawName.contains("/"),
              !rawName.contains("\\"),
              rawName.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw FolderMarkdownCreationError.invalidName
        }

        let extensionName = (rawName as NSString).pathExtension
        if extensionName.isEmpty {
            guard !rawName.hasSuffix(".") else {
                throw FolderMarkdownCreationError.unsupportedExtension
            }
            return rawName + ".md"
        }
        guard FolderBrowserPolicy.supportedExtensions.contains(
            extensionName.lowercased()
        ) else {
            throw FolderMarkdownCreationError.unsupportedExtension
        }
        return rawName
    }

    static func targetDirectory(
        for selection: FolderBrowserSelection,
        projectRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root: URL
        do {
            root = try FolderProjectPathBoundary.normalizedProjectRoot(
                projectRoot,
                fileManager: fileManager
            )
        } catch {
            throw FolderMarkdownCreationError.projectUnavailable
        }

        let requestedDirectory: URL
        switch selection {
        case .none:
            requestedDirectory = root
        case let .directory(url):
            requestedDirectory = url
        case let .file(url):
            requestedDirectory = url.deletingLastPathComponent()
        }

        guard let directory = FolderProjectPathBoundary.resolvedURL(
            requestedDirectory,
            within: root
        ) else {
            throw FolderMarkdownCreationError.targetOutsideProject
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw FolderMarkdownCreationError.targetDirectoryUnavailable
        }
        return directory
    }

    static func createEmptyMarkdownFile(
        named rawName: String,
        projectRoot: URL,
        selection: FolderBrowserSelection = .none,
        expectedRootIdentity: FolderProjectDirectoryIdentity? = nil,
        expectedTargetIdentity: FolderProjectDirectoryIdentity? = nil,
        fileManager: FileManager = .default
    ) throws -> FolderMarkdownFile {
        let fileName = try normalizedFileName(rawName)
        let root: URL
        do {
            root = try FolderProjectPathBoundary.normalizedProjectRoot(
                projectRoot,
                fileManager: fileManager
            )
        } catch {
            throw FolderMarkdownCreationError.projectUnavailable
        }
        let directory = try targetDirectory(
            for: selection,
            projectRoot: root,
            fileManager: fileManager
        )
        guard let directoryComponents = FolderProjectPathBoundary.relativeComponents(
            of: directory,
            in: root
        ) else {
            throw FolderMarkdownCreationError.targetOutsideProject
        }

        try createEmptyFileExclusively(
            named: fileName,
            directoryComponents: directoryComponents,
            projectRoot: root,
            expectedRootIdentity: expectedRootIdentity,
            expectedTargetIdentity: expectedTargetIdentity
        )

        let url = directory.appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        let relativeComponents = directoryComponents + [fileName]
        return FolderMarkdownFile(
            url: url,
            relativePath: relativeComponents.joined(separator: "/")
        )
    }

    private static func createEmptyFileExclusively(
        named fileName: String,
        directoryComponents: [String],
        projectRoot: URL,
        expectedRootIdentity: FolderProjectDirectoryIdentity?,
        expectedTargetIdentity: FolderProjectDirectoryIdentity?
    ) throws {
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootDescriptor = projectRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, directoryFlags)
        }
        guard rootDescriptor >= 0 else {
            throw FolderMarkdownCreationError.projectUnavailable
        }
        guard descriptor(
            rootDescriptor,
            matches: expectedRootIdentity
        ) else {
            _ = Darwin.close(rootDescriptor)
            throw FolderMarkdownCreationError.projectUnavailable
        }

        var directoryDescriptor = rootDescriptor
        defer {
            if directoryDescriptor != rootDescriptor {
                _ = Darwin.close(directoryDescriptor)
            }
            _ = Darwin.close(rootDescriptor)
        }

        for component in directoryComponents {
            let nextDescriptor = component.withCString { name in
                Darwin.openat(directoryDescriptor, name, directoryFlags)
            }
            guard nextDescriptor >= 0 else {
                throw FolderMarkdownCreationError.targetDirectoryUnavailable
            }
            if directoryDescriptor != rootDescriptor {
                _ = Darwin.close(directoryDescriptor)
            }
            directoryDescriptor = nextDescriptor
        }

        guard descriptor(
            directoryDescriptor,
            matches: expectedTargetIdentity
        ) else {
            throw FolderMarkdownCreationError.targetDirectoryUnavailable
        }

        let fileFlags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = fileName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                fileFlags,
                mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw FolderMarkdownCreationError.alreadyExists(fileName: fileName)
            }
            if errno == ENOENT || errno == ENOTDIR {
                throw FolderMarkdownCreationError.targetDirectoryUnavailable
            }
            throw FolderMarkdownCreationError.cannotCreate(fileName: fileName)
        }
        _ = Darwin.close(descriptor)
    }

    private static func descriptor(
        _ descriptor: Int32,
        matches expectedIdentity: FolderProjectDirectoryIdentity?
    ) -> Bool {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR
        else {
            return false
        }
        guard let expectedIdentity else { return true }
        return expectedIdentity.matches(metadata)
    }
}

@MainActor
private final class FolderSecurityScopeLease {
    let url: URL
    private var isActive = true
    private let stopAccess: (URL) -> Void

    init(url: URL, stopAccess: @escaping (URL) -> Void) {
        self.url = url
        self.stopAccess = stopAccess
    }

    func invalidate() {
        guard isActive else { return }
        isActive = false
        stopAccess(url)
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }
}

@MainActor
final class FolderBrowserController: ObservableObject {
    @Published private(set) var folderURL: URL?
    private(set) var projectRootIdentity: FolderProjectDirectoryIdentity?
    @Published private(set) var items: [FolderProjectItem] = []
    @Published private(set) var files: [FolderMarkdownFile] = []
    @Published private(set) var state = FolderBrowserState.idle
    @Published private(set) var restorationWarning: String?
    private let projectDocuments = NSHashTable<NSDocument>.weakObjects()

    private let persistence: FolderBrowserPersistence
    private let bookmarkData: (URL) -> Data?
    private let resolveBookmark: (Data) -> (url: URL, isStale: Bool)?
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    private let scanWorker = FolderContentScanWorker()
    private var retainedAccess: [String: FolderSecurityScopeLease] = [:]
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    init(
        persistence: FolderBrowserPersistence = UserDefaultsFolderBrowserPersistence(),
        restoresSavedFolder: Bool = true,
        bookmarkData: @escaping (URL) -> Data? = { url in
            try? url.bookmarkData(options: .withSecurityScope)
        },
        resolveBookmark: @escaping (Data) -> (url: URL, isStale: Bool)? = { data in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            return (url, isStale)
        },
        startAccess: @escaping (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccess: @escaping (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.persistence = persistence
        self.bookmarkData = bookmarkData
        self.resolveBookmark = resolveBookmark
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        if restoresSavedFolder {
            restoreSavedFolder()
        }
    }

    func chooseFolder(attachedTo window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) {
        let panel = NSOpenPanel()
        panel.title = "打开项目"
        panel.message = "选择一个普通文件夹作为项目。Inflow 不会导入、复制或重组其中内容。"
        panel.prompt = "打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.openFolder(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    func openFolder(_ url: URL, remember: Bool = true) {
        guard let directory = validatedFolderURLForOpening(url),
              let identity = FolderProjectDirectoryIdentity.capture(directory)
        else {
            folderURL = nil
            projectRootIdentity = nil
            items = []
            files = []
            state = .failed(FolderBrowserError.unavailable.localizedDescription)
            if !remember {
                persistence.save(nil)
                restorationWarning =
                    "上次打开的文件夹已移动或不可用，请重新选择。"
            }
            return
        }

        folderURL = identity.resolvedURL
        projectRootIdentity = identity
        restorationWarning = nil
        if remember {
            let bookmark = bookmarkData(directory)
            persistence.save(
                FolderBrowserRecord(exactPath: directory.path, bookmark: bookmark)
            )
            if bookmark == nil {
                restorationWarning =
                    "本次可以正常使用，但未能记住该项目；下次启动时可能需要重新选择。"
            }
        }
        refresh()
    }

    /// Validates a project root without changing the visible browser state.
    /// Security scope must be active before metadata inspection in a sandbox.
    func validatedFolderURLForOpening(_ url: URL) -> URL? {
        let directory = url.standardizedFileURL
        retainAccess(to: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return directory
    }

    /// Scans a candidate without changing the project currently shown. The
    /// caller may therefore wait for a complete, readable first snapshot
    /// before asking the current document to close.
    func prepareFolderForOpening(
        _ url: URL,
        completion: @escaping @MainActor (
            Result<FolderProjectOpenPreparation, Error>
        ) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self, scanWorker] in
            guard let self,
                  let validatedURL = self.validatedFolderURLForOpening(url),
                  let identity = FolderProjectDirectoryIdentity.capture(validatedURL)
            else {
                completion(.failure(FolderBrowserError.unavailable))
                return
            }
            do {
                let snapshot = try await scanWorker.scan(
                    identity.resolvedURL,
                    expectedRootIdentity: identity
                )
                try Task.checkCancellation()
                guard FolderProjectDirectoryIdentity.capture(identity.resolvedURL)
                    == identity
                else {
                    throw FolderBrowserError.unavailable
                }
                completion(
                    .success(
                        FolderProjectOpenPreparation(
                            rootURL: identity.resolvedURL,
                            rootIdentity: identity,
                            snapshot: snapshot
                        )
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Commits only a preparation for the exact directory object that was
    /// scanned. No asynchronous failure remains after this point.
    @discardableResult
    func commitPreparedFolder(
        _ preparation: FolderProjectOpenPreparation,
        finalValidation: () -> Bool = { true }
    ) -> Bool {
        guard FolderProjectDirectoryIdentity.capture(preparation.rootURL)
            == preparation.rootIdentity
        else { return false }

        // Publishing the candidate URL is synchronous. A subscriber can therefore
        // invalidate the directory between the first identity check and the final
        // one. Preserve the complete visible snapshot (and keep an in-flight scan
        // alive) until the candidate has survived that publication boundary.
        let previousFolderURL = folderURL
        let previousProjectRootIdentity = projectRootIdentity
        let previousItems = items
        let previousFiles = files
        let previousState = state
        let previousRestorationWarning = restorationWarning

        folderURL = preparation.rootURL
        projectRootIdentity = preparation.rootIdentity
        items = preparation.snapshot.items
        files = preparation.snapshot.markdownFiles
        state = .ready
        restorationWarning = nil
        guard FolderProjectDirectoryIdentity.capture(preparation.rootURL)
                  == preparation.rootIdentity,
              finalValidation(),
              // The validation closure may itself synchronously enter app or
              // filesystem code, so keep the directory check on both sides.
              FolderProjectDirectoryIdentity.capture(preparation.rootURL)
                  == preparation.rootIdentity
        else {
            projectRootIdentity = previousProjectRootIdentity
            items = previousItems
            files = previousFiles
            state = previousState
            restorationWarning = previousRestorationWarning
            folderURL = previousFolderURL
            return false
        }
        scanTask?.cancel()
        scanGeneration &+= 1
        return true
    }

    func refresh() {
        guard let folderURL,
              let projectRootIdentity,
              FolderProjectDirectoryIdentity.capture(folderURL) == projectRootIdentity
        else {
            items = []
            files = []
            state = folderURL == nil
                ? .idle
                : .failed(FolderBrowserError.unavailable.localizedDescription)
            return
        }
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        files = []
        state = .loading
        scanTask = Task { [weak self, scanWorker] in
            do {
                let snapshot = try await scanWorker.scan(
                    folderURL,
                    expectedRootIdentity: projectRootIdentity
                )
                guard !Task.isCancelled,
                      let self,
                      self.scanGeneration == generation,
                      self.folderURL?.standardizedFileURL == folderURL.standardizedFileURL,
                      self.projectRootIdentity == projectRootIdentity
                else {
                    return
                }
                guard FolderProjectDirectoryIdentity.capture(folderURL)
                    == projectRootIdentity
                else {
                    self.items = []
                    self.files = []
                    self.state = .failed(
                        FolderBrowserError.unavailable.localizedDescription
                    )
                    return
                }
                self.items = snapshot.items
                self.files = snapshot.markdownFiles
                self.state = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.items = []
                self.files = []
                self.state = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? "未能读取这个文件夹。请检查访问权限后重试。"
                )
            }
        }
    }

    func item(withID id: String?) -> FolderProjectItem? {
        guard let id else { return nil }
        for item in items {
            if let match = item.item(withID: id) { return match }
        }
        return nil
    }

    func selection(forItemID id: String?) -> FolderBrowserSelection {
        guard let item = item(withID: id) else { return .none }
        return item.isDirectory ? .directory(item.url) : .file(item.url)
    }

    func targetDirectory(for selection: FolderBrowserSelection) throws -> URL {
        guard let folderURL,
              let projectRootIdentity,
              FolderProjectDirectoryIdentity.capture(folderURL) == projectRootIdentity
        else {
            throw FolderMarkdownCreationError.projectUnavailable
        }
        return try FolderMarkdownFileCreator.targetDirectory(
            for: selection,
            projectRoot: folderURL
        )
    }

    func creationAuthorization(
        for selection: FolderBrowserSelection
    ) throws -> FolderMarkdownCreationAuthorization {
        guard let projectRootIdentity else {
            throw FolderMarkdownCreationError.projectUnavailable
        }
        let target = try targetDirectory(for: selection)
        guard let targetIdentity = FolderProjectDirectoryIdentity.capture(target) else {
            throw FolderMarkdownCreationError.targetDirectoryUnavailable
        }
        return FolderMarkdownCreationAuthorization(
            projectIdentity: projectRootIdentity,
            targetIdentity: targetIdentity
        )
    }

    func creationAuthorizationIsCurrent(
        _ authorization: FolderMarkdownCreationAuthorization,
        for selection: FolderBrowserSelection
    ) -> Bool {
        guard projectRootIdentity == authorization.projectIdentity,
              let folderURL,
              FolderProjectDirectoryIdentity.capture(folderURL)
                  == authorization.projectIdentity,
              let target = try? targetDirectory(for: selection),
              FolderProjectDirectoryIdentity.capture(target)
                  == authorization.targetIdentity
        else {
            return false
        }
        return true
    }

    func validateMarkdownFileCreation(
        named rawName: String,
        selection: FolderBrowserSelection = .none
    ) throws {
        let fileName = try FolderMarkdownFileCreator.normalizedFileName(rawName)
        let directory = try targetDirectory(for: selection)
        guard let folderURL,
              FolderProjectPathBoundary.contains(directory, in: folderURL)
        else {
            throw FolderMarkdownCreationError.targetOutsideProject
        }

        let target = directory.appendingPathComponent(fileName, isDirectory: false)
        var metadata = stat()
        let targetExists = target.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &metadata) == 0
        }
        guard !targetExists else {
            throw FolderMarkdownCreationError.alreadyExists(fileName: fileName)
        }
    }

    @discardableResult
    func createMarkdownFile(
        named rawName: String,
        selection: FolderBrowserSelection = .none,
        expectedRootIdentity: FolderProjectDirectoryIdentity? = nil,
        expectedTargetIdentity: FolderProjectDirectoryIdentity? = nil,
        openDocument: (URL) throws -> Void
    ) -> FolderMarkdownCreationResult {
        switch createFileOnDisk(
            named: rawName,
            selection: selection,
            expectedRootIdentity: expectedRootIdentity,
            expectedTargetIdentity: expectedTargetIdentity
        ) {
        case let .failure(error):
            return .notCreated(error)
        case let .success(file):
            do {
                try openDocument(file.url)
                return .createdAndOpened(file)
            } catch {
                return .createdButOpeningFailed(
                    file,
                    reason: Self.openFailureReason(error)
                )
            }
        }
    }

    func createMarkdownFile(
        named rawName: String,
        selection: FolderBrowserSelection = .none,
        expectedRootIdentity: FolderProjectDirectoryIdentity? = nil,
        expectedTargetIdentity: FolderProjectDirectoryIdentity? = nil,
        openDocumentWithCompletion openDocument: FolderDocumentOpener,
        completion: @escaping @MainActor (FolderMarkdownCreationResult) -> Void
    ) {
        switch createFileOnDisk(
            named: rawName,
            selection: selection,
            expectedRootIdentity: expectedRootIdentity,
            expectedTargetIdentity: expectedTargetIdentity
        ) {
        case let .failure(error):
            completion(.notCreated(error))
        case let .success(file):
            openDocument(file.url) { result in
                switch result {
                case .success:
                    completion(.createdAndOpened(file))
                case let .failure(error):
                    completion(
                        .createdButOpeningFailed(
                            file,
                            reason: Self.openFailureReason(error)
                        )
                    )
                }
            }
        }
    }

    static func exactResolvedDirectory(
        for record: FolderBrowserRecord,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        resolveBookmark: (Data) -> (url: URL, isStale: Bool)?
    ) -> URL? {
        let exactURL = URL(fileURLWithPath: record.exactPath).standardizedFileURL
        guard let bookmark = record.bookmark else {
            return directoryExists(record.exactPath) ? exactURL : nil
        }
        guard let resolved = resolveBookmark(bookmark),
              !resolved.isStale,
              resolved.url.standardizedFileURL.path == record.exactPath
        else {
            return nil
        }
        return resolved.url.standardizedFileURL
    }

    private func restoreSavedFolder() {
        guard let record = persistence.load() else { return }
        guard let directory = Self.exactResolvedDirectory(
            for: record,
            resolveBookmark: resolveBookmark
        ) else {
            persistence.save(nil)
            restorationWarning =
                "上次打开的项目已移动或不可用，请重新选择。"
            return
        }
        openFolder(directory, remember: false)
    }

    func dismissRestorationWarning() {
        restorationWarning = nil
    }

    func associateProjectWindow(with document: NSDocument?) {
        guard let document else {
            projectDocuments.removeAllObjects()
            return
        }
        projectDocuments.add(document)
    }

    func isAssociatedProjectDocument(_ document: NSDocument?) -> Bool {
        guard let document else { return false }
        return projectDocuments.allObjects.contains { $0 === document }
    }

    func dissociateProjectWindow(_ document: NSDocument?) {
        guard let document else { return }
        projectDocuments.remove(document)
    }

    private func retainAccess(to directory: URL) {
        let identity = directory.standardizedFileURL.path
        guard retainedAccess[identity] == nil, startAccess(directory) else { return }
        retainedAccess[identity] = FolderSecurityScopeLease(
            url: directory,
            stopAccess: stopAccess
        )
    }

    private func includeCreatedFile(_ file: FolderMarkdownFile) {
        files.removeAll { $0.relativePath == file.relativePath }
        files.append(file)
        files.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        let newItem = FolderProjectItem(
            url: file.url,
            relativePath: file.relativePath,
            kind: .file
        )
        let parentPath = file.parentPath
        var didInsert = false
        items = Self.inserting(
            newItem,
            below: parentPath,
            in: items,
            didInsert: &didInsert
        )
        if !didInsert {
            items.append(newItem)
            items.sort(by: FolderProjectItem.projectOrder)
        }
        state = .ready
    }

    private func createFileOnDisk(
        named rawName: String,
        selection: FolderBrowserSelection,
        expectedRootIdentity: FolderProjectDirectoryIdentity?,
        expectedTargetIdentity: FolderProjectDirectoryIdentity?
    ) -> Result<FolderMarkdownFile, FolderMarkdownCreationError> {
        guard let folderURL,
              let projectRootIdentity,
              FolderProjectDirectoryIdentity.capture(folderURL) == projectRootIdentity,
              expectedRootIdentity.map({ $0 == projectRootIdentity }) ?? true
        else {
            return .failure(.projectUnavailable)
        }
        do {
            let file = try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                named: rawName,
                projectRoot: folderURL,
                selection: selection,
                expectedRootIdentity: expectedRootIdentity ?? projectRootIdentity,
                expectedTargetIdentity: expectedTargetIdentity
            )
            includeCreatedFile(file)
            return .success(file)
        } catch let error as FolderMarkdownCreationError {
            return .failure(error)
        } catch {
            let fallbackName = (try? FolderMarkdownFileCreator.normalizedFileName(rawName))
                ?? rawName
            return .failure(.cannotCreate(fileName: fallbackName))
        }
    }

    private static func openFailureReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func inserting(
        _ newItem: FolderProjectItem,
        below parentPath: String?,
        in currentItems: [FolderProjectItem],
        didInsert: inout Bool
    ) -> [FolderProjectItem] {
        if parentPath == nil {
            didInsert = true
            var result = currentItems.filter { $0.id != newItem.id }
            result.append(newItem)
            return result.sorted(by: FolderProjectItem.projectOrder)
        }

        return currentItems.map { item in
            guard item.isDirectory else { return item }
            if item.relativePath == parentPath {
                didInsert = true
                var children = (item.children ?? []).filter { $0.id != newItem.id }
                children.append(newItem)
                return FolderProjectItem(
                    url: item.url,
                    relativePath: item.relativePath,
                    kind: .directory,
                    children: children.sorted(by: FolderProjectItem.projectOrder)
                )
            }
            let children = inserting(
                newItem,
                below: parentPath,
                in: item.children ?? [],
                didInsert: &didInsert
            )
            return FolderProjectItem(
                url: item.url,
                relativePath: item.relativePath,
                kind: .directory,
                children: children
            )
        }
    }
}

struct FolderBrowserSidebar: View {
    @ObservedObject var controller: FolderBrowserController
    let currentDocumentURL: URL?
    let onOpenDocument: (URL) throws -> Void
    private let onOpenDocumentWithCompletion: FolderDocumentOpener
    private let onOpenCreatedDocument: FolderDocumentOpener
    private let onPrepareToReplaceCurrentDocument: (@escaping (Bool) -> Void) -> Void

    @State private var selectedItemID: String?
    @State private var creationSelection = FolderBrowserSelection.none
    @State private var newFileName = ""
    @State private var creationError: FolderMarkdownCreationError?
    @State private var isPresentingNewFile = false
    @State private var isPreparingCreation = false
    @State private var notice: FolderBrowserNotice?
    @State private var creationAuthorization: FolderMarkdownCreationAuthorization?

    init(
        controller: FolderBrowserController,
        currentDocumentURL: URL?,
        onOpenDocument: @escaping (URL) throws -> Void,
        onOpenDocumentWithCompletion: FolderDocumentOpener? = nil,
        onOpenCreatedDocument: FolderDocumentOpener? = nil,
        onPrepareToReplaceCurrentDocument: @escaping (
            @escaping (Bool) -> Void
        ) -> Void = { completion in completion(true) }
    ) {
        self.controller = controller
        self.currentDocumentURL = currentDocumentURL
        self.onOpenDocument = onOpenDocument
        self.onOpenDocumentWithCompletion = onOpenDocumentWithCompletion ?? { url, completion in
            do {
                try onOpenDocument(url)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        self.onOpenCreatedDocument = onOpenCreatedDocument ?? { url, completion in
            do {
                try onOpenDocument(url)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        self.onPrepareToReplaceCurrentDocument = onPrepareToReplaceCurrentDocument
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            browserContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("项目侧栏")
        .sheet(isPresented: $isPresentingNewFile) {
            FolderNewMarkdownFileSheet(
                targetFolderName: targetFolderName,
                fileName: $newFileName,
                error: creationError,
                onCreate: createMarkdownFile,
                onCancel: dismissNewFileSheet
            )
        }
        .alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            if let url = notice?.fileURL {
                Button("重试打开") { openItem(at: url, createdFile: true) }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("完成", role: .cancel) { notice = nil }
        } message: {
            Text(notice?.message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(controller.folderURL?.lastPathComponent ?? "项目")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                beginCreatingMarkdown(
                    in: controller.selection(forItemID: selectedItemID)
                )
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新建 Markdown 文件…")
            .disabled(controller.folderURL == nil || controller.state != .ready)
            .accessibilityLabel("新建 Markdown 文件")
            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新项目")
            .disabled(controller.folderURL == nil || controller.state == .loading)
            .accessibilityLabel("刷新项目")
        }
        .padding(.horizontal, 12)
        .frame(height: EditorWorkspaceMetrics.navigationHeaderHeight)
    }

    @ViewBuilder
    private var browserContent: some View {
        switch controller.state {
        case .idle:
            ContentUnavailableView(
                "尚未打开项目",
                systemImage: "folder",
                description: Text("从“文件”菜单选择“打开项目…”。")
            )
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取项目…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where controller.items.isEmpty:
            ContentUnavailableView {
                Label("这个项目中还没有文件", systemImage: "folder")
            } description: {
                Text("你可以直接新建 Markdown 文件，或在 Finder 中加入文件后刷新项目。")
            } actions: {
                Button("新建 Markdown 文件…") {
                    beginCreatingMarkdown(in: .none)
                }
                Button("刷新项目") { controller.refresh() }
            }
            .contextMenu {
                Button("新建 Markdown 文件…") {
                    beginCreatingMarkdown(in: .none)
                }
            }
        case .ready:
            List(selection: $selectedItemID) {
                OutlineGroup(controller.items, children: \.children) { item in
                    FolderProjectItemRow(
                        item: item,
                        isCurrentDocument: isCurrentDocument(item),
                        onActivate: {
                            selectedItemID = item.id
                            activateItem(withID: item.id)
                        }
                    )
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedItemID = item.id
                        activateItem(withID: item.id)
                    }
                    .contextMenu {
                        Button("新建 Markdown 文件…") {
                            selectedItemID = item.id
                            beginCreatingMarkdown(
                                in: item.isDirectory
                                    ? .directory(item.url)
                                    : .file(item.url)
                            )
                        }
                    }
                    .help(item.relativePath)
                }
            }
            .listStyle(.sidebar)
            .onKeyPress(.return, phases: .down) { _ in
                activateItem(withID: selectedItemID) ? .handled : .ignored
            }
            .contextMenu {
                Button("新建 Markdown 文件…") {
                    selectedItemID = nil
                    beginCreatingMarkdown(in: .none)
                }
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("暂时无法刷新项目", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { controller.refresh() }
            }
        }
    }

    private var targetFolderName: String {
        (try? controller.targetDirectory(for: creationSelection))?.lastPathComponent
            ?? controller.folderURL?.lastPathComponent
            ?? "项目"
    }

    private func beginCreatingMarkdown(in selection: FolderBrowserSelection) {
        creationSelection = selection
        creationAuthorization = try? controller.creationAuthorization(for: selection)
        newFileName = ""
        creationError = nil
        isPresentingNewFile = true
    }

    private func dismissNewFileSheet() {
        isPresentingNewFile = false
        isPreparingCreation = false
        creationError = nil
        creationAuthorization = nil
    }

    private func createMarkdownFile() {
        guard !isPreparingCreation else { return }
        guard let creationAuthorization,
              controller.creationAuthorizationIsCurrent(
                  creationAuthorization,
                  for: creationSelection
              )
        else {
            creationError = .projectUnavailable
            return
        }
        do {
            try controller.validateMarkdownFileCreation(
                named: newFileName,
                selection: creationSelection
            )
        } catch let error as FolderMarkdownCreationError {
            creationError = error
            return
        } catch {
            creationError = .cannotCreate(fileName: newFileName)
            return
        }

        isPreparingCreation = true
        onPrepareToReplaceCurrentDocument { shouldCreate in
            guard shouldCreate else {
                isPreparingCreation = false
                return
            }
            guard controller.creationAuthorizationIsCurrent(
                creationAuthorization,
                for: creationSelection
            )
            else {
                isPreparingCreation = false
                creationError = .projectUnavailable
                return
            }
            controller.createMarkdownFile(
                named: newFileName,
                selection: creationSelection,
                expectedRootIdentity: creationAuthorization.projectIdentity,
                expectedTargetIdentity: creationAuthorization.targetIdentity,
                openDocumentWithCompletion: onOpenCreatedDocument,
                completion: handleCreationResult
            )
        }
    }

    private func handleCreationResult(_ result: FolderMarkdownCreationResult) {
        isPreparingCreation = false
        switch result {
        case let .notCreated(error):
            LocalFailureLogController.shared.record(.project, code: .projectCreationFailed)
            creationError = error
        case .createdAndOpened:
            dismissNewFileSheet()
        case let .createdButOpeningFailed(file, reason):
            LocalFailureLogController.shared.record(.project, code: .projectCreationFailed)
            dismissNewFileSheet()
            notice = FolderBrowserNotice.createdButCouldNotOpen(
                file: file,
                reason: reason
            )
        }
    }

    private func openItem(at url: URL, createdFile: Bool) {
        onOpenDocumentWithCompletion(url) { result in
            switch result {
            case .success:
                if let currentDocumentURL,
                   FolderProjectPathBoundary.normalizedResolvedURL(url)
                       != FolderProjectPathBoundary.normalizedResolvedURL(currentDocumentURL)
                {
                    // A target that is already open in another Inflow window
                    // is focused without changing this project's current
                    // document. Do not leave the sidebar implying otherwise.
                    selectedItemID = nil
                }
                notice = nil
            case let .failure(error):
                selectedItemID = nil
                if let openError = error as? DocumentOpenError,
                   case .cancelled = openError
                {
                    notice = nil
                    return
                }
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                notice = createdFile
                    ? .createdButCouldNotOpen(
                        file: FolderMarkdownFile(
                            url: url,
                            relativePath: url.lastPathComponent
                        ),
                        reason: reason
                    )
                    : .couldNotOpen(fileURL: url, reason: reason)
            }
        }
    }

    @discardableResult
    private func activateItem(withID itemID: String?) -> Bool {
        guard let url = FolderBrowserActivation.markdownURL(
            forSelectedItemID: itemID,
            in: controller.items
        ) else { return false }
        openItem(at: url, createdFile: false)
        return true
    }

    private func isCurrentDocument(_ item: FolderProjectItem) -> Bool {
        guard item.isMarkdown, let currentDocumentURL else { return false }
        return FolderProjectPathBoundary.normalizedResolvedURL(item.url)
            == FolderProjectPathBoundary.normalizedResolvedURL(currentDocumentURL)
    }
}

private struct FolderProjectItemRow: View {
    let item: FolderProjectItem
    let isCurrentDocument: Bool
    let onActivate: () -> Void

    @ViewBuilder
    var body: some View {
        if item.isMarkdown {
            rowContent
                .accessibilityAction(.default) {
                    onActivate()
                }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(item.displayName)
                .lineLimit(1)
            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            isCurrentDocument ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isCurrentDocument ? "当前文档" : "")
    }

    private var systemImage: String {
        if item.isDirectory { return "folder" }
        switch item.url.pathExtension.lowercased() {
        case "md", "markdown": return "doc.text"
        case "png", "jpg", "jpeg": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    private var accessibilityLabel: String {
        if item.isDirectory { return "文件夹 \(item.displayName)" }
        if item.isMarkdown { return "打开 \(item.displayName)" }
        return "文件 \(item.displayName)"
    }
}

private struct FolderNewMarkdownFileSheet: View {
    let targetFolderName: String
    @Binding var fileName: String
    let error: FolderMarkdownCreationError?
    let onCreate: () -> Void
    let onCancel: () -> Void

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建 Markdown 文件")
                .font(.title2.bold())
            Text("将在「\(targetFolderName)」中立即创建并打开一个空文件。未输入扩展名时会自动使用 .md，也可以输入 .markdown。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("文件名", text: $fileName)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(onCreate)
            if let error {
                Label {
                    Text(error.localizedDescription)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("创建", action: onCreate)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear { isNameFocused = true }
    }
}

private struct FolderBrowserNotice {
    let title: String
    let message: String
    let fileURL: URL?

    static func createdButCouldNotOpen(
        file: FolderMarkdownFile,
        reason: String
    ) -> FolderBrowserNotice {
        FolderBrowserNotice(
            title: "文件已创建但无法打开",
            message: "「\(file.displayName)」已保存在项目中并显示在目录树里，Inflow 不会删除它。\(reason)",
            fileURL: file.url
        )
    }

    static func couldNotOpen(fileURL: URL, reason: String) -> FolderBrowserNotice {
        FolderBrowserNotice(
            title: "无法打开文件",
            message: "\(reason)文件未被修改。",
            fileURL: fileURL
        )
    }
}

struct FolderBrowserCommands: Commands {
    @ObservedObject private var controller: FolderBrowserController

    init(controller: FolderBrowserController) {
        self.controller = controller
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("打开项目…") {
                controller.chooseFolder()
            }
            if controller.folderURL != nil {
                Button("刷新项目") {
                    controller.refresh()
                }
                .disabled(controller.state == .loading)
            }
        }
    }
}
