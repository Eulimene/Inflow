//! Adapter for the selected open-source Mermaid implementation.
//!
//! This is the only module allowed to reference `mermaid-rs-renderer`.

use mermaid_rs_renderer::{RenderOptions, render_strict};

use crate::mermaid::{MermaidError, MermaidRenderer};

pub(crate) struct MermaidRsRendererAdapter;

impl MermaidRenderer for MermaidRsRendererAdapter {
    fn render_svg(&self, source: &str) -> Result<String, MermaidError> {
        render_strict(source, options())
            .map(|svg| explicit_text_lines(&svg))
            .map_err(|_| MermaidError::InvalidSyntax)
    }
}

/// `AppKit`'s SVG decoder concatenates `tspan` contents and ignores their `dy`
/// offsets. Convert the simple numeric line spans emitted by mmdr into
/// equivalent positioned text elements. Layout, routing and text measurement
/// remain entirely owned by the upstream renderer.
fn explicit_text_lines(svg: &str) -> String {
    let mut output = String::with_capacity(svg.len());
    let mut remaining = svg;
    while let Some(text_start) = remaining.find("<text ") {
        output.push_str(&remaining[..text_start]);
        let text = &remaining[text_start..];
        let Some(open_end) = text.find('>') else {
            output.push_str(text);
            return output;
        };
        let Some(close_start) = text[open_end + 1..].find("</text>") else {
            output.push_str(text);
            return output;
        };
        let close_start = open_end + 1 + close_start;
        let element_end = close_start + "</text>".len();
        let open = &text[..=open_end];
        let body = &text[open_end + 1..close_start];
        if let Some(lines) = expanded_text_element(open, body) {
            output.push_str(&lines);
        } else {
            output.push_str(&text[..element_end]);
        }
        remaining = &text[element_end..];
    }
    output.push_str(remaining);
    output
}

fn expanded_text_element(open: &str, body: &str) -> Option<String> {
    if !body.starts_with("<tspan ") {
        return None;
    }
    let mut y = attribute(open, "y")?.parse::<f64>().ok()?;
    let mut remaining = body;
    let mut spans = Vec::new();
    while !remaining.is_empty() {
        let span_open_end = remaining.find('>')?;
        let span_open = &remaining[..=span_open_end];
        if !span_open.starts_with("<tspan ") {
            return None;
        }
        let span_close = remaining[span_open_end + 1..].find("</tspan>")?;
        let span_close = span_open_end + 1 + span_close;
        let content = &remaining[span_open_end + 1..span_close];
        if content.contains('<') {
            return None;
        }
        let x = attribute(span_open, "x")?;
        let dy = attribute(span_open, "dy")?.parse::<f64>().ok()?;
        y += dy;
        spans.push((x, y, content, attribute(span_open, "font-weight")));
        remaining = &remaining[span_close + "</tspan>".len()..];
    }

    let mut output = String::with_capacity(open.len() * spans.len() + body.len());
    for (x, y, content, weight) in spans {
        let mut line_open = replacing_attribute(open, "x", x)?;
        line_open = replacing_attribute(&line_open, "y", &format!("{y:.2}"))?;
        if let Some(weight) = weight
            && attribute(&line_open, "font-weight").is_none()
        {
            line_open.insert_str(line_open.len() - 1, &format!(" font-weight=\"{weight}\""));
        }
        output.push_str(&line_open);
        output.push_str(content);
        output.push_str("</text>");
    }
    Some(output)
}

fn replacing_attribute(tag: &str, name: &str, value: &str) -> Option<String> {
    let prefix = format!("{name}=\"");
    let start = tag.find(&prefix)? + prefix.len();
    let end = start + tag[start..].find('"')?;
    let mut output = tag.to_owned();
    output.replace_range(start..end, value);
    Some(output)
}

fn attribute<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let prefix = format!("{name}=\"");
    let start = tag.find(&prefix)? + prefix.len();
    let end = start + tag[start..].find('"')?;
    Some(&tag[start..end])
}

fn options() -> RenderOptions {
    // Typora's light theme uses classic Mermaid colors and typography.
    // Keep these in the SVG so AppKit, HTML and PDF use the same appearance.
    let mut options = RenderOptions::mermaid_default()
        .with_node_spacing(50.0)
        .with_rank_spacing(50.0);
    let theme = &mut options.theme;
    "'trebuchet ms', verdana, arial, 'PingFang SC', sans-serif".clone_into(&mut theme.font_family);
    "#9370DB".clone_into(&mut theme.primary_border_color);
    "#333333".clone_into(&mut theme.line_color);
    "#E8E8E8".clone_into(&mut theme.edge_label_background);
    "#ECECFF".clone_into(&mut theme.sequence_actor_fill);
    "#9370DB".clone_into(&mut theme.sequence_actor_border);
    options.layout.node_padding_x = 15.0;
    options.layout.node_padding_y = 10.0;
    options.layout.label_line_height = 1.5;
    options.layout.max_label_width_chars = 28;
    options
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_upstream_multiline_labels_for_appkit_without_changing_layout() {
        let raw = render_strict(
            "flowchart LR\nA[\"接手\\n打开文件\"] --> B[结束]",
            options(),
        )
        .expect("upstream SVG");
        let converted = explicit_text_lines(&raw);

        assert!(raw.contains("<tspan"));
        assert!(!converted.contains("<tspan"));
        assert!(converted.contains(">接手</text>"));
        assert!(!converted.contains("font-weight=\"600\""));
        assert!(converted.contains(">打开文件</text>"));
        assert_eq!(attribute(&raw, "viewBox"), attribute(&converted, "viewBox"));
    }

    #[test]
    fn leaves_non_numeric_or_structured_spans_unchanged() {
        for svg in [
            "<svg><text x=\"1\" y=\"2\"><tspan x=\"1\" dy=\"1em\">A</tspan></text></svg>",
            "<svg><text x=\"1\" y=\"2\"><tspan x=\"1\" dy=\"3\"><b>A</b></tspan></text></svg>",
        ] {
            assert_eq!(explicit_text_lines(svg), svg);
        }
    }
}
