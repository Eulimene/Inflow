import AppKit
import SwiftUI
import XCTest
@testable import Inflow

final class WritingModeTests: XCTestCase {
    @MainActor
    func testFocusModeDimsOnlyOtherParagraphsWithoutChangingDocumentOrUndo() throws {
        let session = MarkdownSourceEditorSession()
        let source = "First paragraph\n\nSecond **paragraph**\n\nThird paragraph"
        session.textView.string = source
        let secondRange = (source as NSString).range(of: "Second")
        session.textView.setSelectedRange(NSRange(location: secondRange.location, length: 0))
        session.textView.insertText("Current ", replacementRange: session.textView.selectedRange())
        let edited = session.textView.string
        let selection = session.textView.selectedRange()
        let canUndo = session.textView.undoManager?.canUndo

        session.setWritingModes(focusModeEnabled: true, typewriterModeEnabled: false)

        let layoutManager = try XCTUnwrap(session.textView.layoutManager)
        XCTAssertNotNil(
            layoutManager.temporaryAttribute(
                .foregroundColor,
                atCharacterIndex: 0,
                effectiveRange: nil
            )
        )
        XCTAssertNil(
            layoutManager.temporaryAttribute(
                .foregroundColor,
                atCharacterIndex: selection.location,
                effectiveRange: nil
            )
        )
        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, edited))
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertEqual(session.textView.undoManager?.canUndo, canUndo)

        session.setWritingModes(focusModeEnabled: false, typewriterModeEnabled: false)
        XCTAssertNil(
            layoutManager.temporaryAttribute(
                .foregroundColor,
                atCharacterIndex: 0,
                effectiveRange: nil
            )
        )
        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, edited))
        XCTAssertEqual(session.textView.undoManager?.canUndo, canUndo)
    }

    @MainActor
    func testTypewriterModeCentersCaretWithoutChangingTextOrSelection() throws {
        let session = MarkdownSourceEditorSession()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let source = (1...120).map { "Line \($0)" }.joined(separator: "\n")
        session.textView.string = source
        session.applySourceAppearance(.default, force: true)
        let location = (source as NSString).range(of: "Line 100").location
        let selection = NSRange(location: location, length: 0)
        session.textView.setSelectedRange(selection)

        session.setWritingModes(focusModeEnabled: false, typewriterModeEnabled: true)

        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, source))
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertGreaterThan(session.scrollView.contentView.bounds.origin.y, 0)
        let layoutManager = try XCTUnwrap(session.textView.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyph,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        ).offsetBy(
            dx: session.textView.textContainerOrigin.x,
            dy: session.textView.textContainerOrigin.y
        )
        let visibleRect = session.scrollView.documentVisibleRect
        XCTAssertEqual(lineRect.midY, visibleRect.midY, accuracy: lineRect.height * 1.5)
    }

    @MainActor
    func testCommandActionsAreSceneScopedAndReadOnlyCanOnlyExitActiveModes() {
        var firstFocus = false
        var firstTypewriter = false
        var secondFocus = false
        let first = WritingModeCommandActions(
            isFocusModeEnabled: false,
            isTypewriterModeEnabled: false,
            canEdit: true,
            setFocusMode: { firstFocus = $0 },
            setTypewriterMode: { firstTypewriter = $0 }
        )
        let second = WritingModeCommandActions(
            isFocusModeEnabled: false,
            isTypewriterModeEnabled: false,
            canEdit: true,
            setFocusMode: { secondFocus = $0 },
            setTypewriterMode: { _ in }
        )

        first.focusModeBinding.wrappedValue = true
        first.typewriterModeBinding.wrappedValue = true
        XCTAssertTrue(firstFocus)
        XCTAssertTrue(firstTypewriter)
        XCTAssertFalse(secondFocus)
        XCTAssertFalse(second.focusModeBinding.wrappedValue)

        let readOnly = WritingModeCommandActions(
            isFocusModeEnabled: true,
            isTypewriterModeEnabled: false,
            canEdit: false,
            setFocusMode: { _ in },
            setTypewriterMode: { _ in }
        )
        XCTAssertTrue(readOnly.canToggleFocusMode)
        XCTAssertFalse(readOnly.canToggleTypewriterMode)
    }

    @MainActor
    func testAppMenuExposesWritingModesWithoutUndocumentedShortcuts() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        for title in ["专注模式", "打字机模式"] {
            let matching = items.filter { $0.title == title }
            XCTAssertEqual(matching.count, 1)
            XCTAssertEqual(try XCTUnwrap(matching.first).keyEquivalent, "")
        }
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
