import AppKit
import SwiftUI

/// Updating an `NSHostingView.rootView` replaces the root of that SwiftUI tree
/// and can discard local state in a sidebar while an unrelated editor changes.
/// This stable relay keeps the hosting root fixed and lets SwiftUI diff only
/// the changed descendants.
@MainActor
private final class PersistentHostingContent<Content: View>: ObservableObject {
    @Published var content: Content

    init(_ content: Content) {
        self.content = content
    }
}

private struct PersistentHostingRoot<Content: View>: View {
    @ObservedObject var relay: PersistentHostingContent<Content>

    var body: some View {
        relay.content
    }
}

enum EditorSplitLayout {
    static let allowedFraction = 0.25 ... 0.75
    static let defaultFraction = 0.5

    static func normalized(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultFraction }
        return min(max(fraction, allowedFraction.lowerBound), allowedFraction.upperBound)
    }

    static func position(
        for fraction: Double,
        totalWidth: CGFloat,
        dividerThickness: CGFloat
    ) -> CGFloat {
        let availableWidth = max(0, totalWidth - dividerThickness)
        return availableWidth * normalized(fraction)
    }

    static func fraction(
        for position: CGFloat,
        totalWidth: CGFloat,
        dividerThickness: CGFloat
    ) -> Double {
        let availableWidth = max(0, totalWidth - dividerThickness)
        guard availableWidth > 0 else { return defaultFraction }
        return normalized(Double(position / availableWidth))
    }
}

enum WorkspaceSplitEdge: Equatable, Sendable {
    case leading
    case trailing
}

enum WorkspaceEdgeSplitLayout {
    static func normalized(
        _ width: Double,
        allowedWidth: ClosedRange<Double>
    ) -> Double {
        guard width.isFinite else { return allowedWidth.lowerBound }
        return min(max(width, allowedWidth.lowerBound), allowedWidth.upperBound)
    }

    static func position(
        for edgeWidth: Double,
        edge: WorkspaceSplitEdge,
        totalWidth: CGFloat,
        dividerThickness: CGFloat,
        allowedWidth: ClosedRange<Double>
    ) -> CGFloat {
        let availableWidth = max(0, totalWidth - dividerThickness)
        let resolvedWidth = min(
            availableWidth,
            CGFloat(normalized(edgeWidth, allowedWidth: allowedWidth))
        )
        return switch edge {
        case .leading: resolvedWidth
        case .trailing: availableWidth - resolvedWidth
        }
    }

    static func edgeWidth(
        for position: CGFloat,
        edge: WorkspaceSplitEdge,
        totalWidth: CGFloat,
        dividerThickness: CGFloat,
        allowedWidth: ClosedRange<Double>
    ) -> Double {
        let availableWidth = max(0, totalWidth - dividerThickness)
        let proposedWidth = switch edge {
        case .leading: position
        case .trailing: availableWidth - position
        }
        return normalized(Double(proposedWidth), allowedWidth: allowedWidth)
    }
}

@MainActor
private final class EdgeWidthSplitView: NSSplitView {
    var desiredEdgeWidth = 0.0
    var edge = WorkspaceSplitEdge.leading
    var allowedWidth = 0.0 ... 0.0
    private var isApplyingDesiredWidth = false

    func applyDesiredWidth() {
        let totalWidth = max(0, bounds.width)
        let totalHeight = max(0, bounds.height)
        guard subviews.count == 2, totalWidth > dividerThickness else { return }
        isApplyingDesiredWidth = true
        defer { isApplyingDesiredWidth = false }

        let position = WorkspaceEdgeSplitLayout.position(
            for: desiredEdgeWidth,
            edge: edge,
            totalWidth: totalWidth,
            dividerThickness: dividerThickness,
            allowedWidth: allowedWidth
        )
        let availableWidth = max(0, totalWidth - dividerThickness)
        subviews[0].frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: position,
            height: totalHeight
        )
        subviews[1].frame = NSRect(
            x: bounds.minX + position + dividerThickness,
            y: bounds.minY,
            width: max(0, availableWidth - position),
            height: totalHeight
        )
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        applyDesiredWidth()
    }

    var isApplyingProgrammaticLayout: Bool {
        isApplyingDesiredWidth
    }
}

struct PersistentEdgeSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    @Binding private var width: Double
    private let edge: WorkspaceSplitEdge
    private let allowedWidth: ClosedRange<Double>
    private let accessibilityLabel: String
    private let leading: Leading
    private let trailing: Trailing

    init(
        edge: WorkspaceSplitEdge,
        width: Binding<Double>,
        allowedWidth: ClosedRange<Double>,
        accessibilityLabel: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.edge = edge
        _width = width
        self.allowedWidth = allowedWidth
        self.accessibilityLabel = accessibilityLabel
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(width: $width)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = EdgeWidthSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.edge = edge
        splitView.allowedWidth = allowedWidth
        splitView.desiredEdgeWidth = WorkspaceEdgeSplitLayout.normalized(
            width,
            allowedWidth: allowedWidth
        )
        splitView.setAccessibilityLabel(accessibilityLabel)

        let leadingRelay = PersistentHostingContent(leading)
        let trailingRelay = PersistentHostingContent(trailing)
        let leadingHost = NSHostingView(
            rootView: PersistentHostingRoot(relay: leadingRelay)
        )
        let trailingHost = NSHostingView(
            rootView: PersistentHostingRoot(relay: trailingRelay)
        )
        splitView.addArrangedSubview(leadingHost)
        splitView.addArrangedSubview(trailingHost)
        context.coordinator.install(
            splitView: splitView,
            leadingRelay: leadingRelay,
            trailingRelay: trailingRelay,
            allowedWidth: allowedWidth,
            edge: edge
        )
        splitView.delegate = context.coordinator
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        guard let edgeSplitView = splitView as? EdgeWidthSplitView else { return }
        context.coordinator.update(
            width: $width,
            leading: leading,
            trailing: trailing,
            splitView: edgeSplitView,
            allowedWidth: allowedWidth,
            edge: edge
        )
    }

    static func dismantleNSView(_ splitView: NSSplitView, coordinator: Coordinator) {
        splitView.delegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        private var width: Binding<Double>
        private weak var splitView: EdgeWidthSplitView?
        private var leadingRelay: PersistentHostingContent<Leading>?
        private var trailingRelay: PersistentHostingContent<Trailing>?
        private var acceptsResizePersistence = false
        private var resizePersistenceActivationTask: Task<Void, Never>?
        private var contentUpdateTask: Task<Void, Never>?

        init(width: Binding<Double>) {
            self.width = width
        }

        fileprivate func install(
            splitView: EdgeWidthSplitView,
            leadingRelay: PersistentHostingContent<Leading>,
            trailingRelay: PersistentHostingContent<Trailing>,
            allowedWidth: ClosedRange<Double>,
            edge: WorkspaceSplitEdge
        ) {
            self.splitView = splitView
            self.leadingRelay = leadingRelay
            self.trailingRelay = trailingRelay
            configure(splitView, allowedWidth: allowedWidth, edge: edge)
            applyStoredWidth(to: splitView)
            resizePersistenceActivationTask?.cancel()
            resizePersistenceActivationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.acceptsResizePersistence = true
                self?.resizePersistenceActivationTask = nil
            }
        }

        fileprivate func update(
            width: Binding<Double>,
            leading: Leading,
            trailing: Trailing,
            splitView: EdgeWidthSplitView,
            allowedWidth: ClosedRange<Double>,
            edge: WorkspaceSplitEdge
        ) {
            self.width = width
            contentUpdateTask?.cancel()
            contentUpdateTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.leadingRelay?.content = leading
                self.trailingRelay?.content = trailing
                self.contentUpdateTask = nil
            }
            configure(splitView, allowedWidth: allowedWidth, edge: edge)
            applyStoredWidth(to: splitView)
        }

        func detach() {
            resizePersistenceActivationTask?.cancel()
            resizePersistenceActivationTask = nil
            contentUpdateTask?.cancel()
            contentUpdateTask = nil
            acceptsResizePersistence = false
            splitView = nil
            leadingRelay = nil
            trailingRelay = nil
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == 0,
                  let splitView = splitView as? EdgeWidthSplitView
            else { return proposedPosition }
            let width = WorkspaceEdgeSplitLayout.edgeWidth(
                for: proposedPosition,
                edge: splitView.edge,
                totalWidth: splitView.bounds.width,
                dividerThickness: splitView.dividerThickness,
                allowedWidth: splitView.allowedWidth
            )
            return WorkspaceEdgeSplitLayout.position(
                for: width,
                edge: splitView.edge,
                totalWidth: splitView.bounds.width,
                dividerThickness: splitView.dividerThickness,
                allowedWidth: splitView.allowedWidth
            )
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? EdgeWidthSplitView,
                  acceptsResizePersistence,
                  !splitView.isApplyingProgrammaticLayout,
                  splitView.subviews.count == 2
            else { return }
            let position = splitView.subviews[0].frame.width
            let newWidth = WorkspaceEdgeSplitLayout.edgeWidth(
                for: position,
                edge: splitView.edge,
                totalWidth: splitView.bounds.width,
                dividerThickness: splitView.dividerThickness,
                allowedWidth: splitView.allowedWidth
            )
            splitView.desiredEdgeWidth = newWidth
            if abs(width.wrappedValue - newWidth) > 0.5 {
                width.wrappedValue = newWidth
            }
        }

        private func configure(
            _ splitView: EdgeWidthSplitView,
            allowedWidth: ClosedRange<Double>,
            edge: WorkspaceSplitEdge
        ) {
            splitView.allowedWidth = allowedWidth
            splitView.edge = edge
        }

        private func applyStoredWidth(to splitView: EdgeWidthSplitView) {
            splitView.desiredEdgeWidth = WorkspaceEdgeSplitLayout.normalized(
                width.wrappedValue,
                allowedWidth: splitView.allowedWidth
            )
            splitView.applyDesiredWidth()
        }
    }
}

@MainActor
private final class FractionSplitView: NSSplitView {
    var desiredFraction = EditorSplitLayout.defaultFraction
    private var isApplyingDesiredFraction = false

    func applyDesiredFraction() {
        let totalWidth = max(0, bounds.width)
        let totalHeight = max(0, bounds.height)
        guard subviews.count == 2, totalWidth > dividerThickness else { return }
        isApplyingDesiredFraction = true
        defer { isApplyingDesiredFraction = false }

        let position = EditorSplitLayout.position(
            for: desiredFraction,
            totalWidth: totalWidth,
            dividerThickness: dividerThickness
        )
        let availableWidth = max(0, totalWidth - dividerThickness)
        subviews[0].frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: position,
            height: totalHeight
        )
        subviews[1].frame = NSRect(
            x: bounds.minX + position + dividerThickness,
            y: bounds.minY,
            width: max(0, availableWidth - position),
            height: totalHeight
        )
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        applyDesiredFraction()
    }

    var isApplyingProgrammaticLayout: Bool {
        isApplyingDesiredFraction
    }
}

struct PersistentHorizontalSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    @Binding private var fraction: Double
    private let leading: Leading
    private let trailing: Trailing

    init(
        fraction: Binding<Double>,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        _fraction = fraction
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fraction: $fraction)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = FractionSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.desiredFraction = EditorSplitLayout.normalized(fraction)
        splitView.setAccessibilityLabel("源码与预览分栏")

        let leadingRelay = PersistentHostingContent(leading)
        let trailingRelay = PersistentHostingContent(trailing)
        let leadingHost = NSHostingView(
            rootView: PersistentHostingRoot(relay: leadingRelay)
        )
        let trailingHost = NSHostingView(
            rootView: PersistentHostingRoot(relay: trailingRelay)
        )
        splitView.addArrangedSubview(leadingHost)
        splitView.addArrangedSubview(trailingHost)
        context.coordinator.install(
            splitView: splitView,
            leadingRelay: leadingRelay,
            trailingRelay: trailingRelay
        )
        // Installing arranged subviews emits transient resize callbacks while
        // AppKit still holds its 50/50 bootstrap geometry. Attach the delegate
        // only after the configured fraction has been applied so that bootstrap
        // geometry can never overwrite a new scene's first-frame value.
        splitView.delegate = context.coordinator
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        guard let fractionSplitView = splitView as? FractionSplitView else { return }
        context.coordinator.update(
            fraction: $fraction,
            leading: leading,
            trailing: trailing,
            splitView: fractionSplitView
        )
    }

    static func dismantleNSView(_ splitView: NSSplitView, coordinator: Coordinator) {
        splitView.delegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        private var fraction: Binding<Double>
        private weak var splitView: FractionSplitView?
        private var leadingRelay: PersistentHostingContent<Leading>?
        private var trailingRelay: PersistentHostingContent<Trailing>?
        private var acceptsResizePersistence = false
        private var resizePersistenceActivationTask: Task<Void, Never>?
        private var contentUpdateTask: Task<Void, Never>?

        init(fraction: Binding<Double>) {
            self.fraction = fraction
        }

        fileprivate func install(
            splitView: FractionSplitView,
            leadingRelay: PersistentHostingContent<Leading>,
            trailingRelay: PersistentHostingContent<Trailing>
        ) {
            self.splitView = splitView
            self.leadingRelay = leadingRelay
            self.trailingRelay = trailingRelay
            applyStoredFraction(to: splitView)
            resizePersistenceActivationTask?.cancel()
            resizePersistenceActivationTask = Task { @MainActor [weak self] in
                // Initial SwiftUI/AppKit mounting can emit several synthetic
                // resize callbacks. No pointer interaction is possible before
                // the next actor turn, so persistence can safely begin there.
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.acceptsResizePersistence = true
                self?.resizePersistenceActivationTask = nil
            }
        }

        fileprivate func update(
            fraction: Binding<Double>,
            leading: Leading,
            trailing: Trailing,
            splitView: FractionSplitView
        ) {
            self.fraction = fraction
            contentUpdateTask?.cancel()
            contentUpdateTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.leadingRelay?.content = leading
                self.trailingRelay?.content = trailing
                self.contentUpdateTask = nil
            }
            applyStoredFraction(to: splitView)
        }

        func detach() {
            resizePersistenceActivationTask?.cancel()
            resizePersistenceActivationTask = nil
            contentUpdateTask?.cancel()
            contentUpdateTask = nil
            acceptsResizePersistence = false
            splitView = nil
            leadingRelay = nil
            trailingRelay = nil
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == 0 else { return proposedPosition }
            let minimum = EditorSplitLayout.position(
                for: EditorSplitLayout.allowedFraction.lowerBound,
                totalWidth: splitView.bounds.width,
                dividerThickness: splitView.dividerThickness
            )
            let maximum = EditorSplitLayout.position(
                for: EditorSplitLayout.allowedFraction.upperBound,
                totalWidth: splitView.bounds.width,
                dividerThickness: splitView.dividerThickness
            )
            return min(max(proposedPosition, minimum), maximum)
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? FractionSplitView,
                  acceptsResizePersistence,
                  !splitView.isApplyingProgrammaticLayout,
                  let firstPane = splitView.subviews.first
            else {
                return
            }
            let newFraction = EditorSplitLayout.fraction(
                for: firstPane.frame.width,
                totalWidth: splitView.bounds.width,
                dividerThickness: splitView.dividerThickness
            )
            splitView.desiredFraction = newFraction
            if abs(fraction.wrappedValue - newFraction) > 0.000_1 {
                fraction.wrappedValue = newFraction
            }
        }

        private func applyStoredFraction(to splitView: FractionSplitView) {
            let normalized = EditorSplitLayout.normalized(fraction.wrappedValue)
            splitView.desiredFraction = normalized
            splitView.applyDesiredFraction()
        }
    }
}
