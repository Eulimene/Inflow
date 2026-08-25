//! Self-contained HTML export for immutable Markdown snapshots.

use pulldown_cmark::{Event, Parser, Tag};

use crate::render;

#[allow(dead_code)] // Reserved by the stable v1 C ABI for older core binaries.
pub const ISSUE_IMAGE: u64 = 1 << 0;
#[allow(dead_code)] // Reserved by the stable v1 C ABI for older core binaries.
pub const ISSUE_FORMULA: u64 = 1 << 1;
#[allow(dead_code)] // Reserved by the stable v1 C ABI for older core binaries.
pub const ISSUE_MERMAID: u64 = 1 << 2;
pub const ISSUE_LOCAL_LINK: u64 = 1 << 3;
pub const ISSUE_UNSAFE_LINK: u64 = 1 << 4;

pub const MAX_HTML_BYTES: usize = 100 * 1024 * 1024;

#[derive(Debug, Eq, PartialEq)]
pub enum ExportError {
    UnsupportedContent(u64),
    OutputTooLarge,
}

pub fn html_document(markdown: &str) -> Result<Vec<u8>, ExportError> {
    html_document_with_limit(markdown, MAX_HTML_BYTES)
}

fn html_document_with_limit(markdown: &str, maximum_bytes: usize) -> Result<Vec<u8>, ExportError> {
    let issues = blocking_issues(markdown);
    if issues != 0 {
        return Err(ExportError::UnsupportedContent(issues));
    }

    let fragment = render::html_fragment(markdown);
    let document = format!("{DOCUMENT_PREFIX}{fragment}{DOCUMENT_SUFFIX}");
    if document.len() > maximum_bytes {
        return Err(ExportError::OutputTooLarge);
    }
    Ok(document.into_bytes())
}

pub fn blocking_issues(markdown: &str) -> u64 {
    let mut issues = 0;

    for event in Parser::new_ext(markdown, render::options()) {
        if let Event::Start(Tag::Link { dest_url, .. }) = event {
            issues |= link_issue(dest_url.as_ref());
        }
    }

    issues
}

fn link_issue(destination: &str) -> u64 {
    let destination = destination.trim_matches(char::is_whitespace);
    if destination.is_empty() || destination.starts_with('#') {
        return 0;
    }

    let scheme_end = destination.find(':');
    let path_marker = destination
        .find(['/', '?', '#'])
        .unwrap_or(destination.len());
    if let Some(scheme_end) = scheme_end.filter(|position| *position < path_marker) {
        return match destination[..scheme_end].to_ascii_lowercase().as_str() {
            "http" | "https" | "mailto" => 0,
            "file" => ISSUE_LOCAL_LINK,
            _ => ISSUE_UNSAFE_LINK,
        };
    }

    ISSUE_LOCAL_LINK
}

const DOCUMENT_PREFIX: &str = r#"<!doctype html>
<html lang="zh-Hans">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="generator" content="Inflow">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; media-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; script-src 'none'; form-action 'none'; base-uri 'none'">
  <title>Markdown 文档</title>
  <style>
    :root { color-scheme: light dark; font: 17px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; }
    * { box-sizing: border-box; }
    body { max-width: 760px; margin: 0 auto; padding: 32px 36px 72px; color: #24292f; background: #fff; overflow-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.28; margin: 1.45em 0 .55em; }
    h1, h2 { border-bottom: 1px solid #d8dee4; padding-bottom: .28em; }
    h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
    a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
    blockquote { margin: 1em 0; padding: .15em 1em; color: #57606a; border-left: 4px solid #d0d7de; }
    code { font: .88em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; background: #afb8c133; border-radius: 5px; padding: .16em .34em; }
    pre { overflow: auto; padding: 16px; background: #f6f8fa; border-radius: 8px; }
    pre code { padding: 0; background: transparent; }
    table { width: 100%; border-collapse: collapse; display: block; overflow-x: auto; }
    th, td { border: 1px solid #d0d7de; padding: 7px 12px; }
    tr:nth-child(even) { background: #f6f8fa; }
    hr { height: 1px; border: 0; background: #d8dee4; margin: 2em 0; }
    img { display: block; max-width: 100%; height: auto; margin: 1em 0; }
    math { font-family: STIX Two Math, STIXGeneral, serif; }
    math[display="block"] { display: block; max-width: 100%; overflow-x: auto; margin: 1.2em 0; text-align: center; }
    .mermaid-diagram { margin: 1.4em 0; overflow-x: auto; }
    .mermaid-diagram svg { min-width: 420px; width: 100%; height: auto; color: currentColor; }
    .mermaid-diagram .node rect { fill: #f6f8fa; stroke: #57606a; stroke-width: 1.5; }
    .mermaid-diagram text { fill: currentColor; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
    .mermaid-error { border: 1px solid #d4a72c; border-radius: 8px; padding: 12px 14px; color: #9a6700; }
    .task-list-item { list-style: none; } input[type="checkbox"] { margin: 0 .45em 0 -1.35em; }
    @media (prefers-color-scheme: dark) {
      body { color: #e6edf3; background: #0d1117; }
      h1, h2, th, td { border-color: #30363d; }
      a { color: #58a6ff; }
      blockquote { color: #8b949e; border-color: #3b434b; }
      pre, tr:nth-child(even) { background: #161b22; }
      code { background: #6e768166; }
      hr { background: #30363d; }
      .mermaid-diagram .node rect { fill: #161b22; stroke: #8b949e; }
      .mermaid-error { color: #d29922; border-color: #9e6a03; }
    }
  </style>
</head>
<body>
<main>
"#;

const DOCUMENT_SUFFIX: &str = "</main>\n</body>\n</html>\n";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exports_complete_resource_independent_html() {
        let markdown = concat!(
            "# 标题\n\n",
            "**Bold** and ~~old~~. [Site](https://example.com).\n\n",
            "- [x] Done\n\n",
            "| A | B |\n| - | - |\n| 1 | 2 |\n\n",
            "Footnote[^1]\n\n[^1]: Detail\n",
        );
        let bytes = html_document(markdown).expect("supported Markdown exports");
        let html = String::from_utf8(bytes).expect("export is UTF-8");

        assert!(html.starts_with("<!doctype html>"));
        assert!(html.contains("<h1>标题</h1>"));
        assert!(html.contains("<table>"));
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("href=\"https://example.com\""));
        assert!(html.contains("default-src 'none'"));
        assert!(html.contains("script-src 'none'"));
        assert!(html.contains("connect-src 'none'"));
        assert!(!html.contains("<script"));
        assert!(!html.contains("http://cdn"));
        assert!(html.ends_with("</html>\n"));
    }

    #[test]
    fn escapes_raw_html_in_export() {
        let html = String::from_utf8(html_document("<script>alert(1)</script>").unwrap()).unwrap();

        assert!(!html.contains("<script>alert"));
        assert!(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"));
    }

    #[test]
    fn reports_every_blocking_content_category() {
        let markdown = concat!(
            "![local](image.png)\n\n",
            "[local](../notes.md)\n\n",
            "[unsafe](javascript:alert(1))\n",
        );

        assert_eq!(
            blocking_issues(markdown),
            ISSUE_LOCAL_LINK | ISSUE_UNSAFE_LINK
        );
        assert_eq!(
            html_document(markdown),
            Err(ExportError::UnsupportedContent(blocking_issues(markdown)))
        );
    }

    #[test]
    fn leaves_images_as_inert_slots_for_platform_export_resolution() {
        let html = String::from_utf8(
            html_document("![photo](assets/photo.png)").expect("platform resolves image"),
        )
        .expect("export is UTF-8");
        assert!(html.contains("class=\"inflow-image-slot\""));
        assert!(!html.contains("src=\"assets/photo.png\""));
    }

    #[test]
    fn exports_inline_and_display_formula_as_self_contained_mathml() {
        let html = String::from_utf8(
            html_document("Inline $x_1^2$\n\n$$\\frac{a}{b}$$\n").expect("formula is supported"),
        )
        .expect("export is UTF-8");

        assert!(html.contains("<math xmlns=\"http://www.w3.org/1998/Math/MathML\""));
        assert!(html.contains("<msubsup>"));
        assert!(html.contains("<mfrac>"));
        assert!(!html.contains("<script"));
        assert!(!html.contains("https://"));
    }

    #[test]
    fn permits_external_and_same_document_links() {
        let markdown = concat!(
            "[web](https://example.com) ",
            "[mail](mailto:hello@example.com) ",
            "[heading](#section) ",
            "[top]()"
        );

        assert_eq!(blocking_issues(markdown), 0);
    }

    #[test]
    fn treats_file_and_unknown_schemes_as_blocking() {
        assert_eq!(
            blocking_issues("[file](file:///tmp/private.md)"),
            ISSUE_LOCAL_LINK
        );
        assert_eq!(
            blocking_issues("[absolute](/Users/me/private.md)"),
            ISSUE_LOCAL_LINK
        );
        assert_eq!(
            blocking_issues("[custom](notes-app:secret)"),
            ISSUE_UNSAFE_LINK
        );
    }

    #[test]
    fn mermaid_language_matching_is_case_insensitive() {
        let html = String::from_utf8(
            html_document("```MerMaid\ngraph LR\nA --> B\n```").expect("Mermaid is self-contained"),
        )
        .expect("export is UTF-8");
        assert!(html.contains("class=\"mermaid-diagram\""));
        assert_eq!(blocking_issues("```rust\nlet mermaid = true;\n```"), 0);
    }

    #[test]
    fn rejects_output_larger_than_limit_before_returning_bytes() {
        let minimum = DOCUMENT_PREFIX.len() + DOCUMENT_SUFFIX.len();
        assert_eq!(
            html_document_with_limit("", minimum - 1),
            Err(ExportError::OutputTooLarge)
        );
        assert!(html_document_with_limit("", minimum).is_ok());
    }
}
