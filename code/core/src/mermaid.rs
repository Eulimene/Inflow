//! Deterministic, offline renderer for the launch-scope Mermaid diagram types.

use std::fmt::Write as _;

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

#[derive(Debug, Eq, PartialEq)]
pub enum MermaidError {
    UnsupportedType,
    InvalidSyntax,
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

fn render(diagram: &Diagram, source: &str) -> Result<String, MermaidError> {
    let node_width = 150usize;
    let node_height = 52usize;
    let spacing = 70usize;
    let (width, height) = match diagram.direction {
        Direction::Horizontal => (60 + diagram.nodes.len() * (node_width + spacing), 190usize),
        Direction::Vertical => (430usize, 50 + diagram.nodes.len() * (node_height + spacing)),
    };
    let positions: Vec<(usize, usize)> = (0..diagram.nodes.len())
        .map(|index| match diagram.direction {
            Direction::Horizontal => (40 + index * (node_width + spacing), 65),
            Direction::Vertical => (140, 30 + index * (node_height + spacing)),
        })
        .collect();
    let mut output = format!(
        "<figure class=\"mermaid-diagram\" aria-label=\"{}\"><svg xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" viewBox=\"0 0 {width} {height}\" aria-label=\"{}\"><defs><marker id=\"inflow-arrow\" markerWidth=\"10\" markerHeight=\"10\" refX=\"9\" refY=\"3\" orient=\"auto\"><path d=\"M0,0 L0,6 L9,3 z\" fill=\"currentColor\"/></marker></defs>",
        diagram.kind,
        escape(source)
    );
    for edge in &diagram.edges {
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
        let (from_x, from_y) = positions[from_index];
        let (to_x, to_y) = positions[to_index];
        let (x1, y1, x2, y2) = match diagram.direction {
            Direction::Horizontal => (
                from_x + node_width,
                from_y + node_height / 2,
                to_x,
                to_y + node_height / 2,
            ),
            Direction::Vertical => (
                from_x + node_width / 2,
                from_y + node_height,
                to_x + node_width / 2,
                to_y,
            ),
        };
        let dash = if edge.dashed {
            " stroke-dasharray=\"6 5\""
        } else {
            ""
        };
        let _ = write!(
            output,
            "<line x1=\"{x1}\" y1=\"{y1}\" x2=\"{x2}\" y2=\"{y2}\" stroke=\"currentColor\" stroke-width=\"2\"{dash} marker-end=\"url(#inflow-arrow)\"/>"
        );
        if !edge.label.is_empty() {
            let _ = write!(
                output,
                "<text x=\"{}\" y=\"{}\" text-anchor=\"middle\" class=\"edge-label\">{}</text>",
                usize::midpoint(x1, x2),
                usize::midpoint(y1, y2).saturating_sub(7),
                escape(&edge.label)
            );
        }
    }
    for (node, (x, y)) in diagram.nodes.iter().zip(positions) {
        let _ = write!(
            output,
            "<g class=\"node\"><rect x=\"{x}\" y=\"{y}\" width=\"{node_width}\" height=\"{node_height}\" rx=\"9\"/><text x=\"{}\" y=\"{}\" text-anchor=\"middle\" dominant-baseline=\"middle\">{}</text></g>",
            x + node_width / 2,
            y + node_height / 2,
            escape(&node.label)
        );
    }
    output.push_str("</svg></figure>");
    Ok(output)
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
    fn renders_repository_flowcharts_with_labelled_dashed_edges() {
        let source = r#"flowchart LR
    A["content"] --> B["result"]
    F["personalization"] -.贯穿.-> A
    F -.贯穿.-> B
    G["extensions"] -.服务.-> B"#;

        let output = svg(source).expect("repository flowchart syntax");

        assert!(output.contains("stroke-dasharray=\"6 5\""));
        assert_eq!(output.matches("class=\"edge-label\"").count(), 3);
        assert!(output.contains(">贯穿</text>"));
        assert!(output.contains(">服务</text>"));
        assert!(!output.contains("mermaid-error"));
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
