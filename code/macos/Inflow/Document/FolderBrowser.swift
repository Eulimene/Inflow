import AppKit
import Combine
import Foundation
import SwiftUI

enum InflowLaunchPolicy {
    static let opensUntitledDocument = true

    @MainActor
    static func openUntitledDocument(using openDocument: () -> Void) -> Bool {
        openDocument()
        return true
    }
}

enum FolderBrowserPolicy {
    static let recordKey = "documents.folderBrowser.record.v1"
    static let supportedExtensions: Set<String> = ["md", "markdown"]
    static let maximumFileCount = 20_000
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

enum FolderBrowserError: Error, Equatable, LocalizedError {
    case unavailable
    case tooManyMarkdownFiles(limit: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "这个文件夹当前不可读取。请重新选择文件夹并确认访问权限。"
        case let .tooManyMarkdownFiles(limit):
            "这个文件夹包含超过 \(limit) 个 Markdown 文件。为避免界面失去响应，本次没有载入。"
        }
    }
}

enum FolderContentScanner {
    static func scan(
        _ rootURL: URL,
        fileManager: FileManager = .default,
        maximumFileCount: Int = FolderBrowserPolicy.maximumFileCount
    ) throws -> [FolderMarkdownFile] {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [
                      .isDirectoryKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                  ],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else {
            throw FolderBrowserError.unavailable
        }

        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var files: [FolderMarkdownFile] = []
        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  FolderBrowserPolicy.supportedExtensions.contains(
                      item.pathExtension.lowercased()
                  )
            else {
                continue
            }

            let file = item.standardizedFileURL
            guard file.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(file.path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { continue }
            files.append(FolderMarkdownFile(url: file, relativePath: relativePath))
            guard files.count <= maximumFileCount else {
                throw FolderBrowserError.tooManyMarkdownFiles(limit: maximumFileCount)
            }
        }

        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}

private actor FolderContentScanWorker {
    func scan(_ rootURL: URL) throws -> [FolderMarkdownFile] {
        try FolderContentScanner.scan(rootURL)
    }
}

enum FolderBrowserState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
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
    @Published private(set) var files: [FolderMarkdownFile] = []
    @Published private(set) var state = FolderBrowserState.idle
    @Published private(set) var restorationWarning: String?

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
        panel.title = "打开文件夹"
        panel.message = "选择包含 Markdown 文件的文件夹。Inflow 只会列出 .md 和 .markdown 文件。"
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
        let directory = url.standardizedFileURL
        // A restored sandbox bookmark must be activated before even checking
        // directory metadata. Outside the active scope, fileExists can report
        // a false negative for a perfectly valid folder.
        retainAccess(to: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            folderURL = nil
            files = []
            state = .failed(FolderBrowserError.unavailable.localizedDescription)
            if !remember {
                persistence.save(nil)
                restorationWarning =
                    "上次打开的文件夹已移动或不可用，请重新选择。"
            }
            return
        }

        folderURL = directory
        restorationWarning = nil
        if remember {
            let bookmark = bookmarkData(directory)
            persistence.save(
                FolderBrowserRecord(exactPath: directory.path, bookmark: bookmark)
            )
            if bookmark == nil {
                restorationWarning =
                    "本次可以浏览，但未能保存文件夹访问权限；下次启动时可能需要重新选择。"
            }
        }
        refresh()
    }

    func refresh() {
        guard let folderURL else {
            files = []
            state = .idle
            return
        }
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        files = []
        state = .loading
        scanTask = Task { [weak self, scanWorker] in
            do {
                let files = try await scanWorker.scan(folderURL)
                guard !Task.isCancelled,
                      let self,
                      self.scanGeneration == generation,
                      self.folderURL?.standardizedFileURL == folderURL.standardizedFileURL
                else {
                    return
                }
                self.files = files
                self.state = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.files = []
                self.state = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? "未能读取这个文件夹。请检查访问权限后重试。"
                )
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
                "上次打开的文件夹已移动、不可用或权限已过期，请重新选择。"
            return
        }
        openFolder(directory, remember: false)
    }

    func dismissRestorationWarning() {
        restorationWarning = nil
    }

    private func retainAccess(to directory: URL) {
        let identity = directory.standardizedFileURL.path
        guard retainedAccess[identity] == nil, startAccess(directory) else { return }
        retainedAccess[identity] = FolderSecurityScopeLease(
            url: directory,
            stopAccess: stopAccess
        )
    }
}

struct FolderBrowserSidebar: View {
    @ObservedObject var controller: FolderBrowserController
    let currentDocumentURL: URL?
    let onOpenDocument: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            browserContent
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件夹浏览器")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(controller.folderURL?.lastPathComponent ?? "文件夹")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新文件夹")
            .disabled(controller.folderURL == nil || controller.state == .loading)
            .accessibilityLabel("刷新文件夹")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    @ViewBuilder
    private var browserContent: some View {
        switch controller.state {
        case .idle:
            ContentUnavailableView(
                "尚未打开文件夹",
                systemImage: "folder",
                description: Text("从“文件”菜单选择“打开文件夹…”。")
            )
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取 Markdown 文件…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where controller.files.isEmpty:
            ContentUnavailableView(
                "没有 Markdown 文件",
                systemImage: "doc.text.magnifyingglass",
                description: Text("这个文件夹中没有 .md 或 .markdown 文件。")
            )
        case .ready:
            List(controller.files) { file in
                Button {
                    onOpenDocument(file.url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.displayName)
                                .lineLimit(1)
                            if let parentPath = file.parentPath {
                                Text(parentPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 5)
                    .background(
                        isCurrentDocument(file)
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(file.relativePath)
                .accessibilityLabel("打开 \(file.relativePath)")
                .accessibilityValue(isCurrentDocument(file) ? "当前文档" : "")
            }
            .listStyle(.sidebar)
        case let .failed(message):
            ContentUnavailableView {
                Label("无法读取文件夹", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { controller.refresh() }
            }
        }
    }

    private func isCurrentDocument(_ file: FolderMarkdownFile) -> Bool {
        file.url.standardizedFileURL == currentDocumentURL?.standardizedFileURL
    }
}

struct FolderBrowserCommands: Commands {
    @ObservedObject private var controller: FolderBrowserController

    init(controller: FolderBrowserController) {
        self.controller = controller
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("打开文件夹…") {
                controller.chooseFolder()
            }
            if controller.folderURL != nil {
                Button("刷新文件夹") {
                    controller.refresh()
                }
                .disabled(controller.state == .loading)
            }
        }
    }
}
