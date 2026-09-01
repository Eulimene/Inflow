import SwiftUI

@MainActor
final class HTMLExportCommandActions {
    let isExportingPDF: Bool
    let canExportPDF: Bool
    let startPDF: () -> Void

    init(
        isExportingPDF: Bool,
        canExportPDF: Bool,
        startPDF: @escaping () -> Void
    ) {
        self.isExportingPDF = isExportingPDF
        self.canExportPDF = canExportPDF
        self.startPDF = startPDF
    }
}

private struct HTMLExportActionsFocusedKey: FocusedValueKey {
    typealias Value = HTMLExportCommandActions
}

extension FocusedValues {
    var htmlExportActions: HTMLExportCommandActions? {
        get { self[HTMLExportActionsFocusedKey.self] }
        set { self[HTMLExportActionsFocusedKey.self] = newValue }
    }
}

struct HTMLExportCommands: Commands {
    @FocusedValue(\.htmlExportActions) private var actions

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("导出 PDF…") {
                actions?.startPDF()
            }
            .disabled(
                actions == nil
                    || actions?.canExportPDF != true
                    || actions?.isExportingPDF == true
            )
        }
    }
}
