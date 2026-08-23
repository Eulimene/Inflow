import SwiftUI

@MainActor
final class HTMLExportCommandActions {
    let isExporting: Bool
    let start: () -> Void

    init(isExporting: Bool, start: @escaping () -> Void) {
        self.isExporting = isExporting
        self.start = start
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
            Button("导出 HTML…") {
                actions?.start()
            }
            .disabled(actions == nil || actions?.isExporting == true)
        }
    }
}
