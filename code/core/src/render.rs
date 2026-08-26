//! Safe Markdown-to-HTML rendering shared by platform clients.

use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd, html};

use crate::{math, mermaid};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RenderConfiguration {
    pub math_enabled: bool,
    pub mermaid_enabled: bool,
}

impl Default for RenderConfiguration {
    fn default() -> Self {
        Self {
            math_enabled: true,
            mermaid_enabled: true,
        }
    }
}

#[allow(dead_code)] // Default policy convenience used by core callers and regression tests.
pub fn html_fragment(markdown: &str) -> String {
    html_fragment_with_configuration(markdown, RenderConfiguration::default())
}

pub fn html_fragment_with_configuration(
    markdown: &str,
    configuration: RenderConfiguration,
) -> String {
    let events = safe_events(markdown, configuration);
    let mut output = String::with_capacity(markdown.len());
    html::push_html(&mut output, events.into_iter());
    output
}

fn safe_events(markdown: &str, configuration: RenderConfiguration) -> Vec<Event<'_>> {
    let mut parser = Parser::new_ext(markdown, options_with_configuration(configuration));
    let mut events = Vec::new();
    while let Some(event) = parser.next() {
        if let Event::Start(Tag::Image { dest_url, .. }) = &event {
            let destination = dest_url.to_string();
            let mut alternative = String::new();
            for image_event in parser.by_ref() {
                match image_event {
                    Event::End(TagEnd::Image) => break,
                    Event::Text(text) | Event::Code(text) => alternative.push_str(&text),
                    Event::SoftBreak | Event::HardBreak => alternative.push(' '),
                    _ => {}
                }
            }
            events.push(Event::InlineHtml(
                format!(
                    "<span class=\"inflow-image-slot\" data-inflow-target=\"{}\" data-inflow-alt=\"{}\"></span>",
                    hex(destination.as_bytes()),
                    hex(alternative.trim().as_bytes())
                )
                .into(),
            ));
        } else if configuration.mermaid_enabled
            && matches!(
                &event,
                Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(language)))
                    if language
                        .split_ascii_whitespace()
                        .next()
                        .is_some_and(|name| name.eq_ignore_ascii_case("mermaid"))
            )
        {
            let mut source = String::new();
            for code_event in parser.by_ref() {
                match code_event {
                    Event::End(TagEnd::CodeBlock) => break,
                    Event::Text(text) | Event::Code(text) => source.push_str(&text),
                    Event::SoftBreak | Event::HardBreak => source.push('\n'),
                    _ => {}
                }
            }
            let diagram = mermaid::svg(source.trim_end())
                .unwrap_or_else(|error| mermaid::fallback(source.trim_end(), &error));
            events.push(Event::InlineHtml(diagram.into()));
        } else {
            events.push(sanitize_event(event));
        }
    }
    events
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(char::from(DIGITS[usize::from(byte >> 4)]));
        output.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    output
}

pub(crate) fn options() -> Options {
    options_with_configuration(RenderConfiguration::default())
}

fn options_with_configuration(configuration: RenderConfiguration) -> Options {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    if configuration.math_enabled {
        options.insert(Options::ENABLE_MATH);
    }
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    options
}

fn sanitize_event(event: Event<'_>) -> Event<'_> {
    match event {
        Event::Html(raw_html) | Event::InlineHtml(raw_html) => Event::Text(raw_html),
        Event::InlineMath(source) => Event::InlineHtml(math::mathml(&source, false).into()),
        Event::DisplayMath(source) => Event::InlineHtml(math::mathml(&source, true).into()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_common_markdown_and_gfm_extensions() {
        let markdown = concat!(
            "# Title\n\n",
            "A **bold** paragraph with ~~old text~~.\n\n",
            "- [x] complete\n- [ ] pending\n\n",
            "| Name | Value |\n| --- | ---: |\n| One | 1 |\n",
        );
        let html = html_fragment(markdown);

        assert!(html.contains("<h1>Title</h1>"));
        assert!(html.contains("<strong>bold</strong>"));
        assert!(html.contains("<del>old text</del>"));
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("<table>"));
    }

    #[test]
    fn escapes_raw_html_instead_of_executing_it() {
        let html = html_fragment("Before\n\n<script>alert('no')</script>\n\nAfter");

        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;script&gt;"));
        assert!(html.contains("alert('no')"));
    }

    #[test]
    fn escapes_html_inside_code_blocks() {
        let html = html_fragment("```html\n<script>bad()</script>\n```\n");

        assert!(html.contains("<pre><code class=\"language-html\">"));
        assert!(html.contains("&lt;script&gt;bad()&lt;/script&gt;"));
        assert!(!html.contains("<script>bad()"));
    }

    #[test]
    fn renders_inline_and_display_math_without_scripts() {
        let html = html_fragment("Inline $x_1^2$\n\n$$\\frac{a}{b}$$\n");

        assert!(html.contains("<math xmlns=\"http://www.w3.org/1998/Math/MathML\""));
        assert!(html.contains("display=\"inline\""));
        assert!(html.contains("display=\"block\""));
        assert!(html.contains("<msubsup>") || html.contains("<msup>"));
        assert!(html.contains("<mfrac>"));
        assert!(!html.contains("<script"));
    }

    #[test]
    fn renders_mermaid_offline_and_localizes_single_diagram_failure() {
        let html =
            html_fragment("Before\n\n```mermaid\nflowchart TD\nA[开始] --> B[结束]\n```\n\nAfter");
        assert!(html.contains("class=\"mermaid-diagram\""));
        assert!(html.contains("<svg"));
        assert!(html.contains("开始"));
        assert!(html.contains("<p>After</p>"));
        assert!(!html.contains("<script"));

        let fallback = html_fragment("```mermaid\npie\ntitle Values\n```\n\nStill readable");
        assert!(fallback.contains("无法呈现这个图表"));
        assert!(fallback.contains("pie"));
        assert!(fallback.contains("<p>Still readable</p>"));
    }

    #[test]
    fn disabled_presentation_features_remain_readable_markdown_source() {
        let configuration = RenderConfiguration {
            math_enabled: false,
            mermaid_enabled: false,
        };
        let html = html_fragment_with_configuration(
            "Inline $x^2$\n\n```mermaid\nflowchart TD\nA --> B\n```\n",
            configuration,
        );

        assert!(html.contains("Inline $x^2$"));
        assert!(!html.contains("<math"));
        assert!(html.contains("<pre><code class=\"language-mermaid\">"));
        assert!(html.contains("flowchart TD"));
        assert!(!html.contains("class=\"mermaid-diagram\""));
        assert!(!html.contains("<svg"));
    }

    #[test]
    fn presentation_features_can_be_toggled_independently() {
        let markdown = "$x$\n\n```mermaid\nflowchart TD\nA --> B\n```\n";
        let math_only = html_fragment_with_configuration(
            markdown,
            RenderConfiguration {
                math_enabled: true,
                mermaid_enabled: false,
            },
        );
        assert!(math_only.contains("<math"));
        assert!(math_only.contains("language-mermaid"));
        assert!(!math_only.contains("mermaid-diagram"));

        let mermaid_only = html_fragment_with_configuration(
            markdown,
            RenderConfiguration {
                math_enabled: false,
                mermaid_enabled: true,
            },
        );
        assert!(!mermaid_only.contains("<math"));
        assert!(mermaid_only.contains("$x$"));
        assert!(mermaid_only.contains("mermaid-diagram"));
    }

    #[test]
    fn renders_images_as_inert_slots_for_the_platform_resolver() {
        let html = html_fragment(
            "Local ![封面](assets/cover.png) remote ![外部](https://example.com/a.jpg)",
        );

        assert_eq!(html.matches("class=\"inflow-image-slot\"").count(), 2);
        assert!(html.contains("data-inflow-target=\"6173736574732f636f7665722e706e67\""));
        assert!(html.contains("data-inflow-alt=\"e5b081e99da2\""));
        assert!(!html.contains("<img"));
        assert!(!html.contains("src=\"https://"));
    }
}
