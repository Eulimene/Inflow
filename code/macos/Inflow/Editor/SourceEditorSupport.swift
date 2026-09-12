import AppKit
import Foundation

struct RenderedMarkdownResourceContext: Equatable, Sendable {
    let documentDirectory: URL?
    let projectRoot: URL?
    let expectedProjectRootIdentity: FolderProjectDirectoryIdentity?
    let requiresProjectBoundary: Bool

    static let unavailable = Self(
        documentDirectory: nil,
        projectRoot: nil,
        expectedProjectRootIdentity: nil,
        requiresProjectBoundary: false
    )
}

enum RenderedMarkdownImageTarget: Equatable, Sendable {
    case remote(URL)
    case local(URL)

    static func resolve(_ target: String, documentDirectory: URL?) -> Self? {
        if let components = URLComponents(string: target),
           let scheme = components.scheme?.lowercased()
        {
            if scheme == "http" || scheme == "https" {
                guard components.host?.isEmpty == false,
                      components.user == nil,
                      components.password == nil,
                      let url = components.url
                else { return nil }
                return .remote(url)
            }
            guard scheme == "file",
                  components.host == nil || components.host?.isEmpty == true
                    || components.host == "localhost",
                  components.user == nil,
                  components.password == nil,
                  let path = components.percentEncodedPath.removingPercentEncoding,
                  !path.isEmpty
            else { return nil }
            return .local(URL(fileURLWithPath: path).standardizedFileURL)
        }
        if target.hasPrefix("/") {
            guard let path = target.removingPercentEncoding else { return nil }
            return .local(URL(fileURLWithPath: path).standardizedFileURL)
        }
        guard let documentDirectory,
              let url = URL(string: target, relativeTo: documentDirectory)?.absoluteURL,
              url.isFileURL
        else { return nil }
        return .local(url.standardizedFileURL)
    }
}

actor RenderedMarkdownImageLoader {
    static let shared = RenderedMarkdownImageLoader()

    private var remoteCache: [URL: Data] = [:]
    private var remoteCacheOrder: [URL] = []
    private let maximumRemoteEntries = 24

    func load(target: String, context: RenderedMarkdownResourceContext) async -> Data? {
        guard !Task.isCancelled, !target.isEmpty,
              let resolved = RenderedMarkdownImageTarget.resolve(
                  target,
                  documentDirectory: context.documentDirectory
              )
        else { return nil }
        if case let .remote(remoteURL) = resolved { return await loadRemote(remoteURL) }
        guard case let .local(localURL) = resolved else { return nil }

        let readsOutsideProject: Bool
        if let projectRoot = context.projectRoot,
           let normalizedRoot = try? FolderProjectPathBoundary.normalizedProjectRoot(projectRoot),
           context.expectedProjectRootIdentity.map({
               FolderProjectDirectoryIdentity.capture(normalizedRoot) == $0
           }) ?? true
        {
            readsOutsideProject = FolderProjectPathBoundary.resolvedURL(
                localURL,
                within: normalizedRoot
            ) == nil
        } else {
            readsOutsideProject = false
        }

        return try? ProjectBoundLocalImageLoader.load(
            at: localURL,
            projectRoot: readsOutsideProject ? nil : context.projectRoot,
            expectedProjectRootIdentity: readsOutsideProject
                ? nil : context.expectedProjectRootIdentity,
            requiresProjectBoundary: readsOutsideProject
                ? false : context.requiresProjectBoundary
        ).data
    }

    private func loadRemote(_ url: URL) async -> Data? {
        if let cached = remoteCache[url] { return cached }
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              data.count <= LocalImageValidator.maximumBytes,
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true
        else { return nil }
        remoteCache[url] = data
        remoteCacheOrder.removeAll { $0 == url }
        remoteCacheOrder.append(url)
        while remoteCacheOrder.count > maximumRemoteEntries {
            remoteCache.removeValue(forKey: remoteCacheOrder.removeFirst())
        }
        return data
    }
}

extension RenderedMarkdownMarkerKind {
    var remainsVisibleWhenInactive: Bool {
        switch self {
        case .orderedList: true
        case .unorderedList, .taskList, .rule, .footnoteReference, .footnoteDefinition: false
        case .heading, .blockQuote, .referenceDefinition, .emphasis, .strong, .strikethrough,
             .inlineCode, .tableBoundary, .tableSeparator, .tableDelimiterRow, .linkDelimiter,
             .linkDestination, .mathDelimiter: false
        }
    }
}

enum MarkdownEditorPresentation: Equatable {
    case source
    case rendered
}

struct SourceSelectionRequest: Equatable {
    let generation: Int
    let utf8Range: Range<Int>
    let style: SourceSelectionStyle
    let focusesEditor: Bool

    init(
        generation: Int,
        utf8Range: Range<Int>,
        style: SourceSelectionStyle = .caret,
        focusesEditor: Bool = true
    ) {
        self.generation = generation
        self.utf8Range = utf8Range
        self.style = style
        self.focusesEditor = focusesEditor
    }
}

enum SourceSelectionStyle: Equatable {
    case caret
    case match
    var showsTransientMatchIndicator: Bool { self == .match }
}

struct SourceNavigationTarget: Equatable {
    let revealRange: NSRange
    let caretRange: NSRange
}

enum MarkdownSourceRange {
    static func utf8Range(
        forUTF16Range utf16Range: NSRange,
        in text: String
    ) -> Range<Int>? {
        let utf16 = text.utf16
        guard utf16Range.location >= 0,
              utf16Range.length >= 0,
              utf16Range.location <= utf16.count,
              utf16Range.length <= utf16.count - utf16Range.location,
              let lowerUTF16 = utf16.index(
                  utf16.startIndex,
                  offsetBy: utf16Range.location,
                  limitedBy: utf16.endIndex
              ),
              let upperUTF16 = utf16.index(
                  lowerUTF16,
                  offsetBy: utf16Range.length,
                  limitedBy: utf16.endIndex
              ),
              let lower = String.Index(lowerUTF16, within: text),
              let upper = String.Index(upperUTF16, within: text),
              let lowerUTF8 = lower.samePosition(in: text.utf8),
              let upperUTF8 = upper.samePosition(in: text.utf8)
        else { return nil }

        let lowerOffset = text.utf8.distance(from: text.utf8.startIndex, to: lowerUTF8)
        let upperOffset = text.utf8.distance(from: text.utf8.startIndex, to: upperUTF8)
        return lowerOffset..<upperOffset
    }

    static func navigationTarget(
        forUTF8Range utf8Range: Range<Int>,
        in text: String
    ) -> SourceNavigationTarget? {
        guard utf8Range.lowerBound >= 0,
              utf8Range.lowerBound <= utf8Range.upperBound,
              utf8Range.upperBound <= text.utf8.count,
              let lowerUTF8 = text.utf8.index(
                  text.utf8.startIndex,
                  offsetBy: utf8Range.lowerBound,
                  limitedBy: text.utf8.endIndex
              ),
              let upperUTF8 = text.utf8.index(
                  text.utf8.startIndex,
                  offsetBy: utf8Range.upperBound,
                  limitedBy: text.utf8.endIndex
              ),
              let lower = String.Index(lowerUTF8, within: text),
              let upper = String.Index(upperUTF8, within: text)
        else { return nil }

        let revealRange = NSRange(lower..<upper, in: text)
        return SourceNavigationTarget(
            revealRange: revealRange,
            caretRange: NSRange(location: revealRange.location, length: 0)
        )
    }
}
