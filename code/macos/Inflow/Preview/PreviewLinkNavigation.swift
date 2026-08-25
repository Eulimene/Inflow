import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

enum PreviewLocalLinkKind: String, Equatable, Sendable {
    case markdown
    case image
    case pdf
    case attachment
}

struct PreviewLocalFileSnapshot: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    static func capture(_ url: URL) throws -> Self {
        var metadata = stat()
        errno = 0
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0 else {
            if errno == ENOENT {
                throw PreviewLocalFileError.missing
            }
            throw PreviewLocalFileError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw PreviewLocalFileError.notRegularFile
        }
        return Self(
            device: UInt64(metadata.st_dev),
            inode: metadata.st_ino,
            generation: metadata.st_gen,
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
            size: metadata.st_size,
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }
}

enum PreviewLocalFileError: Error, Equatable, Sendable {
    case missing
    case unavailable
    case notRegularFile
    case unsafeContent
}

struct PreviewExternalLink: Equatable, Sendable {
    let url: URL
    let displayDestination: String
}

struct PreviewLocalLink: Equatable, Sendable {
    let url: URL
    let fragment: String?
    let kind: PreviewLocalLinkKind
    let snapshot: PreviewLocalFileSnapshot
}

enum PreviewLinkFailureReason: Equatable, Sendable {
    case noLongerInDocument
    case invalidTarget
    case unsupportedScheme
    case relativeTargetNeedsSavedDocument
    case missingHeading
    case missingLocalTarget
    case unavailableLocalTarget
    case unsafeLocalTarget
    case cannotOpen
}

struct PreviewLinkFailure: Equatable, Sendable {
    let reason: PreviewLinkFailureReason
    let safeTarget: String
    let expectedURL: URL?
}

enum PreviewLinkDestination: Equatable, Sendable {
    case currentDocument(fragment: String?)
    case external(PreviewExternalLink)
    case local(PreviewLocalLink)
    case blocked(PreviewLinkFailure)
}

struct PreviewLinkPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceUTF8: Data
    let target: String
    let destination: PreviewLinkDestination

    init(sourceUTF8: Data, target: String, destination: PreviewLinkDestination) {
        id = UUID()
        self.sourceUTF8 = sourceUTF8
        self.target = target
        self.destination = destination
    }
}

actor PreviewLinkWorker {
    func plan(markdown: String, target: String, documentURL: URL?) -> PreviewLinkPlan {
        PreviewLinkPlanner.plan(markdown: markdown, target: target, documentURL: documentURL)
    }
}

enum PreviewLinkPlanner {
    private static let maximumTargetBytes = 16 * 1_024

    static func plan(markdown: String, target: String, documentURL: URL?) -> PreviewLinkPlan {
        let sourceUTF8 = Data(markdown.utf8)
        let safeTarget = safeDisplayTarget(target)
        let decodedTarget = target.removingPercentEncoding
        guard target.utf8.count <= maximumTargetBytes,
              let decodedTarget,
              !target.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
              }),
              !decodedTarget.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
              })
        else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .invalidTarget,
                safeTarget: safeTarget
            )
        }
        guard containsExactLink(target, in: markdown) else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .noLongerInDocument,
                safeTarget: safeTarget
            )
        }

        if target.isEmpty {
            return PreviewLinkPlan(
                sourceUTF8: sourceUTF8,
                target: target,
                destination: .currentDocument(fragment: nil)
            )
        }
        if target.hasPrefix("#") {
            guard let fragment = decodedComponent(String(target.dropFirst())) else {
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .invalidTarget,
                    safeTarget: safeTarget
                )
            }
            return PreviewLinkPlan(
                sourceUTF8: sourceUTF8,
                target: target,
                destination: .currentDocument(fragment: fragment.isEmpty ? nil : fragment)
            )
        }

        if let components = URLComponents(string: target),
           let scheme = components.scheme?.lowercased()
        {
            switch scheme {
            case "http", "https":
                guard components.host?.isEmpty == false,
                      components.user == nil,
                      components.password == nil,
                      let url = components.url
                else {
                    return blocked(
                        sourceUTF8: sourceUTF8,
                        target: target,
                        reason: .invalidTarget,
                        safeTarget: safeTarget
                    )
                }
                return PreviewLinkPlan(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    destination: .external(
                        PreviewExternalLink(
                            url: url,
                            displayDestination: components.host ?? "默认浏览器"
                        )
                    )
                )
            case "mailto":
                guard components.query == nil,
                      components.fragment == nil,
                      !components.path.isEmpty,
                      let url = components.url,
                      decodedComponent(components.path, permitsEmpty: false) != nil
                else {
                    return blocked(
                        sourceUTF8: sourceUTF8,
                        target: target,
                        reason: .invalidTarget,
                        safeTarget: safeTarget
                    )
                }
                return PreviewLinkPlan(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    destination: .external(
                        PreviewExternalLink(url: url, displayDestination: "默认邮件应用")
                    )
                )
            case "file":
                var fileComponents = components
                fileComponents.fragment = nil
                let fragment: String?
                if let encodedFragment = components.percentEncodedFragment {
                    guard let decoded = decodedComponent(encodedFragment) else {
                        return blocked(
                            sourceUTF8: sourceUTF8,
                            target: target,
                            reason: .invalidTarget,
                            safeTarget: safeTarget
                        )
                    }
                    fragment = decoded.isEmpty ? nil : decoded
                } else {
                    fragment = nil
                }
                guard components.query == nil,
                      components.user == nil,
                      components.password == nil,
                      components.host == nil || components.host?.isEmpty == true
                          || components.host?.lowercased() == "localhost",
                      let url = fileComponents.url,
                      url.isFileURL
                else {
                    return blocked(
                        sourceUTF8: sourceUTF8,
                        target: target,
                        reason: .invalidTarget,
                        safeTarget: safeTarget
                    )
                }
                return localPlan(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    url: url.standardizedFileURL,
                    fragment: fragment,
                    documentURL: documentURL
                )
            default:
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .unsupportedScheme,
                    safeTarget: safeTarget
                )
            }
        }

        guard !target.hasPrefix("//"),
              let parts = localParts(target),
              !parts.path.isEmpty
        else {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .invalidTarget,
                safeTarget: safeTarget
            )
        }
        let url: URL
        if parts.path.hasPrefix("/") {
            url = URL(fileURLWithPath: parts.path).standardizedFileURL
        } else {
            guard let documentURL else {
                return blocked(
                    sourceUTF8: sourceUTF8,
                    target: target,
                    reason: .relativeTargetNeedsSavedDocument,
                    safeTarget: safeTarget
                )
            }
            url = URL(
                fileURLWithPath: parts.path,
                relativeTo: documentURL.deletingLastPathComponent()
            ).standardizedFileURL
        }
        return localPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            url: url,
            fragment: parts.fragment,
            documentURL: documentURL
        )
    }

    static func isCurrent(_ plan: PreviewLinkPlan, markdown: String) -> Bool {
        plan.sourceUTF8 == Data(markdown.utf8)
            && containsExactLink(plan.target, in: markdown)
    }

    static func localTargetIsCurrent(_ link: PreviewLocalLink) -> Bool {
        (try? PreviewLocalFileSnapshot.capture(link.url)) == link.snapshot
    }

    private static func localPlan(
        sourceUTF8: Data,
        target: String,
        url: URL,
        fragment: String?,
        documentURL: URL?
    ) -> PreviewLinkPlan {
        if let documentURL,
           url.standardizedFileURL.path == documentURL.standardizedFileURL.path
        {
            return PreviewLinkPlan(
                sourceUTF8: sourceUTF8,
                target: target,
                destination: .currentDocument(fragment: fragment)
            )
        }

        let safeTarget = url.lastPathComponent.isEmpty ? "该本地目标" : url.lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let snapshot: PreviewLocalFileSnapshot
        do {
            snapshot = try PreviewLocalFileSnapshot.capture(url)
        } catch PreviewLocalFileError.missing {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .missingLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        } catch PreviewLocalFileError.notRegularFile {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .unsafeLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        } catch {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .unavailableLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        }

        let kind = localKind(for: url)
        do {
            switch kind {
            case .image:
                _ = try LocalImageValidator.load(at: url)
            case .pdf:
                guard let document = CGPDFDocument(url as CFURL),
                      document.numberOfPages > 0
                else {
                    throw PreviewLocalFileError.unsafeContent
                }
            case .markdown, .attachment:
                break
            }
            guard try PreviewLocalFileSnapshot.capture(url) == snapshot else {
                throw PreviewLocalFileError.unavailable
            }
        } catch {
            return blocked(
                sourceUTF8: sourceUTF8,
                target: target,
                reason: .unsafeLocalTarget,
                safeTarget: safeTarget,
                expectedURL: url
            )
        }

        return PreviewLinkPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            destination: .local(
                PreviewLocalLink(
                    url: url,
                    fragment: fragment,
                    kind: kind,
                    snapshot: snapshot
                )
            )
        )
    }

    private static func containsExactLink(_ target: String, in markdown: String) -> Bool {
        guard let references = try? MarkdownReferenceScanner.references(in: markdown) else {
            return false
        }
        let targetUTF8 = Data(target.utf8)
        return references.contains {
            $0.kind == .link && Data($0.target.utf8) == targetUTF8
        }
    }

    private static func localKind(for url: URL) -> PreviewLocalLinkKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "png", "jpg", "jpeg": .image
        case "pdf": .pdf
        default: .attachment
        }
    }

    private static func localParts(_ target: String) -> (path: String, fragment: String?)? {
        let beforeFragment: Substring
        let encodedFragment: Substring?
        if let hash = target.firstIndex(of: "#") {
            beforeFragment = target[..<hash]
            encodedFragment = target[target.index(after: hash)...]
        } else {
            beforeFragment = Substring(target)
            encodedFragment = nil
        }
        guard !beforeFragment.contains("?"),
              let path = decodedComponent(String(beforeFragment), permitsEmpty: false)
        else {
            return nil
        }
        let fragment: String?
        if let encodedFragment {
            guard let decoded = decodedComponent(String(encodedFragment)) else { return nil }
            fragment = decoded.isEmpty ? nil : decoded
        } else {
            fragment = nil
        }
        return (path, fragment?.isEmpty == true ? nil : fragment)
    }

    private static func decodedComponent(
        _ encoded: String?,
        permitsEmpty: Bool = true
    ) -> String? {
        guard let encoded else { return nil }
        guard permitsEmpty || !encoded.isEmpty,
              let decoded = encoded.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
              })
        else {
            return nil
        }
        return decoded
    }

    private static func safeDisplayTarget(_ target: String) -> String {
        guard !target.isEmpty else { return "当前文档顶部" }
        if target.hasPrefix("#") {
            let fragment = String(target.dropFirst()).removingPercentEncoding ?? ""
            return fragment.isEmpty ? "当前文档顶部" : "标题“\(fragment.prefix(80))”"
        }
        if let components = URLComponents(string: target), let scheme = components.scheme {
            if scheme.lowercased() == "http" || scheme.lowercased() == "https" {
                return components.host ?? "网页链接"
            }
            if scheme.lowercased() == "mailto" { return "邮件链接" }
        }
        let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        let name = URL(fileURLWithPath: path.removingPercentEncoding ?? path).lastPathComponent
        return name.isEmpty ? "该链接" : String(name.prefix(120))
    }

    private static func blocked(
        sourceUTF8: Data,
        target: String,
        reason: PreviewLinkFailureReason,
        safeTarget: String,
        expectedURL: URL? = nil
    ) -> PreviewLinkPlan {
        PreviewLinkPlan(
            sourceUTF8: sourceUTF8,
            target: target,
            destination: .blocked(
                PreviewLinkFailure(
                    reason: reason,
                    safeTarget: safeTarget,
                    expectedURL: expectedURL
                )
            )
        )
    }
}

enum PreviewHeadingAnchorResolver {
    static func heading(for fragment: String, in headings: [DocumentHeading]) -> DocumentHeading? {
        let requested = fragment.removingPercentEncoding ?? fragment
        var duplicateCounts: [String: Int] = [:]
        for heading in headings {
            let base = slug(heading.title)
            let duplicate = duplicateCounts[base, default: 0]
            duplicateCounts[base] = duplicate + 1
            let identifier = duplicate == 0 ? base : "\(base)-\(duplicate)"
            if identifier == requested.lowercased()
                || UTF8Text.isExactlyEqual(heading.title, requested)
            {
                return heading
            }
        }
        return nil
    }

    private static func slug(_ title: String) -> String {
        var result = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "_" || scalar == "-"
            {
                result.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.append("-")
            }
        }
        return result
    }
}

@MainActor
final class PreviewDocumentNavigationBroker {
    static let shared = PreviewDocumentNavigationBroker()

    private struct Registration {
        let url: URL
        let navigate: (String?) -> Void
    }

    private struct PendingNavigation {
        let token: UUID
        let fragment: String?
    }

    private var registrations: [UUID: Registration] = [:]
    private var pending: [String: PendingNavigation] = [:]

    func register(id: UUID, url: URL?, navigate: @escaping (String?) -> Void) {
        registrations[id] = nil
        guard let url else { return }
        let key = canonicalKey(url)
        registrations[id] = Registration(url: url, navigate: navigate)
        if let request = pending.removeValue(forKey: key) {
            navigate(request.fragment)
        }
    }

    func unregister(id: UUID) {
        registrations[id] = nil
    }

    func routeIfOpen(to url: URL, fragment: String?) -> Bool {
        let key = canonicalKey(url)
        guard let registration = registrations.values.first(where: {
            canonicalKey($0.url) == key
        }) else {
            return false
        }
        registration.navigate(fragment)
        return true
    }

    @discardableResult
    func enqueue(url: URL, fragment: String?) -> UUID {
        let token = UUID()
        pending[canonicalKey(url)] = PendingNavigation(token: token, fragment: fragment)
        return token
    }

    func cancelPending(url: URL, token: UUID) {
        let key = canonicalKey(url)
        guard pending[key]?.token == token else { return }
        pending[key] = nil
    }

    private func canonicalKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

@MainActor
enum PreviewLinkAuthorization {
    static func chooseExactTarget(_ expectedURL: URL, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "重新授权链接目标"
        panel.message = "请选择同一文件。选择其他路径不会改写 Markdown 链接。"
        panel.prompt = "重新授权并打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = expectedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = expectedURL.lastPathComponent

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK,
              let chosen = panel.url,
              chosen.standardizedFileURL.path == expectedURL.standardizedFileURL.path
        else {
            return nil
        }
        return chosen
    }
}

struct PreviewLinkDecisionView: View {
    let plan: PreviewLinkPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onReveal: (URL) -> Void
    let onReauthorize: (URL) -> Void
    let onCopyTarget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityLabel("链接目标")
            }
            Spacer(minLength: 0)
            HStack {
                secondaryActions
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if showsConfirm {
                    Button(confirmTitle, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 250)
    }

    @ViewBuilder
    private var secondaryActions: some View {
        switch plan.destination {
        case let .local(link):
            Button("在 Finder 中显示") { onReveal(link.url) }
        case let .blocked(failure):
            if let url = failure.expectedURL,
               failure.reason == .missingLocalTarget
                    || failure.reason == .unavailableLocalTarget
            {
                Button("重新授权…") { onReauthorize(url) }
            } else if failure.reason == .unsupportedScheme
                || failure.reason == .invalidTarget
                || failure.reason == .unsafeLocalTarget
                || failure.reason == .cannotOpen
            {
                Button("复制链接文本", action: onCopyTarget)
            }
        case .currentDocument, .external:
            EmptyView()
        }
    }

    private var title: String {
        switch plan.destination {
        case .external: "在 Inflow 外打开链接？"
        case let .local(link):
            link.kind == .attachment ? "这个附件只在 Finder 中显示" : "打开本地目标？"
        case .currentDocument: "定位当前文档"
        case let .blocked(failure):
            switch failure.reason {
            case .missingHeading, .missingLocalTarget, .unavailableLocalTarget:
                "找不到链接目标"
            case .noLongerInDocument: "预览链接已过期"
            case .invalidTarget, .unsupportedScheme, .unsafeLocalTarget, .cannotOpen,
                 .relativeTargetNeedsSavedDocument:
                "为安全起见，未打开这个链接"
            }
        }
    }

    private var icon: String {
        switch plan.destination {
        case .external: "arrow.up.right.square"
        case let .local(link):
            switch link.kind {
            case .markdown: "doc.text"
            case .image: "photo"
            case .pdf: "doc.richtext"
            case .attachment: "paperclip"
            }
        case .currentDocument: "text.append"
        case .blocked: "exclamationmark.triangle"
        }
    }

    private var message: String {
        switch plan.destination {
        case let .external(link):
            "这是一次由你发起的外部操作。Inflow 不会上传正文；确认后只会把该链接交给\(link.displayDestination)。"
        case let .local(link):
            switch link.kind {
            case .markdown:
                "将在 Inflow 中打开已校验的 Markdown 文件，并在有标题片段时定位到对应源文本。"
            case .image, .pdf:
                "目标已校验为受支持的本地文件。确认后将交给系统默认应用。"
            case .attachment:
                "首发版不直接打开这种附件；可以在 Finder 中显示后再由你决定。"
            }
        case .currentDocument:
            "将在当前文档中定位，不会打开外部应用。"
        case let .blocked(failure):
            switch failure.reason {
            case .noLongerInDocument:
                "当前 Markdown 已不再包含你点击的链接，因此不会沿用旧预览结果。"
            case .invalidTarget, .unsupportedScheme:
                "链接类型不受支持或无法安全确认。"
            case .relativeTargetNeedsSavedDocument:
                "未命名文档没有可用于解析相对链接的目录。请先保存文档。"
            case .missingHeading:
                "当前目标文档中没有与\(failure.safeTarget)匹配的标题，因此未移动编辑位置。"
            case .missingLocalTarget:
                "\(failure.safeTarget)不存在、已被移动，或当前位置不可达。"
            case .unavailableLocalTarget:
                "\(failure.safeTarget)当前未授权或无法读取。重新授权时必须选择同一路径。"
            case .unsafeLocalTarget:
                "\(failure.safeTarget)不是可信的普通文件，或其内容与声明类型不一致。"
            case .cannotOpen:
                "系统未能打开\(failure.safeTarget)。当前 Markdown 和编辑位置保持不变。"
            }
        }
    }

    private var detail: String? {
        switch plan.destination {
        case let .external(link): link.url.absoluteString
        case let .local(link): link.url.lastPathComponent
        case let .blocked(failure): failure.safeTarget
        case .currentDocument: nil
        }
    }

    private var showsConfirm: Bool {
        switch plan.destination {
        case .external: true
        case let .local(link): link.kind != .attachment
        case .currentDocument, .blocked: false
        }
    }

    private var confirmTitle: String {
        switch plan.destination {
        case let .local(link) where link.kind == .markdown: "在 Inflow 中打开"
        case .external: "继续打开"
        default: "打开"
        }
    }
}
