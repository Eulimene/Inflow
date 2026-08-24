//! Predictable Markdown source edits shared by platform clients.

use std::ops::Range;

use pulldown_cmark::{Event, Parser, Tag, TagEnd};
use unicode_segmentation::UnicodeSegmentation;

use crate::render;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineFormat {
    Bold,
    Italic,
}

#[derive(Debug, Eq, PartialEq)]
pub struct MarkdownEdit {
    pub replace_range: Range<usize>,
    pub replacement: String,
    pub selection_range: Range<usize>,
}

#[derive(Debug, Eq, PartialEq)]
pub enum FormatError {
    InvalidSelection,
    AmbiguousSelection,
}

#[derive(Debug)]
struct FormatSpan {
    full_range: Range<usize>,
    content_range: Range<usize>,
}

pub fn format_inline(
    source: &str,
    requested_selection: Range<usize>,
    format: InlineFormat,
) -> Result<MarkdownEdit, FormatError> {
    if requested_selection.start > requested_selection.end
        || requested_selection.end > source.len()
        || !is_grapheme_boundary(source, requested_selection.start)
        || !is_grapheme_boundary(source, requested_selection.end)
    {
        return Err(FormatError::InvalidSelection);
    }

    let marker = match format {
        InlineFormat::Bold => "**",
        InlineFormat::Italic => "*",
    };

    if requested_selection.is_empty() {
        let replacement = format!("{marker}{marker}");
        let caret = requested_selection.start + marker.len();
        return Ok(MarkdownEdit {
            replace_range: requested_selection,
            replacement,
            selection_range: caret..caret,
        });
    }

    let selection = trim_surrounding_whitespace(source, requested_selection)
        .ok_or(FormatError::AmbiguousSelection)?;
    let spans = format_spans(source, format);
    if let Some(span) = spans
        .iter()
        .find(|span| selection == span.full_range || selection == span.content_range)
    {
        let replacement = source[span.content_range.clone()].to_owned();
        let selection_start = span.full_range.start;
        let selection_end = selection_start + replacement.len();
        return Ok(MarkdownEdit {
            replace_range: span.full_range.clone(),
            replacement,
            selection_range: selection_start..selection_end,
        });
    }

    if spans
        .iter()
        .any(|span| ranges_overlap(&selection, &span.full_range))
    {
        return Err(FormatError::AmbiguousSelection);
    }

    let selected = &source[selection.clone()];
    let replacement = format!("{marker}{selected}{marker}");
    let expected_full_range = selection.start..selection.start + marker.len() * 2 + selected.len();
    let expected_content_range =
        selection.start + marker.len()..selection.start + marker.len() + selected.len();
    let candidate = replacing(source, selection.clone(), &replacement);
    if !format_spans(&candidate, format).iter().any(|span| {
        span.full_range == expected_full_range && span.content_range == expected_content_range
    }) {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range: selection.clone(),
        replacement,
        selection_range: selection.start + marker.len()..selection.end + marker.len(),
    })
}

fn trim_surrounding_whitespace(source: &str, selection: Range<usize>) -> Option<Range<usize>> {
    let selected = &source[selection.clone()];
    let first = selected
        .char_indices()
        .find(|(_, character)| !character.is_whitespace())?
        .0;
    let last = selected
        .char_indices()
        .rev()
        .find(|(_, character)| !character.is_whitespace())?;
    let last_end = last.0 + last.1.len_utf8();
    Some(selection.start + first..selection.start + last_end)
}

fn replacing(source: &str, range: Range<usize>, replacement: &str) -> String {
    let mut result = String::with_capacity(source.len() - range.len() + replacement.len());
    result.push_str(&source[..range.start]);
    result.push_str(replacement);
    result.push_str(&source[range.end..]);
    result
}

fn format_spans(source: &str, format: InlineFormat) -> Vec<FormatSpan> {
    let mut stack: Vec<usize> = Vec::new();
    let mut spans = Vec::new();

    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        match event {
            Event::Start(tag) if is_target_start(&tag, format) => {
                stack.push(range.start);
            }
            Event::End(end) if is_target_end(end, format) => {
                if let Some(full_start) = stack.pop() {
                    let marker_length = match format {
                        InlineFormat::Bold => 2,
                        InlineFormat::Italic => 1,
                    };
                    let content_start = full_start + marker_length;
                    let content_end = range.end.saturating_sub(marker_length);
                    if content_start > content_end {
                        continue;
                    }
                    spans.push(FormatSpan {
                        full_range: full_start..range.end,
                        content_range: content_start..content_end,
                    });
                }
            }
            _ => {}
        }
    }

    spans
}

fn is_target_start(tag: &Tag<'_>, format: InlineFormat) -> bool {
    matches!(
        (tag, format),
        (Tag::Strong, InlineFormat::Bold) | (Tag::Emphasis, InlineFormat::Italic)
    )
}

fn is_target_end(end: TagEnd, format: InlineFormat) -> bool {
    matches!(
        (end, format),
        (TagEnd::Strong, InlineFormat::Bold) | (TagEnd::Emphasis, InlineFormat::Italic)
    )
}

fn ranges_overlap(lhs: &Range<usize>, rhs: &Range<usize>) -> bool {
    lhs.start < rhs.end && rhs.start < lhs.end
}

fn is_grapheme_boundary(source: &str, offset: usize) -> bool {
    offset == source.len()
        || source
            .grapheme_indices(true)
            .any(|(grapheme_offset, _)| grapheme_offset == offset)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_unicode_selection_and_keeps_content_selected() {
        let source = "Start 中文👩‍💻 end";
        let start = "Start ".len();
        let end = start + "中文👩‍💻".len();

        assert_eq!(
            format_inline(source, start..end, InlineFormat::Bold),
            Ok(MarkdownEdit {
                replace_range: start..end,
                replacement: "**中文👩‍💻**".to_owned(),
                selection_range: start + 2..end + 2,
            })
        );
    }

    #[test]
    fn removes_complete_asterisk_or_underscore_wrappers() {
        for (source, content_range, full_range, format) in [
            ("**bold**", 2..6, 0..8, InlineFormat::Bold),
            ("__bold__", 2..6, 0..8, InlineFormat::Bold),
            ("*italic*", 1..7, 0..8, InlineFormat::Italic),
            ("_italic_", 1..7, 0..8, InlineFormat::Italic),
        ] {
            for selection in [content_range, full_range.clone()] {
                assert_eq!(
                    format_inline(source, selection, format),
                    Ok(MarkdownEdit {
                        replace_range: full_range.clone(),
                        replacement: source[full_range.start + format_marker_len(format)
                            ..full_range.end - format_marker_len(format)]
                            .to_owned(),
                        selection_range: 0..source.len() - 2 * format_marker_len(format),
                    })
                );
            }
        }
    }

    #[test]
    fn inserts_editable_template_for_empty_selection() {
        assert_eq!(
            format_inline("text", 2..2, InlineFormat::Bold),
            Ok(MarkdownEdit {
                replace_range: 2..2,
                replacement: "****".to_owned(),
                selection_range: 4..4,
            })
        );
        assert_eq!(
            format_inline("text", 2..2, InlineFormat::Italic),
            Ok(MarkdownEdit {
                replace_range: 2..2,
                replacement: "**".to_owned(),
                selection_range: 3..3,
            })
        );
    }

    #[test]
    fn rejects_partial_or_mixed_formatted_selection() {
        assert_eq!(
            format_inline("**bold**", 3..5, InlineFormat::Bold),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            format_inline("plain **bold**", 0..14, InlineFormat::Bold),
            Err(FormatError::AmbiguousSelection)
        );
    }

    #[test]
    fn trims_outer_whitespace_and_formats_a_soft_line_break() {
        assert_eq!(
            format_inline(" bold ", 0..6, InlineFormat::Bold),
            Ok(MarkdownEdit {
                replace_range: 1..5,
                replacement: "**bold**".to_owned(),
                selection_range: 3..7,
            })
        );

        let source = "first\nsecond";
        let edit = format_inline(source, 0..source.len(), InlineFormat::Italic).unwrap();
        let result = replacing(source, edit.replace_range, &edit.replacement);
        assert_eq!(result, "*first\nsecond*");
        assert!(render::html_fragment(&result).contains("<em>first\nsecond</em>"));
    }

    #[test]
    fn rejects_whitespace_only_or_cross_paragraph_inline_format() {
        assert_eq!(
            format_inline(" \n ", 0..3, InlineFormat::Bold),
            Err(FormatError::AmbiguousSelection)
        );
        let source = "first\n\nsecond";
        assert_eq!(
            format_inline(source, 0..source.len(), InlineFormat::Italic),
            Err(FormatError::AmbiguousSelection)
        );
    }

    #[test]
    fn removes_nested_format_without_dropping_the_other_format() {
        let source = "***both***";
        let edit = format_inline(source, 3..7, InlineFormat::Bold).unwrap();
        assert_eq!(edit.replace_range, 1..9);
        assert_eq!(edit.replacement, "both");

        let mut bytes = source.as_bytes().to_vec();
        bytes.splice(edit.replace_range, edit.replacement.bytes());
        assert_eq!(String::from_utf8(bytes).unwrap(), "*both*");
    }

    #[test]
    fn rejects_scalar_and_grapheme_internal_offsets() {
        let source = "e\u{301}👩‍💻";
        assert_eq!(
            format_inline(source, 1..3, InlineFormat::Italic),
            Err(FormatError::InvalidSelection)
        );
        assert_eq!(
            format_inline(source, 0..2, InlineFormat::Bold),
            Err(FormatError::InvalidSelection)
        );
    }

    fn format_marker_len(format: InlineFormat) -> usize {
        match format {
            InlineFormat::Bold => 2,
            InlineFormat::Italic => 1,
        }
    }
}
