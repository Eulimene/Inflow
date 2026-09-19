//! Predictable Markdown source edits shared by platform clients.

use std::ops::Range;

use pulldown_cmark::{CodeBlockKind, Event, Parser, Tag, TagEnd};
use unicode_segmentation::UnicodeSegmentation;

use crate::{analysis, render};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineFormat {
    Bold,
    Italic,
    Strikethrough,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ListFormat {
    Unordered,
    Ordered,
    Task,
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
struct FencedCodeSpan {
    full: Range<usize>,
    content: Range<usize>,
    unwrapped_content: Range<usize>,
    selection_content: Range<usize>,
}

#[derive(Debug)]
struct LinkSpan {
    full: Range<usize>,
    label: Range<usize>,
}

#[derive(Debug)]
struct ImageSpan {
    full: Range<usize>,
    alternative: Range<usize>,
}

#[derive(Debug)]
struct TableSpan {
    full: Range<usize>,
    columns: usize,
    body_rows: usize,
}

#[derive(Debug)]
struct MathSpan {
    full: Range<usize>,
    content: Range<usize>,
    display: bool,
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

#[derive(Debug)]
struct QuoteLineOutput {
    old_line_start: usize,
    new_line_start: usize,
    old_range: Range<usize>,
    old_probe: usize,
    new_probe: usize,
    removed_marker: Option<Range<usize>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ListMarker {
    kind: ListFormat,
    marker_start: usize,
    marker_end: usize,
    content_start: usize,
    checked: bool,
}

#[derive(Debug)]
struct ListLineOutput {
    old_range: Range<usize>,
    old_content_start: usize,
    new_content_start: usize,
    marker_start: usize,
    actionable: bool,
}

#[derive(Debug)]
struct SemanticListItem {
    source_start: usize,
    source_end: usize,
    kind: ListFormat,
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

pub fn format_inline_code(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }
    if requested_selection.is_empty() {
        let caret = requested_selection.start + 1;
        return Ok(MarkdownEdit {
            replace_range: requested_selection,
            replacement: "``".to_owned(),
            selection_range: caret..caret,
        });
    }

    let selected = &source[requested_selection.clone()];
    if selected.contains('\n') || selected.chars().all(char::is_whitespace) {
        return Err(FormatError::AmbiguousSelection);
    }

    let spans = inline_code_spans(source);
    if let Some(span) = spans.iter().find(|span| {
        requested_selection == span.full_range || requested_selection == span.content_range
    }) {
        let replacement = source[span.content_range.clone()].to_owned();
        let selection_start = span.full_range.start;
        return Ok(MarkdownEdit {
            replace_range: span.full_range.clone(),
            selection_range: selection_start..selection_start + replacement.len(),
            replacement,
        });
    }
    if spans.iter().any(|span| {
        ranges_overlap(&requested_selection, &span.full_range)
            && !(requested_selection.start <= span.full_range.start
                && span.full_range.end <= requested_selection.end)
    }) {
        return Err(FormatError::AmbiguousSelection);
    }

    let delimiter = "`".repeat(longest_backtick_run(selected).saturating_add(1));
    let needs_padding = selected.starts_with(['`', ' ']) || selected.ends_with(['`', ' ']);
    let padding = if needs_padding { " " } else { "" };
    let replacement = format!("{delimiter}{padding}{selected}{padding}{delimiter}");
    let full_range = requested_selection.start..requested_selection.start + replacement.len();
    let content_start = requested_selection.start + delimiter.len() + padding.len();
    let content_range = content_start..content_start + selected.len();
    let candidate = replacing(source, requested_selection.clone(), &replacement);
    if !inline_code_spans(&candidate)
        .iter()
        .any(|span| span.full_range == full_range && span.content_range == content_range)
    {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range: requested_selection,
        replacement,
        selection_range: content_range,
    })
}

pub fn format_code_block(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }

    let spans = fenced_code_spans(source);
    if let Some(span) = spans.iter().find(|span| {
        requested_selection == span.full
            || requested_selection == span.content
            || requested_selection == span.unwrapped_content
            || requested_selection == span.selection_content
            || (requested_selection.is_empty()
                && span.full.start <= requested_selection.start
                && requested_selection.start <= span.full.end)
    }) {
        let replacement = source[span.unwrapped_content.clone()].to_owned();
        let selection_range = if requested_selection.is_empty() {
            let offset = requested_selection
                .start
                .saturating_sub(span.content.start)
                .min(replacement.len());
            let caret = span.full.start + offset;
            caret..caret
        } else {
            span.full.start..span.full.start + without_trailing_line_ending(&replacement)
        };
        return Ok(MarkdownEdit {
            replace_range: span.full.clone(),
            replacement,
            selection_range,
        });
    }

    if requested_selection.is_empty() {
        let caret = requested_selection.start;
        let prefix = if caret > 0 && source.as_bytes()[caret - 1] != b'\n' {
            "\n"
        } else {
            ""
        };
        let suffix = if caret < source.len() && source.as_bytes()[caret] != b'\n' {
            "\n"
        } else {
            ""
        };
        let replacement = format!("{prefix}```\n\n```{suffix}");
        let content_start = caret + prefix.len() + 4;
        let candidate = replacing(source, requested_selection.clone(), &replacement);
        if !fenced_code_spans(&candidate).iter().any(|span| {
            span.full.start == caret + prefix.len() && span.content.start == content_start
        }) {
            return Err(FormatError::AmbiguousSelection);
        }
        return Ok(MarkdownEdit {
            replace_range: requested_selection,
            replacement,
            selection_range: content_start..content_start,
        });
    }

    let block_range = selected_line_range(source, requested_selection.clone());
    if spans.iter().any(|span| {
        ranges_overlap(&block_range, &span.full)
            && !(block_range.start <= span.full.start && span.full.end <= block_range.end)
    }) {
        return Err(FormatError::AmbiguousSelection);
    }

    let content = &source[block_range.clone()];
    let fence = "`".repeat(longest_backtick_run(content).saturating_add(1).max(3));
    let content_has_line_ending = content.ends_with('\n');
    let mut replacement = String::with_capacity(block_range.len() + fence.len() * 2 + 2);
    replacement.push_str(&fence);
    replacement.push('\n');
    replacement.push_str(content);
    if !content_has_line_ending {
        replacement.push('\n');
    }
    replacement.push_str(&fence);
    if content_has_line_ending {
        replacement.push('\n');
    }

    let content_start = block_range.start + fence.len() + 1;
    let candidate = replacing(source, block_range.clone(), &replacement);
    let expected_full_start = block_range.start;
    let expected_content_end =
        content_start + content.len() + usize::from(!content_has_line_ending);
    if !fenced_code_spans(&candidate).iter().any(|span| {
        span.full.start == expected_full_start
            && span.content == (content_start..expected_content_end)
    }) {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range: block_range,
        replacement,
        selection_range: content_start..content_start + without_trailing_line_ending(content),
    })
}

/// Removes Markdown markers that the editor can create from one explicit
/// selection. Parsing is intentionally limited to the selected fragment: a
/// marker must be fully selected and semantically active before it can be
/// removed. This keeps surrounding source byte-for-byte unchanged and avoids
/// interpreting fenced or inline-code contents as Markdown after unwrapping.
pub fn clear_format(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }
    if requested_selection.is_empty() {
        return Err(FormatError::AmbiguousSelection);
    }

    let fragment = &source[requested_selection.clone()];
    let removals = clearable_marker_ranges(fragment);
    if removals.is_empty() {
        return Err(FormatError::AmbiguousSelection);
    }

    let mut replacement = String::with_capacity(fragment.len());
    let mut cursor = 0;
    for range in removals {
        replacement.push_str(&fragment[cursor..range.start]);
        cursor = range.end;
    }
    replacement.push_str(&fragment[cursor..]);

    let selection_start = requested_selection.start;
    let selection_end = selection_start + replacement.len();
    Ok(MarkdownEdit {
        replace_range: requested_selection,
        replacement,
        selection_range: selection_start..selection_end,
    })
}

fn clearable_marker_ranges(fragment: &str) -> Vec<Range<usize>> {
    let mut removals = Vec::new();

    for format in [
        InlineFormat::Bold,
        InlineFormat::Italic,
        InlineFormat::Strikethrough,
    ] {
        for span in format_spans(fragment, format) {
            removals.push(span.full_range.start..span.content_range.start);
            removals.push(span.content_range.end..span.full_range.end);
        }
    }

    for span in inline_code_spans(fragment) {
        removals.push(span.full_range.start..span.content_range.start);
        removals.push(span.content_range.end..span.full_range.end);
    }

    for span in fenced_code_spans(fragment) {
        removals.push(span.full.start..span.unwrapped_content.start);
        removals.push(span.unwrapped_content.end..span.full.end);
    }

    for heading in analysis::analyze(fragment).headings {
        if let Some(content) = atx_heading_content_range(fragment, heading.source_range.clone()) {
            removals.push(heading.source_range.start..content.start);
            removals.push(content.end..heading.source_range.end);
        } else if let Some(newline_offset) = fragment[heading.source_range.clone()].find('\n') {
            // Setext headings keep the first line ending and discard only the
            // underline line. The parser has already established semantics.
            let underline_start = heading.source_range.start + newline_offset + 1;
            let underline_end = line_end_including_ending(fragment, heading.source_range.end);
            removals.push(underline_start..underline_end);
        }
    }

    let quote_spans = block_quote_spans(fragment);
    for line in physical_line_ranges(fragment, 0..fragment.len()) {
        let depth = block_quote_depth_at(&quote_spans, line_probe(fragment, line.clone()));
        let mut remainder = line;
        for _ in 0..depth {
            let Some(marker) = block_quote_marker_range(fragment, remainder.clone()) else {
                break;
            };
            removals.push(marker.clone());
            remainder.start = marker.end;
        }
    }

    let semantic_items = semantic_list_items(fragment);
    for line in physical_line_ranges(fragment, 0..fragment.len()) {
        let depth = block_quote_depth_at(&quote_spans, line_probe(fragment, line.clone()));
        let mut list_line = line;
        for _ in 0..depth {
            let Some(quote_marker) = block_quote_marker_range(fragment, list_line.clone()) else {
                break;
            };
            list_line.start = quote_marker.end;
        }
        let Some(marker) = list_marker(fragment, list_line) else {
            continue;
        };
        if semantic_items.iter().any(|item| {
            item.source_start <= marker.marker_start
                && marker.marker_start < item.source_end
                && item.kind == marker.kind
        }) {
            removals.push(marker.marker_start..marker.marker_end);
        }
    }

    merge_ranges(removals)
}

fn merge_ranges(mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    ranges.retain(|range| range.start < range.end);
    ranges.sort_unstable_by_key(|range| (range.start, range.end));

    let mut merged: Vec<Range<usize>> = Vec::with_capacity(ranges.len());
    for range in ranges {
        if let Some(previous) = merged.last_mut()
            && range.start <= previous.end
        {
            previous.end = previous.end.max(range.end);
        } else {
            merged.push(range);
        }
    }
    merged
}

pub fn insert_link(
    source: &str,
    requested_selection: Range<usize>,
    destination: &str,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }
    let destination = destination.trim();
    if destination.is_empty()
        || destination
            .chars()
            .any(|character| character.is_control() || matches!(character, '<' | '>' | '\\'))
    {
        return Err(FormatError::InvalidSelection);
    }

    let spans = link_spans(source);
    let existing = spans
        .iter()
        .find(|span| requested_selection == span.full || requested_selection == span.label);
    if existing.is_none()
        && spans
            .iter()
            .any(|span| ranges_overlap(&requested_selection, &span.full))
    {
        return Err(FormatError::AmbiguousSelection);
    }

    let (replace_range, label) = if let Some(span) = existing {
        (span.full.clone(), source[span.label.clone()].to_owned())
    } else if requested_selection.is_empty() {
        (requested_selection.clone(), "链接文字".to_owned())
    } else {
        (
            requested_selection.clone(),
            escaped_link_label(&source[requested_selection.clone()]),
        )
    };
    let replacement = format!("[{label}](<{destination}>)");
    let label_range = replace_range.start + 1..replace_range.start + 1 + label.len();
    let full_range = replace_range.start..replace_range.start + replacement.len();
    let candidate = replacing(source, replace_range.clone(), &replacement);
    if !link_spans(&candidate)
        .iter()
        .any(|span| span.full == full_range && span.label == label_range)
    {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range,
        replacement,
        selection_range: label_range,
    })
}

pub fn insert_image(
    source: &str,
    requested_selection: Range<usize>,
    destination: &str,
    default_alternative: &str,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }
    let destination = destination.trim();
    let default_alternative = default_alternative.trim();
    if !is_valid_destination(destination)
        || default_alternative.is_empty()
        || default_alternative.chars().any(char::is_control)
    {
        return Err(FormatError::InvalidSelection);
    }
    let parsed_image_spans = image_spans(source);
    let existing = parsed_image_spans
        .iter()
        .find(|span| span.full == requested_selection);
    if (existing.is_none()
        && link_spans(source)
            .iter()
            .any(|span| ranges_overlap(&requested_selection, &span.full)))
        || parsed_image_spans.iter().any(|span| {
            ranges_overlap(&requested_selection, &span.full) && span.full != requested_selection
        })
    {
        return Err(FormatError::AmbiguousSelection);
    }

    let (replace_range, alternative) = if let Some(span) = existing {
        (
            span.full.clone(),
            source[span.alternative.clone()].to_owned(),
        )
    } else if requested_selection.is_empty() {
        (requested_selection.clone(), default_alternative.to_owned())
    } else {
        (
            requested_selection.clone(),
            escaped_link_label(&source[requested_selection.clone()]),
        )
    };
    if alternative
        .chars()
        .any(|character| matches!(character, '\n' | '\r'))
    {
        return Err(FormatError::AmbiguousSelection);
    }
    let replacement = format!("![{alternative}](<{destination}>)");
    let alternative_range = replace_range.start + 2..replace_range.start + 2 + alternative.len();
    let full_range = replace_range.start..replace_range.start + replacement.len();
    let candidate = replacing(source, replace_range.clone(), &replacement);
    if !image_spans(&candidate)
        .iter()
        .any(|span| span.full == full_range && span.alternative == alternative_range)
    {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range,
        replacement,
        selection_range: alternative_range,
    })
}

pub fn insert_table_with_dimensions(
    source: &str,
    requested_selection: Range<usize>,
    columns: usize,
    rows: usize,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }
    if !(2..=10).contains(&columns) || !(2..=10).contains(&rows) {
        return Err(FormatError::AmbiguousSelection);
    }
    let tables = table_spans(source);
    if tables.iter().any(|table| {
        ranges_overlap(&requested_selection, &table.full)
            || (requested_selection.is_empty()
                && table.full.start <= requested_selection.start
                && requested_selection.start <= table.full.end)
    }) {
        return Err(FormatError::AmbiguousSelection);
    }

    let label = if requested_selection.is_empty() {
        "标题 1".to_owned()
    } else {
        escaped_table_cell(&source[requested_selection.clone()])
    };
    let prefix = if requested_selection.start > 0
        && source.as_bytes()[requested_selection.start - 1] != b'\n'
    {
        "\n\n"
    } else {
        ""
    };
    let suffix = if requested_selection.end < source.len()
        && source.as_bytes()[requested_selection.end] != b'\n'
    {
        "\n\n"
    } else {
        ""
    };
    let mut header_cells = (1..=columns)
        .map(|column| format!("标题 {column}"))
        .collect::<Vec<_>>();
    header_cells[0].clone_from(&label);
    let header = format!("| {} |", header_cells.join(" | "));
    let delimiter = format!("| {} |", vec!["---"; columns].join(" | "));
    let mut table_lines = vec![header, delimiter];
    let mut content_index = 1;
    for _ in 1..rows {
        let cells = (0..columns)
            .map(|_| {
                let cell = format!("内容 {content_index}");
                content_index += 1;
                cell
            })
            .collect::<Vec<_>>();
        table_lines.push(format!("| {} |", cells.join(" | ")));
    }
    let table = table_lines.join("\n");
    let replacement = format!("{prefix}{table}{suffix}");
    let table_start = requested_selection.start + prefix.len();
    let label_start = table_start + 2;
    let label_range = label_start..label_start + label.len();
    let candidate = replacing(source, requested_selection.clone(), &replacement);
    if !table_spans(&candidate).iter().any(|span| {
        span.full.start == table_start && span.columns == columns && span.body_rows == rows - 1
    }) {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range: requested_selection,
        replacement,
        selection_range: label_range,
    })
}

pub fn insert_horizontal_rule(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }

    let insertion_point = requested_selection.end;
    let leading_newlines = consecutive_newlines_before(source, insertion_point).min(2);
    let prefix = "\n".repeat(if insertion_point == 0 {
        0
    } else {
        2 - leading_newlines
    });
    let trailing_newlines = consecutive_newlines_after(source, insertion_point).min(2);
    let suffix = "\n".repeat(2 - trailing_newlines);
    let replacement = format!("{prefix}---{suffix}");
    let rule_start = insertion_point + prefix.len();
    let candidate = replacing(source, insertion_point..insertion_point, &replacement);
    if !horizontal_rule_ranges(&candidate)
        .iter()
        .any(|range| range.start == rule_start)
    {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range: insertion_point..insertion_point,
        selection_range: insertion_point + replacement.len()..insertion_point + replacement.len(),
        replacement,
    })
}

pub fn insert_footnote(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }

    let used_names = footnote_names(source);
    let identifier = (1..=used_names.len() + 1)
        .map(|number| format!("note-{number}"))
        .find(|candidate| !used_names.contains(candidate))
        .ok_or(FormatError::AmbiguousSelection)?;
    let insertion_point = requested_selection.end;
    let reference = format!("[^{identifier}]");
    let mut replacement = format!("{reference}{}", &source[insertion_point..]);
    let trailing_newlines = replacement
        .as_bytes()
        .iter()
        .rev()
        .take_while(|byte| **byte == b'\n')
        .count()
        .min(2);
    replacement.push_str(&"\n".repeat(2 - trailing_newlines));
    let definition_start = insertion_point + replacement.len();
    let definition_prefix = format!("[^{identifier}]: ");
    replacement.push_str(&definition_prefix);
    let placeholder_start = insertion_point + replacement.len();
    replacement.push_str("脚注内容\n");
    let placeholder_end = insertion_point + replacement.len() - 1;

    let replace_range = insertion_point..source.len();
    let candidate = replacing(source, replace_range.clone(), &replacement);
    let (references, definitions) = footnote_parts(&candidate, &identifier);
    if !references
        .iter()
        .any(|range| range.start == insertion_point)
        || !definitions
            .iter()
            .any(|range| range.start == definition_start)
    {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range,
        replacement,
        selection_range: placeholder_start..placeholder_end,
    })
}

pub fn insert_math(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }
    if math_spans(source)
        .iter()
        .any(|span| ranges_overlap(&requested_selection, &span.full))
    {
        return Err(FormatError::AmbiguousSelection);
    }

    let selected = &source[requested_selection.clone()];
    if selected.contains('$') {
        return Err(FormatError::AmbiguousSelection);
    }
    let display = requested_selection.is_empty() || selected.contains('\n');
    let content = if requested_selection.is_empty() {
        "公式内容"
    } else {
        selected
    };
    let (replacement, content_start, full_start) = if display {
        let prefix = if requested_selection.start > 0
            && source.as_bytes()[requested_selection.start - 1] != b'\n'
        {
            "\n\n"
        } else {
            ""
        };
        let suffix = if requested_selection.end < source.len()
            && source.as_bytes()[requested_selection.end] != b'\n'
        {
            "\n\n"
        } else {
            ""
        };
        let replacement = format!("{prefix}$$\n{content}\n$${suffix}");
        let content_start = requested_selection.start + prefix.len() + 3;
        (
            replacement,
            content_start,
            requested_selection.start + prefix.len(),
        )
    } else {
        let replacement = format!("${content}$");
        let content_start = requested_selection.start + 1;
        (replacement, content_start, requested_selection.start)
    };
    let content_range = content_start..content_start + content.len();
    let candidate = replacing(source, requested_selection.clone(), &replacement);
    if !math_spans(&candidate).iter().any(|span| {
        span.full.start == full_start && span.content == content_range && span.display == display
    }) {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range: requested_selection,
        replacement,
        selection_range: content_range,
    })
}

pub fn insert_mermaid(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }
    if fenced_code_spans(source)
        .iter()
        .any(|span| ranges_overlap(&requested_selection, &span.full))
    {
        return Err(FormatError::AmbiguousSelection);
    }

    let content = if requested_selection.is_empty() {
        "flowchart TD\n    A[开始] --> B[结束]"
    } else {
        &source[requested_selection.clone()]
    };
    // Syntax validation belongs to mermaid.js. Insertion only requires nonempty source.
    if content.trim().is_empty() {
        return Err(FormatError::AmbiguousSelection);
    }
    let prefix = if requested_selection.start > 0
        && source.as_bytes()[requested_selection.start - 1] != b'\n'
    {
        "\n\n"
    } else {
        ""
    };
    let suffix = if requested_selection.end < source.len()
        && source.as_bytes()[requested_selection.end] != b'\n'
    {
        "\n\n"
    } else {
        ""
    };
    let fence = "`".repeat(longest_backtick_run(content).saturating_add(1).max(3));
    let content_has_line_ending = content.ends_with('\n');
    let mut replacement = format!("{prefix}{fence}mermaid\n{content}");
    if !content_has_line_ending {
        replacement.push('\n');
    }
    replacement.push_str(&fence);
    replacement.push_str(suffix);
    let full_start = requested_selection.start + prefix.len();
    let content_start = full_start + fence.len() + "mermaid\n".len();
    let content_range = content_start..content_start + without_trailing_line_ending(content);
    let candidate = replacing(source, requested_selection.clone(), &replacement);
    if !mermaid_code_ranges(&candidate)
        .iter()
        .any(|range| range.start == full_start)
    {
        return Err(FormatError::AmbiguousSelection);
    }

    Ok(MarkdownEdit {
        replace_range: requested_selection,
        replacement,
        selection_range: content_range,
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

pub fn format_block_quote(
    source: &str,
    requested_selection: Range<usize>,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }

    let document_analysis = analysis::analyze(source);
    let initial_range = heading_aware_line_range(
        source,
        requested_selection.clone(),
        &document_analysis.headings,
    );
    let quote_spans = block_quote_spans(source);
    let block_range = quote_aware_line_range(
        source,
        requested_selection.clone(),
        initial_range,
        &quote_spans,
    );
    let lines = physical_line_ranges(source, block_range.clone());
    let markers: Vec<Option<Range<usize>>> = lines
        .iter()
        .map(|line| block_quote_marker_range(source, line.clone()))
        .collect();
    let remove = markers.iter().all(Option::is_some);

    let mut replacement = String::with_capacity(block_range.len() + lines.len() * 2);
    let mut outputs = Vec::with_capacity(lines.len());
    for (line, marker) in lines.iter().zip(markers) {
        let new_line_start = replacement.len();
        if remove {
            let marker = marker.ok_or(FormatError::AmbiguousSelection)?;
            replacement.push_str(&source[line.start..marker.start]);
            replacement.push_str(&source[marker.end..line.end]);
            let new_line_end = replacement.len();
            outputs.push(QuoteLineOutput {
                old_line_start: line.start,
                new_line_start,
                old_range: line.clone(),
                old_probe: line_probe(source, line.clone()),
                new_probe: line_probe(&replacement, new_line_start..new_line_end),
                removed_marker: Some(marker),
            });
        } else {
            replacement.push_str("> ");
            replacement.push_str(&source[line.clone()]);
            let new_line_end = replacement.len();
            outputs.push(QuoteLineOutput {
                old_line_start: line.start,
                new_line_start,
                old_range: line.clone(),
                old_probe: line_probe(source, line.clone()),
                new_probe: line_probe(&replacement, new_line_start..new_line_end),
                removed_marker: None,
            });
        }
    }

    let candidate = replacing(source, block_range.clone(), &replacement);
    let candidate_spans = block_quote_spans(&candidate);
    for output in &outputs {
        let old_depth = block_quote_depth_at(&quote_spans, output.old_probe);
        let new_depth =
            block_quote_depth_at(&candidate_spans, block_range.start + output.new_probe);
        let valid = if remove {
            old_depth > 0 && new_depth + 1 == old_depth
        } else {
            new_depth == old_depth + 1
        };
        if !valid {
            return Err(FormatError::AmbiguousSelection);
        }
    }

    let selection_range = if requested_selection.is_empty() {
        let caret = requested_selection.start;
        let output = outputs
            .iter()
            .find(|output| output.old_range.start <= caret && caret <= output.old_range.end)
            .ok_or(FormatError::InvalidSelection)?;
        let old_offset = caret - output.old_line_start;
        let new_offset = if let Some(marker) = &output.removed_marker {
            if caret <= marker.start {
                old_offset
            } else {
                old_offset.saturating_sub((caret.min(marker.end)) - marker.start)
            }
        } else {
            old_offset + 2
        };
        let new_caret = block_range.start + output.new_line_start + new_offset;
        new_caret..new_caret
    } else {
        block_range.start..block_range.start + without_trailing_line_ending(&replacement)
    };

    Ok(MarkdownEdit {
        replace_range: block_range,
        replacement,
        selection_range,
    })
}

pub fn format_list(
    source: &str,
    requested_selection: Range<usize>,
    format: ListFormat,
) -> Result<MarkdownEdit, FormatError> {
    if !is_valid_selection(source, &requested_selection) {
        return Err(FormatError::InvalidSelection);
    }

    let block_range = selected_line_range(source, requested_selection.clone());
    let lines = physical_line_ranges(source, block_range.clone());
    let markers: Vec<Option<ListMarker>> = lines
        .iter()
        .map(|line| list_marker(source, line.clone()))
        .collect();
    let caret = requested_selection.start;
    let actionable: Vec<bool> = lines
        .iter()
        .zip(&markers)
        .map(|(line, marker)| {
            marker.is_some()
                || line_has_content(source, line.clone())
                || (requested_selection.is_empty() && line.start <= caret && caret <= line.end)
        })
        .collect();
    if !actionable.iter().any(|value| *value) {
        return Err(FormatError::AmbiguousSelection);
    }

    let original_items = semantic_list_items(source);
    let remove = markers
        .iter()
        .zip(&actionable)
        .filter(|(_, actionable)| **actionable)
        .all(|(marker, _)| marker.is_some_and(|marker| marker.kind == format));
    if remove {
        for marker in markers.iter().flatten() {
            if !original_items
                .iter()
                .any(|item| item.source_start == marker.marker_start && item.kind == format)
            {
                return Err(FormatError::AmbiguousSelection);
            }
        }
    }

    let (replacement, outputs) = build_list_replacement(
        source,
        block_range.len(),
        &lines,
        &markers,
        &actionable,
        format,
        remove,
    )?;

    let candidate = replacing(source, block_range.clone(), &replacement);
    let candidate_items = semantic_list_items(&candidate);
    for output in outputs.iter().filter(|output| output.actionable) {
        let expected_start = block_range.start + output.marker_start;
        let item = candidate_items
            .iter()
            .find(|item| item.source_start == expected_start);
        if remove {
            if item.is_some_and(|item| item.kind == format) {
                return Err(FormatError::AmbiguousSelection);
            }
        } else if item.is_none_or(|item| item.kind != format) {
            return Err(FormatError::AmbiguousSelection);
        }
    }

    let selection_range = if requested_selection.is_empty() {
        let output = outputs
            .iter()
            .find(|output| output.old_range.start <= caret && caret <= output.old_range.end)
            .ok_or(FormatError::InvalidSelection)?;
        let old_content_end = trailing_line_ending_start(source, output.old_range.clone());
        let content_offset = caret
            .saturating_sub(output.old_content_start)
            .min(old_content_end.saturating_sub(output.old_content_start));
        let new_caret = block_range.start + output.new_content_start + content_offset;
        new_caret..new_caret
    } else {
        block_range.start..block_range.start + without_trailing_line_ending(&replacement)
    };

    Ok(MarkdownEdit {
        replace_range: block_range,
        replacement,
        selection_range,
    })
}

fn build_list_replacement(
    source: &str,
    source_length: usize,
    lines: &[Range<usize>],
    markers: &[Option<ListMarker>],
    actionable: &[bool],
    format: ListFormat,
    remove: bool,
) -> Result<(String, Vec<ListLineOutput>), FormatError> {
    let mut replacement = String::with_capacity(source_length + lines.len() * 6);
    let mut outputs = Vec::with_capacity(lines.len());
    for ((line, marker), actionable) in lines.iter().zip(markers).zip(actionable.iter().copied()) {
        let new_line_start = replacement.len();
        let indentation_end = leading_indentation_end(source, line.clone());
        let old_content_start = marker.map_or(indentation_end, |value| value.content_start);
        let marker_start = marker.map_or(indentation_end, |value| value.marker_start);
        let new_content_start;

        if !actionable {
            replacement.push_str(&source[line.clone()]);
            new_content_start = new_line_start + old_content_start - line.start;
        } else if remove {
            let marker = marker.ok_or(FormatError::AmbiguousSelection)?;
            replacement.push_str(&source[line.start..marker.marker_start]);
            new_content_start = replacement.len();
            replacement.push_str(&source[marker.marker_end..line.end]);
        } else {
            replacement.push_str(&source[line.start..marker_start]);
            let marker_text = match format {
                ListFormat::Unordered => "- ".to_owned(),
                ListFormat::Ordered => "1. ".to_owned(),
                ListFormat::Task => {
                    if marker.is_some_and(|value| value.kind == ListFormat::Task && value.checked) {
                        "- [x] ".to_owned()
                    } else {
                        "- [ ] ".to_owned()
                    }
                }
            };
            replacement.push_str(&marker_text);
            new_content_start = replacement.len();
            replacement.push_str(&source[old_content_start..line.end]);
        }

        outputs.push(ListLineOutput {
            old_range: line.clone(),
            old_content_start,
            new_content_start,
            marker_start: new_line_start + marker_start - line.start,
            actionable,
        });
    }
    Ok((replacement, outputs))
}

fn selected_line_range(source: &str, selection: Range<usize>) -> Range<usize> {
    let start = line_start(source, selection.start);
    let end_anchor = if !selection.is_empty()
        && source.as_bytes().get(selection.end.saturating_sub(1)) == Some(&b'\n')
    {
        selection.end - 1
    } else {
        selection.end
    };
    start..line_end_including_ending(source, end_anchor)
}

fn leading_indentation_end(source: &str, line: Range<usize>) -> usize {
    let content_end = trailing_line_ending_start(source, line.clone());
    let bytes = source.as_bytes();
    let mut cursor = line.start;
    while cursor < content_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    cursor
}

fn line_has_content(source: &str, line: Range<usize>) -> bool {
    leading_indentation_end(source, line.clone()) < trailing_line_ending_start(source, line)
}

fn list_marker(source: &str, line: Range<usize>) -> Option<ListMarker> {
    let bytes = source.as_bytes();
    let content_end = trailing_line_ending_start(source, line.clone());
    let marker_start = leading_indentation_end(source, line);
    if marker_start >= content_end {
        return None;
    }

    if matches!(bytes[marker_start], b'-' | b'+' | b'*') {
        let mut cursor = marker_start + 1;
        if cursor < content_end && !matches!(bytes[cursor], b' ' | b'\t') {
            return None;
        }
        while cursor < content_end && matches!(bytes[cursor], b' ' | b'\t') {
            cursor += 1;
        }
        let checkbox_start = cursor;
        if checkbox_start + 3 <= content_end
            && bytes[checkbox_start] == b'['
            && matches!(bytes[checkbox_start + 1], b' ' | b'x' | b'X')
            && bytes[checkbox_start + 2] == b']'
            && (checkbox_start + 3 == content_end
                || matches!(bytes[checkbox_start + 3], b' ' | b'\t'))
        {
            cursor = checkbox_start + 3;
            while cursor < content_end && matches!(bytes[cursor], b' ' | b'\t') {
                cursor += 1;
            }
            return Some(ListMarker {
                kind: ListFormat::Task,
                marker_start,
                marker_end: cursor,
                content_start: cursor,
                checked: matches!(bytes[checkbox_start + 1], b'x' | b'X'),
            });
        }
        return Some(ListMarker {
            kind: ListFormat::Unordered,
            marker_start,
            marker_end: cursor,
            content_start: cursor,
            checked: false,
        });
    }

    let mut cursor = marker_start;
    while cursor < content_end && bytes[cursor].is_ascii_digit() && cursor - marker_start < 9 {
        cursor += 1;
    }
    if cursor == marker_start || cursor >= content_end || !matches!(bytes[cursor], b'.' | b')') {
        return None;
    }
    cursor += 1;
    if cursor < content_end && !matches!(bytes[cursor], b' ' | b'\t') {
        return None;
    }
    while cursor < content_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    Some(ListMarker {
        kind: ListFormat::Ordered,
        marker_start,
        marker_end: cursor,
        content_start: cursor,
        checked: false,
    })
}

fn semantic_list_items(source: &str) -> Vec<SemanticListItem> {
    let mut list_stack: Vec<ListFormat> = Vec::new();
    let mut item_stack: Vec<usize> = Vec::new();
    let mut items = Vec::new();

    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        match event {
            Event::Start(Tag::List(start)) => list_stack.push(if start.is_some() {
                ListFormat::Ordered
            } else {
                ListFormat::Unordered
            }),
            Event::Start(Tag::Item) => {
                let kind = list_stack.last().copied().unwrap_or(ListFormat::Unordered);
                items.push(SemanticListItem {
                    source_start: range.start,
                    source_end: range.end,
                    kind,
                });
                item_stack.push(items.len() - 1);
            }
            Event::TaskListMarker(_) => {
                if let Some(index) = item_stack.last().copied() {
                    items[index].kind = ListFormat::Task;
                }
            }
            Event::End(TagEnd::Item) => {
                item_stack.pop();
            }
            Event::End(TagEnd::List(_)) => {
                list_stack.pop();
            }
            _ => {}
        }
    }
    items
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

fn quote_aware_line_range(
    source: &str,
    selection: Range<usize>,
    mut range: Range<usize>,
    quote_spans: &[Range<usize>],
) -> Range<usize> {
    loop {
        let previous = range.clone();
        for quote in quote_spans {
            if ranges_overlap(&range, quote)
                || (selection.is_empty()
                    && quote.start <= selection.start
                    && selection.start <= quote.end)
            {
                range.start = range.start.min(line_start(source, quote.start));
                range.end = range.end.max(line_end_including_ending(source, quote.end));
            }
        }
        if range == previous {
            return range;
        }
    }
}

fn physical_line_ranges(source: &str, block_range: Range<usize>) -> Vec<Range<usize>> {
    if block_range.is_empty() {
        return vec![block_range];
    }

    let mut lines = Vec::new();
    let mut cursor = block_range.start;
    while cursor < block_range.end {
        let end = line_end_including_ending(source, cursor).min(block_range.end);
        lines.push(cursor..end);
        cursor = end;
    }
    lines
}

fn block_quote_marker_range(source: &str, line: Range<usize>) -> Option<Range<usize>> {
    let bytes = source.as_bytes();
    let content_end = trailing_line_ending_start(source, line.clone());
    let mut cursor = line.start;
    let mut indentation = 0;
    while cursor < content_end && bytes[cursor] == b' ' && indentation < 3 {
        cursor += 1;
        indentation += 1;
    }
    if cursor >= content_end || bytes[cursor] != b'>' {
        return None;
    }
    let marker_start = cursor;
    cursor += 1;
    if cursor < content_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    Some(marker_start..cursor)
}

fn block_quote_spans(source: &str) -> Vec<Range<usize>> {
    let mut starts = Vec::new();
    let mut spans = Vec::new();
    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        match event {
            Event::Start(Tag::BlockQuote(_)) => starts.push(range.start),
            Event::End(TagEnd::BlockQuote(_)) => {
                if let Some(start) = starts.pop() {
                    spans.push(start..range.end);
                }
            }
            _ => {}
        }
    }
    spans
}

fn block_quote_depth_at(spans: &[Range<usize>], position: usize) -> usize {
    spans
        .iter()
        .filter(|span| span.start <= position && (position < span.end || span.start == span.end))
        .count()
}

fn line_probe(source: &str, line: Range<usize>) -> usize {
    let content_end = trailing_line_ending_start(source, line.clone());
    if content_end > line.start {
        content_end - 1
    } else {
        line.start
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

fn inline_code_spans(source: &str) -> Vec<FormatSpan> {
    Parser::new_ext(source, render::options())
        .into_offset_iter()
        .filter_map(|(event, range)| {
            if !matches!(event, Event::Code(_)) {
                return None;
            }
            let raw = &source[range.clone()];
            let delimiter_length = raw.bytes().take_while(|byte| *byte == b'`').count();
            if delimiter_length == 0
                || raw.bytes().rev().take_while(|byte| *byte == b'`').count() != delimiter_length
                || delimiter_length * 2 > raw.len()
            {
                return None;
            }
            let mut content_start = range.start + delimiter_length;
            let mut content_end = range.end - delimiter_length;
            let interior = &source[content_start..content_end];
            if interior.starts_with(' ')
                && interior.ends_with(' ')
                && interior.bytes().any(|byte| byte != b' ')
            {
                content_start += 1;
                content_end -= 1;
            }
            Some(FormatSpan {
                full_range: range,
                content_range: content_start..content_end,
            })
        })
        .collect()
}

fn fenced_code_spans(source: &str) -> Vec<FencedCodeSpan> {
    Parser::new_ext(source, render::options())
        .into_offset_iter()
        .filter_map(|(event, full_range)| {
            if !matches!(
                event,
                Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(_)))
            ) {
                return None;
            }
            let opening_line = line_start(source, full_range.start)
                ..line_end_including_ending(source, full_range.start).min(full_range.end);
            let (marker, opening_length) = fence_marker(source, opening_line.clone())?;
            let mut cursor = opening_line.end;
            let mut closing_line = None;
            while cursor < full_range.end {
                let line = cursor..line_end_including_ending(source, cursor).min(full_range.end);
                if closing_fence_length(source, line.clone(), marker)
                    .is_some_and(|length| length >= opening_length)
                {
                    closing_line = Some(line.clone());
                }
                if line.end == cursor {
                    break;
                }
                cursor = line.end;
            }
            let closing_line = closing_line?;
            let content_range = opening_line.end..closing_line.start;
            let closing_has_line_ending = source[closing_line.clone()].ends_with('\n');
            let unwrapped_end =
                if !closing_has_line_ending && source[content_range.clone()].ends_with('\n') {
                    content_range.end - 1
                } else {
                    content_range.end
                };
            Some(FencedCodeSpan {
                full: full_range,
                content: content_range.clone(),
                unwrapped_content: content_range.start..unwrapped_end,
                selection_content: content_range.start
                    ..content_range.start
                        + without_trailing_line_ending(&source[content_range.clone()]),
            })
        })
        .collect()
}

fn link_spans(source: &str) -> Vec<LinkSpan> {
    #[derive(Debug)]
    struct OpenLink {
        full: Range<usize>,
        label_start: Option<usize>,
        label_end: Option<usize>,
    }

    let mut stack: Vec<OpenLink> = Vec::new();
    let mut spans = Vec::new();
    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        match event {
            Event::Start(Tag::Link { .. }) => stack.push(OpenLink {
                full: range,
                label_start: None,
                label_end: None,
            }),
            Event::End(TagEnd::Link) => {
                let Some(link) = stack.pop() else { continue };
                let empty_label = link.full.start.saturating_add(1);
                let label_start = link.label_start.unwrap_or(empty_label);
                let label_end = link.label_end.unwrap_or(label_start);
                if link.full.start <= label_start
                    && label_start <= label_end
                    && label_end <= link.full.end
                {
                    spans.push(LinkSpan {
                        full: link.full,
                        label: label_start..label_end,
                    });
                }
            }
            _ => {
                if let Some(link) = stack.last_mut() {
                    link.label_start = Some(
                        link.label_start
                            .map_or(range.start, |start| start.min(range.start)),
                    );
                    link.label_end =
                        Some(link.label_end.map_or(range.end, |end| end.max(range.end)));
                }
            }
        }
    }
    spans
}

fn image_spans(source: &str) -> Vec<ImageSpan> {
    #[derive(Debug)]
    struct OpenImage {
        full: Range<usize>,
        alternative_start: Option<usize>,
        alternative_end: Option<usize>,
    }

    let mut stack: Vec<OpenImage> = Vec::new();
    let mut spans = Vec::new();
    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        match event {
            Event::Start(Tag::Image { .. }) => stack.push(OpenImage {
                full: range,
                alternative_start: None,
                alternative_end: None,
            }),
            Event::End(TagEnd::Image) => {
                let Some(image) = stack.pop() else { continue };
                let empty_alternative = image.full.start.saturating_add(2);
                let alternative_start = image.alternative_start.unwrap_or(empty_alternative);
                let alternative_end = image.alternative_end.unwrap_or(alternative_start);
                if image.full.start <= alternative_start
                    && alternative_start <= alternative_end
                    && alternative_end <= image.full.end
                {
                    spans.push(ImageSpan {
                        full: image.full,
                        alternative: alternative_start..alternative_end,
                    });
                }
            }
            _ => {
                if let Some(image) = stack.last_mut() {
                    image.alternative_start = Some(
                        image
                            .alternative_start
                            .map_or(range.start, |start| start.min(range.start)),
                    );
                    image.alternative_end = Some(
                        image
                            .alternative_end
                            .map_or(range.end, |end| end.max(range.end)),
                    );
                }
            }
        }
    }
    spans
}

fn is_valid_destination(destination: &str) -> bool {
    !destination.is_empty()
        && !destination
            .chars()
            .any(|character| character.is_control() || matches!(character, '<' | '>' | '\\'))
}

fn escaped_link_label(label: &str) -> String {
    label.chars().fold(
        String::with_capacity(label.len()),
        |mut escaped, character| {
            if matches!(character, '\\' | '[' | ']') {
                escaped.push('\\');
            }
            escaped.push(character);
            escaped
        },
    )
}

fn table_spans(source: &str) -> Vec<TableSpan> {
    let mut open: Vec<TableSpan> = Vec::new();
    let mut spans = Vec::new();
    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        match event {
            Event::Start(Tag::Table(alignments)) => open.push(TableSpan {
                full: range,
                columns: alignments.len(),
                body_rows: 0,
            }),
            Event::Start(Tag::TableRow) => {
                if let Some(table) = open.last_mut() {
                    table.body_rows += 1;
                }
            }
            Event::End(TagEnd::Table) => {
                if let Some(table) = open.pop() {
                    spans.push(table);
                }
            }
            _ => {}
        }
    }
    spans
}

fn horizontal_rule_ranges(source: &str) -> Vec<Range<usize>> {
    Parser::new_ext(source, render::options())
        .into_offset_iter()
        .filter_map(|(event, range)| matches!(event, Event::Rule).then_some(range))
        .collect()
}

fn footnote_names(source: &str) -> Vec<String> {
    Parser::new_ext(source, render::options())
        .filter_map(|event| match event {
            Event::Start(Tag::FootnoteDefinition(name)) | Event::FootnoteReference(name) => {
                Some(name.into_string())
            }
            _ => None,
        })
        .collect()
}

fn footnote_parts(source: &str, identifier: &str) -> (Vec<Range<usize>>, Vec<Range<usize>>) {
    let mut references = Vec::new();
    let mut definitions = Vec::new();
    for (event, range) in Parser::new_ext(source, render::options()).into_offset_iter() {
        match event {
            Event::FootnoteReference(name) if name.as_ref() == identifier => references.push(range),
            Event::Start(Tag::FootnoteDefinition(name)) if name.as_ref() == identifier => {
                definitions.push(range);
            }
            _ => {}
        }
    }
    (references, definitions)
}

fn math_spans(source: &str) -> Vec<MathSpan> {
    Parser::new_ext(source, render::options())
        .into_offset_iter()
        .filter_map(|(event, full)| {
            let (delimiter_length, display) = match event {
                Event::InlineMath(_) => (1, false),
                Event::DisplayMath(_) => (2, true),
                _ => return None,
            };
            let mut content_start = full.start + delimiter_length;
            let mut content_end = full.end.checked_sub(delimiter_length)?;
            if display && source.as_bytes().get(content_start) == Some(&b'\n') {
                content_start += 1;
            }
            if display
                && content_end > content_start
                && source.as_bytes().get(content_end - 1) == Some(&b'\n')
            {
                content_end -= 1;
            }
            (content_start <= content_end).then_some(MathSpan {
                full,
                content: content_start..content_end,
                display,
            })
        })
        .collect()
}

fn mermaid_code_ranges(source: &str) -> Vec<Range<usize>> {
    Parser::new_ext(source, render::options())
        .into_offset_iter()
        .filter_map(|(event, range)| match event {
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(language)))
                if language
                    .split_ascii_whitespace()
                    .next()
                    .is_some_and(|name| name.eq_ignore_ascii_case("mermaid")) =>
            {
                Some(range)
            }
            _ => None,
        })
        .collect()
}

fn consecutive_newlines_before(source: &str, position: usize) -> usize {
    source.as_bytes()[..position]
        .iter()
        .rev()
        .take_while(|byte| **byte == b'\n')
        .count()
}

fn consecutive_newlines_after(source: &str, position: usize) -> usize {
    source.as_bytes()[position..]
        .iter()
        .take_while(|byte| **byte == b'\n')
        .count()
}

fn escaped_table_cell(content: &str) -> String {
    content.chars().fold(
        String::with_capacity(content.len()),
        |mut escaped, character| {
            match character {
                '\\' => escaped.push_str("\\\\"),
                '|' => escaped.push_str("\\|"),
                '\n' => escaped.push_str("<br>"),
                _ => escaped.push(character),
            }
            escaped
        },
    )
}

fn fence_marker(source: &str, line: Range<usize>) -> Option<(u8, usize)> {
    let bytes = source.as_bytes();
    let content_end = trailing_line_ending_start(source, line.clone());
    let mut cursor = line.start;
    let mut indentation = 0;
    while cursor < content_end && bytes[cursor] == b' ' && indentation < 3 {
        cursor += 1;
        indentation += 1;
    }
    if cursor >= content_end || !matches!(bytes[cursor], b'`' | b'~') {
        return None;
    }
    let marker = bytes[cursor];
    let marker_start = cursor;
    while cursor < content_end && bytes[cursor] == marker {
        cursor += 1;
    }
    let marker_length = cursor - marker_start;
    (marker_length >= 3).then_some((marker, marker_length))
}

fn closing_fence_length(source: &str, line: Range<usize>, marker: u8) -> Option<usize> {
    let bytes = source.as_bytes();
    let content_end = trailing_line_ending_start(source, line.clone());
    let mut cursor = line.start;
    let mut indentation = 0;
    while cursor < content_end && bytes[cursor] == b' ' && indentation < 3 {
        cursor += 1;
        indentation += 1;
    }
    let marker_start = cursor;
    while cursor < content_end && bytes[cursor] == marker {
        cursor += 1;
    }
    let marker_length = cursor - marker_start;
    while cursor < content_end && matches!(bytes[cursor], b' ' | b'\t') {
        cursor += 1;
    }
    (marker_length >= 3 && cursor == content_end).then_some(marker_length)
}

fn longest_backtick_run(text: &str) -> usize {
    text.bytes()
        .fold((0, 0), |(longest, current), byte| {
            if byte == b'`' {
                let next = current + 1;
                (longest.max(next), next)
            } else {
                (longest, 0)
            }
        })
        .0
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
    fn adds_quote_to_current_unicode_line_and_empty_document() {
        let source = "前文\n引用👩‍💻\n";
        let line_start = "前文\n".len();
        let caret = line_start + "引用".len();
        assert_eq!(
            format_block_quote(source, caret..caret),
            Ok(MarkdownEdit {
                replace_range: line_start..source.len(),
                replacement: "> 引用👩‍💻\n".to_owned(),
                selection_range: caret + 2..caret + 2,
            })
        );
        assert_eq!(
            format_block_quote("", 0..0),
            Ok(MarkdownEdit {
                replace_range: 0..0,
                replacement: "> ".to_owned(),
                selection_range: 2..2,
            })
        );
    }

    #[test]
    fn adds_and_removes_multiline_quote_with_blank_line() {
        let source = "one\n\n二\n";
        let added = format_block_quote(source, 0..source.len()).unwrap();
        assert_eq!(added.replacement, "> one\n> \n> 二\n");
        let formatted = replacing(source, added.replace_range, &added.replacement);
        assert!(render::html_fragment(&formatted).contains("<blockquote>"));

        let removed = format_block_quote(&formatted, 0..formatted.len()).unwrap();
        assert_eq!(removed.replacement, source);
        assert_eq!(
            replacing(&formatted, removed.replace_range, &removed.replacement),
            source
        );
    }

    #[test]
    fn removes_one_nested_quote_level_and_preserves_caret() {
        let nested = "> > inner\n> > next\n";
        let removed = format_block_quote(nested, 5..5).unwrap();
        assert_eq!(removed.replace_range, 0..nested.len());
        assert_eq!(removed.replacement, "> inner\n> next\n");

        let single = "> text\n";
        let removed = format_block_quote(single, 4..4).unwrap();
        assert_eq!(removed.replacement, "text\n");
        assert_eq!(removed.selection_range, 2..2);
    }

    #[test]
    fn quote_requires_a_real_block_quote_and_preserves_complete_code_fence() {
        let fenced = "```\ninside\n```\n";
        assert_eq!(
            format_block_quote(fenced, 6..6),
            Err(FormatError::AmbiguousSelection)
        );

        let quoted = format_block_quote(fenced, 0..fenced.len()).unwrap();
        assert_eq!(quoted.replacement, "> ```\n> inside\n> ```\n");
        let result = replacing(fenced, quoted.replace_range, &quoted.replacement);
        let html = render::html_fragment(&result);
        assert!(html.contains("<blockquote>"));
        assert!(html.contains("<pre><code>inside\n</code></pre>"));
    }

    #[test]
    fn quote_rejects_invalid_selection_and_deepens_lazy_continuation() {
        assert_eq!(
            format_block_quote("e\u{301}", 1..1),
            Err(FormatError::InvalidSelection)
        );
        let lazy = "> quoted\nlazy continuation\n";
        let edit = format_block_quote(lazy, 12..12).unwrap();
        assert_eq!(edit.replacement, "> > quoted\n> lazy continuation\n");
        let result = replacing(lazy, edit.replace_range, &edit.replacement);
        assert!(render::html_fragment(&result).contains("<blockquote>\n<blockquote>"));
    }

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
    fn inline_code_wraps_unicode_and_chooses_a_safe_delimiter() {
        let source = "before code `with` 中文 after";
        let start = "before ".len();
        let end = source.len() - " after".len();
        let edit = format_inline_code(source, start..end).unwrap();
        assert_eq!(edit.replacement, "``code `with` 中文``");
        assert_eq!(edit.selection_range, start + 2..end + 2);
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert!(render::html_fragment(&formatted).contains("<code>code `with` 中文</code>"));
    }

    #[test]
    fn inline_code_preserves_edge_spaces_and_removes_complete_span() {
        let source = "x leading and trailing y";
        let start = 1;
        let end = source.len() - 1;
        let added = format_inline_code(source, start..end).unwrap();
        assert_eq!(added.replacement, "`  leading and trailing  `");
        let formatted = replacing(source, added.replace_range, &added.replacement);
        let removed = format_inline_code(&formatted, added.selection_range).unwrap();
        assert_eq!(
            replacing(&formatted, removed.replace_range, &removed.replacement),
            source
        );
    }

    #[test]
    fn inline_code_inserts_template_and_rejects_partial_or_multiline_selection() {
        assert_eq!(
            format_inline_code("text", 2..2),
            Ok(MarkdownEdit {
                replace_range: 2..2,
                replacement: "``".to_owned(),
                selection_range: 3..3,
            })
        );
        assert_eq!(
            format_inline_code("`code`", 2..4),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            format_inline_code("one\ntwo", 0..7),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            format_inline_code("e\u{301}", 1..1),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn code_block_wraps_complete_lines_with_a_safe_fence_and_round_trips() {
        let source = "before\nlet value = ```raw```;\nprint(\"\u{4e2d}\u{6587}\")\nafter\n";
        let start = "before\n".len();
        let end = source.len() - "after\n".len() - 1;
        let added = format_code_block(source, start..end).unwrap();
        assert_eq!(added.replace_range, start..source.len() - "after\n".len());
        assert_eq!(
            added.replacement,
            "````\nlet value = ```raw```;\nprint(\"\u{4e2d}\u{6587}\")\n````\n"
        );
        let formatted = replacing(source, added.replace_range, &added.replacement);
        assert!(render::html_fragment(&formatted).contains("<pre><code>"));

        let removed = format_code_block(&formatted, added.selection_range).unwrap();
        assert_eq!(
            replacing(&formatted, removed.replace_range, &removed.replacement),
            source
        );
    }

    #[test]
    fn code_block_inserts_an_editable_template_at_empty_caret() {
        assert_eq!(
            format_code_block("", 0..0),
            Ok(MarkdownEdit {
                replace_range: 0..0,
                replacement: "```\n\n```".to_owned(),
                selection_range: 4..4,
            })
        );
        assert_eq!(
            format_code_block("text", 2..2),
            Ok(MarkdownEdit {
                replace_range: 2..2,
                replacement: "\n```\n\n```\n".to_owned(),
                selection_range: 7..7,
            })
        );

        let templated = "```\n\n```";
        let removed = format_code_block(templated, 4..4).unwrap();
        assert_eq!(removed.replacement, "");
        assert_eq!(removed.selection_range, 0..0);
    }

    #[test]
    fn code_block_removes_tilde_fence_and_rejects_partial_existing_block() {
        let source = "~~~swift\nprint(\"ok\")\n~~~\n";
        let caret = source.find("print").unwrap() + 2;
        let removed = format_code_block(source, caret..caret).unwrap();
        assert_eq!(removed.replacement, "print(\"ok\")");
        assert_eq!(removed.selection_range, 2..2);
        assert_eq!(
            replacing(source, removed.replace_range, &removed.replacement),
            "print(\"ok\")\n"
        );

        assert_eq!(
            format_code_block(source, 10..15),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            format_code_block("e\u{301}", 1..1),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn link_wraps_unicode_selection_and_inserts_empty_template() {
        let source = "Read 文档\u{1f469}\u{200d}\u{1f4bb} now";
        let start = "Read ".len();
        let end = source.len() - " now".len();
        let edit = insert_link(source, start..end, " https://example.com/a b ").unwrap();
        assert_eq!(
            edit.replacement,
            "[文档\u{1f469}\u{200d}\u{1f4bb}](<https://example.com/a b>)"
        );
        assert_eq!(edit.selection_range, start + 1..end + 1);
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert!(
            render::html_fragment(&formatted)
                .contains("href=\"https://example.com/a%20b\">文档\u{1f469}\u{200d}\u{1f4bb}</a>")
        );

        let empty = insert_link("", 0..0, "#section").unwrap();
        assert_eq!(empty.replacement, "[链接文字](<#section>)");
        assert_eq!(empty.selection_range, 1..13);
    }

    #[test]
    fn link_updates_complete_existing_link_without_nesting() {
        let source = "before [**bold**](old.md) after";
        let label_start = source.find("**bold**").unwrap();
        let label_end = label_start + "**bold**".len();
        let edit = insert_link(source, label_start..label_end, "guide/new.md").unwrap();
        assert_eq!(edit.replacement, "[**bold**](<guide/new.md>)");
        assert_eq!(
            replacing(source, edit.replace_range, &edit.replacement),
            "before [**bold**](<guide/new.md>) after"
        );
    }

    #[test]
    fn link_escapes_label_and_rejects_ambiguous_or_invalid_input() {
        let source = "choose [one]";
        let edit = insert_link(source, 0..source.len(), "mailto:a@example.com").unwrap();
        assert_eq!(
            edit.replacement,
            "[choose \\[one\\]](<mailto:a@example.com>)"
        );

        assert_eq!(
            insert_link("[label](old)", 2..4, "new"),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_link("text", 0..4, "https://example.com/<unsafe>"),
            Err(FormatError::InvalidSelection)
        );
        assert_eq!(
            insert_link("e\u{301}", 1..1, "https://example.com"),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn image_wraps_unicode_selection_and_uses_editable_default_alternative() {
        let source = "Before 文档\u{1f469}\u{200d}\u{1f4bb} after";
        let start = "Before ".len();
        let end = source.len() - " after".len();
        let edit = insert_image(source, start..end, "assets/cover image.png", "cover").unwrap();
        assert_eq!(
            edit.replacement,
            "![文档\u{1f469}\u{200d}\u{1f4bb}](<assets/cover image.png>)"
        );
        assert_eq!(edit.selection_range, start + 2..end + 2);
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert!(render::html_fragment(&formatted).contains("class=\"inflow-image-slot\""));

        let empty = insert_image("", 0..0, "assets/photo.jpg", "photo").unwrap();
        assert_eq!(empty.replacement, "![photo](<assets/photo.jpg>)");
        assert_eq!(empty.selection_range, 2..7);

        let existing = "前 ![旧图](<assets/old.png>) 后";
        let start = "前 ".len();
        let end = existing.len() - " 后".len();
        let update = insert_image(existing, start..end, "assets/new image.png", "unused").unwrap();
        assert_eq!(update.replace_range, start..end);
        assert_eq!(update.replacement, "![旧图](<assets/new image.png>)");
        assert_eq!(&update.replacement[2..8], "旧图");
    }

    #[test]
    fn image_rejects_unsafe_or_ambiguous_input() {
        assert_eq!(
            insert_image("text", 0..4, "../unsafe\\image.png", "image"),
            Err(FormatError::InvalidSelection)
        );
        assert_eq!(
            insert_image("text", 0..4, "assets/image.png", ""),
            Err(FormatError::InvalidSelection)
        );
        assert_eq!(
            insert_image("line one\nline two", 0..17, "assets/image.png", "image"),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_image("![old](<assets/old.png>)", 3..5, "assets/new.png", "new"),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_image("e\u{301}", 1..1, "assets/image.png", "image"),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn table_inserts_three_by_three_template_and_selects_first_header() {
        let edit = insert_table_with_dimensions("", 0..0, 3, 3).unwrap();
        assert_eq!(
            edit.replacement,
            "| 标题 1 | 标题 2 | 标题 3 |\n| --- | --- | --- |\n| 内容 1 | 内容 2 | 内容 3 |\n| 内容 4 | 内容 5 | 内容 6 |"
        );
        assert_eq!(edit.selection_range, 2..10);
        assert!(render::html_fragment(&edit.replacement).contains("<table>"));
    }

    #[test]
    fn table_inserts_requested_dimensions_and_rejects_unsupported_sizes() {
        let edit = insert_table_with_dimensions("", 0..0, 2, 4).unwrap();
        assert_eq!(
            edit.replacement,
            "| 标题 1 | 标题 2 |\n| --- | --- |\n| 内容 1 | 内容 2 |\n| 内容 3 | 内容 4 |\n| 内容 5 | 内容 6 |"
        );
        assert_eq!(edit.selection_range, 2..10);
        assert_eq!(
            insert_table_with_dimensions("", 0..0, 1, 3),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_table_with_dimensions("", 0..0, 3, 11),
            Err(FormatError::AmbiguousSelection)
        );
    }

    #[test]
    fn table_preserves_selection_with_cell_escaping_and_block_boundaries() {
        let source = "before A|B\nC after";
        let start = "before ".len();
        let end = source.len() - " after".len();
        let edit = insert_table_with_dimensions(source, start..end, 3, 3).unwrap();
        assert!(edit.replacement.starts_with("\n\n| A\\|B<br>C |"));
        assert!(edit.replacement.ends_with("|\n\n"));
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert!(render::html_fragment(&formatted).contains("<table>"));
        assert_eq!(&formatted[edit.selection_range], "A\\|B<br>C");
    }

    #[test]
    fn table_rejects_existing_table_and_invalid_grapheme_boundary() {
        let source = "| One | Two |\n| --- | --- |\n| A | B |\n";
        let caret = source.find('A').unwrap();
        assert_eq!(
            insert_table_with_dimensions(source, caret..caret, 3, 3),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_table_with_dimensions("e\u{301}", 1..1, 3, 3),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn horizontal_rule_inserts_a_real_block_and_leaves_an_editable_line() {
        let edit = insert_horizontal_rule("", 0..0).unwrap();
        assert_eq!(edit.replacement, "---\n\n");
        assert_eq!(edit.selection_range, 5..5);
        assert_eq!(horizontal_rule_ranges(&edit.replacement).len(), 1);
        assert!(render::html_fragment(&edit.replacement).contains("<hr />"));

        let source = "before\nafter";
        let caret = "before\n".len();
        let edit = insert_horizontal_rule(source, caret..caret).unwrap();
        assert_eq!(edit.replacement, "\n---\n\n");
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert_eq!(formatted, "before\n\n---\n\nafter");
        assert_eq!(horizontal_rule_ranges(&formatted).len(), 1);
    }

    #[test]
    fn horizontal_rule_preserves_selection_and_rejects_unsafe_contexts() {
        let source = "before 文字👩‍💻 after";
        let selected_end = source.find(" after").unwrap();
        let edit = insert_horizontal_rule(source, "before ".len()..selected_end).unwrap();
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert_eq!(formatted, "before 文字👩‍💻\n\n---\n\n after");
        assert!(formatted.starts_with(&source[..selected_end]));

        let fenced = "```text\ninside\n```\n";
        let caret = fenced.find("inside").unwrap() + 2;
        assert_eq!(
            insert_horizontal_rule(fenced, caret..caret),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_horizontal_rule("e\u{301}", 1..1),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn footnote_inserts_unique_reference_and_editable_definition() {
        let edit = insert_footnote("", 0..0).unwrap();
        assert_eq!(edit.replacement, "[^note-1]\n\n[^note-1]: 脚注内容\n");
        assert_eq!(&edit.replacement[edit.selection_range], "脚注内容");
        let (references, definitions) = footnote_parts(&edit.replacement, "note-1");
        assert_eq!(references.len(), 1);
        assert_eq!(definitions.len(), 1);
        let html = render::html_fragment(&edit.replacement);
        assert!(html.contains("footnote-reference"));
        assert!(html.contains("footnote-definition"));

        let source = "Existing[^note-1]\n\n[^note-1]: First\n";
        let edit = insert_footnote(source, "Existing".len().."Existing".len()).unwrap();
        assert!(edit.replacement.starts_with("[^note-2]"));
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert!(formatted.contains("[^note-2]: 脚注内容"));
    }

    #[test]
    fn footnote_preserves_selected_anchor_and_rejects_invalid_context() {
        let source = "Before 文本👩‍💻 after";
        let end = source.find(" after").unwrap();
        let edit = insert_footnote(source, "Before ".len()..end).unwrap();
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert!(formatted.starts_with("Before 文本👩‍💻[^note-1] after"));
        assert!(formatted.ends_with("[^note-1]: 脚注内容\n"));
        assert_eq!(&formatted[edit.selection_range], "脚注内容");

        let fenced = "```text\ninside\n```\n";
        let caret = fenced.find("inside").unwrap() + 2;
        assert_eq!(
            insert_footnote(fenced, caret..caret),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_footnote("e\u{301}", 1..1),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn math_wraps_single_line_and_inserts_editable_display_template() {
        let source = "Euler e^{i\\pi}+1=0 end";
        let start = "Euler ".len();
        let end = source.find(" end").unwrap();
        let inline = insert_math(source, start..end).unwrap();
        assert_eq!(inline.replacement, "$e^{i\\pi}+1=0$");
        assert_eq!(
            &inline.replacement[1..inline.replacement.len() - 1],
            &source[start..end]
        );
        let formatted = replacing(source, inline.replace_range, &inline.replacement);
        assert!(render::html_fragment(&formatted).contains("data-inflow-render=\"math\""));

        let display = insert_math("", 0..0).unwrap();
        assert_eq!(display.replacement, "$$\n公式内容\n$$");
        assert_eq!(&display.replacement[display.selection_range], "公式内容");
        assert!(render::html_fragment(&display.replacement).contains("data-display=\"true\""));
    }

    #[test]
    fn math_preserves_multiline_selection_and_rejects_ambiguous_input() {
        let source = "before a+b\nc+d after";
        let start = "before ".len();
        let end = source.find(" after").unwrap();
        let edit = insert_math(source, start..end).unwrap();
        assert_eq!(edit.replacement, "\n\n$$\na+b\nc+d\n$$\n\n");
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        assert!(render::html_fragment(&formatted).contains("data-display=\"true\""));
        assert_eq!(&formatted[edit.selection_range], "a+b\nc+d");

        assert_eq!(
            insert_math("already $x$", 9..10),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_math("price $5", 0..8),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            insert_math("e\u{301}", 1..1),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn mermaid_inserts_editable_offline_flowchart_template() {
        let edit = insert_mermaid("", 0..0).unwrap();
        assert_eq!(
            edit.replacement,
            "```mermaid\nflowchart TD\n    A[开始] --> B[结束]\n```"
        );
        assert_eq!(
            &edit.replacement[edit.selection_range],
            "flowchart TD\n    A[开始] --> B[结束]"
        );
        let html = render::html_fragment(&edit.replacement);
        assert!(html.contains("class=\"mermaid-diagram\""));
        assert!(html.contains("data-inflow-render=\"mermaid\""));
        assert!(!html.contains("<script"));
    }

    #[test]
    fn mermaid_wraps_supported_selection_and_rejects_invalid_diagram() {
        let source = "before stateDiagram-v2\n[*] --> Ready after";
        let start = "before ".len();
        let end = source.find(" after").unwrap();
        let edit = insert_mermaid(source, start..end).unwrap();
        assert!(
            edit.replacement
                .starts_with("\n\n```mermaid\nstateDiagram-v2")
        );
        assert!(edit.replacement.ends_with("```\n\n"));
        let formatted = replacing(source, edit.replace_range, &edit.replacement);
        let html = render::html_fragment(&formatted);
        assert!(html.contains("class=\"mermaid-diagram\""));
        assert!(html.contains("Ready"));

        // The JS parser owns diagram syntax; insertion preserves all nonempty source.
        let invalid = "flowchart LR\n-->";
        assert!(insert_mermaid(invalid, 0..invalid.len()).is_ok());
        assert_eq!(
            insert_mermaid("```mermaid\nflowchart TD\nA-->B\n```", 15..15),
            Err(FormatError::AmbiguousSelection)
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

    #[test]
    fn list_inserts_editable_templates_and_preserves_unicode_caret() {
        for (format, expected, caret) in [
            (ListFormat::Unordered, "- ", 2),
            (ListFormat::Ordered, "1. ", 3),
            (ListFormat::Task, "- [ ] ", 6),
        ] {
            assert_eq!(
                format_list("", 0..0, format),
                Ok(MarkdownEdit {
                    replace_range: 0..0,
                    replacement: expected.to_owned(),
                    selection_range: caret..caret,
                })
            );
        }

        let source = "Intro\n事项👩‍💻\nTail\n";
        let line_start = "Intro\n".len();
        let caret = line_start + "事项".len();
        let edit = format_list(source, caret..caret, ListFormat::Unordered).unwrap();
        assert_eq!(edit.replacement, "- 事项👩‍💻\n");
        assert_eq!(edit.selection_range, caret + 2..caret + 2);
    }

    #[test]
    fn list_unifies_mixed_lines_and_removes_matching_markers() {
        let source = "- one\n2. two\nthree\n\n";
        let edit = format_list(source, 0..source.len(), ListFormat::Unordered).unwrap();
        assert_eq!(edit.replacement, "- one\n- two\n- three\n\n");
        assert_eq!(edit.selection_range, 0..edit.replacement.len() - 1);

        let formatted = edit.replacement;
        let removed = format_list(&formatted, 0..formatted.len(), ListFormat::Unordered).unwrap();
        assert_eq!(removed.replacement, "one\ntwo\nthree\n\n");
    }

    #[test]
    fn ordered_list_uses_stable_markers_and_preserves_nested_structure() {
        let source = "first\n   child\nsecond\n   other\n";
        let edit = format_list(source, 0..source.len(), ListFormat::Ordered).unwrap();
        assert_eq!(
            edit.replacement,
            "1. first\n   1. child\n1. second\n   1. other\n"
        );
        let html = render::html_fragment(&edit.replacement);
        assert!(html.contains("<ol>"));
        assert!(html.contains("<li>first"));
    }

    #[test]
    fn task_list_preserves_checked_items_and_normalizes_other_markers() {
        let source = "- [x] done\n- todo\n3. later\n";
        let edit = format_list(source, 0..source.len(), ListFormat::Task).unwrap();
        assert_eq!(edit.replacement, "- [x] done\n- [ ] todo\n- [ ] later\n");
        let html = render::html_fragment(&edit.replacement);
        assert!(html.contains("type=\"checkbox\" checked=\"\""));
        assert!(html.contains("type=\"checkbox\""));

        let removed = format_list(
            &edit.replacement,
            0..edit.replacement.len(),
            ListFormat::Task,
        )
        .unwrap();
        assert_eq!(removed.replacement, "done\ntodo\nlater\n");
    }

    #[test]
    fn list_rejects_code_fence_markers_and_invalid_grapheme_boundaries() {
        let fenced = "```\n- not an item\n```\n";
        assert_eq!(
            format_list(fenced, 6..6, ListFormat::Unordered),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            format_list("e\u{301}", 1..1, ListFormat::Task),
            Err(FormatError::InvalidSelection)
        );
    }

    #[test]
    fn list_selection_ending_at_newline_leaves_the_next_line_untouched() {
        let source = "one\ntwo\n";
        let edit = format_list(source, 0..4, ListFormat::Unordered).unwrap();
        assert_eq!(edit.replace_range, 0..4);
        assert_eq!(edit.replacement, "- one\n");
        assert_eq!(
            replacing(source, edit.replace_range, &edit.replacement),
            "- one\ntwo\n"
        );
    }

    #[test]
    fn clear_format_removes_supported_inline_and_block_markers() {
        let source = "# **Hello** and *world* with ~~old~~ and `code`\n\n> - [x] task\n";
        let edit = clear_format(source, 0..source.len()).unwrap();
        assert_eq!(edit.replace_range, 0..source.len());
        assert_eq!(
            edit.replacement,
            "Hello and world with old and code\n\ntask\n"
        );
        assert_eq!(edit.selection_range, 0..edit.replacement.len());
    }

    #[test]
    fn clear_format_preserves_links_literals_and_unicode() {
        let source = "[**标签👩‍💻**](https://example.com/a_b) and \\*literal\\*";
        let edit = clear_format(source, 0..source.len()).unwrap();
        assert_eq!(
            edit.replacement,
            "[标签👩‍💻](https://example.com/a_b) and \\*literal\\*"
        );
    }

    #[test]
    fn clear_format_unwraps_code_without_reinterpreting_its_contents() {
        let fenced = "```md\n# **code**\n```\n";
        let edit = clear_format(fenced, 0..fenced.len()).unwrap();
        assert_eq!(edit.replacement, "# **code**\n");

        let inline = "`**not bold**`";
        let edit = clear_format(inline, 0..inline.len()).unwrap();
        assert_eq!(edit.replacement, "**not bold**");
    }

    #[test]
    fn clear_format_handles_setext_crlf_and_nested_quotes() {
        let source = "Title\r\n=====\r\n\r\n> > quoted\r\n";
        let edit = clear_format(source, 0..source.len()).unwrap();
        assert_eq!(edit.replacement, "Title\r\n\r\nquoted\r\n");
    }

    #[test]
    fn clear_format_requires_complete_markers_and_valid_graphemes() {
        let source = "before **bold** after";
        let content_start = source.find("bold").unwrap();
        assert_eq!(
            clear_format(source, content_start..content_start + 4),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            clear_format(source, 0.."before ".len()),
            Err(FormatError::AmbiguousSelection)
        );
        assert_eq!(
            clear_format("e\u{301}", 1..3),
            Err(FormatError::InvalidSelection)
        );
        assert_eq!(
            clear_format(source, 0..0),
            Err(FormatError::AmbiguousSelection)
        );
    }

    fn format_marker_len(format: InlineFormat) -> usize {
        match format {
            InlineFormat::Italic => 1,
            InlineFormat::Bold | InlineFormat::Strikethrough => 2,
        }
    }
}
