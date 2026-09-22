import AppKit
import XCTest
@testable import Inflow

final class RenderedMarkdownEditorTests: XCTestCase {
    @MainActor
    private func resolvedDiagramPlan(for source: String) async throws -> RenderedMarkdownPlan {
        let plan = RenderedMarkdownEditor.plan(for: source)
        let candidate = await JavaScriptRenderService.shared.resolveDiagrams(in: plan, revision: 0)
        let resolution = try XCTUnwrap(candidate)
        return try XCTUnwrap(plan.resolvingMermaid(with: resolution))
    }

    @MainActor
    func testPlanCoversPersonalEditionDirectEditingStructures() async {
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
        XCTAssertTrue(
            hasMarker(
                .linkDestination,
                text: "(https://example.com/path)",
                source: source,
                plan: plan
            )
        )
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
        _ = await session.deriveContent(for: source, configuration: .default)
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
        XCTAssertLessThan(quoteMarkerFont?.pointSize ?? .greatestFiniteMagnitude, 1)
        if let quoteMarker {
            assertVisuallyHidden(quoteMarker.sourceRange.utf16Range, in: storage)
        }
        XCTAssertEqual(session.textView.renderedQuoteRanges.count, 1)
        XCTAssertEqual(
            session.textView.renderedHeadingDividerRanges.count,
            4,
            "H1 and H2 headings share the reference design's quiet divider"
        )
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
    func testRenderedSessionMountsTableQuoteAndMermaidWithoutChangingSource() async throws {
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
        let plan = try await resolvedDiagramPlan(for: source)
        XCTAssertTrue(plan.localSourceBlocks.isEmpty)
        XCTAssertEqual(plan.tables.first?.alignments, [.leading, .trailing])
        XCTAssertEqual(plan.mermaidDiagrams.count, 1)

        var activatedTarget: String?
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        session.scrollView.layoutSubtreeIfNeeded()
        session.textView.string = source
        let resolvedContent = try XCTUnwrap(
            EditorEngineDerivedContent.deriveSynchronously(source: source)
        )
        session.deferredMermaidResolver = { _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return EditorEngineMermaidResolution(
                revision: resolvedContent.revision,
                diagrams: plan.mermaidDiagrams,
                failedSourceRanges: []
            )
        }
        let derivedContent = await session.deriveContent(
            for: source,
            configuration: .default
        )
        let content = try XCTUnwrap(derivedContent)
        XCTAssertTrue(content.mermaidDeferred)
        XCTAssertTrue(content.nativeRenderPlan.mermaidDiagrams.allSatisfy(\.isPlaceholder))
        XCTAssertNil(content.htmlFragment)
        XCTAssertNil(content.previewHTMLFragment)
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(
            .rendered,
            source: source,
            onLinkClick: { activatedTarget = $0 }
        )
        let placeholder = try XCTUnwrap(content.nativeRenderPlan.mermaidDiagrams.first)
        XCTAssertNotNil(
            session.textView.renderedImage(
                atUTF16Location: placeholder.sourceRange.utf16Range.location
            )
        )
        XCTAssertEqual(session.renderedMermaidPatchCount, 0)

        let table = try XCTUnwrap(plan.tables.first)
        let tableView = try XCTUnwrap(
            session.textView.renderedTable(
                atUTF16Location: table.sourceRange.utf16Range.location
            )
        )
        XCTAssertEqual(tableView.cellTexts, [["名称", "文档"], ["Inflow", "打开"]])
        XCTAssertGreaterThan(tableView.renderedSize.width, 100)
        XCTAssertGreaterThan(tableView.renderedSize.height, 60)
        XCTAssertEqual(
            tableView.restingLinkUnderlineStyles(),
            [MarkdownLinkVisualStyle.restingUnderline]
        )
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

        let fullPresentationPasses = session.renderedPresentationPassCount
        await session.waitForRenderedResources()
        XCTAssertLessThanOrEqual(session.renderedPresentationPassCount, fullPresentationPasses + 1)
        XCTAssertEqual(
            session.renderedMermaidPatchCount,
            1,
            "the completed SVG should patch only the Mermaid overlay"
        )

        let diagram = try XCTUnwrap(plan.mermaidDiagrams.first)
        XCTAssertGreaterThan(diagram.intrinsicWidth, 0)
        XCTAssertGreaterThan(diagram.intrinsicHeight, 0)
        XCTAssertNotNil(
            session.textView.renderedImage(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )
        let diagramSize = try XCTUnwrap(
            session.textView.renderedImageSize(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )
        XCTAssertEqual(diagramSize.width, CGFloat(diagram.intrinsicWidth), accuracy: 0.001)
        XCTAssertEqual(diagramSize.height, CGFloat(diagram.intrinsicHeight), accuracy: 0.001)
        XCTAssertEqual(
            diagramSize.width / diagramSize.height,
            CGFloat(diagram.intrinsicWidth) / CGFloat(diagram.intrinsicHeight),
            accuracy: 0.01
        )
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)

        let readOnlySession = MarkdownSourceEditorSession(role: .renderedProjection)
        readOnlySession.scrollView.frame = session.scrollView.frame
        readOnlySession.scrollView.layoutSubtreeIfNeeded()
        readOnlySession.textView.isEditable = false
        readOnlySession.setPresentation(.rendered, source: "", onLinkClick: nil)
        XCTAssertEqual(readOnlySession.textView.string, "")
        readOnlySession.installSharedRenderedPlan(plan, source: source)
        XCTAssertEqual(readOnlySession.textView.string, source)
        let initialProjectionPassCount = readOnlySession.renderedPresentationPassCount
        readOnlySession.installSharedRenderedPlan(plan, source: source)
        XCTAssertEqual(
            readOnlySession.renderedPresentationPassCount,
            initialProjectionPassCount,
            "repeated open/file notifications must not rebuild an unchanged rendered snapshot"
        )
        let readOnlyTable = try XCTUnwrap(
            readOnlySession.textView.renderedTable(
                atUTF16Location: table.sourceRange.utf16Range.location
            )
        )
        XCTAssertEqual(
            readOnlyTable.renderedSize.width,
            contextMenuTable.renderedSize.width,
            accuracy: 12,
            "table width may differ only by the viewport's vertical scroller inset"
        )
        XCTAssertEqual(readOnlyTable.renderedSize.height, contextMenuTable.renderedSize.height)
        XCTAssertEqual(
            readOnlyTable.backgroundColor(forRow: 0),
            contextMenuTable.backgroundColor(forRow: 0)
        )
        XCTAssertEqual(
            readOnlyTable.backgroundColor(forRow: 1),
            contextMenuTable.backgroundColor(forRow: 1)
        )
        XCTAssertNotEqual(
            contextMenuTable.backgroundColor(forRow: 0),
            contextMenuTable.backgroundColor(forRow: 1)
        )
        XCTAssertNotEqual(
            RenderedMarkdownTableView.backgroundColor(forRow: 1),
            RenderedMarkdownTableView.backgroundColor(forRow: 2)
        )
        XCTAssertNotEqual(
            RenderedMarkdownTableView.backgroundColor(
                forRow: 0,
                appearance: try XCTUnwrap(NSAppearance(named: .aqua))
            ),
            RenderedMarkdownTableView.backgroundColor(
                forRow: 0,
                appearance: try XCTUnwrap(NSAppearance(named: .darkAqua))
            )
        )
        XCTAssertEqual(
            RenderedMarkdownTableView.borderColor,
            MarkdownRenderPalette.resolved(for: NSApp.effectiveAppearance).borderColor
        )
        let quoteLocation = (source as NSString).range(of: "行内引用").location
        let editableQuote = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .paragraphStyle,
                at: quoteLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        let readOnlyQuote = try XCTUnwrap(
            readOnlySession.textView.textStorage?.attribute(
                .paragraphStyle,
                at: quoteLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertEqual(readOnlyQuote.lineHeightMultiple, editableQuote.lineHeightMultiple)
        XCTAssertEqual(readOnlyQuote.headIndent, editableQuote.headIndent)
        XCTAssertFalse(readOnlySession.textView.isEditable)

        let raceSession = MarkdownSourceEditorSession(role: .renderedProjection)
        raceSession.scrollView.frame = session.scrollView.frame
        raceSession.textView.isEditable = false
        raceSession.setPresentation(.rendered, source: "", onLinkClick: nil)
        raceSession.installResolvedMermaidPlan(plan, source: source)
        XCTAssertEqual(raceSession.textView.string, source)
        let resolvedRaceSize = try XCTUnwrap(
            raceSession.textView.renderedImageSize(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )
        let resolvedRacePassCount = raceSession.renderedPresentationPassCount
        raceSession.installSharedRenderedPlan(content.nativeRenderPlan, source: source)
        XCTAssertEqual(raceSession.renderedPresentationPassCount, resolvedRacePassCount)
        XCTAssertEqual(
            raceSession.textView.renderedImageSize(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            ),
            resolvedRaceSize,
            "a late placeholder plan must not replace an already resolved SVG"
        )

        session.textView.string = "newer revision"
        session.installResolvedMermaidPlan(plan, source: source)
        XCTAssertEqual(
            session.renderedMermaidPatchCount,
            1,
            "a completed result for an obsolete source must be discarded"
        )
    }

    @MainActor
    func testRenderedTableUsesOneLayoutAnchorAndCollapsesBackingRows() async throws {
        let source = """
        表格之前

        | 名称 | 说明 |
        | --- | --- |
        | A | 第一行 |
        | B | 第二行 |
        | C | 第三行 |
        | D | 第四行 |

        表格之后
        """
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        session.scrollView.layoutSubtreeIfNeeded()
        session.textView.string = source
        let derivedContent = await session.deriveContent(for: source, configuration: .default)
        let content = try XCTUnwrap(derivedContent)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let table = try XCTUnwrap(content.nativeRenderPlan.tables.first)
        let tableRange = table.sourceRange.utf16Range
        let tableView = try XCTUnwrap(
            session.textView.renderedTable(atUTF16Location: tableRange.location)
        )
        let storage = try XCTUnwrap(session.textView.textStorage)
        let anchorStyle = try XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: tableRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        let backingRowLocation = (source as NSString).range(of: "| B | 第二行 |").location
        let backingRowStyle = try XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: backingRowLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )

        XCTAssertEqual(
            anchorStyle.minimumLineHeight,
            tableView.renderedSize.height + 10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            anchorStyle.maximumLineHeight,
            anchorStyle.minimumLineHeight,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(backingRowStyle.maximumLineHeight, 0.101)
        XCTAssertEqual(backingRowStyle.paragraphSpacingBefore, 0, accuracy: 0.001)
        XCTAssertEqual(backingRowStyle.paragraphSpacing, 0, accuracy: 0.001)

        let layoutManager = try XCTUnwrap(session.textView.layoutManager)
        let textContainer = try XCTUnwrap(session.textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let anchorGlyph = layoutManager.glyphIndexForCharacter(at: tableRange.location)
        let followingLocation = (source as NSString).range(of: "表格之后").location
        let followingGlyph = layoutManager.glyphIndexForCharacter(at: followingLocation)
        let anchorLine = layoutManager.lineFragmentRect(
            forGlyphAt: anchorGlyph,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        let followingLine = layoutManager.lineFragmentRect(
            forGlyphAt: followingGlyph,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        XCTAssertLessThanOrEqual(
            followingLine.minY - anchorLine.minY,
            tableView.renderedSize.height + 40,
            "hidden Markdown rows must not leave a large blank region after the table"
        )
    }

    @MainActor
    func testRenderedParagraphsDoNotAddExtraParagraphSpacing() async throws {
        let source = "第一段\n\n第二段"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let storage = try XCTUnwrap(session.textView.textStorage)

        for text in ["第一段", "第二段"] {
            let location = (source as NSString).range(of: text).location
            let style = try XCTUnwrap(
                storage.attribute(
                    .paragraphStyle,
                    at: location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )
            XCTAssertEqual(style.paragraphSpacing, 0, accuracy: 0.001)
        }
        let defaultStyle = try XCTUnwrap(session.textView.defaultParagraphStyle)
        XCTAssertEqual(defaultStyle.paragraphSpacing, 0, accuracy: 0.001)
        let blankLineLocation = (source as NSString).range(of: "\n\n").location + 1
        let blankStyle = try XCTUnwrap(
            storage.attribute(.paragraphStyle, at: blankLineLocation, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(
            blankStyle.minimumLineHeight,
            CGFloat(session.sourceAppearance.fontSize * session.sourceAppearance.lineHeight),
            accuracy: 0.001
        )
        XCTAssertEqual(blankStyle.maximumLineHeight, 0)
        XCTAssertGreaterThan(try XCTUnwrap(storage.attribute(.font, at: blankLineLocation, effectiveRange: nil) as? NSFont).pointSize, 1)
    }

    @MainActor
    func testRenderedSessionKeepsProseRenderedAndUnmountsOnlySourceOnlyBlocks() async throws {
        let source = "第一段 **粗体**\n\n```mermaid\nflowchart LR\nA --> B\n```\n\n第二段 *斜体*"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let boldMarker = try XCTUnwrap(plan.markers.first { $0.kind == .strong })
        let italicMarker = try XCTUnwrap(plan.markers.first { $0.kind == .emphasis })
        let diagram = try XCTUnwrap(plan.mermaidDiagrams.first)
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)

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
        XCTAssertFalse(session.textView.renderedCollapsedSourceRanges.contains(boldMarker.sourceRange.utf16Range))
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
        XCTAssertNotNil(
            session.textView.renderedImage(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            ),
            "editing Mermaid should retain a live diagram below its visible source"
        )
        let closingFenceLocation = (source as NSString).range(
            of: "```",
            options: .backwards
        ).location
        let closingParagraph = try XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: closingFenceLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertGreaterThan(
            closingParagraph.paragraphSpacing,
            CGFloat(diagram.intrinsicHeight),
            "the live diagram should reserve space after the editable Mermaid source"
        )

        session.textView.setSelectedRange(
            NSRange(location: italicMarker.sourceRange.utf16Range.location, length: 0)
        )
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        assertVisuallyHidden(boldMarker.sourceRange.utf16Range, in: session.textView.textStorage)
        XCTAssertFalse(session.textView.renderedCollapsedSourceRanges.contains(italicMarker.sourceRange.utf16Range))
        XCTAssertNotNil(
            session.textView.renderedImage(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )

        _ = window.makeFirstResponder(nil)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        assertVisuallyHidden(italicMarker.sourceRange.utf16Range, in: session.textView.textStorage)
    }

    @MainActor
    func testUnsupportedMermaidRemainsReadableLocalSource() async throws {
        let source = "```mermaid\nflowchart LR\n-->\n```"
        let plan = try await resolvedDiagramPlan(for: source)
        XCTAssertTrue(plan.mermaidDiagrams.isEmpty)
        XCTAssertEqual(plan.localSourceBlocks.flatMap(\.reasons), [.mermaid])
        XCTAssertEqual(plan.sourceSnapshot, source)
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.installSharedRenderedPlan(plan, source: source)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        XCTAssertNotNil(session.textView.renderedImage(atUTF16Location: 0), "Failed diagrams retain source and show a visible diagnostic")
        XCTAssertEqual(session.textView.string, source)
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
    func testRenderedSessionSupportsSingleClickAndContextMenuLinkPreferences() async throws {
        let source = "Read [the guide](guide.md)."
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
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
                for: [.capsLock, .numericPad],
                preference: .singleClick
            ),
            "keyboard state unrelated to editing must not disable links"
        )
        XCTAssertFalse(
            RenderedMarkdownLinkActivation.shouldNavigate(
                for: [.option],
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

        let values = [["中文😀\n下一行", "a\tb"], ["quote\"here", "A|B"]]
        XCTAssertEqual(TableClipboard.decode(TableClipboard.encode(values)), values)
        let updated = try XCTUnwrap(RenderedMarkdownTableEditing.replacement(for: table,
            applying: .updateCells(row: 1, column: 0, texts: values)))
        let updatedTable = try XCTUnwrap(RenderedMarkdownEditor.plan(for: updated).tables.first)
        XCTAssertEqual(updatedTable.rows.count, 3)
        XCTAssertEqual(updatedTable.rows[1][0].text, "中文😀\n下一行")
        XCTAssertEqual(updatedTable.rows[2][1].text, "A|B")
        XCTAssertTrue(updated.contains("<br>"))
        let expanded = try XCTUnwrap(RenderedMarkdownTableEditing.replacement(for: table,
            applying: .updateCells(row: 1, column: 1, texts: [["a", "b", "c"], ["d", "e", "f"]])))
        let expandedTable = try XCTUnwrap(RenderedMarkdownEditor.plan(for: expanded).tables.first)
        XCTAssertEqual(expandedTable.rows.count, 3)
        XCTAssertEqual(expandedTable.rows[0].count, 4)
        XCTAssertEqual(expandedTable.rows[2][3].text, "f")


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

    @MainActor
    func testAdaptiveTableLayoutFillsAndRespondsToTheViewport() throws {
        let storage = NSTextStorage(string: "first\nunchanged", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let projection = NSMutableAttributedString(attributedString: storage)
        projection.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 5))
        XCTAssertEqual(RenderedAttributePatch.apply(projection, to: storage), [NSRange(location: 0, length: 5)])
        XCTAssertTrue(RenderedAttributePatch.apply(projection, to: storage).isEmpty)
        XCTAssertNil(storage.attribute(.foregroundColor, at: 6, effectiveRange: nil))

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

        let denseSource = "| A | B | C | D | E |\n| --- | --- | --- | --- | --- |\n| 1 | 2 | 3 | 4 | 5 |"
        let denseTable = try XCTUnwrap(RenderedMarkdownEditor.plan(for: denseSource).tables.first)
        let compressed = strategy.columnWidths(
            for: denseTable,
            font: font,
            availableWidth: 160
        )
        XCTAssertEqual(compressed.count, 5)
        XCTAssertEqual(compressed.reduce(0, +), 160, accuracy: 0.001)
        XCTAssertTrue(compressed.allSatisfy { $0 > 0 })

        let measured = CountingTableLayoutStrategy()
        let view = RenderedMarkdownTableView(table: table, baseFont: font, maximumWidth: 680,
            linkActivation: .singleClick, palette: .light, onLinkClick: { _ in }, onEdit: { _ in }, layoutStrategy: measured)
        for _ in 0..<10 { XCTAssertFalse(view.updateMaximumWidth(680)) }
        XCTAssertEqual(measured.calls, 1, "Repeated overlay layout must reuse unchanged content measurements")
        let edited = try XCTUnwrap(RenderedMarkdownEditor.plan(for: source.replacingOccurrences(of: "value", with: "one<br>two<br>three")).tables.first)
        let oldHeight = view.renderedSize.height
        view.update(table: edited, onEdit: { _ in })
        XCTAssertTrue(view.updateMaximumWidth(680))
        XCTAssertGreaterThan(view.renderedSize.height, oldHeight, "Cell soft breaks must still invalidate row heights")
        XCTAssertEqual(measured.calls, 2)
        XCTAssertTrue(view.updateMaximumWidth(320))
        XCTAssertEqual(measured.calls, 3, "Window resizing must invalidate cached widths")
    }

    @MainActor
    func testRenderedTableOverlaySurvivesUnrelatedProseTyping() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let firstPlan = RenderedMarkdownEditor.plan(for: source)
        let firstTable = try XCTUnwrap(firstPlan.tables.first)
        let mounted = try XCTUnwrap(
            session.textView.renderedTable(
                atUTF16Location: firstTable.sourceRange.utf16Range.location
            )
        )

        session.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        _ = await session.deriveContent(
            for: session.textView.string,
            configuration: .default
        )
        await settleRenderedPresentation()
        let updatedSource = session.textView.string
        let updatedTable = try XCTUnwrap(RenderedMarkdownEditor.plan(for: updatedSource).tables.first)
        let retained = try XCTUnwrap(
            session.textView.renderedTable(
                atUTF16Location: updatedTable.sourceRange.utf16Range.location
            )
        )

        XCTAssertTrue(mounted === retained, "unrelated typing must not rebuild the table overlay")
        XCTAssertTrue(session.renderedAttributePatchRanges.allSatisfy { NSMaxRange($0) <= 7 },
            "Typing in the first paragraph must not rewrite the unchanged table's attributes")

    }

    @MainActor
    func testFencedCodeRendersUntilCaretRequestsItsSource() async throws {
        let source = "Before\n\n```swift\nprint(1)\n```\n\nAfter"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let block = try XCTUnwrap(plan.localSourceBlocks.first { $0.reasons == [.fencedCode] })
        let opening = block.sourceRange.utf16Range.location
        let body = (source as NSString).range(of: "print(1)").location
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
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
        XCTAssertEqual(session.textView.renderedCodeBlockRanges.count, 1)
        XCTAssertTrue(
            NSLocationInRange(body, try XCTUnwrap(session.textView.renderedCodeBlockRanges.first))
        )
        let codeParagraph = try XCTUnwrap(
            storage.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(
            codeParagraph.headIndent,
            MarkdownRenderMetrics.tableCellHorizontalPadding,
            accuracy: 0.001
        )
        XCTAssertEqual(
            codeParagraph.lineHeightMultiple,
            MarkdownRenderMetrics.codeBlockLineHeight,
            accuracy: 0.001
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
        XCTAssertEqual(session.textView.renderedCodeBlockRanges.count, 1)
        XCTAssertTrue(NSLocationInRange(body, try XCTUnwrap(session.textView.renderedCodeBlockRanges.first)))
        XCTAssertLessThan(try XCTUnwrap(storage.attribute(.font, at: opening, effectiveRange: nil) as? NSFont).pointSize, 1)
        session.textView.setSelectedRange(NSRange(location: opening + 3, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        XCTAssertEqual(session.textView.renderedCodeBlockRanges, [plan.localSourceBlocks[0].sourceRange.utf16Range])
        XCTAssertGreaterThan(try XCTUnwrap(storage.attribute(.font, at: opening, effectiveRange: nil) as? NSFont).pointSize, 1)
    }

    @MainActor
    func testRenderedCaretTypingFontMatchesTheVisibleText() async throws {
        let source = "# 同一基线"
        let location = (source as NSString).range(of: "同").location
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
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
    func testRenderedCaretAtHeadingEndSkipsHiddenMarkersAndNewline() async throws {
        let source = "# **同一基线**\n下一段"
        let insertion = (source as NSString).range(of: "\n").location
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.textView.setSelectedRange(NSRange(location: insertion, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let font = try XCTUnwrap(session.textView.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(
            font.pointSize,
            CGFloat(
                SourceEditorAppearance.default.fontSize
                    * MarkdownRenderMetrics.heading(level: 1).scale
            ),
            accuracy: 0.001
        )
        let rect = RenderedMarkdownCaretStyleResolver.adjustedInsertionRect(
            NSRect(x: 10, y: 10, width: 1, height: 40),
            font: font
        )
        XCTAssertEqual(rect.midY, 30, accuracy: 0.001)
        XCTAssertEqual(rect.height, ceil(font.ascender - font.descender + font.leading))

        let baselineRect = RenderedMarkdownCaretStyleResolver.adjustedInsertionRect(
            NSRect(x: 10, y: 10, width: 1, height: 40),
            font: font,
            baselineY: 50
        )
        XCTAssertEqual(baselineRect.minY, 50 - font.ascender, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(baselineRect.height, ceil(font.ascender - font.descender + font.leading))
        let tiny = RenderedMarkdownCaretStyleResolver.adjustedInsertionRect(NSRect(x: 10, y: 100, width: 1, height: 1), font: font)
        XCTAssertEqual(tiny.height, baselineRect.height, "A temporarily collapsed native line must not shrink the caret")

        for initial in ["正文", "# 标题", "> 引用", "- 列表", "- [ ] 任务", "**粗体**", "`代码`", "$$x$$"] {
            let editor = MarkdownSourceEditorSession()
            editor.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            editor.textView.string = initial
            _ = await editor.deriveContent(for: initial, configuration: .default)
            editor.setPresentation(.rendered, source: initial, onLinkClick: nil)
            editor.textView.setSelectedRange(NSRange(location: initial.utf16.count, length: 0))
            editor.textView.insertNewline(nil)
            let changed = editor.textView.string
            XCTAssertEqual(editor.textView.selectedRange().location, changed.utf16.count)
            _ = await editor.deriveContent(for: changed, configuration: .default)
            editor.setPresentation(.rendered, source: changed, onLinkClick: nil)
            let manager = try XCTUnwrap(editor.textView.layoutManager)
            let container = try XCTUnwrap(editor.textView.textContainer)
            manager.ensureLayout(for: container)
            let nativeLine = changed.hasSuffix("\n") ? manager.extraLineFragmentRect
                : manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: changed.utf16.count - 1), effectiveRange: nil)
            let nativeCaret = NSRect(x: nativeLine.minX + editor.textView.textContainerOrigin.x,
                y: nativeLine.minY + editor.textView.textContainerOrigin.y, width: 1, height: nativeLine.height)
            let drawn = editor.textView.renderedInsertionRect(nativeCaret)
            XCTAssertEqual(drawn.midY, nativeCaret.midY, accuracy: 0.001, initial)
            XCTAssertGreaterThan(drawn.height, 10, initial)
            XCTAssertGreaterThan(nativeLine.minY, 0, initial)
            XCTAssertEqual(editor.textView.selectedRange().location, changed.utf16.count)
        }
        for initial in ["正文", "# 标题"] {
            let editor = MarkdownSourceEditorSession()
            editor.textView.string = initial + "\n\n后续段落"
            _ = await editor.deriveContent(for: editor.textView.string, configuration: .default)
            editor.setPresentation(.rendered, source: editor.textView.string, onLinkClick: nil)
            editor.textView.setSelectedRange(NSRange(location: initial.utf16.count, length: 0))
            for _ in 0..<3 {
                editor.textView.insertNewline(nil)
                let caret = editor.textView.selectedRange()
                _ = await editor.deriveContent(for: editor.textView.string, configuration: .default)
                editor.setPresentation(.rendered, source: editor.textView.string, onLinkClick: nil)
                let typingFont = try XCTUnwrap(editor.textView.typingAttributes[.font] as? NSFont)
                XCTAssertEqual(typingFont.pointSize, CGFloat(editor.sourceAppearance.fontSize), accuracy: 0.1)
                let paragraph = try XCTUnwrap(editor.textView.textStorage?.attribute(.paragraphStyle, at: caret.location, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertGreaterThanOrEqual(paragraph.minimumLineHeight, typingFont.pointSize * 1.5)
                XCTAssertEqual(editor.textView.selectedRange(), caret)
            }
        }
    }

    @MainActor
    func testQuoteContinuationKeepsOneBarAndStylesEmptyLines() async throws {
        for source in ["> 第一行\n> 第二行\n> ", "> 第一行\n后续行\n> ", "> "] {
            let session = MarkdownSourceEditorSession()
            session.textView.string = source
            _ = await session.deriveContent(for: source, configuration: .default)
            session.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            session.setPresentation(.rendered, source: source, onLinkClick: nil)
            XCTAssertEqual(session.textView.renderedQuoteRanges, [NSRange(location: 0, length: source.utf16.count)])
            let storage = try XCTUnwrap(session.textView.textStorage)
            var location = 0
            while location < storage.length {
                let line = (source as NSString).lineRange(for: NSRange(location: location, length: 0))
                let paragraph = try XCTUnwrap(storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertEqual(paragraph.headIndent, 16, source)
                XCTAssertGreaterThan(paragraph.minimumLineHeight, 20, source)
                location = NSMaxRange(line)
            }
            let font = try XCTUnwrap(session.textView.typingAttributes[.font] as? NSFont)
            XCTAssertEqual(font.pointSize, session.textView.renderedReplacementBaseFont.pointSize)
            XCTAssertEqual(session.textView.typingAttributes[.foregroundColor] as? NSColor,
                MarkdownRenderPalette.resolved(for: session.textView.effectiveAppearance).secondaryTextColor)
            session.textView.insertText("新增", replacementRange: session.textView.selectedRange())
            XCTAssertEqual(session.textView.string, source + "新增")
        }
        let separated = "> 第一块\n\n> 第二块"
        let session = MarkdownSourceEditorSession()
        session.textView.string = separated
        _ = await session.deriveContent(for: separated, configuration: .default)
        session.setPresentation(.rendered, source: separated, onLinkClick: nil)
        XCTAssertEqual(session.textView.renderedQuoteRanges.count, 2, "Separate quote blocks must retain their gap")
    }

    @MainActor
    func testTableAndParagraphCaretsShareFontHeightAndLineCentre() async throws {
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let source = "| A | B |\n| --- | --- |\n| | |"
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let table = try XCTUnwrap(session.textView.renderedTable(atUTF16Location: 0))
        let cells = table.subviews.compactMap { $0 as? RenderedMarkdownTableCellTextView }
        let cell = try XCTUnwrap(cells.last)
        let font = try XCTUnwrap(cell.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, session.textView.renderedReplacementBaseFont.pointSize)
        let oldHeight = table.renderedSize.height
        cell.insertText("文字", replacementRange: NSRange(location: 0, length: 0))
        cell.insertLineBreak(nil)
        XCTAssertEqual(cell.string, "文字\n")
        XCTAssertGreaterThan(table.renderedSize.height, oldHeight)
        let manager = try XCTUnwrap(cell.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(cell.textContainer))
        let line = manager.extraLineFragmentRect
        let caret = cell.renderedInsertionRect(NSRect(x: 3, y: 0, width: 1, height: 1))
        XCTAssertEqual(caret.height, ceil(font.ascender - font.descender + font.leading))
        XCTAssertEqual(caret.midY, cell.textContainerOrigin.y + line.midY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(caret.maxY, cell.bounds.height, "The trailing empty line and caret must fit in the cell")
        let paragraph = MarkdownSourceEditorSession()
        paragraph.textView.string = "正文\n"
        _ = await paragraph.deriveContent(for: paragraph.textView.string, configuration: .default)
        paragraph.setPresentation(.rendered, source: paragraph.textView.string, onLinkClick: nil)
        paragraph.textView.setSelectedRange(NSRange(location: paragraph.textView.string.utf16.count, length: 0))
        let paragraphManager = try XCTUnwrap(paragraph.textView.layoutManager)
        paragraphManager.ensureLayout(for: try XCTUnwrap(paragraph.textView.textContainer))
        let bodyCaret = paragraph.textView.renderedInsertionRect(NSRect(x: 3, y: 0, width: 1, height: 1))
        XCTAssertEqual(bodyCaret.height, caret.height)
        XCTAssertEqual(bodyCaret.midY, paragraph.textView.textContainerOrigin.y + paragraphManager.extraLineFragmentRect.midY, accuracy: 0.001)
    }

    @MainActor
    func testLongChineseBlockQuoteUsesRenderedTypographyWithoutExposingMarker() async throws {
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
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let storage = try XCTUnwrap(session.textView.textStorage)
        assertVisuallyHidden(NSRange(location: 0, length: 2), in: storage)
        let contentLocation = (source as NSString).range(of: "接手文件").location
        let color = try XCTUnwrap(
            storage.attribute(.foregroundColor, at: contentLocation, effectiveRange: nil)
                as? NSColor
        )
        XCTAssertEqual(
            color,
            MarkdownRenderPalette.resolved(
                for: session.textView.effectiveAppearance
            ).secondaryTextColor
        )
        XCTAssertEqual(session.textView.renderedQuoteRanges.count, 1)
        XCTAssertEqual(
            session.textView.renderedQuoteRanges.first,
            (source as NSString).paragraphRange(for: NSRange(location: 0, length: 1))
        )
        let paragraph = try XCTUnwrap(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.headIndent, 16, accuracy: 0.001)
        XCTAssertEqual(paragraph.paragraphSpacingBefore, 0, accuracy: 0.001)
        XCTAssertEqual(paragraph.paragraphSpacing, 0, accuracy: 0.001)
        XCTAssertTrue(session.textView.isRenderedCharacterSuppressed(at: 0))
        XCTAssertTrue(session.textView.isRenderedCharacterSuppressed(at: 1))

        let font = try XCTUnwrap(
            storage.attribute(.font, at: contentLocation, effectiveRange: nil) as? NSFont
        )
        let lineFragment = NSRect(x: 0, y: 6, width: 400, height: 32)
        let baselineOffset = CGFloat(23)
        let bar = RenderedMarkdownQuoteGeometry.barRect(
            lineFragment: lineFragment,
            textContainerOrigin: NSPoint(x: 12, y: 14),
            font: font,
            baselineOffset: baselineOffset
        )
        XCTAssertEqual(
            bar.minY,
            14 + lineFragment.minY + baselineOffset - font.ascender,
            accuracy: 0.001
        )
        XCTAssertEqual(
            bar.height,
            font.ascender - font.descender,
            accuracy: 0.001
        )

        session.textView.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let darkColor = try XCTUnwrap(
            storage.attribute(.foregroundColor, at: contentLocation, effectiveRange: nil)
                as? NSColor
        )
        XCTAssertEqual(darkColor, MarkdownRenderPalette.dark.secondaryTextColor)
        XCTAssertEqual(session.textView.string, source)
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
        _ = await session.deriveContent(for: source, configuration: .default)
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
    func testRenderedSessionReappliesPresentationAfterSourceAppearanceChanges() async throws {
        let source = "# Title\n\nBody\n"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let initialPassCount = session.renderedPresentationPassCount
        _ = await session.deriveContent(for: source, configuration: .default)
        XCTAssertEqual(
            session.renderedPresentationPassCount,
            initialPassCount,
            "duplicate open notifications must not flash the editable rendered surface"
        )

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
        XCTAssertEqual(
            reappliedFont.pointSize,
            CGFloat(19 * MarkdownRenderMetrics.heading(level: 1).scale),
            accuracy: 0.001
        )
        XCTAssertEqual(paragraphStyle.minimumLineHeight, reappliedFont.pointSize * MarkdownRenderMetrics.headingLineHeight(level: 1), accuracy: 0.001)

        session.setPresentation(
            .rendered,
            source: source,
            onLinkClick: nil,
            theme: .code
        )
        let bodyLocation = try XCTUnwrap((source as NSString).range(of: "Body").nonEmptyLocation)
        let codeThemeBodyFont = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: bodyLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertTrue(codeThemeBodyFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertFalse(session.scrollView.hasVerticalRuler)
        XCTAssertEqual(Data(session.textView.string.utf8), Data(source.utf8))
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
    }

    @MainActor
    func testRenderedModeUsesViewportWrappingAndRestoresSourcePreference() async {
        let source = "A long line that should use the rendered viewport instead of a horizontal canvas."
        let session = MarkdownSourceEditorSession()
        let appearance = SourceEditorAppearance(
            fontSize: 15,
            lineHeight: 1.55,
            spellingEnabled: true,
            wrapsLines: false,
            showsLineNumbers: false
        )
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        session.textView.string = source
        session.applySourceAppearance(appearance)
        XCTAssertFalse(session.textView.textContainer?.widthTracksTextView == true)

        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        XCTAssertTrue(session.textView.textContainer?.widthTracksTextView == true)
        XCTAssertFalse(session.scrollView.hasHorizontalScroller)

        session.setPresentation(.source, source: source, onLinkClick: nil)
        XCTAssertFalse(session.textView.textContainer?.widthTracksTextView == true)
        XCTAssertTrue(session.scrollView.hasHorizontalScroller)
    }

    @MainActor
    func testWideMermaidDiagramFitsAndRespondsToViewport() async throws {
        let source = """
        ```mermaid
        flowchart LR
        A --> B
        B --> C
        C --> D
        D --> E
        E --> F
        ```
        """
        let plan = try await resolvedDiagramPlan(for: source)
        let diagram = try XCTUnwrap(plan.mermaidDiagrams.first)
        XCTAssertGreaterThan(diagram.intrinsicWidth, 360)
        XCTAssertGreaterThan(diagram.intrinsicHeight, 0)

        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 360, height: 280)
        session.scrollView.layoutSubtreeIfNeeded()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        await session.waitForRenderedResources()
        let location = diagram.sourceRange.utf16Range.location
        let narrow = try XCTUnwrap(session.textView.renderedImageSize(atUTF16Location: location))
        XCTAssertLessThan(narrow.width, CGFloat(diagram.intrinsicWidth))
        XCTAssertLessThanOrEqual(narrow.width, session.scrollView.contentSize.width)
        XCTAssertEqual(
            narrow.width / narrow.height,
            CGFloat(diagram.intrinsicWidth) / CGFloat(diagram.intrinsicHeight),
            accuracy: 0.01
        )

        session.scrollView.setFrameSize(NSSize(width: 640, height: 280))
        session.scrollView.layoutSubtreeIfNeeded()
        session.textView.setFrameSize(
            NSSize(width: session.scrollView.contentSize.width, height: session.textView.frame.height)
        )
        await settleRenderedPresentation()
        let wide = try XCTUnwrap(session.textView.renderedImageSize(atUTF16Location: location))
        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertLessThanOrEqual(wide.width, session.scrollView.contentSize.width)
        XCTAssertLessThanOrEqual(wide.width, CGFloat(diagram.intrinsicWidth))

        session.scrollView.setFrameSize(NSSize(width: 1_200, height: 420))
        session.scrollView.layoutSubtreeIfNeeded()
        session.textView.setFrameSize(
            NSSize(width: session.scrollView.contentSize.width, height: session.textView.frame.height)
        )
        await settleRenderedPresentation()
        let fullWidth = try XCTUnwrap(
            session.textView.renderedImageSize(atUTF16Location: location)
        )
        XCTAssertEqual(fullWidth.width, CGFloat(diagram.intrinsicWidth), accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(fullWidth.width, wide.width)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.scrollView
        defer { window.makeFirstResponder(nil); window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(session.textView))
        session.textView.setSelectedRange(NSRange(location: 20, length: 0))
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        await settleRenderedPresentation()
        let imageView = try XCTUnwrap(session.textView.subviews.compactMap { $0 as? NSImageView }.first)
        let manager = try XCTUnwrap(session.textView.layoutManager)
        let anchor = source.utf16.count - 1
        let glyph = manager.glyphIndexForCharacter(at: anchor)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = try XCTUnwrap(session.textView.textStorage?.attribute(.font, at: anchor, effectiveRange: nil) as? NSFont)
        let textBottom = session.textView.textContainerOrigin.y + line.minY + manager.location(forGlyphAt: glyph).y - font.descender
        XCTAssertEqual(imageView.frame.minY - textBottom, 10, accuracy: 1,
            "Preview starts below the visible closing fence, excluding reserved paragraph spacing")
    }

    @MainActor
    func testSmallMermaidUsesIntrinsicSizeWithoutCreatingViewportWhitespace() async throws {
        let source = "```mermaid\nflowchart LR\nA[开始] --> B[结束]\n```\n\n正文"
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        session.scrollView.layoutSubtreeIfNeeded()
        session.textView.string = source
        let derivedContent = await session.deriveContent(
            for: source,
            configuration: .default
        )
        let content = try XCTUnwrap(derivedContent)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        await session.waitForRenderedResources()
        let resolved = try await resolvedDiagramPlan(for: source)
        let diagram = try XCTUnwrap(resolved.mermaidDiagrams.first)
        let size = try XCTUnwrap(
            session.textView.renderedImageSize(
                atUTF16Location: diagram.sourceRange.utf16Range.location
            )
        )

        XCTAssertEqual(size.width, CGFloat(diagram.intrinsicWidth), accuracy: 0.001)
        XCTAssertEqual(size.height, CGFloat(diagram.intrinsicHeight), accuracy: 0.001)
        let paragraph = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .paragraphStyle,
                at: diagram.sourceRange.utf16Range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertLessThanOrEqual(paragraph.minimumLineHeight, size.height + 10.001)
    }

    @MainActor
    func testInlineCodeDelimitersCollapseWithoutDistortingCodeTypography() async throws {
        let source = "前缀 `inline code` 后缀"
        let plan = RenderedMarkdownEditor.plan(for: source)
        let markers = plan.markers.filter { $0.kind == .inlineCode }
        XCTAssertEqual(markers.count, 2)

        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let storage = try XCTUnwrap(session.textView.textStorage)
        let contentLocation = (source as NSString).range(of: "inline code").location
        let contentFont = try XCTUnwrap(
            storage.attribute(.font, at: contentLocation, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(contentFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        let contentBackground = storage.attribute(
            .backgroundColor,
            at: contentLocation,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(contentBackground?.alphaComponent ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(
            session.textView.renderedInlineCodeRanges,
            [NSRange(location: contentLocation, length: "inline code".utf16.count)]
        )

        for marker in markers {
            let location = marker.sourceRange.utf16Range.location
            let font = try XCTUnwrap(
                storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            )
            let kern = try XCTUnwrap(
                storage.attribute(.kern, at: location, effectiveRange: nil) as? NSNumber
            )
            XCTAssertLessThan(font.pointSize, 1)
            XCTAssertEqual(
                kern.doubleValue,
                Double(MarkdownRenderMetrics.inlineCodeHorizontalPadding - 0.1),
                accuracy: 0.001
            )
            XCTAssertTrue(session.textView.isRenderedCharacterSuppressed(at: location))
            let markerBackground = storage.attribute(
                .backgroundColor,
                at: location,
                effectiveRange: nil
            ) as? NSColor
            XCTAssertEqual(markerBackground?.alphaComponent ?? 0, 0, accuracy: 0.001)
        }
        let proseBackground = storage.attribute(
            .backgroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(proseBackground?.alphaComponent ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(session.textView.string, source)
    }

    @MainActor
    func testInlineCodeBackgroundTracksTheGlyphBaselineInsteadOfTheLineBox() async throws {
        let source = "统一状态为：`草稿`、`待评审`。"
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 520, height: 120)
        session.textView.frame = NSRect(x: 0, y: 0, width: 520, height: 120)
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let storage = try XCTUnwrap(session.textView.textStorage)
        let layoutManager = try XCTUnwrap(session.textView.layoutManager)
        let textContainer = try XCTUnwrap(session.textView.textContainer)
        let codeRange = (source as NSString).range(of: "草稿")
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: codeRange,
            actualCharacterRange: nil
        )
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let lineFragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        let font = try XCTUnwrap(
            storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        )
        let baselineOffset = layoutManager.location(forGlyphAt: glyphRange.location).y
        let background = RenderedMarkdownInlineCodeGeometry.backgroundRect(
            glyphRect: glyphRect,
            lineFragment: lineFragment,
            textContainerOrigin: session.textView.textContainerOrigin,
            font: font,
            baselineOffset: baselineOffset
        )
        let textTop = session.textView.textContainerOrigin.y
            + lineFragment.minY
            + baselineOffset
            - font.ascender

        XCTAssertEqual(
            background.minY + MarkdownRenderMetrics.inlineCodeVerticalPadding,
            textTop,
            accuracy: 0.001
        )
        XCTAssertEqual(
            background.height,
            ceil(font.ascender - font.descender)
                + MarkdownRenderMetrics.inlineCodeVerticalPadding * 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            background.minX,
            session.textView.textContainerOrigin.x
                + glyphRect.minX
                - MarkdownRenderMetrics.inlineCodeHorizontalPadding,
            accuracy: 0.001
        )
        XCTAssertLessThan(background.height, lineFragment.height)
    }

    @MainActor
    func testSingleLineChineseBlockQuoteBarAlignsWithVisibleTextBaseline() async throws {
        let source = "> 接手文件"
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        session.textView.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let storage = try XCTUnwrap(session.textView.textStorage)
        let layoutManager = try XCTUnwrap(session.textView.layoutManager)
        let contentLocation = (source as NSString).range(of: "接手文件").location
        let font = try XCTUnwrap(
            storage.attribute(.font, at: contentLocation, effectiveRange: nil) as? NSFont
        )
        let glyph = layoutManager.glyphIndexForCharacter(at: contentLocation)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: storage.length))
        let lineFragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyph,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        let baselineOffset = layoutManager.location(forGlyphAt: glyph).y
        let bar = RenderedMarkdownQuoteGeometry.barRect(
            lineFragment: lineFragment,
            textContainerOrigin: session.textView.textContainerOrigin,
            font: font,
            baselineOffset: baselineOffset
        )
        let expectedTextTop = session.textView.textContainerOrigin.y
            + lineFragment.minY
            + baselineOffset
            - font.ascender

        XCTAssertEqual(bar.minY, expectedTextTop, accuracy: 0.001)
        XCTAssertEqual(
            bar.maxY,
            expectedTextTop + font.ascender - font.descender,
            accuracy: 0.001
        )
        XCTAssertEqual(
            bar.minX,
            session.textView.textContainerOrigin.x + lineFragment.minX + 4,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(bar.minY, session.textView.textContainerOrigin.y + lineFragment.minY)
        XCTAssertLessThanOrEqual(
            bar.maxY,
            session.textView.textContainerOrigin.y + lineFragment.maxY + 1
        )
    }

    @MainActor
    func testRenderedSessionRendersStructuralMarkersWithoutLeakingQuoteSource() async throws {
        let source = "> quote\n- item\n1. ordered\n- [x] done\n\nparagraph **bold**"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
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
        XCTAssertLessThan(quoteFont.pointSize, 1)
        XCTAssertTrue(session.textView.isRenderedCharacterSuppressed(at: quoteLocation))
        assertVisuallyHidden(
            NSRange(location: quoteLocation, length: 2),
            in: session.textView.textStorage,
            message: "quote source marker must be hidden without shrinking the caret"
        )

        let orderedLocation = try XCTUnwrap(
            (source as NSString).range(of: "1. ").nonEmptyLocation
        )
        let orderedFont = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: orderedLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertEqual(
            orderedFont.pointSize,
            CGFloat(SourceEditorAppearance.default.fontSize),
            accuracy: 0.001,
            "ordered marker should use the body type size"
        )
        let orderedColor = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .foregroundColor,
                at: orderedLocation,
                effectiveRange: nil
            ) as? NSColor
        )
        XCTAssertEqual(
            orderedColor,
            MarkdownRenderPalette.resolved(for: session.textView.effectiveAppearance).textColor
        )
        let orderedRange = (source as NSString).range(of: "1. ")
        let orderedKern = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .kern,
                at: NSMaxRange(orderedRange) - 1,
                effectiveRange: nil
            ) as? NSNumber
        )
        XCTAssertEqual(
            CGFloat(truncating: orderedKern),
            MarkdownRenderMetrics.listMarkerExtraSpacing,
            accuracy: 0.001
        )
        let bulletFont = RenderedMarkdownMarkerTypography.font(
            for: .unorderedList,
            baseFont: orderedFont
        )
        XCTAssertEqual(
            bulletFont.pointSize,
            orderedFont.pointSize * MarkdownRenderMetrics.unorderedListMarkerScale,
            accuracy: 0.001
        )
        let markerLine = NSRect(x: 0, y: 8, width: 400, height: 32)
        let contentBaselineOffset = CGFloat(23)
        let bulletOriginY = RenderedMarkdownMarkerTypography.originY(
            for: .unorderedList,
            font: bulletFont,
            baseFont: orderedFont,
            lineRect: markerLine,
            baselineOffset: contentBaselineOffset
        )
        XCTAssertEqual(
            bulletOriginY + bulletFont.ascender,
            markerLine.minY + contentBaselineOffset,
            accuracy: 0.001,
            "the symbol baseline must match the following list text"
        )
        let unorderedMarker = try XCTUnwrap(
            session.textView.renderedReplacementMarkers.first { $0.kind == .unorderedList }
        )
        let unorderedKern = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .kern,
                at: unorderedMarker.sourceRange.utf16Range.location,
                effectiveRange: nil
            ) as? NSNumber
        )
        let bulletWidth = ceil(
            ("• " as NSString).size(withAttributes: [.font: bulletFont]).width
        )
        XCTAssertEqual(
            CGFloat(truncating: unorderedKern),
            bulletWidth + MarkdownRenderMetrics.listMarkerExtraSpacing,
            accuracy: 0.001
        )
        XCTAssertEqual(
            session.textView.renderedReplacementMarkers.compactMap(\.replacementText),
            ["• ", "• ", "☑ "]
        )
        for marker in RenderedMarkdownEditor.plan(for: source).markers
        where marker.replacementText != nil {
            assertVisuallyHidden(marker.sourceRange.utf16Range, in: session.textView.textStorage)
        }

        let inlineMarkerFont = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: inlineMarker.location,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertLessThan(inlineMarkerFont.pointSize, 1)
        XCTAssertTrue(session.textView.isRenderedCharacterSuppressed(at: inlineMarker.location))
        assertVisuallyHidden(
            NSRange(location: inlineMarker.location, length: 2),
            in: session.textView.textStorage,
            message: "inline Markdown delimiters must stay visually collapsed while editing"
        )
    }

    @MainActor
    func testRenderedSessionMatchesPreviewMarkersRulesLinksAndFootnotes() async throws {
        let source = """
        [link](https://example.com)

        - item
        - [x] done

        ---

        Note[^b] then[^a].

        [^a]: Alpha
        [^b]: Beta
        """
        let plan = RenderedMarkdownEditor.plan(for: source)

        let linkSuffix = try XCTUnwrap(
            plan.markers.first { $0.kind == .linkDestination }
        )
        XCTAssertEqual(
            utf8Text(linkSuffix.sourceRange, source: source),
            "(https://example.com)"
        )
        XCTAssertEqual(
            plan.markers.first { $0.kind == .unorderedList }?.replacementText,
            "• "
        )
        XCTAssertEqual(
            plan.markers.first { $0.kind == .taskList }?.replacementText,
            "☑ "
        )
        XCTAssertEqual(plan.markers.filter { $0.kind == .rule }.count, 1)
        XCTAssertEqual(
            plan.markers.filter { $0.kind == .footnoteReference }.map(\.replacementText),
            ["1", "2"]
        )
        XCTAssertEqual(
            plan.markers.filter { $0.kind == .footnoteDefinition }.map(\.replacementText),
            ["2 ", "1 "]
        )
        XCTAssertFalse(plan.markers.contains { marker in
            marker.kind == .referenceDefinition
                && utf8Text(marker.sourceRange, source: source).hasPrefix("[^")
        })

        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        XCTAssertEqual(
            session.textView.renderedReplacementMarkers.compactMap(\.replacementText),
            ["• ", "• ", "☑ ", "1", "2", "2 ", "1 "]
        )
        XCTAssertEqual(session.textView.renderedRuleRanges.count, 1)
        for marker in plan.markers where marker.replacementText != nil || marker.kind == .rule {
            assertVisuallyHidden(marker.sourceRange.utf16Range, in: session.textView.textStorage)
        }
        assertVisuallyHidden(linkSuffix.sourceRange.utf16Range, in: session.textView.textStorage)
        let alpha = (source as NSString).range(of: "Alpha")
        let alphaColor = session.textView.textStorage?.attribute(
            .foregroundColor,
            at: alpha.location,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertGreaterThan(alphaColor?.alphaComponent ?? 0, 0.9)
    }

    @MainActor
    func testRenderedSessionUsesThePreviewMathParseAndKeepsFailuresEditable() async throws {
        let source = "$x_1^2$\n\n$$\n\\frac{x}{y}\n$$\n\n$\\unknown{x}$"
        let derived = try XCTUnwrap(
            EditorEngineDerivedContent.deriveSynchronously(
                source: source,
                configuration: .default
            )
        )
        let plan = derived.nativeRenderPlan

        XCTAssertTrue(plan.contentStyles.contains { $0.kind == .inlineMath })
        XCTAssertTrue(plan.contentStyles.contains { $0.kind == .displayMath })
        XCTAssertEqual(plan.markers.filter { $0.kind == .mathDelimiter }.count, 6)
        XCTAssertEqual(plan.renderRequests.filter { $0.kind == "math" }.count, 3)
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        await session.waitForRenderedResources()
        let invalidRange = (source as NSString).range(of: "$\\unknown{x}$")
        for marker in plan.markers where marker.kind == .mathDelimiter
            && NSIntersectionRange(marker.sourceRange.utf16Range, invalidRange).length == 0 {
            assertVisuallyHidden(marker.sourceRange.utf16Range, in: session.textView.textStorage)
        }
        XCTAssertNil(session.textView.renderedImage(atUTF16Location: invalidRange.location))
        let invalidLocation = (source as NSString).range(of: "\\unknown").location
        let invalidColor = session.textView.textStorage?.attribute(
            .foregroundColor,
            at: invalidLocation,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertGreaterThan(invalidColor?.alphaComponent ?? 0, 0.8)
    }

    @MainActor
    func testRenderedSessionComposesEveryInlineStyleWithoutShrinkingHeadingText() async throws {
        let source = "# **Bold** *italic* ~~gone~~ `code` [link](https://example.com)"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
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
        let headingPointSize = CGFloat(
            SourceEditorAppearance.default.fontSize
                * MarkdownRenderMetrics.heading(level: 1).scale
        )
        XCTAssertEqual(boldFont.pointSize, headingPointSize, accuracy: 0.001)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        XCTAssertEqual(
            codeFont.pointSize,
            headingPointSize * CGFloat(MarkdownRenderMetrics.inlineCodeScale),
            accuracy: 0.001
        )
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(linkFont.pointSize, headingPointSize, accuracy: 0.001)
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
        XCTAssertEqual(underline.intValue, 0, "links should underline only while hovered")

        for marker in RenderedMarkdownEditor.plan(for: source).markers {
            let location = marker.sourceRange.utf16Range.location
            let markerFont = try XCTUnwrap(
                storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            )
            XCTAssertLessThan(markerFont.pointSize, 1)
            XCTAssertTrue(session.textView.isRenderedCharacterSuppressed(at: location))
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
        let session = MarkdownSourceEditorSession()
        session.textView.string = "plain"
        _ = await session.deriveContent(for: "plain", configuration: .default)
        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        session.textView.undoManager?.removeAllActions()
        session.setPresentation(.rendered, source: "plain", onLinkClick: nil)

        session.textView.insertText(
            " **bold**",
            replacementRange: session.textView.selectedRange()
        )
        _ = await session.deriveContent(
            for: session.textView.string,
            configuration: .default
        )
        await settleRenderedPresentation()
        XCTAssertEqual(session.textView.string, "plain **bold**")
        try assertStrongTextIsRendered(in: session, source: session.textView.string)

        session.textView.undo(nil)
        for _ in 0..<20 where session.textView.string != "plain" { await Task.yield() }
        _ = await session.deriveContent(for: "plain", configuration: .default)
        await settleRenderedPresentation()
        XCTAssertEqual(session.textView.string, "plain")

        session.textView.redo(nil)
        for _ in 0..<20 where session.textView.string != "plain **bold**" {
            await Task.yield()
        }
        _ = await session.deriveContent(
            for: "plain **bold**",
            configuration: .default
        )
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
    func testRenderedLinkPublishesHoverRangeAtItsVisibleGlyphs() async throws {
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
        _ = await session.deriveContent(for: source, configuration: .default)
        var activatedTarget: String?
        session.setPresentation(
            .rendered,
            source: source,
            onLinkClick: { activatedTarget = $0 }
        )
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
        XCTAssertTrue(
            session.textView.cursorForRenderedContent(atLocalPoint: viewPoint)
                === NSCursor.pointingHand
        )
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: session.textView.convert(viewPoint, to: nil),
                modifierFlags: [.capsLock, .command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        session.textView.mouseDown(with: click)
        XCTAssertEqual(activatedTarget, "guide.md")
        XCTAssertEqual(
            (session.textView.layoutManager?.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: link.textRange.utf16Range.location,
                effectiveRange: nil
            ) as? NSNumber)?.intValue,
            MarkdownLinkVisualStyle.hoverUnderline
        )
        XCTAssertNil(
            session.textView.layoutManager?.temporaryAttribute(
                .backgroundColor,
                atCharacterIndex: link.textRange.utf16Range.location,
                effectiveRange: nil
            )
        )
        session.textView.updateHoveredLink(atLocalPoint: NSPoint(x: -20, y: -20))
        XCTAssertNil(session.textView.hoveredLinkRange)
        XCTAssertNil(
            session.textView.layoutManager?.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: link.textRange.utf16Range.location,
                effectiveRange: nil
            )
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
        XCTAssertLessThan(markerFont.pointSize, 1)
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

extension RenderedMarkdownEditorTests {
    @MainActor
    func testContinuousTableNavigationAndCommandReturn() async throws {
        let session = MarkdownSourceEditorSession()
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        session.textView.string = source
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.scrollView
        defer { window.contentView = nil }
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let grid = try XCTUnwrap(session.textView.renderedTable(atUTF16Location: 0))
        XCTAssertTrue(grid.focusCell(row: 1, column: 1))
        var times: [Double] = []
        for index in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            (window.firstResponder as? NSTextView)?.insertTab(nil)
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let current = try XCTUnwrap(session.textView.renderedTable(atUTF16Location: 0))
            XCTAssertTrue(current === grid, "Appending rows must retain existing cell editors")
            XCTAssertEqual(current.focusedCell?.row, 2 + index / 2)
            XCTAssertEqual(current.focusedCell?.column, index % 2)
        }
        XCTAssertEqual(grid.table.rows.count, 52)
        let sorted = times.sorted()
        print("Table navigation, 100 native commands: P50=\(sorted[49])ms P95=\(sorted[94])ms (not end-to-end input latency)")
        XCTAssertTrue(grid.focusCell(row: 1, column: 1))
        let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        (window.firstResponder as? NSTextView)?.keyDown(with: command)
        let updated = try XCTUnwrap(session.textView.renderedTable(atUTF16Location: 0))
        XCTAssertEqual(updated.table.rows.count, 53)
        XCTAssertEqual(updated.focusedCell?.row, 2)
        XCTAssertEqual(updated.focusedCell?.column, 1)
        XCTAssertTrue(updated.subviews.contains { $0 is NSPopUpButton })
        let cell = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(cell.accessibilityLabel(), "第 3 行，第 2 列")
        cell.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: cell.selectedRange())
        XCTAssertFalse(session.textView.string.contains("pin"), "Uncommitted cell composition must not reach the document")
        cell.insertText("拼", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.textView.string.contains("拼"))
    }

    @MainActor
    func testSemanticParagraphAndLineBreakTransactions() async throws {
        let examples: [(String, Int, MarkdownEditingIntent, String, Int)] = [
            ("前后", 1, .paragraphBreak, "前\n\n后", 3),
            ("前后", 1, .lineBreak, "前\n后", 2),
            ("# 标题", 4, .paragraphBreak, "# 标题\n\n", 6),
            ("> 引用", 4, .paragraphBreak, "> 引用\n>\n> ", 9),
            ("> 引用", 4, .lineBreak, "> 引用\n> ", 7),
            ("> > ", 4, .paragraphBreak, "> ", 2),
            ("- 项目", 4, .lineBreak, "- 项目\n  ", 7),
            ("- [x] 项目", 8, .paragraphBreak, "- [x] 项目\n- [ ] ", 15),
            ("第一段\n\n第二段", 5, .mergeBackward, "第一段第二段", 3),
            ("```swift", 8, .paragraphBreak, "```swift\n\n```", 9),
            ("$$", 2, .paragraphBreak, "$$\n\n$$", 3),
            ("```swift\ncode\n```", 17, .paragraphBreak, "```swift\ncode\n```\n\n", 19),
        ]
        for (source, location, intent, expected, caret) in examples {
            let edit = try XCTUnwrap(MarkdownEditingTransaction.plan(intent, source: source,
                selection: NSRange(location: location, length: 0), renderPlan: RenderedMarkdownEditor.plan(for: source)), source)
            XCTAssertEqual((source as NSString).replacingCharacters(in: edit.range, with: edit.text), expected, source)
            XCTAssertEqual(edit.selection.location, caret, source)
        }
        let session = MarkdownSourceEditorSession()
        let source = "中文😀"
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        session.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        session.textView.insertNewline(nil)
        XCTAssertEqual(session.textView.string, source + "\n\n")
        _ = await session.deriveContent(for: session.textView.string, configuration: .default)
        session.textView.undo(nil)
        for _ in 0..<100 where session.textView.string != source { await Task.yield() }
        XCTAssertEqual(session.textView.string, source)
        XCTAssertEqual(session.textView.selectedRange().location, source.utf16.count)
        session.textView.insertLineBreak(nil)
        XCTAssertEqual(session.textView.string, source + "\n")
    }

    func testLiveWritingStructuralTransactions() throws {
        for (source, action, expected) in [
            ("- 项目", MarkdownWritingAction.newline, "- 项目\n- "),
            ("09. 项目", .newline, "09. 项目\n10. "),
            ("- [x] 完成", .newline, "- [x] 完成\n- [ ] "),
            ("> 引用", .newline, "> 引用\n> "),
            ("> - 项目", .newline, "> - 项目\n> - "),
            ("> - ", .newline, "> "),
            ("> > ", .newline, "> "),
            ("- ", .newline, ""),
            ("- ", .backwardDelete, ""),
            ("## ", .backwardDelete, ""),
            ("  - ", .backwardDelete, "- "),
            ("- 项目", .indent, "  - 项目"),
            ("  - 项目", .outdent, "- 项目")
        ] {
            let edit = try XCTUnwrap(MarkdownWritingRules.edit(action, source: source,
                selection: NSRange(location: source.utf16.count, length: 0)), source)
            XCTAssertEqual((source as NSString).replacingCharacters(in: edit.range, with: edit.text), expected)
            XCTAssertLessThanOrEqual(NSMaxRange(edit.selection), expected.utf16.count)
        }
        let selected = "- 一\n- 二\n正文"
        let indent = try XCTUnwrap(MarkdownWritingRules.edit(.indent, source: selected, selection: NSRange(location: 0, length: 8)))
        XCTAssertEqual((selected as NSString).replacingCharacters(in: indent.range, with: indent.text), "  - 一\n  - 二\n正文")
        XCTAssertNil(MarkdownWritingRules.edit(.newline, source: "正文", selection: NSRange(location: 2, length: 0)))
        XCTAssertNil(MarkdownWritingRules.edit(.newline, source: "- 选区", selection: NSRange(location: 2, length: 2)))
        let middle = try XCTUnwrap(MarkdownWritingRules.edit(.newline, source: "- 前后", selection: NSRange(location: 3, length: 0)))
        XCTAssertEqual(("- 前后" as NSString).replacingCharacters(in: middle.range, with: middle.text), "- 前\n- 后")
    }

    @MainActor
    func testLiveWritingPairsAndProtectedBlocks() throws {
        let session = MarkdownSourceEditorSession()
        let view = session.textView
        view.string = ""
        session.setPresentation(.rendered, source: "", onLinkClick: nil)
        view.insertText("(", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "()")
        XCTAssertEqual(view.selectedRange().location, 1)
        view.insertText("中文😀", replacementRange: view.selectedRange())
        view.insertText(")", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "(中文😀)")
        XCTAssertEqual(view.selectedRange().location, view.string.utf16.count)
        view.string = "()"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "")
        view.string = "中文😀"
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.insertText("*", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "*中文😀*")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 4))
        view.markdownAutoPairEnabled = false
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("(", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "(")
        view.markdownAutoPairEnabled = true
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<3 { view.insertText("`", replacementRange: view.selectedRange()) }
        XCTAssertEqual(view.string, "```", "Auto pairing must not interfere with opening a fenced block")
        view.string = "```swift\n  first\n  second\n```"
        let body = (view.string as NSString).range(of: "  first\n  second\n")
        let plan = RenderedMarkdownEditor.plan(for: view.string)
        XCTAssertNil(RenderedMarkdownEditor.sourceEditingBlockRange(containingUTF16Location: body.location + 2, source: view.string, plan: plan))
        view.setSelectedRange(body)
        view.insertTab(nil)
        XCTAssertEqual(view.string, "```swift\n      first\n      second\n```")
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "```swift\n  first\n  second\n```")
        view.setSelectedRange(NSRange(location: body.location + 7, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "```swift\n  first\n  \n  second\n```")
        view.string = "```text\n- code\n```"
        view.setSelectedRange(NSRange(location: 14, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "```text\n- code\n\n```")
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setMarkedText("(", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "(", "IME composition must not generate a closing delimiter")
        view.insertText("（", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "（")
        session.setPresentation(.source, source: "- plain", onLinkClick: nil)
        view.string = "- plain"
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- plain\n")
        XCTAssertFalse(RenderedMarkdownLinkActivation.shouldNavigate(for: [], preference: .singleClick, isEditing: true))
        XCTAssertTrue(RenderedMarkdownLinkActivation.shouldNavigate(for: [.command], preference: .singleClick, isEditing: true))
        XCTAssertFalse(RenderedMarkdownLinkActivation.shouldNavigate(for: [.command], preference: .contextMenu, isEditing: true))
    }

    @MainActor
    func testLiveWritingReturnUndoRestoresSourceAndCaret() async throws {
        let session = MarkdownSourceEditorSession()
        let source = "- 中文😀"
        session.textView.string = source
        _ = await session.deriveContent(for: source, configuration: .default)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let caret = NSRange(location: source.utf16.count, length: 0)
        session.textView.setSelectedRange(caret)
        session.textView.insertNewline(nil)
        let changed = source + "\n- "
        XCTAssertEqual(session.textView.string, changed)
        _ = await session.deriveContent(for: changed, configuration: .default)
        session.textView.undo(nil)
        for _ in 0..<100 where session.textView.string != source { await Task.yield() }
        XCTAssertEqual(session.textView.string, source)
        XCTAssertEqual(session.textView.selectedRange(), caret)
        session.textView.redo(nil)
        for _ in 0..<100 where session.textView.string != changed { await Task.yield() }
        XCTAssertEqual(session.textView.string, changed)
    }

    @MainActor
    func testLiveWritingRevealsOnlyFocusedInlineSyntax() async throws {
        let source = "**加粗** 与 *斜体* [链接](target.md)\n"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        let derived = await session.deriveContent(for: source, configuration: .default)
        let plan = try XCTUnwrap(derived?.nativeRenderPlan)
        let bold = (source as NSString).range(of: "加粗")
        let markers = MarkdownWritingRules.revealedMarkers(plan: plan, selection: bold)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.map { (source as NSString).substring(with: $0) }, ["**", "**"])
        let link = try XCTUnwrap(plan.links.first)
        let linkMarkers = MarkdownWritingRules.revealedMarkers(plan: plan, selection: link.textRange.utf16Range)
        XCTAssertTrue(linkMarkers.contains { NSIntersectionRange($0, link.targetRange.utf16Range).length > 0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(session.textView)
        session.textView.setSelectedRange(bold)
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        for marker in markers { XCTAssertFalse(session.textView.renderedCollapsedSourceRanges.contains(marker)) }
        XCTAssertEqual(session.textView.string, source)
        let italicMarker = try XCTUnwrap(plan.markers.first { $0.kind == .emphasis })
        XCTAssertTrue(session.textView.renderedCollapsedSourceRanges.contains(italicMarker.sourceRange.utf16Range))
        let tableSource = "| 链接 |\n| --- |\n| [打开](file.md) |"
        let preview = MarkdownSourceEditorSession(role: .renderedProjection)
        preview.textView.string = tableSource
        let previewContent = await preview.deriveContent(for: tableSource, configuration: .default)
        preview.setPresentation(.rendered, source: tableSource, onLinkClick: nil)
        let tablePlan = try XCTUnwrap(previewContent?.nativeRenderPlan.tables.first)
        let tableView = try XCTUnwrap(preview.textView.renderedTable(atUTF16Location: tablePlan.sourceRange.utf16Range.location))
        let cells = tableView.subviews.compactMap { $0 as? NSTextView }
        XCTAssertFalse(cells.isEmpty)
        XCTAssertTrue(cells.allSatisfy { !$0.isEditable })

        let editing = MarkdownSourceEditorSession()
        let editableSource = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter"
        editing.textView.string = editableSource
        _ = await editing.deriveContent(for: editableSource, configuration: .default)
        window.contentView = editing.scrollView
        editing.setPresentation(.rendered, source: editableSource, onLinkClick: nil)
        let grid = try XCTUnwrap(editing.textView.renderedTable(atUTF16Location: 0))
        XCTAssertTrue(grid.focusCell(row: 0, column: 0))
        (window.firstResponder as? NSTextView)?.insertTab(nil)
        XCTAssertEqual(grid.focusedCell?.column, 1)
        (window.firstResponder as? NSTextView)?.insertBacktab(nil)
        XCTAssertEqual(grid.focusedCell?.column, 0)
        let first = try XCTUnwrap(window.firstResponder as? NSTextView)
        first.insertText("Changed", replacementRange: first.selectedRange())
        XCTAssertTrue(editing.textView.string.contains("Changed"))
        XCTAssertTrue(editing.textView.string.hasSuffix("\n\nAfter"))
        XCTAssertTrue(grid.focusCell(row: 1, column: 1))
        (window.firstResponder as? NSTextView)?.insertTab(nil)
        let changedSource = editing.textView.string
        let changedPlan = RenderedMarkdownEditor.plan(for: changedSource)
        XCTAssertEqual(changedPlan.tables.first?.rows.count, 3)
        _ = await editing.deriveContent(for: changedSource, configuration: .default)
        editing.setPresentation(.rendered, source: changedSource, onLinkClick: nil)
        let updatedGrid = try XCTUnwrap(editing.textView.renderedTable(atUTF16Location: 0))
        XCTAssertEqual(updatedGrid.focusedCell?.row, 2)
        XCTAssertEqual(updatedGrid.focusedCell?.column, 0)
        (window.firstResponder as? NSTextView)?.cancelOperation(nil)
        XCTAssertTrue(window.firstResponder === editing.textView)
        XCTAssertTrue(updatedGrid.focusCell(row: 0, column: 0))
        updatedGrid.extendCellSelection(row: 1, column: 1)
        XCTAssertEqual(updatedGrid.selectedCellTexts, [["Changed", "B"], ["1", "2"]])
        let pasteboardBefore = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(pasteboardBefore)
        }
        XCTAssertTrue(updatedGrid.handleCellClipboard("copy"))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Changed\tB\n1\t2")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("X\tY\nZ\tW", forType: .string)
        XCTAssertTrue(updatedGrid.handleCellClipboard("paste"))
        let pasted = editing.textView.string
        XCTAssertTrue(pasted.contains("| X | Y |"))
        XCTAssertTrue(pasted.contains("| Z | W |"))
        _ = await editing.deriveContent(for: pasted, configuration: .default)
        editing.setPresentation(.rendered, source: pasted, onLinkClick: nil)
        let pastedGrid = try XCTUnwrap(editing.textView.renderedTable(atUTF16Location: 0))
        XCTAssertTrue(pastedGrid.focusCell(row: 1, column: 0, selection: NSRange(location: 1, length: 0)))
        let shiftReturn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        (window.firstResponder as? NSTextView)?.keyDown(with: shiftReturn)
        XCTAssertTrue(editing.textView.string.contains("Z<br>"))
        let softBreakSource = editing.textView.string
        _ = await editing.deriveContent(for: softBreakSource, configuration: .default)
        editing.setPresentation(.rendered, source: softBreakSource, onLinkClick: nil)
        XCTAssertEqual(RenderedMarkdownEditor.plan(for: softBreakSource).tables.first?.rows[1][0].text, "Z\n")
        let softGrid = try XCTUnwrap(editing.textView.renderedTable(atUTF16Location: 0))
        XCTAssertTrue(softGrid.focusCell(row: 1, column: 0))
        (window.firstResponder as? RenderedMarkdownTableCellTextView)?.undo(nil)
        for _ in 0..<100 where editing.textView.string != pasted { await Task.yield() }
        XCTAssertEqual(editing.textView.string, pasted, "A soft break must undo as one document transaction")
        editing.textView.redo(nil)
        for _ in 0..<100 where editing.textView.string != softBreakSource { await Task.yield() }
        XCTAssertEqual(editing.textView.string, softBreakSource)
        _ = await editing.deriveContent(for: softBreakSource, configuration: .default)
        editing.setPresentation(.rendered, source: softBreakSource, onLinkClick: nil)
        let replacementGrid = try XCTUnwrap(editing.textView.renderedTable(atUTF16Location: 0))
        replacementGrid.selectCells(from: (0, 0), to: (1, 1))
        let replacementCell = try XCTUnwrap(window.firstResponder as? NSTextView)
        replacementCell.insertText("替换", replacementRange: replacementCell.selectedRange())
        XCTAssertEqual(replacementGrid.focusedCell?.row, 0)
        XCTAssertEqual(replacementGrid.focusedCell?.column, 0)
        let continuingCell = try XCTUnwrap(window.firstResponder as? NSTextView)
        continuingCell.insertText("继续", replacementRange: continuingCell.selectedRange())
        XCTAssertEqual(RenderedMarkdownEditor.plan(for: editing.textView.string).tables.first?.rows[0][0].text, "替换继续")
        XCTAssertEqual(RenderedMarkdownEditor.plan(for: editing.textView.string).tables.first?.rows[1][1].text, "")

        let scrolling = MarkdownSourceEditorSession()
        let prefix = String(repeating: "正文\n\n", count: 40)
        scrolling.textView.string = prefix + "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n结束"
        window.contentView = scrolling.scrollView
        _ = await scrolling.deriveContent(for: scrolling.textView.string, configuration: .default)
        scrolling.setPresentation(.rendered, source: scrolling.textView.string, onLinkClick: nil)
        for row in 1...3 {
            let grid = try XCTUnwrap(scrolling.textView.renderedTable(atUTF16Location: prefix.utf16.count))
            XCTAssertTrue(grid.focusCell(row: row, column: 1))
            let before = scrolling.scrollView.contentView.bounds.origin.y
            (window.firstResponder as? NSTextView)?.insertTab(nil)
            XCTAssertEqual(grid.focusedCell?.row, row + 1, "Tab must focus the added row before returning, without an async derivation")
            XCTAssertEqual(grid.focusedCell?.column, 0)
            XCTAssertLessThanOrEqual(abs(scrolling.scrollView.contentView.bounds.origin.y - before), 80)
            let updated = scrolling.textView.string
            _ = await scrolling.deriveContent(for: updated, configuration: .default)
            scrolling.setPresentation(.rendered, source: updated, onLinkClick: nil)
            await settleRenderedPresentation()
            let next = try XCTUnwrap(scrolling.textView.renderedTable(atUTF16Location: prefix.utf16.count))
            XCTAssertTrue(next === grid, "Appending a row must retain the table and its active cell editors")
            XCTAssertEqual(next.focusedCell?.row, row + 1)
            XCTAssertEqual(next.focusedCell?.column, 0)
            XCTAssertLessThanOrEqual(abs(scrolling.scrollView.contentView.bounds.origin.y - before), 80,
                "Appending one visible row must not jump to another part of the document")
        }
        let persistentGrid = try XCTUnwrap(scrolling.textView.renderedTable(atUTF16Location: prefix.utf16.count))
        let existingCells = persistentGrid.subviews.compactMap { $0 as? NSTextView }
        let fullPasses = scrolling.renderedPresentationPassCount
        for _ in 0..<6 { (window.firstResponder as? NSTextView)?.insertTab(nil) }
        XCTAssertEqual(scrolling.renderedPresentationPassCount, fullPasses, "Tab edits must not synchronously re-render the whole document")
        XCTAssertTrue(scrolling.textView.renderedTable(atUTF16Location: prefix.utf16.count) === persistentGrid)
        XCTAssertEqual(persistentGrid.focusedCell?.row, 7)
        XCTAssertEqual(persistentGrid.focusedCell?.column, 0)
        XCTAssertTrue(existingCells.allSatisfy { $0.superview === persistentGrid })





    }
}

private final class CountingTableLayoutStrategy: RenderedMarkdownTableLayoutStrategy {
    var calls = 0
    func columnWidths(for table: RenderedMarkdownTable, font: NSFont, availableWidth: CGFloat) -> [CGFloat] {
        calls += 1
        return AdaptiveRenderedMarkdownTableLayoutStrategy().columnWidths(for: table, font: font, availableWidth: availableWidth)
    }
}
