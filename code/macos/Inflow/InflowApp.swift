import SwiftUI

private enum ManualSaveDocumentGateState: Equatable {
    case pending
    case ready
    case failed(String)
}

@MainActor
final class ManualSaveDocumentGateRegistry {
    static let shared = ManualSaveDocumentGateRegistry()

    private final class Entry {
        weak var window: NSWindow?
        weak var document: NSDocument?
        var owners: Set<UUID>

        init(window: NSWindow, document: NSDocument?, owner: UUID) {
            self.window = window
            self.document = document
            owners = [owner]
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func block(_ window: NSWindow, document: NSDocument?, owner: UUID) {
        removeReleasedEntries()
        let windowID = ObjectIdentifier(window)
        if let entry = entries[windowID] {
            entry.document = document ?? entry.document
            entry.owners.insert(owner)
        } else {
            entries[windowID] = Entry(window: window, document: document, owner: owner)
        }
    }

    func unblock(_ window: NSWindow?, owner: UUID) {
        guard let window else { return }
        let windowID = ObjectIdentifier(window)
        guard let entry = entries[windowID] else { return }
        entry.owners.remove(owner)
        if entry.owners.isEmpty {
            entries.removeValue(forKey: windowID)
        }
    }

    var hasBlockedDocumentGates: Bool {
        removeReleasedEntries()
        return !entries.isEmpty
    }

    func focusFirstBlockedWindow() {
        removeReleasedEntries()
        guard let window = entries.values.compactMap(\.window).first else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func removeReleasedEntries() {
        entries = entries.filter { $0.value.window != nil }
    }
}

/// Keeps the entire editor tree out of the hierarchy until the concrete
/// DocumentGroup host has adopted and verified the manual-save policy.
private struct ManualSaveDocumentGate<Content: View>: View {
    @State private var state = ManualSaveDocumentGateState.pending
    @State private var blockedWindow: NSWindow?
    @State private var blockedDocument: NSDocument?
    @State private var isConfirmingDiscard = false
    @State private var registryOwner = UUID()
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
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
        .onDisappear {
            releaseBlockedHost()
        }
    }

    @MainActor
    private func configureHost(in window: NSWindow) -> Bool {
        guard state == .pending else { return true }
        releasePreviousHost(ifDifferentFrom: window)
        blockedWindow = window
        window.standardWindowButton(.closeButton)?.isEnabled = false
        ManualSaveDocumentGateRegistry.shared.block(
            window,
            document: blockedDocument,
            owner: registryOwner
        )
        guard let document = window.windowController?.document as? NSDocument,
              NSDocumentController.shared.documents.contains(where: { $0 === document })
        else {
            return false
        }
        blockedDocument = document
        ManualSaveDocumentGateRegistry.shared.block(
            window,
            document: document,
            owner: registryOwner
        )

        do {
            try ManualSaveDocumentHostPolicy.apply(to: document)
            ManualSaveDocumentGateRegistry.shared.unblock(window, owner: registryOwner)
            window.standardWindowButton(.closeButton)?.isEnabled = true
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
        window.standardWindowButton(.closeButton)?.isEnabled = false
        ManualSaveDocumentGateRegistry.shared.block(
            window,
            document: blockedDocument,
            owner: registryOwner
        )
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
        ManualSaveDocumentGateRegistry.shared.unblock(window, owner: registryOwner)
        window?.standardWindowButton(.closeButton)?.isEnabled = true
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
        guard let previous = blockedWindow, previous !== window else { return }
        ManualSaveDocumentGateRegistry.shared.unblock(previous, owner: registryOwner)
        previous.standardWindowButton(.closeButton)?.isEnabled = true
        blockedDocument = nil
        blockedWindow = nil
    }

    @MainActor
    private func releaseBlockedHost() {
        let window = blockedWindow
        ManualSaveDocumentGateRegistry.shared.unblock(window, owner: registryOwner)
        window?.standardWindowButton(.closeButton)?.isEnabled = true
        blockedDocument = nil
        blockedWindow = nil
    }
}

private struct DocumentWindowResolver: NSViewRepresentable {
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
        private let registryOwner = UUID()

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
                ManualSaveDocumentGateRegistry.shared.unblock(
                    candidateWindow,
                    owner: registryOwner
                )
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
            if let previous = candidateWindow, previous !== window {
                ManualSaveDocumentGateRegistry.shared.unblock(
                    previous,
                    owner: registryOwner
                )
                previous.standardWindowButton(.closeButton)?.isEnabled = true
            }
            window.standardWindowButton(.closeButton)?.isEnabled = false
            ManualSaveDocumentGateRegistry.shared.block(
                window,
                document: window.windowController?.document as? NSDocument,
                owner: registryOwner
            )
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
final class LightweightProjectCoordinator {
    let browser: FolderBrowserController
    private weak var projectDocument: NSDocument?
    private let createProjectDocument: () throws -> NSDocument
    private let documentSwitchGate = ProjectDocumentSwitchGate()
    private let reservationRegistry = ProjectDocumentReservationRegistry()
    private var projectPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var projectPreparationTimeouts: [UUID: Task<Void, Never>] = [:]

    init(
        browser: FolderBrowserController,
        createProjectDocument: @escaping () throws -> NSDocument
    ) {
        self.browser = browser
        self.createProjectDocument = createProjectDocument
    }

    var openedProjectURLs: [URL] {
        guard activeProjectDocument != nil else { return [] }
        return browser.folderURL.map { [$0] } ?? []
    }

    var hasActiveDocumentSwitch: Bool { documentSwitchGate.isBusy }

    func canReuseAsBlankDocument(_ document: NSDocument) -> Bool {
        !reservationRegistry.isReserved(document)
    }

    func focusCurrentDocumentWindow() {
        let document = activeProjectDocument
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
        let previousDocument = activeProjectDocument
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
            guard self.browser.commitPreparedFolder(preparation) else {
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

            self.attach(to: targetDocument)
            if let previousDocument, previousDocument !== targetDocument {
                previousDocument.close()
            }
            self.finishSwitchToken(switchToken)
        }
    }

    func focusProject(_: URL) {
        guard !DocumentCloseAuthorization.hasPendingRequests,
              let switchToken = documentSwitchGate.begin()
        else { return }
        defer { finishSwitchToken(switchToken) }
        let document = activeProjectDocument
        guard let document else { return }
        attach(to: document)
    }

    func prepareToReplaceCurrentDocument(
        _ candidate: NSDocument?,
        completion: @escaping (Bool) -> Void
    ) {
        guard !documentSwitchGate.isBusy,
              !DocumentCloseAuthorization.hasPendingRequests
        else {
            completion(false)
            return
        }
        DocumentCloseAuthorization.request(
            for: currentProjectDocument(candidate),
            completion: completion
        )
    }

    func openDocument(
        _ url: URL,
        replacing candidate: NSDocument?,
        using recentDocuments: RecentDocumentsController,
        requiresCloseAuthorization: Bool = true,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard let root = browser.folderURL,
              FolderProjectPathBoundary.contains(url, in: root)
        else {
            completion(.failure(DocumentOpenError.unsupportedTarget))
            return
        }

        guard !documentSwitchGate.isBusy,
              !DocumentCloseAuthorization.hasPendingRequests
        else {
            completion(.failure(DocumentOpenError.cancelled))
            return
        }

        let current = currentProjectDocument(candidate)
        if let currentURL = current?.fileURL,
           DocumentRelocationAnalyzer.isSameFile(currentURL, url)
        {
            current?.showWindows()
            current?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            completion(.success(()))
            return
        }

        if let existing = NativeDocumentSaveCoordinator.documentAlreadyOpen(
            at: url,
            excluding: current
        ) {
            existing.showWindows()
            existing.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        recentDocuments.openDocumentFromFolderDetailed(
            url,
            display: false
        ) { [weak self, weak current] result in
            timeoutTask.cancel()
            guard let self else { return }
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
                guard !opened.wasAlreadyOpen else {
                    opened.document.showWindows()
                    opened.document.windowControllers.first?.window?
                        .makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    self.finishDocumentSwitch(
                        switchToken,
                        result: .success(()),
                        completion: completion
                    )
                    return
                }

                guard requiresCloseAuthorization else {
                    // This path is used only by project-tree creation. Its
                    // still-present sheet keeps the old editor modal after
                    // the pre-creation close review, so no new user edit can
                    // appear between that review and this replacement.
                    self.completeDocumentReplacement(
                        opened.document,
                        replacing: current,
                        switchToken: switchToken,
                        completion: completion
                    )
                    return
                }

                // Opening is asynchronous, so the old editor may have
                // changed after the click. Review it only now, immediately
                // before replacement. Keep the freshly opened window hidden
                // until the user decides which document remains current.
                opened.document.windowControllers.forEach {
                    $0.window?.orderOut(nil)
                }
                current?.showWindows()
                current?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                DocumentCloseAuthorization.request(for: current) { [weak self, weak current] shouldReplace in
                    guard let self,
                          self.documentSwitchGate.isActive(switchToken)
                    else { return }
                    guard shouldReplace else {
                        self.closeUncommittedDocumentIfSafe(opened.document)
                        current?.showWindows()
                        current?.windowControllers.first?.window?
                            .makeKeyAndOrderFront(nil)
                        self.finishDocumentSwitch(
                            switchToken,
                            result: .failure(DocumentOpenError.cancelled),
                            completion: completion
                        )
                        return
                    }
                    self.completeDocumentReplacement(
                        opened.document,
                        replacing: current,
                        switchToken: switchToken,
                        completion: completion
                    )
                }
            case let .failure(error):
                self.finishDocumentSwitch(
                    switchToken,
                    result: .failure(error),
                    completion: completion
                )
            }
        }
    }

    private var activeProjectDocument: NSDocument? {
        guard let document = projectDocument,
              NSDocumentController.shared.documents.contains(where: { $0 === document }),
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

    private func currentProjectDocument(_ candidate: NSDocument?) -> NSDocument? {
        if browser.isAssociatedProjectDocument(candidate) {
            return candidate
        }
        return activeProjectDocument
    }

    private func attach(to document: NSDocument?) {
        projectDocument = document
        browser.associateProjectWindow(with: document)
        if let document, document.windowControllers.isEmpty {
            document.makeWindowControllers()
        }
        document?.showWindows()
        document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreProject(document: NSDocument?) {
        projectDocument = document
        browser.associateProjectWindow(with: document)
        document?.showWindows()
        document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
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

    private func completeDocumentReplacement(
        _ openedDocument: NSDocument,
        replacing current: NSDocument?,
        switchToken: UUID,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard documentSwitchGate.isActive(switchToken) else { return }
        attach(to: openedDocument)
        if let current, current !== openedDocument {
            current.close()
        }
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
final class InflowApplicationDelegate: NSObject, NSApplicationDelegate {
    let recentDocuments: RecentDocumentsController
    let folderBrowser: FolderBrowserController
    let projectCoordinator: LightweightProjectCoordinator
    private let createUntitledDocument: (Any?) -> Void
    private let installLaunchIntegrations: (RecentDocumentsController) -> Void
    private var hasInstalledLaunchIntegrations = false
    private var isReviewingTermination = false

    override convenience init() {
        self.init(
            createUntitledDocument: { sender in
                NSDocumentController.shared.newDocument(sender)
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
    }

    func application(_: NSApplication, open urls: [URL]) {
        recentDocuments.openExternalDocuments(urls)
    }

    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        InflowLaunchPolicy.automaticallyOpensUntitledDocument
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        createUntitledDocument(sender)
        return true
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
        guard !ManualSaveDocumentGateRegistry.shared.hasBlockedDocumentGates else {
            ManualSaveDocumentGateRegistry.shared.focusFirstBlockedWindow()
            return .terminateCancel
        }
        guard !projectCoordinator.hasActiveDocumentSwitch,
              !DocumentCloseAuthorization.hasPendingRequests
        else {
            projectCoordinator.focusCurrentDocumentWindow()
            return .terminateCancel
        }
        guard NSDocumentController.shared.hasEditedDocuments else {
            return .terminateNow
        }
        guard !isReviewingTermination else { return .terminateLater }
        isReviewingTermination = true
        NSDocumentController.shared.reviewUnsavedDocuments(
            withAlertTitle: nil,
            cancellable: true,
            delegate: self,
            didReviewAllSelector: #selector(documentController(_:didReviewAll:contextInfo:)),
            contextInfo: nil
        )
        return .terminateLater
    }

    @objc private func documentController(
        _ documentController: NSDocumentController,
        didReviewAll: Bool,
        contextInfo _: UnsafeMutableRawPointer?
    ) {
        isReviewingTermination = false
        guard didReviewAll else {
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        guard !ManualSaveDocumentGateRegistry.shared.hasBlockedDocumentGates else {
            ManualSaveDocumentGateRegistry.shared.focusFirstBlockedWindow()
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        guard !projectCoordinator.hasActiveDocumentSwitch,
              !DocumentCloseAuthorization.hasPendingRequests
        else {
            projectCoordinator.focusCurrentDocumentWindow()
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        NSApp.reply(toApplicationShouldTerminate: true)
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
                "显示项目侧栏",
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
    @StateObject private var recoveryCoordinator = DocumentRecoveryCoordinator()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var failureLog = LocalFailureLogController.shared

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            ManualSaveDocumentGate {
                MarkdownEditorView(
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
            .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            InflowPrimaryCommands(
                recentDocuments: applicationDelegate.recentDocuments,
                folderBrowser: applicationDelegate.folderBrowser
            )
            InflowEditingCommands(failureLog: failureLog)
        }

        Window("Inflow 帮助", id: InflowHelpWindow.identifier) {
            InflowHelpView()
        }
        .defaultSize(width: 760, height: 680)

    }
}
