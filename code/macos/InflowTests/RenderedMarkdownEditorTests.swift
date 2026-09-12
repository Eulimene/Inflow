import AppKit
import XCTest
@testable import Inflow

final class RenderedMarkdownEditorTests: XCTestCase {
    @MainActor
    func testPlanCoversPersonalEditionDirectEditingStructures() {
        let source = """
        普通段落
        # H1
        ## H2
        ### H3
        #### H4
        ##### H5
        ###### H6

        Setext H1
        =========

        Setext H2
        ---------

        > 引用内容
        - 无序项
        1. 有序项
        - [x] 已完成任务
        **粗体** __下划线粗体__ *斜体* _下划线斜体_ ***粗斜体*** ~~删除~~ `代码` `` padded `` [链接文字](https://example.com/path)

        [完整引用][docs] [折叠引用][] [快捷引用]

        | 领域 | 入口 |
        | --- | --- |
        | 文档 | [表格链接](./00%20文档治理/README.md) |

        [docs]: guide.md
        [折叠引用]: collapsed.md
        [快捷引用]: shortcut.md
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
        XCTAssertEqual(headingLevels, [1, 2, 3, 4, 5, 6, 1, 2])
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
        XCTAssertTrue(hasStyle(.strong, text: "下划线粗体", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.emphasis, text: "斜体", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.emphasis, text: "下划线斜体", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.strong, text: "粗斜体", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.emphasis, text: "**粗斜体**", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.strikethrough, text: "删除", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.inlineCode, text: "代码", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.inlineCode, text: "padded", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.link, text: "链接文字", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.link, text: "完整引用", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.link, text: "折叠引用", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.link, text: "快捷引用", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.tableHeader, text: "| 领域 | 入口 |", source: source, plan: plan))
        XCTAssertTrue(
            plan.contentStyles.contains { style in
                if case .tableBody = style.kind {
                    return utf8Text(style.sourceRange, source: source).contains("表格链接")
                }
                return false
            }
        )
        XCTAssertTrue(hasStyle(.link, text: "表格链接", source: source, plan: plan))
        XCTAssertEqual(plan.tables.count, 1)
        XCTAssertEqual(plan.tables.first?.rows.map { $0.map(\.text) }, [
            ["领域", "入口"],
            ["文档", "表格链接"],
        ])
        XCTAssertEqual(plan.tables.first?.rows[1][1].links.map(\.target), [
            "./00%20文档治理/README.md",
        ])

        XCTAssertTrue(hasMarker(.blockQuote, text: "> ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.unorderedList, text: "- ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.orderedList, text: "1. ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.taskList, text: "[x] ", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.strong, text: "**", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.emphasis, text: "*", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.strikethrough, text: "~~", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.inlineCode, text: "`", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.linkDestination, text: "https://example.com/path", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.tableBoundary, text: "|", source: source, plan: plan))
        XCTAssertTrue(hasMarker(.tableSeparator, text: "|", source: source, plan: plan))
        XCTAssertTrue(
            plan.markers.contains { marker in
                marker.kind == .tableDelimiterRow
                    && utf8Text(marker.sourceRange, source: source).contains("---")
            }
        )
        XCTAssertEqual(
            plan.links.map(\.target),
            [
                "https://example.com/path",
                "guide.md",
                "collapsed.md",
                "shortcut.md",
                "./00%20文档治理/README.md",
            ]
        )
        XCTAssertTrue(
            plan.markers.contains { marker in
                marker.kind == .linkDestination
                    && utf8Text(marker.sourceRange, source: source).hasSuffix("[]")
            },
            "Collapsed-reference suffix must not leak into rendered text"
        )
        XCTAssertEqual(
            plan.markers.filter { $0.kind == .referenceDefinition }.count,
            3,
            "Reference definitions are metadata and must not render as body text"
        )

        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let storage = try? XCTUnwrap(session.textView.textStorage)
        XCTAssertNotNil(storage)

        for marker in plan.markers where marker.kind == .referenceDefinition {
            assertVisuallyHidden(marker.sourceRange.utf16Range, in: storage)
        }

        let tableDelimiter = plan.markers.first { $0.kind == .tableDelimiterRow }
        let tableDelimiterFont = tableDelimiter.flatMap { marker in
            storage?.attribute(
                .font,
                at: marker.sourceRange.utf16Range.location,
                effectiveRange: nil
            ) as? NSFont
        }
        XCTAssertLessThan(tableDelimiterFont?.pointSize ?? .greatestFiniteMagnitude, 1)

        let quoteMarker = try? XCTUnwrap(plan.markers.first { $0.kind == .blockQuote })
        let quoteMarkerFont = quoteMarker.flatMap { marker in
            storage?.attribute(
                .font,
                at: marker.sourceRange.utf16Range.location,
                effectiveRange: nil
            ) as? NSFont
        }
        XCTAssertGreaterThanOrEqual(quoteMarkerFont?.pointSize ?? 0, 15)
        if let quoteMarker {
            assertVisuallyHidden(quoteMarker.sourceRange.utf16Range, in: storage)
        }
        XCTAssertEqual(session.textView.renderedQuoteRanges.count, 1)
        XCTAssertNotNil(
            plan.tables.first.flatMap {
                session.textView.renderedTable(
                    atUTF16Location: $0.sourceRange.utf16Range.location
                )
            }
        )

        let paddedLocation = (source as NSString).range(of: "padded").location
        let paddedFont = storage?.attribute(
            .font,
            at: paddedLocation,
            effectiveRange: nil
        ) as? NSFont
        XCTAssertTrue(paddedFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)

        for title in ["Setext H1", "Setext H2"] {
            let location = (source as NSString).range(of: title).location
            let font = storage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            XCTAssertTrue(
                font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
            )
            XCTAssertGreaterThan(font?.pointSize ?? 0, 20)
        }
        XCTAssertEqual(Data(session.textView.string.utf8), Data(source.utf8))
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
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

    func testOnlySourceOnlyBlocksRevealMarkdownAtTheCaret() throws {
        let source = "第一段 **粗体**\n续行\n\n```mermaid\nflowchart LR\nA --> B\n```\n\n最后一段"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let firstLocation = (source as NSString).range(of: "粗体").location
        XCTAssertNil(
            RenderedMarkdownEditor.sourceEditingBlockRange(
                containingUTF16Location: firstLocation,
                source: source,
                plan: plan
            ),
            "ordinary prose must remain WYSIWYG while editing"
        )

        let diagram = try XCTUnwrap(plan.mermaidDiagrams.first)
        XCTAssertEqual(
            RenderedMarkdownEditor.sourceEditingBlockRange(
                containingUTF16Location: diagram.sourceRange.utf16Range.location + 4,
                source: source,
                plan: plan
            ),
            diagram.sourceRange.utf16Range
        )

        let tableSource = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let tablePlan = RenderedMarkdownEditor.plan(for: tableSource)
        XCTAssertNil(
            RenderedMarkdownEditor.sourceEditingBlockRange(
                containingUTF16Location: 3,
                source: tableSource,
                plan: tablePlan
            ),
            "tables are edited through their rendered cells"
        )
    }

    func testComplexStructuresBecomeNonoverlappingLocalSourceBlocks() {
        let source = """
        安全段落

        | A | B |
        | - | - |
        | 1 | 2 |

        ```swift
        print("code")
        [not-definition]: hidden.md
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

        XCTAssertFalse(reasons.contains(.table))
        XCTAssertTrue(reasons.contains(.fencedCode))
        XCTAssertFalse(reasons.contains(.mermaid))
        XCTAssertTrue(reasons.contains(.rawHTML))
        XCTAssertTrue(reasons.contains(.complexOrAmbiguous))
        XCTAssertEqual(plan.images.map(\.target), ["image.png"])
        XCTAssertEqual(plan.tables.count, 1)
        XCTAssertEqual(plan.mermaidDiagrams.count, 1)
        XCTAssertTrue(plan.mermaidDiagrams[0].svg.contains("<svg"))
        XCTAssertTrue(hasStyle(.paragraph, text: "安全段落", source: source, plan: plan))
        XCTAssertTrue(hasStyle(.tableHeader, text: "| A | B |", source: source, plan: plan))
        XCTAssertTrue(
            plan.contentStyles.contains { style in
                if case .tableBody = style.kind {
                    return utf8Text(style.sourceRange, source: source) == "| 1 | 2 |"
                }
                return false
            }
        )
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
            XCTAssertFalse(plan.tables.contains {
                rangesOverlap($0.sourceRange.utf8Range, block.sourceRange.utf8Range)
            })
            XCTAssertFalse(plan.mermaidDiagrams.contains {
                rangesOverlap($0.sourceRange.utf8Range, block.sourceRange.utf8Range)
            })
        }
    }

    @MainActor
    func testRenderedSessionMountsTableQuoteAndMermaidWithoutChangingSource() throws {
        let source = """
        > 行内引用

        | 名称 | 文档 |
        | :--- | ---: |
        | Inflow | [打开](guide.md) |

        ```mermaid
        flowchart LR
        A[开始] --> B[结束]
        ```
        """
        let plan = RenderedMarkdownEditor.plan(for: source)
        XCTAssertTrue(plan.localSourceBlocks.isEmpty)
        XCTAssertEqual(plan.tables.first?.alignments, [.leading, .trailing])
        XCTAssertEqual(plan.mermaidDiagrams.count, 1)

        var activatedTarget: String?
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(
            .rendered,
            source: source,
            onLinkClick: { activatedTarget = $0 }
        )

        let table = try XCTUnwrap(plan.tables.first)
        let tableView = try XCTUnwrap(
            session.textView.renderedTable(
                atUTF16Location: table.sourceRange.utf16Range.location
            )
        )
        XCTAssertEqual(tableView.cellTexts, [["名称", "文档"], ["Inflow", "打开"]])
        XCTAssertGreaterThan(tableView.renderedSize.width, 100)
        XCTAssertGreaterThan(tableView.renderedSize.height, 60)
        XCTAssertTrue(
            tableView.textView(NSTextView(), clickedOnLink: "guide.md", at: 0)
        )
        XCTAssertEqual(activatedTarget, "guide.md")

        activatedTarget = nil
        session.setPresentation(
            .rendered,
            source: source,
            onLinkClick: { activatedTarget = $0 },
            linkActivation: .contextMenu
        )
        let contextMenuTable = try XCTUnwrap(
            session.textView.renderedTable(
                atUTF16Location: table.sourceRange.utf16Range.location
            )
        )
        XCTAssertFalse(
            contextMenuTable.textView(NSTextView(), clickedOnLink: "guide.md", at: 0)
        )
        XCTAssertNil(activatedTarget)

        let diagram = try XCTUnwrap(plan.mermaidDiagrams.first)
        XCTAssertNotNil(
            session.textView.renderedImage(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
    }

    @MainActor
    func testRenderedSessionKeepsProseRenderedAndUnmountsOnlySourceOnlyBlocks() throws {
        let source = "第一段 **粗体**\n\n```mermaid\nflowchart LR\nA --> B\n```\n\n第二段 *斜体*"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let boldMarker = try XCTUnwrap(plan.markers.first { $0.kind == .strong })
        let italicMarker = try XCTUnwrap(plan.markers.first { $0.kind == .emphasis })
        let diagram = try XCTUnwrap(plan.mermaidDiagrams.first)
        let session = MarkdownSourceEditorSession()
        session.textView.string = source

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.scrollView
        defer {
            _ = window.makeFirstResponder(nil)
            window.contentView = nil
        }
        XCTAssertTrue(window.makeFirstResponder(session.textView))

        session.textView.setSelectedRange(
            NSRange(location: boldMarker.sourceRange.utf16Range.location, length: 0)
        )
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        assertVisuallyHidden(boldMarker.sourceRange.utf16Range, in: session.textView.textStorage)
        assertVisuallyHidden(italicMarker.sourceRange.utf16Range, in: session.textView.textStorage)
        XCTAssertNotNil(
            session.textView.renderedImage(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )
        let storage = try XCTUnwrap(session.textView.textStorage)
        let openingParagraph = try XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: diagram.sourceRange.utf16Range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        let diagramBodyLocation = (source as NSString).range(of: "flowchart LR").location
        let bodyParagraph = try XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: diagramBodyLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertGreaterThan(
            openingParagraph.minimumLineHeight,
            bodyParagraph.minimumLineHeight,
            "only the anchor line should reserve the Mermaid overlay height"
        )

        session.textView.setSelectedRange(
            NSRange(location: diagram.sourceRange.utf16Range.location + 4, length: 0)
        )
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        assertVisuallyHidden(boldMarker.sourceRange.utf16Range, in: session.textView.textStorage)
        XCTAssertNil(
            session.textView.renderedImage(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            ),
            "the Mermaid overlay must not remain above the source being edited"
        )

        session.textView.setSelectedRange(
            NSRange(location: italicMarker.sourceRange.utf16Range.location, length: 0)
        )
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        assertVisuallyHidden(boldMarker.sourceRange.utf16Range, in: session.textView.textStorage)
        assertVisuallyHidden(italicMarker.sourceRange.utf16Range, in: session.textView.textStorage)
        XCTAssertNotNil(
            session.textView.renderedImage(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )

        _ = window.makeFirstResponder(nil)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        assertVisuallyHidden(italicMarker.sourceRange.utf16Range, in: session.textView.textStorage)
    }

    func testUnsupportedMermaidRemainsReadableLocalSource() {
        let source = "```mermaid\npie\ntitle Values\n```"
        let plan = RenderedMarkdownEditor.plan(for: source)

        XCTAssertTrue(plan.mermaidDiagrams.isEmpty)
        XCTAssertEqual(plan.localSourceBlocks.flatMap(\.reasons), [.mermaid])
        XCTAssertEqual(plan.sourceSnapshot, source)
    }

    @MainActor
    func testUnsupportedTripleDashBlockRemainsLiteralSource() throws {
        let source = "---\n测试文字\n---"
        let plan = RenderedMarkdownEditor.plan(for: source)

        let block = try XCTUnwrap(plan.localSourceBlocks.first)
        XCTAssertEqual(plan.localSourceBlocks.count, 1)
        XCTAssertEqual(block.reasons, [.unsupportedSyntax])
        XCTAssertEqual(utf8Text(block.sourceRange, source: source), source)
        XCTAssertTrue(plan.markers.isEmpty)
        XCTAssertTrue(plan.contentStyles.isEmpty)
        XCTAssertTrue(plan.links.isEmpty)
        XCTAssertTrue(plan.images.isEmpty)
        XCTAssertTrue(plan.tables.isEmpty)
        XCTAssertTrue(plan.mermaidDiagrams.isEmpty)

        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
    }

    func testPlanRendersLocalAndRemoteImagesWithoutChangingSource() throws {
        let source = """
        ![本地图](assets/封面.png)

        ![remote](https://example.com/a.png)

        ![引用图][cover]

        ![折叠图][]

        [cover]: assets/reference.png
        [折叠图]: https://example.com/collapsed.png
        """

        let plan = RenderedMarkdownEditor.plan(for: source)

        XCTAssertTrue(plan.localSourceBlocks.isEmpty)
        XCTAssertEqual(plan.images.count, 4)
        XCTAssertEqual(plan.images.map(\.alternative), ["本地图", "remote", "引用图", "折叠图"])
        XCTAssertEqual(
            plan.images.map(\.target),
            [
                "assets/封面.png",
                "https://example.com/a.png",
                "assets/reference.png",
                "https://example.com/collapsed.png",
            ]
        )
        XCTAssertEqual(
            utf8Text(try XCTUnwrap(plan.images.first).sourceRange, source: source),
            "![本地图](assets/封面.png)"
        )
        XCTAssertEqual(Data(plan.sourceSnapshot.utf8), Data(source.utf8))
        XCTAssertTrue(
            utf8Text(try XCTUnwrap(plan.images.last).sourceRange, source: source)
                .hasSuffix("[]"),
            "Collapsed-reference image suffix must be covered by the rendered image"
        )
        XCTAssertEqual(plan.markers.filter { $0.kind == .referenceDefinition }.count, 2)
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
    func testRenderedSessionSupportsSingleClickAndContextMenuLinkPreferences() throws {
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
        XCTAssertTrue(
            RenderedMarkdownLinkActivation.shouldNavigate(for: [], preference: .singleClick)
        )
        XCTAssertTrue(
            RenderedMarkdownLinkActivation.shouldNavigate(
                for: [.command],
                preference: .singleClick
            )
        )
        XCTAssertTrue(
            RenderedMarkdownLinkActivation.shouldNavigate(
                for: [.command, .shift],
                preference: .singleClick
            ) == false
        )
        XCTAssertFalse(
            RenderedMarkdownLinkActivation.shouldNavigate(for: [], preference: .contextMenu)
        )
    }

    func testRenderedTableEditingPreservesMarkdownAndSupportsCommonOperations() throws {
        let source = "| Name | Score |\n| :--- | ---: |\n| Alice | 9 |"
        let table = try XCTUnwrap(RenderedMarkdownEditor.plan(for: source).tables.first)

        XCTAssertEqual(
            RenderedMarkdownTableEditing.replacement(
                for: table,
                applying: .updateCell(row: 1, column: 0, text: "A|B")
            ),
            "| Name | Score |\n| --- | ---: |\n| A\\|B | 9 |"
        )
        XCTAssertEqual(
            RenderedMarkdownTableEditing.replacement(
                for: table,
                applying: .insertRow(at: 2)
            ),
            "| Name | Score |\n| --- | ---: |\n| Alice | 9 |\n|  |  |"
        )
        XCTAssertEqual(
            RenderedMarkdownTableEditing.replacement(
                for: table,
                applying: .insertColumn(at: 1)
            ),
            "| Name |  | Score |\n| --- | --- | ---: |\n| Alice |  | 9 |"
        )
        XCTAssertEqual(
            RenderedMarkdownTableEditing.replacement(
                for: table,
                applying: .setAlignment(column: 0, alignment: .center)
            ),
            "| Name | Score |\n| :---: | ---: |\n| Alice | 9 |"
        )

        let richSource = "| **Name** | Docs |\n| --- | --- |\n| Alice | [Open](guide.md) |"
        let richTable = try XCTUnwrap(RenderedMarkdownEditor.plan(for: richSource).tables.first)
        XCTAssertEqual(
            RenderedMarkdownTableEditing.replacement(
                for: richTable,
                applying: .updateCell(row: 1, column: 0, text: "Bob")
            ),
            "| **Name** | Docs |\n| --- | --- |\n| Bob | [Open](guide.md) |",
            "editing one cell must preserve Markdown in every untouched cell"
        )
    }

    func testAdaptiveTableLayoutFillsAndRespondsToTheViewport() throws {
        let source = "| A much longer heading | B |\n| --- | ---: |\n| value | 1 |"
        let table = try XCTUnwrap(RenderedMarkdownEditor.plan(for: source).tables.first)
        let strategy = AdaptiveRenderedMarkdownTableLayoutStrategy()
        let font = NSFont.systemFont(ofSize: 15)
        let wide = strategy.columnWidths(for: table, font: font, availableWidth: 680)
        let narrow = strategy.columnWidths(for: table, font: font, availableWidth: 320)

        XCTAssertEqual(wide.reduce(0, +), 680, accuracy: 2)
        XCTAssertEqual(narrow.reduce(0, +), 320, accuracy: 2)
        XCTAssertGreaterThan(wide[0], wide[1])
        XCTAssertGreaterThan(narrow[0], narrow[1])
        XCTAssertTrue(narrow.allSatisfy { $0 >= 56 })
    }

    @MainActor
    func testRenderedTableOverlaySurvivesUnrelatedProseTyping() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let firstPlan = RenderedMarkdownEditor.plan(for: source)
        let firstTable = try XCTUnwrap(firstPlan.tables.first)
        let mounted = try XCTUnwrap(
            session.textView.renderedTable(
                atUTF16Location: firstTable.sourceRange.utf16Range.location
            )
        )

        session.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        await settleRenderedPresentation()
        let updatedSource = session.textView.string
        let updatedTable = try XCTUnwrap(RenderedMarkdownEditor.plan(for: updatedSource).tables.first)
        let retained = try XCTUnwrap(
            session.textView.renderedTable(
                atUTF16Location: updatedTable.sourceRange.utf16Range.location
            )
        )

        XCTAssertTrue(mounted === retained, "unrelated typing must not rebuild the table overlay")
    }

    @MainActor
    func testFencedCodeRendersUntilCaretRequestsItsSource() throws {
        let source = "Before\n\n```swift\nprint(1)\n```\n\nAfter"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let block = try XCTUnwrap(plan.localSourceBlocks.first { $0.reasons == [.fencedCode] })
        let opening = block.sourceRange.utf16Range.location
        let body = (source as NSString).range(of: "print(1)").location
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let storage = try XCTUnwrap(session.textView.textStorage)
        XCTAssertLessThan(
            try XCTUnwrap(storage.attribute(.font, at: opening, effectiveRange: nil) as? NSFont)
                .pointSize,
            1
        )
        XCTAssertTrue(
            try XCTUnwrap(storage.attribute(.font, at: body, effectiveRange: nil) as? NSFont)
                .fontDescriptor.symbolicTraits.contains(.monoSpace)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.scrollView
        defer { window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(session.textView))
        session.textView.setSelectedRange(NSRange(location: body, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        XCTAssertGreaterThan(
            try XCTUnwrap(storage.attribute(.font, at: opening, effectiveRange: nil) as? NSFont)
                .pointSize,
            1
        )
    }

    @MainActor
    func testRenderedCaretTypingFontMatchesTheVisibleText() throws {
        let source = "# 同一基线"
        let location = (source as NSString).range(of: "同").location
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.setSelectedRange(NSRange(location: location, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let storage = try XCTUnwrap(session.textView.textStorage)
        let visibleFont = try XCTUnwrap(
            storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        )
        let caretFont = try XCTUnwrap(session.textView.typingAttributes[.font] as? NSFont)

        XCTAssertEqual(caretFont.pointSize, visibleFont.pointSize, accuracy: 0.001)
        XCTAssertEqual(caretFont.fontName, visibleFont.fontName)
    }

    @MainActor
    func testRenderedCaretAtHeadingEndSkipsHiddenMarkersAndNewline() throws {
        let source = "# **同一基线**\n下一段"
        let insertion = (source as NSString).range(of: "\n").location
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.setSelectedRange(NSRange(location: insertion, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let font = try XCTUnwrap(session.textView.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, 27, accuracy: 0.001)
        let rect = RenderedMarkdownCaretStyleResolver.adjustedInsertionRect(
            NSRect(x: 10, y: 10, width: 1, height: 40),
            font: font
        )
        XCTAssertEqual(rect.midY, 30, accuracy: 0.001)
        XCTAssertGreaterThan(rect.height, 20)
    }

    @MainActor
    func testLongChineseBlockQuoteUsesRenderedTypographyWithoutExposingMarker() throws {
        let source = "> 接手文件 → 形成内容 → 理解结构 → 验证结果 → 交付成果 → 继续演进"
        let plan = RenderedMarkdownEditor.plan(for: source)
        XCTAssertTrue(plan.localSourceBlocks.isEmpty)
        XCTAssertTrue(hasMarker(.blockQuote, text: "> ", source: source, plan: plan))
        XCTAssertTrue(
            hasStyle(
                .blockQuote,
                text: "接手文件 → 形成内容 → 理解结构 → 验证结果 → 交付成果 → 继续演进",
                source: source,
                plan: plan
            )
        )

        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let storage = try XCTUnwrap(session.textView.textStorage)
        assertVisuallyHidden(NSRange(location: 0, length: 2), in: storage)
        let contentLocation = (source as NSString).range(of: "接手文件").location
        let color = try XCTUnwrap(
            storage.attribute(.foregroundColor, at: contentLocation, effectiveRange: nil)
                as? NSColor
        )
        XCTAssertEqual(color, NSColor.secondaryLabelColor)
        XCTAssertEqual(session.textView.renderedQuoteRanges.count, 1)
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
    func testRenderedSessionRendersStructuralMarkersWithoutLeakingQuoteSource() throws {
        let source = "> quote\n- item\n1. ordered\n- [x] done\n\nparagraph **bold**"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        let inlineMarker = (source as NSString).range(of: "**bold**")
        session.textView.setSelectedRange(NSRange(location: inlineMarker.location, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let quoteLocation = try XCTUnwrap((source as NSString).range(of: "> ").nonEmptyLocation)
        let quoteFont = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: quoteLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertGreaterThanOrEqual(quoteFont.pointSize, 15)
        assertVisuallyHidden(
            NSRange(location: quoteLocation, length: 2),
            in: session.textView.textStorage,
            message: "quote source marker must be hidden without shrinking the caret"
        )

        for marker in ["- ", "1. ", "[x] "] {
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
        XCTAssertGreaterThanOrEqual(inlineMarkerFont.pointSize, 15)
        assertVisuallyHidden(
            NSRange(location: inlineMarker.location, length: 2),
            in: session.textView.textStorage,
            message: "inline Markdown delimiters must stay visually collapsed while editing"
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
        XCTAssertEqual(codeFont.pointSize, 27, accuracy: 0.001)
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
            XCTAssertGreaterThanOrEqual(markerFont.pointSize, 15)
            assertVisuallyHidden(
                marker.sourceRange.utf16Range,
                in: storage,
                message: "\(marker.kind) should be collapsed without changing line metrics"
            )
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
        let session = MarkdownSourceEditorSession(engineEnabled: false)
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

    @MainActor
    func testRenderedLinkPublishesHoverRangeAtItsVisibleGlyphs() throws {
        let source = "Read [guide](guide.md)"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let link = try XCTUnwrap(plan.links.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let session = MarkdownSourceEditorSession()
        window.contentView = session.scrollView
        session.textView.string = source
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        session.textView.layoutManager?.ensureLayout(for: session.textView.textContainer!)
        let glyph = try XCTUnwrap(session.textView.layoutManager).glyphIndexForCharacter(
            at: link.textRange.utf16Range.location
        )
        let glyphRect = try XCTUnwrap(session.textView.layoutManager).boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: try XCTUnwrap(session.textView.textContainer)
        )
        let viewPoint = NSPoint(
            x: session.textView.textContainerOrigin.x + glyphRect.midX,
            y: session.textView.textContainerOrigin.y + glyphRect.midY
        )
        session.textView.updateHoveredLink(atLocalPoint: viewPoint)
        XCTAssertEqual(session.textView.hoveredLinkRange, link.textRange.utf16Range)
        session.textView.updateHoveredLink(atLocalPoint: NSPoint(x: -20, y: -20))
        XCTAssertNil(session.textView.hoveredLinkRange)
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
            + plan.tables.flatMap { table in
                [table.sourceRange] + table.rows.flatMap { $0.map(\.sourceRange) }
            }
            + plan.mermaidDiagrams.map(\.sourceRange)
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
        XCTAssertGreaterThanOrEqual(markerFont.pointSize, 15)
        assertVisuallyHidden(
            NSRange(location: markerLocation, length: 2),
            in: storage
        )
    }

    private func assertVisuallyHidden(
        _ range: NSRange,
        in storage: NSTextStorage?,
        message: String = "Markdown marker must be visually hidden",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let storage, range.length > 0, NSMaxRange(range) <= storage.length else {
            XCTFail("Invalid hidden marker range", file: file, line: line)
            return
        }
        let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
            as? NSColor
        XCTAssertEqual(color?.alphaComponent ?? 1, 0, accuracy: 0.001, message, file: file, line: line)
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
