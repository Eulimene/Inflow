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
        let data = try composeA4Document(from: pageData)
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
        return data
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

    private static func composeA4Document(from sourcePages: [Data]) throws -> Data {
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
                  let sourcePage = sourceDocument.page(at: 1)
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
            context.translateBy(
                x: margin - sourceBox.minX,
                y: paperSize.height - margin - sourceBox.height - sourceBox.minY
            )
            context.drawPDFPage(sourcePage)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard output.length > 0 else {
            throw PDFExportError.renderingFailed
        }
        return output as Data
    }

    private static func applyingPrintStyle(to html: String) -> String {
        let style = """
        <style>
          @page { size: A4 portrait; margin: 0; }
          html, body { width: auto !important; max-width: none !important; margin: 0 !important; padding: 0 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          img, svg, table, pre, math { max-width: 100% !important; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid-page; }
          pre, table, img, svg, math { break-inside: avoid-page; }
        </style>
        """
        return html.replacingOccurrences(of: "</head>", with: "\(style)</head>")
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
