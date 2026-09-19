//! `TextKit` presentation data derived from the canonical Markdown parse.

use std::collections::{BTreeSet, HashMap};
use std::ops::Range;

use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, LinkType, Tag, TagEnd};
use serde::Serialize;

use crate::markdown_ir::{DocumentIr, LocatedEvent};
use crate::mermaid::MermaidRenderBatch;
use crate::render_ir::{RenderBlockKind, RenderIr};
use crate::{math, mermaid};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeRenderPlan {
    pub markers: Vec<NativeMarker>,
    pub content_styles: Vec<NativeContentStyle>,
    pub local_source_blocks: Vec<NativeLocalSourceBlock>,
    pub links: Vec<NativeLink>,
    pub images: Vec<NativeImage>,
    pub tables: Vec<NativeTable>,
    pub mermaid_diagrams: Vec<NativeMermaidDiagram>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeMarker {
    pub kind: MarkerKind,
    pub source_range: Range<usize>,
    pub heading_level: Option<u8>,
    pub replacement_text: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MarkerKind {
    Heading,
    Emphasis,
    Strong,
    Strikethrough,
    InlineCode,
    BlockQuote,
    UnorderedList,
    OrderedList,
    TaskList,
    TableBoundary,
    TableSeparator,
    TableDelimiterRow,
    ReferenceDefinition,
    LinkDelimiter,
    LinkDestination,
    Rule,
    FootnoteReference,
    FootnoteDefinition,
    MathDelimiter,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeContentStyle {
    pub kind: ContentStyleKind,
    pub source_range: Range<usize>,
    pub heading_level: Option<u8>,
    pub is_checked: Option<bool>,
    pub alternating: Option<bool>,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ContentStyleKind {
    Paragraph,
    Heading,
    Emphasis,
    Strong,
    Strikethrough,
    InlineCode,
    BlockQuote,
    UnorderedListItem,
    OrderedListItem,
    TaskListItem,
    TableHeader,
    TableBody,
    Link,
    InlineMath,
    DisplayMath,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeLocalSourceBlock {
    pub source_range: Range<usize>,
    pub reasons: Vec<LocalSourceReason>,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalSourceReason {
    Mermaid,
    FencedCode,
    RawHtml,
    UnsupportedSyntax,
    ComplexOrAmbiguous,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeLink {
    pub source_range: Range<usize>,
    pub text_range: Range<usize>,
    pub target_range: Range<usize>,
    pub target: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeImage {
    pub source_range: Range<usize>,
    pub alternative_range: Range<usize>,
    pub target_range: Range<usize>,
    pub alternative: String,
    pub target: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeTableAlignment {
    Leading,
    Center,
    Trailing,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeTableCellLink {
    pub visible_source_range: Range<usize>,
    pub target: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeTableCell {
    pub source_range: Range<usize>,
    pub markdown: String,
    pub text: String,
    pub links: Vec<NativeTableCellLink>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeTable {
    pub source_range: Range<usize>,
    pub alignments: Vec<NativeTableAlignment>,
    pub rows: Vec<Vec<NativeTableCell>>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NativeMermaidDiagram {
    pub source_range: Range<usize>,
    pub svg: String,
    pub intrinsic_width: usize,
    pub intrinsic_height: usize,
    pub is_placeholder: bool,
}

pub(crate) struct NativeMermaidResolution {
    pub diagrams: Vec<NativeMermaidDiagram>,
    pub failed_source_ranges: Vec<Range<usize>>,
}

#[derive(Clone)]
struct Local {
    range: Range<usize>,
    reasons: BTreeSet<LocalSourceReason>,
}

impl NativeRenderPlan {
    pub(crate) fn apply_mermaid_resolution(
        &mut self,
        diagrams: &[NativeMermaidDiagram],
        failed_source_ranges: &[Range<usize>],
    ) -> bool {
        let mut expected = self
            .mermaid_diagrams
            .iter()
            .filter(|diagram| diagram.is_placeholder)
            .map(|diagram| diagram.source_range.clone())
            .collect::<Vec<_>>();
        let mut received = diagrams
            .iter()
            .map(|diagram| diagram.source_range.clone())
            .chain(failed_source_ranges.iter().cloned())
            .collect::<Vec<_>>();
        expected.sort_by_key(|range| (range.start, range.end));
        received.sort_by_key(|range| (range.start, range.end));
        if expected != received
            || self
                .mermaid_diagrams
                .iter()
                .any(|item| !item.is_placeholder)
        {
            return false;
        }

        self.mermaid_diagrams = diagrams.to_vec();
        for failed in failed_source_ranges {
            if let Some(local) = self
                .local_source_blocks
                .iter_mut()
                .find(|local| local.source_range == *failed)
            {
                let mut reasons = local.reasons.iter().copied().collect::<BTreeSet<_>>();
                reasons.insert(LocalSourceReason::Mermaid);
                local.reasons = reasons.into_iter().collect();
            } else {
                self.local_source_blocks.push(NativeLocalSourceBlock {
                    source_range: failed.clone(),
                    reasons: vec![LocalSourceReason::Mermaid],
                });
            }
        }
        self.local_source_blocks
            .sort_by_key(|local| (local.source_range.start, local.source_range.end));
        true
    }

    #[cfg(test)]
    #[allow(clippy::too_many_lines)]
    pub fn from_document(
        document: &DocumentIr,
        render: &RenderIr,
        mermaid_enabled: bool,
        defer_mermaid: bool,
    ) -> Self {
        let mermaid =
            (mermaid_enabled && !defer_mermaid).then(|| MermaidRenderBatch::render(document));
        Self::from_document_with_mermaid(
            document,
            render,
            mermaid_enabled,
            defer_mermaid,
            mermaid.as_ref(),
        )
    }

    #[allow(clippy::too_many_lines)]
    pub(crate) fn from_document_with_mermaid(
        document: &DocumentIr,
        render: &RenderIr,
        mermaid_enabled: bool,
        defer_mermaid: bool,
        mermaid_renders: Option<&MermaidRenderBatch>,
    ) -> Self {
        let source = document.source();
        let events = document.events();
        let mut markers = Vec::new();
        let mut styles = Vec::new();
        let mut links = Vec::new();
        let mut images = Vec::new();
        let mut locals = Vec::new();
        let mut diagrams = Vec::new();
        let mut footnote_numbers = HashMap::new();
        reference_markers(source, &mut markers);
        triple_dash_fallback(source, &mut locals);
        malformed_fallback(document, &mut locals);
        let mut table_depth = 0_u32;
        for (index, located) in events.iter().enumerate() {
            let range = trim_eol(source, located.source_range.clone());
            match &located.event {
                Event::Start(Tag::Table(_)) => table_depth += 1,
                Event::End(TagEnd::Table) => table_depth = table_depth.saturating_sub(1),
                Event::Start(Tag::Heading { level, .. }) => heading(
                    source,
                    range,
                    level_number(*level),
                    &mut markers,
                    &mut styles,
                ),
                Event::Start(Tag::Paragraph) if table_depth == 0 && !range.is_empty() => {
                    styles.push(style(ContentStyleKind::Paragraph, range));
                }
                Event::Start(Tag::BlockQuote(_)) => quote(source, range, &mut markers, &mut styles),
                Event::Start(Tag::Item) => {
                    list_item(events, index, source, range, &mut markers, &mut styles);
                }
                Event::Start(Tag::FootnoteDefinition(name)) => {
                    let number = footnote_number(&mut footnote_numbers, name);
                    if let Some(prefix) = footnote_definition_prefix(source, &range) {
                        markers.push(replacement_mark(
                            MarkerKind::FootnoteDefinition,
                            prefix,
                            format!("{number} "),
                        ));
                    }
                }
                Event::Start(Tag::Strong) => wrapped(
                    range,
                    2,
                    MarkerKind::Strong,
                    ContentStyleKind::Strong,
                    &mut markers,
                    &mut styles,
                ),
                Event::Start(Tag::Emphasis) => wrapped(
                    range,
                    1,
                    MarkerKind::Emphasis,
                    ContentStyleKind::Emphasis,
                    &mut markers,
                    &mut styles,
                ),
                Event::Start(Tag::Strikethrough) => wrapped(
                    range,
                    2,
                    MarkerKind::Strikethrough,
                    ContentStyleKind::Strikethrough,
                    &mut markers,
                    &mut styles,
                ),
                Event::Code(_) => inline_code(source, range, &mut markers, &mut styles),
                Event::InlineMath(value) => math_span(
                    source,
                    range,
                    value,
                    false,
                    &mut markers,
                    &mut styles,
                    &mut locals,
                ),
                Event::DisplayMath(value) => math_span(
                    source,
                    range,
                    value,
                    true,
                    &mut markers,
                    &mut styles,
                    &mut locals,
                ),
                Event::Start(Tag::Link {
                    link_type,
                    dest_url,
                    ..
                }) => {
                    if let Some(link) =
                        link(events, index, source, range, *link_type, dest_url, false)
                    {
                        link_markers(source, &link, &mut markers);
                        styles.push(style(ContentStyleKind::Link, link.text_range.clone()));
                        links.push(link);
                    }
                }
                Event::Start(Tag::Image {
                    link_type,
                    dest_url,
                    ..
                }) => {
                    if let Some(item) =
                        link(events, index, source, range, *link_type, dest_url, true)
                    {
                        images.push(NativeImage {
                            alternative: source[item.text_range.clone()].to_owned(),
                            source_range: item.source_range,
                            alternative_range: item.text_range,
                            target_range: item.target_range,
                            target: item.target,
                        });
                    }
                }
                Event::Start(Tag::CodeBlock(kind)) => {
                    let complete = located.source_range.clone();
                    if is_mermaid(kind) {
                        if !mermaid_enabled {
                            add_local(&mut locals, complete, LocalSourceReason::Mermaid);
                            continue;
                        }
                        if defer_mermaid {
                            diagrams.push(mermaid_placeholder(complete));
                            continue;
                        }
                        let rendered = mermaid_renders
                            .and_then(|batch| batch.result(&complete))
                            .cloned()
                            .unwrap_or(Err(mermaid::MermaidError::InvalidSyntax));
                        match rendered {
                            Ok(figure) => {
                                if let Some((svg, intrinsic_width, intrinsic_height)) =
                                    extract_svg(&figure)
                                {
                                    diagrams.push(NativeMermaidDiagram {
                                        source_range: complete,
                                        svg,
                                        intrinsic_width,
                                        intrinsic_height,
                                        is_placeholder: false,
                                    });
                                }
                            }
                            Err(_) => add_local(&mut locals, complete, LocalSourceReason::Mermaid),
                        }
                    } else {
                        add_local(&mut locals, complete, LocalSourceReason::FencedCode);
                    }
                }
                Event::Start(Tag::HtmlBlock) => add_local(
                    &mut locals,
                    located.source_range.clone(),
                    LocalSourceReason::RawHtml,
                ),
                Event::FootnoteReference(name) => {
                    let number = footnote_number(&mut footnote_numbers, name);
                    markers.push(replacement_mark(
                        MarkerKind::FootnoteReference,
                        range,
                        number.to_string(),
                    ));
                }
                Event::Rule => markers.push(mark(MarkerKind::Rule, range)),
                _ => {}
            }
        }
        nested_fallback(render, &mut locals);
        let local_source_blocks = merge_locals(locals);
        let tables = tables(document, render, &links, &mut markers, &mut styles);
        markers.retain(|item| !overlaps_locals(&item.source_range, &local_source_blocks));
        styles.retain(|item| !overlaps_locals(&item.source_range, &local_source_blocks));
        links.retain(|item| !overlaps_locals(&item.source_range, &local_source_blocks));
        images.retain(|item| !overlaps_locals(&item.source_range, &local_source_blocks));
        diagrams.retain(|item| !overlaps_locals(&item.source_range, &local_source_blocks));
        let tables = tables
            .into_iter()
            .filter(|item| !overlaps_locals(&item.source_range, &local_source_blocks))
            .collect();
        markers.sort_by_key(|item| (item.source_range.start, item.source_range.end, item.kind));
        markers.dedup_by(|a, b| a.kind == b.kind && a.source_range == b.source_range);
        styles.sort_by_key(|item| (item.source_range.start, item.source_range.end, item.kind));
        styles.dedup_by(|a, b| a.kind == b.kind && a.source_range == b.source_range);
        links.sort_by_key(|item| (item.source_range.start, item.source_range.end));
        images.sort_by_key(|item| (item.source_range.start, item.source_range.end));
        Self {
            markers,
            content_styles: styles,
            local_source_blocks,
            links,
            images,
            tables,
            mermaid_diagrams: diagrams,
        }
    }
}

pub(crate) fn resolve_mermaid_from_document(document: &DocumentIr) -> NativeMermaidResolution {
    let rendered = MermaidRenderBatch::render(document);
    let mut diagrams = Vec::new();
    let mut failed_source_ranges = Vec::new();
    for located in document.events() {
        let Event::Start(Tag::CodeBlock(kind)) = &located.event else {
            continue;
        };
        if !is_mermaid(kind) {
            continue;
        }
        let source_range = located.source_range.clone();
        let Some(Ok(figure)) = rendered.result(&source_range) else {
            failed_source_ranges.push(source_range);
            continue;
        };
        let Some((svg, intrinsic_width, intrinsic_height)) = extract_svg(figure) else {
            failed_source_ranges.push(source_range);
            continue;
        };
        diagrams.push(NativeMermaidDiagram {
            source_range,
            svg,
            intrinsic_width,
            intrinsic_height,
            is_placeholder: false,
        });
    }
    NativeMermaidResolution {
        diagrams,
        failed_source_ranges,
    }
}

fn mermaid_placeholder(source_range: Range<usize>) -> NativeMermaidDiagram {
    NativeMermaidDiagram {
        source_range,
        svg: concat!(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" ",
            "width=\"640\" height=\"72\" viewBox=\"0 0 640 72\" ",
            "aria-label=\"正在渲染 Mermaid 图表\">",
            "<rect x=\"0.5\" y=\"0.5\" width=\"639\" height=\"71\" rx=\"8\" ",
            "fill=\"#f7f7f8\" stroke=\"#dfe3e8\"/>",
            "<circle cx=\"28\" cy=\"36\" r=\"7\" fill=\"#8b72e8\"/>",
            "<text x=\"48\" y=\"41\" fill=\"#737982\" font-size=\"14\" ",
            "font-family=\"-apple-system, BlinkMacSystemFont, sans-serif\">",
            "正在渲染 Mermaid 图表…</text></svg>"
        )
        .to_owned(),
        intrinsic_width: 640,
        intrinsic_height: 72,
        is_placeholder: true,
    }
}

fn mark(kind: MarkerKind, range: Range<usize>) -> NativeMarker {
    NativeMarker {
        kind,
        source_range: range,
        heading_level: None,
        replacement_text: None,
    }
}
fn replacement_mark(kind: MarkerKind, range: Range<usize>, text: String) -> NativeMarker {
    NativeMarker {
        kind,
        source_range: range,
        heading_level: None,
        replacement_text: Some(text),
    }
}
fn style(kind: ContentStyleKind, range: Range<usize>) -> NativeContentStyle {
    NativeContentStyle {
        kind,
        source_range: range,
        heading_level: None,
        is_checked: None,
        alternating: None,
    }
}

fn heading(
    source: &str,
    range: Range<usize>,
    level: u8,
    markers: &mut Vec<NativeMarker>,
    styles: &mut Vec<NativeContentStyle>,
) {
    let bytes = source.as_bytes();
    let first_end = line_end(bytes, range.start, range.end);
    let mut cursor = range.start;
    while cursor < first_end && bytes[cursor] == b' ' {
        cursor += 1;
    }
    if cursor < first_end && bytes[cursor] == b'#' {
        let opening = cursor;
        while cursor < first_end && bytes[cursor] == b'#' {
            cursor += 1;
        }
        while cursor < first_end && matches!(bytes[cursor], b' ' | b'\t') {
            cursor += 1;
        }
        markers.push(NativeMarker {
            kind: MarkerKind::Heading,
            source_range: opening..cursor,
            heading_level: Some(level),
            replacement_text: None,
        });
        let mut end = first_end;
        while end > cursor && matches!(bytes[end - 1], b' ' | b'\t') {
            end -= 1;
        }
        let mut hashes = end;
        while hashes > cursor && bytes[hashes - 1] == b'#' {
            hashes -= 1;
        }
        if hashes < end && hashes > cursor && matches!(bytes[hashes - 1], b' ' | b'\t') {
            let mut start = hashes - 1;
            while start > cursor && matches!(bytes[start - 1], b' ' | b'\t') {
                start -= 1;
            }
            markers.push(mark(MarkerKind::Heading, start..end));
            end = start;
        }
        if cursor < end {
            let mut item = style(ContentStyleKind::Heading, cursor..end);
            item.heading_level = Some(level);
            styles.push(item);
        }
    } else {
        let delimiter_start = skip_eol(bytes, first_end, range.end);
        let delimiter_end = line_end(bytes, delimiter_start, range.end);
        if range.start < first_end {
            let mut item = style(ContentStyleKind::Heading, range.start..first_end);
            item.heading_level = Some(level);
            styles.push(item);
        }
        if delimiter_start < delimiter_end {
            markers.push(NativeMarker {
                kind: MarkerKind::Heading,
                source_range: delimiter_start..delimiter_end,
                heading_level: Some(level),
                replacement_text: None,
            });
        }
    }
}

fn quote(
    source: &str,
    range: Range<usize>,
    markers: &mut Vec<NativeMarker>,
    styles: &mut Vec<NativeContentStyle>,
) {
    for line in line_ranges(source.as_bytes(), range) {
        let mut cursor = line.start;
        while cursor < line.end && matches!(source.as_bytes()[cursor], b' ' | b'\t') {
            cursor += 1;
        }
        if cursor < line.end && source.as_bytes()[cursor] == b'>' {
            let start = cursor;
            cursor += 1;
            if cursor < line.end && source.as_bytes()[cursor] == b' ' {
                cursor += 1;
            }
            markers.push(mark(MarkerKind::BlockQuote, start..cursor));
            if cursor < line.end {
                styles.push(style(ContentStyleKind::BlockQuote, cursor..line.end));
            }
        }
    }
}

fn list_item(
    events: &[LocatedEvent],
    index: usize,
    source: &str,
    range: Range<usize>,
    markers: &mut Vec<NativeMarker>,
    styles: &mut Vec<NativeContentStyle>,
) {
    let bytes = source.as_bytes();
    let end = line_end(bytes, range.start, range.end);
    let mut cursor = range.start;
    while cursor < end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    let start = cursor;
    let mut ordered = false;
    if cursor < end && bytes[cursor].is_ascii_digit() {
        ordered = true;
        while cursor < end && bytes[cursor].is_ascii_digit() {
            cursor += 1;
        }
        if cursor < end && matches!(bytes[cursor], b'.' | b')') {
            cursor += 1;
        } else {
            return;
        }
    } else if cursor < end && matches!(bytes[cursor], b'-' | b'+' | b'*') {
        cursor += 1;
    } else {
        return;
    }
    while cursor < end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    markers.push(if ordered {
        mark(MarkerKind::OrderedList, start..cursor)
    } else {
        replacement_mark(MarkerKind::UnorderedList, start..cursor, "• ".to_owned())
    });
    let task = events[index + 1..]
        .iter()
        .take_while(|event| event.source_range.start < end)
        .find_map(|event| {
            if let Event::TaskListMarker(value) = event.event {
                Some((event.source_range.clone(), value))
            } else {
                None
            }
        });
    let (kind, checked) = if let Some((task, checked)) = task {
        let mut task_end = task.end;
        while task_end < end && matches!(bytes[task_end], b' ' | b'\t') {
            task_end += 1;
        }
        markers.push(replacement_mark(
            MarkerKind::TaskList,
            task.start..task_end,
            if checked { "☑ " } else { "☐ " }.to_owned(),
        ));
        cursor = task_end;
        (ContentStyleKind::TaskListItem, Some(checked))
    } else if ordered {
        (ContentStyleKind::OrderedListItem, None)
    } else {
        (ContentStyleKind::UnorderedListItem, None)
    };
    if cursor < end {
        let mut item = style(kind, cursor..end);
        item.is_checked = checked;
        styles.push(item);
    }
}

fn wrapped(
    range: Range<usize>,
    width: usize,
    marker_kind: MarkerKind,
    style_kind: ContentStyleKind,
    markers: &mut Vec<NativeMarker>,
    styles: &mut Vec<NativeContentStyle>,
) {
    if range.end >= range.start + width * 2 {
        markers.push(mark(marker_kind, range.start..range.start + width));
        markers.push(mark(marker_kind, range.end - width..range.end));
        styles.push(style(style_kind, range.start + width..range.end - width));
    }
}

fn inline_code(
    source: &str,
    range: Range<usize>,
    markers: &mut Vec<NativeMarker>,
    styles: &mut Vec<NativeContentStyle>,
) {
    let bytes = source.as_bytes();
    let mut width = 0;
    while range.start + width < range.end && bytes[range.start + width] == b'`' {
        width += 1;
    }
    if width == 0 || range.end < range.start + width * 2 {
        return;
    }
    markers.push(mark(
        MarkerKind::InlineCode,
        range.start..range.start + width,
    ));
    markers.push(mark(MarkerKind::InlineCode, range.end - width..range.end));
    let mut content = range.start + width..range.end - width;
    if content.end > content.start + 1
        && bytes[content.start] == b' '
        && bytes[content.end - 1] == b' '
        && bytes[content.clone()].iter().any(|byte| *byte != b' ')
    {
        markers.push(mark(
            MarkerKind::InlineCode,
            content.start..content.start + 1,
        ));
        markers.push(mark(MarkerKind::InlineCode, content.end - 1..content.end));
        content = content.start + 1..content.end - 1;
    }
    if !content.is_empty() {
        styles.push(style(ContentStyleKind::InlineCode, content));
    }
}

fn math_span(
    source: &str,
    range: Range<usize>,
    value: &str,
    display: bool,
    markers: &mut Vec<NativeMarker>,
    styles: &mut Vec<NativeContentStyle>,
    locals: &mut Vec<Local>,
) {
    if math::mathml(value, display).is_err() {
        add_local(locals, range, LocalSourceReason::UnsupportedSyntax);
        return;
    }
    let Some(local) = source.get(range.clone()) else {
        return;
    };
    let Some(relative_start) = local.find(value) else {
        add_local(locals, range, LocalSourceReason::ComplexOrAmbiguous);
        return;
    };
    let content = range.start + relative_start..range.start + relative_start + value.len();
    if range.start < content.start {
        markers.push(mark(MarkerKind::MathDelimiter, range.start..content.start));
    }
    if content.end < range.end {
        markers.push(mark(MarkerKind::MathDelimiter, content.end..range.end));
    }
    styles.push(style(
        if display {
            ContentStyleKind::DisplayMath
        } else {
            ContentStyleKind::InlineMath
        },
        content,
    ));
}

fn link(
    events: &[LocatedEvent],
    index: usize,
    source: &str,
    range: Range<usize>,
    link_type: LinkType,
    target: &str,
    image: bool,
) -> Option<NativeLink> {
    if matches!(link_type, LinkType::Autolink | LinkType::Email) {
        let inner = range.start + 1..range.end.checked_sub(1)?;
        return Some(NativeLink {
            source_range: range,
            text_range: inner.clone(),
            target_range: inner,
            target: target.to_owned(),
        });
    }
    let mut range = range;
    if !matches!(link_type, LinkType::Inline)
        && source
            .as_bytes()
            .get(range.end..range.end.saturating_add(2))
            == Some(b"[]")
    {
        range.end += 2;
    }
    let local = source.get(range.clone())?;
    let bracket = local.find('[')?;
    let visible_start = range.start + bracket + 1;
    let visible_end = events[index + 1..]
        .iter()
        .take_while(|event| event.source_range.start < range.end)
        .filter(|event| matches!(event.event, Event::Text(_) | Event::Code(_)))
        .map(|event| event.source_range.end)
        .max()
        .or_else(|| {
            local[bracket + 1..]
                .find(']')
                .map(|offset| visible_start + offset)
        })?;
    let visible = visible_start..visible_end;
    let target_range = match link_type {
        LinkType::Inline => inline_target(source, &range, &visible, target)?,
        _ => visible.end..visible.end,
    };
    let _ = image;
    Some(NativeLink {
        source_range: range,
        text_range: visible,
        target_range,
        target: target.to_owned(),
    })
}

fn inline_target(
    source: &str,
    range: &Range<usize>,
    visible: &Range<usize>,
    target: &str,
) -> Option<Range<usize>> {
    let bytes = source.as_bytes();
    let mut cursor = visible.end;
    while cursor < range.end && bytes[cursor] != b'(' {
        cursor += 1;
    }
    if cursor == range.end {
        return None;
    }
    cursor += 1;
    while cursor < range.end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    if cursor < range.end && bytes[cursor] == b'<' {
        cursor += 1;
    }
    (cursor + target.len() <= range.end).then_some(cursor..cursor + target.len())
}

fn link_markers(source: &str, link: &NativeLink, markers: &mut Vec<NativeMarker>) {
    let prefix = 1 + usize::from(source.as_bytes()[link.source_range.start] == b'!');
    markers.push(mark(
        MarkerKind::LinkDelimiter,
        link.source_range.start..link.source_range.start + prefix,
    ));
    if link.text_range.end < link.source_range.end {
        markers.push(mark(
            MarkerKind::LinkDelimiter,
            link.text_range.end..link.text_range.end + 1,
        ));
    }
    if link.target_range != link.text_range && link.text_range.end + 1 < link.source_range.end {
        markers.push(mark(
            MarkerKind::LinkDestination,
            link.text_range.end + 1..link.source_range.end,
        ));
    }
}

fn tables(
    document: &DocumentIr,
    render: &RenderIr,
    links: &[NativeLink],
    markers: &mut Vec<NativeMarker>,
    styles: &mut Vec<NativeContentStyle>,
) -> Vec<NativeTable> {
    let source = document.source();
    let bytes = source.as_bytes();
    let mut output = Vec::new();
    for table in render
        .blocks
        .iter()
        .filter(|block| block.kind == RenderBlockKind::Table)
    {
        let alignments = document
            .events()
            .iter()
            .find_map(|event| {
                if event.source_range == (table.source_range.start..table.source_range.end) {
                    if let Event::Start(Tag::Table(items)) = &event.event {
                        Some(items.iter().copied().map(alignment).collect())
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .unwrap_or_default();
        let rows: Vec<_> = render
            .blocks
            .iter()
            .filter(|block| {
                block.parent_id.as_deref() == Some(&table.block_id)
                    && matches!(
                        block.kind,
                        RenderBlockKind::TableHead | RenderBlockKind::TableRow
                    )
            })
            .collect();
        let mut rendered_rows = Vec::new();
        for (index, row) in rows.iter().enumerate() {
            let row_range = trim_eol(source, row.source_range.start..row.source_range.end);
            pipes(bytes, row_range.clone(), markers);
            let mut row_style = style(
                if index == 0 {
                    ContentStyleKind::TableHeader
                } else {
                    ContentStyleKind::TableBody
                },
                row_range,
            );
            if index > 0 {
                row_style.alternating = Some(index % 2 == 0);
            }
            styles.push(row_style);
            rendered_rows.push(
                render
                    .blocks
                    .iter()
                    .filter(|cell| {
                        cell.kind == RenderBlockKind::TableCell
                            && cell.source_range.start >= row.source_range.start
                            && cell.source_range.end <= row.source_range.end
                    })
                    .map(|cell| {
                        let range =
                            trim_space(bytes, cell.source_range.start..cell.source_range.end);
                        NativeTableCell {
                            markdown: source.get(range.clone()).unwrap_or_default().to_owned(),
                            text: cell.visible_text.clone(),
                            links: links
                                .iter()
                                .filter(|link| contains(&range, &link.source_range))
                                .map(|link| NativeTableCellLink {
                                    visible_source_range: link.text_range.clone(),
                                    target: link.target.clone(),
                                })
                                .collect(),
                            source_range: range,
                        }
                    })
                    .collect(),
            );
        }
        if let Some(head) = rows.first() {
            let start = skip_eol(
                bytes,
                head.source_range.end.saturating_sub(1),
                table.source_range.end,
            );
            let end = line_end(bytes, start, table.source_range.end);
            if start < end {
                markers.push(mark(MarkerKind::TableDelimiterRow, start..end));
            }
        }
        output.push(NativeTable {
            source_range: table.source_range.start..table.source_range.end,
            alignments,
            rows: rendered_rows,
        });
    }
    output
}

fn pipes(bytes: &[u8], range: Range<usize>, markers: &mut Vec<NativeMarker>) {
    let mut escaped = false;
    for index in range.clone() {
        match bytes[index] {
            b'\\' => escaped = !escaped,
            b'|' if !escaped => markers.push(mark(
                if index == range.start || index + 1 == range.end {
                    MarkerKind::TableBoundary
                } else {
                    MarkerKind::TableSeparator
                },
                index..index + 1,
            )),
            _ => escaped = false,
        }
    }
}
fn alignment(value: Alignment) -> NativeTableAlignment {
    match value {
        Alignment::Center => NativeTableAlignment::Center,
        Alignment::Right => NativeTableAlignment::Trailing,
        Alignment::None | Alignment::Left => NativeTableAlignment::Leading,
    }
}
fn reference_markers(source: &str, markers: &mut Vec<NativeMarker>) {
    for line in line_ranges(source.as_bytes(), 0..source.len()) {
        let text = source[line.clone()].trim_start();
        if !text.starts_with("[^")
            && (text.starts_with('[') && text.contains("]: ")
                || text.starts_with('[') && text.contains("]:"))
        {
            markers.push(mark(MarkerKind::ReferenceDefinition, line));
        }
    }
}

fn footnote_number(numbers: &mut HashMap<String, usize>, name: &str) -> usize {
    let next = numbers.len() + 1;
    *numbers.entry(name.to_owned()).or_insert(next)
}

fn footnote_definition_prefix(source: &str, range: &Range<usize>) -> Option<Range<usize>> {
    let bytes = source.as_bytes();
    let line_end = line_end(bytes, range.start, range.end);
    let mut cursor = range.start;
    while cursor < line_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    if bytes.get(cursor..cursor.saturating_add(2)) != Some(b"[^") {
        return None;
    }
    let marker_start = cursor;
    cursor += 2;
    while cursor + 1 < line_end && bytes.get(cursor..cursor + 2) != Some(b"]:") {
        cursor += 1;
    }
    if cursor + 1 >= line_end {
        return None;
    }
    cursor += 2;
    while cursor < line_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    Some(marker_start..cursor)
}
fn triple_dash_fallback(source: &str, locals: &mut Vec<Local>) {
    let lines = line_ranges(source.as_bytes(), 0..source.len());
    for window in lines.windows(3) {
        if source[window[0].clone()].trim() == "---"
            && !source[window[1].clone()].trim().is_empty()
            && source[window[2].clone()].trim() == "---"
        {
            add_local(
                locals,
                window[0].start..window[2].end,
                LocalSourceReason::UnsupportedSyntax,
            );
        }
    }
}
fn malformed_fallback(document: &DocumentIr, locals: &mut Vec<Local>) {
    let parsed: Vec<_> = document
        .events()
        .iter()
        .filter_map(|event| {
            matches!(
                event.event,
                Event::Start(Tag::Link { .. } | Tag::Image { .. })
            )
            .then_some(event.source_range.clone())
        })
        .collect();
    for line in line_ranges(document.source().as_bytes(), 0..document.source().len()) {
        let text = &document.source()[line.clone()];
        if text.contains("](")
            && (!text.trim_end().ends_with(')') || text.contains(" title)"))
            && !parsed.iter().any(|item| contains(&line, item))
        {
            add_local(locals, line, LocalSourceReason::ComplexOrAmbiguous);
        }
    }
}
fn nested_fallback(render: &RenderIr, locals: &mut Vec<Local>) {
    for quote in render
        .blocks
        .iter()
        .filter(|item| item.kind == RenderBlockKind::BlockQuote)
    {
        if render.blocks.iter().any(|item| {
            item.source_range.start >= quote.source_range.start
                && item.source_range.end <= quote.source_range.end
                && matches!(
                    item.kind,
                    RenderBlockKind::OrderedList | RenderBlockKind::UnorderedList
                )
        }) {
            add_local(
                locals,
                quote.source_range.start..quote.source_range.end,
                LocalSourceReason::ComplexOrAmbiguous,
            );
        }
    }
}
fn add_local(locals: &mut Vec<Local>, range: Range<usize>, reason: LocalSourceReason) {
    if !range.is_empty() {
        locals.push(Local {
            range,
            reasons: BTreeSet::from([reason]),
        });
    }
}
fn merge_locals(mut locals: Vec<Local>) -> Vec<NativeLocalSourceBlock> {
    locals.sort_by_key(|item| (item.range.start, item.range.end));
    let mut merged: Vec<Local> = Vec::new();
    for item in locals {
        if let Some(last) = merged.last_mut()
            && item.range.start < last.range.end
        {
            last.range.end = last.range.end.max(item.range.end);
            last.reasons.extend(item.reasons);
        } else {
            merged.push(item);
        }
    }
    merged
        .into_iter()
        .map(|item| NativeLocalSourceBlock {
            source_range: item.range,
            reasons: item.reasons.into_iter().collect(),
        })
        .collect()
}
fn overlaps_locals(range: &Range<usize>, locals: &[NativeLocalSourceBlock]) -> bool {
    locals
        .iter()
        .any(|item| range.start < item.source_range.end && item.source_range.start < range.end)
}
fn contains(outer: &Range<usize>, inner: &Range<usize>) -> bool {
    outer.start <= inner.start && inner.end <= outer.end
}
fn is_mermaid(kind: &CodeBlockKind<'_>) -> bool {
    matches!(kind, CodeBlockKind::Fenced(info) if info.split_ascii_whitespace().next().is_some_and(|value| value.eq_ignore_ascii_case("mermaid")))
}
fn extract_svg(figure: &str) -> Option<(String, usize, usize)> {
    let start = figure.find("<svg")?;
    let end = start + figure[start..].find("</svg>")? + 6;
    let svg = &figure[start..end];
    let view_box = attribute(svg, "viewBox")?;
    let mut values = view_box.split_ascii_whitespace();
    let _x = values.next()?.parse::<f64>().ok()?;
    let _y = values.next()?.parse::<f64>().ok()?;
    let width = svg_extent(values.next()?)?;
    let height = svg_extent(values.next()?)?;
    Some((svg.to_owned(), width, height))
}

fn svg_extent(value: &str) -> Option<usize> {
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    let whole = whole.parse::<usize>().ok()?;
    if whole == 0 && fraction.chars().all(|character| character == '0') {
        return None;
    }
    if fraction.is_empty() || fraction.chars().all(|character| character == '0') {
        Some(whole)
    } else if fraction.chars().all(|character| character.is_ascii_digit()) {
        whole.checked_add(1)
    } else {
        None
    }
}

fn attribute<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let prefix = format!("{name}=\"");
    let start = tag.find(&prefix)? + prefix.len();
    let end = start + tag[start..].find('"')?;
    Some(&tag[start..end])
}
fn level_number(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}
fn trim_eol(source: &str, mut range: Range<usize>) -> Range<usize> {
    while range.end > range.start && matches!(source.as_bytes()[range.end - 1], b'\r' | b'\n') {
        range.end -= 1;
    }
    range
}
fn trim_space(bytes: &[u8], mut range: Range<usize>) -> Range<usize> {
    while range.start < range.end && matches!(bytes[range.start], b' ' | b'\t') {
        range.start += 1;
    }
    while range.end > range.start && matches!(bytes[range.end - 1], b' ' | b'\t') {
        range.end -= 1;
    }
    range
}
fn line_ranges(bytes: &[u8], range: Range<usize>) -> Vec<Range<usize>> {
    let mut output = Vec::new();
    let mut start = range.start;
    while start < range.end {
        let end = line_end(bytes, start, range.end);
        output.push(start..end);
        start = skip_eol(bytes, end, range.end);
    }
    output
}
fn line_end(bytes: &[u8], start: usize, limit: usize) -> usize {
    bytes[start..limit]
        .iter()
        .position(|byte| matches!(byte, b'\r' | b'\n'))
        .map_or(limit, |offset| start + offset)
}
fn skip_eol(bytes: &[u8], mut cursor: usize, limit: usize) -> usize {
    if cursor < limit && bytes[cursor] == b'\r' {
        cursor += 1;
    }
    if cursor < limit && bytes[cursor] == b'\n' {
        cursor += 1;
    }
    cursor
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markdown_ir::dialect_options;
    fn plan(source: &str) -> NativeRenderPlan {
        let document = DocumentIr::parse(source, dialect_options(true));
        let render = RenderIr::from_document(&document);
        NativeRenderPlan::from_document(&document, &render, true, false)
    }
    #[test]
    fn derives_native_plan_from_one_parse() {
        let plan = plan("# **标题**\n\n- [x] 任务\n\n[链接](guide.md) ![图](a.png) `code`");
        assert!(
            plan.content_styles
                .iter()
                .any(|item| item.kind == ContentStyleKind::Heading)
        );
        assert!(
            plan.content_styles
                .iter()
                .any(|item| item.kind == ContentStyleKind::Strong)
        );
        assert!(
            plan.content_styles
                .iter()
                .any(|item| item.kind == ContentStyleKind::TaskListItem)
        );
        assert_eq!(plan.links[0].target, "guide.md");
        assert_eq!(plan.images[0].target, "a.png");
    }
    #[test]
    fn derives_tables_diagrams_and_fallbacks() {
        let plan = plan(
            "| A | B |\n| :- | -: |\n| [x](y) | z |\n\n```mermaid\nflowchart LR\nA --> B\n```\n\n```swift\nprint(1)\n```\n\n<div>raw</div>",
        );
        assert_eq!(plan.tables[0].rows[1][0].text, "x");
        assert_eq!(plan.mermaid_diagrams.len(), 1);
        assert!(!plan.mermaid_diagrams[0].is_placeholder);
        assert_eq!(plan.mermaid_diagrams[0].intrinsic_width, 127);
        assert_eq!(plan.mermaid_diagrams[0].intrinsic_height, 68);
        assert!(
            plan.local_source_blocks
                .iter()
                .any(|item| item.reasons.contains(&LocalSourceReason::FencedCode))
        );
        assert!(
            plan.local_source_blocks
                .iter()
                .any(|item| item.reasons.contains(&LocalSourceReason::RawHtml))
        );
    }

    #[test]
    fn defers_mermaid_as_a_fast_placeholder_and_respects_disabled_rendering() {
        let source = "```mermaid\nflowchart LR\nA --> B\n```";
        let document = DocumentIr::parse(source, dialect_options(true));
        let render = RenderIr::from_document(&document);

        let deferred = NativeRenderPlan::from_document(&document, &render, true, true);
        assert_eq!(deferred.mermaid_diagrams.len(), 1);
        assert!(deferred.mermaid_diagrams[0].is_placeholder);
        assert!(
            deferred.mermaid_diagrams[0]
                .svg
                .contains("正在渲染 Mermaid 图表")
        );
        assert!(deferred.local_source_blocks.is_empty());

        let disabled = NativeRenderPlan::from_document(&document, &render, false, false);
        assert!(disabled.mermaid_diagrams.is_empty());
        assert!(
            disabled
                .local_source_blocks
                .iter()
                .any(|block| { block.reasons.contains(&LocalSourceReason::Mermaid) })
        );
    }

    #[test]
    fn native_markers_match_preview_visible_structure() {
        let source = "[link](https://example.com)\n\n- item\n- [x] done\n\n---\n\nNote[^b] then[^a].\n\n[^a]: Alpha\n[^b]: Beta\n";
        let plan = plan(source);

        let marker = |kind| {
            plan.markers
                .iter()
                .find(|item| item.kind == kind)
                .expect("marker")
        };
        assert_eq!(
            &source[marker(MarkerKind::LinkDestination).source_range.clone()],
            "(https://example.com)"
        );
        assert_eq!(
            marker(MarkerKind::UnorderedList)
                .replacement_text
                .as_deref(),
            Some("• ")
        );
        assert_eq!(
            marker(MarkerKind::TaskList).replacement_text.as_deref(),
            Some("☑ ")
        );
        assert_eq!(
            &source[marker(MarkerKind::Rule).source_range.clone()],
            "---"
        );

        let references: Vec<_> = plan
            .markers
            .iter()
            .filter(|item| item.kind == MarkerKind::FootnoteReference)
            .map(|item| item.replacement_text.as_deref())
            .collect();
        assert_eq!(references, [Some("1"), Some("2")]);
        let definitions: Vec<_> = plan
            .markers
            .iter()
            .filter(|item| item.kind == MarkerKind::FootnoteDefinition)
            .map(|item| item.replacement_text.as_deref())
            .collect();
        assert_eq!(definitions, [Some("2 "), Some("1 ")]);
        assert!(!plan.markers.iter().any(|item| {
            item.kind == MarkerKind::ReferenceDefinition
                && source[item.source_range.clone()].starts_with("[^")
        }));
    }

    #[test]
    fn valid_math_hides_only_delimiters_and_invalid_math_stays_source() {
        let source = "$x_1^2$\n\n$$\n\\frac{x}{y}\n$$\n\n$\\unknown{x}$";
        let plan = plan(source);

        assert_eq!(
            plan.content_styles
                .iter()
                .filter(|item| item.kind == ContentStyleKind::InlineMath)
                .count(),
            1
        );
        assert_eq!(
            plan.content_styles
                .iter()
                .filter(|item| item.kind == ContentStyleKind::DisplayMath)
                .count(),
            1
        );
        assert_eq!(
            plan.markers
                .iter()
                .filter(|item| item.kind == MarkerKind::MathDelimiter)
                .count(),
            4
        );
        assert!(plan.local_source_blocks.iter().any(|item| {
            item.reasons.contains(&LocalSourceReason::UnsupportedSyntax)
                && &source[item.source_range.clone()] == "$\\unknown{x}$"
        }));
    }
}
