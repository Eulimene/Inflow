import AppKit
import XCTest
@testable import Inflow

final class RenderedMarkdownEditorTests: XCTestCase {
    func testPlanCoversPersonalEditionDirectEditingStructures() {
        let source = """
        普通段落
        # H1
        ## H2
        ### H3
        #### H4
        ##### H5
        ###### H6
        > 引用内容
        - 无序项
        1. 有序项
        - [x] 已完成任务
        **粗体** *斜体* ~~删除~~ `代码` [链接文字](https://example.com/path)
        """

        let plan = RenderedMarkdownEditor.plan(for: source)

        XCTAssertTrue(plan.exactlyMatches(source))
        XCTAssertEqual(plan.sourceUTF8, Data(source.utf8))
        XCTAssertEqual(Data(plan.sourceSnapshot.utf8), Data(source.utf8))
        XCTAssertTrue(plan.localSourceBlocks.isEmpty)

        let headingLevels = plan.contentStyles.compactMap { style -> Int? in
            guard case let .heading(level) = style.kind else { return nil }
            return level
        }
        XCTAssertEqual(headingLevels, [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(hasStyle(.paragraph, text: "普通段落", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.blockQuote, text: "引用内容", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.unorderedListItem, text: "无序项", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.orderedListItem, text: "有序项", source: source, plan: plan))
        XCTAssertTrue(
            hasStyle(
                .taskListItem(isChecked: true),
                text: "已完成任务",
                source: source,
                plan: plan
            )
        )
        XCTAssertTrue(hasStyle(.strong, text: "粗体", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.emphasis, text: "斜体", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.strikethrough, text: "删除", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.inlineCode, text: "代码", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.link, text: "链接文字", source: source, plan: plan))

        XCTAssertTrue(hasMarker(.blockQuote, text: "> ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.unorderedList, text: "- ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.orderedList, text: "1. ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.taskList, text: "[x] ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.strong, text: "**", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.emphasis, text: "*", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.strikethrough, text: "~~", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.inlineCode, text: "`", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.linkDestination, text: "https://example.com/path", source: source, plan: plan))
        XCTAssertEqual(plan.links.map(\.target), ["https://example.com/path"])
    }

    func testUnicodeRangesUseExactUTF8AndNSTextViewUTF16Coordinates() throws {
        let source = "😀 前缀 [链接👩‍💻](docs/中文.md) 和 **e\u{301}**"

        let plan = RenderedMarkdownEditor.plan(for: source)
        let link = try XCTUnwrap(plan.links.first)

        XCTAssertEqual(link.textRange.utf16Range, (source as NSString).range(of: "链接👩‍💻"))
        XCTAssertEqual(link.targetRange.utf16Range, (source as NSString).range(of: "docs/中文.md"))
        XCTAssertEqual(utf8Text(link.textRange, source: source), "链接👩‍💻")
        XCTAssertEqual(utf8Text(link.targetRange, source: source), "docs/中文.md")

        let strong = try XCTUnwrap(plan.contentStyles.first { $0.kind == .strong })
        XCTAssertEqual(strong.sourceRange.utf16Range, (source as NSString).range(of: "e\u{301}"))
        XCTAssertEqual(utf8Text(strong.sourceRange, source: source), "e\u{301}")

        let utf16Length = (source as NSString).length
        for range in allRanges(in: plan) {
            XCTAssertGreaterThanOrEqual(range.utf16Range.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(range.utf16Range), utf16Length)
            XCTAssertEqual(
                utf8Text(range, source: source),
                (source as NSString).substring(with: range.utf16Range)
            )
        }
    }

    func testComplexStructuresBecomeNonoverlappingLocalSourceBlocks() {
        let source = """
        安全段落

        | A | B |
        | - | - |
        | 1 | 2 |

        ```swift
        print("code")
        ```

        ```mermaid
        flowchart LR
        A --> B
        ```

        ![alt](image.png)

        <div onclick="unsafe()">raw</div>

        > - 嵌套 **内容**
        """

        let plan = RenderedMarkdownEditor.plan(for: source)
        let reasons = Set(plan.localSourceBlocks.flatMap(\.reasons))

        XCTAssertTrue(reasons.contains(.table))
        XCTAssertTrue(reasons.contains(.fencedCode))
        XCTAssertTrue(reasons.contains(.mermaid))
        XCTAssertTrue(reasons.contains(.rawHTML))
        XCTAssertTrue(reasons.contains(.complexOrAmbiguous))
        XCTAssertEqual(plan.images.map(\.target), ["image.png"])
        XCTAssertTrue(hasStyle(.paragraph, text: "安全段落", source: source, plan: plan))
        XCTAssertTrue(plan.exactlyMatches(source))

        for (index, block) in plan.localSourceBlocks.enumerated() {
            XCTAssertFalse(utf8Text(block.sourceRange, source: source).isEmpty)
            if index > 0 {
                XCTAssertLessThanOrEqual(
                    plan.localSourceBlocks[index - 1].sourceRange.utf8Range.upperBound,
                    block.sourceRange.utf8Range.lowerBound
                )
            }
            XCTAssertFalse(plan.markers.contains {
                rangesOverlap($0.sourceRange.utf8Range, block.sourceRange.utf8Range)
            })
            XCTAssertFalse(plan.contentStyles.contains {
                rangesOverlap($0.sourceRange.utf8Range, block.sourceRange.utf8Range)
            })
            XCTAssertFalse(plan.links.contains {
                rangesOverlap($0.sourceRange.utf8Range, block.sourceRange.utf8Range)
            })
            XCTAssertFalse(plan.images.contains {
                rangesOverlap($0.sourceRange.utf8Range, block.sourceRange.utf8Range)
            })
        }
    }

    func testPlanRendersLocalAndRemoteImagesWithoutChangingSource() throws {
        let source = "![本地图](assets/封面.png)\n\n![remote](https://example.com/a.png)"

        let plan = RenderedMarkdownEditor.plan(for: source)

        XCTAssertTrue(plan.localSourceBlocks.isEmpty)
        XCTAssertEqual(plan.images.count, 2)
        XCTAssertEqual(plan.images.map(\.alternative), ["本地图", "remote"])
        XCTAssertEqual(
            plan.images.map(\.target),
            ["assets/封面.png", "https://example.com/a.png"]
        )
        XCTAssertEqual(
            utf8Text(try XCTUnwrap(plan.images.first).sourceRange, source: source),
            "![本地图](assets/封面.png)"
        )
        XCTAssertEqual(Data(plan.sourceSnapshot.utf8), Data(source.utf8))
    }

    func testImageTargetResolvesRelativeAbsoluteFileAndRemotePaths() throws {
        let directory = URL(fileURLWithPath: "/tmp/inflow image root", isDirectory: true)
        XCTAssertEqual(
            RenderedMarkdownImageTarget.resolve(
                "assets/cover%20one.png",
                documentDirectory: directory
            ),
            .local(directory.appendingPathComponent("assets/cover one.png").standardizedFileURL)
        )
        XCTAssertEqual(
            RenderedMarkdownImageTarget.resolve(
                "file:///tmp/cover%20two.jpg",
                documentDirectory: nil
            ),
            .local(URL(fileURLWithPath: "/tmp/cover two.jpg"))
        )
        XCTAssertEqual(
            RenderedMarkdownImageTarget.resolve(
                "https://example.com/cover.png",
                documentDirectory: nil
            ),
            .remote(try XCTUnwrap(URL(string: "https://example.com/cover.png")))
        )
        XCTAssertNil(
            RenderedMarkdownImageTarget.resolve(
                "https://user:secret@example.com/private.png",
                documentDirectory: nil
            )
        )
        XCTAssertNil(
            RenderedMarkdownImageTarget.resolve(
                "javascript:alert(1)",
                documentDirectory: directory
            )
        )
    }

    func testNestedInlineSyntaxRendersWhileMalformedSyntaxFallsBackLocally() {
        let source = """
        ***nested***

        [broken](unterminated
        """

        let plan = RenderedMarkdownEditor.plan(for: source)
        XCTAssertEqual(plan.localSourceBlocks.count, 1)
        XCTAssertTrue(plan.localSourceBlocks[0].reasons.contains(.complexOrAmbiguous))
        XCTAssertEqual(
            utf8Text(plan.localSourceBlocks[0].sourceRange, source: source),
            "[broken](unterminated"
        )
        XCTAssertTrue(hasStyle(.strong, text: "nested", source: source, plan: plan))
        XCTAssertTrue(
            plan.contentStyles.contains { style in
                style.kind == .emphasis
                    && utf8Text(style.sourceRange, source: source).contains("nested")
            }
        )
        XCTAssertTrue(plan.links.isEmpty)
        XCTAssertEqual(Data(plan.sourceSnapshot.utf8), Data(source.utf8))
    }

    func testNormalClickResolvesOnlyCurrentVisibleLinkText() throws {
        let source = "前缀 [链接](<https://example.com/a>) 和 <https://openai.com> 后缀"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let link = try XCTUnwrap(plan.links.first)
        let autolink = try XCTUnwrap(plan.links.last)
        let textLocation = link.textRange.utf16Range.location
        let targetLocation = link.targetRange.utf16Range.location

        XCTAssertEqual(
            RenderedMarkdownEditor.clickTarget(
                atUTF16Location: textLocation,
                currentSource: source,
                plan: plan
            ),
            link
        )
        XCTAssertNil(
            RenderedMarkdownEditor.clickTarget(
                atUTF16Location: targetLocation,
                currentSource: source,
                plan: plan
            )
        )
        XCTAssertEqual(link.target, "https://example.com/a")
        XCTAssertEqual(utf8Text(link.targetRange, source: source), "https://example.com/a")
        XCTAssertEqual(autolink.target, "https://openai.com")
        XCTAssertEqual(autolink.textRange, autolink.targetRange)
        XCTAssertEqual(
            RenderedMarkdownEditor.clickTarget(
                atUTF16Location: autolink.textRange.utf16Range.location,
                currentSource: source,
                plan: plan
            ),
            autolink
        )

        let precomposed = "[é](https://example.com)"
        let canonicallyEquivalentButByteStale = "[e\u{301}](https://example.com)"
        XCTAssertEqual(precomposed, canonicallyEquivalentButByteStale)
        let stalePlan = RenderedMarkdownEditor.plan(for: precomposed)
        let staleLink = try XCTUnwrap(stalePlan.links.first)
        XCTAssertFalse(stalePlan.exactlyMatches(canonicallyEquivalentButByteStale))
        XCTAssertNil(
            RenderedMarkdownEditor.clickTarget(
                atUTF16Location: staleLink.textRange.utf16Range.location,
                currentSource: canonicallyEquivalentButByteStale,
                plan: stalePlan
            )
        )
    }

    @MainActor
    func testRenderedSessionActivatesLinkOnNormalClick() throws {
        let source = "Read [the guide](guide.md)."
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        var activatedTarget: String?
        session.setPresentation(
            .rendered,
            source: source,
            onLinkClick: { activatedTarget = $0 }
        )
        let link = try XCTUnwrap(RenderedMarkdownEditor.plan(for: source).links.first)

        XCTAssertTrue(
            session.textView.linkClickHandler?(link.textRange.utf16Range.location) == true
        )
        XCTAssertEqual(activatedTarget, "guide.md")
    }

    @MainActor
    func testRenderedSessionMountsLocalImageWithoutChangingMarkdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("cover.png")
        let imageData = try makePNG(size: NSSize(width: 64, height: 32))
        try imageData.write(to: imageURL)
        let source = "![Cover](cover.png)"
        let context = RenderedMarkdownResourceContext(
            documentDirectory: directory,
            projectRoot: nil,
            expectedProjectRootIdentity: nil,
            requiresProjectBoundary: false
        )
        let loadedData = await RenderedMarkdownImageLoader().load(
            target: "cover.png",
            context: context
        )
        XCTAssertEqual(loadedData, imageData)
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(
            .rendered,
            source: source,
            onLinkClick: nil,
            resourceContext: context
        )

        let imageRange = try XCTUnwrap(RenderedMarkdownEditor.plan(for: source).images.first)
            .sourceRange.utf16Range
        let placeholder = try XCTUnwrap(
            session.textView.renderedImage(atUTF16Location: imageRange.location)
        )
        var mountedImage: NSImage?
        for _ in 0..<50 {
            if let image = session.textView.renderedImage(
                atUTF16Location: imageRange.location
            ), image !== placeholder
            {
                mountedImage = image
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(try XCTUnwrap(mountedImage).size, NSSize(width: 64, height: 32))
        XCTAssertEqual(
            session.textView.textStorage?.attribute(
                .kern,
                at: imageRange.location,
                effectiveRange: nil
            ) as? CGFloat,
            64
        )
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
    }

    func testLinkAndImageTitlesRenderWhileMalformedDestinationsRemainLocalSource() {
        let source = """
        [label](https://example.com "title")
        ![cover](assets/cover.png "preview")
        [guide][docs]
        ![diagram][asset]

        [broken](https://example.com title)

        [docs]: guide.md
        [asset]: assets/diagram.png
        """

        let plan = RenderedMarkdownEditor.plan(for: source)

        XCTAssertEqual(plan.links.map(\.target), ["https://example.com", "guide.md"])
        XCTAssertEqual(
            plan.images.map(\.target),
            ["assets/cover.png", "assets/diagram.png"]
        )
        XCTAssertEqual(plan.localSourceBlocks.count, 1)
        XCTAssertTrue(plan.localSourceBlocks[0].reasons.contains(.complexOrAmbiguous))
        XCTAssertEqual(
            utf8Text(plan.localSourceBlocks[0].sourceRange, source: source),
            "[broken](https://example.com title)"
        )
    }

    func testMarkedTextRequestsKeepExistingPresentation() {
        let source = "**中文输入**"

        XCTAssertEqual(
            RenderedMarkdownEditor.refreshDecision(for: source, hasMarkedText: true),
            .keepCurrentPresentation
        )
        guard case let .apply(plan) = RenderedMarkdownEditor.refreshDecision(
            for: source,
            hasMarkedText: false
        ) else {
            return XCTFail("Committed text should produce a new display plan")
        }
        XCTAssertTrue(plan.exactlyMatches(source))
        XCTAssertTrue(hasStyle(.strong, text: "中文输入", source: source, plan: plan))
    }

    func testEmptySourceHasAnEmptyCharacterPreservingPlan() {
        let plan = RenderedMarkdownEditor.plan(for: "")

        XCTAssertTrue(plan.exactlyMatches(""))
        XCTAssertTrue(plan.markers.isEmpty)
        XCTAssertTrue(plan.contentStyles.isEmpty)
        XCTAssertTrue(plan.localSourceBlocks.isEmpty)
        XCTAssertTrue(plan.links.isEmpty)
    }

    @MainActor
    func testRenderedSessionReappliesPresentationAfterSourceAppearanceChanges() throws {
        let source = "# Title\n"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let titleLocation = try XCTUnwrap((source as NSString).range(of: "Title").nonEmptyLocation)
        let initialFont = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: titleLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: initialFont).contains(.boldFontMask))
        XCTAssertFalse(session.scrollView.hasVerticalRuler)

        let changedAppearance = SourceEditorAppearance(
            fontSize: 19,
            lineHeight: 1.8,
            spellingEnabled: false,
            wrapsLines: false,
            showsLineNumbers: true
        )
        session.applySourceAppearance(changedAppearance)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let reappliedFont = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: titleLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        let paragraphStyle = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .paragraphStyle,
                at: titleLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: reappliedFont).contains(.boldFontMask))
        XCTAssertEqual(reappliedFont.pointSize, 27, accuracy: 0.001)
        XCTAssertEqual(paragraphStyle.lineHeightMultiple, 1.8, accuracy: 0.001)
        XCTAssertFalse(session.scrollView.hasVerticalRuler)
        XCTAssertEqual(Data(session.textView.string.utf8), Data(source.utf8))
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
    }

    @MainActor
    func testRenderedSessionKeepsStructuralMarkdownMarkersVisible() throws {
        let source = "> quote\n- item\n1. ordered\n- [x] done\n\nparagraph **bold**"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        let inlineMarker = (source as NSString).range(of: "**bold**")
        session.textView.setSelectedRange(NSRange(location: inlineMarker.location, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        for marker in ["> ", "- ", "1. ", "[x] "] {
            let location = try XCTUnwrap((source as NSString).range(of: marker).nonEmptyLocation)
            let font = try XCTUnwrap(
                session.textView.textStorage?.attribute(
                    .font,
                    at: location,
                    effectiveRange: nil
                ) as? NSFont
            )
            XCTAssertGreaterThan(font.pointSize, 1, "\(marker) must remain visible")
        }

        let inlineMarkerFont = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: inlineMarker.location,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertLessThan(
            inlineMarkerFont.pointSize,
            1,
            "inline Markdown delimiters must stay visually collapsed while editing"
        )
    }

    @MainActor
    func testRenderedSessionComposesEveryInlineStyleWithoutShrinkingHeadingText() throws {
        let source = "# **Bold** *italic* ~~gone~~ `code` [link](https://example.com)"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let storage = try XCTUnwrap(session.textView.textStorage)
        let boldLocation = try XCTUnwrap((source as NSString).range(of: "Bold").nonEmptyLocation)
        let italicLocation = try XCTUnwrap(
            (source as NSString).range(of: "italic").nonEmptyLocation
        )
        let goneLocation = try XCTUnwrap((source as NSString).range(of: "gone").nonEmptyLocation)
        let codeLocation = try XCTUnwrap((source as NSString).range(of: "code").nonEmptyLocation)
        let linkLocation = try XCTUnwrap((source as NSString).range(of: "link").nonEmptyLocation)

        let boldFont = try XCTUnwrap(
            storage.attribute(.font, at: boldLocation, effectiveRange: nil) as? NSFont
        )
        let codeFont = try XCTUnwrap(
            storage.attribute(.font, at: codeLocation, effectiveRange: nil) as? NSFont
        )
        let linkFont = try XCTUnwrap(
            storage.attribute(.font, at: linkLocation, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(boldFont.pointSize, 27, accuracy: 0.001)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        XCTAssertEqual(codeFont.pointSize, 26, accuracy: 0.001)
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(linkFont.pointSize, 27, accuracy: 0.001)
        let obliqueness = try XCTUnwrap(
            storage.attribute(.obliqueness, at: italicLocation, effectiveRange: nil) as? NSNumber
        )
        let strikethrough = try XCTUnwrap(
            storage.attribute(.strikethroughStyle, at: goneLocation, effectiveRange: nil)
                as? NSNumber
        )
        let underline = try XCTUnwrap(
            storage.attribute(.underlineStyle, at: linkLocation, effectiveRange: nil)
                as? NSNumber
        )
        XCTAssertEqual(obliqueness.doubleValue, 0.18, accuracy: 0.001)
        XCTAssertEqual(strikethrough.intValue, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(underline.intValue, NSUnderlineStyle.single.rawValue)

        for marker in RenderedMarkdownEditor.plan(for: source).markers {
            let location = marker.sourceRange.utf16Range.location
            let markerFont = try XCTUnwrap(
                storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            )
            XCTAssertLessThan(markerFont.pointSize, 1, "\(marker.kind) should be collapsed")
            XCTAssertEqual(
                (storage.attribute(.underlineStyle, at: location, effectiveRange: nil)
                    as? NSNumber)?.intValue,
                0
            )
            XCTAssertEqual(
                (storage.attribute(.strikethroughStyle, at: location, effectiveRange: nil)
                    as? NSNumber)?.intValue,
                0
            )
        }
        XCTAssertEqual(Data(session.textView.string.utf8), Data(source.utf8))
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
    }

    @MainActor
    func testRenderedSessionRefreshesAfterTypingUndoAndRedo() async throws {
        let session = MarkdownSourceEditorSession()
        session.textView.string = "plain"
        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(.rendered, source: "plain", onLinkClick: nil)

        session.textView.insertText(
            " **bold**",
            replacementRange: session.textView.selectedRange()
        )
        await settleRenderedPresentation()
        XCTAssertEqual(session.textView.string, "plain **bold**")
        try assertStrongTextIsRendered(in: session, source: session.textView.string)

        session.textView.undoManager?.undo()
        await settleRenderedPresentation()
        XCTAssertEqual(session.textView.string, "plain")

        session.textView.undoManager?.redo()
        await settleRenderedPresentation()
        XCTAssertEqual(session.textView.string, "plain **bold**")
        try assertStrongTextIsRendered(in: session, source: session.textView.string)
    }

    @MainActor
    func testLinkClickConvertsWindowCoordinatesIntoTheTextView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        let textView = WindowAwareTextView(frame: NSRect(x: 90, y: 40, width: 300, height: 160))
        container.addSubview(textView)

        XCTAssertEqual(
            textView.localPoint(forWindowPoint: NSPoint(x: 110, y: 70)),
            NSPoint(x: 20, y: 130)
        )
    }

    private func hasMarker(
        _ kind: RenderedMarkdownMarkerKind,
        text: String,
        source: String,
        plan: RenderedMarkdownPlan
    ) -> Bool {
        plan.markers.contains { marker in
            marker.kind == kind && utf8Text(marker.sourceRange, source: source) == text
        }
    }

    private func hasStyle(
        _ kind: RenderedMarkdownContentStyleKind,
        text: String,
        source: String,
        plan: RenderedMarkdownPlan
    ) -> Bool {
        plan.contentStyles.contains { style in
            style.kind == kind && utf8Text(style.sourceRange, source: source) == text
        }
    }

    private func utf8Text(_ range: RenderedMarkdownSourceRange, source: String) -> String {
        let data = Data(source.utf8)
        return String(decoding: data[range.utf8Range], as: UTF8.self)
    }

    private func allRanges(in plan: RenderedMarkdownPlan) -> [RenderedMarkdownSourceRange] {
        plan.markers.map(\.sourceRange)
            + plan.contentStyles.map(\.sourceRange)
            + plan.localSourceBlocks.map(\.sourceRange)
            + plan.links.flatMap { [$0.sourceRange, $0.textRange, $0.targetRange] }
            + plan.images.flatMap {
                [$0.sourceRange, $0.alternativeRange, $0.targetRange]
            }
    }

    private func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound < rhs.upperBound && lhs.upperBound > rhs.lowerBound
    }

    @MainActor
    private func assertStrongTextIsRendered(
        in session: MarkdownSourceEditorSession,
        source: String
    ) throws {
        let storage = try XCTUnwrap(session.textView.textStorage)
        let contentLocation = try XCTUnwrap(
            (source as NSString).range(of: "bold").nonEmptyLocation
        )
        let markerLocation = try XCTUnwrap(
            (source as NSString).range(of: "**bold**").nonEmptyLocation
        )
        let contentFont = try XCTUnwrap(
            storage.attribute(.font, at: contentLocation, effectiveRange: nil) as? NSFont
        )
        let markerFont = try XCTUnwrap(
            storage.attribute(.font, at: markerLocation, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: contentFont).contains(.boldFontMask))
        XCTAssertLessThan(markerFont.pointSize, 1)
    }

    @MainActor
    private func settleRenderedPresentation() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    @MainActor
    private func makePNG(size: NSSize) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private extension NSRange {
    var nonEmptyLocation: Int? {
        location == NSNotFound || length == 0 ? nil : location
    }
}
