import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct HTMLExportSnapshot: Sendable {
    let utf8: Data
    let documentDirectory: URL?
    let appearance: PreviewAppearanceConfiguration
    let documentVersion: String

    init(
        markdown: String,
        documentDirectory: URL? = nil,
        appearance: PreviewAppearanceConfiguration = .default
    ) {
        utf8 = Data(markdown.utf8)
        self.documentDirectory = documentDirectory
        self.appearance = appearance
        documentVersion = Self.versionLabel(for: utf8)
    }

    private static func versionLabel(for data: Data) -> String {
        var hash = UInt64(0xcbf29ce484222325)
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "UTF-8 %016llX", hash)
    }
}

enum HTMLExportIssue: UInt64, CaseIterable, Sendable {
    case image = 1
    case formula = 2
    case mermaid = 4
    case localLink = 8
    case unsafeLink = 16

    var description: String {
        switch self {
        case .image:
            "缺失、未授权或不受支持的图片（交付物将显示安全占位）"
        case .formula:
            "数学公式（核心未能产生安全的自包含渲染结果）"
        case .mermaid:
            "Mermaid 图表（核心未能产生安全的自包含渲染结果）"
        case .localLink:
            "相对或本地文件链接（交付物中将保留文字并停用点击）"
        case .unsafeLink:
            "不安全或不受支持的链接协议（交付物中将保留文字并停用点击）"
        }
    }
}

struct HTMLExportPreparation: Sendable {
    let data: Data
    let warnings: [HTMLExportIssue]

    var warningMessage: String {
        let details = warnings.map { "• \($0.description)" }.joined(separator: "\n")
        return "\(details)\n\n返回 Markdown 可修正引用；明确继续后，缺失图片会保留可读占位，本地或异常链接会显示为不可点击的文字。"
    }
}

enum HTMLExportError: Error, LocalizedError, Sendable {
    case unsupportedContent([HTMLExportIssue])
    case outputTooLarge
    case invalidUTF8
    case unavailableResource
    case coreFailure

    var errorDescription: String? {
        switch self {
        case let .unsupportedContent(issues):
            let details = issues.map { "• \($0.description)" }.joined(separator: "\n")
            return "导出前检查未通过：\n\(details)\n\n未创建文件。请先移除或改写这些内容后重试。"
        case .outputTooLarge:
            return "自包含交付快照超过 100 MiB 上限，已在写入前停止。"
        case .invalidUTF8:
            return "导出快照不是有效的 UTF-8 文本，未创建文件。"
        case .unavailableResource:
            return LocalImageExportError.unavailableResource.localizedDescription
        case .coreFailure:
            return "交付预检暂时失败，未创建文件。当前 Markdown 不受影响。"
        }
    }
}

enum HTMLExporter {
    static func generate(snapshot: HTMLExportSnapshot) throws -> Data {
        let preparation = try prepare(snapshot: snapshot)
        guard preparation.warnings.isEmpty else {
            throw HTMLExportError.unsupportedContent(preparation.warnings)
        }
        return preparation.data
    }

    static func prepare(snapshot: HTMLExportSnapshot) throws -> HTMLExportPreparation {
        let result: InflowHTMLExportResult = snapshot.utf8.withUnsafeBytes { buffer in
            inflow_markdown_prepare_html_with_options(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count),
                snapshot.appearance.coreRenderOptions
            )
        }

        switch result.status {
        case INFLOW_STATUS_OK:
            do {
                let coreData = try InflowCoreBridge.copyAndFree(result.html)
                guard let coreHTML = String(data: coreData, encoding: .utf8) else {
                    throw HTMLExportError.coreFailure
                }
                let resolved = LocalImageResolver.resolveSlotsForPreparedExport(
                    in: coreHTML,
                    documentDirectory: snapshot.documentDirectory
                )
                let themed = PreviewAppearanceCSS.applying(snapshot.appearance, to: resolved.html)
                let output = Data(themed.utf8)
                guard output.count <= LocalImageValidator.maximumBytes else {
                    throw HTMLExportError.outputTooLarge
                }
                var warnings = HTMLExportIssue.allCases.filter {
                    result.blocking_issues & $0.rawValue != 0
                }
                if resolved.hasWarnings, !warnings.contains(.image) {
                    warnings.insert(.image, at: 0)
                }
                return HTMLExportPreparation(data: output, warnings: warnings)
            } catch let error as HTMLExportError {
                throw error
            } catch {
                throw HTMLExportError.coreFailure
            }
        case INFLOW_STATUS_UNSUPPORTED_CONTENT:
            inflow_owned_bytes_free(result.html.data, result.html.length)
            let issues = HTMLExportIssue.allCases.filter {
                result.blocking_issues & $0.rawValue != 0
            }
            throw HTMLExportError.unsupportedContent(issues)
        case INFLOW_STATUS_OUTPUT_TOO_LARGE:
            inflow_owned_bytes_free(result.html.data, result.html.length)
            throw HTMLExportError.outputTooLarge
        case INFLOW_STATUS_INVALID_UTF8:
            inflow_owned_bytes_free(result.html.data, result.html.length)
            throw HTMLExportError.invalidUTF8
        default:
            inflow_owned_bytes_free(result.html.data, result.html.length)
            throw HTMLExportError.coreFailure
        }
    }
}

enum HTMLExportTargetError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedTarget
    case targetChanged
    case cannotInspect
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            "导出目标不是可安全替换的普通文件，请选择其他位置。"
        case .targetChanged:
            "确认后，目标文件已被其他程序创建或修改。为避免覆盖新内容，本次未写入；请重新导出并确认。"
        case .cannotInspect:
            "无法确认导出目标的当前状态，未写入文件。"
        case .cannotWrite:
            "无法完成原子写入，未留下残缺的交付文件。"
        }
    }
}

struct HTMLExportTargetSnapshot: Equatable, Sendable {
    fileprivate enum State: Equatable, Sendable {
        case missing
        case existing(
            device: UInt64,
            inode: UInt64,
            generation: UInt32,
            birthSeconds: Int64,
            birthNanoseconds: Int64,
            changeSeconds: Int64,
            changeNanoseconds: Int64,
            size: Int64,
            modificationSeconds: Int64,
            modificationNanoseconds: Int64,
            contentHash: UInt64
        )
    }

    fileprivate let state: State

    static func capture(_ url: URL, fileManager: FileManager = .default) throws -> Self {
        var metadata = stat()
        errno = 0
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0 else {
            if errno == ENOENT || !fileManager.fileExists(atPath: url.path) {
                return Self(state: .missing)
            }
            throw HTMLExportTargetError.cannotInspect
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw HTMLExportTargetError.unsupportedTarget
        }

        return Self(
            state: .existing(
                device: UInt64(metadata.st_dev),
                inode: metadata.st_ino,
                generation: metadata.st_gen,
                birthSeconds: Int64(metadata.st_birthtimespec.tv_sec),
                birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec),
                changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
                size: metadata.st_size,
                modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                contentHash: try contentHash(of: url)
            )
        )
    }

    fileprivate var exists: Bool {
        if case .existing = state { true } else { false }
    }

    var isExistingTarget: Bool { exists }

    private static func contentHash(of url: URL) throws -> UInt64 {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw HTMLExportTargetError.cannotInspect
        }
        defer { try? handle.close() }

        var hash = UInt64(0xcbf29ce484222325)
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                for byte in chunk {
                    hash ^= UInt64(byte)
                    hash &*= 0x100000001b3
                }
            }
        } catch {
            throw HTMLExportTargetError.cannotInspect
        }
        return hash
    }

}

enum HTMLExportFileWriter {
    static func write(
        _ data: Data,
        to targetURL: URL,
        expectedTarget: HTMLExportTargetSnapshot,
        fileManager: FileManager = .default,
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        let directory = targetURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".inflow-export-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var temporaryExists = false
        defer {
            if temporaryExists {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            temporaryExists = true
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()
            try beforeCommit?()
        } catch let error as HTMLExportTargetError {
            throw error
        } catch {
            throw HTMLExportTargetError.cannotWrite
        }

        var coordinationError: NSError?
        var commitError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: targetURL,
            options: expectedTarget.exists ? .forReplacing : [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                guard try HTMLExportTargetSnapshot.capture(
                    coordinatedURL,
                    fileManager: fileManager
                ) == expectedTarget else {
                    throw HTMLExportTargetError.targetChanged
                }

                if expectedTarget.exists {
                    _ = try fileManager.replaceItemAt(
                        coordinatedURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: coordinatedURL)
                }
                temporaryExists = false
            } catch {
                commitError = error
            }
        }

        if commitError == nil, let coordinationError {
            commitError = coordinationError
        }
        if let error = commitError as? HTMLExportTargetError {
            throw error
        }
        if commitError != nil {
            throw HTMLExportTargetError.cannotWrite
        }
    }
}

actor HTMLExportWorker {
    func captureTarget(_ targetURL: URL) -> Result<HTMLExportTargetSnapshot, HTMLExportTargetError> {
        do {
            return .success(try HTMLExportTargetSnapshot.capture(targetURL))
        } catch let error as HTMLExportTargetError {
            return .failure(error)
        } catch {
            return .failure(.cannotInspect)
        }
    }

    func prepare(_ snapshot: HTMLExportSnapshot) -> Result<HTMLExportPreparation, HTMLExportError> {
        do {
            return .success(try HTMLExporter.prepare(snapshot: snapshot))
        } catch let error as HTMLExportError {
            return .failure(error)
        } catch {
            return .failure(.coreFailure)
        }
    }

    func generate(_ snapshot: HTMLExportSnapshot) -> Result<Data, HTMLExportError> {
        do {
            return .success(try HTMLExporter.generate(snapshot: snapshot))
        } catch let error as HTMLExportError {
            return .failure(error)
        } catch {
            return .failure(.coreFailure)
        }
    }

    func write(
        _ data: Data,
        to targetURL: URL,
        expectedTarget: HTMLExportTargetSnapshot
    ) -> Result<Void, HTMLExportTargetError> {
        do {
            try HTMLExportFileWriter.write(data, to: targetURL, expectedTarget: expectedTarget)
            return .success(())
        } catch let error as HTMLExportTargetError {
            return .failure(error)
        } catch {
            return .failure(.cannotWrite)
        }
    }
}

@MainActor
enum HTMLExportPanel {
    static func chooseDestination(suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出 HTML"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.html]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
