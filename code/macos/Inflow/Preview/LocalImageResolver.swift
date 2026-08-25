import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LocalImageResolver {
    private static let maximumPreviewBytes = 100 * 1_024 * 1_024
    private static let slotExpression = try! NSRegularExpression(
        pattern: #"<span class="inflow-image-slot" data-inflow-target="([0-9a-f]*)" data-inflow-alt="([0-9a-f]*)"></span>"#
    )

    static func resolveSlots(in fragment: String, documentDirectory: URL?) -> String {
        let fullRange = NSRange(location: 0, length: (fragment as NSString).length)
        let matches = slotExpression.matches(in: fragment, range: fullRange)
        guard !matches.isEmpty else { return fragment }

        let output = NSMutableString(string: fragment)
        for match in matches.reversed() {
            guard let target = decodedHexString(
                (fragment as NSString).substring(with: match.range(at: 1))
            ), let alternative = decodedHexString(
                (fragment as NSString).substring(with: match.range(at: 2))
            ) else {
                output.replaceCharacters(
                    in: match.range,
                    with: warning(title: "无法读取图片引用", detail: "图片引用不是有效的 UTF-8。")
                )
                continue
            }

            output.replaceCharacters(
                in: match.range,
                with: resolvedImage(
                    target: target,
                    alternative: alternative,
                    documentDirectory: documentDirectory
                )
            )
        }
        return output as String
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

        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true else {
                return warning(
                    title: "找不到资源",
                    detail: "\(safeDisplayTarget(target)) 不是可读取的普通文件。"
                )
            }
            guard let size = values.fileSize, size >= 0, size <= maximumPreviewBytes else {
                return warning(
                    title: "图片过大，未载入预览",
                    detail: "\(safeDisplayTarget(target)) 超过 100 MiB。引用仍保留。"
                )
            }
            data = try boundedData(at: url)
            guard data.count <= maximumPreviewBytes else {
                return warning(
                    title: "图片过大，未载入预览",
                    detail: "\(safeDisplayTarget(target)) 在读取时超过 100 MiB。引用仍保留。"
                )
            }
        } catch {
            return warning(
                title: "找不到资源",
                detail: "\(safeDisplayTarget(target)) 不存在、不可读或当前未授权。"
            )
        }

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
            return warning(
                title: "不支持这个图片",
                detail: "\(safeDisplayTarget(target)) 不是安全尺寸的静态 PNG 或 JPEG。"
            )
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
            return warning(
                title: "不支持这个图片",
                detail: "\(safeDisplayTarget(target)) 不是静态 PNG 或 JPEG。"
            )
        }

        guard expectedExtensions.contains(url.pathExtension.lowercased()) else {
            return warning(
                title: "图片类型与扩展名不一致",
                detail: "为安全起见，未预览 \(safeDisplayTarget(target))。"
            )
        }

        let label = alternative.isEmpty ? url.deletingPathExtension().lastPathComponent : alternative
        return "<img class=\"inflow-local-image\" src=\"data:\(mimeType);base64,\(data.base64EncodedString())\" alt=\"\(escapeAttribute(label))\">"
    }

    private static func boundedData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximumPreviewBytes, 1_024 * 1_024))
        while data.count <= maximumPreviewBytes {
            let remaining = maximumPreviewBytes + 1 - data.count
            let chunk = try handle.read(upToCount: min(remaining, 1_024 * 1_024))
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
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
