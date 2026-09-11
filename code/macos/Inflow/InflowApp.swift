import SwiftUI

private enum ManualSaveDocumentGateState: Equatable {
    case pending
    case ready
    case failed(String)
}

/// Keeps the entire editor tree out of the hierarchy until the concrete
/// DocumentGroup host has adopted and verified the manual-save policy.
@MainActor
private struct ManualSaveDocumentGate<Content: View>: View {
    @State private var state: ManualSaveDocumentGateState
    @State private var blockedWindow: NSWindow?
    @State private var blockedDocument: NSDocument?
    @State private var isConfirmingDiscard = false
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
        _state = State(
            initialValue: ManualSaveDocumentHostPolicy.isProcessConfigured
                ? .ready
                : .pending
        )
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch state {
            case .pending:
                ProgressView("正在准备手动保存…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        DocumentWindowResolver(
                            onResolve: { window in configureHost(in: window) },
                            onTimeout: { window in resolutionTimedOut(in: window) }
                        )
                    )
            case .ready:
                content()
            case let .failed(message):
                ContentUnavailableView {
                    Label("无法安全启用编辑", systemImage: "lock.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button(
                        currentBlockedDocument?.isDocumentEdited == true
                            ? "放弃更改并关闭…"
                            : "关闭文档"
                    ) {
                        // Resolve again at click time: the concrete document may
                        // have attached after the host-policy timeout.
                        if currentBlockedDocument?.isDocumentEdited == true {
                            isConfirmingDiscard = true
                        } else {
                            discardAndCloseBlockedDocument()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .alert("放弃未保存更改？", isPresented: $isConfirmingDiscard) {
                    Button("取消", role: .cancel) {}
                    Button("放弃并关闭", role: .destructive) {
                        discardAndCloseBlockedDocument()
                    }
                } message: {
                    Text("宿主保存策略未能通过安全检查。该操作只会放弃当前未保存内容，不会写入用户文件。")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            blockedDocument = nil
            blockedWindow = nil
        }
    }

    @MainActor
    private func configureHost(in window: NSWindow) -> Bool {
        guard state == .pending else { return true }
        releasePreviousHost(ifDifferentFrom: window)
        blockedWindow = window
        guard let document = window.windowController?.document as? NSDocument,
              NSDocumentController.shared.documents.contains(where: { $0 === document })
        else {
            return false
        }
        blockedDocument = document

        do {
            try ManualSaveDocumentHostPolicy.apply(to: document)
            blockedDocument = nil
            blockedWindow = nil
            state = .ready
        } catch {
            fail(error)
        }
        return true
    }

    @MainActor
    private func resolutionTimedOut(in window: NSWindow) {
        guard state == .pending else { return }
        releasePreviousHost(ifDifferentFrom: window)
        blockedWindow = window
        blockedDocument = window.windowController?.document as? NSDocument
        fail(ManualSaveDocumentHostPolicyError.unsupportedHost)
    }

    @MainActor
    private func fail(_ error: Error) {
        LocalFailureLogController.shared.record(.saving, code: .saveFailed)
        state = .failed(
            (error as? LocalizedError)?.errorDescription
                ?? ManualSaveDocumentHostPolicyError.cannotOverrideFrameworkPolicy
                    .localizedDescription
        )
    }

    @MainActor
    private func discardAndCloseBlockedDocument() {
        let window = blockedWindow
        let attachedObject = window?.windowController?.document
        let document: NSDocument?
        if let attachedObject {
            // Re-read the host at the destructive decision point. A document
            // can attach after the resolver timed out, and closing a stale
            // captured object would leave that late host unprotected.
            guard let attachedDocument = attachedObject as? NSDocument else { return }
            document = attachedDocument
        } else {
            document = blockedDocument
        }
        blockedDocument = nil
        blockedWindow = nil
        if let document {
            // This is the user's explicit Don't Save decision. Clearing the
            // change count before `close()` prevents an unverified host from
            // taking an automatic-save path while it tears down.
            document.updateChangeCount(.changeCleared)
            document.close()
        } else {
            window?.close()
        }
    }

    @MainActor
    private var currentBlockedDocument: NSDocument? {
        if let attached = blockedWindow?.windowController?.document as? NSDocument {
            return attached
        }
        return blockedDocument
    }

    @MainActor
    private func releasePreviousHost(ifDifferentFrom window: NSWindow) {
        guard let blockedWindow, blockedWindow !== window else { return }
        blockedDocument = nil
        self.blockedWindow = nil
    }
}

struct DocumentWindowResolver: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Bool
    let onTimeout: @MainActor (NSWindow) -> Void

    init(
        onResolve: @escaping @MainActor (NSWindow) -> Bool,
        onTimeout: @escaping @MainActor (NSWindow) -> Void
    ) {
        self.onResolve = onResolve
        self.onTimeout = onTimeout
    }

    init(onResolve: @escaping @MainActor (NSWindow) -> Bool) {
        self.init(onResolve: onResolve, onTimeout: { _ in })
    }

    func makeNSView(context _: Context) -> ResolverView {
        ResolverView(onResolve: onResolve, onTimeout: onTimeout)
    }

    func updateNSView(_ view: ResolverView, context _: Context) {
        view.onResolve = onResolve
        view.onTimeout = onTimeout
        view.resolveIfPossible()
    }

    final class ResolverView: NSView {
        var onResolve: @MainActor (NSWindow) -> Bool
        var onTimeout: @MainActor (NSWindow) -> Void
        private weak var candidateWindow: NSWindow?
        private weak var resolvedWindow: NSWindow?
        private var resolutionTask: Task<Void, Never>?

        init(
            onResolve: @escaping @MainActor (NSWindow) -> Bool,
            onTimeout: @escaping @MainActor (NSWindow) -> Void
        ) {
            self.onResolve = onResolve
            self.onTimeout = onTimeout
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            resolutionTask?.cancel()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                resolutionTask?.cancel()
                resolutionTask = nil
                candidateWindow = nil
                resolvedWindow = nil
            }
            resolveIfPossible()
        }

        @MainActor
        func resolveIfPossible() {
            guard let window, resolvedWindow !== window else { return }
            if candidateWindow !== window {
                resolutionTask?.cancel()
                resolutionTask = nil
                candidateWindow = window
            }
            guard resolutionTask == nil else { return }

            resolutionTask = Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                for attempt in 0 ..< 50 {
                    await Task.yield()
                    guard !Task.isCancelled,
                          self.window === window,
                          self.candidateWindow === window
                    else { return }
                    if self.onResolve(window) {
                        self.resolvedWindow = window
                        self.resolutionTask = nil
                        return
                    }
                    if attempt < 49 {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                guard !Task.isCancelled,
                      self.window === window,
                      self.candidateWindow === window
                else { return }
                self.resolvedWindow = window
                self.resolutionTask = nil
                self.onTimeout(window)
            }
        }
    }
}

@MainActor
final class ProjectDocumentSwitchGate {
    private var activeToken: UUID?

    var isBusy: Bool { activeToken != nil }

    func begin() -> UUID? {
        guard activeToken == nil else { return nil }
        let token = UUID()
        activeToken = token
        return token
    }

    func isActive(_ token: UUID) -> Bool {
        activeToken == token
    }

    @discardableResult
    func finish(_ token: UUID) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }
}

@MainActor
final class ProjectDocumentReservationRegistry {
    private struct Target {
        let paths: Set<String>
        let fileIdentity: DocumentResourceIdentity?

        init(_ url: URL) {
            let standardized = url.standardizedFileURL
            paths = [
                standardized.path,
                standardized.resolvingSymlinksInPath().path,
            ]
            fileIdentity = DocumentResourceIdentity.capture(url)
        }
    }

    private final class DocumentEntry {
        let document: NSDocument
        var owners: Set<UUID>

        init(document: NSDocument, owner: UUID) {
            self.document = document
            owners = [owner]
        }
    }

    private final class AbandonedDocument {
        weak var document: NSDocument?
        let target: Target

        init(document: NSDocument, target: Target) {
            self.document = document
            self.target = target
        }
    }

    private var documents: [ObjectIdentifier: DocumentEntry] = [:]
    private var targetPaths: [String: Set<UUID>] = [:]
    private var targetFiles: [DocumentResourceIdentity: Set<UUID>] = [:]
    private var abandoned: [ObjectIdentifier: AbandonedDocument] = [:]

    func reserve(targetURL: URL, owner: UUID) {
        let target = Target(targetURL)
        for path in target.paths {
            targetPaths[path, default: []].insert(owner)
        }
        if let fileIdentity = target.fileIdentity {
            targetFiles[fileIdentity, default: []].insert(owner)
        }
    }

    func reserve(document: NSDocument, owner: UUID) {
        let identifier = ObjectIdentifier(document)
        if let entry = documents[identifier] {
            entry.owners.insert(owner)
        } else {
            documents[identifier] = DocumentEntry(
                document: document,
                owner: owner
            )
        }
    }

    func isReserved(_ document: NSDocument) -> Bool {
        documents[ObjectIdentifier(document)]?.owners.isEmpty == false
    }

    func release(
        owner: UUID,
        isProtected: (NSDocument) -> Bool
    ) {
        for path in Array(targetPaths.keys) {
            var remaining = targetPaths[path] ?? []
            remaining.remove(owner)
            if remaining.isEmpty {
                targetPaths.removeValue(forKey: path)
            } else {
                targetPaths[path] = remaining
            }
        }
        for fileIdentity in Array(targetFiles.keys) {
            var remaining = targetFiles[fileIdentity] ?? []
            remaining.remove(owner)
            if remaining.isEmpty {
                targetFiles.removeValue(forKey: fileIdentity)
            } else {
                targetFiles[fileIdentity] = remaining
            }
        }
        for identifier in Array(documents.keys) {
            guard let entry = documents[identifier] else { continue }
            entry.owners.remove(owner)
            if entry.owners.isEmpty {
                documents.removeValue(forKey: identifier)
            }
        }
        cleanAbandonedDocuments(isProtected: isProtected)
    }

    func handleLateOpen(
        document: NSDocument,
        targetURL: URL,
        wasAlreadyOpen: Bool,
        isProtected: (NSDocument) -> Bool
    ) {
        guard !wasAlreadyOpen,
              !isProtected(document),
              !document.isDocumentEdited,
              document.windowControllers.allSatisfy({ $0.window?.isVisible != true })
        else { return }

        let target = Target(targetURL)
        if isReserved(document) || hasReservation(for: target) {
            abandoned[ObjectIdentifier(document)] = AbandonedDocument(
                document: document,
                target: target
            )
            return
        }
        document.close()
    }

    private func cleanAbandonedDocuments(
        isProtected: (NSDocument) -> Bool
    ) {
        for identifier in Array(abandoned.keys) {
            guard let candidate = abandoned[identifier] else { continue }
            guard let document = candidate.document else {
                abandoned.removeValue(forKey: identifier)
                continue
            }
            guard !isReserved(document),
                  !hasReservation(for: candidate.target)
            else { continue }
            abandoned.removeValue(forKey: identifier)
            guard !isProtected(document),
                  !document.isDocumentEdited,
                  document.windowControllers.allSatisfy({ $0.window?.isVisible != true })
            else { continue }
            document.close()
        }
    }

    private func hasReservation(for target: Target) -> Bool {
        target.paths.contains { targetPaths[$0]?.isEmpty == false }
            || target.fileIdentity.map {
                targetFiles[$0]?.isEmpty == false
            } == true
    }
}

@MainActor
enum ProjectDocumentTargetPolicy {
    static func isReusableShell(
        _ document: NSDocument,
        isAssociated: Bool,
        isRegistered: Bool
    ) -> Bool {
        document.fileURL == nil
            && !document.isDocumentEdited
            && !isAssociated
            && isRegistered
    }

    static func canCloseUncommitted(
        _ document: NSDocument,
        isRegistered: Bool
    ) -> Bool {
        isRegistered
            && !document.isDocumentEdited
            && document.windowControllers.allSatisfy {
                $0.window?.isVisible != true
            }
    }

}

@MainActor
final class ProjectDocumentSurface: Identifiable {
    let id: ObjectIdentifier
    let nativeDocument: NSDocument
    let content: Binding<MarkdownDocument>
    let fileURL: URL
    let isEditable: Bool
    let sourceEditorSession = MarkdownSourceEditorSession()

    init(
        nativeDocument: NSDocument,
        content: Binding<MarkdownDocument>,
        fileURL: URL,
        isEditable: Bool
    ) {
        id = ObjectIdentifier(nativeDocument)
        self.nativeDocument = nativeDocument
        self.content = content
        self.fileURL = fileURL.standardizedFileURL
        self.isEditable = isEditable
    }

    var title: String { fileURL.lastPathComponent }
}

enum ProjectDocumentTabSelection {
    enum CloseScope: CaseIterable, Equatable {
        case current
        case others
        case left
        case right
    }

    static func targetIDs(
        for scope: CloseScope,
        anchorID: ObjectIdentifier,
        orderedIDs: [ObjectIdentifier]
    ) -> [ObjectIdentifier] {
        guard let anchorIndex = orderedIDs.firstIndex(of: anchorID) else {
            return []
        }
        switch scope {
        case .current:
            return [anchorID]
        case .others:
            return orderedIDs.filter { $0 != anchorID }
        case .left:
            return Array(orderedIDs[..<anchorIndex])
        case .right:
            return Array(orderedIDs[orderedIDs.index(after: anchorIndex)...])
        }
    }

    static func activeIDAfterClosing(
        _ closingID: ObjectIdentifier,
        orderedIDs: [ObjectIdentifier],
        activeID: ObjectIdentifier?
    ) -> ObjectIdentifier? {
        guard let closingIndex = orderedIDs.firstIndex(of: closingID) else {
            return activeID
        }
        guard activeID == closingID else {
            return activeID.flatMap { orderedIDs.contains($0) ? $0 : nil }
        }
        if orderedIDs.indices.contains(closingIndex + 1) {
            return orderedIDs[closingIndex + 1]
        }
        if closingIndex > 0 {
            return orderedIDs[closingIndex - 1]
        }
        return nil
    }

    static func activeIDAfterClosing(
        _ closingIDs: Set<ObjectIdentifier>,
        orderedIDs: [ObjectIdentifier],
        activeID: ObjectIdentifier?
    ) -> ObjectIdentifier? {
        let remainingIDs = orderedIDs.filter { !closingIDs.contains($0) }
        guard let activeID else { return remainingIDs.first }
        if remainingIDs.contains(activeID) {
            return activeID
        }
        guard let activeIndex = orderedIDs.firstIndex(of: activeID) else {
            return remainingIDs.first
        }
        if let rightNeighbor = orderedIDs[orderedIDs.index(after: activeIndex)...]
            .first(where: { !closingIDs.contains($0) })
        {
            return rightNeighbor
        }
        return orderedIDs[..<activeIndex]
            .reversed()
            .first(where: { !closingIDs.contains($0) })
    }
}

@MainActor
enum ProjectSessionBoundary {
    static func hasCurrentRoot(_ browser: FolderBrowserController) -> Bool {
        guard let root = browser.folderURL,
              let identity = browser.projectRootIdentity
        else {
            return false
        }
        return FolderProjectDirectoryIdentity.capture(root) == identity
    }

    static func activeEditorRoot(
        for documentURL: URL?,
        document: NSDocument?,
        browser: FolderBrowserController
    ) -> URL? {
        guard let root = browser.folderURL,
              let identity = browser.projectRootIdentity,
              FolderProjectDirectoryIdentity.capture(root) == identity,
              browser.isAssociatedProjectDocument(document)
        else {
            return nil
        }
        if let documentURL,
           !FolderProjectPathBoundary.contains(documentURL, in: root)
        {
            return nil
        }
        guard FolderProjectDirectoryIdentity.capture(root) == identity else {
            return nil
        }
        return root
    }

    static func matchesRequestedProject(
        _ requestedURL: URL,
        browser: FolderBrowserController
    ) -> Bool {
        guard hasCurrentRoot(browser), let root = browser.folderURL else {
            return false
        }
        return FolderProjectPathBoundary.normalizedResolvedURL(requestedURL)
            == FolderProjectPathBoundary.normalizedResolvedURL(root)
    }

    static func authorizationIsCurrent(
        _ authorization: ProjectDocumentOpenAuthorization,
        targetURL: URL,
        browser: FolderBrowserController
    ) -> Bool {
        guard hasCurrentRoot(browser),
              let root = browser.folderURL,
              let identity = browser.projectRootIdentity,
              FolderProjectPathBoundary.contains(targetURL, in: root),
              authorization.targetURL.standardizedFileURL
                  == targetURL.standardizedFileURL,
              authorization.projectIdentity == identity,
              authorization.isCurrent()
        else {
            return false
        }
        return true
    }
}

typealias ProjectDocumentOpenCompletion = @MainActor (
    Result<OpenedDocumentResult, Error>
) -> Void

@MainActor
struct ProjectDocumentDetailedOpener {
    private let handler: @MainActor (
        URL,
        ProjectDocumentOpenAuthorization,
        @escaping ProjectDocumentOpenCompletion
    ) -> Void

    init(
        _ handler: @escaping @MainActor (
            URL,
            ProjectDocumentOpenAuthorization,
            @escaping ProjectDocumentOpenCompletion
        ) -> Void
    ) {
        self.handler = handler
    }

    func open(
        _ url: URL,
        authorization: ProjectDocumentOpenAuthorization,
        completion: @escaping ProjectDocumentOpenCompletion
    ) {
        handler(url, authorization, completion)
    }
}

@MainActor
final class LightweightProjectCoordinator: ObservableObject {
    private struct WorkspaceSurfaceState {
        var surfaces: [ProjectDocumentSurface] = []
        var activeID: ObjectIdentifier?
    }

    let browser: FolderBrowserController
    private weak var projectDocument: NSDocument?
    private weak var projectHostDocument: NSDocument?
    private let createProjectDocument: () throws -> NSDocument
    private let detailedDocumentOpener: ProjectDocumentDetailedOpener?
    private let willActivateDocumentSurface: (NSDocument) -> Void
    private let documentSwitchGate = ProjectDocumentSwitchGate()
    private let reservationRegistry = ProjectDocumentReservationRegistry()
    private var projectPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var projectPreparationTimeouts: [UUID: Task<Void, Never>] = [:]
    private var pendingSurfaceActivation: ObjectIdentifier?
    @Published private var workspaceSurfaceState = WorkspaceSurfaceState()

    var documentSurfaces: [ProjectDocumentSurface] {
        workspaceSurfaceState.surfaces
    }

    var activeSurfaceID: ObjectIdentifier? {
        workspaceSurfaceState.activeID
    }

    init(
        browser: FolderBrowserController,
        createProjectDocument: @escaping () throws -> NSDocument,
        detailedDocumentOpener: ProjectDocumentDetailedOpener? = nil,
        willActivateDocumentSurface: @escaping (NSDocument) -> Void = { _ in }
    ) {
        self.browser = browser
        self.createProjectDocument = createProjectDocument
        self.detailedDocumentOpener = detailedDocumentOpener
        self.willActivateDocumentSurface = willActivateDocumentSurface
    }

    var openedProjectURLs: [URL] {
        guard activeProjectHost != nil || activeProjectDocument != nil else { return [] }
        return browser.folderURL.map { [$0] } ?? []
    }

    var hasActiveDocumentSwitch: Bool { documentSwitchGate.isBusy }

    var activeDocumentSurface: ProjectDocumentSurface? {
        guard let activeSurfaceID else { return nil }
        return documentSurfaces.first { $0.id == activeSurfaceID }
    }

    func canReuseAsBlankDocument(_ document: NSDocument) -> Bool {
        !reservationRegistry.isReserved(document)
    }

    func focusCurrentDocumentWindow() {
        let document = activeProjectHost
            ?? NSDocumentController.shared.documents.first(where: \.isDocumentEdited)
        document?.showWindows()
        document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        if document != nil {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openProject(_ url: URL, reusableDocument: NSDocument?) {
        guard !DocumentCloseAuthorization.hasPendingRequests,
              let switchToken = documentSwitchGate.begin()
        else {
            LocalFailureLogController.shared.record(.project, code: .projectUnavailable)
            return
        }
        let previousDocument = activeProjectHost ?? activeProjectDocument
        if let reusableDocument {
            reservationRegistry.reserve(
                document: reusableDocument,
                owner: switchToken
            )
        }
        let preparationTask = browser.prepareFolderForOpening(url) {
            [weak self, weak reusableDocument, weak previousDocument] result in
            guard let self,
                  self.documentSwitchGate.isActive(switchToken)
            else { return }
            self.projectPreparationTimeouts.removeValue(forKey: switchToken)?.cancel()
            switch result {
            case let .success(preparation):
                self.completeProjectPreparation(
                    preparation,
                    reusableDocument: reusableDocument,
                    previousDocument: previousDocument,
                    switchToken: switchToken
                )
            case let .failure(error):
                self.finishSwitchToken(switchToken)
                LocalFailureLogController.shared.record(
                    .project,
                    code: .projectUnavailable
                )
                NSDocumentController.shared.presentError(error)
            }
        }
        projectPreparationTasks[switchToken] = preparationTask
        projectPreparationTimeouts[switchToken] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  let self,
                  self.documentSwitchGate.isActive(switchToken)
            else { return }
            self.finishSwitchToken(switchToken)
            LocalFailureLogController.shared.record(
                .project,
                code: .projectUnavailable
            )
            NSDocumentController.shared.presentError(DocumentOpenError.timedOut)
        }
    }

    private func completeProjectPreparation(
        _ preparation: FolderProjectOpenPreparation,
        reusableDocument: NSDocument?,
        previousDocument: NSDocument?,
        switchToken: UUID
    ) {
        guard documentSwitchGate.isActive(switchToken),
              FolderProjectDirectoryIdentity.capture(preparation.rootURL)
                  == preparation.rootIdentity
        else {
            finishSwitchToken(switchToken)
            LocalFailureLogController.shared.record(
                .project,
                code: .projectUnavailable
            )
            NSDocumentController.shared.presentError(FolderBrowserError.unavailable)
            return
        }

        let targetDocument: NSDocument
        let closesTargetOnCancellation: Bool
        if let reusableDocument,
           isReusableProjectShell(reusableDocument)
        {
            targetDocument = reusableDocument
            closesTargetOnCancellation = false
        } else {
            do {
                targetDocument = try createProjectDocument()
                closesTargetOnCancellation = true
            } catch {
                finishSwitchToken(switchToken)
                LocalFailureLogController.shared.record(
                    .project,
                    code: .projectUnavailable
                )
                NSDocumentController.shared.presentError(error)
                return
            }
        }
        reservationRegistry.reserve(
            document: targetDocument,
            owner: switchToken
        )

        DocumentCloseAuthorization.request(for: previousDocument) {
            [weak self, weak previousDocument] shouldReplace in
            guard let self else {
                let isRegistered = NSDocumentController.shared.documents.contains {
                    $0 === targetDocument
                }
                if closesTargetOnCancellation,
                   ProjectDocumentTargetPolicy.canCloseUncommitted(
                       targetDocument,
                       isRegistered: isRegistered
                   )
                {
                    targetDocument.close()
                }
                return
            }
            guard self.documentSwitchGate.isActive(switchToken) else {
                if closesTargetOnCancellation {
                    self.closeUncommittedDocumentIfSafe(targetDocument)
                }
                return
            }
            guard shouldReplace else {
                if closesTargetOnCancellation {
                    self.closeUncommittedDocumentIfSafe(targetDocument)
                }
                previousDocument?.showWindows()
                previousDocument?.windowControllers.first?.window?
                    .makeKeyAndOrderFront(nil)
                self.finishSwitchToken(switchToken)
                return
            }

            guard self.isReusableProjectShell(targetDocument) else {
                if closesTargetOnCancellation {
                    self.closeUncommittedDocumentIfSafe(targetDocument)
                }
                previousDocument?.showWindows()
                previousDocument?.windowControllers.first?.window?
                    .makeKeyAndOrderFront(nil)
                self.finishSwitchToken(switchToken)
                LocalFailureLogController.shared.record(
                    .project,
                    code: .projectUnavailable
                )
                return
            }
            guard self.browser.commitPreparedFolder(
                preparation,
                finalValidation: {
                    self.documentSwitchGate.isActive(switchToken)
                        && self.isReusableProjectShell(targetDocument)
                }
            ) else {
                if closesTargetOnCancellation {
                    self.closeUncommittedDocumentIfSafe(targetDocument)
                }
                self.restoreProject(document: previousDocument)
                self.finishSwitchToken(switchToken)
                LocalFailureLogController.shared.record(
                    .project,
                    code: .projectUnavailable
                )
                NSDocumentController.shared.presentError(
                    FolderBrowserError.unavailable
                )
                return
            }
            guard self.browser.projectRootIdentity == preparation.rootIdentity,
                  ProjectSessionBoundary.hasCurrentRoot(self.browser)
            else {
                if closesTargetOnCancellation {
                    self.closeUncommittedDocumentIfSafe(targetDocument)
                }
                self.restoreProject(document: previousDocument)
                self.finishSwitchToken(switchToken)
                LocalFailureLogController.shared.record(
                    .project,
                    code: .projectUnavailable
                )
                NSDocumentController.shared.presentError(
                    FolderBrowserError.unavailable
                )
                return
            }

            self.browser.associateProjectWindow(with: nil)
            self.attachProjectHost(targetDocument)
            if let previousDocument, previousDocument !== targetDocument {
                previousDocument.close()
            }
            self.finishSwitchToken(switchToken)
        }
    }

    func focusProject(_ url: URL) {
        guard ProjectSessionBoundary.matchesRequestedProject(url, browser: browser),
              !DocumentCloseAuthorization.hasPendingRequests,
              let switchToken = documentSwitchGate.begin()
        else { return }
        defer { finishSwitchToken(switchToken) }
        guard activeProjectHost != nil else { return }
        focusProjectHostWindow()
    }

    func prepareToReplaceCurrentDocument(
        _ candidate: NSDocument?,
        completion: @escaping (Bool) -> Void
    ) {
        _ = candidate
        guard !documentSwitchGate.isBusy,
              !DocumentCloseAuthorization.hasPendingRequests
        else {
            completion(false)
            return
        }
        completion(true)
    }

    func openDocument(
        _ url: URL,
        replacing candidate: NSDocument?,
        using recentDocuments: RecentDocumentsController,
        authorization: ProjectDocumentOpenAuthorization? = nil,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard let root = browser.folderURL,
              let committedProjectIdentity = browser.projectRootIdentity
        else {
            completion(.failure(DocumentOpenError.unsupportedTarget))
            return
        }
        guard FolderProjectDirectoryIdentity.capture(root)
                  == committedProjectIdentity
        else {
            completion(.failure(DocumentOpenError.targetChanged))
            return
        }
        guard FolderProjectPathBoundary.contains(url, in: root) else {
            completion(.failure(DocumentOpenError.unsupportedTarget))
            return
        }
        guard let effectiveAuthorization = authorization
                  ?? ProjectDocumentOpenAuthorization.capture(
                      targetURL: url,
                      projectRoot: root
                  ),
              effectiveAuthorization.isCurrent(),
              effectiveAuthorization.targetURL.standardizedFileURL
                  == url.standardizedFileURL,
              effectiveAuthorization.projectIdentity == committedProjectIdentity
        else {
            completion(.failure(DocumentOpenError.targetChanged))
            return
        }

        guard !documentSwitchGate.isBusy,
              !DocumentCloseAuthorization.hasPendingRequests
        else {
            completion(.failure(DocumentOpenError.cancelled))
            return
        }

        let current = currentProjectDocument(candidate)
        if let current,
           NSDocumentController.shared.documents.contains(where: { $0 === current }),
           NativeDocumentLoadedFileRegistry.matches(
               current,
               authorization: effectiveAuthorization
           )
        {
            guard let receipt = ProjectDocumentOpenReceipt.capture(
                authorization: effectiveAuthorization
            ) else {
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            willActivateDocumentSurface(current)
            guard let refreshedReceipt = refreshedProjectDocumentReceipt(
                receipt,
                targetURL: url
            ) else {
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            NativeDocumentLoadedFileRegistry.register(
                current,
                authorization: refreshedReceipt.authorization
            )
            activateProjectDocument(current)
            focusProjectHostWindow()
            completion(.success(()))
            return
        }

        if let existing = NativeDocumentLoadedFileRegistry.focusableDocument(
            authorization: effectiveAuthorization,
            excluding: current
        ) {
            guard let receipt = ProjectDocumentOpenReceipt.capture(
                authorization: effectiveAuthorization
            ) else {
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            willActivateDocumentSurface(existing)
            guard let refreshedReceipt = refreshedProjectDocumentReceipt(
                receipt,
                targetURL: url
            ) else {
                completion(.failure(DocumentOpenError.targetChanged))
                return
            }
            NativeDocumentLoadedFileRegistry.refreshManagedRegistration(
                existing,
                authorization: refreshedReceipt.authorization
            )
            prepareProjectDocumentSurface(existing)
            completion(.success(()))
            return
        }

        guard let switchToken = documentSwitchGate.begin() else {
            completion(.failure(DocumentOpenError.cancelled))
            return
        }
        reservationRegistry.reserve(targetURL: url, owner: switchToken)
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  let self,
                  self.documentSwitchGate.isActive(switchToken)
            else { return }
            self.finishDocumentSwitch(
                switchToken,
                result: .failure(DocumentOpenError.timedOut),
                completion: completion
            )
        }
        let handleOpenResult: ProjectDocumentOpenCompletion = {
            [weak self, weak current, weak browser = browser] result in
            timeoutTask.cancel()
            guard let self else {
                Self.closeOpenedDocumentAfterCoordinatorReleaseIfSafe(
                    result,
                    browser: browser
                )
                return
            }
            guard self.documentSwitchGate.isActive(switchToken) else {
                self.closeAbandonedNewDocumentIfSafe(result, targetURL: url)
                return
            }
            switch result {
            case let .success(opened):
                self.reservationRegistry.reserve(
                    document: opened.document,
                    owner: switchToken
                )
                // Native document construction, showing, and activation can each
                // update only ctime. Carry the opener's frozen bytes through every
                // commit boundary so those benign updates can be reverified while
                // replacement or content changes still fail closed.
                guard let openedReceipt = opened.receipt,
                      let currentReceipt = self.refreshedProjectDocumentReceipt(
                          openedReceipt,
                          targetURL: url
                      )
                else {
                    if !opened.wasAlreadyOpen {
                        self.closeUncommittedDocumentIfSafe(opened.document)
                    }
                    self.finishDocumentSwitch(
                        switchToken,
                        result: .failure(DocumentOpenError.targetChanged),
                        completion: completion
                    )
                    return
                }
                guard !opened.wasAlreadyOpen else {
                    self.willActivateDocumentSurface(opened.document)
                    guard let focusedReceipt = self.refreshedProjectDocumentReceipt(
                        currentReceipt,
                        targetURL: url
                    ) else {
                        self.finishDocumentSwitch(
                            switchToken,
                            result: .failure(DocumentOpenError.targetChanged),
                            completion: completion
                        )
                        return
                    }
                    NativeDocumentLoadedFileRegistry.refreshManagedRegistration(
                        opened.document,
                        authorization: focusedReceipt.authorization
                    )
                    self.prepareProjectDocumentSurface(opened.document)
                    self.finishDocumentSwitch(
                        switchToken,
                        result: .success(()),
                        completion: completion
                    )
                    return
                }

                // Project files keep independent native document ownership,
                // but their windows stay in the background. The stable project
                // host replaces only its workspace surface.
                self.completeDocumentTabOpen(
                    opened.document,
                    replacing: current,
                    targetURL: url,
                    receipt: currentReceipt,
                    switchToken: switchToken,
                    completion: completion
                )
            case let .failure(error):
                self.finishDocumentSwitch(
                    switchToken,
                    result: .failure(error),
                    completion: completion
                )
            }
        }
        if let detailedDocumentOpener {
            detailedDocumentOpener.open(
                url,
                authorization: effectiveAuthorization,
                completion: handleOpenResult
            )
        } else {
            recentDocuments.openDocumentFromFolderDetailed(
                url,
                authorization: effectiveAuthorization,
                display: false,
                completion: handleOpenResult
            )
        }
    }

    private var activeProjectDocument: NSDocument? {
        let document = activeDocumentSurface?.nativeDocument ?? projectDocument
        guard let document,
              NSDocumentController.shared.documents.contains(where: { $0 === document }),
              ProjectSessionBoundary.hasCurrentRoot(browser),
              let root = browser.folderURL
        else {
            return nil
        }
        if let fileURL = document.fileURL,
           !FolderProjectPathBoundary.contains(fileURL, in: root)
        {
            return nil
        }
        return document
    }

    private var activeProjectHost: NSDocument? {
        guard let document = projectHostDocument,
              NSDocumentController.shared.documents.contains(where: { $0 === document }),
              ProjectSessionBoundary.hasCurrentRoot(browser),
              browser.isAssociatedProjectDocument(document)
        else {
            return nil
        }
        return document
    }

    private func currentProjectDocument(_ candidate: NSDocument?) -> NSDocument? {
        if browser.isAssociatedProjectDocument(candidate) {
            if projectHostDocument == nil, candidate?.fileURL == nil {
                projectHostDocument = candidate
                objectWillChange.send()
            }
            return candidate
        }
        return activeProjectDocument
    }

    func activateProjectDocument(_ document: NSDocument?) {
        guard let document,
              ProjectSessionBoundary.hasCurrentRoot(browser),
              let root = browser.folderURL,
              document.fileURL.map({
                  FolderProjectPathBoundary.contains($0, in: root)
              }) ?? browser.isAssociatedProjectDocument(document)
        else { return }
        projectDocument = document
        browser.associateProjectWindow(with: document)
        let identifier = ObjectIdentifier(document)
        if let surface = documentSurfaces.first(where: { $0.id == identifier }) {
            workspaceSurfaceState.activeID = identifier
            pendingSurfaceActivation = nil
            focusEditorWhenMounted(surface)
        } else if document !== projectHostDocument {
            pendingSurfaceActivation = identifier
        }
    }

    func isProjectHostDocument(_ document: NSDocument?) -> Bool {
        guard let document else { return false }
        return document === activeProjectHost
    }

    func isBackgroundProjectDocument(_ document: NSDocument?) -> Bool {
        guard let document,
              document !== projectHostDocument,
              browser.isAssociatedProjectDocument(document),
              ProjectSessionBoundary.hasCurrentRoot(browser),
              let root = browser.folderURL,
              let fileURL = document.fileURL
        else {
            return false
        }
        return FolderProjectPathBoundary.contains(fileURL, in: root)
    }

    func registerDocumentSurface(
        nativeDocument: NSDocument,
        content: Binding<MarkdownDocument>,
        fileURL: URL,
        isEditable: Bool
    ) {
        guard isBackgroundProjectDocument(nativeDocument),
              nativeDocument.fileURL?.standardizedFileURL == fileURL.standardizedFileURL
        else { return }

        // A DocumentGroup still owns a native window for every project file.
        // Suppress it before publishing or laying out the in-workspace surface,
        // otherwise AppKit can briefly expose that differently sized window.
        suppressBackgroundWindows(of: nativeDocument)

        let identifier = ObjectIdentifier(nativeDocument)
        let surface: ProjectDocumentSurface
        let shouldActivate: Bool
        if let existing = documentSurfaces.first(where: { $0.id == identifier }) {
            surface = existing
            shouldActivate = pendingSurfaceActivation == surface.id || activeSurfaceID == nil
        } else {
            surface = ProjectDocumentSurface(
                nativeDocument: nativeDocument,
                content: content,
                fileURL: fileURL,
                isEditable: isEditable
            )
            // Keep the currently visible editor in place while SwiftUI mounts a
            // newly opened surface. The host reports that mount below and only
            // then performs the visible selection.
            shouldActivate = activeSurfaceID == nil
            var nextState = workspaceSurfaceState
            nextState.surfaces.append(surface)
            if shouldActivate {
                nextState.activeID = surface.id
            }
            // Publish the new surface and its selection atomically. Publishing
            // either half first creates a frame with no visible editor.
            workspaceSurfaceState = nextState
        }

        if shouldActivate {
            projectDocument = nativeDocument
            if activeSurfaceID != surface.id {
                workspaceSurfaceState.activeID = surface.id
            }
            pendingSurfaceActivation = nil
            focusProjectHostWindow()
            focusEditorWhenMounted(surface)
        }
        suppressBackgroundWindows(of: nativeDocument)
    }

    func documentSurfaceDidMount(_ identifier: ObjectIdentifier) {
        guard pendingSurfaceActivation == identifier,
              activeSurfaceID != identifier,
              documentSurfaces.contains(where: { $0.id == identifier })
        else { return }

        // Let the representable descendants create their native views before
        // selecting the new surface. Until then the previous editor remains
        // fully visible, avoiding a blank or partially rendered frame.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.pendingSurfaceActivation == identifier,
                  let surface = self.documentSurfaces.first(where: {
                      $0.id == identifier
                  })
            else { return }
            self.activateProjectDocument(surface.nativeDocument)
        }
    }

    func selectDocumentSurface(_ identifier: ObjectIdentifier) {
        guard let surface = documentSurfaces.first(where: { $0.id == identifier }),
              NSDocumentController.shared.documents.contains(where: {
                  $0 === surface.nativeDocument
              })
        else { return }
        projectDocument = surface.nativeDocument
        workspaceSurfaceState.activeID = identifier
        pendingSurfaceActivation = nil
        focusProjectHostWindow()
        focusEditorWhenMounted(surface)
    }

    func closeDocumentSurface(_ identifier: ObjectIdentifier) {
        closeDocumentSurfaces(
            ProjectDocumentTabSelection.targetIDs(
                for: .current,
                anchorID: identifier,
                orderedIDs: documentSurfaces.map(\.id)
            )
        )
    }

    func closeDocumentSurfaces(
        in scope: ProjectDocumentTabSelection.CloseScope,
        relativeTo identifier: ObjectIdentifier
    ) {
        closeDocumentSurfaces(
            ProjectDocumentTabSelection.targetIDs(
                for: scope,
                anchorID: identifier,
                orderedIDs: documentSurfaces.map(\.id)
            )
        )
    }

    private func closeDocumentSurfaces(_ identifiers: [ObjectIdentifier]) {
        guard !documentSwitchGate.isBusy,
              !DocumentCloseAuthorization.hasPendingRequests
        else { return }

        let requestedIDs = Set(identifiers)
        let surfaces = documentSurfaces.filter { requestedIDs.contains($0.id) }
        guard !surfaces.isEmpty else { return }

        authorizeClosing(surfaces, at: 0) { [weak self] authorized in
            guard authorized else { return }
            self?.commitClosing(surfaces)
        }
    }

    private func authorizeClosing(
        _ surfaces: [ProjectDocumentSurface],
        at index: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard surfaces.indices.contains(index) else {
            completion(true)
            return
        }
        let surface = surfaces[index]
        DocumentCloseAuthorization.request(for: surface.nativeDocument) {
            [weak self, weak surface] shouldClose in
            guard shouldClose, let self, surface != nil else {
                completion(false)
                return
            }
            self.authorizeClosing(surfaces, at: index + 1, completion: completion)
        }
    }

    private func commitClosing(_ authorizedSurfaces: [ProjectDocumentSurface]) {
        guard !documentSwitchGate.isBusy else { return }
        let currentSurfaceIDs = Set(documentSurfaces.map(\.id))
        let surfaces = authorizedSurfaces.filter { currentSurfaceIDs.contains($0.id) }
        guard !surfaces.isEmpty else { return }

        let closingIDs = Set(surfaces.map(\.id))
        let orderedIDs = documentSurfaces.map(\.id)
        let nextActiveID = ProjectDocumentTabSelection.activeIDAfterClosing(
            closingIDs,
            orderedIDs: orderedIDs,
            activeID: activeSurfaceID
        )
        var nextState = workspaceSurfaceState
        nextState.surfaces.removeAll { closingIDs.contains($0.id) }
        nextState.activeID = nextActiveID.flatMap { candidate in
            nextState.surfaces.contains(where: { $0.id == candidate })
                ? candidate
                : nil
        }

        // Remove every requested surface and select its successor in one
        // publication so batch closing never exposes an intermediate editor.
        workspaceSurfaceState = nextState
        if let pendingSurfaceActivation, closingIDs.contains(pendingSurfaceActivation) {
            self.pendingSurfaceActivation = nil
        }
        for surface in surfaces {
            browser.dissociateProjectWindow(surface.nativeDocument)
            NativeDocumentLoadedFileRegistry.clear(surface.nativeDocument)
            surface.nativeDocument.close()
        }

        if let nextID = nextState.activeID,
           let nextSurface = nextState.surfaces.first(where: { $0.id == nextID })
        {
            projectDocument = nextSurface.nativeDocument
            focusProjectHostWindow()
            focusEditorWhenMounted(nextSurface)
        } else {
            projectDocument = projectHostDocument
            focusProjectHostWindow()
        }
    }

    private func attachProjectHost(_ document: NSDocument?) {
        projectHostDocument = document
        projectDocument = document
        workspaceSurfaceState = WorkspaceSurfaceState()
        pendingSurfaceActivation = nil
        browser.associateProjectWindow(with: document)
        if let document, document.windowControllers.isEmpty {
            document.makeWindowControllers()
        }
        document?.showWindows()
        document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func prepareProjectDocumentSurface(_ document: NSDocument) {
        let hostWindow = activeProjectHost?.windowControllers.first?.window
        let stableHostFrame = hostWindow?.frame
        projectDocument = document
        browser.associateProjectWindow(with: document)
        pendingSurfaceActivation = ObjectIdentifier(document)
        if document.windowControllers.isEmpty {
            document.makeWindowControllers()
        }
        for windowController in document.windowControllers {
            let window = windowController.window
            window?.animationBehavior = .none
            window?.orderOut(nil)
            _ = window?.contentViewController?.view
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.orderOut(nil)
        }
        if let hostWindow, let stableHostFrame, hostWindow.frame != stableHostFrame {
            hostWindow.setFrame(stableHostFrame, display: true, animate: false)
        }
        if documentSurfaces.contains(where: { $0.id == ObjectIdentifier(document) }) {
            activateProjectDocument(document)
        }
        focusProjectHostWindow()
    }

    private func suppressBackgroundWindows(of document: NSDocument) {
        for windowController in document.windowControllers {
            windowController.window?.animationBehavior = .none
            windowController.window?.orderOut(nil)
        }
    }

    private func focusProjectHostWindow() {
        guard let document = activeProjectHost else { return }
        if document.windowControllers.isEmpty {
            document.makeWindowControllers()
        }
        guard let window = document.windowControllers.first?.window else { return }
        if !window.isVisible {
            document.showWindows()
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func focusEditorWhenMounted(_ surface: ProjectDocumentSurface) {
        Task { @MainActor [weak self, weak surface] in
            for _ in 0 ..< 6 {
                await Task.yield()
                guard let self,
                      let surface,
                      self.activeSurfaceID == surface.id
                else { return }
                if surface.sourceEditorSession.focusEditor() {
                    return
                }
            }
        }
    }

    private func restoreProject(document: NSDocument?) {
        projectDocument = document
        browser.associateProjectWindow(with: document)
        focusProjectHostWindow()
    }

    private func isReusableProjectShell(_ document: NSDocument) -> Bool {
        ProjectDocumentTargetPolicy.isReusableShell(
            document,
            isAssociated: browser.isAssociatedProjectDocument(document),
            isRegistered: NSDocumentController.shared.documents.contains(where: {
                $0 === document
            })
        )
    }

    private func closeUncommittedDocumentIfSafe(_ document: NSDocument) {
        let isRegistered = NSDocumentController.shared.documents.contains(where: {
            $0 === document
        })
        guard isRegistered else { return }
        if ProjectDocumentTargetPolicy.canCloseUncommitted(
            document,
            isRegistered: isRegistered
        ) {
            document.close()
            return
        }
        document.showWindows()
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshedProjectDocumentReceipt(
        _ receipt: ProjectDocumentOpenReceipt,
        targetURL: URL
    ) -> ProjectDocumentOpenReceipt? {
        guard let refreshedReceipt = receipt.refreshed(),
              ProjectSessionBoundary.authorizationIsCurrent(
                  refreshedReceipt.authorization,
                  targetURL: targetURL,
                  browser: browser
              )
        else {
            return nil
        }
        return refreshedReceipt
    }

    private func completeDocumentTabOpen(
        _ openedDocument: NSDocument,
        replacing current: NSDocument?,
        targetURL: URL,
        receipt: ProjectDocumentOpenReceipt,
        switchToken: UUID,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard documentSwitchGate.isActive(switchToken) else { return }
        guard let currentReceipt = refreshedProjectDocumentReceipt(
            receipt,
            targetURL: targetURL
        ) else {
            closeUncommittedDocumentIfSafe(openedDocument)
            restoreProject(document: current)
            finishDocumentSwitch(
                switchToken,
                result: .failure(DocumentOpenError.targetChanged),
                completion: completion
            )
            return
        }
        willActivateDocumentSurface(openedDocument)
        prepareProjectDocumentSurface(openedDocument)
        guard let attachedReceipt = refreshedProjectDocumentReceipt(
            currentReceipt,
            targetURL: targetURL
        ) else {
            browser.dissociateProjectWindow(openedDocument)
            restoreProject(document: current)
            closeUncommittedDocumentIfSafe(openedDocument)
            finishDocumentSwitch(
                switchToken,
                result: .failure(DocumentOpenError.targetChanged),
                completion: completion
            )
            return
        }
        NativeDocumentLoadedFileRegistry.register(
            openedDocument,
            authorization: attachedReceipt.authorization
        )
        finishDocumentSwitch(
            switchToken,
            result: .success(()),
            completion: completion
        )
    }

    private func finishDocumentSwitch(
        _ switchToken: UUID,
        result: Result<Void, Error>,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard finishSwitchToken(switchToken) else { return }
        completion(result)
    }

    private func closeAbandonedNewDocumentIfSafe(
        _ result: Result<OpenedDocumentResult, Error>,
        targetURL: URL
    ) {
        guard case let .success(opened) = result else { return }
        reservationRegistry.handleLateOpen(
            document: opened.document,
            targetURL: targetURL,
            wasAlreadyOpen: opened.wasAlreadyOpen,
            isProtected: { [weak self] document in
                self?.browser.isAssociatedProjectDocument(document) == true
            }
        )
    }

    /// An authorized open may finish after the coordinator that requested it
    /// has gone away. Close only a genuinely new, still-hidden blank native
    /// result; never take ownership of an existing or project-associated one.
    static func closeOpenedDocumentAfterCoordinatorReleaseIfSafe(
        _ result: Result<OpenedDocumentResult, Error>,
        browser: FolderBrowserController?
    ) {
        guard case let .success(opened) = result,
              !opened.wasAlreadyOpen,
              browser?.isAssociatedProjectDocument(opened.document) != true
        else { return }
        let isRegistered = NSDocumentController.shared.documents.contains {
            $0 === opened.document
        }
        guard ProjectDocumentTargetPolicy.canCloseUncommitted(
            opened.document,
            isRegistered: isRegistered
        ) else { return }
        opened.document.close()
    }

    @discardableResult
    private func finishSwitchToken(_ switchToken: UUID) -> Bool {
        guard documentSwitchGate.finish(switchToken) else { return false }
        projectPreparationTasks.removeValue(forKey: switchToken)?.cancel()
        projectPreparationTimeouts.removeValue(forKey: switchToken)?.cancel()
        reservationRegistry.release(
            owner: switchToken,
            isProtected: { [weak self] document in
                self?.browser.isAssociatedProjectDocument(document) == true
            }
        )
        return true
    }
}

@MainActor
private struct InflowDocumentScene: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    let isEditable: Bool
    let recoveryCoordinator: DocumentRecoveryCoordinator
    @ObservedObject var preferences: AppPreferences
    let recentDocuments: RecentDocumentsController
    @ObservedObject var folderBrowser: FolderBrowserController
    @ObservedObject var projectCoordinator: LightweightProjectCoordinator
    @State private var nativeDocument: NSDocument?

    var body: some View {
        Group {
            if projectCoordinator.isProjectHostDocument(nativeDocument) {
                ProjectWorkspaceScene(
                    shellDocument: $document,
                    hostDocument: nativeDocument,
                    recoveryCoordinator: recoveryCoordinator,
                    preferences: preferences,
                    recentDocuments: recentDocuments,
                    folderBrowser: folderBrowser,
                    projectCoordinator: projectCoordinator
                )
            } else if projectCoordinator.isBackgroundProjectDocument(nativeDocument) {
                Color.clear
                    .accessibilityHidden(true)
                    .onAppear { registerBackgroundSurfaceIfNeeded() }
            } else {
                MarkdownEditorView(
                    document: $document,
                    fileURL: fileURL,
                    isEditable: isEditable,
                    recoveryCoordinator: recoveryCoordinator,
                    preferences: preferences,
                    recentDocuments: recentDocuments,
                    folderBrowser: folderBrowser,
                    projectCoordinator: projectCoordinator
                )
            }
        }
        .background {
            DocumentWindowResolver { window in
                guard let resolved = window.windowController?.document as? NSDocument else {
                    return false
                }
                if nativeDocument !== resolved {
                    nativeDocument = resolved
                }
                if let fileURL {
                    projectCoordinator.registerDocumentSurface(
                        nativeDocument: resolved,
                        content: $document,
                        fileURL: fileURL,
                        isEditable: isEditable
                    )
                }
                return true
            }
        }
    }

    private func registerBackgroundSurfaceIfNeeded() {
        guard let nativeDocument, let fileURL else { return }
        projectCoordinator.registerDocumentSurface(
            nativeDocument: nativeDocument,
            content: $document,
            fileURL: fileURL,
            isEditable: isEditable
        )
    }
}

@MainActor
private struct ProjectWorkspaceScene: View {
    @Binding var shellDocument: MarkdownDocument
    let hostDocument: NSDocument?
    let recoveryCoordinator: DocumentRecoveryCoordinator
    @ObservedObject var preferences: AppPreferences
    let recentDocuments: RecentDocumentsController
    @ObservedObject var folderBrowser: FolderBrowserController
    @ObservedObject var projectCoordinator: LightweightProjectCoordinator

    private var projectSidebarVisibility: Binding<Bool> {
        Binding(
            get: { preferences.workspaceProjectSidebarVisible },
            set: { preferences.workspaceProjectSidebarVisible = $0 }
        )
    }

    var body: some View {
        PersistentEdgeSplitView(
            edge: .leading,
            width: $preferences.workspaceProjectSidebarWidth,
            isEdgeVisible: preferences.workspaceProjectSidebarVisible,
            allowedWidth: AppPreferences.Limits.projectSidebarWidth,
            accessibilityLabel: "目录树与工作区分栏"
        ) {
            projectSidebar
                .frame(
                    minWidth: EditorWorkspaceMetrics.projectSidebarMinimumWidth,
                    maxWidth: EditorWorkspaceMetrics.projectSidebarMaximumWidth
                )
        } trailing: {
            workspaceContent
                .frame(minWidth: EditorWorkspaceMetrics.editorMinimumWidth)
        }
        .focusedSceneValue(\.projectSidebarVisibility, projectSidebarVisibility)
        .background(
            ProjectWorkspaceWindowTitle(
                title: projectCoordinator.activeDocumentSurface?.title
                    ?? folderBrowser.folderURL?.lastPathComponent
                    ?? "Inflow"
            )
        )
    }

    private var projectSidebar: some View {
        FolderBrowserSidebar(
            controller: folderBrowser,
            currentDocumentURL: projectCoordinator.activeDocumentSurface?.fileURL,
            onOpenDocument: { url in
                projectCoordinator.openDocument(
                    url,
                    replacing: projectCoordinator.activeDocumentSurface?.nativeDocument,
                    using: recentDocuments
                )
            },
            onOpenDocumentWithCompletion: { url, completion in
                projectCoordinator.openDocument(
                    url,
                    replacing: projectCoordinator.activeDocumentSurface?.nativeDocument,
                    using: recentDocuments,
                    completion: completion
                )
            },
            onOpenCreatedDocument: { url, completion in
                projectCoordinator.openDocument(
                    url,
                    replacing: projectCoordinator.activeDocumentSurface?.nativeDocument,
                    using: recentDocuments,
                    completion: completion
                )
            },
            onPrepareToReplaceCurrentDocument: { completion in
                projectCoordinator.prepareToReplaceCurrentDocument(
                    projectCoordinator.activeDocumentSurface?.nativeDocument,
                    completion: completion
                )
            },
            onCollapse: {
                preferences.workspaceProjectSidebarVisible = false
            }
        )
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            // Reserve the tab strip from the moment a project opens. Adding the
            // first file must not push the entire editor down by one row.
            ProjectDocumentTabBar(
                projectCoordinator: projectCoordinator,
                showsProjectSidebar: preferences.workspaceProjectSidebarVisible,
                onExpandProjectSidebar: {
                    preferences.workspaceProjectSidebarVisible = true
                }
            )
            Divider()
            activeEditor
        }
    }

    private var activeEditor: some View {
        let hasActiveSurface = projectCoordinator.activeSurfaceID != nil
        return ZStack {
            MarkdownEditorView(
                document: $shellDocument,
                fileURL: nil,
                isEditable: false,
                recoveryCoordinator: recoveryCoordinator,
                preferences: preferences,
                recentDocuments: recentDocuments,
                folderBrowser: folderBrowser,
                projectCoordinator: projectCoordinator,
                nativeDocumentOverride: hostDocument,
                workspaceWindowDocument: hostDocument,
                showsProjectSidebar: false,
                isWorkspaceSurfaceActive: !hasActiveSurface
            )
            .opacity(hasActiveSurface ? 0 : 1)
            .allowsHitTesting(!hasActiveSurface)
            .accessibilityHidden(hasActiveSurface)

            ForEach(projectCoordinator.documentSurfaces) { surface in
                let isActive = projectCoordinator.activeSurfaceID == surface.id
                projectEditor(for: surface, isActive: isActive)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                    .zIndex(isActive ? 1 : 0)
                    .onAppear {
                        projectCoordinator.documentSurfaceDidMount(surface.id)
                    }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func projectEditor(
        for surface: ProjectDocumentSurface,
        isActive: Bool
    ) -> some View {
        MarkdownEditorView(
            document: surface.content,
            fileURL: surface.fileURL,
            isEditable: surface.isEditable,
            recoveryCoordinator: recoveryCoordinator,
            preferences: preferences,
            recentDocuments: recentDocuments,
            folderBrowser: folderBrowser,
            projectCoordinator: projectCoordinator,
            nativeDocumentOverride: surface.nativeDocument,
            workspaceWindowDocument: hostDocument,
            showsProjectSidebar: false,
            tearsDownWhenRemovedFromWorkspace: true,
            sourceEditorSessionOverride: surface.sourceEditorSession,
            isWorkspaceSurfaceActive: isActive
        )
    }
}

@MainActor
private struct ProjectDocumentTabBar: View {
    @ObservedObject var projectCoordinator: LightweightProjectCoordinator
    let showsProjectSidebar: Bool
    let onExpandProjectSidebar: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if !showsProjectSidebar {
                WorkspacePaneVisibilityButton(
                    paneName: "目录树",
                    systemImage: "sidebar.left",
                    isExpanded: false,
                    action: onExpandProjectSidebar
                )
                .padding(.leading, 7)
                .padding(.trailing, 3)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(projectCoordinator.documentSurfaces) { surface in
                        let isActive = projectCoordinator.activeSurfaceID == surface.id
                        HStack(spacing: 2) {
                            Button {
                                projectCoordinator.selectDocumentSurface(surface.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                    Text(surface.title)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 10)
                                .padding(.trailing, 4)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                projectCoordinator.closeDocumentSurface(surface.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 5)
                            .help("关闭 \(surface.title)")
                            .accessibilityLabel("关闭文档：\(surface.title)")
                        }
                        .frame(height: 28)
                        .background(
                            isActive
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("打开的文档：\(surface.title)")
                        .accessibilityValue(isActive ? "当前" : "后台")
                        .contextMenu {
                            Button("关闭当前文件") {
                                projectCoordinator.closeDocumentSurfaces(
                                    in: .current,
                                    relativeTo: surface.id
                                )
                            }
                            Divider()
                            Button("关闭其他文件") {
                                projectCoordinator.closeDocumentSurfaces(
                                    in: .others,
                                    relativeTo: surface.id
                                )
                            }
                            .disabled(
                                ProjectDocumentTabSelection.targetIDs(
                                    for: .others,
                                    anchorID: surface.id,
                                    orderedIDs: projectCoordinator.documentSurfaces.map(\.id)
                                ).isEmpty
                            )
                            Button("关闭左侧文件") {
                                projectCoordinator.closeDocumentSurfaces(
                                    in: .left,
                                    relativeTo: surface.id
                                )
                            }
                            .disabled(
                                ProjectDocumentTabSelection.targetIDs(
                                    for: .left,
                                    anchorID: surface.id,
                                    orderedIDs: projectCoordinator.documentSurfaces.map(\.id)
                                ).isEmpty
                            )
                            Button("关闭右侧文件") {
                                projectCoordinator.closeDocumentSurfaces(
                                    in: .right,
                                    relativeTo: surface.id
                                )
                            }
                            .disabled(
                                ProjectDocumentTabSelection.targetIDs(
                                    for: .right,
                                    anchorID: surface.id,
                                    orderedIDs: projectCoordinator.documentSurfaces.map(\.id)
                                ).isEmpty
                            )
                        }
                        .accessibilityAction(named: "关闭当前文件") {
                            projectCoordinator.closeDocumentSurface(surface.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel("项目文档标签页")
    }
}

private struct ProjectWorkspaceWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.window?.title = title
        view.window?.representedURL = nil
    }
}

enum InflowTerminationPolicy {
    /// AppKit invokes the application delegate only after its document
    /// controller has completed the Save / Don't Save / Cancel review. Inflow
    /// has no second termination transaction of its own, so it must never
    /// silently turn that completed system review into a cancelled Quit.
    static var replyAfterAppKitDocumentReview: NSApplication.TerminateReply {
        return .terminateNow
    }
}

@MainActor
final class InflowApplicationDelegate: NSObject, NSApplicationDelegate {
    let recentDocuments: RecentDocumentsController
    let folderBrowser: FolderBrowserController
    let projectCoordinator: LightweightProjectCoordinator
    private let createUntitledDocument: (Any?) -> Void
    private let hasOpenDocuments: () -> Bool
    private let installLaunchIntegrations: (RecentDocumentsController) -> Void
    private var hasInstalledLaunchIntegrations = false
    private var hasReceivedExternalOpenRequest = false
    private var hasRequestedInitialDocument = false
    private var initialDocumentPresentationTask: Task<Void, Never>?

    override convenience init() {
        self.init(
            createUntitledDocument: { _ in
                do {
                    _ = try NSDocumentController.shared
                        .openUntitledDocumentAndDisplay(true)
                } catch {
                    LocalFailureLogController.shared.record(
                        .opening,
                        code: .fileUnavailable
                    )
                    NSDocumentController.shared.presentError(error)
                }
            },
            createProjectDocument: {
                try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            }
        )
    }

    init(
        createUntitledDocument: @escaping (Any?) -> Void,
        createProjectDocument: @escaping () throws -> NSDocument = {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
        },
        hasOpenDocuments: @escaping () -> Bool = {
            !NSDocumentController.shared.documents.isEmpty
        },
        installLaunchIntegrations: ((RecentDocumentsController) -> Void)? = nil
    ) {
        let folderBrowser = FolderBrowserController(restoresSavedFolder: false)
        let projectCoordinator = LightweightProjectCoordinator(
            browser: folderBrowser,
            createProjectDocument: createProjectDocument
        )
        let controller = RecentDocumentsController(
            capacity: { AppPreferences.LaunchFixed.recentDocumentCapacity },
            openBehavior: { .reuseBlankWindow },
            systemSynchronizer: { _ in },
            recordsOpenedDocuments: false,
            reusableBlankDocumentFilter: { document in
                !folderBrowser.isAssociatedProjectDocument(document)
                    && projectCoordinator.canReuseAsBlankDocument(document)
            },
            failureRecorder: { category, code in
                LocalFailureLogController.shared.record(category, code: code)
            },
            openedProjectURLs: { projectCoordinator.openedProjectURLs },
            focusExistingProject: { projectCoordinator.focusProject($0) },
            openProject: { projectCoordinator.openProject($0, reusableDocument: $1) }
        )
        recentDocuments = controller
        self.folderBrowser = folderBrowser
        self.projectCoordinator = projectCoordinator
        self.createUntitledDocument = createUntitledDocument
        self.hasOpenDocuments = hasOpenDocuments
        self.installLaunchIntegrations = installLaunchIntegrations ?? { controller in
            NSDocumentController.shared.autosavingDelay = 0
            controller.installMenuIntegration()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard !hasInstalledLaunchIntegrations else { return }
        hasInstalledLaunchIntegrations = true
        installLaunchIntegrations(recentDocuments)
        scheduleInitialDocumentIfNeeded()
    }

    func application(_: NSApplication, open urls: [URL]) {
        if !urls.isEmpty {
            hasReceivedExternalOpenRequest = true
            initialDocumentPresentationTask?.cancel()
            initialDocumentPresentationTask = nil
        }
        recentDocuments.openExternalDocuments(urls)
    }

    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        InflowLaunchPolicy.letsAppKitOpenUntitledDocument
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        createUntitledDocument(sender)
        return true
    }

    private func scheduleInitialDocumentIfNeeded() {
        guard initialDocumentPresentationTask == nil,
              !hasRequestedInitialDocument
        else {
            return
        }
        initialDocumentPresentationTask = Task { @MainActor [weak self] in
            // Finder/open-file delivery may follow didFinishLaunching. Give
            // that callback one main-actor turn to cancel the fallback before
            // any untitled window is constructed.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.initialDocumentPresentationTask = nil
            self.presentInitialDocumentIfNeeded()
        }
    }

    private func presentInitialDocumentIfNeeded() {
        guard !hasRequestedInitialDocument,
              InflowLaunchPolicy.shouldCreateInitialDocument(
                  hasReceivedExternalOpenRequest: hasReceivedExternalOpenRequest,
                  hasOpenDocuments: hasOpenDocuments()
              )
        else {
            return
        }
        hasRequestedInitialDocument = true
        createUntitledDocument(nil)
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        createUntitledDocument(nil)
        return true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // NSApplication has already asked NSDocumentController to review every
        // edited document before invoking this callback. Project loading and
        // other short-lived UI work must not make the Quit command a no-op.
        return InflowTerminationPolicy.replyAfterAppKitDocumentReview
    }
}

private struct OutlineVisibilityFocusedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct ProjectSidebarVisibilityFocusedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var outlineVisibility: Binding<Bool>? {
        get { self[OutlineVisibilityFocusedKey.self] }
        set { self[OutlineVisibilityFocusedKey.self] = newValue }
    }


    var projectSidebarVisibility: Binding<Bool>? {
        get { self[ProjectSidebarVisibilityFocusedKey.self] }
        set { self[ProjectSidebarVisibilityFocusedKey.self] = newValue }
    }
}

private struct OutlineCommands: Commands {
    @FocusedValue(\.outlineVisibility) private var outlineVisibility

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(
                outlineVisibility?.wrappedValue == true ? "隐藏大纲" : "显示大纲"
            ) {
                outlineVisibility?.wrappedValue.toggle()
            }
            .disabled(outlineVisibility == nil)
        }
    }
}

private struct InflowPrimaryCommands: Commands {
    let recentDocuments: RecentDocumentsController
    let folderBrowser: FolderBrowserController
    @FocusedValue(\.projectSidebarVisibility) private var projectSidebarVisibility

    var body: some Commands {
        DocumentSaveCommands()
        CommandGroup(after: .newItem) {
            Button("打开项目…") {
                recentDocuments.chooseProjectToOpen()
            }
            if folderBrowser.folderURL != nil {
                Button("刷新项目") { folderBrowser.refresh() }
                    .disabled(folderBrowser.state == .loading)
            }
        }
        EditorViewModeCommands()
        CommandGroup(after: .sidebar) {
            Toggle(
                "显示目录树",
                isOn: projectSidebarVisibility ?? .constant(false)
            )
            .disabled(projectSidebarVisibility == nil)
        }
        OutlineCommands()
    }
}

private struct InflowEditingCommands: Commands {
    let failureLog: LocalFailureLogController

    var body: some Commands {
        DocumentFindCommands()
        HTMLExportCommands()
        MarkdownFormatCommands()
        MarkdownInsertCommands()
        InflowSupplementalCommands(failureLog: failureLog)
    }
}

@main
struct InflowApp: App {
    @NSApplicationDelegateAdaptor(InflowApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var recoveryCoordinator = DocumentRecoveryRuntime.makeCoordinator()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var failureLog = LocalFailureLogController.shared

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            ManualSaveDocumentGate {
                InflowDocumentScene(
                    document: configuration.$document,
                    fileURL: configuration.fileURL,
                    isEditable: configuration.isEditable,
                    recoveryCoordinator: recoveryCoordinator,
                    preferences: preferences,
                    recentDocuments: applicationDelegate.recentDocuments,
                    folderBrowser: applicationDelegate.folderBrowser,
                    projectCoordinator: applicationDelegate.projectCoordinator
                )
            }
            .frame(
                minWidth: EditorWorkspaceMetrics.minimumWindowWidth,
                minHeight: EditorWorkspaceMetrics.minimumWindowHeight
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .defaultSize(
            width: EditorWorkspaceMetrics.defaultWindowWidth,
            height: EditorWorkspaceMetrics.defaultWindowHeight
        )
        .commands {
            InflowPrimaryCommands(
                recentDocuments: applicationDelegate.recentDocuments,
                folderBrowser: applicationDelegate.folderBrowser
            )
            InflowEditingCommands(failureLog: failureLog)
        }

        Settings {
            InflowSettingsView(preferences: preferences)
        }

        Window("Inflow 帮助", id: InflowHelpWindow.identifier) {
            InflowHelpView()
        }
        .defaultSize(width: 760, height: 680)

    }
}
