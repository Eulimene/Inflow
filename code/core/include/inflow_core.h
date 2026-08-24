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
static const InflowStatus INFLOW_STATUS_UNSUPPORTED_CONTENT = 4;
static const InflowStatus INFLOW_STATUS_OUTPUT_TOO_LARGE = 5;
static const InflowStatus INFLOW_STATUS_AMBIGUOUS_FORMAT = 6;
static const InflowStatus INFLOW_STATUS_PANIC = 255;

static const uint8_t INFLOW_LINE_ENDING_LF = 0;
static const uint8_t INFLOW_LINE_ENDING_CRLF = 1;

static const uint8_t INFLOW_INLINE_FORMAT_BOLD = 1;
static const uint8_t INFLOW_INLINE_FORMAT_ITALIC = 2;
static const uint8_t INFLOW_INLINE_FORMAT_STRIKETHROUGH = 3;

typedef uint64_t InflowHTMLExportIssues;
static const InflowHTMLExportIssues INFLOW_HTML_EXPORT_ISSUE_IMAGE = UINT64_C(1) << 0;
static const InflowHTMLExportIssues INFLOW_HTML_EXPORT_ISSUE_FORMULA = UINT64_C(1) << 1;
static const InflowHTMLExportIssues INFLOW_HTML_EXPORT_ISSUE_MERMAID = UINT64_C(1) << 2;
static const InflowHTMLExportIssues INFLOW_HTML_EXPORT_ISSUE_LOCAL_LINK = UINT64_C(1) << 3;
static const InflowHTMLExportIssues INFLOW_HTML_EXPORT_ISSUE_UNSAFE_LINK = UINT64_C(1) << 4;

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

typedef struct InflowHeading {
    uint8_t level;
    /// Start/end are end-exclusive UTF-8 byte offsets into the input passed to
    /// inflow_document_analyze.
    uintptr_t source_start;
    uintptr_t source_end;
    /// Start/length are UTF-8 byte offsets into heading_text_utf8 in the same
    /// InflowAnalysisResult.
    uintptr_t title_start;
    uintptr_t title_length;
} InflowHeading;

typedef struct InflowOwnedHeadings {
    InflowHeading *data;
    uintptr_t length;
} InflowOwnedHeadings;

typedef struct InflowSearchMatch {
    /// End-exclusive UTF-8 byte offsets into the source passed to
    /// inflow_document_search. Both ends align with extended grapheme
    /// boundaries in that source.
    uintptr_t source_start;
    uintptr_t source_end;
} InflowSearchMatch;

typedef struct InflowOwnedSearchMatches {
    InflowSearchMatch *data;
    uintptr_t length;
} InflowOwnedSearchMatches;

typedef struct InflowAnalysisResult {
    InflowStatus status;
    InflowOwnedHeadings headings;
    InflowOwnedBytes heading_text_utf8;
    uint64_t word_count;
    uint64_t character_count_with_spaces;
    uint64_t character_count_without_spaces;
} InflowAnalysisResult;

typedef struct InflowSearchResult {
    InflowStatus status;
    InflowOwnedSearchMatches matches;
} InflowSearchResult;

typedef struct InflowHTMLExportResult {
    InflowStatus status;
    InflowOwnedBytes html;
    InflowHTMLExportIssues blocking_issues;
} InflowHTMLExportResult;

typedef struct InflowMarkdownEditResult {
    InflowStatus status;
    InflowOwnedBytes replacement;
    uintptr_t replace_start;
    uintptr_t replace_end;
    uintptr_t selection_start;
    uintptr_t selection_end;
} InflowMarkdownEditResult;

#if UINTPTR_MAX == UINT64_MAX
#if defined(__cplusplus)
static_assert(sizeof(InflowHeading) == 40, "InflowHeading ABI layout changed");
static_assert(sizeof(InflowAnalysisResult) == 64, "InflowAnalysisResult ABI layout changed");
static_assert(sizeof(InflowSearchMatch) == 16, "InflowSearchMatch ABI layout changed");
static_assert(sizeof(InflowSearchResult) == 24, "InflowSearchResult ABI layout changed");
static_assert(sizeof(InflowHTMLExportResult) == 32, "InflowHTMLExportResult ABI layout changed");
static_assert(sizeof(InflowMarkdownEditResult) == 56, "InflowMarkdownEditResult ABI layout changed");
#else
_Static_assert(sizeof(InflowHeading) == 40, "InflowHeading ABI layout changed");
_Static_assert(sizeof(InflowAnalysisResult) == 64, "InflowAnalysisResult ABI layout changed");
_Static_assert(sizeof(InflowSearchMatch) == 16, "InflowSearchMatch ABI layout changed");
_Static_assert(sizeof(InflowSearchResult) == 24, "InflowSearchResult ABI layout changed");
_Static_assert(sizeof(InflowHTMLExportResult) == 32, "InflowHTMLExportResult ABI layout changed");
_Static_assert(sizeof(InflowMarkdownEditResult) == 56, "InflowMarkdownEditResult ABI layout changed");
#endif
#endif

/// Compatible major version of the stable C ABI implemented by the linked
/// Inflow core. Additive functions and trailing-independent structs do not
/// change this value; incompatible ownership or layout changes do.
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

/// Exports an immutable UTF-8 Markdown snapshot as one self-contained HTML
/// document. The result never references local resources or runtime scripts.
/// Unsupported images, formulas, Mermaid blocks, local links and unsafe link
/// schemes are reported through blocking_issues and return no HTML. Successful
/// output is at most 100 MiB. Returned bytes must be released with
/// inflow_owned_bytes_free.
InflowHTMLExportResult inflow_markdown_export_html(
    const uint8_t *utf8,
    uintptr_t length
);

/// Plans a single inline Markdown edit without modifying the source. Selection
/// and returned ranges use end-exclusive UTF-8 byte offsets aligned to complete
/// extended graphemes. A complete wrapper is removed; plain selected content
/// is wrapped; an empty selection gets an editable template. Partial or mixed
/// target formatting returns INFLOW_STATUS_AMBIGUOUS_FORMAT and no replacement.
/// Returned replacement bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_format_inline(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end,
    uint8_t inline_format
);

/// Plans a heading edit over complete source lines without modifying the
/// source. `heading_level` must be 1...6. Mixed levels are unified; if every
/// nonblank selected line already has the requested level, heading markers are
/// removed. Setext headings are consumed as one block and normalized to ATX
/// when changing level. Selection and returned ranges use end-exclusive UTF-8
/// byte offsets aligned to complete extended graphemes. Returned replacement
/// bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_format_heading(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end,
    uint8_t heading_level
);

/// Extracts heading source ranges and text statistics from UTF-8 Markdown. The
/// returned arrays belong to Inflow and must be released with their matching
/// free functions.
InflowAnalysisResult inflow_document_analyze(
    const uint8_t *utf8,
    uintptr_t length
);

/// Finds non-overlapping literal matches in UTF-8 Markdown source order.
/// case_sensitive must be 0 or 1. Case-insensitive matching uses
/// locale-independent Unicode folding. Only complete extended grapheme ranges
/// are returned, so a match never splits a combining sequence or ZWJ emoji.
/// The returned array belongs to Inflow and must be released with
/// inflow_owned_search_matches_free.
InflowSearchResult inflow_document_search(
    const uint8_t *utf8,
    uintptr_t length,
    const uint8_t *query_utf8,
    uintptr_t query_length,
    uint8_t case_sensitive
);

/// Releases an unchanged pointer and length returned by Inflow.
void inflow_owned_bytes_free(uint8_t *data, uintptr_t length);

/// Releases an unchanged heading pointer and length returned by Inflow.
void inflow_owned_headings_free(InflowHeading *data, uintptr_t length);

/// Releases an unchanged search-match pointer and length returned by Inflow.
void inflow_owned_search_matches_free(
    InflowSearchMatch *data,
    uintptr_t length
);

#ifdef __cplusplus
}
#endif

#endif
