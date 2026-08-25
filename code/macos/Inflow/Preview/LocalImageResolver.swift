import Foundation

enum LocalImageResolver {
    private static let slotExpression = try! NSRegularExpression(
        pattern: #"<span class="inflow-image-slot" data-inflow-target="([0-9a-f]*)" data-inflow-alt="([0-9a-f]*)"></span>"#
    )

    static func resolveSlots(in fragment: String, documentDirectory: URL?) -> String {
        resolution(in: fragment, documentDirectory: documentDirectory).html
    }

    private static func resolution(
        in fragment: String,
        documentDirectory: URL?
    ) -> (html: String, hasFailure: Bool) {
        let fullRange = NSRange(location: 0, length: (fragment as NSString).length)
        let matches = slotExpression.matches(in: fragment, range: fullRange)
        guard !matches.isEmpty else { return (fragment, false) }

        let output = NSMutableString(string: fragment)
        var hasFailure = false
        for match in matches.reversed() {
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

            let replacement = resolvedImage(
                target: target,
                alternative: alternative,
                documentDirectory: documentDirectory
            )
            if !replacement.hasPrefix("<img class=\"inflow-local-image\"") {
                hasFailure = true
            }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return (output as String, hasFailure)
    }

    static func resolveSlotsForExport(
        in fragment: String,
        documentDirectory: URL?
    ) throws -> String {
        let result = resolution(in: fragment, documentDirectory: documentDirectory)
        guard !result.hasFailure else {
            throw LocalImageExportError.unavailableResource
        }
        return result.html
    }

    private static func resolvedImage(
        target: String,
        alternative: String,
        documentDirectory: URL?
    ) -> String {
        guard !target.isEmpty else {
            return warning(title: "找不到资源", detail: "图片地址为空，原引用已保留。")
        }

        if let absolute = URL(string: target), let scheme = absolute.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return warning(
                    title: "远程图片未加载",
                    detail: "首发版不会连接远程图片地址。引用仍保留在 Markdown 中。"
                )
            }
            guard scheme == "file", absolute.isFileURL else {
                return warning(
                    title: "无法预览这个图片地址",
                    detail: "只支持已授权的本地 PNG 或 JPEG。"
                )
            }
            return loadImage(at: absolute, target: target, alternative: alternative)
        }

        guard let documentDirectory else {
            return warning(
                title: "暂时无法读取相对图片",
                detail: "请先保存文档，再检查 \(safeDisplayTarget(target))。"
            )
        }
        guard let resolvedURL = URL(string: target, relativeTo: documentDirectory)?.absoluteURL,
              resolvedURL.isFileURL
        else {
            return warning(
                title: "无法预览这个图片地址",
                detail: "\(safeDisplayTarget(target)) 不是有效的本地路径。"
            )
        }
        return loadImage(at: resolvedURL, target: target, alternative: alternative)
    }

    private static func loadImage(at url: URL, target: String, alternative: String) -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let image: ValidatedLocalImage
        do {
            image = try LocalImageValidator.load(at: url)
        } catch LocalImageValidationError.tooLarge {
            return warning(
                title: "图片过大，未载入预览",
                detail: "\(safeDisplayTarget(target)) 超过 100 MiB。引用仍保留。"
            )
        } catch LocalImageValidationError.extensionMismatch {
            return warning(
                title: "图片类型与扩展名不一致",
                detail: "为安全起见，未预览 \(safeDisplayTarget(target))。"
            )
        } catch LocalImageValidationError.unsafeOrUnsupported {
            return warning(
                title: "不支持这个图片",
                detail: "\(safeDisplayTarget(target)) 不是安全尺寸的静态 PNG 或 JPEG。"
            )
        } catch {
            return warning(
                title: "找不到资源",
                detail: "\(safeDisplayTarget(target)) 不存在、不可读或当前未授权。"
            )
        }

        let label = alternative.isEmpty ? url.deletingPathExtension().lastPathComponent : alternative
        return "<img class=\"inflow-local-image\" src=\"data:\(image.mimeType);base64,\(image.data.base64EncodedString())\" alt=\"\(escapeAttribute(label))\">"
    }

    private static func warning(title: String, detail: String) -> String {
        "<span class=\"image-warning\" role=\"img\" aria-label=\"\(escapeAttribute(title)): \(escapeAttribute(detail))\"><strong>\(escapeText(title))</strong><span>\(escapeText(detail))</span></span>"
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

enum LocalImageExportError: Error, LocalizedError {
    case unavailableResource

    var errorDescription: String? {
        "HTML 导出需要的本地图片缺失、未授权、不受支持或不安全，未创建文件。"
    }
}
