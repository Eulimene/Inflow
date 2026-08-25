import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ValidatedLocalImage: Sendable {
    let data: Data
    let mimeType: String
}

enum LocalImageValidationError: Error, LocalizedError, Equatable {
    case notRegularOrUnreadable
    case tooLarge
    case unsafeOrUnsupported
    case extensionMismatch

    var errorDescription: String? {
        switch self {
        case .notRegularOrUnreadable:
            "图片不存在、不可读，或不是普通文件。"
        case .tooLarge:
            "图片超过 100 MiB，未读取或复制。"
        case .unsafeOrUnsupported:
            "只支持安全尺寸、单帧的静态 PNG 或 JPEG。"
        case .extensionMismatch:
            "图片内容与文件扩展名不一致。"
        }
    }
}

enum LocalImageValidator {
    static let maximumBytes = 100 * 1_024 * 1_024

    static func load(at url: URL) throws -> ValidatedLocalImage {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw LocalImageValidationError.notRegularOrUnreadable
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              size <= maximumBytes
        else {
            if let size = values.fileSize, size > maximumBytes {
                throw LocalImageValidationError.tooLarge
            }
            throw LocalImageValidationError.notRegularOrUnreadable
        }

        let data: Data
        do {
            data = try boundedData(at: url)
        } catch {
            throw LocalImageValidationError.notRegularOrUnreadable
        }
        return try validate(data: data, fileExtension: url.pathExtension)
    }

    static func validate(data: Data, fileExtension: String) throws -> ValidatedLocalImage {
        guard data.count <= maximumBytes else { throw LocalImageValidationError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              width <= 32_768,
              height <= 32_768,
              case let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height),
              !overflow,
              pixelCount <= 100_000_000
        else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }

        let mimeType: String
        let expectedExtensions: Set<String>
        if type.conforms(to: .png) {
            mimeType = "image/png"
            expectedExtensions = ["png"]
        } else if type.conforms(to: .jpeg) {
            mimeType = "image/jpeg"
            expectedExtensions = ["jpg", "jpeg"]
        } else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }
        guard expectedExtensions.contains(fileExtension.lowercased()) else {
            throw LocalImageValidationError.extensionMismatch
        }
        return ValidatedLocalImage(data: data, mimeType: mimeType)
    }

    private static func boundedData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, 1_024 * 1_024))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let chunk = try handle.read(upToCount: min(remaining, 1_024 * 1_024))
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }
}

enum ClipboardImageKind: String, Sendable, Equatable {
    case png
    case jpeg
    case tiff

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .png: NSPasteboard.PasteboardType(UTType.png.identifier)
        case .jpeg: NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        case .tiff: .tiff
        }
    }
}

struct ClipboardImagePayload: Sendable, Equatable {
    let data: Data
    let kind: ClipboardImageKind

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> Self? {
        for kind in [ClipboardImageKind.png, .jpeg, .tiff] {
            if let data = pasteboard.data(forType: kind.pasteboardType) {
                return Self(data: data, kind: kind)
            }
        }
        return nil
    }
}

enum DroppedImageSource {
    @MainActor
    private static let readingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
    ]

    @MainActor
    static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: readingOptions)
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: readingOptions
        ) as? [URL], urls.count == 1 else {
            return nil
        }
        let url = urls[0]
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .png) || type.conforms(to: .jpeg)
        else {
            return nil
        }
        return url
    }
}

enum ClipboardImageProcessor {
    static func validateAndNormalize(_ payload: ClipboardImagePayload) throws -> ValidatedLocalImage {
        switch payload.kind {
        case .png:
            try LocalImageValidator.validate(data: payload.data, fileExtension: "png")
        case .jpeg:
            try LocalImageValidator.validate(data: payload.data, fileExtension: "jpg")
        case .tiff:
            try convertTIFFToPNG(payload.data)
        }
    }

    private static func convertTIFFToPNG(_ data: Data) throws -> ValidatedLocalImage {
        guard data.count <= LocalImageValidator.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              UTType(typeIdentifier)?.conforms(to: .tiff) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              width <= 32_768,
              height <= 32_768,
              case let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height),
              !overflow,
              pixelCount <= 100_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: false,
              ] as CFDictionary)
        else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }
        return try LocalImageValidator.validate(data: output as Data, fileExtension: "png")
    }
}

enum ImageAssetCollisionResolution: Sendable, Equatable {
    case failIfExists
    case replace
    case incrementName
    case numberedSequence
}

enum ExistingImagePlacement: Sendable, Equatable {
    case copyToAssets
    case keepOriginal
}

struct RetainedImageReference: Sendable, Equatable {
    let markdownDestination: String
    let isRelative: Bool
}

enum RetainedImageReferencePlanner {
    static func plan(
        sourceURL: URL,
        documentURL: URL,
        sameVolume override: Bool? = nil
    ) throws -> RetainedImageReference {
        let source = sourceURL.standardizedFileURL
        let documentDirectory = documentURL.deletingLastPathComponent().standardizedFileURL
        let sameVolume = try override ?? urlsShareVolume(source, documentDirectory)
        if sameVolume {
            let sourceComponents = source.pathComponents
            let directoryComponents = documentDirectory.pathComponents
            var sharedCount = 0
            while sharedCount < sourceComponents.count,
                  sharedCount < directoryComponents.count,
                  sourceComponents[sharedCount] == directoryComponents[sharedCount]
            {
                sharedCount += 1
            }
            guard sharedCount > 0 else {
                throw ImageAssetImportError.copyFailed
            }
            let parentComponents = Array(
                repeating: "..",
                count: directoryComponents.count - sharedCount
            )
            let fileComponents = sourceComponents[sharedCount...].map(encodedPathComponent)
            let relative = (parentComponents + fileComponents).joined(separator: "/")
            guard !relative.isEmpty else {
                throw ImageAssetImportError.invalidFilename
            }
            return RetainedImageReference(markdownDestination: relative, isRelative: true)
        }

        return RetainedImageReference(
            markdownDestination: source.absoluteString,
            isRelative: false
        )
    }

    private static func urlsShareVolume(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let lhsValue = try lhs.resourceValues(forKeys: keys).volumeIdentifier
        let rhsValue = try rhs.resourceValues(forKeys: keys).volumeIdentifier
        guard let lhsValue = lhsValue as? AnyHashable,
              let rhsValue = rhsValue as? AnyHashable
        else {
            return false
        }
        return lhsValue == rhsValue
    }

    private static func encodedPathComponent(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}

struct ImageAssetDestinationSnapshot: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case missing
        case existing(
            device: UInt64,
            inode: UInt64,
            generation: UInt32,
            changeSeconds: Int64,
            changeNanoseconds: Int64,
            size: Int64,
            modificationSeconds: Int64,
            modificationNanoseconds: Int64,
            contentHash: UInt64
        )
    }

    private let state: State

    var exists: Bool {
        if case .existing = state { true } else { false }
    }

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
            throw ImageAssetImportError.destinationChanged
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ImageAssetImportError.destinationChanged
        }

        return Self(
            state: .existing(
                device: UInt64(metadata.st_dev),
                inode: metadata.st_ino,
                generation: metadata.st_gen,
                changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
                size: metadata.st_size,
                modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                contentHash: try contentHash(of: url)
            )
        )
    }

    private static func contentHash(of url: URL) throws -> UInt64 {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ImageAssetImportError.destinationChanged
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
            throw ImageAssetImportError.destinationChanged
        }
        return hash
    }
}

struct ImportedImageAsset: Sendable {
    let destinationURL: URL
    let relativeMarkdownPath: String
    let importedData: Data
    let previousData: Data?
    let createdAssetsDirectory: Bool

    func rollback() throws {
        try restoreBeforeUndo()
    }

    func restoreBeforeUndo() throws {
        let snapshot = try ImageAssetDestinationSnapshot.capture(destinationURL)
        guard snapshot.exists else {
            throw ImageAssetImportError.destinationChanged
        }
        let current = try Data(contentsOf: destinationURL, options: .mappedIfSafe)
        guard current == importedData else {
            throw ImageAssetImportError.destinationChanged
        }
        try restore(previousData)
        try removeEmptyCreatedDirectory()
    }

    func restoreAfterRedo() throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let snapshot = try ImageAssetDestinationSnapshot.capture(destinationURL)
            guard snapshot.exists else {
                throw ImageAssetImportError.destinationChanged
            }
            let current = try Data(contentsOf: destinationURL, options: .mappedIfSafe)
            guard current == previousData else {
                throw ImageAssetImportError.destinationChanged
            }
        } else if previousData != nil {
            throw ImageAssetImportError.destinationChanged
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try importedData.write(to: destinationURL, options: .atomic)
    }

    private func restore(_ data: Data?) throws {
        if let data {
            try data.write(to: destinationURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
    }

    private func removeEmptyCreatedDirectory() throws {
        guard createdAssetsDirectory else { return }
        let directory = destinationURL.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        if contents.isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

enum ImageAssetImportError: Error, LocalizedError, Equatable {
    case unsavedDocument
    case invalidFilename
    case unauthorizedDirectory
    case destinationChanged
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .unsavedDocument:
            "请先保存 Markdown 文档，再插入需要复制的图片。"
        case .invalidFilename:
            "图片文件名包含控制字符，无法创建安全的相对引用。"
        case .unauthorizedDirectory:
            "请选择当前 Markdown 文档所在的文件夹，以授权创建 assets。"
        case .destinationChanged:
            "目标图片已被其他操作修改。为避免覆盖，资源变更已停止。"
        case .copyFailed:
            "图片复制失败，Markdown 正文未被修改。"
        }
    }
}

actor ImageAssetWorker {
    func loadSource(at url: URL) throws -> ValidatedLocalImage {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try LocalImageValidator.load(at: url)
    }

    func retainedReference(sourceURL: URL, documentURL: URL) throws -> RetainedImageReference {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        return try RetainedImageReferencePlanner.plan(
            sourceURL: sourceURL,
            documentURL: documentURL
        )
    }

    func prepareClipboardImage(_ payload: ClipboardImagePayload) throws -> ValidatedLocalImage {
        try ClipboardImageProcessor.validateAndNormalize(payload)
    }

    func importClipboardImage(
        _ image: ValidatedLocalImage,
        documentDirectory: URL
    ) throws -> ImportedImageAsset {
        try importAsset(
            image: image,
            originalFilename: image.mimeType == "image/jpeg" ? "image.jpg" : "image.png",
            documentDirectory: documentDirectory,
            collisionResolution: .numberedSequence,
            expectedDestination: nil
        )
    }

    func destinationSnapshot(
        documentDirectory: URL,
        originalFilename: String
    ) throws -> ImageAssetDestinationSnapshot {
        try ImageAssetDestinationSnapshot.capture(
            documentDirectory
                .appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent(originalFilename, isDirectory: false)
        )
    }

    func importAsset(
        image: ValidatedLocalImage,
        originalFilename: String,
        documentDirectory: URL,
        collisionResolution: ImageAssetCollisionResolution,
        expectedDestination: ImageAssetDestinationSnapshot?
    ) throws -> ImportedImageAsset {
        guard !originalFilename.isEmpty,
              !originalFilename.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            throw ImageAssetImportError.invalidFilename
        }
        let fileManager = FileManager.default
        let assetsDirectory = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        let directoryExisted = fileManager.fileExists(atPath: assetsDirectory.path)
        do {
            try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            let directoryValues = try assetsDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true
            else {
                throw ImageAssetImportError.destinationChanged
            }
            let destinationURL = try resolvedDestination(
                assetsDirectory: assetsDirectory,
                originalFilename: originalFilename,
                collisionResolution: collisionResolution
            )
            if collisionResolution == .failIfExists || collisionResolution == .replace {
                guard let expectedDestination,
                      try ImageAssetDestinationSnapshot.capture(destinationURL) == expectedDestination,
                      expectedDestination.exists == (collisionResolution == .replace)
                else {
                    throw ImageAssetImportError.destinationChanged
                }
            }
            let previousData: Data?
            if fileManager.fileExists(atPath: destinationURL.path) {
                guard collisionResolution == .replace else {
                    throw ImageAssetImportError.destinationChanged
                }
                let values = try destinationURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ImageAssetImportError.destinationChanged
                }
                previousData = try Data(contentsOf: destinationURL, options: .mappedIfSafe)
                try image.data.write(to: destinationURL, options: .atomic)
            } else {
                previousData = nil
                try image.data.write(to: destinationURL, options: .withoutOverwriting)
            }
            let encodedFilename = destinationURL.lastPathComponent.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? destinationURL.lastPathComponent
            return ImportedImageAsset(
                destinationURL: destinationURL,
                relativeMarkdownPath: "assets/\(encodedFilename)",
                importedData: image.data,
                previousData: previousData,
                createdAssetsDirectory: !directoryExisted
            )
        } catch let error as ImageAssetImportError {
            removeDirectoryIfNewAndEmpty(assetsDirectory, existed: directoryExisted)
            throw error
        } catch {
            removeDirectoryIfNewAndEmpty(assetsDirectory, existed: directoryExisted)
            throw ImageAssetImportError.copyFailed
        }
    }

    private func resolvedDestination(
        assetsDirectory: URL,
        originalFilename: String,
        collisionResolution: ImageAssetCollisionResolution
    ) throws -> URL {
        let original = assetsDirectory.appendingPathComponent(originalFilename)
        if collisionResolution == .numberedSequence {
            let name = original.deletingPathExtension().lastPathComponent
            let pathExtension = original.pathExtension
            for suffix in 1...10_000 {
                let number = String(format: "%03d", suffix)
                let filename = pathExtension.isEmpty
                    ? "\(name)-\(number)"
                    : "\(name)-\(number).\(pathExtension)"
                let candidate = assetsDirectory.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            throw ImageAssetImportError.copyFailed
        }
        guard collisionResolution == .incrementName,
              FileManager.default.fileExists(atPath: original.path)
        else { return original }
        let name = original.deletingPathExtension().lastPathComponent
        let pathExtension = original.pathExtension
        for suffix in 2...10_000 {
            let filename = pathExtension.isEmpty
                ? "\(name)-\(suffix)"
                : "\(name)-\(suffix).\(pathExtension)"
            let candidate = assetsDirectory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ImageAssetImportError.copyFailed
    }

    private func removeDirectoryIfNewAndEmpty(_ directory: URL, existed: Bool) {
        guard !existed,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              ),
              contents.isEmpty
        else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class ImageAssetDirectoryAccess: ObservableObject {
    private struct Access {
        let url: URL
        let isSecurityScopeActive: Bool
    }

    private var accesses: [String: Access] = [:]

    func authorize(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard accesses[key] == nil else { return }
        accesses[key] = Access(
            url: url,
            isSecurityScopeActive: url.startAccessingSecurityScopedResource()
        )
    }

    deinit {
        for access in accesses.values where access.isSecurityScopeActive {
            access.url.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
enum ImageAssetPicker {
    static func chooseSource(attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.prompt = "选择图片"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    static func choosePlacement(
        filename: String,
        attachedTo window: NSWindow?
    ) async -> ExistingImagePlacement? {
        let alert = NSAlert()
        alert.messageText = "如何引用这张图片？"
        alert.informativeText = "复制会把 \(filename) 放入文档同级 assets；保留原位置不会复制图片，但移动文档或原图后引用可能失效。"
        alert.addButton(withTitle: "复制到 assets")
        alert.addButton(withTitle: "保留原位置")
        alert.addButton(withTitle: "取消")
        let response = await run(alert, attachedTo: window)
        switch response {
        case .alertFirstButtonReturn:
            return .copyToAssets
        case .alertSecondButtonReturn:
            return .keepOriginal
        default:
            return nil
        }
    }

    static func confirmAbsoluteReference(
        filename: String,
        attachedTo window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "这张图片无法使用稳定的相对路径"
        alert.informativeText = "继续会在 Markdown 中写入 \(filename) 的绝对本地地址。移动或分享文档后引用通常会失效，并可能暴露本机文件夹信息。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保留绝对引用")
        alert.addButton(withTitle: "取消")
        return await run(alert, attachedTo: window) == .alertFirstButtonReturn
    }

    static func authorizeDocumentDirectory(
        _ documentDirectory: URL,
        attachedTo window: NSWindow?
    ) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "授权 assets 文件夹"
        panel.message = "请选择当前 Markdown 文档所在的文件夹。Inflow 只会在其中创建或更新 assets。"
        panel.prompt = "授权此文件夹"
        panel.directoryURL = documentDirectory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        guard await run(panel, attachedTo: window) == .OK, let selected = panel.url else {
            return nil
        }
        guard selected.standardizedFileURL == documentDirectory.standardizedFileURL else {
            throw ImageAssetImportError.unauthorizedDirectory
        }
        return selected
    }

    static func resolveCollision(
        filename: String,
        attachedTo window: NSWindow?
    ) async -> ImageAssetCollisionResolution? {
        let alert = NSAlert()
        alert.messageText = "assets 中已存在同名图片"
        alert.informativeText = "\(filename) 已存在。请明确选择覆盖，或保留原文件并使用递增名称。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保留并递增名称")
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "取消")
        let response = await run(alert, attachedTo: window)
        switch response {
        case .alertFirstButtonReturn:
            return ImageAssetCollisionResolution.incrementName
        case .alertSecondButtonReturn:
            return ImageAssetCollisionResolution.replace
        default:
            return nil
        }
    }

    private static func run(_ panel: NSOpenPanel, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return panel.runModal() }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func run(_ alert: NSAlert, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
