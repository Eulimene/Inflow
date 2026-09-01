import AppKit
import CoreGraphics
import Foundation
import PDFKit
import WebKit

enum PDFExportError: Error, LocalizedError, Equatable {
    case renderingFailed
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .renderingFailed:
            "PDF 排版失败，未创建文件。当前 Markdown 不受影响。"
        case .invalidOutput:
            "PDF 交付物无法完整校验，未写入目标。"
        }
    }
}

@MainActor
enum PDFExporter {
    static let paperSize = NSSize(width: 595.28, height: 841.89)
    static let margin = 20.0 / 25.4 * 72.0

    private static var printableSize: NSSize {
        NSSize(
            width: paperSize.width - margin * 2,
            height: paperSize.height - margin * 2
        )
    }

    static func generate(fromSelfContainedHTML html: Data) async throws -> Data {
        try Task.checkCancellation()
        guard var htmlString = String(data: html, encoding: .utf8) else {
            throw PDFExportError.renderingFailed
        }
        htmlString = applyingPrintStyle(to: htmlString)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: printableSize),
            configuration: configuration
        )
        let loader = PDFWebViewLoader()
        webView.navigationDelegate = loader
        try await loader.load(htmlString, in: webView)
        try Task.checkCancellation()
        try await fitWideDisplayFormulae(in: webView)
        try Task.checkCancellation()

        let pageBackgroundColor = try await measuredPageBackgroundColor(in: webView)
        try Task.checkCancellation()

        let contentHeight = try await measuredContentHeight(in: webView)
        try Task.checkCancellation()
        var pageData: [Data] = []
        var pageOriginY = 0.0
        repeat {
            let pageHeight = min(printableSize.height, max(1, contentHeight - pageOriginY))
            let pdfConfiguration = WKPDFConfiguration()
            pdfConfiguration.rect = CGRect(
                x: 0,
                y: pageOriginY,
                width: printableSize.width,
                height: pageHeight
            )
            do {
                pageData.append(try await webView.pdf(configuration: pdfConfiguration))
            } catch {
                throw PDFExportError.renderingFailed
            }
            try Task.checkCancellation()
            pageOriginY += pageHeight
        } while pageOriginY < contentHeight

        try Task.checkCancellation()
        let data = try composeA4Document(
            from: pageData,
            pageBackgroundColor: pageBackgroundColor
        )
        guard let document = PDFDocument(data: data), document.pageCount == pageData.count else {
            throw PDFExportError.renderingFailed
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw PDFExportError.invalidOutput
            }
            let bounds = page.bounds(for: .mediaBox)
            guard abs(bounds.width - paperSize.width) < 1,
                  abs(bounds.height - paperSize.height) < 1
            else {
                throw PDFExportError.invalidOutput
            }
        }
        return try PDFContainerPrivacySanitizer.sanitize(data)
    }

    private static func fitWideDisplayFormulae(in webView: WKWebView) async throws {
        let script = """
        (() => {
          for (const formula of document.querySelectorAll('math[display="block"]')) {
            formula.style.transform = '';
            const availableWidth = Math.min(
              document.documentElement.clientWidth,
              formula.parentElement ? formula.parentElement.clientWidth : Number.POSITIVE_INFINITY
            );
            const content = formula.firstElementChild;
            const requiredWidth = Math.max(
              formula.scrollWidth,
              content ? content.getBoundingClientRect().width : 0
            );
            if (availableWidth <= 0 || requiredWidth <= availableWidth) continue;

            const scale = availableWidth / requiredWidth * 0.98;
            if (!Number.isFinite(scale) || scale <= 0) return false;
            formula.style.transformOrigin = 'left top';
            formula.style.transform = `scale(${scale})`;
            formula.style.overflow = 'visible';

            const fittedWidth = formula.getBoundingClientRect().width;
            if (fittedWidth > availableWidth + 1) return false;
          }
          return true;
        })()
        """
        let result: Any?
        do {
            result = try await webView.evaluateJavaScript(script)
        } catch {
            throw PDFExportError.renderingFailed
        }
        guard (result as? NSNumber)?.boolValue == true else {
            throw PDFExportError.renderingFailed
        }
    }

    private static func measuredContentHeight(in webView: WKWebView) async throws -> CGFloat {
        let script = """
        Math.ceil(Math.max(
          document.body ? document.body.scrollHeight : 0,
          document.documentElement ? document.documentElement.scrollHeight : 0
        ))
        """
        let value: Any?
        do {
            value = try await webView.evaluateJavaScript(script)
        } catch {
            throw PDFExportError.renderingFailed
        }
        guard let number = value as? NSNumber,
              number.doubleValue.isFinite,
              number.doubleValue > 0
        else {
            throw PDFExportError.renderingFailed
        }
        return CGFloat(number.doubleValue)
    }

    private static func measuredPageBackgroundColor(in webView: WKWebView) async throws
        -> CGColor
    {
        let value: Any?
        do {
            value = try await webView.evaluateJavaScript(
                "getComputedStyle(document.body).backgroundColor"
            )
        } catch {
            throw PDFExportError.renderingFailed
        }
        guard let cssColor = value as? String else {
            throw PDFExportError.renderingFailed
        }
        return try pageBackgroundColor(fromCSS: cssColor)
    }

    static func pageBackgroundColor(fromCSS value: String) throws -> CGColor {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let prefix: String
        if normalized.hasPrefix("rgba(") {
            prefix = "rgba("
        } else if normalized.hasPrefix("rgb(") {
            prefix = "rgb("
        } else {
            throw PDFExportError.renderingFailed
        }
        guard normalized.hasSuffix(")") else {
            throw PDFExportError.renderingFailed
        }
        let start = normalized.index(normalized.startIndex, offsetBy: prefix.count)
        let end = normalized.index(before: normalized.endIndex)
        let components = normalized[start..<end]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count == 3 || components.count == 4,
              let red = Double(components[0]),
              let green = Double(components[1]),
              let blue = Double(components[2]),
              (0 ... 255).contains(red),
              (0 ... 255).contains(green),
              (0 ... 255).contains(blue)
        else {
            throw PDFExportError.renderingFailed
        }
        if components.count == 4 {
            guard let alpha = Double(components[3]), alpha >= 0.999, alpha <= 1 else {
                throw PDFExportError.renderingFailed
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(
                  colorSpace: colorSpace,
                  components: [red / 255, green / 255, blue / 255, 1]
              )
        else {
            throw PDFExportError.renderingFailed
        }
        return color
    }

    private static func composeA4Document(
        from sourcePages: [Data],
        pageBackgroundColor: CGColor
    ) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw PDFExportError.renderingFailed
        }
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFExportError.renderingFailed
        }

        for sourceData in sourcePages {
            guard let provider = CGDataProvider(data: sourceData as CFData),
                  let sourceDocument = CGPDFDocument(provider),
                  sourceDocument.numberOfPages == 1,
                  let sourcePage = sourceDocument.page(at: 1),
                  let sourceKitDocument = PDFDocument(data: sourceData),
                  let sourceKitPage = sourceKitDocument.page(at: 0)
            else {
                throw PDFExportError.invalidOutput
            }
            let sourceBox = sourcePage.getBoxRect(.mediaBox)
            guard sourceBox.width > 0,
                  sourceBox.height > 0,
                  sourceBox.width <= printableSize.width + 1,
                  sourceBox.height <= printableSize.height + 1
            else {
                throw PDFExportError.invalidOutput
            }

            context.beginPDFPage(nil)
            context.saveGState()
            context.setFillColor(pageBackgroundColor)
            context.fill(mediaBox)
            context.restoreGState()
            context.saveGState()
            context.translateBy(
                x: margin - sourceBox.minX,
                y: paperSize.height - margin - sourceBox.height - sourceBox.minY
            )
            context.drawPDFPage(sourcePage)
            context.restoreGState()
            for annotation in sourceKitPage.annotations {
                guard let action = annotation.action as? PDFActionURL,
                      let url = action.url,
                      isSafeWebURL(url)
                else {
                    continue
                }
                let translatedBounds = annotation.bounds.offsetBy(
                    dx: margin - sourceBox.minX,
                    dy: paperSize.height - margin - sourceBox.height - sourceBox.minY
                )
                guard translatedBounds.width > 0,
                      translatedBounds.height > 0,
                      mediaBox.contains(translatedBounds)
                else {
                    continue
                }
                context.setURL(url as CFURL, for: translatedBounds)
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard output.length > 0 else {
            throw PDFExportError.renderingFailed
        }
        return output as Data
    }

    private static func isSafeWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else {
            return false
        }
        return true
    }

    private static func applyingPrintStyle(to html: String) -> String {
        let style = """
        <style>
          @page { size: A4 portrait; margin: 0; }
          *, *::before, *::after { box-sizing: border-box; }
          html, body { width: 100% !important; max-width: 100% !important; margin: 0 !important; padding: 0 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          img, svg, table, pre, math { max-width: 100% !important; }
          pre { white-space: pre-wrap !important; overflow: visible !important; overflow-wrap: anywhere; word-break: break-word; }
          pre code { white-space: inherit !important; }
          table { display: table !important; width: 100% !important; table-layout: fixed; overflow: visible !important; }
          th, td { overflow-wrap: anywhere; word-break: break-word; }
          .mermaid-diagram { overflow: visible !important; }
          .mermaid-diagram svg { min-width: 0 !important; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid-page; }
          pre, table, img, svg, math { break-inside: avoid-page; }
        </style>
        """
        return html.replacingOccurrences(of: "</head>", with: "\(style)</head>")
    }
}

/// Quartz writes the host macOS build and export timestamps into the PDF Info
/// object even when no metadata dictionary is supplied. Inflow clears that
/// object in place so page offsets and the cross-reference table remain exact,
/// while the delivered bytes no longer disclose host details.
enum PDFContainerPrivacySanitizer {
    private static let infoReferenceExpression = try! NSRegularExpression(
        pattern: #"/Info\s+([0-9]+)\s+([0-9]+)\s+R"#
    )
    private static let trailerMarker = Data("\ntrailer\n".utf8)
    private static let endObjectMarker = Data("endobj".utf8)

    static func sanitize(_ data: Data) throws -> Data {
        guard let trailerRange = data.range(
            of: trailerMarker,
            options: .backwards
        ) else {
            throw PDFExportError.invalidOutput
        }
        let trailerData = Data(data[trailerRange.lowerBound...])
        guard let trailer = String(data: trailerData, encoding: .isoLatin1) else {
            throw PDFExportError.invalidOutput
        }
        let fullRange = NSRange(location: 0, length: (trailer as NSString).length)
        guard let match = infoReferenceExpression.firstMatch(
            in: trailer,
            range: fullRange
        ), let objectNumberRange = Range(match.range(at: 1), in: trailer),
           let generationRange = Range(match.range(at: 2), in: trailer)
        else {
            throw PDFExportError.invalidOutput
        }

        let objectNumber = trailer[objectNumberRange]
        let generation = trailer[generationRange]
        let objectHeader = Data("\n\(objectNumber) \(generation) obj".utf8)
        guard let headerRange = data.range(
            of: objectHeader,
            options: .backwards,
            in: data.startIndex..<trailerRange.lowerBound
        ), let endRange = data.range(
            of: endObjectMarker,
            in: headerRange.upperBound..<trailerRange.lowerBound
        ) else {
            throw PDFExportError.invalidOutput
        }

        let payloadRange = headerRange.upperBound..<endRange.lowerBound
        let emptyInfo = Data("\n<< >>\n".utf8)
        guard payloadRange.count >= emptyInfo.count else {
            throw PDFExportError.invalidOutput
        }
        var replacement = emptyInfo
        replacement.append(
            Data(repeating: 0x20, count: payloadRange.count - emptyInfo.count)
        )
        var sanitized = data
        sanitized.replaceSubrange(payloadRange, with: replacement)

        guard sanitized.count == data.count else {
            throw PDFExportError.invalidOutput
        }
        try PDFDeliveryPostflight.validate(sanitized)
        return sanitized
    }
}

/// Final fail-closed validation for the exact bytes written to a PDF target.
///
/// The A4 compositor creates a new Core Graphics document and only paints each
/// source page. This postflight verifies that the resulting object graph did
/// not acquire unsafe document actions, embedded payloads, XMP or local paths.
/// Link annotations are accepted only for plain http/https destinations.
/// Page-content stream bytes are deliberately not interpreted as
/// metadata: Markdown may legitimately discuss PDF names or local-path syntax.
enum PDFDeliveryPostflight {
    private static let expectedA4Width: CGFloat = 595.28
    private static let expectedA4Height: CGFloat = 841.89

    private static let forbiddenDictionaryKeys: Set<String> = [
        "AA",
        "AcroForm",
        "AF",
        "Collection",
        "EF",
        "EmbeddedFile",
        "EmbeddedFiles",
        "JavaScript",
        "JS",
        "Launch",
        "Metadata",
        "OpenAction",
        "Outlines",
        "RichMedia",
        "RichMediaContent",
        "RichMediaSettings",
    ]

    private static let forbiddenMetadataKeys: Set<String> = [
        "Author",
        "CreationDate",
        "Creator",
        "Keywords",
        "ModDate",
        "Producer",
        "Subject",
        "Title",
        "Trapped",
    ]

    private static let externalFileStringKeys: Set<String> = [
        "DOS",
        "F",
        "FS",
        "Mac",
        "RF",
        "UF",
        "Unix",
    ]

    private static let forbiddenNameValues: Set<String> = [
        "EmbeddedFile",
        "Filespec",
        "GoToE",
        "GoToR",
        "ImportData",
        "JavaScript",
        "Launch",
        "Movie",
        "Rendition",
        "Sound",
        "SubmitForm",
    ]

    static func validate(_ data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let coreDocument = CGPDFDocument(provider),
              coreDocument.numberOfPages > 0,
              !coreDocument.isEncrypted,
              let catalog = coreDocument.catalog,
              let info = coreDocument.info,
              CGPDFDictionaryGetCount(info) == 0,
              let kitDocument = PDFDocument(data: data),
              kitDocument.pageCount == coreDocument.numberOfPages,
              (kitDocument.documentAttributes ?? [:]).isEmpty
        else {
            throw PDFExportError.invalidOutput
        }

        try validateLinkAnnotations(in: kitDocument)

        let scanner = PDFObjectGraphScanner(
            forbiddenDictionaryKeys: forbiddenDictionaryKeys,
            forbiddenMetadataKeys: forbiddenMetadataKeys,
            externalFileStringKeys: externalFileStringKeys,
            forbiddenNameValues: forbiddenNameValues
        )
        try scanner.inspect(dictionary: catalog)
        try scanner.inspect(dictionary: info)

        for pageIndex in 1 ... coreDocument.numberOfPages {
            guard let page = coreDocument.page(at: pageIndex),
                  let pageDictionary = page.dictionary
            else {
                throw PDFExportError.invalidOutput
            }
            let mediaBox = page.getBoxRect(.mediaBox)
            guard mediaBox.width.isFinite,
                  mediaBox.height.isFinite,
                  abs(mediaBox.width - expectedA4Width) < 1,
                  abs(mediaBox.height - expectedA4Height) < 1
            else {
                throw PDFExportError.invalidOutput
            }
            try scanner.inspect(dictionary: pageDictionary)
        }
    }

    private static func validateLinkAnnotations(in document: PDFDocument) throws {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw PDFExportError.invalidOutput
            }
            for annotation in page.annotations {
                // PDFKit reports the same subtype as either `Link` or `/Link`
                // depending on the macOS release and how the PDF was parsed.
                guard annotation.type?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                ) == "Link",
                      let action = annotation.action as? PDFActionURL,
                      let url = action.url,
                      isSafeWebURL(url),
                      annotation.bounds.width > 0,
                      annotation.bounds.height > 0,
                      page.bounds(for: .mediaBox).contains(annotation.bounds),
                      annotation.value(forAnnotationKey: .additionalActions) == nil,
                      annotation.value(forAnnotationKey: .destination) == nil
                else {
                    throw PDFExportError.invalidOutput
                }
            }
        }
    }

    private static func isSafeWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else {
            return false
        }
        return true
    }
}

private final class PDFObjectGraphScanner {
    private let forbiddenDictionaryKeys: Set<String>
    private let forbiddenMetadataKeys: Set<String>
    private let externalFileStringKeys: Set<String>
    private let forbiddenNameValues: Set<String>

    private var visitedDictionaries = Set<UInt>()
    private var visitedArrays = Set<UInt>()
    private var visitedStreams = Set<UInt>()
    private var inspectedObjectCount = 0

    private let maximumDepth = 128
    private let maximumObjectCount = 100_000

    init(
        forbiddenDictionaryKeys: Set<String>,
        forbiddenMetadataKeys: Set<String>,
        externalFileStringKeys: Set<String>,
        forbiddenNameValues: Set<String>
    ) {
        self.forbiddenDictionaryKeys = forbiddenDictionaryKeys
        self.forbiddenMetadataKeys = forbiddenMetadataKeys
        self.externalFileStringKeys = externalFileStringKeys
        self.forbiddenNameValues = forbiddenNameValues
    }

    func inspect(dictionary: CGPDFDictionaryRef) throws {
        try inspect(dictionary: dictionary, depth: 0)
    }

    private func inspect(dictionary: CGPDFDictionaryRef, depth: Int) throws {
        guard try registerContainer(
            identity: unsafeBitCast(dictionary, to: UInt.self),
            depth: depth,
            insert: { visitedDictionaries.insert($0).inserted }
        ) else {
            return
        }

        var scanError: Error?
        CGPDFDictionaryApplyBlock(
            dictionary,
            { keyPointer, object, _ in
                guard scanError == nil else { return false }
                let key = String(cString: keyPointer)
                do {
                    guard !self.forbiddenDictionaryKeys.contains(key),
                          !self.forbiddenMetadataKeys.contains(key)
                    else {
                        throw PDFExportError.invalidOutput
                    }
                    try self.inspect(object: object, dictionaryKey: key, depth: depth + 1)
                } catch {
                    scanError = error
                    return false
                }
                return true
            },
            nil
        )
        if let scanError {
            throw scanError
        }
    }

    private func inspect(array: CGPDFArrayRef, depth: Int) throws {
        guard try registerContainer(
            identity: unsafeBitCast(array, to: UInt.self),
            depth: depth,
            insert: { visitedArrays.insert($0).inserted }
        ) else {
            return
        }

        var scanError: Error?
        CGPDFArrayApplyBlock(
            array,
            { _, object, _ in
                guard scanError == nil else { return false }
                do {
                    try self.inspect(object: object, dictionaryKey: nil, depth: depth + 1)
                } catch {
                    scanError = error
                    return false
                }
                return true
            },
            nil
        )
        if let scanError {
            throw scanError
        }
    }

    private func inspect(stream: CGPDFStreamRef, depth: Int) throws {
        let identity = unsafeBitCast(stream, to: UInt.self)
        guard try registerContainer(
            identity: identity,
            depth: depth,
            insert: { visitedStreams.insert($0).inserted }
        ) else {
            return
        }
        guard let dictionary = CGPDFStreamGetDictionary(stream) else {
            throw PDFExportError.invalidOutput
        }
        try inspect(dictionary: dictionary, depth: depth + 1)
    }

    private func inspect(
        object: CGPDFObjectRef,
        dictionaryKey: String?,
        depth: Int
    ) throws {
        guard depth <= maximumDepth else {
            throw PDFExportError.invalidOutput
        }
        inspectedObjectCount += 1
        guard inspectedObjectCount <= maximumObjectCount else {
            throw PDFExportError.invalidOutput
        }

        switch CGPDFObjectGetType(object) {
        case .name:
            var namePointer: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &namePointer),
                  let namePointer
            else {
                throw PDFExportError.invalidOutput
            }
            let name = String(cString: namePointer)
            guard !forbiddenNameValues.contains(name),
                  !(dictionaryKey.map(externalFileStringKeys.contains) ?? false)
            else {
                throw PDFExportError.invalidOutput
            }

        case .string:
            var pdfString: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &pdfString),
                  let pdfString,
                  let string = CGPDFStringCopyTextString(pdfString) as String?
            else {
                throw PDFExportError.invalidOutput
            }
            guard !(dictionaryKey.map(externalFileStringKeys.contains) ?? false),
                  !Self.containsAbsoluteLocalPath(string)
            else {
                throw PDFExportError.invalidOutput
            }

        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array else {
                throw PDFExportError.invalidOutput
            }
            try inspect(array: array, depth: depth)

        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary),
                  let dictionary
            else {
                throw PDFExportError.invalidOutput
            }
            try inspect(dictionary: dictionary, depth: depth)

        case .stream:
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else {
                throw PDFExportError.invalidOutput
            }
            try inspect(stream: stream, depth: depth)

        case .null, .boolean, .integer, .real:
            break

        default:
            throw PDFExportError.invalidOutput
        }
    }

    private func registerContainer(
        identity: UInt,
        depth: Int,
        insert: (UInt) -> Bool
    ) throws -> Bool {
        guard depth <= maximumDepth else {
            throw PDFExportError.invalidOutput
        }
        return insert(identity)
    }

    private static func containsAbsoluteLocalPath(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let lowercased = normalized.lowercased()
        if lowercased.hasPrefix("file:") || lowercased.hasPrefix("~/") {
            return true
        }
        let unixPrefixes = [
            "/applications/",
            "/etc/",
            "/home/",
            "/library/",
            "/opt/",
            "/private/",
            "/system/",
            "/tmp/",
            "/users/",
            "/usr/",
            "/var/",
            "/volumes/",
        ]
        if unixPrefixes.contains(where: lowercased.hasPrefix) {
            return true
        }
        let scalars = Array(normalized.unicodeScalars)
        return scalars.count >= 3
            && CharacterSet.letters.contains(scalars[0])
            && scalars[1].value == 0x3A
            && scalars[2].value == 0x2F
    }
}

@MainActor
private final class PDFWebViewLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        continuation?.resume(throwing: PDFExportError.renderingFailed)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        continuation?.resume(throwing: PDFExportError.renderingFailed)
        continuation = nil
    }
}

@MainActor
enum PDFExportPanel {
    static func chooseDestination(suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出 PDF"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.pdf]
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
