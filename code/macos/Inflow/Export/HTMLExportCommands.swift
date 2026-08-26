import SwiftUI

@MainActor
final class HTMLExportCommandActions {
    let isExportingHTML: Bool
    let isExportingPDF: Bool
    let startHTML: () -> Void
    let startPDF: () -> Void

    init(
        isExportingHTML: Bool,
        isExportingPDF: Bool,
        startHTML: @escaping () -> Void,
        startPDF: @escaping () -> Void
    ) {
        self.isExportingHTML = isExportingHTML
        self.isExportingPDF = isExportingPDF
        self.startHTML = startHTML
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
            Menu("导出…") {
                Button("导出 HTML…") {
                    actions?.startHTML()
                }
                .disabled(
                    actions == nil
                        || actions?.isExportingHTML == true
                        || actions?.isExportingPDF == true
                )

                Button("导出 PDF…") {
                    actions?.startPDF()
                }
                .disabled(
                    actions == nil
                        || actions?.isExportingHTML == true
                        || actions?.isExportingPDF == true
                )
            }
            .disabled(actions == nil)
        }
    }
}
