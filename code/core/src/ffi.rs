//! Stable C ABI adapter for the document core.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use crate::document::{self, DecodeError, LineEnding};
use crate::render;

pub const STATUS_OK: i32 = 0;
pub const STATUS_INVALID_ARGUMENT: i32 = 1;
pub const STATUS_INVALID_UTF8: i32 = 2;
pub const STATUS_MIXED_LINE_ENDINGS: i32 = 3;
pub const STATUS_PANIC: i32 = 255;

pub const LINE_ENDING_LF: u8 = 0;
pub const LINE_ENDING_CRLF: u8 = 1;

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
}
