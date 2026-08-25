import AppKit
import XCTest
@testable import Inflow

final class MarkdownInsertionTests: XCTestCase {
    func testLinkPlanWrapsUnicodeSelectionAndUpdatesExistingLink() throws {
        let source = "Read 文档👩‍💻 now"
        let selected = (source as NSString).range(of: "文档👩‍💻")
        let added = try MarkdownFormatter.linkPlan(
            source: source,
            selectedUTF16Range: selected,
            destination: "https://example.com/guide"
        )
        XCTAssertEqual(
            added.resultingSource,
            "Read [文档👩‍💻](<https://example.com/guide>) now"
        )
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: added.resultingSource).contains(
            "href=\"https://example.com/guide\""
        ))

        let updated = try MarkdownFormatter.linkPlan(
            source: added.resultingSource,
            selectedUTF16Range: (added.resultingSource as NSString).range(of: "文档👩‍💻"),
            destination: "guide/local.md"
        )
        XCTAssertEqual(
            updated.resultingSource,
            "Read [文档👩‍💻](<guide/local.md>) now"
        )
    }

    func testEmptyLinkPlanSelectsEditableLabelAndRejectsUnsafeDestination() throws {
        let plan = try MarkdownFormatter.linkPlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: "#section"
        )
        XCTAssertEqual(plan.resultingSource, "[链接文字](<#section>)")
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: plan.selectionUTF8Range,
                in: plan.resultingSource
            )
        )
        XCTAssertEqual((plan.resultingSource as NSString).substring(with: target.revealRange), "链接文字")

        XCTAssertThrowsError(
            try MarkdownFormatter.linkPlan(
                source: "text",
                selectedUTF16Range: NSRange(location: 0, length: 4),
                destination: "https://example.com/<unsafe>"
            )
        ) { error in
            guard case MarkdownFormatError.invalidDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testImagePlanCreatesStandardMarkdownAndEditableAlternative() throws {
        let source = "Before 图片👩‍💻 after"
        let selection = (source as NSString).range(of: "图片👩‍💻")
        let selected = try MarkdownFormatter.imagePlan(
            source: source,
            selectedUTF16Range: selection,
            destination: "assets/cover%20image.png",
            defaultAlternative: "cover image"
        )
        XCTAssertEqual(
            selected.resultingSource,
            "Before ![图片👩‍💻](<assets/cover%20image.png>) after"
        )
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: selected.resultingSource).contains(
            "class=\"inflow-image-slot\""
        ))

        let empty = try MarkdownFormatter.imagePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: "assets/photo.jpg",
            defaultAlternative: "photo"
        )
        XCTAssertEqual(empty.resultingSource, "![photo](<assets/photo.jpg>)")
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: empty.selectionUTF8Range,
                in: empty.resultingSource
            )
        )
        XCTAssertEqual((empty.resultingSource as NSString).substring(with: target.revealRange), "photo")
    }

    func testImagePlanRejectsPartialExistingImageAndUnsafeDestination() {
        let existing = "![old](<assets/old.png>)"
        XCTAssertThrowsError(
            try MarkdownFormatter.imagePlan(
                source: existing,
                selectedUTF16Range: (existing as NSString).range(of: "old"),
                destination: "assets/new.png",
                defaultAlternative: "new"
            )
        )
        XCTAssertThrowsError(
            try MarkdownFormatter.imagePlan(
                source: "",
                selectedUTF16Range: NSRange(location: 0, length: 0),
                destination: "assets/<unsafe>.png",
                defaultAlternative: "image"
            )
        )
    }

    func testImageWorkerCopiesValidatedAssetAndIncrementsCollision() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("cover image.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let missingDestination = try await worker.destinationSnapshot(
            documentDirectory: documentDirectory,
            originalFilename: sourceURL.lastPathComponent
        )
        let first = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .failIfExists,
            expectedDestination: missingDestination
        )
        XCTAssertEqual(first.relativeMarkdownPath, "assets/cover%20image.png")
        XCTAssertEqual(try Data(contentsOf: first.destinationURL), image.data)

        await XCTAssertThrowsErrorAsync {
            let existingDestination = try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
            _ = try await worker.importAsset(
                image: image,
                originalFilename: sourceURL.lastPathComponent,
                documentDirectory: documentDirectory,
                collisionResolution: .failIfExists,
                expectedDestination: existingDestination
            )
        }

        let second = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .incrementName,
            expectedDestination: try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
        )
        XCTAssertEqual(second.relativeMarkdownPath, "assets/cover%20image-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.destinationURL.path))
        try second.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.destinationURL.path))

        let previous = Data("previous asset".utf8)
        try previous.write(to: first.destinationURL, options: .atomic)
        let replaceDestination = try await worker.destinationSnapshot(
            documentDirectory: documentDirectory,
            originalFilename: sourceURL.lastPathComponent
        )
        let replaced = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .replace,
            expectedDestination: replaceDestination
        )
        XCTAssertEqual(replaced.previousData, previous)
        XCTAssertEqual(try Data(contentsOf: replaced.destinationURL), image.data)
        try replaced.rollback()
        XCTAssertEqual(try Data(contentsOf: replaced.destinationURL), previous)
    }

    func testImageWorkerRefusesReplaceWhenDestinationChangesAfterConfirmation() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let assetsDirectory = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)
        let destinationURL = assetsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try Data("confirmed bytes".utf8).write(to: destinationURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let confirmedDestination = try await worker.destinationSnapshot(
            documentDirectory: documentDirectory,
            originalFilename: sourceURL.lastPathComponent
        )
        let externalChange = Data("external change after confirmation".utf8)
        try externalChange.write(to: destinationURL, options: .atomic)

        await XCTAssertThrowsErrorAsync {
            _ = try await worker.importAsset(
                image: image,
                originalFilename: sourceURL.lastPathComponent,
                documentDirectory: documentDirectory,
                collisionResolution: .replace,
                expectedDestination: confirmedDestination
            )
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), externalChange)
    }

    func testImageWorkerRefusesSymbolicAssetsDirectory() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: documentDirectory.appendingPathComponent("assets", isDirectory: true),
            withDestinationURL: outsideDirectory
        )
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let snapshot = try await worker.destinationSnapshot(
            documentDirectory: documentDirectory,
            originalFilename: sourceURL.lastPathComponent
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await worker.importAsset(
                image: image,
                originalFilename: sourceURL.lastPathComponent,
                documentDirectory: documentDirectory,
                collisionResolution: .failIfExists,
                expectedDestination: snapshot
            )
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path).isEmpty)
    }

    @MainActor
    func testImageInsertionUndoAndRedoOwnBothMarkdownAndCreatedResource() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let asset = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .failIfExists,
            expectedDestination: try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
        )
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = "Before "
        session.textView.setSelectedRange(NSRange(location: 7, length: 0))
        let plan = try MarkdownFormatter.imagePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange(),
            destination: asset.relativeMarkdownPath,
            defaultAlternative: "photo"
        )
        var resourceError: String?
        XCTAssertTrue(session.applyMarkdownImage(
            plan,
            asset: asset,
            actionName: "插入图片",
            onResourceError: { resourceError = $0 }
        ))
        XCTAssertEqual(session.textView.string, "Before ![photo](<assets/photo.png>)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.destinationURL.path))

        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Before ")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.destinationURL.path))
        XCTAssertNil(resourceError)

        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Before ![photo](<assets/photo.png>)")
        XCTAssertEqual(try Data(contentsOf: asset.destinationURL), image.data)
        XCTAssertNil(resourceError)
    }

    @MainActor
    func testImageUndoNeverOverwritesExternallyChangedResource() async throws {
        let root = try temporaryImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try testPNGData().write(to: sourceURL)

        let worker = ImageAssetWorker()
        let image = try await worker.loadSource(at: sourceURL)
        let asset = try await worker.importAsset(
            image: image,
            originalFilename: sourceURL.lastPathComponent,
            documentDirectory: documentDirectory,
            collisionResolution: .failIfExists,
            expectedDestination: try await worker.destinationSnapshot(
                documentDirectory: documentDirectory,
                originalFilename: sourceURL.lastPathComponent
            )
        )
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        let plan = try MarkdownFormatter.imagePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: asset.relativeMarkdownPath,
            defaultAlternative: "photo"
        )
        var resourceError: String?
        XCTAssertTrue(session.applyMarkdownImage(
            plan,
            asset: asset,
            actionName: "插入图片",
            onResourceError: { resourceError = $0 }
        ))

        let externalChange = Data("external change".utf8)
        try externalChange.write(to: asset.destinationURL, options: .atomic)
        session.textView.undoManager?.undo()
        XCTAssertEqual(try Data(contentsOf: asset.destinationURL), externalChange)
        XCTAssertNotNil(resourceError)
    }

    func testTablePlanCreatesThreeByThreeTemplateAndEscapesSelection() throws {
        let empty = try MarkdownFormatter.tablePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            empty.resultingSource,
            "| 标题 1 | 标题 2 | 标题 3 |\n| --- | --- | --- |\n| 内容 1 | 内容 2 | 内容 3 |\n| 内容 4 | 内容 5 | 内容 6 |"
        )
        let header = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: empty.selectionUTF8Range,
                in: empty.resultingSource
            )
        )
        XCTAssertEqual((empty.resultingSource as NSString).substring(with: header.revealRange), "标题 1")

        let source = "before A|B\nC after"
        let selected = (source as NSString).range(of: "A|B\nC")
        let escaped = try MarkdownFormatter.tablePlan(
            source: source,
            selectedUTF16Range: selected
        )
        XCTAssertTrue(escaped.resultingSource.contains("| A\\|B<br>C | 标题 2 |"))
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: escaped.resultingSource).contains(
            "<table>"
        ))
    }

    func testTablePlanRejectsInsertionInsideExistingTable() {
        let source = "| One | Two |\n| --- | --- |\n| A | B |\n"
        XCTAssertThrowsError(
            try MarkdownFormatter.tablePlan(
                source: source,
                selectedUTF16Range: NSRange(
                    location: (source as NSString).range(of: "A").location,
                    length: 0
                )
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHorizontalRulePlanPreservesSelectionAndCreatesRealRule() throws {
        let empty = try MarkdownFormatter.horizontalRulePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(empty.resultingSource, "---\n\n")
        XCTAssertEqual(empty.selectionUTF8Range, 5..<5)
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: empty.resultingSource).contains(
            "<hr />"
        ))

        let source = "before 文字👩‍💻 after"
        let selection = (source as NSString).range(of: "文字👩‍💻")
        let plan = try MarkdownFormatter.horizontalRulePlan(
            source: source,
            selectedUTF16Range: selection
        )
        XCTAssertEqual(plan.resultingSource, "before 文字👩‍💻\n\n---\n\n after")
        XCTAssertTrue(plan.resultingSource.hasPrefix("before 文字👩‍💻"))
    }

    func testFootnotePlanCreatesUniqueReferenceAndEditableDefinition() throws {
        let empty = try MarkdownFormatter.footnotePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(empty.resultingSource, "[^note-1]\n\n[^note-1]: 脚注内容\n")
        let placeholder = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: empty.selectionUTF8Range,
                in: empty.resultingSource
            )
        )
        XCTAssertEqual(
            (empty.resultingSource as NSString).substring(with: placeholder.revealRange),
            "脚注内容"
        )
        let html = try MarkdownRenderer.htmlFragment(for: empty.resultingSource)
        XCTAssertTrue(html.contains("footnote-reference"))
        XCTAssertTrue(html.contains("footnote-definition"))

        let source = "Anchor[^note-1]\n\n[^note-1]: Existing\n"
        let selection = (source as NSString).range(of: "Anchor")
        let unique = try MarkdownFormatter.footnotePlan(
            source: source,
            selectedUTF16Range: selection
        )
        XCTAssertTrue(unique.resultingSource.hasPrefix("Anchor[^note-2][^note-1]"))
        XCTAssertTrue(unique.resultingSource.hasSuffix("[^note-2]: 脚注内容\n"))
    }

    func testMathPlanCreatesInlineAndDisplayMathML() throws {
        let source = "Euler e^{i\\pi}+1=0 end"
        let inline = try MarkdownFormatter.mathPlan(
            source: source,
            selectedUTF16Range: (source as NSString).range(of: "e^{i\\pi}+1=0")
        )
        XCTAssertEqual(inline.resultingSource, "Euler $e^{i\\pi}+1=0$ end")
        let inlineHTML = try MarkdownRenderer.htmlFragment(for: inline.resultingSource)
        XCTAssertTrue(inlineHTML.contains("<math"))
        XCTAssertTrue(inlineHTML.contains("display=\"inline\""))
        XCTAssertTrue(inlineHTML.contains("<msup>"))

        let display = try MarkdownFormatter.mathPlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(display.resultingSource, "$$\n公式内容\n$$")
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: display.selectionUTF8Range,
                in: display.resultingSource
            )
        )
        XCTAssertEqual((display.resultingSource as NSString).substring(with: target.revealRange), "公式内容")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: display.resultingSource).contains(
            "display=\"block\""
        ))
    }

    func testMermaidPlanCreatesEditableOfflineDiagram() throws {
        let template = try MarkdownFormatter.mermaidPlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            template.resultingSource,
            "```mermaid\nflowchart TD\n    A[开始] --> B[结束]\n```"
        )
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: template.selectionUTF8Range,
                in: template.resultingSource
            )
        )
        XCTAssertEqual(
            (template.resultingSource as NSString).substring(with: target.revealRange),
            "flowchart TD\n    A[开始] --> B[结束]"
        )
        let html = try MarkdownRenderer.htmlFragment(for: template.resultingSource)
        XCTAssertTrue(html.contains("class=\"mermaid-diagram\""))
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertFalse(html.contains("<script"))
    }

    @MainActor
    func testInsertionPlansApplyAsOneUndoUnit() throws {
        let source = "Read docs"
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = source
        session.textView.setSelectedRange((source as NSString).range(of: "docs"))
        let plan = try MarkdownFormatter.linkPlan(
            source: source,
            selectedUTF16Range: session.textView.selectedRange(),
            destination: "https://example.com"
        )
        XCTAssertTrue(session.applyMarkdownFormat(plan, actionName: "插入链接"))
        XCTAssertEqual(session.textView.string, "Read [docs](<https://example.com>)")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, source)
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Read [docs](<https://example.com>)")

        session.textView.string = "Header"
        session.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let table = try MarkdownFormatter.tablePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(table, actionName: "插入表格"))
        XCTAssertTrue(session.textView.string.hasPrefix("| Header | 标题 2 |"))
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Header")
        session.textView.undoManager?.redo()
        XCTAssertTrue(session.textView.string.hasPrefix("| Header | 标题 2 |"))

        session.textView.string = "Before"
        session.textView.setSelectedRange(NSRange(location: 6, length: 0))
        let horizontalRule = try MarkdownFormatter.horizontalRulePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(horizontalRule, actionName: "插入分隔线"))
        XCTAssertEqual(session.textView.string, "Before\n\n---\n\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Before")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Before\n\n---\n\n")

        session.textView.string = "Anchor"
        session.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let footnote = try MarkdownFormatter.footnotePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(footnote, actionName: "插入脚注"))
        XCTAssertEqual(session.textView.string, "Anchor[^note-1]\n\n[^note-1]: 脚注内容\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Anchor")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Anchor[^note-1]\n\n[^note-1]: 脚注内容\n")

        session.textView.string = "x^2"
        session.textView.setSelectedRange(NSRange(location: 0, length: 3))
        let formula = try MarkdownFormatter.mathPlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(formula, actionName: "插入公式"))
        XCTAssertEqual(session.textView.string, "$x^2$")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "x^2")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "$x^2$")

        session.textView.string = ""
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let diagram = try MarkdownFormatter.mermaidPlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(diagram, actionName: "插入图表"))
        XCTAssertTrue(session.textView.string.hasPrefix("```mermaid\nflowchart TD"))
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "")
        session.textView.undoManager?.redo()
        XCTAssertTrue(session.textView.string.hasPrefix("```mermaid\nflowchart TD"))
    }

    @MainActor
    func testInsertActionsAreSceneScopedAndMenuHasCommandK() throws {
        var firstCount = 0
        var firstImageCount = 0
        var secondCount = 0
        var firstTableCount = 0
        var firstRuleCount = 0
        var firstFootnoteCount = 0
        var firstFormulaCount = 0
        var firstDiagramCount = 0
        let first = MarkdownInsertCommandActions(
            canInsert: true,
            insertLink: { firstCount += 1 },
            insertImage: { firstImageCount += 1 },
            insertTable: { firstTableCount += 1 },
            insertHorizontalRule: { firstRuleCount += 1 },
            insertFootnote: { firstFootnoteCount += 1 },
            insertFormula: { firstFormulaCount += 1 },
            insertDiagram: { firstDiagramCount += 1 }
        )
        let second = MarkdownInsertCommandActions(
            canInsert: false,
            insertLink: { secondCount += 1 },
            insertImage: { secondCount += 1 },
            insertTable: { secondCount += 1 },
            insertHorizontalRule: { secondCount += 1 },
            insertFootnote: { secondCount += 1 },
            insertFormula: { secondCount += 1 },
            insertDiagram: { secondCount += 1 }
        )
        first.insertLink()
        first.insertImage()
        first.insertTable()
        first.insertHorizontalRule()
        first.insertFootnote()
        first.insertFormula()
        first.insertDiagram()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(firstImageCount, 1)
        XCTAssertEqual(firstTableCount, 1)
        XCTAssertEqual(firstRuleCount, 1)
        XCTAssertEqual(firstFootnoteCount, 1)
        XCTAssertEqual(firstFormulaCount, 1)
        XCTAssertEqual(firstDiagramCount, 1)
        XCTAssertEqual(secondCount, 0)
        XCTAssertFalse(second.canInsert)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let matches = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "链接…"
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.keyEquivalent, "k")
        XCTAssertEqual(
            matches.first?.keyEquivalentModifierMask.intersection([.command, .option, .shift]),
            .command
        )

        let imageItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "图片…"
        }
        XCTAssertEqual(imageItems.count, 1)
        XCTAssertEqual(imageItems.first?.keyEquivalent, "")

        let tableItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "表格"
        }
        XCTAssertEqual(tableItems.count, 1)
        XCTAssertEqual(tableItems.first?.keyEquivalent, "")

        let horizontalRuleItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "分隔线"
        }
        XCTAssertEqual(horizontalRuleItems.count, 1)
        XCTAssertEqual(horizontalRuleItems.first?.keyEquivalent, "")

        let footnoteItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "脚注"
        }
        XCTAssertEqual(footnoteItems.count, 1)
        XCTAssertEqual(footnoteItems.first?.keyEquivalent, "")

        let formulaItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "公式"
        }
        XCTAssertEqual(formulaItems.count, 1)
        XCTAssertEqual(formulaItems.first?.keyEquivalent, "")

        let diagramItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "图表"
        }
        XCTAssertEqual(diagramItems.count, 1)
        XCTAssertEqual(diagramItems.first?.keyEquivalent, "")
    }

    @MainActor
    func testLinkDestinationEditorKeepsInputLiteral() {
        let editor = NSTextView()
        editor.smartInsertDeleteEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticLinkDetectionEnabled = true
        editor.isAutomaticDataDetectionEnabled = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true

        LiteralLinkDestinationField.configureLiteralInput(editor)

        XCTAssertFalse(editor.smartInsertDeleteEnabled)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(editor.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(editor.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(editor.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(editor.isGrammarCheckingEnabled)
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }

    private func temporaryImageDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-image-import-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func testPNGData() throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )
        )
        let pixels = try XCTUnwrap(representation.bitmapData)
        pixels[0] = 32
        pixels[1] = 96
        pixels[2] = 220
        pixels[3] = 255
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
