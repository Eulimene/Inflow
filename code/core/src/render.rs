//! Safe Markdown-to-HTML rendering shared by platform clients.

use pulldown_cmark::{Event, Options, Parser, html};

pub fn html_fragment(markdown: &str) -> String {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);

    let events = Parser::new_ext(markdown, options).map(sanitize_event);
    let mut output = String::with_capacity(markdown.len());
    html::push_html(&mut output, events);
    output
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
}
