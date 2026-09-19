//! TeX is interpreted by the offline `MathJax` adapter, never by a partial Rust parser.
pub fn placeholder(source: &str, display: bool) -> String {
    let tag = if display { "div" } else { "span" };
    let body = source
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    format!(
        "<{tag} class=\"inflow-math\" data-inflow-render=\"math\" data-display=\"{display}\">{body}</{tag}>"
    )
}
