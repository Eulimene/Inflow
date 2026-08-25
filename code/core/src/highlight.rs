//! Semantic Markdown syntax spans shared by platform editors.

use std::ops::Range;

use pulldown_cmark::{Event, Parser, Tag};

use crate::render;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
#[repr(u8)]
pub enum HighlightKind {
    Heading = 1,
    Emphasis = 2,
    Strong = 3,
    Strikethrough = 4,
    Code = 5,
    Link = 6,
    Image = 7,
    BlockQuote = 8,
    List = 9,
    Table = 10,
    Footnote = 11,
    Math = 12,
    Raw = 13,
    Rule = 14,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HighlightSpan {
    pub kind: HighlightKind,
    pub source_range: Range<usize>,
}

pub fn spans(source: &str) -> Vec<HighlightSpan> {
    let mut spans = Vec::new();
    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        let kind = match event {
            Event::Start(Tag::Item) => {
                if let Some(marker) = list_marker_range(source, range.start) {
                    spans.push(HighlightSpan {
                        kind: HighlightKind::List,
                        source_range: marker,
                    });
                }
                None
            }
            Event::Start(tag) => kind_for_tag(&tag),
            Event::Code(_) => Some(HighlightKind::Code),
            Event::InlineMath(_) | Event::DisplayMath(_) => Some(HighlightKind::Math),
            Event::Html(_) | Event::InlineHtml(_) => Some(HighlightKind::Raw),
            Event::FootnoteReference(_) => Some(HighlightKind::Footnote),
            Event::Rule => Some(HighlightKind::Rule),
            Event::TaskListMarker(_) => Some(HighlightKind::List),
            Event::End(_) | Event::Text(_) | Event::SoftBreak | Event::HardBreak => None,
        };
        if let Some(kind) = kind
            && !range.is_empty()
            && source.get(range.clone()).is_some()
        {
            spans.push(HighlightSpan {
                kind,
                source_range: trim_line_ending(source, range),
            });
        }
    }

    spans.retain(|span| !span.source_range.is_empty());
    spans.sort_unstable_by(|left, right| {
        left.source_range
            .start
            .cmp(&right.source_range.start)
            .then_with(|| right.source_range.end.cmp(&left.source_range.end))
            .then_with(|| left.kind.cmp(&right.kind))
    });
    spans.dedup();
    spans
}

fn kind_for_tag(tag: &Tag<'_>) -> Option<HighlightKind> {
    match tag {
        Tag::Heading { .. } => Some(HighlightKind::Heading),
        Tag::Emphasis => Some(HighlightKind::Emphasis),
        Tag::Strong => Some(HighlightKind::Strong),
        Tag::Strikethrough => Some(HighlightKind::Strikethrough),
        Tag::CodeBlock(_) => Some(HighlightKind::Code),
        Tag::Link { .. } => Some(HighlightKind::Link),
        Tag::Image { .. } => Some(HighlightKind::Image),
        Tag::BlockQuote(_) => Some(HighlightKind::BlockQuote),
        Tag::Table(_) => Some(HighlightKind::Table),
        Tag::FootnoteDefinition(_) => Some(HighlightKind::Footnote),
        Tag::HtmlBlock => Some(HighlightKind::Raw),
        Tag::Paragraph
        | Tag::Item
        | Tag::List(_)
        | Tag::TableHead
        | Tag::TableRow
        | Tag::TableCell
        | Tag::Superscript
        | Tag::Subscript
        | Tag::MetadataBlock(_)
        | Tag::DefinitionList
        | Tag::DefinitionListTitle
        | Tag::DefinitionListDefinition => None,
    }
}

fn list_marker_range(source: &str, start: usize) -> Option<Range<usize>> {
    let bytes = source.as_bytes();
    let line_end = bytes[start..]
        .iter()
        .position(|byte| *byte == b'\n')
        .map_or(bytes.len(), |offset| start + offset);
    let mut cursor = start;
    while cursor < line_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    let marker_start = cursor;
    if cursor < line_end && matches!(bytes[cursor], b'-' | b'+' | b'*') {
        cursor += 1;
    } else {
        let digits_start = cursor;
        while cursor < line_end && bytes[cursor].is_ascii_digit() {
            cursor += 1;
        }
        if cursor == digits_start || cursor >= line_end || !matches!(bytes[cursor], b'.' | b')') {
            return None;
        }
        cursor += 1;
    }
    if cursor >= line_end || !matches!(bytes[cursor], b' ' | b'\t') {
        return None;
    }
    while cursor < line_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    Some(marker_start..cursor)
}

fn trim_line_ending(source: &str, mut range: Range<usize>) -> Range<usize> {
    let bytes = source.as_bytes();
    while range.end > range.start && matches!(bytes[range.end - 1], b'\r' | b'\n') {
        range.end -= 1;
    }
    range
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matching<'a>(
        source: &'a str,
        spans: &'a [HighlightSpan],
        kind: HighlightKind,
    ) -> Vec<&'a str> {
        spans
            .iter()
            .filter(|span| span.kind == kind)
            .map(|span| &source[span.source_range.clone()])
            .collect()
    }

    #[test]
    fn highlights_launch_markdown_constructs_with_source_ranges() {
        let source = concat!(
            "# 标题 **bold**\n\n",
            "> *quote* and ~~gone~~\n\n",
            "- [x] [link](https://example.com) ![alt](image.png) `code` $x^2$\n\n",
            "| A | B |\n| - | - |\n| 1 | 2 |\n\n",
            "[^note]: footnote\n\n---\n\n",
            "```rust\nlet value = 1;\n```\n",
        );
        let result = spans(source);

        assert_eq!(
            matching(source, &result, HighlightKind::Heading)[0],
            "# 标题 **bold**"
        );
        assert!(matching(source, &result, HighlightKind::Strong).contains(&"**bold**"));
        assert!(matching(source, &result, HighlightKind::Emphasis).contains(&"*quote*"));
        assert!(matching(source, &result, HighlightKind::Strikethrough).contains(&"~~gone~~"));
        assert!(
            matching(source, &result, HighlightKind::Link).contains(&"[link](https://example.com)")
        );
        assert!(matching(source, &result, HighlightKind::Image).contains(&"![alt](image.png)"));
        assert!(matching(source, &result, HighlightKind::Code).contains(&"`code`"));
        assert!(matching(source, &result, HighlightKind::Math).contains(&"$x^2$"));
        assert!(matching(source, &result, HighlightKind::Rule).contains(&"---"));
        assert!(
            result
                .iter()
                .all(|span| source.get(span.source_range.clone()).is_some())
        );
    }

    #[test]
    fn does_not_highlight_markdown_inside_code_blocks() {
        let source = "```markdown\n# not a heading\n[not](a-link)\n```\n";
        let result = spans(source);

        assert_eq!(
            matching(source, &result, HighlightKind::Code),
            vec![source.trim_end()]
        );
        assert!(matching(source, &result, HighlightKind::Heading).is_empty());
        assert!(matching(source, &result, HighlightKind::Link).is_empty());
    }

    #[test]
    fn preserves_unicode_and_combining_grapheme_boundaries() {
        let source = "## e\u{301} 👩‍💻\n\n**中文**";
        let result = spans(source);

        assert_eq!(
            matching(source, &result, HighlightKind::Heading),
            vec!["## e\u{301} 👩‍💻"]
        );
        assert_eq!(
            matching(source, &result, HighlightKind::Strong),
            vec!["**中文**"]
        );
    }

    #[test]
    fn highlights_the_full_megabyte_document_without_truncation() {
        let line = "- **item** with [link](https://example.com) and `code`\n";
        let source = line.repeat(20_000);
        assert!(source.len() > 1_000_000);
        assert!(source.lines().count() >= 10_000);

        let result = spans(&source);

        assert_eq!(
            matching(&source, &result, HighlightKind::Strong).len(),
            20_000
        );
        assert_eq!(
            matching(&source, &result, HighlightKind::Link).len(),
            20_000
        );
        assert_eq!(
            matching(&source, &result, HighlightKind::Code).len(),
            20_000
        );
        assert!(
            result
                .last()
                .is_some_and(|span| span.source_range.end > 1_000_000)
        );
    }
}
