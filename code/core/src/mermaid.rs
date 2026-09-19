//! Diagram requests prepared by `CommonMark`; JavaScript owns parsing and rendering.
//! The historical Mermaid field names remain wire-compatible for native clients.

use crate::markdown_ir::DocumentIr;
#[cfg(test)]
use crate::render;
#[cfg(test)]
use pulldown_cmark::Parser;
use pulldown_cmark::{CodeBlockKind, Event, Tag, TagEnd};
use std::collections::HashMap;
use std::ops::Range;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MermaidError {
    #[cfg(test)]
    UnsupportedType,
    InvalidSyntax,
}

pub(crate) fn diagram_language(info: &str) -> Option<&'static str> {
    match info
        .split_ascii_whitespace()
        .next()?
        .to_ascii_lowercase()
        .as_str()
    {
        "mermaid" => Some("mermaid"),
        "flow" => Some("flow"),
        "sequence" => Some("sequence"),
        _ => None,
    }
}

pub(crate) struct MermaidRenderBatch {
    by_source_range: HashMap<Range<usize>, Result<String, MermaidError>>,
}
impl MermaidRenderBatch {
    pub(crate) fn render(document: &DocumentIr) -> Self {
        let mut by_source_range = HashMap::new();
        for (index, located) in document.events().iter().enumerate() {
            let Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info))) = &located.event else {
                continue;
            };
            let Some(language) = diagram_language(info) else {
                continue;
            };
            let mut body = String::new();
            for event in &document.events()[index + 1..] {
                match &event.event {
                    Event::End(TagEnd::CodeBlock) => break,
                    Event::Text(text) | Event::Code(text) => body.push_str(text),
                    _ => {}
                }
            }
            by_source_range.insert(
                located.source_range.clone(),
                Ok(placeholder(language, &body)),
            );
        }
        Self { by_source_range }
    }
    pub(crate) fn result(&self, range: &Range<usize>) -> Option<&Result<String, MermaidError>> {
        self.by_source_range.get(range)
    }
}

#[cfg(test)]
fn source_from_markdown(markdown: &str) -> Result<(&'static str, String), MermaidError> {
    let mut events = Parser::new_ext(markdown, render::options());
    let Some(Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info)))) = events.next() else {
        return Err(MermaidError::InvalidSyntax);
    };
    let language = diagram_language(&info).ok_or(MermaidError::UnsupportedType)?;
    let mut source = String::new();
    for event in events {
        match event {
            Event::Text(text) | Event::Code(text) => source.push_str(&text),
            Event::End(TagEnd::CodeBlock) => break,
            _ => {}
        }
    }
    Ok((language, source))
}

pub(crate) fn placeholder(language: &str, source: &str) -> String {
    format!(
        "<figure class=\"mermaid-diagram\" data-inflow-render=\"{language}\" aria-label=\"图表\"><pre><code>{}</code></pre></figure>",
        escape(source)
    )
}

pub fn fallback(source: &str, _error: &MermaidError) -> String {
    format!(
        "<figure class=\"mermaid-error\"><figcaption>无法呈现这个图表，原内容已保留。</figcaption><pre><code>{}</code></pre></figure>",
        escape(source)
    )
}
pub fn fallback_at(source: &str, error: &MermaidError, _range: Range<usize>) -> String {
    fallback(source, error)
}
fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markdown_ir::dialect_options;
    #[test]
    fn routes_three_fence_languages_without_interpreting_javascript() {
        for language in ["mermaid", "flow", "sequence", "MERMAID"] {
            let text = format!("~~~ {language}\n<script>alert(1)</script>\n~~~\n");
            let document = DocumentIr::parse(&text, dialect_options(true));
            let batch = MermaidRenderBatch::render(&document);
            let range = &document.events()[0].source_range;
            let html = batch.result(range).unwrap().as_ref().unwrap();
            assert!(html.contains("data-inflow-render="));
            assert!(html.contains("&lt;script&gt;"));
            assert!(!html.contains("<script>"));
        }
        assert_eq!(diagram_language("rust"), None);
    }
    #[test]
    fn preserves_diagram_syntax_for_the_selected_js_engine() {
        let (language, body) = source_from_markdown("```sequence\n甲->乙: 你好\n```\n").unwrap();
        assert_eq!(language, "sequence");
        assert_eq!(body, "甲->乙: 你好\n");
    }
}
