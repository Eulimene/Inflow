#ifndef INFLOW_CORE_H
#define INFLOW_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t InflowStatus;

static const InflowStatus INFLOW_STATUS_OK = 0;
static const InflowStatus INFLOW_STATUS_INVALID_ARGUMENT = 1;
static const InflowStatus INFLOW_STATUS_INVALID_UTF8 = 2;
static const InflowStatus INFLOW_STATUS_MIXED_LINE_ENDINGS = 3;
static const InflowStatus INFLOW_STATUS_PANIC = 255;

static const uint8_t INFLOW_LINE_ENDING_LF = 0;
static const uint8_t INFLOW_LINE_ENDING_CRLF = 1;

typedef struct InflowOwnedBytes {
    uint8_t *data;
    uintptr_t length;
} InflowOwnedBytes;

typedef struct InflowDecodeResult {
    InflowStatus status;
    InflowOwnedBytes utf8;
    uint8_t has_utf8_bom;
    uint8_t line_ending;
} InflowDecodeResult;

typedef struct InflowEncodeResult {
    InflowStatus status;
    InflowOwnedBytes bytes;
} InflowEncodeResult;

/// Version of the stable C ABI implemented by the linked Inflow core.
uint32_t inflow_core_abi_version(void);

/// Decodes UTF-8 Markdown and normalizes in-memory line endings to LF.
/// The returned bytes belong to Inflow and must be released with
/// inflow_owned_bytes_free.
InflowDecodeResult inflow_document_decode(const uint8_t *bytes, uintptr_t length);

/// Encodes normalized UTF-8 Markdown using the requested BOM and line ending.
/// The returned bytes belong to Inflow and must be released with
/// inflow_owned_bytes_free.
InflowEncodeResult inflow_document_encode(
    const uint8_t *utf8,
    uintptr_t length,
    uint8_t has_utf8_bom,
    uint8_t line_ending
);

/// Renders UTF-8 Markdown into an HTML fragment. Raw HTML is escaped. The
/// returned bytes belong to Inflow and must be released with
/// inflow_owned_bytes_free.
InflowEncodeResult inflow_markdown_render_html(
    const uint8_t *utf8,
    uintptr_t length
);

/// Releases an unchanged pointer and length returned by Inflow.
void inflow_owned_bytes_free(uint8_t *data, uintptr_t length);

#ifdef __cplusplus
}
#endif

#endif
