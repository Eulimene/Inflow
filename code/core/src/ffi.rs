//! Minimal stable C ABI for the stateful editor engine.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use crate::engine::{
    CommandEnvelope, ENGINE_SCHEMA_VERSION, EditorEngine, EngineCreateRequest, EngineError,
};

pub const STATUS_OK: i32 = 0;
pub const STATUS_INVALID_ARGUMENT: i32 = 1;
pub const STATUS_INVALID_UTF8: i32 = 2;
pub const STATUS_MIXED_LINE_ENDINGS: i32 = 3;
pub const STATUS_OUTPUT_TOO_LARGE: i32 = 5;
pub const STATUS_AMBIGUOUS_FORMAT: i32 = 6;
pub const STATUS_REVISION_CONFLICT: i32 = 7;
pub const STATUS_PANIC: i32 = 255;

/// Status code returned by the stable C ABI.
pub type InflowStatus = i32;

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
        let data = Box::into_raw(bytes.into_boxed_slice()).cast::<u8>();
        Self { data, length }
    }
}

/// Opaque editor state owned by Rust and accessed only through engine functions.
pub struct InflowEditorEngine {
    engine: EditorEngine,
}

#[repr(C)]
pub struct InflowEngineCreateResult {
    pub status: InflowStatus,
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
    pub status: InflowStatus,
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

/// Returns a full versioned JSON snapshot for resynchronization.
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
        EngineError::InvalidUtf8 => STATUS_INVALID_UTF8,
        EngineError::MixedLineEndings => STATUS_MIXED_LINE_ENDINGS,
        EngineError::UnsupportedSchema
        | EngineError::EmptyDocumentId
        | EngineError::EmptyRequestId
        | EngineError::InvalidRange
        | EngineError::InvalidSelection
        | EngineError::NothingToUndo
        | EngineError::NothingToRedo
        | EngineError::EmptySaveId
        | EngineError::UnknownSave
        | EngineError::ReadOnly => STATUS_INVALID_ARGUMENT,
        EngineError::OutputTooLarge => STATUS_OUTPUT_TOO_LARGE,
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
        EngineError::EmptySaveId => ("empty_save_id", "The save identifier is empty."),
        EngineError::UnknownSave => (
            "unknown_save",
            "The save identifier does not name a prepared save.",
        ),
        EngineError::ReadOnly => (
            "read_only",
            "The document mode does not permit text mutations.",
        ),
        EngineError::InvalidUtf8 => ("invalid_utf8", "The document bytes are not valid UTF-8."),
        EngineError::MixedLineEndings => (
            "mixed_line_endings",
            "The document contains unsupported mixed line endings.",
        ),
        EngineError::OutputTooLarge => (
            "output_too_large",
            "The generated output exceeds the configured size limit.",
        ),
        EngineError::RevisionOverflow => (
            "revision_overflow",
            "The document revision cannot be incremented.",
        ),
    }
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

    #[allow(clippy::needless_pass_by_value)] // Taking ownership documents the single free in tests.
    fn copy_and_free(bytes: InflowOwnedBytes) -> Vec<u8> {
        let copied = if bytes.length == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(bytes.data, bytes.length).to_vec() }
        };
        unsafe { inflow_owned_bytes_free(bytes.data, bytes.length) };
        copied
    }

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
        let created_snapshot: serde_json::Value =
            serde_json::from_slice(&copy_and_free(created.payload))
                .expect("snapshot should be JSON");
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
        let patch: serde_json::Value =
            serde_json::from_slice(&copy_and_free(dispatched.bytes)).expect("patch should be JSON");
        assert_eq!(patch["patch"]["revision"], 1);

        let snapshot = unsafe { inflow_engine_snapshot(created.engine) };
        assert_eq!(snapshot.status, STATUS_OK);
        let snapshot: serde_json::Value = serde_json::from_slice(&copy_and_free(snapshot.bytes))
            .expect("snapshot should be JSON");
        assert_eq!(snapshot["text"], "Hi 世界");

        let stale =
            unsafe { inflow_engine_dispatch(created.engine, command.as_ptr(), command.len()) };
        assert_eq!(stale.status, STATUS_REVISION_CONFLICT);
        let error: serde_json::Value =
            serde_json::from_slice(&copy_and_free(stale.bytes)).expect("error should be JSON");
        assert_eq!(error["code"], "revision_conflict");
        assert_eq!(error["revision"], 1);
        unsafe { inflow_engine_free(created.engine) };
    }

    #[test]
    fn ffi_engine_rejects_invalid_handles_and_owns_only_byte_results() {
        let invalid = unsafe { inflow_engine_create(ptr::null(), 1) };
        assert_eq!(invalid.status, STATUS_INVALID_ARGUMENT);
        assert!(invalid.engine.is_null());
        let error: serde_json::Value = serde_json::from_slice(&copy_and_free(invalid.payload))
            .expect("structured error should be JSON");
        assert_eq!(error["code"], "invalid_request");

        let snapshot = unsafe { inflow_engine_snapshot(ptr::null()) };
        assert_eq!(snapshot.status, STATUS_INVALID_ARGUMENT);
        let _ = copy_and_free(snapshot.bytes);
        unsafe { inflow_engine_free(ptr::null_mut()) };
    }
}
