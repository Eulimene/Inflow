import AppKit
import Foundation

enum LocalFailureCategory: String, Codable, CaseIterable, Sendable {
    case opening
    case saving
    case previewing
    case imageImport
    case linkOpening
    case project
    case recovery
    case pdfExport
    case logExport
}

enum LocalFailureCode: String, Codable, CaseIterable, Sendable {
    case unsupportedEncoding
    case fileUnavailable
    case saveFailed
    case previewFailed
    case invalidImage
    case unsafeLinkTarget
    case projectUnavailable
    case projectCreationFailed
    case recoveryUnavailable
    case pdfPreparationFailed
    case pdfRenderingFailed
    case pdfWriteFailed
    case logWriteFailed
    case unknown
}

struct LocalFailureRecord: Codable, Equatable, Sendable {
    let timestamp: String
    let applicationVersion: String
    let operationCategory: LocalFailureCategory
    let errorCode: LocalFailureCode
}

struct LocalFailureLogExport: Codable, Equatable, Sendable {
    let previousSession: [LocalFailureRecord]
    let currentSession: [LocalFailureRecord]
}

enum LocalFailureLogError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "本地日志当前无法写入；没有保存空文件，也没有发送任何信息。"
    }
}

@MainActor
final class LocalFailureLogController: ObservableObject {
    static let shared = LocalFailureLogController()

    private static let currentFilename = "current-session.json"
    private static let previousFilename = "previous-session.json"

    private let fileManager: FileManager
    private let directoryURL: URL
    private let currentURL: URL
    private let previousURL: URL
    private let timestamp: () -> String
    private let applicationVersion: () -> String
    private(set) var currentSession: [LocalFailureRecord] = []
    private(set) var previousSession: [LocalFailureRecord] = []

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        rotatesOnStart: Bool = true,
        timestamp: @escaping () -> String = {
            ISO8601DateFormatter().string(from: Date())
        },
        applicationVersion: @escaping () -> String = {
            let short = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            return LocalFailureLogController.safeVersion(short: short, build: build)
        }
    ) {
        self.fileManager = fileManager
        let resolvedDirectory = directoryURL ?? Self.defaultDirectory(fileManager: fileManager)
        self.directoryURL = resolvedDirectory
        currentURL = resolvedDirectory.appendingPathComponent(Self.currentFilename)
        previousURL = resolvedDirectory.appendingPathComponent(Self.previousFilename)
        self.timestamp = timestamp
        self.applicationVersion = applicationVersion
        prepareStorage(rotatesOnStart: rotatesOnStart)
    }

    func record(_ category: LocalFailureCategory, code: LocalFailureCode) {
        let record = LocalFailureRecord(
            timestamp: timestamp(),
            applicationVersion: applicationVersion(),
            operationCategory: category,
            errorCode: code
        )
        currentSession.append(record)
        try? persist(currentSession, to: currentURL)
    }

    func exportData() throws -> Data {
        let payload = LocalFailureLogExport(
            previousSession: previousSession,
            currentSession: currentSession
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), !data.isEmpty else {
            throw LocalFailureLogError.unavailable
        }
        return data
    }

    func writeExport(to targetURL: URL) throws {
        let data = try exportData()
        do {
            try data.write(to: targetURL, options: .atomic)
        } catch {
            record(.logExport, code: .logWriteFailed)
            throw LocalFailureLogError.unavailable
        }
    }

    func presentExport(attachedTo window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) {
        let confirmation = NSAlert()
        confirmation.alertStyle = .informational
        confirmation.messageText = "导出本地日志？"
        confirmation.informativeText =
            "日志不包含正文、文件名、路径、选区、剪贴板、链接、搜索词、凭据或恢复内容。Inflow 不会自动上传。"
        confirmation.addButton(withTitle: "选择保存位置…")
        confirmation.addButton(withTitle: "取消")

        present(confirmation, attachedTo: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let panel = NSSavePanel()
            panel.title = "导出本地日志"
            panel.prompt = "保存"
            panel.nameFieldStringValue = "Inflow-local-log.json"
            panel.isExtensionHidden = false
            self.present(panel, attachedTo: window) { [weak self] response in
                guard response == .OK, let self, let url = panel.url else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    try self.writeExport(to: url)
                    self.presentSuccess(for: url, attachedTo: window)
                } catch {
                    self.presentFailure(attachedTo: window)
                }
            }
        }
    }

    static func safeVersion(short: String?, build: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".+-_"))
        func clean(_ value: String?) -> String? {
            guard let value, !value.isEmpty,
                  value.unicodeScalars.allSatisfy(allowed.contains)
            else {
                return nil
            }
            return value
        }
        return switch (clean(short), clean(build)) {
        case let (short?, build?): "\(short) (\(build))"
        case let (short?, nil): short
        case let (nil, build?): build
        case (nil, nil): "unknown"
        }
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Inflow", isDirectory: true)
            .appendingPathComponent("FailureLogs", isDirectory: true)
    }

    private func prepareStorage(rotatesOnStart: Bool) {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            if rotatesOnStart, fileManager.fileExists(atPath: currentURL.path) {
                if fileManager.fileExists(atPath: previousURL.path) {
                    try fileManager.removeItem(at: previousURL)
                }
                try fileManager.moveItem(at: currentURL, to: previousURL)
            }
            previousSession = load(from: previousURL)
            currentSession = rotatesOnStart ? [] : load(from: currentURL)
            try persist(currentSession, to: currentURL)
        } catch {
            previousSession = []
            currentSession = []
        }
    }

    private func load(from url: URL) -> [LocalFailureRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([LocalFailureRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    private func persist(_ records: [LocalFailureRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(records)
        try data.write(to: url, options: .atomic)
    }

    private func present(
        _ alert: NSAlert,
        attachedTo window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func present(
        _ panel: NSSavePanel,
        attachedTo window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func presentSuccess(for url: URL, attachedTo window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "日志已保存"
        alert.informativeText = "是否以及如何上传由你决定。"
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "完成")
        present(alert, attachedTo: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func presentFailure(attachedTo window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "未能导出日志"
        alert.informativeText = "没有保存空文件，也没有发送任何信息。"
        alert.addButton(withTitle: "好")
        present(alert, attachedTo: window) { _ in }
    }
}
