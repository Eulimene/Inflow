import AppKit
import SwiftUI

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

@MainActor
private final class FractionSplitView: NSSplitView {
    var desiredFraction = EditorSplitLayout.defaultFraction
    private var isApplyingDesiredFraction = false

    func applyDesiredFraction() {
        guard subviews.count == 2, bounds.width > dividerThickness else { return }
        isApplyingDesiredFraction = true
        defer { isApplyingDesiredFraction = false }

        let position = EditorSplitLayout.position(
            for: desiredFraction,
            totalWidth: bounds.width,
            dividerThickness: dividerThickness
        )
        let availableWidth = max(0, bounds.width - dividerThickness)
        subviews[0].frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: position,
            height: bounds.height
        )
        subviews[1].frame = NSRect(
            x: bounds.minX + position + dividerThickness,
            y: bounds.minY,
            width: max(0, availableWidth - position),
            height: bounds.height
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
        splitView.delegate = context.coordinator
        splitView.setAccessibilityLabel("源码与预览分栏")

        let leadingHost = NSHostingView(rootView: leading)
        let trailingHost = NSHostingView(rootView: trailing)
        splitView.addArrangedSubview(leadingHost)
        splitView.addArrangedSubview(trailingHost)
        context.coordinator.install(
            splitView: splitView,
            leadingHost: leadingHost,
            trailingHost: trailingHost
        )
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
        private var leadingHost: NSHostingView<Leading>?
        private var trailingHost: NSHostingView<Trailing>?

        init(fraction: Binding<Double>) {
            self.fraction = fraction
        }

        fileprivate func install(
            splitView: FractionSplitView,
            leadingHost: NSHostingView<Leading>,
            trailingHost: NSHostingView<Trailing>
        ) {
            self.splitView = splitView
            self.leadingHost = leadingHost
            self.trailingHost = trailingHost
            applyStoredFraction(to: splitView)
        }

        fileprivate func update(
            fraction: Binding<Double>,
            leading: Leading,
            trailing: Trailing,
            splitView: FractionSplitView
        ) {
            self.fraction = fraction
            leadingHost?.rootView = leading
            trailingHost?.rootView = trailing
            applyStoredFraction(to: splitView)
        }

        func detach() {
            splitView = nil
            leadingHost = nil
            trailingHost = nil
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
