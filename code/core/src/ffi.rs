//! Stable C ABI adapter for the document core.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use crate::analysis;
use crate::document::{self, DecodeError, LineEnding};
use crate::export::{self, ExportError};
use crate::format::{self, FormatError, InlineFormat, ListFormat};
use crate::render;
use crate::search;

pub const STATUS_OK: i32 = 0;
pub const STATUS_INVALID_ARGUMENT: i32 = 1;
pub const STATUS_INVALID_UTF8: i32 = 2;
pub const STATUS_MIXED_LINE_ENDINGS: i32 = 3;
pub const STATUS_UNSUPPORTED_CONTENT: i32 = 4;
pub const STATUS_OUTPUT_TOO_LARGE: i32 = 5;
pub const STATUS_AMBIGUOUS_FORMAT: i32 = 6;
pub const STATUS_PANIC: i32 = 255;

pub const LINE_ENDING_LF: u8 = 0;
pub const LINE_ENDING_CRLF: u8 = 1;

pub const INLINE_FORMAT_BOLD: u8 = 1;
pub const INLINE_FORMAT_ITALIC: u8 = 2;
pub const INLINE_FORMAT_STRIKETHROUGH: u8 = 3;

pub const LIST_FORMAT_UNORDERED: u8 = 1;
pub const LIST_FORMAT_ORDERED: u8 = 2;
pub const LIST_FORMAT_TASK: u8 = 3;

#[repr(C)]
pub struct InflowOwnedBytes {
    pub data: *mut u8,
    pub length: usize,
}

impl InflowOwnedBytes {
    const fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            length: 0,
        }
    }

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }

        let length = bytes.len();
        let boxed = bytes.into_boxed_slice();
        let data = Box::into_raw(boxed).cast::<u8>();
        Self { data, length }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct InflowHeading {
    pub level: u8,
    pub source_start: usize,
    pub source_end: usize,
    pub title_start: usize,
    pub title_length: usize,
}

#[repr(C)]
pub struct InflowOwnedHeadings {
    pub data: *mut InflowHeading,
    pub length: usize,
}

impl InflowOwnedHeadings {
    const fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            length: 0,
        }
    }

    fn from_vec(headings: Vec<InflowHeading>) -> Self {
        if headings.is_empty() {
            return Self::empty();
        }

        let length = headings.len();
        let boxed = headings.into_boxed_slice();
        let data = Box::into_raw(boxed).cast::<InflowHeading>();
        Self { data, length }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct InflowSearchMatch {
    pub source_start: usize,
    pub source_end: usize,
}

#[repr(C)]
pub struct InflowOwnedSearchMatches {
    pub data: *mut InflowSearchMatch,
    pub length: usize,
}

impl InflowOwnedSearchMatches {
    const fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            length: 0,
        }
    }

    fn from_vec(matches: Vec<InflowSearchMatch>) -> Self {
        if matches.is_empty() {
            return Self::empty();
        }

        let length = matches.len();
        let boxed = matches.into_boxed_slice();
        let data = Box::into_raw(boxed).cast::<InflowSearchMatch>();
        Self { data, length }
    }
}

#[repr(C)]
pub struct InflowDecodeResult {
    pub status: i32,
    pub utf8: InflowOwnedBytes,
    pub has_utf8_bom: u8,
    pub line_ending: u8,
}

impl InflowDecodeResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            utf8: InflowOwnedBytes::empty(),
            has_utf8_bom: 0,
            line_ending: LINE_ENDING_LF,
        }
    }
}

#[repr(C)]
pub struct InflowEncodeResult {
    pub status: i32,
    pub bytes: InflowOwnedBytes,
}

impl InflowEncodeResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            bytes: InflowOwnedBytes::empty(),
        }
    }
}

#[repr(C)]
pub struct InflowAnalysisResult {
    pub status: i32,
    pub headings: InflowOwnedHeadings,
    pub heading_text_utf8: InflowOwnedBytes,
    pub word_count: u64,
    pub character_count_with_spaces: u64,
    pub character_count_without_spaces: u64,
}

impl InflowAnalysisResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            headings: InflowOwnedHeadings::empty(),
            heading_text_utf8: InflowOwnedBytes::empty(),
            word_count: 0,
            character_count_with_spaces: 0,
            character_count_without_spaces: 0,
        }
    }
}

#[repr(C)]
pub struct InflowSearchResult {
    pub status: i32,
    pub matches: InflowOwnedSearchMatches,
}

#[repr(C)]
pub struct InflowHTMLExportResult {
    pub status: i32,
    pub html: InflowOwnedBytes,
    pub blocking_issues: u64,
}

#[repr(C)]
pub struct InflowMarkdownEditResult {
    pub status: i32,
    pub replacement: InflowOwnedBytes,
    pub replace_start: usize,
    pub replace_end: usize,
    pub selection_start: usize,
    pub selection_end: usize,
}

impl InflowMarkdownEditResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            replacement: InflowOwnedBytes::empty(),
            replace_start: 0,
            replace_end: 0,
            selection_start: 0,
            selection_end: 0,
        }
    }
}

impl InflowHTMLExportResult {
    const fn error(status: i32, blocking_issues: u64) -> Self {
        Self {
            status,
            html: InflowOwnedBytes::empty(),
            blocking_issues,
        }
    }
}

impl InflowSearchResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            matches: InflowOwnedSearchMatches::empty(),
        }
    }
}

/// Decodes UTF-8 Markdown and normalizes its in-memory line endings to LF.
///
/// # Safety
///
/// When `length` is non-zero, `bytes` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_document_decode(
    bytes: *const u8,
    length: usize,
) -> InflowDecodeResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(bytes, length) }) else {
            return InflowDecodeResult::error(STATUS_INVALID_ARGUMENT);
        };

        match document::decode(input) {
            Ok(decoded) => InflowDecodeResult {
                status: STATUS_OK,
                utf8: InflowOwnedBytes::from_vec(decoded.text.into_bytes()),
                has_utf8_bom: u8::from(decoded.has_utf8_bom),
                line_ending: match decoded.line_ending {
                    LineEnding::Lf => LINE_ENDING_LF,
                    LineEnding::CrLf => LINE_ENDING_CRLF,
                },
            },
            Err(DecodeError::InvalidUtf8) => InflowDecodeResult::error(STATUS_INVALID_UTF8),
            Err(DecodeError::MixedLineEndings) => {
                InflowDecodeResult::error(STATUS_MIXED_LINE_ENDINGS)
            }
        }
    }))
    .unwrap_or_else(|_| InflowDecodeResult::error(STATUS_PANIC))
}

/// Encodes normalized UTF-8 Markdown using the requested file properties.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_document_encode(
    utf8: *const u8,
    length: usize,
    has_utf8_bom: u8,
    line_ending: u8,
) -> InflowEncodeResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowEncodeResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(text) = std::str::from_utf8(input) else {
            return InflowEncodeResult::error(STATUS_INVALID_UTF8);
        };
        let line_ending = match line_ending {
            LINE_ENDING_LF => LineEnding::Lf,
            LINE_ENDING_CRLF => LineEnding::CrLf,
            _ => return InflowEncodeResult::error(STATUS_INVALID_ARGUMENT),
        };

        InflowEncodeResult {
            status: STATUS_OK,
            bytes: InflowOwnedBytes::from_vec(document::encode(
                text,
                has_utf8_bom != 0,
                line_ending,
            )),
        }
    }))
    .unwrap_or_else(|_| InflowEncodeResult::error(STATUS_PANIC))
}

/// Renders UTF-8 Markdown into an HTML fragment with raw HTML escaped.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_render_html(
    utf8: *const u8,
    length: usize,
) -> InflowEncodeResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowEncodeResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowEncodeResult::error(STATUS_INVALID_UTF8);
        };

        InflowEncodeResult {
            status: STATUS_OK,
            bytes: InflowOwnedBytes::from_vec(render::html_fragment(markdown).into_bytes()),
        }
    }))
    .unwrap_or_else(|_| InflowEncodeResult::error(STATUS_PANIC))
}

/// Exports an immutable UTF-8 Markdown snapshot as a self-contained HTML document.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_export_html(
    utf8: *const u8,
    length: usize,
) -> InflowHTMLExportResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_ARGUMENT, 0);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_UTF8, 0);
        };

        match export::html_document(markdown) {
            Ok(html) => InflowHTMLExportResult {
                status: STATUS_OK,
                html: InflowOwnedBytes::from_vec(html),
                blocking_issues: 0,
            },
            Err(ExportError::UnsupportedContent(issues)) => {
                InflowHTMLExportResult::error(STATUS_UNSUPPORTED_CONTENT, issues)
            }
            Err(ExportError::OutputTooLarge) => {
                InflowHTMLExportResult::error(STATUS_OUTPUT_TOO_LARGE, 0)
            }
        }
    }))
    .unwrap_or_else(|_| InflowHTMLExportResult::error(STATUS_PANIC, 0))
}

/// Plans one predictable inline Markdown formatting edit for a UTF-8 snapshot.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_format_inline(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
    inline_format: u8,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(source) = std::str::from_utf8(input) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        let inline_format = match inline_format {
            INLINE_FORMAT_BOLD => InlineFormat::Bold,
            INLINE_FORMAT_ITALIC => InlineFormat::Italic,
            INLINE_FORMAT_STRIKETHROUGH => InlineFormat::Strikethrough,
            _ => return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT),
        };

        markdown_edit_result(format::format_inline(
            source,
            selection_start..selection_end,
            inline_format,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one predictable inline-code edit for a UTF-8 snapshot.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_format_inline_code(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(source) = std::str::from_utf8(input) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        markdown_edit_result(format::format_inline_code(
            source,
            selection_start..selection_end,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one predictable fenced-code-block edit for a UTF-8 snapshot.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_format_code_block(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(source) = std::str::from_utf8(input) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        markdown_edit_result(format::format_code_block(
            source,
            selection_start..selection_end,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one predictable ATX heading edit for complete source lines.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_format_heading(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
    heading_level: u8,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(source) = std::str::from_utf8(input) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        markdown_edit_result(format::format_heading(
            source,
            selection_start..selection_end,
            heading_level,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one predictable block quote level edit for complete source lines.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_format_block_quote(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(source) = std::str::from_utf8(input) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        markdown_edit_result(format::format_block_quote(
            source,
            selection_start..selection_end,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one predictable list edit for complete source lines.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_format_list(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
    list_format: u8,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(source) = std::str::from_utf8(input) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        let list_format = match list_format {
            LIST_FORMAT_UNORDERED => ListFormat::Unordered,
            LIST_FORMAT_ORDERED => ListFormat::Ordered,
            LIST_FORMAT_TASK => ListFormat::Task,
            _ => return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT),
        };
        markdown_edit_result(format::format_list(
            source,
            selection_start..selection_end,
            list_format,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

fn markdown_edit_result(
    result: Result<format::MarkdownEdit, FormatError>,
) -> InflowMarkdownEditResult {
    match result {
        Ok(edit) => InflowMarkdownEditResult {
            status: STATUS_OK,
            replacement: InflowOwnedBytes::from_vec(edit.replacement.into_bytes()),
            replace_start: edit.replace_range.start,
            replace_end: edit.replace_range.end,
            selection_start: edit.selection_range.start,
            selection_end: edit.selection_range.end,
        },
        Err(FormatError::InvalidSelection) => {
            InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT)
        }
        Err(FormatError::AmbiguousSelection) => {
            InflowMarkdownEditResult::error(STATUS_AMBIGUOUS_FORMAT)
        }
    }
}

/// Extracts heading source ranges and text statistics from UTF-8 Markdown.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_document_analyze(
    utf8: *const u8,
    length: usize,
) -> InflowAnalysisResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowAnalysisResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowAnalysisResult::error(STATUS_INVALID_UTF8);
        };

        let analysis = analysis::analyze(markdown);
        let mut heading_text_utf8 = Vec::new();
        let headings = analysis
            .headings
            .into_iter()
            .map(|heading| {
                let title_start = heading_text_utf8.len();
                let title = heading.title.as_bytes();
                heading_text_utf8.extend_from_slice(title);

                InflowHeading {
                    level: heading.level,
                    source_start: heading.source_range.start,
                    source_end: heading.source_range.end,
                    title_start,
                    title_length: title.len(),
                }
            })
            .collect();

        InflowAnalysisResult {
            status: STATUS_OK,
            headings: InflowOwnedHeadings::from_vec(headings),
            heading_text_utf8: InflowOwnedBytes::from_vec(heading_text_utf8),
            word_count: analysis.word_count,
            character_count_with_spaces: analysis.character_count_with_spaces,
            character_count_without_spaces: analysis.character_count_without_spaces,
        }
    }))
    .unwrap_or_else(|_| InflowAnalysisResult::error(STATUS_PANIC))
}

/// Finds non-overlapping literal matches in UTF-8 Markdown source.
///
/// # Safety
///
/// When their lengths are non-zero, `utf8` and `query_utf8` must point to the
/// corresponding number of readable bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_document_search(
    utf8: *const u8,
    length: usize,
    query_utf8: *const u8,
    query_length: usize,
    case_sensitive: u8,
) -> InflowSearchResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowSearchResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Some(query_input) = (unsafe { borrowed_bytes(query_utf8, query_length) }) else {
            return InflowSearchResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowSearchResult::error(STATUS_INVALID_UTF8);
        };
        let Ok(query) = std::str::from_utf8(query_input) else {
            return InflowSearchResult::error(STATUS_INVALID_UTF8);
        };
        let case_sensitive = match case_sensitive {
            0 => false,
            1 => true,
            _ => return InflowSearchResult::error(STATUS_INVALID_ARGUMENT),
        };

        let matches = search::find_literal(markdown, query, case_sensitive)
            .into_iter()
            .map(|found| InflowSearchMatch {
                source_start: found.source_range.start,
                source_end: found.source_range.end,
            })
            .collect();

        InflowSearchResult {
            status: STATUS_OK,
            matches: InflowOwnedSearchMatches::from_vec(matches),
        }
    }))
    .unwrap_or_else(|_| InflowSearchResult::error(STATUS_PANIC))
}

/// Releases bytes returned by this library.
///
/// # Safety
///
/// `data` and `length` must be an unchanged pair returned by this library and
/// must not have been released previously. A null pointer is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_owned_bytes_free(data: *mut u8, length: usize) {
    if data.is_null() {
        return;
    }

    let slice = ptr::slice_from_raw_parts_mut(data, length);
    drop(unsafe { Box::from_raw(slice) });
}

/// Releases headings returned by this library.
///
/// # Safety
///
/// `data` and `length` must be an unchanged pair returned by this library and
/// must not have been released previously. A null pointer is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_owned_headings_free(data: *mut InflowHeading, length: usize) {
    if data.is_null() {
        return;
    }

    let slice = ptr::slice_from_raw_parts_mut(data, length);
    drop(unsafe { Box::from_raw(slice) });
}

/// Releases search matches returned by this library.
///
/// # Safety
///
/// `data` and `length` must be an unchanged pair returned by this library and
/// must not have been released previously. A null pointer is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_owned_search_matches_free(
    data: *mut InflowSearchMatch,
    length: usize,
) {
    if data.is_null() {
        return;
    }

    let slice = ptr::slice_from_raw_parts_mut(data, length);
    drop(unsafe { Box::from_raw(slice) });
}

unsafe fn borrowed_bytes<'a>(data: *const u8, length: usize) -> Option<&'a [u8]> {
    if length == 0 {
        return Some(&[]);
    }
    if data.is_null() {
        return None;
    }

    Some(unsafe { std::slice::from_raw_parts(data, length) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_round_trip_preserves_file_properties() {
        let source = [
            b"\xEF\xBB\xBF".as_slice(),
            "# 标题\r\n\r\nBody\r\n".as_bytes(),
        ]
        .concat();
        let decoded = unsafe { inflow_document_decode(source.as_ptr(), source.len()) };

        assert_eq!(decoded.status, STATUS_OK);
        assert_eq!(decoded.has_utf8_bom, 1);
        assert_eq!(decoded.line_ending, LINE_ENDING_CRLF);
        let normalized =
            unsafe { std::slice::from_raw_parts(decoded.utf8.data, decoded.utf8.length).to_vec() };
        unsafe { inflow_owned_bytes_free(decoded.utf8.data, decoded.utf8.length) };

        let encoded = unsafe {
            inflow_document_encode(
                normalized.as_ptr(),
                normalized.len(),
                decoded.has_utf8_bom,
                decoded.line_ending,
            )
        };
        assert_eq!(encoded.status, STATUS_OK);
        let output = unsafe {
            std::slice::from_raw_parts(encoded.bytes.data, encoded.bytes.length).to_vec()
        };
        unsafe { inflow_owned_bytes_free(encoded.bytes.data, encoded.bytes.length) };

        assert_eq!(output, source);
    }

    #[test]
    fn ffi_rejects_null_non_empty_input() {
        let result = unsafe { inflow_document_decode(ptr::null(), 1) };
        assert_eq!(result.status, STATUS_INVALID_ARGUMENT);
        assert!(result.utf8.data.is_null());
    }

    #[test]
    fn ffi_renders_utf8_markdown() {
        let markdown = "# 标题\n\n**Body**";
        let result = unsafe { inflow_markdown_render_html(markdown.as_ptr(), markdown.len()) };

        assert_eq!(result.status, STATUS_OK);
        let html =
            unsafe { std::slice::from_raw_parts(result.bytes.data, result.bytes.length).to_vec() };
        unsafe { inflow_owned_bytes_free(result.bytes.data, result.bytes.length) };

        assert_eq!(
            String::from_utf8(html).expect("renderer returns UTF-8"),
            "<h1>标题</h1>\n<p><strong>Body</strong></p>\n"
        );
    }

    #[test]
    fn ffi_analyzes_duplicate_unicode_headings_and_statistics() {
        let markdown = "# 概览\n\nBody 123\n\n## Same\n\n## Same\n";
        let result = unsafe { inflow_document_analyze(markdown.as_ptr(), markdown.len()) };

        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.headings.length, 3);
        let headings =
            unsafe { std::slice::from_raw_parts(result.headings.data, result.headings.length) };
        assert_ne!(headings[1].source_start, headings[2].source_start);
        assert_eq!(headings[0].level, 1);
        assert_eq!(
            &markdown[headings[0].source_start..headings[0].source_end],
            "# 概览"
        );

        let title_bytes = unsafe {
            std::slice::from_raw_parts(
                result.heading_text_utf8.data,
                result.heading_text_utf8.length,
            )
        };
        let first_title = &title_bytes
            [headings[0].title_start..headings[0].title_start + headings[0].title_length];
        assert_eq!(std::str::from_utf8(first_title).unwrap(), "概览");
        assert_eq!(result.word_count, 6);

        unsafe {
            inflow_owned_headings_free(result.headings.data, result.headings.length);
            inflow_owned_bytes_free(
                result.heading_text_utf8.data,
                result.heading_text_utf8.length,
            );
        }
    }

    #[test]
    fn ffi_analysis_rejects_invalid_inputs_with_empty_owned_results() {
        for result in [unsafe { inflow_document_analyze(ptr::null(), 1) }, unsafe {
            inflow_document_analyze([0xFF].as_ptr(), 1)
        }] {
            assert!(matches!(
                result.status,
                STATUS_INVALID_ARGUMENT | STATUS_INVALID_UTF8
            ));
            assert!(result.headings.data.is_null());
            assert_eq!(result.headings.length, 0);
            assert!(result.heading_text_utf8.data.is_null());
            assert_eq!(result.heading_text_utf8.length, 0);
            assert_eq!(result.word_count, 0);
        }
    }

    #[test]
    #[cfg(target_pointer_width = "64")]
    fn ffi_analysis_layout_matches_64_bit_c_contract() {
        assert_eq!(std::mem::size_of::<InflowHeading>(), 40);
        assert_eq!(std::mem::align_of::<InflowHeading>(), 8);
        assert_eq!(std::mem::size_of::<InflowOwnedHeadings>(), 16);
        assert_eq!(std::mem::size_of::<InflowAnalysisResult>(), 64);
        assert_eq!(std::mem::size_of::<InflowSearchMatch>(), 16);
        assert_eq!(std::mem::align_of::<InflowSearchMatch>(), 8);
        assert_eq!(std::mem::size_of::<InflowOwnedSearchMatches>(), 16);
        assert_eq!(std::mem::size_of::<InflowSearchResult>(), 24);
        assert_eq!(std::mem::size_of::<InflowHTMLExportResult>(), 32);
        assert_eq!(std::mem::size_of::<InflowMarkdownEditResult>(), 56);
    }

    #[test]
    fn ffi_searches_unicode_with_exact_source_ranges() {
        let markdown = "标题 Alpha\n标题 alpha\nStraße";
        let query = "alpha";
        let result = unsafe {
            inflow_document_search(
                markdown.as_ptr(),
                markdown.len(),
                query.as_ptr(),
                query.len(),
                0,
            )
        };

        assert_eq!(result.status, STATUS_OK);
        let matches =
            unsafe { std::slice::from_raw_parts(result.matches.data, result.matches.length) };
        assert_eq!(matches.len(), 2);
        assert_eq!(
            &markdown[matches[0].source_start..matches[0].source_end],
            "Alpha"
        );
        assert_eq!(
            &markdown[matches[1].source_start..matches[1].source_end],
            "alpha"
        );
        unsafe { inflow_owned_search_matches_free(result.matches.data, result.matches.length) };
    }

    #[test]
    fn ffi_search_rejects_invalid_arguments_with_empty_results() {
        let valid = "text";
        let invalid_utf8 = [0xFF];
        let cases = [
            unsafe { inflow_document_search(ptr::null(), 1, valid.as_ptr(), valid.len(), 0) },
            unsafe { inflow_document_search(valid.as_ptr(), valid.len(), ptr::null(), 1, 0) },
            unsafe {
                inflow_document_search(
                    valid.as_ptr(),
                    valid.len(),
                    invalid_utf8.as_ptr(),
                    invalid_utf8.len(),
                    0,
                )
            },
            unsafe {
                inflow_document_search(valid.as_ptr(), valid.len(), valid.as_ptr(), valid.len(), 2)
            },
        ];

        for result in cases {
            assert!(matches!(
                result.status,
                STATUS_INVALID_ARGUMENT | STATUS_INVALID_UTF8
            ));
            assert!(result.matches.data.is_null());
            assert_eq!(result.matches.length, 0);
        }
    }

    #[test]
    fn ffi_exports_html_and_reports_blocking_issues() {
        let markdown = "# Export\n";
        let result = unsafe { inflow_markdown_export_html(markdown.as_ptr(), markdown.len()) };
        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.blocking_issues, 0);
        let html = unsafe { std::slice::from_raw_parts(result.html.data, result.html.length) };
        assert!(
            std::str::from_utf8(html)
                .unwrap()
                .contains("<h1>Export</h1>")
        );
        unsafe { inflow_owned_bytes_free(result.html.data, result.html.length) };

        let unsupported = "![image](photo.png) and $formula$";
        let result =
            unsafe { inflow_markdown_export_html(unsupported.as_ptr(), unsupported.len()) };
        assert_eq!(result.status, STATUS_UNSUPPORTED_CONTENT);
        assert_eq!(
            result.blocking_issues,
            export::ISSUE_IMAGE | export::ISSUE_FORMULA
        );
        assert!(result.html.data.is_null());
        assert_eq!(result.html.length, 0);
    }

    #[test]
    fn ffi_export_rejects_invalid_inputs_without_allocating() {
        let invalid_utf8 = [0xFF];
        for result in [
            unsafe { inflow_markdown_export_html(ptr::null(), 1) },
            unsafe { inflow_markdown_export_html(invalid_utf8.as_ptr(), invalid_utf8.len()) },
        ] {
            assert!(matches!(
                result.status,
                STATUS_INVALID_ARGUMENT | STATUS_INVALID_UTF8
            ));
            assert!(result.html.data.is_null());
            assert_eq!(result.html.length, 0);
            assert_eq!(result.blocking_issues, 0);
        }
    }

    #[test]
    fn ffi_plans_inline_format_and_reports_ambiguous_selection() {
        let source = "Text 中文";
        let start = "Text ".len();
        let result = unsafe {
            inflow_markdown_format_inline(
                source.as_ptr(),
                source.len(),
                start,
                source.len(),
                INLINE_FORMAT_BOLD,
            )
        };
        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.replace_start, start);
        assert_eq!(result.replace_end, source.len());
        assert_eq!(result.selection_start, start + 2);
        assert_eq!(result.selection_end, source.len() + 2);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(std::str::from_utf8(replacement).unwrap(), "**中文**");
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let formatted = "**bold**";
        let result = unsafe {
            inflow_markdown_format_inline(
                formatted.as_ptr(),
                formatted.len(),
                3,
                5,
                INLINE_FORMAT_BOLD,
            )
        };
        assert_eq!(result.status, STATUS_AMBIGUOUS_FORMAT);
        assert!(result.replacement.data.is_null());
    }

    #[test]
    fn ffi_plans_inline_code_and_releases_result() {
        let source = "code `value`";
        let result = unsafe {
            inflow_markdown_format_inline_code(source.as_ptr(), source.len(), 0, source.len())
        };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(
            std::str::from_utf8(replacement).unwrap(),
            "`` code `value` ``"
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let ambiguous =
            unsafe { inflow_markdown_format_inline_code(source.as_ptr(), source.len(), 7, 10) };
        assert_eq!(ambiguous.status, STATUS_AMBIGUOUS_FORMAT);
        assert!(ambiguous.replacement.data.is_null());

        let invalid = unsafe { inflow_markdown_format_inline_code(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_plans_code_block_and_releases_result() {
        let source = "let value = `raw`;\n";
        let result = unsafe {
            inflow_markdown_format_code_block(source.as_ptr(), source.len(), 0, source.len())
        };
        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.replace_start, 0);
        assert_eq!(result.replace_end, source.len());
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(
            std::str::from_utf8(replacement).unwrap(),
            "```\nlet value = `raw`;\n```\n"
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid = unsafe { inflow_markdown_format_code_block(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_format_rejects_invalid_arguments_without_allocating() {
        let source = "text";
        for result in [
            unsafe { inflow_markdown_format_inline(ptr::null(), 1, 0, 0, INLINE_FORMAT_BOLD) },
            unsafe {
                inflow_markdown_format_inline(
                    source.as_ptr(),
                    source.len(),
                    0,
                    5,
                    INLINE_FORMAT_BOLD,
                )
            },
            unsafe { inflow_markdown_format_inline(source.as_ptr(), source.len(), 0, 0, 99) },
        ] {
            assert_eq!(result.status, STATUS_INVALID_ARGUMENT);
            assert!(result.replacement.data.is_null());
            assert_eq!(result.replacement.length, 0);
        }
    }

    #[test]
    fn ffi_plans_multiline_heading_and_validates_level() {
        let source = "# One\nplain\n";
        let result = unsafe {
            inflow_markdown_format_heading(source.as_ptr(), source.len(), 0, source.len(), 2)
        };
        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.replace_start, 0);
        assert_eq!(result.replace_end, source.len());
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(
            std::str::from_utf8(replacement).unwrap(),
            "## One\n## plain\n"
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid =
            unsafe { inflow_markdown_format_heading(source.as_ptr(), source.len(), 0, 0, 7) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_plans_multiline_block_quote_and_releases_result() {
        let source = "one\n二\n";
        let result = unsafe {
            inflow_markdown_format_block_quote(source.as_ptr(), source.len(), 0, source.len())
        };
        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.replace_start, 0);
        assert_eq!(result.replace_end, source.len());
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(std::str::from_utf8(replacement).unwrap(), "> one\n> 二\n");
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid = unsafe { inflow_markdown_format_block_quote(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_plans_task_list_and_validates_kind() {
        let source = "done\n待办\n";
        let result = unsafe {
            inflow_markdown_format_list(
                source.as_ptr(),
                source.len(),
                0,
                source.len(),
                LIST_FORMAT_TASK,
            )
        };
        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.replace_start, 0);
        assert_eq!(result.replace_end, source.len());
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(
            std::str::from_utf8(replacement).unwrap(),
            "- [ ] done\n- [ ] 待办\n"
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        for invalid in [
            unsafe { inflow_markdown_format_list(ptr::null(), 1, 0, 0, LIST_FORMAT_TASK) },
            unsafe {
                inflow_markdown_format_list(source.as_ptr(), source.len(), 0, source.len(), 99)
            },
        ] {
            assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
            assert!(invalid.replacement.data.is_null());
        }
    }
}
