//! Parsed Markdown destinations used by platform relocation preflight.

use pulldown_cmark::{Event, Parser, Tag};

use crate::render;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReferenceKind {
    Link,
    Image,
}

#[derive(Debug, Eq, PartialEq)]
pub struct MarkdownReference {
    pub kind: ReferenceKind,
    pub target: String,
}

pub fn references(markdown: &str) -> Vec<MarkdownReference> {
    Parser::new_ext(markdown, render::options())
        .filter_map(|event| match event {
            Event::Start(Tag::Link { dest_url, .. }) => Some(MarkdownReference {
                kind: ReferenceKind::Link,
                target: dest_url.into_string(),
            }),
            Event::Start(Tag::Image { dest_url, .. }) => Some(MarkdownReference {
                kind: ReferenceKind::Image,
                target: dest_url.into_string(),
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
                },
                MarkdownReference {
                    kind: ReferenceKind::Image,
                    target: "assets/a%20b.png".into(),
                },
                MarkdownReference {
                    kind: ReferenceKind::Link,
                    target: "https://example.com".into(),
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
                },
                MarkdownReference {
                    kind: ReferenceKind::Image,
                    target: "media/a.png".into(),
                },
            ]
        );
    }
}
