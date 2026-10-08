import AppKit
import CoreGraphics
import Foundation
import PDFKit

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

    /// Produces PDF from the same revision-bound native render plan used by the
    /// editable and read-only editor surfaces. HTML is deliberately not an
    /// input here: keeping PDF on the native path prevents an export-only
    /// renderer from becoming a second interpretation of Markdown.
    static func generate(snapshot: HTMLExportSnapshot) async throws -> Data {
        try Task.checkCancellation()
        let markdown = String(decoding: snapshot.utf8, as: UTF8.self)
        let session = MarkdownSourceEditorSession(role: .renderedProjection)
        session.scrollView.frame = NSRect(origin: .zero, size: printableSize)
        session.scrollView.layoutSubtreeIfNeeded()
        let appearance = snapshot.appearance.nativeRenderedAppearance(spellingEnabled: false)
        session.textView.string = markdown
        session.applySourceAppearance(appearance, force: true)
        guard let derived = await session.deriveContent(
            for: markdown,
            configuration: snapshot.appearance
        ) else {
            throw PDFExportError.renderingFailed
        }
        try Task.checkCancellation()
        session.installSharedRenderedPlan(derived.nativeRenderPlan, source: markdown)
        session.textView.appearance = snapshot.appearance.colorScheme.nativeAppearance
        session.setPresentation(
            .rendered,
            source: markdown,
            onLinkClick: nil,
            resourceContext: RenderedMarkdownResourceContext(
                documentDirectory: snapshot.documentDirectory,
                projectRoot: snapshot.projectRoot,
                expectedProjectRootIdentity: snapshot.expectedProjectRootIdentity,
                requiresProjectBoundary: snapshot.requiresProjectBoundary
            ),
            theme: snapshot.appearance.theme
        )
        await session.waitForRenderedResources()
        try Task.checkCancellation()
        let view = session.textView
        view.frame = NSRect(origin: .zero, size: printableSize)
        view.textContainer?.containerSize = NSSize(
            width: printableSize.width,
            height: .greatestFiniteMagnitude
        )
        view.prepareRenderedLayoutForPrinting()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let usedHeight = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0
        view.frame.size.height = max(printableSize.height, ceil(usedHeight + view.textContainerInset.height * 2))
        view.layoutSubtreeIfNeeded()
        view.prepareRenderedLayoutForPrinting()

        var sourcePages: [Data] = []
        var pageOriginY = 0.0
        repeat {
            let pageHeight = min(
                printableSize.height,
                max(1, view.bounds.height - pageOriginY)
            )
            sourcePages.append(
                view.dataWithPDF(
                    inside: NSRect(
                        x: 0,
                        y: pageOriginY,
                        width: printableSize.width,
                        height: pageHeight
                    )
                )
            )
            pageOriginY += pageHeight
            try Task.checkCancellation()
        } while pageOriginY < view.bounds.height

        // Reuse the rendered document's resolved surface, including custom CSS.
        // Resolving a default palette here would paint different-colored margins.
        let composed = try composeA4Document(
            from: sourcePages,
            pageBackgroundColor: view.backgroundColor.cgColor
        )
        let output = try addingSafeLinkAnnotations(
            to: composed,
            links: derived.nativeRenderPlan.links,
            in: view
        )
        try Task.checkCancellation()
        return try PDFContainerPrivacySanitizer.sanitize(output)
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
                else { continue }
                let translatedBounds = annotation.bounds.offsetBy(
                    dx: margin - sourceBox.minX,
                    dy: paperSize.height - margin - sourceBox.height - sourceBox.minY
                )
                guard translatedBounds.width > 0,
                      translatedBounds.height > 0,
                      mediaBox.contains(translatedBounds)
                else { continue }
                context.setURL(url as CFURL, for: translatedBounds)
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard output.length > 0 else { throw PDFExportError.renderingFailed }
        return output as Data
    }

    private static func addingSafeLinkAnnotations(
        to data: Data,
        links: [RenderedMarkdownLink],
        in view: NSTextView
    ) throws -> Data {
        guard let document = PDFDocument(data: data),
              let layoutManager = view.layoutManager,
              let textContainer = view.textContainer
        else { throw PDFExportError.invalidOutput }

        for link in links {
            guard let url = URL(string: link.target), isSafeWebURL(url) else { continue }
            let characterRange = link.textRange.utf16Range
            guard NSMaxRange(characterRange) <= (view.string as NSString).length else {
                throw PDFExportError.invalidOutput
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                _, _, _, lineGlyphRange, _ in
                let intersection = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard intersection.length > 0 else { return }
                let rect = layoutManager.boundingRect(
                    forGlyphRange: intersection,
                    in: textContainer
                ).offsetBy(
                    dx: view.textContainerOrigin.x,
                    dy: view.textContainerOrigin.y
                )
                let pageIndex = max(0, Int(floor(rect.midY / printableSize.height)))
                guard let page = document.page(at: pageIndex) else { return }
                let localTop = rect.minY - CGFloat(pageIndex) * printableSize.height
                let bounds = NSRect(
                    x: margin + rect.minX,
                    y: paperSize.height - margin - localTop - rect.height,
                    width: rect.width,
                    height: rect.height
                )
                guard bounds.width > 0,
                      bounds.height > 0,
                      page.bounds(for: .mediaBox).contains(bounds)
                else { return }
                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .link,
                    withProperties: nil
                )
                annotation.action = PDFActionURL(url: url)
                page.addAnnotation(annotation)
            }
        }
        guard let annotated = document.dataRepresentation(), !annotated.isEmpty else {
            throw PDFExportError.renderingFailed
        }
        return annotated
    }

    private static func isSafeWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else { return false }
        return true
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
