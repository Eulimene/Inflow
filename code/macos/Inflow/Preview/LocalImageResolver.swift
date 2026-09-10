import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProjectBoundLocalImageError: Error, Equatable {
    case outsideProject
}

enum ProjectBoundLocalImageLoader {
    static func load(
        at requestedURL: URL,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false,
        afterIdentityCapture: (() throws -> Void)? = nil,
        beforeOpen: (() throws -> Void)? = nil,
        onWillRead: (() throws -> Void)? = nil
    ) throws -> ValidatedLocalImage {
        let accessed = requestedURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { requestedURL.stopAccessingSecurityScopedResource() }
        }

        guard let projectRoot else {
            guard !requiresProjectBoundary else {
                throw ProjectBoundLocalImageError.outsideProject
            }
            return try LocalImageValidator.load(
                at: requestedURL,
                onWillRead: onWillRead
            )
        }
        guard !requiresProjectBoundary || expectedProjectRootIdentity != nil else {
            throw ProjectBoundLocalImageError.outsideProject
        }
        guard let normalizedRoot = try? FolderProjectPathBoundary.normalizedProjectRoot(
            projectRoot
        ), let capturedURL = FolderProjectPathBoundary.resolvedURL(
            requestedURL,
            within: normalizedRoot
        ), projectRootIsCurrent(
            normalizedRoot,
            expectedIdentity: expectedProjectRootIdentity
        ) else {
            throw ProjectBoundLocalImageError.outsideProject
        }

        let expectedIdentity = try LocalImageDescriptorReader.captureIdentity(at: capturedURL)
        try afterIdentityCapture?()

        guard projectRootIsCurrent(
            normalizedRoot,
            expectedIdentity: expectedProjectRootIdentity
        ), let revalidatedURL = FolderProjectPathBoundary.resolvedURL(
            requestedURL,
            within: normalizedRoot
        ), revalidatedURL.standardizedFileURL.path == capturedURL.standardizedFileURL.path
        else {
            throw ProjectBoundLocalImageError.outsideProject
        }

        try beforeOpen?()
        guard projectRootIsCurrent(
            normalizedRoot,
            expectedIdentity: expectedProjectRootIdentity
        ) else {
            throw ProjectBoundLocalImageError.outsideProject
        }
        return try LocalImageValidator.load(
            at: revalidatedURL,
            expectedIdentity: expectedIdentity,
            onWillRead: {
                guard projectRootIsCurrent(
                    normalizedRoot,
                    expectedIdentity: expectedProjectRootIdentity
                ) else {
                    throw ProjectBoundLocalImageError.outsideProject
                }
                try onWillRead?()
            }
        )
    }

    private static func projectRootIsCurrent(
        _ projectRoot: URL,
        expectedIdentity: FolderProjectDirectoryIdentity?
    ) -> Bool {
        guard let expectedIdentity else { return true }
        return FolderProjectDirectoryIdentity.capture(projectRoot) == expectedIdentity
    }
}

enum LocalImageResolver {
    struct ExportResolution: Sendable {
        let html: String
        let hasWarnings: Bool
    }

    private static let slotExpression = try! NSRegularExpression(
        pattern: #"<span class="inflow-image-slot" data-inflow-target="([0-9a-f]*)" data-inflow-alt="([0-9a-f]*)"></span>"#
    )

    static func resolveSlots(
        in fragment: String,
        documentDirectory: URL?,
        imageReferences: [MarkdownReference] = [],
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false
    ) -> String {
        resolution(
            in: fragment,
            documentDirectory: documentDirectory,
            imageReferences: imageReferences,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            allowsOutsideProject: true
        ).html
    }

    private static func resolution(
        in fragment: String,
        documentDirectory: URL?,
        imageReferences: [MarkdownReference] = [],
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false,
        allowsOutsideProject: Bool = false,
        sanitizesImageMetadata: Bool = false
    ) -> (html: String, hasFailure: Bool) {
        let fullRange = NSRange(location: 0, length: (fragment as NSString).length)
        let matches = slotExpression.matches(in: fragment, range: fullRange)
        guard !matches.isEmpty else { return (fragment, false) }

        let output = NSMutableString(string: fragment)
        var hasFailure = false
        let referencesMatchSlots = imageReferences.count == matches.count
        for (index, match) in matches.enumerated().reversed() {
            guard let target = decodedHexString(
                (fragment as NSString).substring(with: match.range(at: 1))
            ), let alternative = decodedHexString(
                (fragment as NSString).substring(with: match.range(at: 2))
            ) else {
                hasFailure = true
                output.replaceCharacters(
                    in: match.range,
                    with: warning(title: "无法读取图片引用", detail: "图片引用不是有效的 UTF-8。")
                )
                continue
            }

            let reference = referencesMatchSlots ? imageReferences[index] : nil
            let warningContext: WarningContext? = if let reference,
                                                     reference.kind == .image,
                                                     UTF8Text.isExactlyEqual(reference.target, target),
                                                     target.utf8.count <= 16 * 1_024,
                                                     !target.unicodeScalars.contains(where: {
                                                         CharacterSet.controlCharacters.contains($0)
                                                     })
            {
                WarningContext(
                    sourceUTF8Offset: reference.sourceUTF8Range.lowerBound,
                    target: target
                )
            } else {
                nil
            }

            let replacement = resolvedImage(
                target: target,
                alternative: alternative,
                documentDirectory: documentDirectory,
                projectRoot: projectRoot,
                expectedProjectRootIdentity: expectedProjectRootIdentity,
                requiresProjectBoundary: requiresProjectBoundary,
                allowsOutsideProject: allowsOutsideProject,
                warningContext: warningContext,
                sanitizesMetadata: sanitizesImageMetadata
            )
            if !replacement.hasPrefix("<img class=\"inflow-local-image\"")
                && !replacement.hasPrefix("<img class=\"inflow-remote-image\"")
            {
                hasFailure = true
            }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return (output as String, hasFailure)
    }

    static func resolveSlotsForExport(
        in fragment: String,
        documentDirectory: URL?,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false
    ) throws -> String {
        let result = resolution(
            in: fragment,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            sanitizesImageMetadata: true
        )
        guard !result.hasFailure else {
            throw LocalImageExportError.unavailableResource
        }
        return result.html
    }

    static func resolveSlotsForPreparedExport(
        in fragment: String,
        documentDirectory: URL?,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false
    ) -> ExportResolution {
        let result = resolution(
            in: fragment,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            sanitizesImageMetadata: true
        )
        return ExportResolution(html: result.html, hasWarnings: result.hasFailure)
    }

    private static func resolvedImage(
        target: String,
        alternative: String,
        documentDirectory: URL?,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity?,
        requiresProjectBoundary: Bool,
        allowsOutsideProject: Bool,
        warningContext: WarningContext?,
        sanitizesMetadata: Bool
    ) -> String {
        guard !target.isEmpty else {
            return warning(
                title: "找不到资源",
                detail: "图片地址为空，原引用已保留。",
                kind: .local,
                context: warningContext
            )
        }

        if let absolute = URL(string: target), let scheme = absolute.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                guard let components = URLComponents(url: absolute, resolvingAgainstBaseURL: false),
                      components.host?.isEmpty == false,
                      components.user == nil,
                      components.password == nil,
                      let remoteURL = components.url
                else {
                    return warning(
                        title: "无法预览这个图片地址",
                        detail: "在线图片地址无效，原引用已保留。",
                        kind: .remote,
                        context: warningContext
                    )
                }
                let label = alternative.isEmpty ? remoteURL.lastPathComponent : alternative
                return "<img class=\"inflow-remote-image\" src=\"\(escapeAttribute(remoteURL.absoluteString))\" alt=\"\(escapeAttribute(label))\" loading=\"lazy\" referrerpolicy=\"no-referrer\">"
            }
            guard scheme == "file", absolute.isFileURL else {
                return warning(
                    title: "无法预览这个图片地址",
                    detail: "只支持已授权的本地 PNG 或 JPEG。",
                    kind: .local,
                    context: warningContext
                )
            }
            return loadImage(
                at: absolute,
                target: target,
                alternative: alternative,
                projectRoot: projectRoot,
                expectedProjectRootIdentity: expectedProjectRootIdentity,
                requiresProjectBoundary: requiresProjectBoundary,
                allowsOutsideProject: allowsOutsideProject,
                warningContext: warningContext,
                sanitizesMetadata: sanitizesMetadata
            )
        }

        guard let documentDirectory else {
            return warning(
                title: "暂时无法读取相对图片",
                detail: "请先保存文档，再检查 \(safeDisplayTarget(target))。",
                kind: .local,
                context: warningContext
            )
        }
        guard let resolvedURL = URL(string: target, relativeTo: documentDirectory)?.absoluteURL,
              resolvedURL.isFileURL
        else {
            return warning(
                title: "无法预览这个图片地址",
                detail: "\(safeDisplayTarget(target)) 不是有效的本地路径。",
                kind: .local,
                context: warningContext
            )
        }
        return loadImage(
            at: resolvedURL,
            target: target,
            alternative: alternative,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            allowsOutsideProject: allowsOutsideProject,
            warningContext: warningContext,
            sanitizesMetadata: sanitizesMetadata
        )
    }

    private static func outsideProjectWarning(
        target: String,
        warningContext: WarningContext?
    ) -> String {
        warning(
            title: "无法读取项目外图片",
            detail: "\(safeDisplayTarget(target)) 位于当前项目边界之外，原引用已保留。",
            kind: .local,
            context: warningContext
        )
    }

    private static func loadImage(
        at url: URL,
        target: String,
        alternative: String,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity?,
        requiresProjectBoundary: Bool,
        allowsOutsideProject: Bool,
        warningContext: WarningContext?,
        sanitizesMetadata: Bool
    ) -> String {
        let readsOutsideProject: Bool
        if let projectRoot,
           let normalizedRoot = try? FolderProjectPathBoundary.normalizedProjectRoot(
               projectRoot
           ),
           expectedProjectRootIdentity.map({
               FolderProjectDirectoryIdentity.capture(normalizedRoot) == $0
           }) ?? true
        {
            readsOutsideProject = FolderProjectPathBoundary.resolvedURL(
                url,
                within: normalizedRoot
            ) == nil
        } else {
            readsOutsideProject = false
        }

        let image: ValidatedLocalImage
        do {
            image = try ProjectBoundLocalImageLoader.load(
                at: url,
                projectRoot: allowsOutsideProject && readsOutsideProject ? nil : projectRoot,
                expectedProjectRootIdentity: allowsOutsideProject && readsOutsideProject
                    ? nil
                    : expectedProjectRootIdentity,
                requiresProjectBoundary: allowsOutsideProject && readsOutsideProject
                    ? false
                    : requiresProjectBoundary
            )
        } catch ProjectBoundLocalImageError.outsideProject {
            return outsideProjectWarning(
                target: target,
                warningContext: warningContext
            )
        } catch LocalImageValidationError.tooLarge {
            return warning(
                title: "图片过大，未载入预览",
                detail: "\(safeDisplayTarget(target)) 超过 100 MiB。引用仍保留。",
                kind: .local,
                context: warningContext
            )
        } catch LocalImageValidationError.extensionMismatch {
            return warning(
                title: "图片类型与扩展名不一致",
                detail: "为安全起见，未预览 \(safeDisplayTarget(target))。",
                kind: .local,
                context: warningContext
            )
        } catch LocalImageValidationError.unsafeOrUnsupported {
            return warning(
                title: "不支持这个图片",
                detail: "\(safeDisplayTarget(target)) 不是安全尺寸的静态 PNG 或 JPEG。",
                kind: .local,
                context: warningContext
            )
        } catch {
            return warning(
                title: "找不到资源",
                detail: "\(safeDisplayTarget(target)) 不存在、不可读或当前未授权。",
                kind: .local,
                context: warningContext
            )
        }

        let deliveryImage: ValidatedLocalImage
        do {
            deliveryImage = sanitizesMetadata
                ? try LocalImageExportSanitizer.sanitize(image)
                : image
        } catch {
            return warning(
                title: "无法安全处理图片",
                detail: "\(safeDisplayTarget(target)) 的私密元数据无法可靠移除。引用仍保留。",
                kind: .local,
                context: warningContext
            )
        }

        let label = alternative.isEmpty ? url.deletingPathExtension().lastPathComponent : alternative
        return "<img class=\"inflow-local-image\" src=\"data:\(deliveryImage.mimeType);base64,\(deliveryImage.data.base64EncodedString())\" alt=\"\(escapeAttribute(label))\">"
    }

    private enum WarningKind {
        case local
        case remote
    }

    private struct WarningContext {
        let sourceUTF8Offset: Int
        let target: String
    }

    private static func warning(
        title: String,
        detail: String,
        kind: WarningKind = .local,
        context: WarningContext? = nil
    ) -> String {
        let content = "<strong>\(escapeText(title))</strong><span>\(escapeText(detail))</span>"
        guard let context else {
            return "<span class=\"image-warning\" role=\"img\" aria-label=\"\(escapeAttribute(title)): \(escapeAttribute(detail))\">\(content)</span>"
        }
        let actions: String
        switch kind {
        case .local:
            actions = imageAction("replace", title: "选择替代文件…")
                + imageAction("locate", title: "定位引用")
                + imageAction("ignore", title: "忽略")
        case .remote:
            actions = imageAction("locate", title: "定位引用")
                + imageAction("copyTarget", title: "复制地址")
                + imageAction("ignore", title: "关闭")
        }
        return "<span class=\"image-warning\" role=\"group\" aria-label=\"\(escapeAttribute(title)): \(escapeAttribute(detail))\" data-inflow-image-source-start=\"\(context.sourceUTF8Offset)\" data-inflow-image-target-hex=\"\(hex(context.target))\">\(content)<span class=\"image-warning-actions\">\(actions)</span></span>"
    }

    private static func imageAction(_ action: String, title: String) -> String {
        "<button type=\"button\" data-inflow-image-action=\"\(action)\">\(title)</button>"
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeDisplayTarget(_ target: String) -> String {
        if let url = URL(string: target), url.isFileURL || url.scheme != nil {
            return url.lastPathComponent.isEmpty ? "该资源" : url.lastPathComponent
        }
        return target.removingPercentEncoding ?? target
    }

    private static func decodedHexString(_ hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Re-rasterizes an already validated static image before it becomes part of a
/// delivery artifact. The new container carries pixels only: source EXIF, GPS,
/// TIFF/IPTC fields, comments, filenames and device details are not copied.
enum LocalImageExportSanitizer {
    static func sanitize(_ image: ValidatedLocalImage) throws -> ValidatedLocalImage {
        guard let source = CGImageSourceCreateWithData(
            image.data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) == 1,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0,
           height > 0
        else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let raster = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }

        let destinationType: UTType
        let fileExtension: String
        let destinationProperties: [CFString: Any]?
        switch image.mimeType {
        case "image/png":
            destinationType = .png
            fileExtension = "png"
            destinationProperties = nil
        case "image/jpeg":
            destinationType = .jpeg
            fileExtension = "jpg"
            destinationProperties = [kCGImageDestinationLossyCompressionQuality: 1.0]
        default:
            throw LocalImageValidationError.unsafeOrUnsupported
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            destinationType.identifier as CFString,
            1,
            nil
        ) else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }
        CGImageDestinationAddImage(
            destination,
            raster,
            destinationProperties.map { $0 as CFDictionary }
        )
        guard CGImageDestinationFinalize(destination) else {
            throw LocalImageValidationError.unsafeOrUnsupported
        }
        return try LocalImageValidator.validate(
            data: output as Data,
            fileExtension: fileExtension
        )
    }
}

enum LocalImageExportError: Error, LocalizedError {
    case unavailableResource

    var errorDescription: String? {
        "HTML 导出需要的本地图片缺失、未授权、不受支持或不安全，未创建文件。"
    }
}
