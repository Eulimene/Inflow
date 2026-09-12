//! Parsed Markdown destinations used by platform relocation preflight.

use std::ops::Range;

use pulldown_cmark::{Event, Tag};
use serde::Serialize;

use crate::markdown_ir::{DocumentIr, dialect_options};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReferenceKind {
    Link,
    Image,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MarkdownReference {
    pub kind: ReferenceKind,
    pub target: String,
    /// End-exclusive UTF-8 byte range of the complete reference in source.
    pub source_range: Range<usize>,
}

pub fn references(markdown: &str) -> Vec<MarkdownReference> {
    let document = DocumentIr::parse(markdown, dialect_options(true));
    references_from_document(&document)
}

pub fn references_from_document(document: &DocumentIr) -> Vec<MarkdownReference> {
    document
        .events()
        .iter()
        .filter_map(|located| match &located.event {
            Event::Start(Tag::Link { dest_url, .. }) => Some(MarkdownReference {
                kind: ReferenceKind::Link,
                target: dest_url.to_string(),
                source_range: located.source_range.clone(),
            }),
            Event::Start(Tag::Image { dest_url, .. }) => Some(MarkdownReference {
                kind: ReferenceKind::Image,
                target: dest_url.to_string(),
                source_range: located.source_range.clone(),
            }),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_inline_reference_and_autolink_destinations_in_source_order() {
        assert_eq!(
            references(
                "[local](../notes/\u{4e00}.md#part) ![photo](assets/a%20b.png)\n\n<https://example.com>"
            ),
            vec![
                MarkdownReference {
                    kind: ReferenceKind::Link,
                    target: "../notes/\u{4e00}.md#part".into(),
                    source_range: 0..29,
                },
                MarkdownReference {
                    kind: ReferenceKind::Image,
                    target: "assets/a%20b.png".into(),
                    source_range: 30..56,
                },
                MarkdownReference {
                    kind: ReferenceKind::Link,
                    target: "https://example.com".into(),
                    source_range: 58..79,
                },
            ]
        );
    }

    #[test]
    fn resolves_reference_definitions_and_ignores_code_and_raw_text() {
        assert_eq!(
            references(
                "[label][id]\n\n![image][photo]\n\n[id]: sibling.md\n[photo]: media/a.png\n\n`[code](ignored.md)`"
            ),
            vec![
                MarkdownReference {
                    kind: ReferenceKind::Link,
                    target: "sibling.md".into(),
                    source_range: 0..11,
                },
                MarkdownReference {
                    kind: ReferenceKind::Image,
                    target: "media/a.png".into(),
                    source_range: 13..28,
                },
            ]
        );
    }

    #[test]
    fn returns_exact_ranges_for_duplicate_unicode_image_references() {
        let markdown = "前 ![图](assets/图.png) 中 ![图](assets/图.png) 后";
        let references = references(markdown);

        assert_eq!(references.len(), 2);
        assert_eq!(
            &markdown[references[0].source_range.clone()],
            "![图](assets/图.png)"
        );
        assert_eq!(
            &markdown[references[1].source_range.clone()],
            "![图](assets/图.png)"
        );
        assert!(references[0].source_range.end < references[1].source_range.start);
    }
}
