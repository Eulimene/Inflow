import AppKit
import SwiftUI

struct DocumentFindCommandActions {
    let hasQuery: Bool
    let canReplace: Bool
    let showFind: () -> Void
    let showReplace: () -> Void
    let next: () -> Void
    let previous: () -> Void
    let useSelection: (String) -> Void
}

struct DocumentFindCommands: Commands {
    var body: some Commands { TextEditingCommands() }
}

/// Connect native Find menu actions to the document's revision-aware search.
/// Each document window owns its responder; sheets keep their own responder chain.
struct DocumentFindCommandBridge: NSViewRepresentable {
    var actions: DocumentFindCommandActions?

    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ view: BridgeView, context: Context) {
        view.responder.actions = actions
    }
    static func dismantleNSView(_ view: BridgeView, coordinator: ()) {
        view.responder.actions = nil
        view.detach()
    }

    final class BridgeView: NSView {
        let responder = DocumentFindResponder()
        private weak var installedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            installedWindow = window
            responder.window = window
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
        }

        func detach() {
            var previous: NSResponder? = installedWindow
            while let current = previous {
                if current.nextResponder === responder {
                    current.nextResponder = responder.nextResponder
                    break
                }
                previous = current.nextResponder
            }
            installedWindow = nil
            responder.window = nil
            responder.nextResponder = nil
        }
    }
}

@MainActor
final class DocumentFindResponder: NSResponder, NSUserInterfaceValidations {
    weak var window: NSWindow?
    var actions: DocumentFindCommandActions?

    static func active(in window: NSWindow?) -> DocumentFindResponder? {
        var current = window?.nextResponder
        while let responder = current {
            if let find = responder as? DocumentFindResponder, find.actions != nil { return find }
            current = responder.nextResponder
        }
        return nil
    }

    private var selectedText: String {
        guard let editor = window?.firstResponder as? NSTextView else { return "" }
        let source = editor.string as NSString
        let range = editor.selectedRange()
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return "" }
        return source.substring(with: range)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performFindPanelAction(_:)), let actions else { return false }
        switch NSTextFinder.Action(rawValue: item.tag) {
        case .showFindInterface: return true
        case .showReplaceInterface: return actions.canReplace
        case .nextMatch, .previousMatch: return actions.hasQuery
        case .setSearchString: return !selectedText.isEmpty
        default: return false
        }
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, validateUserInterfaceItem(item), let actions else { return }
        switch NSTextFinder.Action(rawValue: item.tag) {
        case .showFindInterface: actions.showFind()
        case .showReplaceInterface: actions.showReplace()
        case .nextMatch: actions.next()
        case .previousMatch: actions.previous()
        case .setSearchString: actions.useSelection(selectedText)
        default: break
        }
    }
}

/// NSTextView already implements Find, so forward explicitly before its built-in
/// finder takes over. Copy/paste, spelling and all other actions remain native.
class DocumentFindTextView: NSTextView {
    override func performFindPanelAction(_ sender: Any?) {
        if let responder = DocumentFindResponder.active(in: window) {
            responder.performFindPanelAction(sender)
        } else {
            super.performFindPanelAction(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)),
           let responder = DocumentFindResponder.active(in: window) {
            return responder.validateUserInterfaceItem(item)
        }
        return super.validateUserInterfaceItem(item)
    }
}
