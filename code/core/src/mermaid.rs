//! Renderer-neutral Mermaid façade used by every document presentation.
//!
//! Markdown extraction, failure semantics and output safety belong to the
//! application core. The concrete open-source renderer lives behind
//! [`MermaidRenderer`] so it can be replaced without changing Render IR, FFI
//! DTOs or platform clients.

use pulldown_cmark::{CodeBlockKind, Event, Parser, Tag, TagEnd};

use crate::{mermaid_rs_adapter::MermaidRsRendererAdapter, render};

#[derive(Debug, Eq, PartialEq)]
pub enum MermaidError {
    UnsupportedType,
    InvalidSyntax,
}

pub(crate) trait MermaidRenderer {
    fn render_svg(&self, source: &str) -> Result<String, MermaidError>;
}

/// Extracts one parser-validated Mermaid fence and renders its body. Keeping
/// fence recognition here ensures export and native instant editing consume
/// the same `CommonMark` event stream.
pub fn svg_from_markdown(markdown: &str) -> Result<String, MermaidError> {
    let mut events = Parser::new_ext(markdown, render::options());
    let Some(Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info)))) = events.next() else {
        return Err(MermaidError::InvalidSyntax);
    };
    if !info
        .split_ascii_whitespace()
        .next()
        .is_some_and(|name| name.eq_ignore_ascii_case("mermaid"))
    {
        return Err(MermaidError::UnsupportedType);
    }
    let mut source = String::new();
    loop {
        match events.next() {
            Some(Event::Text(text) | Event::Code(text)) => source.push_str(&text),
            Some(Event::End(TagEnd::CodeBlock)) => break,
            Some(_) => {}
            None => return Err(MermaidError::InvalidSyntax),
        }
    }
    if events.any(|event| !matches!(event, Event::SoftBreak | Event::HardBreak)) {
        return Err(MermaidError::InvalidSyntax);
    }
    svg(source.trim_end())
}

pub fn svg(source: &str) -> Result<String, MermaidError> {
    render_with(&MermaidRsRendererAdapter, source)
}

fn render_with(renderer: &dyn MermaidRenderer, source: &str) -> Result<String, MermaidError> {
    if source.trim().is_empty() {
        return Err(MermaidError::InvalidSyntax);
    }
    let output = renderer.render_svg(source)?;
    if safe_svg(&output) {
        Ok(format!(
            "<figure class=\"mermaid-diagram\" aria-label=\"Mermaid 图表\">{output}</figure>"
        ))
    } else {
        Err(MermaidError::InvalidSyntax)
    }
}

fn safe_svg(output: &str) -> bool {
    let trimmed = output.trim_start();
    let lower = trimmed.to_ascii_lowercase();
    trimmed.starts_with("<svg")
        && trimmed.trim_end().ends_with("</svg>")
        && !lower.contains("<script")
        && !lower.contains("<foreignobject")
        && !lower.contains("javascript:")
        && !lower.contains("data:text/html")
        && !lower.contains(" onload=")
        && !lower.contains(" onclick=")
}

pub fn fallback(source: &str, error: &MermaidError) -> String {
    fallback_with_attributes(source, error, "", false)
}

pub fn fallback_at(
    source: &str,
    error: &MermaidError,
    source_range: std::ops::Range<usize>,
) -> String {
    fallback_with_attributes(
        source,
        error,
        &format!(
            " data-inflow-source-start=\"{}\" data-inflow-source-end=\"{}\"",
            source_range.start, source_range.end
        ),
        true,
    )
}

fn fallback_with_attributes(
    source: &str,
    error: &MermaidError,
    attributes: &str,
    includes_actions: bool,
) -> String {
    let reason = match error {
        MermaidError::UnsupportedType => "代码块不是 Mermaid 图表。",
        MermaidError::InvalidSyntax => "请检查 Mermaid 图表声明和连接语法。",
    };
    let actions = if includes_actions {
        "<div class=\"mermaid-error-actions\"><button type=\"button\" data-inflow-preview-error-action=\"locate\">定位源文本</button><button type=\"button\" data-inflow-preview-error-action=\"retry\">重试</button></div>"
    } else {
        ""
    };
    format!(
        "<figure class=\"mermaid-error\" role=\"group\" aria-label=\"无法呈现这个图表\"{attributes}><figcaption><strong>无法呈现这个图表</strong><br>{reason}<br>原内容已保留，当前文档的其他内容和其他文档不受影响。</figcaption><pre><code>{}</code></pre>{actions}</figure>",
        escape(source),
    )
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

    struct StubRenderer(Result<&'static str, MermaidError>);

    impl MermaidRenderer for StubRenderer {
        fn render_svg(&self, _source: &str) -> Result<String, MermaidError> {
            self.0
                .as_ref()
                .map(|value| (*value).to_owned())
                .map_err(|error| match error {
                    MermaidError::UnsupportedType => MermaidError::UnsupportedType,
                    MermaidError::InvalidSyntax => MermaidError::InvalidSyntax,
                })
        }
    }

    #[test]
    fn renderer_port_keeps_the_application_core_independent() {
        let output = render_with(
            &StubRenderer(Ok("<svg viewBox=\"0 0 10 10\"></svg>")),
            "flowchart LR\nA-->B",
        )
        .expect("adapter output");
        assert!(output.contains("class=\"mermaid-diagram\""));
        assert!(output.contains("viewBox"));
    }

    #[test]
    fn rejects_active_or_non_svg_adapter_output() {
        for output in [
            "<html></html>",
            "<svg><script>alert(1)</script></svg>",
            "<svg><foreignObject>HTML</foreignObject></svg>",
            "<svg><a href=\"javascript:alert(1)\"></a></svg>",
            "<svg><g onclick=\"alert(1)\"></g></svg>",
        ] {
            assert_eq!(
                render_with(&StubRenderer(Ok(output)), "flowchart LR\nA-->B"),
                Err(MermaidError::InvalidSyntax)
            );
        }
    }

    #[test]
    fn fenced_entry_point_uses_commonmark_fence_parsing() {
        let output = svg_from_markdown("~~~ mermaid\nflowchart LR\nA[开始] --> B[结束]\n~~~\n")
            .expect("validated Mermaid fence");
        assert!(output.contains("开始"));
        assert_eq!(
            svg_from_markdown("```rust\nfn main() {}\n```"),
            Err(MermaidError::UnsupportedType)
        );
    }

    #[test]
    fn open_source_adapter_renders_the_product_cycle_and_service_edges() {
        let source = r#"flowchart LR
    A["接手\n打开或创建自己的文件"] --> B["形成\n持续写作与整理"]
    B --> C["理解\n看见结构与问题"]
    C --> D["验证\n确认内容与呈现"]
    D --> E["交付\n分享、归档或继续流转"]
    E --> A
    F["按需增强\n加入可撤销的专业能力"] -.服务.-> B
    F -.服务.-> C
    F -.服务.-> E"#;

        let output = svg(source).expect("supported upstream Mermaid syntax");

        assert!(output.contains("<svg"));
        assert!(output.contains("viewBox="));
        assert!(output.contains("接手"));
        assert!(output.contains("打开或创建自己的文件"));
        assert!(output.contains("服务"));
        assert!(output.contains("stroke-dasharray"));
        assert!(!output.contains("<script"));
    }

    #[test]
    fn open_source_adapter_supports_multiple_mermaid_diagram_families() {
        for source in [
            "flowchart TD\nA[开始] -->|继续| B[结束]",
            "stateDiagram-v2\n[*] --> Ready\nReady --> [*]",
            "sequenceDiagram\nAlice->>Bob: 你好",
            "classDiagram\nAnimal <|-- Duck",
            "pie\ntitle Values\n\"A\" : 2\n\"B\" : 1",
        ] {
            let output = svg(source).expect("diagram supported by open-source adapter");
            assert!(output.contains("<svg"));
            assert!(!output.contains("<script"));
        }
    }

    #[test]
    fn invalid_diagram_returns_an_escaped_local_fallback() {
        let error = svg("flowchart LR\n-->").expect_err("invalid diagram");
        let fallback = fallback("flowchart LR\n<script>", &error);
        assert!(fallback.contains("无法呈现这个图表"));
        assert!(fallback.contains("请检查 Mermaid 图表声明和连接语法。"));
        assert!(fallback.contains("&lt;script&gt;"));
        assert!(!fallback.contains("<script>"));
    }
}
