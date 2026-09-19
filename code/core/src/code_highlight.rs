//! `CodeMirror` owns language grammars; Rust only emits escaped source.
pub(crate) fn supports_language(info: &str) -> bool {
    !info.trim().is_empty()
}
pub(crate) fn highlighted_code_block(info: &str, source: &str) -> Option<String> {
    let language = info.split_ascii_whitespace().next()?;
    let escape = |s: &str| {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
    };
    Some(format!(
        "<pre><code class=\"language-{} inflow-code-highlight\" data-inflow-render=\"code\" data-language=\"{}\">{}</code></pre>\n",
        escape(language),
        escape(language),
        escape(source)
    ))
}
