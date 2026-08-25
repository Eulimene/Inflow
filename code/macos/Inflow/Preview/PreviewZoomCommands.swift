import SwiftUI

@MainActor
final class PreviewZoomCommandActions {
    static let step = 0.1

    let zoom: Double
    let supportedRange: ClosedRange<Double>
    let setZoom: (Double) -> Void

    init(
        zoom: Double,
        supportedRange: ClosedRange<Double> = AppPreferences.Limits.previewZoom,
        setZoom: @escaping (Double) -> Void
    ) {
        self.zoom = min(max(zoom, supportedRange.lowerBound), supportedRange.upperBound)
        self.supportedRange = supportedRange
        self.setZoom = setZoom
    }

    var canZoomIn: Bool { zoom < supportedRange.upperBound }
    var canZoomOut: Bool { zoom > supportedRange.lowerBound }

    func zoomIn() {
        guard canZoomIn else { return }
        setZoom(min(supportedRange.upperBound, roundedStep(zoom + Self.step)))
    }

    func zoomOut() {
        guard canZoomOut else { return }
        setZoom(max(supportedRange.lowerBound, roundedStep(zoom - Self.step)))
    }

    func reset() {
        setZoom(PreviewAppearanceConfiguration.default.zoom)
    }

    private func roundedStep(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

private struct PreviewZoomActionsFocusedKey: FocusedValueKey {
    typealias Value = PreviewZoomCommandActions
}

extension FocusedValues {
    var previewZoomActions: PreviewZoomCommandActions? {
        get { self[PreviewZoomActionsFocusedKey.self] }
        set { self[PreviewZoomActionsFocusedKey.self] = newValue }
    }
}

struct PreviewZoomCommands: Commands {
    @FocusedValue(\.previewZoomActions) private var actions

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("放大") { actions?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions?.canZoomIn != true)
            Button("缩小") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions?.canZoomOut != true)
            Button("实际大小") { actions?.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions == nil)
            Divider()
        }
    }
}
