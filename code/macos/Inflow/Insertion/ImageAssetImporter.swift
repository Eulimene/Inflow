import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ValidatedLocalImage: Sendable {
    let data: Data
    let mimeType: String
}

struct LocalImageFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

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

    static func load(
        at url: URL,
        expectedIdentity: LocalImageFileIdentity? = nil,
        onWillRead: (() throws -> Void)? = nil,
        afterRead: (() throws -> Void)? = nil
    ) throws -> ValidatedLocalImage {
        let data: Data
        do {
            data = try LocalImageDescriptorReader.read(
                at: url,
                expectedIdentity: expectedIdentity,
                maximumBytes: maximumBytes,
                onWillRead: onWillRead,
                afterRead: afterRead
            )
        } catch let error as LocalImageValidationError {
            throw error
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

}

enum LocalImageDescriptorReader {
    static func captureIdentity(at url: URL) throws -> LocalImageFileIdentity {
        let descriptor = try openDescriptor(at: url)
        defer { Darwin.close(descriptor) }
        return try identity(of: descriptor)
    }

    static func read(
        at url: URL,
        expectedIdentity: LocalImageFileIdentity? = nil,
        maximumBytes: Int,
        onWillRead: (() throws -> Void)? = nil,
        afterRead: (() throws -> Void)? = nil
    ) throws -> Data {
        let descriptor = try openDescriptor(at: url)
        defer { Darwin.close(descriptor) }

        let beforeRead = try identity(of: descriptor)
        if let expectedIdentity, beforeRead != expectedIdentity {
            throw LocalImageValidationError.notRegularOrUnreadable
        }
        guard beforeRead.size >= 0 else {
            throw LocalImageValidationError.notRegularOrUnreadable
        }
        guard beforeRead.size <= maximumBytes else {
            throw LocalImageValidationError.tooLarge
        }

        try onWillRead?()

        var data = Data()
        data.reserveCapacity(min(Int(beforeRead.size), 1_024 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw LocalImageValidationError.notRegularOrUnreadable
            }
            guard data.count <= maximumBytes - count else {
                throw LocalImageValidationError.tooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        try afterRead?()

        let afterRead = try identity(of: descriptor)
        guard afterRead == beforeRead,
              data.count == Int(afterRead.size)
        else {
            throw LocalImageValidationError.notRegularOrUnreadable
        }
        return data
    }

    private static func openDescriptor(at url: URL) throws -> Int32 {
        errno = 0
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw LocalImageValidationError.notRegularOrUnreadable
        }
        return descriptor
    }

    private static func identity(of descriptor: Int32) throws -> LocalImageFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else {
            throw LocalImageValidationError.notRegularOrUnreadable
        }
        return LocalImageFileIdentity(metadata: metadata)
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
        for kind in [ClipboardImageKind.png, .jpeg] {
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
            throw LocalImageValidationError.unsafeOrUnsupported
        }
    }
}

enum ImageAssetCollisionResolution: Sendable, Equatable {
    case failIfExists
    case replace
    case incrementName
    case numberedSequence
}

enum ExistingImageCollisionDecision: Sendable, Equatable {
    case incrementName
    case replace
    case keepOriginal
}

enum ExistingImagePlacement: Sendable, Equatable {
    case copyToAssets
    case copyToRelativeDirectory
    case keepOriginal
}

enum ExistingImagePlacementPreference: String, CaseIterable, Identifiable, Sendable {
    case copyToAssets
    case copyToRelativeDirectory
    case keepOriginal
    case askEveryTime

    var id: Self { self }

    var label: String {
        switch self {
        case .copyToAssets: "复制到文档同级 assets"
        case .copyToRelativeDirectory: "复制到指定相对目录…"
        case .keepOriginal: "保留原位置"
        case .askEveryTime: "每次询问"
        }
    }

    var automaticPlacement: ExistingImagePlacement? {
        switch self {
        case .copyToAssets: .copyToAssets
        case .copyToRelativeDirectory: .copyToRelativeDirectory
        case .keepOriginal: .keepOriginal
        case .askEveryTime: nil
        }
    }
}

struct ImageAssetDirectoryPlan: Equatable, Sendable {
    private struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let generation: UInt32

        static func capture(_ url: URL) throws -> Self {
            var metadata = stat()
            errno = 0
            let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &metadata)
            }
            guard status == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR
            else {
                throw ImageAssetImportError.unauthorizedDirectory
            }
            return Self(
                device: UInt64(metadata.st_dev),
                inode: metadata.st_ino,
                generation: metadata.st_gen
            )
        }
    }

    let documentDirectory: URL
    let directoryURL: URL
    let relativeComponents: [String]
    let allowsCreation: Bool
    private let expectedIdentity: Identity?

    static func assets(in documentDirectory: URL) -> Self {
        let root = documentDirectory.standardizedFileURL
        return Self(
            documentDirectory: root,
            directoryURL: root.appendingPathComponent("assets", isDirectory: true),
            relativeComponents: ["assets"],
            allowsCreation: true,
            expectedIdentity: nil
        )
    }

    static func selected(
        _ selectedDirectory: URL,
        relativeTo documentDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        let root = documentDirectory.standardizedFileURL
        let selected = selectedDirectory.standardizedFileURL
        let relativeComponents = try validatedRelativeComponents(
            from: root,
            to: selected
        )
        let plan = Self(
            documentDirectory: root,
            directoryURL: selected,
            relativeComponents: relativeComponents,
            allowsCreation: false,
            expectedIdentity: try Identity.capture(selected)
        )
        _ = try plan.validatedDirectory(
            createIfNeeded: false,
            fileManager: fileManager
        )
        return plan
    }

    var markdownDirectoryPath: String {
        relativeComponents.map(Self.encodedPathComponent).joined(separator: "/")
    }

    func validatedDirectory(
        createIfNeeded: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = documentDirectory.standardizedFileURL
        guard root.isFileURL,
              directoryURL.standardizedFileURL == relativeComponents.reduce(root, {
                  $0.appendingPathComponent($1, isDirectory: true)
              })
        else {
            throw ImageAssetImportError.unauthorizedDirectory
        }

        let rootValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw ImageAssetImportError.unauthorizedDirectory
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ImageAssetImportError.unauthorizedDirectory
        }

        var current = root
        for (index, component) in relativeComponents.enumerated() {
            current.appendPathComponent(component, isDirectory: true)
            if !fileManager.fileExists(atPath: current.path) {
                let isFinalComponent = index == relativeComponents.indices.last
                guard createIfNeeded, allowsCreation, isFinalComponent else {
                    throw ImageAssetImportError.unauthorizedDirectory
                }
                do {
                    try fileManager.createDirectory(
                        at: current,
                        withIntermediateDirectories: false
                    )
                } catch {
                    throw ImageAssetImportError.copyFailed
                }
            }
            let values: URLResourceValues
            do {
                values = try current.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                throw ImageAssetImportError.unauthorizedDirectory
            }
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ImageAssetImportError.unauthorizedDirectory
            }
        }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = current.resolvingSymlinksInPath().standardizedFileURL
        _ = try Self.validatedRelativeComponents(from: resolvedRoot, to: resolvedDirectory)
        if let expectedIdentity,
           try Identity.capture(current) != expectedIdentity
        {
            throw ImageAssetImportError.destinationChanged
        }
        return current
    }

    private static func validatedRelativeComponents(
        from root: URL,
        to candidate: URL
    ) throws -> [String] {
        guard root.isFileURL, candidate.isFileURL else {
            throw ImageAssetImportError.unauthorizedDirectory
        }
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else {
            throw ImageAssetImportError.unauthorizedDirectory
        }
        let relative = Array(candidateComponents.dropFirst(rootComponents.count))
        guard !relative.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ImageAssetImportError.unauthorizedDirectory
        }
        return relative
    }

    static func encodedPathComponent(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
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
            "请选择当前 Markdown 文档所在目录或其真实子目录。"
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
        try importClipboardImage(
            image,
            directoryPlan: .assets(in: documentDirectory)
        )
    }

    func importClipboardImage(
        _ image: ValidatedLocalImage,
        directoryPlan: ImageAssetDirectoryPlan
    ) throws -> ImportedImageAsset {
        try importAsset(
            image: image,
            originalFilename: image.mimeType == "image/jpeg" ? "image.jpg" : "image.png",
            directoryPlan: directoryPlan,
            collisionResolution: .numberedSequence,
            expectedDestination: nil
        )
    }

    func destinationSnapshot(
        documentDirectory: URL,
        originalFilename: String
    ) throws -> ImageAssetDestinationSnapshot {
        try destinationSnapshot(
            directoryPlan: .assets(in: documentDirectory),
            originalFilename: originalFilename
        )
    }

    func destinationSnapshot(
        directoryPlan: ImageAssetDirectoryPlan,
        originalFilename: String
    ) throws -> ImageAssetDestinationSnapshot {
        let directory: URL
        if directoryPlan.allowsCreation,
           !FileManager.default.fileExists(atPath: directoryPlan.directoryURL.path)
        {
            directory = directoryPlan.directoryURL
        } else {
            directory = try directoryPlan.validatedDirectory(createIfNeeded: false)
        }
        return try ImageAssetDestinationSnapshot.capture(
            directory
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
        try importAsset(
            image: image,
            originalFilename: originalFilename,
            directoryPlan: .assets(in: documentDirectory),
            collisionResolution: collisionResolution,
            expectedDestination: expectedDestination
        )
    }

    func importAsset(
        image: ValidatedLocalImage,
        originalFilename: String,
        directoryPlan: ImageAssetDirectoryPlan,
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
        let assetDirectory = directoryPlan.directoryURL
        let directoryExisted = fileManager.fileExists(atPath: assetDirectory.path)
        let createdDirectory = !directoryExisted && directoryPlan.allowsCreation
        do {
            let validatedDirectory = try directoryPlan.validatedDirectory(
                createIfNeeded: true,
                fileManager: fileManager
            )
            let destinationURL = try resolvedDestination(
                assetsDirectory: validatedDirectory,
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
            let encodedFilename = ImageAssetDirectoryPlan.encodedPathComponent(
                destinationURL.lastPathComponent
            )
            let relativePath = [directoryPlan.markdownDirectoryPath, encodedFilename]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            return ImportedImageAsset(
                destinationURL: destinationURL,
                relativeMarkdownPath: relativePath,
                importedData: image.data,
                previousData: previousData,
                createdAssetsDirectory: createdDirectory
            )
        } catch let error as ImageAssetImportError {
            removeDirectoryIfNewAndEmpty(assetDirectory, existed: !createdDirectory)
            throw error
        } catch {
            removeDirectoryIfNewAndEmpty(assetDirectory, existed: !createdDirectory)
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

struct ResourceDirectoryAuthorizationRecord: Codable, Equatable, Sendable {
    let exactPath: String
    let bookmark: Data
    let authorizedAt: Date
}

@MainActor
protocol ResourceDirectoryAuthorizationPersistence: AnyObject {
    func load() -> [ResourceDirectoryAuthorizationRecord]
    func save(_ records: [ResourceDirectoryAuthorizationRecord])
}

@MainActor
final class UserDefaultsResourceDirectoryAuthorizationPersistence:
    ResourceDirectoryAuthorizationPersistence
{
    static let recordsKey = "resources.directory-authorizations.v1"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsResourceDirectoryAuthorizationPersistence.recordsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [ResourceDirectoryAuthorizationRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode(
            [ResourceDirectoryAuthorizationRecord].self,
            from: data
        )) ?? []
    }

    func save(_ records: [ResourceDirectoryAuthorizationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class ImageAssetDirectoryAccess: ObservableObject {
    typealias BookmarkResolver = (Data) -> (url: URL, isStale: Bool)?

    private struct Access {
        let url: URL
        let isSecurityScopeActive: Bool
    }

    @Published private(set) var authorizationVersion = 0

    private static let maximumPersistedDirectories = 100
    private var accesses: [String: Access] = [:]
    private let persistence: ResourceDirectoryAuthorizationPersistence
    private let bookmarkData: (URL) throws -> Data
    private let resolveBookmark: BookmarkResolver
    private let beginAccess: (URL) -> Bool
    private let endAccess: (URL) -> Void

    init(
        persistence: ResourceDirectoryAuthorizationPersistence =
            UserDefaultsResourceDirectoryAuthorizationPersistence(),
        bookmarkData: @escaping (URL) throws -> Data = { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: @escaping BookmarkResolver = { data in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                return nil
            }
            return (url, stale)
        },
        beginAccess: @escaping (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        endAccess: @escaping (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.persistence = persistence
        self.bookmarkData = bookmarkData
        self.resolveBookmark = resolveBookmark
        self.beginAccess = beginAccess
        self.endAccess = endAccess
    }

    func authorize(_ url: URL) {
        let exactURL = url.standardizedFileURL
        let key = exactURL.path
        guard accesses[key] == nil else { return }
        accesses[key] = Access(
            url: exactURL,
            isSecurityScopeActive: beginAccess(exactURL)
        )
        authorizationVersion &+= 1
    }

    /// Registers a directory that is already covered by the security-scoped
    /// lease retained by the system picker owner, such as a selected project.
    /// Selecting the directory is the user decision; no second app-level
    /// authorization is required.
    func registerUserSelectedDirectory(_ directory: URL) {
        let exactURL = directory.standardizedFileURL
        guard accesses[exactURL.path] == nil else { return }
        accesses[exactURL.path] = Access(
            url: exactURL,
            isSecurityScopeActive: false
        )
        authorizationVersion &+= 1
    }

    func authorizePersistently(_ directory: URL, now: Date = Date()) throws {
        let exactURL = directory.standardizedFileURL
        let bookmark = try bookmarkData(exactURL)
        var records = persistence.load().filter {
            $0.exactPath != exactURL.path
        }
        records.insert(
            ResourceDirectoryAuthorizationRecord(
                exactPath: exactURL.path,
                bookmark: bookmark,
                authorizedAt: now
            ),
            at: 0
        )
        persistence.save(Array(records.prefix(Self.maximumPersistedDirectories)))
        authorize(exactURL)
    }

    @discardableResult
    func restoreAuthorization(for directory: URL) -> Bool {
        let exactURL = directory.standardizedFileURL
        var records = persistence.load()
        guard let index = records.firstIndex(where: {
            $0.exactPath == exactURL.path
        }), let resolved = resolveBookmark(records[index].bookmark),
              resolved.url.standardizedFileURL.path == exactURL.path
        else {
            records.removeAll { $0.exactPath == exactURL.path }
            persistence.save(records)
            return false
        }

        authorize(resolved.url)
        if resolved.isStale, let refreshed = try? bookmarkData(resolved.url) {
            records[index] = ResourceDirectoryAuthorizationRecord(
                exactPath: exactURL.path,
                bookmark: refreshed,
                authorizedAt: records[index].authorizedAt
            )
            persistence.save(records)
        }
        return true
    }

    func isAuthorized(_ directory: URL) -> Bool {
        let exactURL = directory.standardizedFileURL
        return accesses.values.contains {
            FolderProjectPathBoundary.contains(exactURL, in: $0.url)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            for access in accesses.values where access.isSecurityScopeActive {
                endAccess(access.url)
            }
        }
    }
}

@MainActor
enum ImageAssetPicker {
    static let documentDirectoryPanelTitle = "选择文档所在文件夹"
    static let documentDirectoryPanelMessage =
        "请选择当前 Markdown 文档所在的文件夹，用于创建或更新 assets。"
    static let documentDirectoryPanelPrompt = "使用此文件夹"

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
        alert.informativeText = "可将 \(filename) 复制到文档同级 assets 或你选择的文档内相对目录。保留原位置不会复制图片，但移动文档或原图后引用可能失效。"
        alert.addButton(withTitle: "复制到 assets")
        alert.addButton(withTitle: "选择相对目录…")
        alert.addButton(withTitle: "保留原位置")
        let cancelButton = alert.addButton(withTitle: "取消")
        cancelButton.keyEquivalent = "\u{1b}"
        let response = await run(alert, attachedTo: window)
        return placementDecision(for: response)
    }

    static func placementDecision(
        for response: NSApplication.ModalResponse
    ) -> ExistingImagePlacement? {
        switch response {
        case .alertFirstButtonReturn:
            return .copyToAssets
        case .alertSecondButtonReturn:
            return .copyToRelativeDirectory
        case .alertThirdButtonReturn:
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

    static func chooseDocumentDirectory(
        _ documentDirectory: URL,
        attachedTo window: NSWindow?
    ) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = documentDirectoryPanelTitle
        panel.message = documentDirectoryPanelMessage
        panel.prompt = documentDirectoryPanelPrompt
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

    static func chooseRelativeAssetDirectory(
        relativeTo documentDirectory: URL,
        attachedTo window: NSWindow?
    ) async throws -> ImageAssetDirectoryPlan? {
        let panel = NSOpenPanel()
        panel.title = "选择相对资源目录"
        panel.message = "请选择当前 Markdown 文档所在目录或其子目录。不会允许符号链接或目录外位置。"
        panel.prompt = "使用此目录"
        panel.directoryURL = documentDirectory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard await run(panel, attachedTo: window) == .OK, let selected = panel.url else {
            return nil
        }
        let accessIsActive = selected.startAccessingSecurityScopedResource()
        defer {
            if accessIsActive { selected.stopAccessingSecurityScopedResource() }
        }
        return try ImageAssetDirectoryPlan.selected(
            selected,
            relativeTo: documentDirectory
        )
    }

    static func resolveExistingImageCollision(
        filename: String,
        attachedTo window: NSWindow?
    ) async -> ExistingImageCollisionDecision? {
        let alert = NSAlert()
        alert.messageText = "资源目录中已存在同名图片"
        alert.informativeText = "\(filename) 已存在。请选择使用递增名称、明确覆盖，或改为引用原图位置。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保留并递增名称")
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "保留原位置")
        let cancelButton = alert.addButton(withTitle: "取消")
        cancelButton.keyEquivalent = "\u{1b}"
        let response = await run(alert, attachedTo: window)
        return existingImageCollisionDecision(for: response)
    }

    static func existingImageCollisionDecision(
        for response: NSApplication.ModalResponse
    ) -> ExistingImageCollisionDecision? {
        switch response {
        case .alertFirstButtonReturn:
            return .incrementName
        case .alertSecondButtonReturn:
            return .replace
        case .alertThirdButtonReturn:
            return .keepOriginal
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
