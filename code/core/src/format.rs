//! Predictable Markdown source edits shared by platform clients.

use std::ops::Range;

use pulldown_cmark::{Event, Parser, Tag, TagEnd};
use unicode_segmentation::UnicodeSegmentation;

use crate::{analysis, render};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineFormat {
    Bold,
    Italic,
    Strikethrough,
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

#[derive(Debug)]
struct BlockUnit {
    source_range: Range<usize>,
    content_range: Range<usize>,
    line_ending_range: Range<usize>,
    heading_level: Option<u8>,
}

#[derive(Debug)]
struct OutputUnit {
    old_source_range: Range<usize>,
    old_content_range: Range<usize>,
    new_unit_range: Range<usize>,
    new_content_start: usize,
    actionable: bool,
}

pub fn format_inline(
    source: &str,
    requested_selection: Range<usize>,
    format: InlineFormat,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }

    let marker = match format {
        InlineFormat::Bold => "**",
        InlineFormat::Italic => "*",
        InlineFormat::Strikethrough => "~~",
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

pub fn format_heading(
    source: &str,
    requested_selection: Range<usize>,
    level: u8,
) -> Result<MarkdownEdit, FormatError> {
    if !(1..=6).contains(&level) || !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }

    let document_analysis = analysis::analyze(source);
    let block_range = heading_aware_line_range(
        source,
        requested_selection.clone(),
        &document_analysis.headings,
    );
    let units = block_units(source, block_range.clone(), &document_analysis.headings)?;
    let caret = requested_selection.start;
    let actionable: Vec<bool> = units
        .iter()
        .map(|unit| {
            unit.heading_level.is_some()
                || !unit.content_range.is_empty()
                || (requested_selection.is_empty()
                    && unit.source_range.start <= caret
                    && caret <= unit.source_range.end)
        })
        .collect();
    if !actionable.iter().any(|is_actionable| *is_actionable) {
        return Err(FormatError::AmbiguousSelection);
    }

    let remove = units
        .iter()
        .zip(&actionable)
        .filter(|(_, is_actionable)| **is_actionable)
        .all(|(unit, _)| unit.heading_level == Some(level));
    let marker = "#".repeat(usize::from(level));
    let mut replacement = String::with_capacity(block_range.len() + units.len() * 7);
    let mut output_units = Vec::with_capacity(units.len());

    for (unit, is_actionable) in units.iter().zip(actionable) {
        let new_unit_start = replacement.len();
        let content = &source[unit.content_range.clone()];
        let new_content_start;

        if !is_actionable {
            replacement.push_str(&source[unit.source_range.clone()]);
            new_content_start = new_unit_start
                + unit
                    .content_range
                    .start
                    .saturating_sub(unit.source_range.start);
        } else if remove {
            new_content_start = new_unit_start;
            replacement.push_str(content);
            replacement.push_str(&source[unit.line_ending_range.clone()]);
        } else {
            replacement.push_str(&marker);
            replacement.push(' ');
            new_content_start = replacement.len();
            replacement.push_str(content);
            replacement.push_str(&source[unit.line_ending_range.clone()]);
        }

        output_units.push(OutputUnit {
            old_source_range: unit.source_range.clone(),
            old_content_range: unit.content_range.clone(),
            new_unit_range: new_unit_start..replacement.len(),
            new_content_start,
            actionable: is_actionable,
        });
    }

    let candidate = replacing(source, block_range.clone(), &replacement);
    let candidate_headings = analysis::analyze(&candidate).headings;
    for unit in output_units.iter().filter(|unit| unit.actionable) {
        let expected_start = block_range.start + unit.new_unit_range.start;
        let heading = candidate_headings
            .iter()
            .find(|heading| heading.source_range.start == expected_start);
        if remove {
            if heading.is_some() {
                return Err(FormatError::AmbiguousSelection);
            }
        } else if heading.is_none_or(|heading| heading.level != level) {
            return Err(FormatError::AmbiguousSelection);
        }
    }

    let selection_range = if requested_selection.is_empty() {
        let unit = output_units
            .iter()
            .find(|unit| unit.old_source_range.start <= caret && caret <= unit.old_source_range.end)
            .ok_or(FormatError::InvalidSelection)?;
        let old_content_offset = caret
            .saturating_sub(unit.old_content_range.start)
            .min(unit.old_content_range.len());
        let new_caret = block_range.start + unit.new_content_start + old_content_offset;
        new_caret..new_caret
    } else {
        let selected_end = block_range.start + without_trailing_line_ending(&replacement);
        block_range.start..selected_end
    };

    Ok(MarkdownEdit {
        replace_range: block_range,
        replacement,
        selection_range,
    })
}

fn heading_aware_line_range(
    source: &str,
    selection: Range<usize>,
    headings: &[analysis::Heading],
) -> Range<usize> {
    let start = line_start(source, selection.start);
    let end_anchor = if !selection.is_empty()
        && selection.end > selection.start
        && source.as_bytes().get(selection.end - 1) == Some(&b'\n')
    {
        selection.end - 1
    } else {
        selection.end
    };
    let mut range = start..line_end_including_ending(source, end_anchor);

    loop {
        let previous = range.clone();
        for heading in headings {
            if ranges_overlap(&range, &heading.source_range)
                || (selection.is_empty()
                    && heading.source_range.start <= selection.start
                    && selection.start <= heading.source_range.end)
            {
                range.start = range
                    .start
                    .min(line_start(source, heading.source_range.start));
                range.end = range
                    .end
                    .max(line_end_including_ending(source, heading.source_range.end));
            }
        }
        if range == previous {
            return range;
        }
    }
}

fn block_units(
    source: &str,
    block_range: Range<usize>,
    headings: &[analysis::Heading],
) -> Result<Vec<BlockUnit>, FormatError> {
    if block_range.is_empty() {
        return Ok(vec![BlockUnit {
            source_range: block_range.clone(),
            content_range: block_range.clone(),
            line_ending_range: block_range,
            heading_level: None,
        }]);
    }

    let mut units = Vec::new();
    let mut cursor = block_range.start;
    while cursor < block_range.end {
        if let Some(heading) = headings.iter().find(|heading| {
            heading.source_range.start == cursor && heading.source_range.end <= block_range.end
        }) {
            let unit_end = line_end_including_ending(source, heading.source_range.end);
            let content_range = heading_content_range(source, heading)?;
            units.push(BlockUnit {
                source_range: cursor..unit_end,
                content_range,
                line_ending_range: heading.source_range.end..unit_end,
                heading_level: Some(heading.level),
            });
            cursor = unit_end;
            continue;
        }

        let unit_end = line_end_including_ending(source, cursor);
        let line_ending_start = trailing_line_ending_start(source, cursor..unit_end);
        units.push(BlockUnit {
            source_range: cursor..unit_end,
            content_range: trim_horizontal_whitespace(source, cursor..line_ending_start),
            line_ending_range: line_ending_start..unit_end,
            heading_level: None,
        });
        cursor = unit_end;
    }
    Ok(units)
}

fn heading_content_range(
    source: &str,
    heading: &analysis::Heading,
) -> Result<Range<usize>, FormatError> {
    let raw = &source[heading.source_range.clone()];
    if let Some(newline) = raw.find('\n') {
        let title_end = heading.source_range.start + newline;
        let title_end = if source.as_bytes().get(title_end.saturating_sub(1)) == Some(&b'\r') {
            title_end - 1
        } else {
            title_end
        };
        return Ok(trim_horizontal_whitespace(
            source,
            heading.source_range.start..title_end,
        ));
    }

    atx_heading_content_range(source, heading.source_range.clone())
        .ok_or(FormatError::AmbiguousSelection)
}

fn atx_heading_content_range(source: &str, range: Range<usize>) -> Option<Range<usize>> {
    let bytes = source.as_bytes();
    let mut cursor = range.start;
    let mut indent = 0;
    while cursor < range.end && bytes[cursor] == b' ' && indent < 3 {
        cursor += 1;
        indent += 1;
    }
    let marker_start = cursor;
    while cursor < range.end && bytes[cursor] == b'#' {
        cursor += 1;
    }
    let marker_length = cursor - marker_start;
    if !(1..=6).contains(&marker_length)
        || (cursor < range.end && !matches!(bytes[cursor], b' ' | b'\t'))
    {
        return None;
    }
    while cursor < range.end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }

    let mut content_end = range.end;
    while content_end > cursor && matches!(bytes[content_end - 1], b' ' | b'\t') {
        content_end -= 1;
    }
    let closing_end = content_end;
    while content_end > cursor && bytes[content_end - 1] == b'#' {
        content_end -= 1;
    }
    if content_end < closing_end
        && content_end > cursor
        && matches!(bytes[content_end - 1], b' ' | b'\t')
    {
        while content_end > cursor && matches!(bytes[content_end - 1], b' ' | b'\t') {
            content_end -= 1;
        }
    } else {
        content_end = closing_end;
    }
    Some(cursor..content_end)
}

fn trim_horizontal_whitespace(source: &str, mut range: Range<usize>) -> Range<usize> {
    let bytes = source.as_bytes();
    while range.start < range.end && matches!(bytes[range.start], b' ' | b'\t') {
        range.start += 1;
    }
    while range.end > range.start && matches!(bytes[range.end - 1], b' ' | b'\t') {
        range.end -= 1;
    }
    range
}

fn line_start(source: &str, offset: usize) -> usize {
    source.as_bytes()[..offset]
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |newline| newline + 1)
}

fn line_end_including_ending(source: &str, offset: usize) -> usize {
    if offset >= source.len() {
        return source.len();
    }
    source.as_bytes()[offset..]
        .iter()
        .position(|byte| *byte == b'\n')
        .map_or(source.len(), |newline| offset + newline + 1)
}

fn trailing_line_ending_start(source: &str, range: Range<usize>) -> usize {
    let bytes = source.as_bytes();
    if range.end > range.start && bytes[range.end - 1] == b'\n' {
        if range.end - 1 > range.start && bytes[range.end - 2] == b'\r' {
            range.end - 2
        } else {
            range.end - 1
        }
    } else {
        range.end
    }
}

fn without_trailing_line_ending(text: &str) -> usize {
    if text.ends_with("\r\n") {
        text.len() - 2
    } else if text.ends_with('\n') {
        text.len() - 1
    } else {
        text.len()
    }
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
                        InlineFormat::Italic => 1,
                        InlineFormat::Bold | InlineFormat::Strikethrough => 2,
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
        (Tag::Strong, InlineFormat::Bold)
            | (Tag::Emphasis, InlineFormat::Italic)
            | (Tag::Strikethrough, InlineFormat::Strikethrough)
    )
}

fn is_target_end(end: TagEnd, format: InlineFormat) -> bool {
    matches!(
        (end, format),
        (TagEnd::Strong, InlineFormat::Bold)
            | (TagEnd::Emphasis, InlineFormat::Italic)
            | (TagEnd::Strikethrough, InlineFormat::Strikethrough)
    )
}

fn ranges_overlap(lhs: &Range<usize>, rhs: &Range<usize>) -> bool {
    lhs.start < rhs.end && rhs.start < lhs.end
}

fn is_valid_selection(source: &str, selection: &Range<usize>) -> bool {
    selection.start <= selection.end
        && selection.end <= source.len()
        && is_grapheme_boundary(source, selection.start)
        && is_grapheme_boundary(source, selection.end)
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
    fn adds_heading_to_current_line_and_preserves_caret_position() {
        assert_eq!(
            format_heading("plain text\nnext\n", 2..2, 2),
            Ok(MarkdownEdit {
                replace_range: 0..11,
                replacement: "## plain text\n".to_owned(),
                selection_range: 5..5,
            })
        );
        assert_eq!(
            format_heading("", 0..0, 1),
            Ok(MarkdownEdit {
                replace_range: 0..0,
                replacement: "# ".to_owned(),
                selection_range: 2..2,
            })
        );
    }

    #[test]
    fn removes_same_atx_heading_and_normalizes_closing_hashes() {
        let source = "## Title ##\nBody\n";
        let edit = format_heading(source, 4..4, 2).unwrap();
        assert_eq!(edit.replace_range, 0..12);
        assert_eq!(edit.replacement, "Title\n");
        assert_eq!(edit.selection_range, 1..1);
        assert_eq!(
            replacing(source, edit.replace_range, &edit.replacement),
            "Title\nBody\n"
        );
    }

    #[test]
    fn unifies_mixed_multiline_headings_then_removes_them_together() {
        let source = "# One\nplain\n### Three\n\nnext\n";
        let selected_end = "# One\nplain\n### Three\n\n".len();
        let added = format_heading(source, 0..selected_end, 2).unwrap();
        assert_eq!(added.replace_range, 0..selected_end);
        assert_eq!(added.replacement, "## One\n## plain\n## Three\n\n");
        assert_eq!(added.selection_range, 0..added.replacement.len() - 1);

        let formatted = replacing(source, added.replace_range, &added.replacement);
        let removed = format_heading(&formatted, 0..added.replacement.len() - 1, 2).unwrap();
        assert_eq!(removed.replacement, "One\nplain\nThree\n");
        assert_eq!(
            replacing(&formatted, removed.replace_range, &removed.replacement),
            "One\nplain\nThree\n\nnext\n"
        );
    }

    #[test]
    fn converts_or_removes_setext_heading_as_one_block() {
        let source = "Title\n=====\nBody\n";
        let converted = format_heading(source, 2..2, 3).unwrap();
        assert_eq!(converted.replace_range, 0..12);
        assert_eq!(converted.replacement, "### Title\n");
        assert_eq!(
            replacing(source, converted.replace_range, &converted.replacement),
            "### Title\nBody\n"
        );

        let removed = format_heading(source, 8..8, 1).unwrap();
        assert_eq!(removed.replacement, "Title\n");

        let crlf = "Title\r\n=====\r\n";
        let converted = format_heading(crlf, 9..9, 4).unwrap();
        assert_eq!(converted.replacement, "#### Title\r\n");
    }

    #[test]
    fn selection_ending_at_line_break_does_not_change_next_line() {
        let source = "one\ntwo\n";
        let edit = format_heading(source, 0..4, 1).unwrap();
        assert_eq!(edit.replace_range, 0..4);
        assert_eq!(edit.replacement, "# one\n");
        assert_eq!(
            replacing(source, edit.replace_range, &edit.replacement),
            "# one\ntwo\n"
        );
    }

    #[test]
    fn refuses_headings_inside_code_fences_or_secondary_heading_on_removal() {
        let fenced = "```\ninside\n```\n";
        assert_eq!(
            format_heading(fenced, 6..6, 1),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            format_heading("## # Child\n", 4..4, 2),
            Err(FormatError::AmbiguousSelection)
        );
    }

    #[test]
    fn rejects_invalid_heading_level_and_grapheme_internal_selection() {
        assert_eq!(
            format_heading("text", 0..0, 0),
            Err(FormatError::InvalidSelection)
        );
        assert_eq!(
            format_heading("e\u{301}", 1..1, 1),
            Err(FormatError::InvalidSelection)
        );
    }

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
        assert_eq!(
            format_inline("text", 2..2, InlineFormat::Strikethrough),
            Ok(MarkdownEdit {
                replace_range: 2..2,
                replacement: "~~~~".to_owned(),
                selection_range: 4..4,
            })
        );
    }

    #[test]
    fn adds_and_removes_gfm_strikethrough() {
        let source = "before 旧内容 after";
        let start = "before ".len();
        let end = start + "旧内容".len();
        let added = format_inline(source, start..end, InlineFormat::Strikethrough).unwrap();
        let formatted = replacing(source, added.replace_range, &added.replacement);
        assert_eq!(formatted, "before ~~旧内容~~ after");
        assert!(render::html_fragment(&formatted).contains("<del>旧内容</del>"));

        let content_start = start + 2;
        let content_end = content_start + "旧内容".len();
        let removed = format_inline(
            &formatted,
            content_start..content_end,
            InlineFormat::Strikethrough,
        )
        .unwrap();
        assert_eq!(
            replacing(&formatted, removed.replace_range, &removed.replacement),
            source
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
            InlineFormat::Italic => 1,
            InlineFormat::Bold | InlineFormat::Strikethrough => 2,
        }
    }
}
