import AppKit
import SwiftUI

struct SourceOnlyDocumentBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("已切换为源码优先").font(.headline)
                Text(
                    "文件大于 1 MiB。完整源码、查找、保存、恢复和冲突保护仍可用；"
                        + "实时/纯预览、大纲、完整语法高亮、诊断、统计和结构格式已暂停。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyMarkdownPreviewView: View {
    let onStartWriting: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(EmptyMarkdownGuidance.title, systemImage: "doc.text")
        } description: {
            Text(EmptyMarkdownGuidance.description)
        } actions: {
            Button("在源码编辑器中开始", action: onStartWriting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
    }
}

/// Keeps the scene's native document identity available while SwiftUI resolves
/// an ordinary document window or the project shell shows empty guidance.
@MainActor
final class MarkdownEditorNativeDocumentHost: ObservableObject {
    weak private(set) var document: NSDocument?

    func attach(_ document: NSDocument) {
        guard self.document !== document else { return }
        objectWillChange.send()
        self.document = document
    }
}

struct MarkdownEditorNativeDocumentResolver: NSViewRepresentable {
    let onResolve: @MainActor (NSDocument) -> Void

    func makeNSView(context _: Context) -> ResolverView {
        ResolverView(onResolve: onResolve)
    }

    func updateNSView(_ view: ResolverView, context _: Context) {
        view.onResolve = onResolve
        view.resolveIfPossible()
    }

    final class ResolverView: NSView {
        var onResolve: @MainActor (NSDocument) -> Void
        private weak var candidateWindow: NSWindow?
        private weak var resolvedDocument: NSDocument?
        private var resolutionTask: Task<Void, Never>?

        init(onResolve: @escaping @MainActor (NSDocument) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit { resolutionTask?.cancel() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                resolutionTask?.cancel()
                resolutionTask = nil
                candidateWindow = nil
                return
            }
            resolveIfPossible()
        }

        @MainActor
        func resolveIfPossible() {
            guard let window else { return }
            if let document = window.windowController?.document as? NSDocument {
                resolutionTask?.cancel()
                resolutionTask = nil
                candidateWindow = window
                if resolvedDocument !== document {
                    resolvedDocument = document
                    onResolve(document)
                }
                return
            }
            guard resolutionTask == nil else { return }
            candidateWindow = window
            resolutionTask = Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                for attempt in 0 ..< 50 {
                    await Task.yield()
                    guard !Task.isCancelled,
                          self.window === window,
                          self.candidateWindow === window
                    else { return }
                    if let document = window.windowController?.document as? NSDocument {
                        self.resolvedDocument = document
                        self.resolutionTask = nil
                        self.onResolve(document)
                        return
                    }
                    if attempt < 49 { try? await Task.sleep(for: .milliseconds(20)) }
                }
                self.resolutionTask = nil
            }
        }
    }
}

/// Preserve standard macOS close, minimize and full-screen behavior.
struct DocumentWindowControls: NSViewRepresentable {
    func makeNSView(context _: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context _: Context) {
        view.configureWindow()
    }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            // AppKit setters can invalidate native window commands even when the
            // assigned value is unchanged. SwiftUI can refresh this view while
            // the Window menu is open, so only write actual policy changes.
            if !window.styleMask.contains(.miniaturizable) {
                window.styleMask.insert(.miniaturizable)
            }
            var behavior = window.collectionBehavior
            behavior.remove([.fullScreenNone, .fullScreenAuxiliary])
            behavior.insert(.fullScreenPrimary)
            if window.collectionBehavior != behavior {
                window.collectionBehavior = behavior
            }
        }
    }
}

/// SwiftUI reconciles its generated Window submenu when focused commands
/// change. AppKit's dynamically inserted tiling items are not in that model,
/// so give AppKit a separate submenu whose contents SwiftUI never reconciles.
@MainActor
final class NativeWindowMenuController {
    private(set) var menu: NSMenu?
    private var windowMenuTitle: String?
    private var observers: [NSObjectProtocol] = []
    private var menuObservations: [NSKeyValueObservation] = []
    private var installationTask: Task<Void, Never>?

    func install() {
        guard observers.isEmpty else { return }
        observers = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
            NSMenu.didRemoveItemNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let changedMenu = notification.object as? NSMenu else { return }
                let changedID = ObjectIdentifier(changedMenu)
                MainActor.assumeIsolated {
                    guard NSApp.mainMenu.map(ObjectIdentifier.init) == changedID else { return }
                    self?.scheduleInstallation()
                }
            }
        }
        menuObservations = [
            NSApp.observe(\.mainMenu) { [weak self] _, _ in
                Task { @MainActor in self?.scheduleInstallation() }
            },
            NSApp.observe(\.windowsMenu) { [weak self] _, _ in
                Task { @MainActor in self?.scheduleInstallation() }
            },
        ]
        scheduleInstallation()
    }

    func stop() {
        installationTask?.cancel()
        installationTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        menuObservations.removeAll()
    }

    private func scheduleInstallation() {
        guard !observers.isEmpty, installationTask == nil else { return }
        installationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.installationTask = nil
            self.attachToMainMenu()
        }
    }

    func attachToMainMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let item = mainMenu.items.first(where: { item in
                  guard let submenu = item.submenu else { return false }
                  return submenu === menu || submenu === NSApp.windowsMenu
                      || (windowMenuTitle != nil && item.title == windowMenuTitle)
                      || submenu.items.contains { $0.action == #selector(NSWindow.performMiniaturize(_:)) }
              }) else { return }
        if menu == nil {
            windowMenuTitle = item.title
            let nativeMenu = NSMenu(title: item.title)
            nativeMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            nativeMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            nativeMenu.addItem(.separator())
            nativeMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
            menu = nativeMenu
        }
        guard let menu else { return }
        if item.submenu !== menu { item.submenu = menu }
        if NSApp.windowsMenu !== menu {
            NSApp.windowsMenu = menu
            for window in NSApp.windows where window.isVisible && !window.isExcludedFromWindowsMenu {
                NSApp.updateWindowsItem(window)
            }
        }
    }
}

/// Document ownership stays with NSDocument. Only the visible window changes
/// when selecting a tab, so native Save, close review and undo remain intact.
@MainActor
final class DocumentWindowTabs: ObservableObject {
    static let shared = DocumentWindowTabs()
    enum TabID: Equatable {
        case window(ObjectIdentifier)
        case pending(UUID)
    }
    struct Item: Identifiable {
        let id: ObjectIdentifier
        weak var window: NSWindow?
    }
    struct Pending: Identifiable {
        let id: UUID
        var title: String
        let dismiss: () -> Void
        let open: () -> Void
        var isOpening = false
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var pending: [Pending] = []
    @Published private(set) var selected: ObjectIdentifier?
    private var titleObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                guard let window = event.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { self?.remove(window, selectingNeighbor: true) }
                    else { self?.activate(window) }
                }
            }
        }
    }

    func register(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard !items.contains(where: { $0.id == id }) else { return }
        window.tabbingMode = .disallowed
        items.append(Item(id: id, window: window))
        titleObservers[id] = window.observe(\.title) { [weak self] _, _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        if window.isVisible || selected == nil { activate(window) }
    }

    func activate(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard items.contains(where: { $0.id == id }) else { return }
        if selected != id {
            if let previous = items.first(where: { $0.id == selected })?.window,
               !previous.styleMask.contains(.fullScreen), !window.styleMask.contains(.fullScreen) {
                window.setFrame(previous.frame, display: true)
            }
            selected = id
        }
        for item in items where item.id != id { item.window?.orderOut(nil) }
    }

    func select(_ item: Item) {
        guard items.contains(where: { $0.id == item.id }), let window = item.window else { return }
        activate(window)
        window.makeKeyAndOrderFront(nil)
    }

    func remove(_ window: NSWindow, selectingNeighbor: Bool = false) {
        let id = ObjectIdentifier(window)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        titleObservers.removeValue(forKey: id)
        guard selected == id else { return }
        selected = nil
        if selectingNeighbor, !items.isEmpty {
            let next = items[min(index, items.count - 1)]
            Task { @MainActor [weak self] in self?.select(next) }
        }
    }

    func addPending(_ placeholder: RecoveryDraftPlaceholder, dismiss: @escaping () -> Void = {}, open: @escaping () -> Void) {
        guard !pending.contains(where: { $0.id == placeholder.id }) else { return }
        pending.append(Pending(id: placeholder.id, title: placeholder.title, dismiss: dismiss, open: open))
    }

    func openPending(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }), !pending[index].isOpening else { return }
        pending[index].isOpening = true
        pending[index].open()
    }

    func removePending(_ id: UUID) {
        if pending.contains(where: { $0.id == id }) { pending.removeAll { $0.id == id } }
    }

    func closePending(_ id: UUID) {
        pending.first(where: { $0.id == id })?.dismiss()
        removePending(id)
    }

    func namePending(_ id: UUID, title: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }), pending[index].title != title else { return }
        pending[index].title = title
    }

    func targets(_ scope: ProjectDocumentTabSelection.CloseScope, relativeTo anchor: TabID) -> [TabID] {
        ProjectDocumentTabSelection.targetIDs(for: scope, anchorID: anchor,
            orderedIDs: items.filter { $0.window != nil }.map { .window($0.id) }
                + pending.map { .pending($0.id) })
    }

    func close(_ scope: ProjectDocumentTabSelection.CloseScope, relativeTo anchor: TabID) {
        let targets = targets(scope, relativeTo: anchor)
        // Remove unloaded placeholders first: closing the final native window
        // may end the process. Their original recovery files remain intact.
        for case let .pending(id) in targets { closePending(id) }
        for case let .window(id) in targets {
            items.first(where: { $0.id == id })?.window?.performClose(nil)
        }
    }
}

/// A public AppKit titlebar accessory shares the traffic-light row. The custom
/// tabs replace the extra native tab strip rather than hiding private AppKit views.
struct DocumentTitlebar<Content: View>: NSViewRepresentable {
    var isEnabled: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }
    func updateNSView(_ view: TitlebarView, context: Context) {
        view.content = AnyView(content())
        view.isEnabled = isEnabled
        view.configure()
    }
    static func dismantleNSView(_ view: TitlebarView, coordinator: ()) { view.detach() }

    final class TitlebarView: NSView {
        var content = AnyView(EmptyView())
        var isEnabled = true
        private weak var attachedWindow: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?
        private var host: NSHostingView<AnyView>?
        private var layoutObservers: [NSObjectProtocol] = []
        private var configurationTask: Task<Void, Never>?
        private var isFullScreen = false
        private var isResizing = false

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            configurationTask?.cancel()
            configurationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let window = self.window else { return }
                guard self.isEnabled else { self.detach(); return }
                if self.attachedWindow !== window {
                    self.detach()
                    self.attachedWindow = window
                    self.isFullScreen = window.styleMask.contains(.fullScreen)
                    window.tabbingMode = .disallowed
                    window.titleVisibility = .hidden
                    let controller = NSTitlebarAccessoryViewController()
                    controller.layoutAttribute = .left
                    controller.automaticallyAdjustsSize = false
                    let host = NSHostingView(rootView: self.content)
                    host.sizingOptions = []
                    controller.view = host
                    self.host = host
                    self.accessory = controller
                    self.resize()
                    window.addTitlebarAccessoryViewController(controller)
                    self.layoutObservers = [NSWindow.didResizeNotification,
                        NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                        NSWindow.didExitFullScreenNotification].map { name in
                        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                            [weak self] _ in MainActor.assumeIsolated {
                                if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.didEnterFullScreenNotification {
                                    self?.isFullScreen = true
                                } else if name == NSWindow.didExitFullScreenNotification {
                                    self?.isFullScreen = false
                                }
                                self?.resize()
                            }
                        }
                    }
                    DocumentWindowTabs.shared.register(window)
                }
                self.host?.rootView = self.content
                self.resize()
            }
        }
        private func resize() {
            guard !isResizing, let window = attachedWindow, let accessory else { return }
            isResizing = true
            defer { isResizing = false }
            let fullScreen = isFullScreen
            let height = ThemeStyleResources.defaults.token("titlebar-height")
            // AppKit only honors fullScreenMinHeight for bottom accessories.
            // Keep the tab/side-panel controls visible when the system hides
            // traffic lights in full screen; normal windows still use one row.
            let attribute: NSLayoutConstraint.Attribute = fullScreen ? .bottom : .left
            if accessory.layoutAttribute != attribute { accessory.layoutAttribute = attribute }
            let minimumHeight = fullScreen ? height : 0
            if accessory.fullScreenMinHeight != minimumHeight { accessory.fullScreenMinHeight = minimumHeight }
            let reserved = fullScreen ? 0 : ThemeStyleResources.defaults.token("titlebar-controls-width")
            let size = NSSize(width: max(0, window.frame.width - reserved), height: height)
            if host?.frame.size != size { host?.setFrameSize(size) }
        }
        func detach() {
            layoutObservers.forEach { NotificationCenter.default.removeObserver($0) }
            layoutObservers.removeAll()
            if let window = attachedWindow {
                DocumentWindowTabs.shared.remove(window)
                if let accessory, let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
            }
            attachedWindow = nil; accessory = nil; host = nil
        }
    }
}
