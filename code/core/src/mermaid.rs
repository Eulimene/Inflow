//! Deterministic, offline renderer for the launch-scope Mermaid diagram types.

use std::fmt::Write as _;

use pulldown_cmark::{CodeBlockKind, Event, Parser, Tag, TagEnd};

use crate::render;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Direction {
    Horizontal,
    Vertical,
}

#[derive(Debug)]
struct Node {
    id: String,
    label: String,
}

#[derive(Debug)]
struct Edge {
    from: String,
    to: String,
    label: String,
    dashed: bool,
}

#[derive(Debug)]
struct Diagram {
    kind: &'static str,
    direction: Direction,
    nodes: Vec<Node>,
    edges: Vec<Edge>,
}

#[derive(Clone, Copy, Debug)]
struct NodeLayout {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
}

#[derive(Debug, Eq, PartialEq)]
pub enum MermaidError {
    UnsupportedType,
    InvalidSyntax,
}

/// Extracts one parser-validated Mermaid fence and renders its body. Keeping
/// fence recognition here ensures preview and native instant editing consume
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
    let mut logical_lines = source
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with("%%"));
    let header = logical_lines.next().ok_or(MermaidError::InvalidSyntax)?;
    let lines: Vec<&str> = logical_lines.collect();
    let diagram = if header.starts_with("flowchart ") {
        parse_flowchart(header, &lines)?
    } else if header == "stateDiagram-v2" {
        parse_state(&lines)?
    } else {
        return Err(MermaidError::UnsupportedType);
    };
    render(&diagram, source)
}

fn parse_flowchart(header: &str, lines: &[&str]) -> Result<Diagram, MermaidError> {
    let direction = header
        .split_ascii_whitespace()
        .nth(1)
        .map_or(Direction::Vertical, |value| match value {
            "LR" | "RL" => Direction::Horizontal,
            _ => Direction::Vertical,
        });
    let mut diagram = Diagram {
        kind: "流程图",
        direction,
        nodes: Vec::new(),
        edges: Vec::new(),
    };
    for statement in lines.iter().flat_map(|line| line.split(';')).map(str::trim) {
        if statement.is_empty() {
            continue;
        }
        let (left, operator, right, inline_label) = split_flow_relation(statement)?;
        let (right, trailing_label) = flow_edge_label(right);
        let from = add_node_spec(&mut diagram, left)?;
        let to = add_node_spec(&mut diagram, right)?;
        diagram.edges.push(Edge {
            from,
            to,
            label: inline_label.unwrap_or(trailing_label),
            dashed: operator == "-.->",
        });
    }
    require_content(diagram)
}

fn split_flow_relation(
    statement: &str,
) -> Result<(&str, &'static str, &str, Option<String>), MermaidError> {
    // Mermaid's labelled dashed edge places its label inside the operator:
    // `A -.label.-> B`. Treat it as the same safe, static dashed relation as
    // `A -.-> B`, while retaining the label for the generated SVG.
    if let Some(opening) = statement.find("-.") {
        let label_start = opening + 2;
        if let Some(relative_closing) = statement[label_start..].find(".->") {
            let closing = label_start + relative_closing;
            let left = statement[..opening].trim();
            let right = statement[closing + 3..].trim();
            let label = statement[label_start..closing].trim();
            if !left.is_empty() && !right.is_empty() && !label.is_empty() {
                return Ok((left, "-.->", right, Some(label.to_owned())));
            }
        }
    }

    let (left, operator, right) = split_relation(statement, &["-.->", "==>", "-->", "---"])?;
    Ok((left, operator, right, None))
}

fn parse_state(lines: &[&str]) -> Result<Diagram, MermaidError> {
    let mut diagram = Diagram {
        kind: "状态图",
        direction: Direction::Vertical,
        nodes: Vec::new(),
        edges: Vec::new(),
    };
    for line in lines {
        if let Some(declaration) = line.strip_prefix("state ")
            && let Some((label, id)) = declaration.rsplit_once(" as ")
        {
            add_node(&mut diagram, id.trim(), label.trim().trim_matches('"'))?;
            continue;
        }
        let (left, operator, right) = split_relation(line, &["-->", "--"])?;
        let (right, label) = split_label(right);
        let from = add_state_node(&mut diagram, left)?;
        let to = add_state_node(&mut diagram, right)?;
        diagram.edges.push(Edge {
            from,
            to,
            label,
            dashed: operator == "--",
        });
    }
    require_content(diagram)
}

fn split_relation<'a>(
    statement: &'a str,
    operators: &[&'static str],
) -> Result<(&'a str, &'static str, &'a str), MermaidError> {
    operators
        .iter()
        .filter_map(|operator| {
            statement
                .find(operator)
                .map(|position| (position, *operator))
        })
        .min_by_key(|(position, _)| *position)
        .map(|(position, operator)| {
            (
                statement[..position].trim(),
                operator,
                statement[position + operator.len()..].trim(),
            )
        })
        .filter(|(left, _, right)| !left.is_empty() && !right.is_empty())
        .ok_or(MermaidError::InvalidSyntax)
}

fn flow_edge_label(value: &str) -> (&str, String) {
    if let Some(rest) = value.strip_prefix('|')
        && let Some((label, node)) = rest.split_once('|')
    {
        return (node.trim(), label.trim().to_owned());
    }
    split_label(value)
}

fn split_label(value: &str) -> (&str, String) {
    value
        .split_once(':')
        .map_or((value.trim(), String::new()), |(node, label)| {
            (node.trim(), label.trim().to_owned())
        })
}

fn add_state_node(diagram: &mut Diagram, specification: &str) -> Result<String, MermaidError> {
    if specification.trim() == "[*]" {
        let id = if diagram.nodes.iter().any(|node| node.id == "__terminal") {
            "__terminal_2"
        } else {
            "__terminal"
        };
        add_node(diagram, id, "●")
    } else {
        add_node_spec(diagram, specification)
    }
}

fn add_node_spec(diagram: &mut Diagram, specification: &str) -> Result<String, MermaidError> {
    let specification = specification.trim();
    let marker = specification.find(['[', '(', '{']);
    let (id, label) = marker.map_or((specification, specification), |position| {
        let id = specification[..position].trim();
        let label = specification[position + 1..]
            .trim_end_matches([']', ')', '}'])
            .trim_matches('"');
        (id, label)
    });
    add_node(diagram, id, label)
}

fn add_node(diagram: &mut Diagram, id: &str, label: &str) -> Result<String, MermaidError> {
    if id.is_empty()
        || !id
            .chars()
            .all(|character| character.is_alphanumeric() || matches!(character, '_' | '-'))
    {
        return Err(MermaidError::InvalidSyntax);
    }
    if let Some(node) = diagram.nodes.iter_mut().find(|node| node.id == id) {
        if node.label == node.id && label != id {
            label.clone_into(&mut node.label);
        }
        return Ok(id.to_owned());
    }
    diagram.nodes.push(Node {
        id: id.to_owned(),
        label: label.to_owned(),
    });
    Ok(id.to_owned())
}

fn require_content(diagram: Diagram) -> Result<Diagram, MermaidError> {
    if diagram.nodes.is_empty() || diagram.edges.is_empty() {
        Err(MermaidError::InvalidSyntax)
    } else {
        Ok(diagram)
    }
}

#[allow(clippy::too_many_lines)]
fn render(diagram: &Diagram, source: &str) -> Result<String, MermaidError> {
    let node_height = 52usize;
    let spacing = 70usize;
    let node_widths: Vec<usize> = diagram
        .nodes
        .iter()
        .map(|node| node_width_for_label(&node.label))
        .collect();
    let (width, height, positions) = match diagram.direction {
        Direction::Horizontal => {
            let width = 80
                + node_widths.iter().sum::<usize>()
                + spacing * diagram.nodes.len().saturating_sub(1);
            let height = 190;
            let mut x = 40;
            let positions: Vec<NodeLayout> = node_widths
                .iter()
                .map(|node_width| {
                    let layout = NodeLayout {
                        x,
                        y: (height - node_height) / 2,
                        width: *node_width,
                        height: node_height,
                    };
                    x += node_width + spacing;
                    layout
                })
                .collect();
            (width, height, positions)
        }
        Direction::Vertical => {
            let maximum_node_width = node_widths.iter().copied().max().unwrap_or(96);
            let width = 430.max(maximum_node_width + 160);
            let height = 60
                + diagram.nodes.len() * node_height
                + spacing * diagram.nodes.len().saturating_sub(1);
            let positions: Vec<NodeLayout> = node_widths
                .iter()
                .enumerate()
                .map(|(index, node_width)| NodeLayout {
                    x: (width - node_width) / 2,
                    y: 30 + index * (node_height + spacing),
                    width: *node_width,
                    height: node_height,
                })
                .collect();
            (width, height, positions)
        }
    };
    let mut output = format!(
        "<figure class=\"mermaid-diagram\" aria-label=\"{}\"><svg xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\" aria-label=\"{}\"><defs><marker id=\"inflow-arrow\" markerWidth=\"10\" markerHeight=\"10\" refX=\"9\" refY=\"3\" orient=\"auto\"><path d=\"M0,0 L0,6 L9,3 z\" fill=\"currentColor\"/></marker></defs>",
        diagram.kind,
        escape(source)
    );
    let mut edge_labels = Vec::new();
    for (edge_index, edge) in diagram.edges.iter().enumerate() {
        let from_index = diagram
            .nodes
            .iter()
            .position(|node| node.id == edge.from)
            .ok_or(MermaidError::InvalidSyntax)?;
        let to_index = diagram
            .nodes
            .iter()
            .position(|node| node.id == edge.to)
            .ok_or(MermaidError::InvalidSyntax)?;
        let (path, label_x, label_y, routed) = edge_path(
            diagram.direction,
            positions[from_index],
            positions[to_index],
            (width, height),
            from_index,
            to_index,
            edge_index,
        );
        let dash = if edge.dashed {
            " stroke-dasharray=\"6 5\""
        } else {
            ""
        };
        let route_class = if routed { " edge-routed" } else { "" };
        let _ = write!(
            output,
            "<path class=\"edge{route_class}\" d=\"{path}\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"{dash} marker-end=\"url(#inflow-arrow)\"/>"
        );
        if !edge.label.is_empty() {
            edge_labels.push((edge.label.as_str(), label_x, label_y));
        }
    }
    for (label, label_x, label_y) in edge_labels {
        let label_width = text_width(label) + 16;
        let label_left = label_x.saturating_sub(label_width / 2);
        let label_top = label_y.saturating_sub(11);
        let _ = write!(
            output,
            "<rect x=\"{label_left}\" y=\"{label_top}\" width=\"{label_width}\" height=\"22\" rx=\"4\" class=\"edge-label-background\"/><text x=\"{label_x}\" y=\"{label_y}\" text-anchor=\"middle\" dominant-baseline=\"middle\" class=\"edge-label\">{}</text>",
            escape(label)
        );
    }
    for (node, layout) in diagram.nodes.iter().zip(positions) {
        let _ = write!(
            output,
            "<g class=\"node\"><rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" rx=\"9\"/><text x=\"{}\" y=\"{}\" text-anchor=\"middle\" dominant-baseline=\"middle\">{}</text></g>",
            layout.x,
            layout.y,
            layout.width,
            layout.height,
            layout.x + layout.width / 2,
            layout.y + layout.height / 2,
            escape(&node.label)
        );
    }
    output.push_str("</svg></figure>");
    Ok(output)
}

fn node_width_for_label(label: &str) -> usize {
    (text_width(label) + 32).max(96)
}

fn text_width(text: &str) -> usize {
    text.chars()
        .map(|character| if character.is_ascii() { 8 } else { 14 })
        .sum()
}

#[allow(clippy::too_many_arguments)]
fn edge_path(
    direction: Direction,
    from: NodeLayout,
    to: NodeLayout,
    canvas_size: (usize, usize),
    from_index: usize,
    to_index: usize,
    edge_index: usize,
) -> (String, usize, usize, bool) {
    let is_adjacent_forward = to_index == from_index + 1;
    match direction {
        Direction::Horizontal if is_adjacent_forward => {
            let start = (from.x + from.width, from.y + from.height / 2);
            let end = (to.x, to.y + to.height / 2);
            (
                format!("M {} {} L {} {}", start.0, start.1, end.0, end.1),
                usize::midpoint(start.0, end.0),
                usize::midpoint(start.1, end.1),
                false,
            )
        }
        Direction::Horizontal => {
            let forward = to.x > from.x;
            let start = if forward {
                (from.x + from.width, from.y + from.height / 2)
            } else {
                (from.x, from.y + from.height / 2)
            };
            let end = if forward {
                (to.x, to.y + to.height / 2)
            } else {
                (to.x + to.width, to.y + to.height / 2)
            };
            let lane_offset = [0, 14][(edge_index / 2) % 2];
            let lane = if edge_index.is_multiple_of(2) {
                22 + lane_offset
            } else {
                canvas_size.1.saturating_sub(22 + lane_offset)
            };
            let exit = if forward {
                start.0 + 28
            } else {
                start.0.saturating_sub(28)
            };
            let entrance = if forward {
                end.0.saturating_sub(28)
            } else {
                end.0 + 28
            };
            (
                format!(
                    "M {} {} H {exit} V {lane} H {entrance} V {} H {}",
                    start.0, start.1, end.1, end.0
                ),
                usize::midpoint(exit, entrance),
                lane,
                true,
            )
        }
        Direction::Vertical if is_adjacent_forward => {
            let start = (from.x + from.width / 2, from.y + from.height);
            let end = (to.x + to.width / 2, to.y);
            (
                format!("M {} {} L {} {}", start.0, start.1, end.0, end.1),
                usize::midpoint(start.0, end.0),
                usize::midpoint(start.1, end.1),
                false,
            )
        }
        Direction::Vertical => {
            let forward = to.y > from.y;
            let start = if forward {
                (from.x + from.width / 2, from.y + from.height)
            } else {
                (from.x + from.width / 2, from.y)
            };
            let end = if forward {
                (to.x + to.width / 2, to.y)
            } else {
                (to.x + to.width / 2, to.y + to.height)
            };
            let lane_offset = [0, 18][(edge_index / 2) % 2];
            let lane = if edge_index.is_multiple_of(2) {
                35 + lane_offset
            } else {
                canvas_size.0.saturating_sub(35 + lane_offset)
            };
            let exit = if forward {
                start.1 + 28
            } else {
                start.1.saturating_sub(28)
            };
            let entrance = if forward {
                end.1.saturating_sub(28)
            } else {
                end.1 + 28
            };
            (
                format!(
                    "M {} {} V {exit} H {lane} V {entrance} H {} V {}",
                    start.0, start.1, end.0, end.1
                ),
                lane,
                usize::midpoint(exit, entrance),
                true,
            )
        }
    }
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
        MermaidError::UnsupportedType => "当前仅支持 flowchart 与 stateDiagram-v2。",
        MermaidError::InvalidSyntax => "请检查图表声明、节点和连接语法。",
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

    #[test]
    fn renders_two_personal_milestone_diagram_types() {
        for source in [
            "flowchart TD\nA[开始] -->|继续| B[结束]",
            "stateDiagram-v2\n[*] --> Ready\nReady --> [*]",
        ] {
            let output = svg(source).expect("supported diagram");
            assert!(output.contains("<svg"));
            assert!(output.contains("marker-end"));
            assert!(!output.contains("<script"));
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
    fn renders_repository_flowcharts_with_labelled_dashed_edges() {
        let source = r#"flowchart LR
    A["content"] --> B["result"]
    F["personalization"] -.贯穿.-> A
    F -.贯穿.-> B
    G["extensions"] -.服务.-> B"#;

        let output = svg(source).expect("repository flowchart syntax");

        assert!(output.contains("stroke-dasharray=\"6 5\""));
        assert_eq!(output.matches("class=\"edge-label\"").count(), 3);
        assert_eq!(output.matches("class=\"edge-label-background\"").count(), 3);
        assert!(
            output.rfind("marker-end").expect("last edge")
                < output
                    .find("class=\"edge-label-background\"")
                    .expect("first label background"),
            "edge labels must paint after every connector"
        );
        assert!(output.contains(">贯穿</text>"));
        assert!(output.contains(">服务</text>"));
        assert!(!output.contains("mermaid-error"));
    }

    #[test]
    fn routes_non_adjacent_edges_around_intermediate_nodes() {
        let output = svg("flowchart LR\nA --> B\nB --> C\nA -->|跳过| C").expect("supported graph");

        assert!(output.contains("width=\"508\" height=\"190\""));
        assert!(output.contains("class=\"edge edge-routed\""));
        assert!(output.contains(" H "));
        assert!(output.contains(" V "));
        assert!(output.contains(">跳过</text>"));
    }

    #[test]
    fn sizes_nodes_from_labels_and_keeps_edges_outside_node_interiors() {
        let label = "接手文件 → 形成内容 → 理解结构 → 验证结果";
        let output =
            svg(&format!("flowchart LR\nA[开始] --> B[{label}]")).expect("supported graph");
        let expected_width = node_width_for_label(label);

        assert!(expected_width > 150);
        assert!(output.contains(&format!("width=\"{expected_width}\" height=\"52\"")));
        assert!(output.contains("d=\"M 136 95 L 206 95\""));
        let edge_position = output.find("class=\"edge\"").expect("edge");
        let node_position = output.find("class=\"node\"").expect("node");
        assert!(
            edge_position < node_position,
            "opaque nodes must paint above edges"
        );
    }

    #[test]
    fn rejects_mermaid_types_outside_the_personal_milestone() {
        for source in [
            "graph LR\nA --> B",
            "stateDiagram\n[*] --> Ready",
            "sequenceDiagram\nAlice->>Bob: 你好",
            "classDiagram\nAnimal <|-- Duck",
            "pie\ntitle Values",
        ] {
            assert_eq!(svg(source), Err(MermaidError::UnsupportedType));
        }
    }

    #[test]
    fn escapes_content_and_returns_local_fallback_for_invalid_diagram() {
        let source = "flowchart TD\nA[<script>] --> B";
        let output = svg(source).expect("valid structure");
        assert!(output.contains("&lt;script&gt;"));
        assert!(!output.contains("<script>"));

        let error = svg("pie\ntitle Unsafe").expect_err("unsupported diagram");
        let fallback = fallback("pie\n<script>", &error);
        assert!(fallback.contains("无法呈现这个图表"));
        assert!(fallback.contains("当前仅支持 flowchart 与 stateDiagram-v2。"));
        assert!(!fallback.contains("时序图"));
        assert!(!fallback.contains("类图"));
        assert!(fallback.contains("&lt;script&gt;"));
        assert!(!fallback.contains("<script>"));
    }
}
