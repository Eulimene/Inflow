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

typedef uint32_t InflowRenderOptions;
static const InflowRenderOptions INFLOW_RENDER_OPTION_MATH = UINT32_C(1) << 0;
static const InflowRenderOptions INFLOW_RENDER_OPTION_MERMAID = UINT32_C(1) << 1;
static const InflowRenderOptions INFLOW_RENDER_OPTIONS_DEFAULT =
    INFLOW_RENDER_OPTION_MATH | INFLOW_RENDER_OPTION_MERMAID;

static const uint8_t INFLOW_INLINE_FORMAT_BOLD = 1;
static const uint8_t INFLOW_INLINE_FORMAT_ITALIC = 2;
static const uint8_t INFLOW_INLINE_FORMAT_STRIKETHROUGH = 3;

static const uint8_t INFLOW_LIST_FORMAT_UNORDERED = 1;
static const uint8_t INFLOW_LIST_FORMAT_ORDERED = 2;
static const uint8_t INFLOW_LIST_FORMAT_TASK = 3;

static const uint8_t INFLOW_REFERENCE_KIND_LINK = 1;
static const uint8_t INFLOW_REFERENCE_KIND_IMAGE = 2;

static const uint8_t INFLOW_HIGHLIGHT_KIND_HEADING = 1;
static const uint8_t INFLOW_HIGHLIGHT_KIND_EMPHASIS = 2;
static const uint8_t INFLOW_HIGHLIGHT_KIND_STRONG = 3;
static const uint8_t INFLOW_HIGHLIGHT_KIND_STRIKETHROUGH = 4;
static const uint8_t INFLOW_HIGHLIGHT_KIND_CODE = 5;
static const uint8_t INFLOW_HIGHLIGHT_KIND_LINK = 6;
static const uint8_t INFLOW_HIGHLIGHT_KIND_IMAGE = 7;
static const uint8_t INFLOW_HIGHLIGHT_KIND_BLOCK_QUOTE = 8;
static const uint8_t INFLOW_HIGHLIGHT_KIND_LIST = 9;
static const uint8_t INFLOW_HIGHLIGHT_KIND_TABLE = 10;
static const uint8_t INFLOW_HIGHLIGHT_KIND_FOOTNOTE = 11;
static const uint8_t INFLOW_HIGHLIGHT_KIND_MATH = 12;
static const uint8_t INFLOW_HIGHLIGHT_KIND_RAW = 13;
static const uint8_t INFLOW_HIGHLIGHT_KIND_RULE = 14;

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

typedef struct InflowDocumentOpenResult {
    InflowStatus status;
    InflowOwnedBytes utf8;
    uint8_t has_utf8_bom;
    uint8_t line_ending;
    uint8_t requires_line_ending_choice;
} InflowDocumentOpenResult;

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

typedef struct InflowReference {
    uint8_t kind;
    /// Start/length are UTF-8 byte offsets into target_text_utf8 in the same
    /// InflowReferenceResult.
    uintptr_t target_start;
    uintptr_t target_length;
} InflowReference;

typedef struct InflowOwnedReferences {
    InflowReference *data;
    uintptr_t length;
} InflowOwnedReferences;

typedef struct InflowHighlightSpan {
    uint8_t kind;
    /// Start/end are end-exclusive UTF-8 byte offsets into the input passed to
    /// inflow_markdown_highlight. Ranges may overlap for nested Markdown.
    uintptr_t source_start;
    uintptr_t source_end;
} InflowHighlightSpan;

typedef struct InflowOwnedHighlightSpans {
    InflowHighlightSpan *data;
    uintptr_t length;
} InflowOwnedHighlightSpans;

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

typedef struct InflowReferenceResult {
    InflowStatus status;
    InflowOwnedReferences references;
    InflowOwnedBytes target_text_utf8;
} InflowReferenceResult;

typedef struct InflowHighlightResult {
    InflowStatus status;
    InflowOwnedHighlightSpans spans;
} InflowHighlightResult;

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
static_assert(sizeof(InflowDocumentOpenResult) == 32, "InflowDocumentOpenResult ABI layout changed");
static_assert(sizeof(InflowAnalysisResult) == 64, "InflowAnalysisResult ABI layout changed");
static_assert(sizeof(InflowSearchMatch) == 16, "InflowSearchMatch ABI layout changed");
static_assert(sizeof(InflowSearchResult) == 24, "InflowSearchResult ABI layout changed");
static_assert(sizeof(InflowReference) == 24, "InflowReference ABI layout changed");
static_assert(sizeof(InflowReferenceResult) == 40, "InflowReferenceResult ABI layout changed");
static_assert(sizeof(InflowHighlightSpan) == 24, "InflowHighlightSpan ABI layout changed");
static_assert(sizeof(InflowHighlightResult) == 24, "InflowHighlightResult ABI layout changed");
static_assert(sizeof(InflowHTMLExportResult) == 32, "InflowHTMLExportResult ABI layout changed");
static_assert(sizeof(InflowMarkdownEditResult) == 56, "InflowMarkdownEditResult ABI layout changed");
#else
_Static_assert(sizeof(InflowHeading) == 40, "InflowHeading ABI layout changed");
_Static_assert(sizeof(InflowDocumentOpenResult) == 32, "InflowDocumentOpenResult ABI layout changed");
_Static_assert(sizeof(InflowAnalysisResult) == 64, "InflowAnalysisResult ABI layout changed");
_Static_assert(sizeof(InflowSearchMatch) == 16, "InflowSearchMatch ABI layout changed");
_Static_assert(sizeof(InflowSearchResult) == 24, "InflowSearchResult ABI layout changed");
_Static_assert(sizeof(InflowReference) == 24, "InflowReference ABI layout changed");
_Static_assert(sizeof(InflowReferenceResult) == 40, "InflowReferenceResult ABI layout changed");
_Static_assert(sizeof(InflowHighlightSpan) == 24, "InflowHighlightSpan ABI layout changed");
_Static_assert(sizeof(InflowHighlightResult) == 24, "InflowHighlightResult ABI layout changed");
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

/// Opens UTF-8 Markdown and normalizes all in-memory line endings to LF.
/// Mixed LF/CRLF or bare CR remains readable, but
/// requires_line_ending_choice is set and the caller must prevent writeback
/// until the user chooses LF or CRLF. Returned bytes belong to Inflow and must
/// be released with inflow_owned_bytes_free.
InflowDocumentOpenResult inflow_document_open(const uint8_t *bytes, uintptr_t length);

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

/// Renders UTF-8 Markdown with explicit presentation options. Unknown option
/// bits return INFLOW_STATUS_INVALID_ARGUMENT and no bytes. With math disabled,
/// formula delimiters remain ordinary text; with Mermaid disabled, Mermaid
/// fences remain ordinary code blocks. Returned bytes belong to Inflow.
InflowEncodeResult inflow_markdown_render_html_with_options(
    const uint8_t *utf8,
    uintptr_t length,
    InflowRenderOptions options
);

/// Exports an immutable UTF-8 Markdown snapshot as one self-contained HTML
/// document. The result never references local resources or runtime scripts.
/// Unsupported images, local links and unsafe link schemes are reported
/// through blocking_issues and return no HTML. Supported formulas and Mermaid
/// blocks are emitted as self-contained MathML and SVG. Successful output is
/// at most 100 MiB. Returned bytes must be released with inflow_owned_bytes_free.
InflowHTMLExportResult inflow_markdown_export_html(
    const uint8_t *utf8,
    uintptr_t length
);

/// Exports a snapshot with the same explicit presentation options as preview.
/// Unknown option bits return INFLOW_STATUS_INVALID_ARGUMENT and no bytes.
InflowHTMLExportResult inflow_markdown_export_html_with_options(
    const uint8_t *utf8,
    uintptr_t length,
    InflowRenderOptions options
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

/// Plans a single inline-code edit without modifying the source. Complete code
/// spans are unwrapped; ordinary selections are wrapped with a backtick run
/// longer than any run inside the content. Edge spaces and backticks receive
/// CommonMark padding so the selected source is preserved. Empty selections
/// receive an editable template. Partial existing spans, multiline selections
/// and whitespace-only selections return INFLOW_STATUS_AMBIGUOUS_FORMAT.
/// Returned replacement bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_format_inline_code(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Plans a fenced-code-block edit over complete source lines. The backtick
/// fence is at least three bytes and one byte longer than the longest run in
/// the selected content. A complete parsed fence or its complete content is
/// unwrapped; an empty selection receives an editable block template. Partial
/// existing fences return INFLOW_STATUS_AMBIGUOUS_FORMAT. Selection and
/// returned ranges use end-exclusive UTF-8 byte offsets aligned to complete
/// extended graphemes. Returned replacement bytes must be released with
/// inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_format_code_block(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Removes supported Markdown format markers fully contained by one non-empty
/// selection. Supported markers are emphasis, strong, strikethrough, inline
/// and fenced code, ATX/Setext headings, block quotes and all list variants.
/// Links, literal punctuation and code contents remain unchanged. A selection
/// without an active complete marker returns INFLOW_STATUS_AMBIGUOUS_FORMAT.
/// Returned replacement bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_clear_format(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Plans one inline Markdown link insertion. Plain selected source becomes the
/// label; an empty selection receives an editable label placeholder. Selecting
/// a complete existing link or its complete label updates the destination
/// without nesting. Partial existing links and destinations containing control
/// bytes, angle brackets or backslashes are rejected without a replacement.
/// Both source and destination are UTF-8. Selection and returned ranges use
/// end-exclusive UTF-8 byte offsets aligned to complete extended graphemes.
/// Returned replacement bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_insert_link(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end,
    const uint8_t *destination_utf8,
    uintptr_t destination_length
);

/// Plans one standard Markdown image insertion. Plain selected source becomes
/// escaped alternative text; an empty selection uses and selects the supplied
/// default alternative. Existing link/image intersections, multiline labels,
/// empty alternatives and unsafe destinations are rejected without mutation.
/// All strings are UTF-8. Selection and returned ranges use end-exclusive UTF-8
/// byte offsets aligned to complete extended graphemes. Returned replacement
/// bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_insert_image(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end,
    const uint8_t *destination_utf8,
    uintptr_t destination_length,
    const uint8_t *alternative_utf8,
    uintptr_t alternative_length
);

/// Plans a 3-column by 3-row Markdown table insertion (one header and two data
/// rows). Selected source is escaped into the first header; an empty selection
/// receives a default header, which remains selected for immediate editing.
/// Newlines become safe `<br>` cell content and pipes/backslashes are escaped.
/// Existing table intersections are rejected without modifying the source.
/// Selection and returned ranges use end-exclusive UTF-8 byte offsets aligned
/// to complete extended graphemes. Returned replacement bytes must be released
/// with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_insert_table(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Plans one CommonMark horizontal rule after the current selection without
/// removing selected source. The edit adds enough surrounding line endings to
/// keep `---` from becoming a Setext heading, and leaves the caret on an empty
/// line after the rule. Selection and returned ranges use end-exclusive UTF-8
/// byte offsets aligned to complete extended graphemes. Returned replacement
/// bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_insert_horizontal_rule(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Plans one Markdown footnote after the current selection. The selected
/// anchor source remains unchanged, a unique `note-N` reference is inserted at
/// its end, and a matching definition is appended after the document with its
/// placeholder selected. Existing parsed footnote names are never reused.
/// Selection and returned ranges use end-exclusive UTF-8 byte offsets aligned
/// to complete extended graphemes. Returned replacement bytes must be released
/// with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_insert_footnote(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Plans a formula insertion. A non-empty single-line selection becomes an
/// inline `$...$` formula; an empty or multiline selection becomes a `$$`
/// display block whose delimiters occupy their own lines. Existing formula
/// intersections and selected dollar delimiters are rejected without changing
/// source. Selection and returned ranges use end-exclusive UTF-8 byte offsets
/// aligned to complete extended graphemes. Returned replacement bytes must be
/// released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_insert_math(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Plans a fenced Mermaid diagram insertion. An empty selection receives an
/// editable flowchart template; selected source must parse as one supported
/// launch-scope flowchart, sequence, class or state diagram. The fence is made
/// longer than every selected backtick run. Existing fenced-code intersections
/// and unsupported syntax are rejected. Selection and returned ranges use
/// end-exclusive UTF-8 byte offsets aligned to complete extended graphemes.
/// Returned replacement bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_insert_mermaid(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
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

/// Plans adding or removing one block quote level over complete source lines.
/// Existing contiguous quote blocks are treated as a unit so a marker-only
/// change cannot leave CommonMark lazy continuation semantics unchanged. Empty
/// lines and nested levels are preserved. Selection and returned ranges use
/// end-exclusive UTF-8 byte offsets aligned to complete extended graphemes.
/// Returned replacement bytes must be released with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_format_block_quote(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end
);

/// Plans an unordered, ordered or task-list edit over complete source lines.
/// Mixed/plain lines are normalized to the requested list type; if every
/// actionable line already has that semantic type, one list marker is removed.
/// Blank lines and indentation are preserved, ordered source uses stable `1.`
/// markers, and task completion is retained. Candidate edits must parse as real
/// Markdown list items, so marker-like text inside code fences is rejected.
/// Selection and returned ranges use end-exclusive UTF-8 byte offsets aligned
/// to complete extended graphemes. Returned replacement bytes must be released
/// with inflow_owned_bytes_free.
InflowMarkdownEditResult inflow_markdown_format_list(
    const uint8_t *utf8,
    uintptr_t length,
    uintptr_t selection_start,
    uintptr_t selection_end,
    uint8_t list_format
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

/// Extracts parsed Markdown link and image destinations in source order.
/// Reference definitions are resolved and literal code is ignored. Each
/// target uses UTF-8 offsets into target_text_utf8. Both returned allocations
/// belong to Inflow and must be released with their matching free functions.
InflowReferenceResult inflow_document_references(
    const uint8_t *utf8,
    uintptr_t length
);

/// Returns semantic syntax spans for UTF-8 Markdown. Spans use end-exclusive
/// byte offsets into the exact source and can overlap for nested constructs.
/// The returned array belongs to Inflow and must be released with
/// inflow_owned_highlight_spans_free.
InflowHighlightResult inflow_markdown_highlight(
    const uint8_t *utf8,
    uintptr_t length
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

/// Releases an unchanged Markdown-reference pointer and length from Inflow.
void inflow_owned_references_free(
    InflowReference *data,
    uintptr_t length
);

/// Releases an unchanged syntax-span pointer and length returned by Inflow.
void inflow_owned_highlight_spans_free(
    InflowHighlightSpan *data,
    uintptr_t length
);

#ifdef __cplusplus
}
#endif

#endif
