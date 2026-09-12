//! Stable C ABI adapter for the document core.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use crate::analysis;
use crate::document::{self, DecodeError, LineEnding};
use crate::engine::{
    CommandEnvelope, ENGINE_SCHEMA_VERSION, EditorEngine, EngineCreateRequest, EngineError,
};
use crate::export::{self, ExportError};
use crate::format::{self, FormatError, InlineFormat, ListFormat};
use crate::highlight;
use crate::mermaid;
use crate::reference::{self, ReferenceKind};
use crate::render;
use crate::search;

pub const STATUS_OK: i32 = 0;
pub const STATUS_INVALID_ARGUMENT: i32 = 1;
pub const STATUS_INVALID_UTF8: i32 = 2;
pub const STATUS_MIXED_LINE_ENDINGS: i32 = 3;
pub const STATUS_UNSUPPORTED_CONTENT: i32 = 4;
pub const STATUS_OUTPUT_TOO_LARGE: i32 = 5;
pub const STATUS_AMBIGUOUS_FORMAT: i32 = 6;
pub const STATUS_REVISION_CONFLICT: i32 = 7;
pub const STATUS_PANIC: i32 = 255;

pub const LINE_ENDING_LF: u8 = 0;
pub const LINE_ENDING_CRLF: u8 = 1;

pub const RENDER_OPTION_MATH: u32 = 1 << 0;
pub const RENDER_OPTION_MERMAID: u32 = 1 << 1;
pub const RENDER_OPTIONS_DEFAULT: u32 = RENDER_OPTION_MATH | RENDER_OPTION_MERMAID;

pub const INLINE_FORMAT_BOLD: u8 = 1;
pub const INLINE_FORMAT_ITALIC: u8 = 2;
pub const INLINE_FORMAT_STRIKETHROUGH: u8 = 3;

pub const LIST_FORMAT_UNORDERED: u8 = 1;
pub const LIST_FORMAT_ORDERED: u8 = 2;
pub const LIST_FORMAT_TASK: u8 = 3;

pub const REFERENCE_KIND_LINK: u8 = 1;
pub const REFERENCE_KIND_IMAGE: u8 = 2;

pub const HIGHLIGHT_KIND_HEADING: u8 = 1;
pub const HIGHLIGHT_KIND_EMPHASIS: u8 = 2;
pub const HIGHLIGHT_KIND_STRONG: u8 = 3;
pub const HIGHLIGHT_KIND_STRIKETHROUGH: u8 = 4;
pub const HIGHLIGHT_KIND_CODE: u8 = 5;
pub const HIGHLIGHT_KIND_LINK: u8 = 6;
pub const HIGHLIGHT_KIND_IMAGE: u8 = 7;
pub const HIGHLIGHT_KIND_BLOCK_QUOTE: u8 = 8;
pub const HIGHLIGHT_KIND_LIST: u8 = 9;
pub const HIGHLIGHT_KIND_TABLE: u8 = 10;
pub const HIGHLIGHT_KIND_FOOTNOTE: u8 = 11;
pub const HIGHLIGHT_KIND_MATH: u8 = 12;
pub const HIGHLIGHT_KIND_RAW: u8 = 13;
pub const HIGHLIGHT_KIND_RULE: u8 = 14;

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
#[derive(Clone, Copy)]
pub struct InflowReference {
    pub kind: u8,
    pub source_start: usize,
    pub source_end: usize,
    pub target_start: usize,
    pub target_length: usize,
}

#[repr(C)]
pub struct InflowOwnedReferences {
    pub data: *mut InflowReference,
    pub length: usize,
}

impl InflowOwnedReferences {
    const fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            length: 0,
        }
    }

    fn from_vec(references: Vec<InflowReference>) -> Self {
        if references.is_empty() {
            return Self::empty();
        }
        let length = references.len();
        let boxed = references.into_boxed_slice();
        let data = Box::into_raw(boxed).cast::<InflowReference>();
        Self { data, length }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct InflowHighlightSpan {
    pub kind: u8,
    pub source_start: usize,
    pub source_end: usize,
}

#[repr(C)]
pub struct InflowOwnedHighlightSpans {
    pub data: *mut InflowHighlightSpan,
    pub length: usize,
}

impl InflowOwnedHighlightSpans {
    const fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            length: 0,
        }
    }

    fn from_vec(spans: Vec<InflowHighlightSpan>) -> Self {
        if spans.is_empty() {
            return Self::empty();
        }
        let length = spans.len();
        let data = Box::into_raw(spans.into_boxed_slice()).cast::<InflowHighlightSpan>();
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

#[repr(C)]
pub struct InflowDocumentOpenResult {
    pub status: i32,
    pub utf8: InflowOwnedBytes,
    pub has_utf8_bom: u8,
    pub line_ending: u8,
    pub requires_line_ending_choice: u8,
}

impl InflowDocumentOpenResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            utf8: InflowOwnedBytes::empty(),
            has_utf8_bom: 0,
            line_ending: LINE_ENDING_LF,
            requires_line_ending_choice: 0,
        }
    }
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
pub struct InflowEditorEngine {
    engine: EditorEngine,
}

#[repr(C)]
pub struct InflowEngineCreateResult {
    pub status: i32,
    pub engine: *mut InflowEditorEngine,
    pub payload: InflowOwnedBytes,
}

impl InflowEngineCreateResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            engine: ptr::null_mut(),
            payload: InflowOwnedBytes::empty(),
        }
    }
}

#[repr(C)]
pub struct InflowBytesResult {
    pub status: i32,
    pub bytes: InflowOwnedBytes,
}

impl InflowBytesResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            bytes: InflowOwnedBytes::empty(),
        }
    }
}

#[derive(serde::Serialize)]
struct EngineErrorResponse<'a> {
    schema_version: u32,
    domain: &'static str,
    code: &'static str,
    message: &'static str,
    revision: Option<u64>,
    request_id: Option<&'a str>,
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
pub struct InflowReferenceResult {
    pub status: i32,
    pub references: InflowOwnedReferences,
    pub target_text_utf8: InflowOwnedBytes,
}

#[repr(C)]
pub struct InflowHighlightResult {
    pub status: i32,
    pub spans: InflowOwnedHighlightSpans,
}

impl InflowHighlightResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            spans: InflowOwnedHighlightSpans::empty(),
        }
    }
}

impl InflowReferenceResult {
    const fn error(status: i32) -> Self {
        Self {
            status,
            references: InflowOwnedReferences::empty(),
            target_text_utf8: InflowOwnedBytes::empty(),
        }
    }
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

/// Creates an opaque stateful editor engine from a versioned JSON request.
///
/// # Safety
///
/// When `length` is non-zero, `request` must point to `length` readable bytes
/// for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_engine_create(
    request: *const u8,
    length: usize,
) -> InflowEngineCreateResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(request, length) }) else {
            return engine_create_error(
                STATUS_INVALID_ARGUMENT,
                "invalid_request",
                "The engine creation request pointer is invalid.",
            );
        };
        let Ok(request) = serde_json::from_slice::<EngineCreateRequest>(input) else {
            return engine_create_error(
                STATUS_INVALID_ARGUMENT,
                "invalid_request",
                "The engine creation request is not valid schema-versioned JSON.",
            );
        };
        let engine = match EditorEngine::create(request) {
            Ok(engine) => engine,
            Err(error) => {
                let (code, message) = engine_error_details(error);
                return engine_create_error(engine_error_status(error), code, message);
            }
        };
        let Some(payload) = json_owned_bytes(&engine.snapshot()) else {
            return InflowEngineCreateResult::error(STATUS_PANIC);
        };
        let engine = Box::into_raw(Box::new(InflowEditorEngine { engine }));

        InflowEngineCreateResult {
            status: STATUS_OK,
            engine,
            payload,
        }
    }))
    .unwrap_or_else(|_| InflowEngineCreateResult::error(STATUS_PANIC))
}

/// Dispatches one versioned JSON command to an opaque editor engine.
///
/// A single engine must be serialized by its platform owner. Successful
/// responses and structured errors are returned as owned JSON bytes.
///
/// # Safety
///
/// `engine` must be a live pointer returned by `inflow_engine_create`. When
/// `length` is non-zero, `command` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_engine_dispatch(
    engine: *mut InflowEditorEngine,
    command: *const u8,
    length: usize,
) -> InflowBytesResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = (unsafe { engine.as_mut() }) else {
            return engine_bytes_error(
                STATUS_INVALID_ARGUMENT,
                "invalid_handle",
                "The editor engine handle is null.",
                None,
                None,
            );
        };
        let Some(input) = (unsafe { borrowed_bytes(command, length) }) else {
            return engine_bytes_error(
                STATUS_INVALID_ARGUMENT,
                "invalid_request",
                "The command pointer is invalid.",
                Some(engine.engine.snapshot().revision),
                None,
            );
        };
        let Ok(envelope) = serde_json::from_slice::<CommandEnvelope>(input) else {
            return engine_bytes_error(
                STATUS_INVALID_ARGUMENT,
                "invalid_request",
                "The command is not valid schema-versioned JSON.",
                Some(engine.engine.snapshot().revision),
                None,
            );
        };
        let request_id = envelope.request_id.clone();
        match engine.engine.dispatch(envelope) {
            Ok(response) => json_owned_bytes(&response).map_or_else(
                || InflowBytesResult::error(STATUS_PANIC),
                |bytes| InflowBytesResult {
                    status: STATUS_OK,
                    bytes,
                },
            ),
            Err(error) => {
                let (code, message) = engine_error_details(error);
                engine_bytes_error(
                    engine_error_status(error),
                    code,
                    message,
                    Some(engine.engine.snapshot().revision),
                    Some(&request_id),
                )
            }
        }
    }))
    .unwrap_or_else(|_| InflowBytesResult::error(STATUS_PANIC))
}

/// Returns a full versioned JSON snapshot for shadow comparison and resync.
///
/// # Safety
///
/// `engine` must be a live pointer returned by `inflow_engine_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_engine_snapshot(
    engine: *const InflowEditorEngine,
) -> InflowBytesResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = (unsafe { engine.as_ref() }) else {
            return engine_bytes_error(
                STATUS_INVALID_ARGUMENT,
                "invalid_handle",
                "The editor engine handle is null.",
                None,
                None,
            );
        };
        json_owned_bytes(&engine.engine.snapshot()).map_or_else(
            || InflowBytesResult::error(STATUS_PANIC),
            |bytes| InflowBytesResult {
                status: STATUS_OK,
                bytes,
            },
        )
    }))
    .unwrap_or_else(|_| InflowBytesResult::error(STATUS_PANIC))
}

/// Releases one opaque editor engine.
///
/// # Safety
///
/// `engine` must be null or a live pointer returned by `inflow_engine_create`
/// that has not already been released.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_engine_free(engine: *mut InflowEditorEngine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

fn json_owned_bytes(value: &impl serde::Serialize) -> Option<InflowOwnedBytes> {
    serde_json::to_vec(value)
        .ok()
        .map(InflowOwnedBytes::from_vec)
}

fn engine_create_error(
    status: i32,
    code: &'static str,
    message: &'static str,
) -> InflowEngineCreateResult {
    let response = EngineErrorResponse {
        schema_version: ENGINE_SCHEMA_VERSION,
        domain: "editor_engine",
        code,
        message,
        revision: None,
        request_id: None,
    };
    InflowEngineCreateResult {
        status,
        engine: ptr::null_mut(),
        payload: json_owned_bytes(&response).unwrap_or_else(InflowOwnedBytes::empty),
    }
}

fn engine_bytes_error(
    status: i32,
    code: &'static str,
    message: &'static str,
    revision: Option<u64>,
    request_id: Option<&str>,
) -> InflowBytesResult {
    let response = EngineErrorResponse {
        schema_version: ENGINE_SCHEMA_VERSION,
        domain: "editor_engine",
        code,
        message,
        revision,
        request_id,
    };
    InflowBytesResult {
        status,
        bytes: json_owned_bytes(&response).unwrap_or_else(InflowOwnedBytes::empty),
    }
}

const fn engine_error_status(error: EngineError) -> i32 {
    match error {
        EngineError::RevisionConflict => STATUS_REVISION_CONFLICT,
        EngineError::AmbiguousFormat => STATUS_AMBIGUOUS_FORMAT,
        EngineError::UnsupportedSchema
        | EngineError::EmptyDocumentId
        | EngineError::EmptyRequestId
        | EngineError::InvalidRange
        | EngineError::InvalidSelection
        | EngineError::NothingToUndo
        | EngineError::NothingToRedo => STATUS_INVALID_ARGUMENT,
        EngineError::RevisionOverflow => STATUS_PANIC,
    }
}

const fn engine_error_details(error: EngineError) -> (&'static str, &'static str) {
    match error {
        EngineError::UnsupportedSchema => (
            "unsupported_schema",
            "The request schema version is not supported.",
        ),
        EngineError::EmptyDocumentId => (
            "empty_document_id",
            "The document identifier must not be empty.",
        ),
        EngineError::EmptyRequestId => (
            "empty_request_id",
            "The request identifier must not be empty.",
        ),
        EngineError::RevisionConflict => (
            "revision_conflict",
            "The command base revision does not match the current revision.",
        ),
        EngineError::InvalidRange => (
            "invalid_range",
            "The edit range is not an extended-grapheme-aligned UTF-8 range.",
        ),
        EngineError::InvalidSelection => (
            "invalid_selection",
            "The selection is not an extended-grapheme-aligned UTF-8 range.",
        ),
        EngineError::AmbiguousFormat => (
            "ambiguous_format",
            "The requested Markdown format cannot be applied without ambiguity.",
        ),
        EngineError::NothingToUndo => ("nothing_to_undo", "The undo history is empty."),
        EngineError::NothingToRedo => ("nothing_to_redo", "The redo history is empty."),
        EngineError::RevisionOverflow => (
            "revision_overflow",
            "The document revision cannot be incremented.",
        ),
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

/// Opens UTF-8 Markdown for editing, returning readable normalized text for
/// mixed line endings while requiring a platform choice before writeback.
///
/// # Safety
///
/// When `length` is non-zero, `bytes` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_document_open(
    bytes: *const u8,
    length: usize,
) -> InflowDocumentOpenResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(bytes, length) }) else {
            return InflowDocumentOpenResult::error(STATUS_INVALID_ARGUMENT);
        };

        match document::decode_for_open(input) {
            Ok(opened) => InflowDocumentOpenResult {
                status: STATUS_OK,
                utf8: InflowOwnedBytes::from_vec(opened.text.into_bytes()),
                has_utf8_bom: u8::from(opened.has_utf8_bom),
                line_ending: match opened.line_ending {
                    LineEnding::Lf => LINE_ENDING_LF,
                    LineEnding::CrLf => LINE_ENDING_CRLF,
                },
                requires_line_ending_choice: u8::from(opened.requires_line_ending_choice),
            },
            Err(DecodeError::InvalidUtf8) => InflowDocumentOpenResult::error(STATUS_INVALID_UTF8),
            Err(DecodeError::MixedLineEndings) => {
                InflowDocumentOpenResult::error(STATUS_MIXED_LINE_ENDINGS)
            }
        }
    }))
    .unwrap_or_else(|_| InflowDocumentOpenResult::error(STATUS_PANIC))
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
    unsafe { inflow_markdown_render_html_with_options(utf8, length, RENDER_OPTIONS_DEFAULT) }
}

/// Renders UTF-8 Markdown using an explicit, validated presentation policy.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_render_html_with_options(
    utf8: *const u8,
    length: usize,
    options: u32,
) -> InflowEncodeResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(configuration) = render_configuration(options) else {
            return InflowEncodeResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowEncodeResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowEncodeResult::error(STATUS_INVALID_UTF8);
        };

        InflowEncodeResult {
            status: STATUS_OK,
            bytes: InflowOwnedBytes::from_vec(
                render::html_fragment_with_configuration(markdown, configuration).into_bytes(),
            ),
        }
    }))
    .unwrap_or_else(|_| InflowEncodeResult::error(STATUS_PANIC))
}

/// Compatibility alias for clients built while the editable `WebKit` experiment
/// existed. It now returns the canonical read-only fragment and never embeds
/// source text or editing metadata.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_render_editor_html_with_options(
    utf8: *const u8,
    length: usize,
    options: u32,
) -> InflowEncodeResult {
    unsafe { inflow_markdown_render_html_with_options(utf8, length, options) }
}

/// Renders one UTF-8 Mermaid fenced Markdown block into a deterministic,
/// script-free SVG.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_mermaid_render_svg(
    utf8: *const u8,
    length: usize,
) -> InflowEncodeResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowEncodeResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(source) = std::str::from_utf8(input) else {
            return InflowEncodeResult::error(STATUS_INVALID_UTF8);
        };
        match mermaid::svg_from_markdown(source) {
            Ok(svg) => InflowEncodeResult {
                status: STATUS_OK,
                bytes: InflowOwnedBytes::from_vec(svg.into_bytes()),
            },
            Err(_) => InflowEncodeResult::error(STATUS_UNSUPPORTED_CONTENT),
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
    unsafe { inflow_markdown_export_html_with_options(utf8, length, RENDER_OPTIONS_DEFAULT) }
}

/// Exports a snapshot using an explicit, validated presentation policy.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_export_html_with_options(
    utf8: *const u8,
    length: usize,
    options: u32,
) -> InflowHTMLExportResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(configuration) = render_configuration(options) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_ARGUMENT, 0);
        };
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_ARGUMENT, 0);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_UTF8, 0);
        };

        match export::html_document_with_configuration(markdown, configuration) {
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

/// Prepares a safe self-contained HTML candidate and reports reviewable
/// delivery warnings. Local and unsupported links are rendered as inert text.
/// A successful result may therefore have a non-zero `blocking_issues` field;
/// the host must ask the user whether to return to the source or continue.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_prepare_html_with_options(
    utf8: *const u8,
    length: usize,
    options: u32,
) -> InflowHTMLExportResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(configuration) = render_configuration(options) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_ARGUMENT, 0);
        };
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_ARGUMENT, 0);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowHTMLExportResult::error(STATUS_INVALID_UTF8, 0);
        };

        match export::prepare_html_document_with_configuration(markdown, configuration) {
            Ok(prepared) => InflowHTMLExportResult {
                status: STATUS_OK,
                html: InflowOwnedBytes::from_vec(prepared.bytes),
                blocking_issues: prepared.warnings,
            },
            Err(ExportError::OutputTooLarge) => {
                InflowHTMLExportResult::error(STATUS_OUTPUT_TOO_LARGE, 0)
            }
            Err(ExportError::UnsupportedContent(_)) => {
                unreachable!("preparation converts reviewable content to safe output")
            }
        }
    }))
    .unwrap_or_else(|_| InflowHTMLExportResult::error(STATUS_PANIC, 0))
}

fn render_configuration(options: u32) -> Option<render::RenderConfiguration> {
    if options & !RENDER_OPTIONS_DEFAULT != 0 {
        return None;
    }
    Some(render::RenderConfiguration {
        math_enabled: options & RENDER_OPTION_MATH != 0,
        mermaid_enabled: options & RENDER_OPTION_MERMAID != 0,
    })
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

/// Plans removal of all supported Markdown format markers fully contained by
/// one non-empty selection.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_clear_format(
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
        markdown_edit_result(format::clear_format(source, selection_start..selection_end))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one predictable inline Markdown link insertion for a UTF-8 snapshot.
///
/// # Safety
///
/// Non-zero source and destination lengths require pointers to that many
/// readable bytes for the duration of this call. Selection offsets are
/// end-exclusive UTF-8 byte offsets aligned with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_insert_link(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
    destination_utf8: *const u8,
    destination_length: usize,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Some(destination) = (unsafe { borrowed_bytes(destination_utf8, destination_length) })
        else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let (Ok(source), Ok(destination)) =
            (std::str::from_utf8(input), std::str::from_utf8(destination))
        else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        markdown_edit_result(format::insert_link(
            source,
            selection_start..selection_end,
            destination,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one standard Markdown image insertion for a UTF-8 snapshot.
///
/// # Safety
///
/// Non-zero source, destination and alternative lengths require pointers to
/// that many readable bytes for the duration of this call. Selection offsets
/// are end-exclusive UTF-8 byte offsets aligned with grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_insert_image(
    utf8: *const u8,
    length: usize,
    selection_start: usize,
    selection_end: usize,
    destination_utf8: *const u8,
    destination_length: usize,
    alternative_utf8: *const u8,
    alternative_length: usize,
) -> InflowMarkdownEditResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Some(destination) = (unsafe { borrowed_bytes(destination_utf8, destination_length) })
        else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Some(alternative) = (unsafe { borrowed_bytes(alternative_utf8, alternative_length) })
        else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_ARGUMENT);
        };
        let (Ok(source), Ok(destination), Ok(alternative)) = (
            std::str::from_utf8(input),
            std::str::from_utf8(destination),
            std::str::from_utf8(alternative),
        ) else {
            return InflowMarkdownEditResult::error(STATUS_INVALID_UTF8);
        };
        markdown_edit_result(format::insert_image(
            source,
            selection_start..selection_end,
            destination,
            alternative,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one three-column, three-row Markdown table insertion.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_insert_table(
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
        markdown_edit_result(format::insert_table(source, selection_start..selection_end))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one `CommonMark` horizontal-rule insertion after the current selection.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_insert_horizontal_rule(
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
        markdown_edit_result(format::insert_horizontal_rule(
            source,
            selection_start..selection_end,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one unique Markdown footnote reference and editable definition.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_insert_footnote(
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
        markdown_edit_result(format::insert_footnote(
            source,
            selection_start..selection_end,
        ))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one inline or display formula insertion.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_insert_math(
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
        markdown_edit_result(format::insert_math(source, selection_start..selection_end))
    }))
    .unwrap_or_else(|_| InflowMarkdownEditResult::error(STATUS_PANIC))
}

/// Plans one supported Mermaid fenced-diagram insertion.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call. Selection offsets are end-exclusive UTF-8 byte
/// offsets and must align with extended grapheme boundaries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_insert_mermaid(
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
        markdown_edit_result(format::insert_mermaid(
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

/// Extracts parsed Markdown link and image destinations in source order.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_document_references(
    utf8: *const u8,
    length: usize,
) -> InflowReferenceResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowReferenceResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowReferenceResult::error(STATUS_INVALID_UTF8);
        };

        let mut target_text_utf8 = Vec::new();
        let references = reference::references(markdown)
            .into_iter()
            .map(|reference| {
                let target_start = target_text_utf8.len();
                let target = reference.target.as_bytes();
                target_text_utf8.extend_from_slice(target);

                InflowReference {
                    kind: match reference.kind {
                        ReferenceKind::Link => REFERENCE_KIND_LINK,
                        ReferenceKind::Image => REFERENCE_KIND_IMAGE,
                    },
                    source_start: reference.source_range.start,
                    source_end: reference.source_range.end,
                    target_start,
                    target_length: target.len(),
                }
            })
            .collect();

        InflowReferenceResult {
            status: STATUS_OK,
            references: InflowOwnedReferences::from_vec(references),
            target_text_utf8: InflowOwnedBytes::from_vec(target_text_utf8),
        }
    }))
    .unwrap_or_else(|_| InflowReferenceResult::error(STATUS_PANIC))
}

/// Returns semantic syntax spans for UTF-8 Markdown source.
///
/// # Safety
///
/// When `length` is non-zero, `utf8` must point to `length` readable bytes for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_markdown_highlight(
    utf8: *const u8,
    length: usize,
) -> InflowHighlightResult {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(input) = (unsafe { borrowed_bytes(utf8, length) }) else {
            return InflowHighlightResult::error(STATUS_INVALID_ARGUMENT);
        };
        let Ok(markdown) = std::str::from_utf8(input) else {
            return InflowHighlightResult::error(STATUS_INVALID_UTF8);
        };

        let spans = highlight::spans(markdown)
            .into_iter()
            .map(|span| InflowHighlightSpan {
                kind: match span.kind {
                    highlight::HighlightKind::Heading => HIGHLIGHT_KIND_HEADING,
                    highlight::HighlightKind::Emphasis => HIGHLIGHT_KIND_EMPHASIS,
                    highlight::HighlightKind::Strong => HIGHLIGHT_KIND_STRONG,
                    highlight::HighlightKind::Strikethrough => HIGHLIGHT_KIND_STRIKETHROUGH,
                    highlight::HighlightKind::Code => HIGHLIGHT_KIND_CODE,
                    highlight::HighlightKind::Link => HIGHLIGHT_KIND_LINK,
                    highlight::HighlightKind::Image => HIGHLIGHT_KIND_IMAGE,
                    highlight::HighlightKind::BlockQuote => HIGHLIGHT_KIND_BLOCK_QUOTE,
                    highlight::HighlightKind::List => HIGHLIGHT_KIND_LIST,
                    highlight::HighlightKind::Table => HIGHLIGHT_KIND_TABLE,
                    highlight::HighlightKind::Footnote => HIGHLIGHT_KIND_FOOTNOTE,
                    highlight::HighlightKind::Math => HIGHLIGHT_KIND_MATH,
                    highlight::HighlightKind::Raw => HIGHLIGHT_KIND_RAW,
                    highlight::HighlightKind::Rule => HIGHLIGHT_KIND_RULE,
                },
                source_start: span.source_range.start,
                source_end: span.source_range.end,
            })
            .collect();
        InflowHighlightResult {
            status: STATUS_OK,
            spans: InflowOwnedHighlightSpans::from_vec(spans),
        }
    }))
    .unwrap_or_else(|_| InflowHighlightResult::error(STATUS_PANIC))
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

/// Releases syntax spans returned by this library.
///
/// # Safety
///
/// `data` and `length` must be an unchanged pair returned by this library and
/// must not have been released previously. A null pointer is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_owned_highlight_spans_free(
    data: *mut InflowHighlightSpan,
    length: usize,
) {
    if data.is_null() {
        return;
    }

    let slice = ptr::slice_from_raw_parts_mut(data, length);
    drop(unsafe { Box::from_raw(slice) });
}

/// Releases Markdown references returned by this library.
///
/// # Safety
///
/// `data` and `length` must be an unchanged pair returned by this library and
/// must not have been released previously. A null pointer is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inflow_owned_references_free(data: *mut InflowReference, length: usize) {
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
    fn ffi_editor_engine_round_trips_unicode_patches_and_rejects_stale_revisions() {
        let create_request = r#"{
            "schema_version": 1,
            "document_id": "document-1",
            "text": "Hi 🌍",
            "selection": { "start": 7, "end": 7 }
        }"#
        .as_bytes();
        let created =
            unsafe { inflow_engine_create(create_request.as_ptr(), create_request.len()) };
        assert_eq!(created.status, STATUS_OK);
        assert!(!created.engine.is_null());
        let created_payload = unsafe {
            std::slice::from_raw_parts(created.payload.data, created.payload.length).to_vec()
        };
        unsafe { inflow_owned_bytes_free(created.payload.data, created.payload.length) };
        let created_snapshot: serde_json::Value =
            serde_json::from_slice(&created_payload).expect("snapshot should be JSON");
        assert_eq!(created_snapshot["revision"], 0);
        assert_eq!(created_snapshot["text"], "Hi 🌍");

        let command = r#"{
            "schema_version": 1,
            "request_id": "request-1",
            "command": {
                "type": "replace_text",
                "base_revision": 0,
                "range": { "start": 3, "end": 7 },
                "inserted": "世界",
                "selection_after": { "start": 9, "end": 9 }
            }
        }"#
        .as_bytes();
        let dispatched =
            unsafe { inflow_engine_dispatch(created.engine, command.as_ptr(), command.len()) };
        assert_eq!(dispatched.status, STATUS_OK);
        let patch = unsafe {
            std::slice::from_raw_parts(dispatched.bytes.data, dispatched.bytes.length).to_vec()
        };
        unsafe { inflow_owned_bytes_free(dispatched.bytes.data, dispatched.bytes.length) };
        let patch: serde_json::Value =
            serde_json::from_slice(&patch).expect("patch should be JSON");
        assert_eq!(patch["request_id"], "request-1");
        assert_eq!(patch["patch"]["revision"], 1);

        let snapshot = unsafe { inflow_engine_snapshot(created.engine) };
        assert_eq!(snapshot.status, STATUS_OK);
        let snapshot_bytes = unsafe {
            std::slice::from_raw_parts(snapshot.bytes.data, snapshot.bytes.length).to_vec()
        };
        unsafe { inflow_owned_bytes_free(snapshot.bytes.data, snapshot.bytes.length) };
        let snapshot: serde_json::Value =
            serde_json::from_slice(&snapshot_bytes).expect("snapshot should be JSON");
        assert_eq!(snapshot["revision"], 1);
        assert_eq!(snapshot["text"], "Hi 世界");

        let refresh = r#"{
            "schema_version": 1,
            "request_id": "refresh-1",
            "command": {
                "type": "refresh_derived",
                "revision": 1
            }
        }"#
        .as_bytes();
        let refreshed =
            unsafe { inflow_engine_dispatch(created.engine, refresh.as_ptr(), refresh.len()) };
        assert_eq!(refreshed.status, STATUS_OK);
        let refreshed_bytes = unsafe {
            std::slice::from_raw_parts(refreshed.bytes.data, refreshed.bytes.length).to_vec()
        };
        unsafe { inflow_owned_bytes_free(refreshed.bytes.data, refreshed.bytes.length) };
        let refreshed: serde_json::Value =
            serde_json::from_slice(&refreshed_bytes).expect("derived patch should be JSON");
        assert_eq!(refreshed["patch"]["revision"], 1);
        assert!(refreshed["patch"]["text"].is_null());
        assert_eq!(refreshed["patch"]["derived"]["revision"], 1);
        assert_eq!(
            refreshed["patch"]["derived"]["render"]["blocks"][0]["visible_text"],
            "Hi 世界"
        );

        let stale =
            unsafe { inflow_engine_dispatch(created.engine, command.as_ptr(), command.len()) };
        assert_eq!(stale.status, STATUS_REVISION_CONFLICT);
        let error =
            unsafe { std::slice::from_raw_parts(stale.bytes.data, stale.bytes.length).to_vec() };
        unsafe { inflow_owned_bytes_free(stale.bytes.data, stale.bytes.length) };
        let error: serde_json::Value =
            serde_json::from_slice(&error).expect("error should be JSON");
        assert_eq!(error["code"], "revision_conflict");
        assert_eq!(error["revision"], 1);
        assert_eq!(error["request_id"], "request-1");

        unsafe { inflow_engine_free(created.engine) };
    }

    #[test]
    fn ffi_editor_engine_rejects_invalid_handles_and_requests_without_allocating_state() {
        let invalid = unsafe { inflow_engine_create(ptr::null(), 1) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.engine.is_null());
        unsafe { inflow_owned_bytes_free(invalid.payload.data, invalid.payload.length) };

        let snapshot = unsafe { inflow_engine_snapshot(ptr::null()) };
        assert_eq!(snapshot.status, STATUS_INVALID_ARGUMENT);
        unsafe { inflow_owned_bytes_free(snapshot.bytes.data, snapshot.bytes.length) };

        unsafe { inflow_engine_free(ptr::null_mut()) };
    }

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
    fn ffi_opens_mixed_line_endings_without_authorizing_writeback() {
        let source = b"one\r\ntwo\nthree\rfour";
        let opened = unsafe { inflow_document_open(source.as_ptr(), source.len()) };

        assert_eq!(opened.status, STATUS_OK);
        assert_eq!(opened.requires_line_ending_choice, 1);
        assert_eq!(opened.line_ending, LINE_ENDING_LF);
        let normalized =
            unsafe { std::slice::from_raw_parts(opened.utf8.data, opened.utf8.length).to_vec() };
        unsafe { inflow_owned_bytes_free(opened.utf8.data, opened.utf8.length) };
        assert_eq!(normalized, b"one\ntwo\nthree\nfour");
    }

    #[test]
    fn ffi_rejects_null_non_empty_input() {
        let result = unsafe { inflow_document_decode(ptr::null(), 1) };
        assert_eq!(result.status, STATUS_INVALID_ARGUMENT);
        assert!(result.utf8.data.is_null());

        let opened = unsafe { inflow_document_open(ptr::null(), 1) };
        assert_eq!(opened.status, STATUS_INVALID_ARGUMENT);
        assert!(opened.utf8.data.is_null());
        assert_eq!(opened.utf8.length, 0);
        assert_eq!(opened.requires_line_ending_choice, 0);

        let invalid = unsafe { inflow_document_open([0xFF].as_ptr(), 1) };
        assert_eq!(invalid.status, STATUS_INVALID_UTF8);
        assert!(invalid.utf8.data.is_null());
        assert_eq!(invalid.utf8.length, 0);
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
    fn ffi_legacy_editor_renderer_is_read_only_and_does_not_embed_source() {
        let markdown = "正文 **加粗**";
        let result = unsafe {
            inflow_markdown_render_editor_html_with_options(
                markdown.as_ptr(),
                markdown.len(),
                RENDER_OPTIONS_DEFAULT,
            )
        };

        assert_eq!(result.status, STATUS_OK);
        let html =
            unsafe { std::slice::from_raw_parts(result.bytes.data, result.bytes.length).to_vec() };
        unsafe { inflow_owned_bytes_free(result.bytes.data, result.bytes.length) };
        let html = String::from_utf8(html).expect("renderer returns UTF-8");
        assert_eq!(html, "<p>正文 <strong>加粗</strong></p>\n");
        assert!(!html.contains("data-inflow-source-"));
    }

    #[test]
    fn ffi_renders_mermaid_svg_without_an_html_extraction_step() {
        let source = "```mermaid\nflowchart LR\nA[开始] --> B[结束]\n```";
        let result = unsafe { inflow_mermaid_render_svg(source.as_ptr(), source.len()) };

        assert_eq!(result.status, STATUS_OK);
        let svg =
            unsafe { std::slice::from_raw_parts(result.bytes.data, result.bytes.length).to_vec() };
        unsafe { inflow_owned_bytes_free(result.bytes.data, result.bytes.length) };
        let svg = String::from_utf8(svg).expect("renderer returns UTF-8");
        assert!(svg.starts_with("<figure class=\"mermaid-diagram\""));
        assert!(svg.contains("<svg"));
        assert!(svg.contains("开始"));

        let unsupported = "```mermaid\nsequenceDiagram\nA->>B: hi\n```";
        let unsupported_result =
            unsafe { inflow_mermaid_render_svg(unsupported.as_ptr(), unsupported.len()) };
        assert_eq!(unsupported_result.status, STATUS_UNSUPPORTED_CONTENT);
        assert!(unsupported_result.bytes.data.is_null());
        assert_eq!(unsupported_result.bytes.length, 0);
    }

    #[test]
    fn ffi_renders_with_independent_presentation_options() {
        let markdown = "$x$\n\n```mermaid\nflowchart TD\nA --> B\n```";
        let result = unsafe {
            inflow_markdown_render_html_with_options(
                markdown.as_ptr(),
                markdown.len(),
                RENDER_OPTION_MERMAID,
            )
        };
        assert_eq!(result.status, STATUS_OK);
        let html = unsafe { std::slice::from_raw_parts(result.bytes.data, result.bytes.length) };
        let html = std::str::from_utf8(html).unwrap();
        assert!(html.contains("$x$"));
        assert!(!html.contains("<math"));
        assert!(html.contains("mermaid-diagram"));
        unsafe { inflow_owned_bytes_free(result.bytes.data, result.bytes.length) };

        let invalid = unsafe {
            inflow_markdown_render_html_with_options(markdown.as_ptr(), markdown.len(), 1 << 31)
        };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.bytes.data.is_null());
        assert_eq!(invalid.bytes.length, 0);
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
        assert_eq!(std::mem::size_of::<InflowDocumentOpenResult>(), 32);
        assert_eq!(std::mem::align_of::<InflowDocumentOpenResult>(), 8);
        assert_eq!(std::mem::size_of::<InflowAnalysisResult>(), 64);
        assert_eq!(std::mem::size_of::<InflowSearchMatch>(), 16);
        assert_eq!(std::mem::align_of::<InflowSearchMatch>(), 8);
        assert_eq!(std::mem::size_of::<InflowOwnedSearchMatches>(), 16);
        assert_eq!(std::mem::size_of::<InflowSearchResult>(), 24);
        assert_eq!(std::mem::size_of::<InflowReference>(), 40);
        assert_eq!(std::mem::align_of::<InflowReference>(), 8);
        assert_eq!(std::mem::size_of::<InflowOwnedReferences>(), 16);
        assert_eq!(std::mem::size_of::<InflowReferenceResult>(), 40);
        assert_eq!(std::mem::size_of::<InflowHighlightSpan>(), 24);
        assert_eq!(std::mem::align_of::<InflowHighlightSpan>(), 8);
        assert_eq!(std::mem::size_of::<InflowOwnedHighlightSpans>(), 16);
        assert_eq!(std::mem::size_of::<InflowHighlightResult>(), 24);
        assert_eq!(std::mem::size_of::<InflowHTMLExportResult>(), 32);
        assert_eq!(std::mem::size_of::<InflowMarkdownEditResult>(), 56);
        assert_eq!(std::mem::size_of::<InflowEngineCreateResult>(), 32);
        assert_eq!(std::mem::size_of::<InflowBytesResult>(), 24);
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
    fn ffi_extracts_markdown_references_and_releases_owned_results() {
        let markdown = "[文档](../notes/一.md#part) ![图片](assets/photo.png)";
        let result = unsafe { inflow_document_references(markdown.as_ptr(), markdown.len()) };

        assert_eq!(result.status, STATUS_OK);
        let references =
            unsafe { std::slice::from_raw_parts(result.references.data, result.references.length) };
        let targets = unsafe {
            std::slice::from_raw_parts(result.target_text_utf8.data, result.target_text_utf8.length)
        };
        assert_eq!(references.len(), 2);
        assert_eq!(references[0].kind, REFERENCE_KIND_LINK);
        assert_eq!(references[1].kind, REFERENCE_KIND_IMAGE);
        assert_eq!(
            &markdown[references[0].source_start..references[0].source_end],
            "[文档](../notes/一.md#part)"
        );
        assert_eq!(
            &markdown[references[1].source_start..references[1].source_end],
            "![图片](assets/photo.png)"
        );
        assert_eq!(
            std::str::from_utf8(
                &targets[references[0].target_start
                    ..references[0].target_start + references[0].target_length]
            )
            .unwrap(),
            "../notes/一.md#part"
        );
        assert_eq!(
            std::str::from_utf8(
                &targets[references[1].target_start
                    ..references[1].target_start + references[1].target_length]
            )
            .unwrap(),
            "assets/photo.png"
        );

        unsafe {
            inflow_owned_references_free(result.references.data, result.references.length);
            inflow_owned_bytes_free(result.target_text_utf8.data, result.target_text_utf8.length);
        }
    }

    #[test]
    fn ffi_reference_extraction_rejects_invalid_inputs_without_allocating() {
        for result in [
            unsafe { inflow_document_references(ptr::null(), 1) },
            unsafe { inflow_document_references([0xFF].as_ptr(), 1) },
        ] {
            assert!(matches!(
                result.status,
                STATUS_INVALID_ARGUMENT | STATUS_INVALID_UTF8
            ));
            assert!(result.references.data.is_null());
            assert_eq!(result.references.length, 0);
            assert!(result.target_text_utf8.data.is_null());
            assert_eq!(result.target_text_utf8.length, 0);
        }
    }

    #[test]
    fn ffi_highlights_unicode_markdown_and_releases_spans() {
        let markdown = "# 标题\n\n**bold** and `code`";
        let result = unsafe { inflow_markdown_highlight(markdown.as_ptr(), markdown.len()) };

        assert_eq!(result.status, STATUS_OK);
        let spans = unsafe { std::slice::from_raw_parts(result.spans.data, result.spans.length) };
        assert!(spans.iter().any(|span| {
            span.kind == HIGHLIGHT_KIND_HEADING
                && &markdown[span.source_start..span.source_end] == "# 标题"
        }));
        assert!(spans.iter().any(|span| {
            span.kind == HIGHLIGHT_KIND_STRONG
                && &markdown[span.source_start..span.source_end] == "**bold**"
        }));
        assert!(spans.iter().any(|span| {
            span.kind == HIGHLIGHT_KIND_CODE
                && &markdown[span.source_start..span.source_end] == "`code`"
        }));

        unsafe { inflow_owned_highlight_spans_free(result.spans.data, result.spans.length) };
    }

    #[test]
    fn ffi_highlight_rejects_invalid_inputs_without_allocating() {
        for result in [
            unsafe { inflow_markdown_highlight(ptr::null(), 1) },
            unsafe { inflow_markdown_highlight([0xFF].as_ptr(), 1) },
        ] {
            assert!(matches!(
                result.status,
                STATUS_INVALID_ARGUMENT | STATUS_INVALID_UTF8
            ));
            assert!(result.spans.data.is_null());
            assert_eq!(result.spans.length, 0);
        }
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

        let unsupported = "![image](photo.png) and [local](../note.md)";
        let result =
            unsafe { inflow_markdown_export_html(unsupported.as_ptr(), unsupported.len()) };
        assert_eq!(result.status, STATUS_UNSUPPORTED_CONTENT);
        assert_eq!(result.blocking_issues, export::ISSUE_LOCAL_LINK);
        assert!(result.html.data.is_null());
        assert_eq!(result.html.length, 0);

        let formula = "$x_1^2$";
        let result = unsafe { inflow_markdown_export_html(formula.as_ptr(), formula.len()) };
        assert_eq!(result.status, STATUS_OK);
        let html = unsafe { std::slice::from_raw_parts(result.html.data, result.html.length) };
        assert!(std::str::from_utf8(html).unwrap().contains("<msubsup>"));
        unsafe { inflow_owned_bytes_free(result.html.data, result.html.length) };

        let configurable = unsafe {
            inflow_markdown_export_html_with_options(
                formula.as_ptr(),
                formula.len(),
                RENDER_OPTION_MERMAID,
            )
        };
        assert_eq!(configurable.status, STATUS_OK);
        let html =
            unsafe { std::slice::from_raw_parts(configurable.html.data, configurable.html.length) };
        assert!(std::str::from_utf8(html).unwrap().contains("$x_1^2$"));
        assert!(!std::str::from_utf8(html).unwrap().contains("<math"));
        unsafe { inflow_owned_bytes_free(configurable.html.data, configurable.html.length) };

        let invalid = unsafe {
            inflow_markdown_export_html_with_options(formula.as_ptr(), formula.len(), 1 << 31)
        };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.html.data.is_null());
        assert_eq!(invalid.html.length, 0);
    }

    #[test]
    fn ffi_prepares_safe_html_and_returns_reviewable_warnings() {
        let markdown = b"[local](/Users/person/Secret.md) [run](javascript:alert(1))";
        let result = unsafe {
            inflow_markdown_prepare_html_with_options(
                markdown.as_ptr(),
                markdown.len(),
                RENDER_OPTIONS_DEFAULT,
            )
        };

        assert_eq!(result.status, STATUS_OK);
        assert_eq!(
            result.blocking_issues,
            export::ISSUE_LOCAL_LINK | export::ISSUE_UNSAFE_LINK
        );
        let html = unsafe { std::slice::from_raw_parts(result.html.data, result.html.length) };
        let html = std::str::from_utf8(html).unwrap();
        assert_eq!(html.matches("inflow-disabled-link").count(), 2);
        assert!(!html.contains("/Users/person"));
        assert!(!html.contains("javascript:"));
        unsafe { inflow_owned_bytes_free(result.html.data, result.html.length) };
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
    fn ffi_clears_supported_format_and_reports_plain_selection() {
        let source = "# **标题**\n";
        let result =
            unsafe { inflow_markdown_clear_format(source.as_ptr(), source.len(), 0, source.len()) };
        assert_eq!(result.status, STATUS_OK);
        assert_eq!(result.replace_start, 0);
        assert_eq!(result.replace_end, source.len());
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(std::str::from_utf8(replacement).unwrap(), "标题\n");
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let plain = "plain";
        let unavailable =
            unsafe { inflow_markdown_clear_format(plain.as_ptr(), plain.len(), 0, plain.len()) };
        assert_eq!(unavailable.status, STATUS_AMBIGUOUS_FORMAT);
        assert!(unavailable.replacement.data.is_null());

        let invalid = unsafe { inflow_markdown_clear_format(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_inserts_link_and_releases_result() {
        let source = "Read 文档";
        let destination = "https://example.com";
        let start = "Read ".len();
        let result = unsafe {
            inflow_markdown_insert_link(
                source.as_ptr(),
                source.len(),
                start,
                source.len(),
                destination.as_ptr(),
                destination.len(),
            )
        };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(
            std::str::from_utf8(replacement).unwrap(),
            "[文档](<https://example.com>)"
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        for invalid in [
            unsafe {
                inflow_markdown_insert_link(
                    ptr::null(),
                    1,
                    0,
                    0,
                    destination.as_ptr(),
                    destination.len(),
                )
            },
            unsafe {
                inflow_markdown_insert_link(source.as_ptr(), source.len(), 0, 0, ptr::null(), 1)
            },
        ] {
            assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
            assert!(invalid.replacement.data.is_null());
        }
    }

    #[test]
    fn ffi_inserts_image_and_releases_result() {
        let source = "Before 图片";
        let destination = "assets/photo.png";
        let alternative = "photo";
        let start = "Before ".len();
        let result = unsafe {
            inflow_markdown_insert_image(
                source.as_ptr(),
                source.len(),
                start,
                source.len(),
                destination.as_ptr(),
                destination.len(),
                alternative.as_ptr(),
                alternative.len(),
            )
        };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(
            std::str::from_utf8(replacement).unwrap(),
            "![图片](<assets/photo.png>)"
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        for invalid in [
            unsafe {
                inflow_markdown_insert_image(
                    ptr::null(),
                    1,
                    0,
                    0,
                    destination.as_ptr(),
                    destination.len(),
                    alternative.as_ptr(),
                    alternative.len(),
                )
            },
            unsafe {
                inflow_markdown_insert_image(
                    source.as_ptr(),
                    source.len(),
                    0,
                    0,
                    ptr::null(),
                    1,
                    alternative.as_ptr(),
                    alternative.len(),
                )
            },
            unsafe {
                inflow_markdown_insert_image(
                    source.as_ptr(),
                    source.len(),
                    0,
                    0,
                    destination.as_ptr(),
                    destination.len(),
                    ptr::null(),
                    1,
                )
            },
        ] {
            assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
            assert!(invalid.replacement.data.is_null());
        }
    }

    #[test]
    fn ffi_inserts_table_and_releases_result() {
        let source = "表头";
        let result =
            unsafe { inflow_markdown_insert_table(source.as_ptr(), source.len(), 0, source.len()) };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert!(
            std::str::from_utf8(replacement)
                .unwrap()
                .starts_with("| 表头 | 标题 2 | 标题 3 |")
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid = unsafe { inflow_markdown_insert_table(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_inserts_horizontal_rule_and_releases_result() {
        let source = "before";
        let result = unsafe {
            inflow_markdown_insert_horizontal_rule(
                source.as_ptr(),
                source.len(),
                source.len(),
                source.len(),
            )
        };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(std::str::from_utf8(replacement).unwrap(), "\n\n---\n\n");
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid = unsafe { inflow_markdown_insert_horizontal_rule(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_inserts_footnote_and_releases_result() {
        let source = "Anchor";
        let result = unsafe {
            inflow_markdown_insert_footnote(
                source.as_ptr(),
                source.len(),
                source.len(),
                source.len(),
            )
        };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(
            std::str::from_utf8(replacement).unwrap(),
            "[^note-1]\n\n[^note-1]: 脚注内容\n"
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid = unsafe { inflow_markdown_insert_footnote(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_inserts_math_and_releases_result() {
        let source = "x^2";
        let result =
            unsafe { inflow_markdown_insert_math(source.as_ptr(), source.len(), 0, source.len()) };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert_eq!(std::str::from_utf8(replacement).unwrap(), "$x^2$");
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid = unsafe { inflow_markdown_insert_math(ptr::null(), 1, 0, 0) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.replacement.data.is_null());
    }

    #[test]
    fn ffi_inserts_mermaid_and_releases_result() {
        let result = unsafe { inflow_markdown_insert_mermaid(ptr::null(), 0, 0, 0) };
        assert_eq!(result.status, STATUS_OK);
        let replacement = unsafe {
            std::slice::from_raw_parts(result.replacement.data, result.replacement.length)
        };
        assert!(
            std::str::from_utf8(replacement)
                .unwrap()
                .starts_with("```mermaid\nflowchart TD")
        );
        unsafe {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length);
        }

        let invalid = unsafe { inflow_markdown_insert_mermaid(ptr::null(), 1, 0, 0) };
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
