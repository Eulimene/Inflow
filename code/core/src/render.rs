//! Safe Markdown-to-HTML rendering shared by platform clients.

use std::fmt::Write;
use std::ops::Range;

use pulldown_cmark::{CodeBlockKind, Event, Options, Tag, TagEnd, html};

use crate::markdown_ir::{DocumentIr, dialect_options};
use crate::render_ir::RenderIr;
use crate::{code_highlight, math, mermaid};

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
    let document = DocumentIr::parse(markdown, options_with_configuration(configuration));
    html_fragment_from_document(&document, configuration)
}

pub fn html_fragment_from_document(
    document: &DocumentIr,
    configuration: RenderConfiguration,
) -> String {
    let events = safe_events(document, configuration, false, false);
    let mut output = String::with_capacity(document.source().len());
    html::push_html(&mut output, events.into_iter());
    output
}

/// Renders the in-app preview fragment while attaching parsed link targets at
/// the same event boundary that creates each anchor. Platform hosts therefore
/// never have to correlate rendered `<a>` tags with a second reference scan.
pub fn html_fragment_for_preview_from_document(
    document: &DocumentIr,
    configuration: RenderConfiguration,
) -> String {
    let events = safe_events(document, configuration, false, true);
    let mut output = String::with_capacity(document.source().len());
    html::push_html(&mut output, events.into_iter());
    annotate_blocks(output, document, configuration, false)
}

/// Renders the canonical in-app fragment and adds inert source metadata used
/// by the editable `WebKit` host. The rendered elements and presentation are
/// otherwise byte-for-byte the same as the read-only preview fragment.
pub fn html_fragment_for_editor(markdown: &str, configuration: RenderConfiguration) -> String {
    let document = DocumentIr::parse(markdown, options_with_configuration(configuration));
    annotate_blocks(
        html_fragment_from_document(&document, configuration),
        &document,
        configuration,
        true,
    )
}

#[derive(Debug, Eq, PartialEq)]
struct EditableBlockAnnotation {
    opening_tag: String,
    source_range: Range<usize>,
    block_id: String,
}

/// Adds inert source metadata to the exact HTML consumed by both preview hosts.
///
/// Keeping this in the core means editability never requires a second Markdown
/// parser or a second renderer in the platform layer. The attributes are data
/// only, have no visual effect, and are omitted from delivery/export HTML.
fn annotate_blocks(
    mut html: String,
    document: &DocumentIr,
    configuration: RenderConfiguration,
    include_source_hex: bool,
) -> String {
    let annotations = editable_block_annotations(document, configuration);
    let mut search_start = 0;
    for annotation in annotations {
        let needle = format!("<{}", annotation.opening_tag);
        let Some(relative_start) = html[search_start..].find(&needle) else {
            continue;
        };
        let tag_start = search_start + relative_start;
        let Some(relative_end) = html[tag_start..].find('>') else {
            break;
        };
        let tag_end = tag_start + relative_end;
        let opening = &html[tag_start..=tag_end];
        let source = &document.source().as_bytes()[annotation.source_range.clone()];
        let mut attributes = String::new();
        if !opening.contains("data-inflow-source-start=") {
            write!(
                attributes,
                " data-inflow-block-id=\"{}\" data-inflow-source-start=\"{}\" data-inflow-source-end=\"{}\"",
                annotation.block_id, annotation.source_range.start, annotation.source_range.end
            )
            .expect("writing to a String cannot fail");
        }
        if include_source_hex {
            write!(attributes, " data-inflow-source-hex=\"{}\"", hex(source))
                .expect("writing to a String cannot fail");
        }
        let insertion = if html.as_bytes().get(tag_end.wrapping_sub(1)) == Some(&b'/') {
            tag_end - 1
        } else {
            tag_end
        };
        html.insert_str(insertion, &attributes);
        search_start = tag_end + attributes.len() + 1;
    }
    html
}

fn editable_block_annotations(
    document: &DocumentIr,
    configuration: RenderConfiguration,
) -> Vec<EditableBlockAnnotation> {
    let mut annotations = Vec::new();
    let render = RenderIr::from_document(document);
    let mut block_depth = 0_u32;
    for located in document.events() {
        let source_range = located.source_range.clone();
        match &located.event {
            Event::Start(tag) if is_block_tag(tag) => {
                if block_depth == 0
                    && !source_range.is_empty()
                    && let Some(opening_tag) = opening_tag_for(tag, configuration)
                {
                    let block_id = render
                        .blocks
                        .iter()
                        .find(|block| {
                            block.depth == 0
                                && block.source_range.start == source_range.start
                                && block.source_range.end == source_range.end
                        })
                        .map_or_else(
                            || format!("source-{}-{}", source_range.start, source_range.end),
                            |block| block.block_id.clone(),
                        );
                    annotations.push(EditableBlockAnnotation {
                        opening_tag,
                        source_range,
                        block_id,
                    });
                }
                block_depth += 1;
            }
            Event::End(tag) if is_block_end(*tag) => {
                block_depth = block_depth.saturating_sub(1);
            }
            Event::Rule if block_depth == 0 && !source_range.is_empty() => {
                let block_id = render
                    .blocks
                    .iter()
                    .find(|block| {
                        block.depth == 0
                            && block.source_range.start == source_range.start
                            && block.source_range.end == source_range.end
                    })
                    .map_or_else(
                        || format!("source-{}-{}", source_range.start, source_range.end),
                        |block| block.block_id.clone(),
                    );
                annotations.push(EditableBlockAnnotation {
                    opening_tag: "hr".to_owned(),
                    source_range,
                    block_id,
                });
            }
            _ => {}
        }
    }
    annotations
}

fn opening_tag_for(tag: &Tag<'_>, configuration: RenderConfiguration) -> Option<String> {
    match tag {
        Tag::Paragraph => Some("p".to_owned()),
        Tag::Heading { level, .. } => Some(format!("h{}", *level as u8)),
        Tag::BlockQuote(_) => Some("blockquote".to_owned()),
        Tag::CodeBlock(kind) => Some(
            if configuration.mermaid_enabled && is_mermaid_code_block(kind) {
                "figure"
            } else {
                "pre"
            }
            .to_owned(),
        ),
        Tag::List(Some(_)) => Some("ol".to_owned()),
        Tag::List(None) => Some("ul".to_owned()),
        Tag::Table(_) => Some("table".to_owned()),
        Tag::FootnoteDefinition(_) => Some("div".to_owned()),
        Tag::DefinitionList => Some("dl".to_owned()),
        Tag::HtmlBlock
        | Tag::Item
        | Tag::TableHead
        | Tag::TableRow
        | Tag::TableCell
        | Tag::DefinitionListTitle
        | Tag::DefinitionListDefinition
        | Tag::Emphasis
        | Tag::Strong
        | Tag::Strikethrough
        | Tag::Link { .. }
        | Tag::Image { .. }
        | Tag::Superscript
        | Tag::Subscript
        | Tag::MetadataBlock(_) => None,
    }
}

fn is_block_tag(tag: &Tag<'_>) -> bool {
    matches!(
        tag,
        Tag::Paragraph
            | Tag::Heading { .. }
            | Tag::BlockQuote(_)
            | Tag::CodeBlock(_)
            | Tag::List(_)
            | Tag::Item
            | Tag::Table(_)
            | Tag::TableHead
            | Tag::TableRow
            | Tag::TableCell
            | Tag::FootnoteDefinition(_)
            | Tag::HtmlBlock
            | Tag::DefinitionList
            | Tag::DefinitionListTitle
            | Tag::DefinitionListDefinition
            | Tag::MetadataBlock(_)
    )
}

fn is_block_end(tag: TagEnd) -> bool {
    matches!(
        tag,
        TagEnd::Paragraph
            | TagEnd::Heading(_)
            | TagEnd::BlockQuote(_)
            | TagEnd::CodeBlock
            | TagEnd::List(_)
            | TagEnd::Item
            | TagEnd::Table
            | TagEnd::TableHead
            | TagEnd::TableRow
            | TagEnd::TableCell
            | TagEnd::FootnoteDefinition
            | TagEnd::HtmlBlock
            | TagEnd::DefinitionList
            | TagEnd::DefinitionListTitle
            | TagEnd::DefinitionListDefinition
            | TagEnd::MetadataBlock(_)
    )
}

fn is_mermaid_code_block(kind: &CodeBlockKind<'_>) -> bool {
    matches!(
        kind,
        CodeBlockKind::Fenced(language)
            if language
                .split_ascii_whitespace()
                .next()
                .is_some_and(|name| name.eq_ignore_ascii_case("mermaid"))
    )
}

/// Renders a delivery-safe fragment. Links which cannot be carried safely in a
/// self-contained file remain readable but are deliberately not clickable.
pub(crate) fn html_fragment_for_delivery(
    markdown: &str,
    configuration: RenderConfiguration,
) -> String {
    let document = DocumentIr::parse(markdown, options_with_configuration(configuration));
    let events = safe_events(&document, configuration, true, false);
    let mut output = String::with_capacity(document.source().len());
    html::push_html(&mut output, events.into_iter());
    output
}

#[allow(clippy::too_many_lines)] // One ordered state machine keeps nested Markdown event handling auditable.
fn safe_events(
    document: &DocumentIr,
    configuration: RenderConfiguration,
    neutralize_delivery_links: bool,
    annotate_preview_links: bool,
) -> Vec<Event<'static>> {
    let mut parser = document
        .events()
        .iter()
        .map(|located| (located.event.clone(), located.source_range.clone()));
    let mut events = Vec::new();
    let mut neutralized_link_depth = 0_u32;
    while let Some((event, event_range)) = parser.next() {
        if neutralize_delivery_links
            && matches!(&event, Event::Start(Tag::Link { dest_url, .. }) if !is_portable_link(dest_url))
        {
            neutralized_link_depth += 1;
            events.push(Event::InlineHtml(
                "<span class=\"inflow-disabled-link\" role=\"note\" aria-label=\"该链接在导出时已停用\">"
                    .into(),
            ));
        } else if neutralized_link_depth > 0 && matches!(event, Event::End(TagEnd::Link)) {
            neutralized_link_depth -= 1;
            events.push(Event::InlineHtml("</span>".into()));
        } else if annotate_preview_links && let Some(link) = preview_link_start(&event) {
            events.push(link);
        } else if annotate_preview_links && matches!(event, Event::End(TagEnd::Link)) {
            events.push(Event::InlineHtml("</a>".into()));
        } else if let Event::Start(Tag::Image { dest_url, .. }) = &event {
            let destination = dest_url.to_string();
            let mut alternative = String::new();
            for (image_event, _) in parser.by_ref() {
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
            let mut source_end = event_range.end;
            for (code_event, code_range) in parser.by_ref() {
                source_end = code_range.end;
                match code_event {
                    Event::End(TagEnd::CodeBlock) => break,
                    Event::Text(text) | Event::Code(text) => source.push_str(&text),
                    Event::SoftBreak | Event::HardBreak => source.push('\n'),
                    _ => {}
                }
            }
            let diagram = mermaid::svg(source.trim_end()).unwrap_or_else(|error| {
                if neutralize_delivery_links {
                    mermaid::fallback(source.trim_end(), &error)
                } else {
                    mermaid::fallback_at(source.trim_end(), &error, event_range.start..source_end)
                }
            });
            events.push(Event::InlineHtml(diagram.into()));
        } else if let Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(language))) = &event {
            if code_highlight::supports_language(language) {
                let mut source = String::new();
                for (code_event, _) in parser.by_ref() {
                    match code_event {
                        Event::End(TagEnd::CodeBlock) => break,
                        Event::Text(text) | Event::Code(text) => source.push_str(&text),
                        Event::SoftBreak | Event::HardBreak => source.push('\n'),
                        _ => {}
                    }
                }
                let block = code_highlight::highlighted_code_block(language, &source)
                    .expect("the language profile was checked above");
                events.push(Event::InlineHtml(block.into()));
            } else {
                events.push(sanitize_event(event));
            }
        } else if let Event::InlineMath(source) = &event {
            events.push(render_math(
                source,
                false,
                (!neutralize_delivery_links).then_some(&event_range),
            ));
        } else if let Event::DisplayMath(source) = &event {
            events.push(render_math(
                source,
                true,
                (!neutralize_delivery_links).then_some(&event_range),
            ));
        } else {
            events.push(sanitize_event(event));
        }
    }
    events
}

fn preview_link_start(event: &Event<'_>) -> Option<Event<'static>> {
    let Event::Start(Tag::Link { dest_url, .. }) = event else {
        return None;
    };
    Some(Event::InlineHtml(
        format!(
            "<a href=\"{}\" data-inflow-link-target-hex=\"{}\">",
            preview_href(dest_url),
            hex(dest_url.as_bytes())
        )
        .into(),
    ))
}

fn preview_href(destination: &str) -> String {
    let mut escaped = String::with_capacity(destination.len());
    for character in destination.chars() {
        match character {
            ' ' => escaped.push_str("%20"),
            '&' => escaped.push_str("&amp;"),
            '\"' => escaped.push_str("&quot;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            character if character.is_control() => {
                let mut bytes = [0_u8; 4];
                for byte in character.encode_utf8(&mut bytes).bytes() {
                    write!(escaped, "%{byte:02X}").expect("writing to a String cannot fail");
                }
            }
            character => escaped.push(character),
        }
    }
    escaped
}

fn render_math(
    source: &str,
    display: bool,
    source_range: Option<&std::ops::Range<usize>>,
) -> Event<'static> {
    let markup = math::mathml(source, display)
        .unwrap_or_else(|error| math::fallback(source, error, display, source_range));
    Event::InlineHtml(markup.into())
}

pub(crate) fn is_portable_link(destination: &str) -> bool {
    let destination = destination.trim_matches(char::is_whitespace);
    if destination.is_empty() || destination.starts_with('#') {
        return true;
    }

    let scheme_end = destination.find(':');
    let path_marker = destination
        .find(['/', '?', '#'])
        .unwrap_or(destination.len());
    let Some(scheme_end) = scheme_end.filter(|position| *position < path_marker) else {
        return false;
    };
    matches!(
        destination[..scheme_end].to_ascii_lowercase().as_str(),
        "http" | "https" | "mailto"
    )
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
    dialect_options(configuration.math_enabled)
}

fn sanitize_event(event: Event<'_>) -> Event<'_> {
    match event {
        Event::Html(raw_html) | Event::InlineHtml(raw_html) => Event::Text(raw_html),
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
    fn preview_blocks_carry_core_owned_edit_ranges_without_changing_delivery_html() {
        let markdown = "# 标题\n\n正文 **加粗**\n\n| A | B |\n| - | - |\n| 1 | 2 |\n";
        let preview = html_fragment_for_editor(markdown, RenderConfiguration::default());

        let heading_end = markdown.find('\n').expect("heading line ending") + 1;
        assert!(preview.contains("<h1 data-inflow-block-id=\"heading-"));
        assert!(preview.contains(&format!(
            "data-inflow-source-start=\"0\" data-inflow-source-end=\"{heading_end}\""
        )));
        assert!(preview.contains("data-inflow-source-hex=\"2320e6a087e9a2980a\""));
        assert!(preview.contains("<p data-inflow-block-id=\"paragraph-"));
        assert!(preview.contains("<table data-inflow-block-id=\"table-"));

        let delivery = html_fragment_for_delivery(markdown, RenderConfiguration::default());
        assert!(!delivery.contains("data-inflow-source-"));
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

        assert!(html.contains("<pre><code class=\"language-html inflow-code-highlight\">"));
        assert!(html.contains("&lt;script&gt;"));
        assert!(html.contains("bad()"));
        assert!(html.contains("&lt;/script&gt;"));
        assert!(!html.contains("<script>bad()"));
    }

    #[test]
    fn highlights_known_code_languages_without_scripts_or_source_loss() {
        let html =
            html_fragment("```swift\nlet greeting = \"<script>你好</script>\" // 注释\n```\n");

        assert!(html.contains("language-swift inflow-code-highlight"));
        assert!(html.contains("<span class=\"tok-keyword\">let</span>"));
        assert!(html.contains("<span class=\"tok-comment\">// 注释</span>"));
        assert!(html.contains("&lt;script&gt;你好&lt;/script&gt;"));
        assert!(!html.contains("<script>"));
    }

    #[test]
    fn leaves_unknown_language_blocks_readable_and_escaped() {
        let html = html_fragment("```unknown\n<unsafe>& text\n```\n");

        assert!(html.contains("<pre><code class=\"language-unknown\">"));
        assert!(html.contains("&lt;unsafe&gt;&amp; text"));
        assert!(!html.contains("inflow-code-highlight"));
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
    fn localizes_formula_failure_with_preview_actions_and_delivery_privacy() {
        let markdown = "Before $\\unknown{x}$ after";
        let preview = html_fragment(markdown);
        let formula_start = markdown.find('$').unwrap();
        let formula_end = markdown.rfind('$').unwrap() + 1;
        assert!(preview.contains("无法呈现这个公式"));
        assert!(preview.contains(&format!("data-inflow-source-start=\"{formula_start}\"")));
        assert!(preview.contains(&format!("data-inflow-source-end=\"{formula_end}\"")));
        assert!(preview.contains("data-inflow-preview-error-action=\"locate\""));
        assert!(preview.contains("<p>Before "));
        assert!(preview.contains(" after</p>"));

        let delivery = html_fragment_for_delivery(markdown, RenderConfiguration::default());
        assert!(delivery.contains("无法呈现这个公式"));
        assert!(!delivery.contains("data-inflow-source-start"));
        assert!(!delivery.contains("data-inflow-preview-error-action"));
        assert!(!delivery.contains("<button"));
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

        let markdown = "```mermaid\npie\ntitle Values\n```\n\nStill readable";
        let fallback = html_fragment(markdown);
        let diagram_end = markdown.find("\n\nStill readable").unwrap();
        assert!(fallback.contains("无法呈现这个图表"));
        assert!(fallback.contains("pie"));
        assert!(fallback.contains("data-inflow-source-start=\"0\""));
        assert!(fallback.contains(&format!("data-inflow-source-end=\"{diagram_end}\"")));
        assert!(fallback.contains("data-inflow-preview-error-action=\"locate\""));
        assert!(fallback.contains("data-inflow-preview-error-action=\"retry\""));
        assert!(fallback.contains("定位源文本"));
        assert!(fallback.contains("重试"));
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
    fn delivery_mermaid_failure_does_not_expose_editor_offsets_or_dead_actions() {
        let html = html_fragment_for_delivery(
            "```mermaid\npie\ntitle Values\n```",
            RenderConfiguration::default(),
        );

        assert!(html.contains("无法呈现这个图表"));
        assert!(!html.contains("data-inflow-source-start"));
        assert!(!html.contains("data-inflow-preview-error-action"));
        assert!(!html.contains("<button"));
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

    #[test]
    fn preview_links_carry_targets_directly_from_parser_events() {
        let markdown = "[space](<https://example.com/a b>) [资料](资料/说明.md)";
        let document = DocumentIr::parse(markdown, options());
        let html =
            html_fragment_for_preview_from_document(&document, RenderConfiguration::default());

        assert!(html.contains("href=\"https://example.com/a%20b\""));
        assert!(html.contains(
            "data-inflow-link-target-hex=\"68747470733a2f2f6578616d706c652e636f6d2f612062\""
        ));
        assert!(html.contains("data-inflow-link-target-hex=\"e8b584e696992fe8afb4e6988e2e6d64\""));
        assert_eq!(html.matches("data-inflow-link-target-hex").count(), 2);
        assert!(html.contains("data-inflow-block-id=\"paragraph-"));
        assert!(!html.contains("data-inflow-source-hex"));
    }

    #[test]
    fn delivery_neutralizes_local_and_unsafe_links_without_leaking_targets() {
        let html = html_fragment_for_delivery(
            "[local](/Users/person/Private.md) [unsafe](javascript:alert(1)) [web](https://example.com)",
            RenderConfiguration::default(),
        );

        assert_eq!(html.matches("class=\"inflow-disabled-link\"").count(), 2);
        assert!(html.contains(">local</span>"));
        assert!(html.contains(">unsafe</span>"));
        assert!(html.contains("href=\"https://example.com\""));
        assert!(!html.contains("/Users/person"));
        assert!(!html.contains("javascript:"));
    }
}
