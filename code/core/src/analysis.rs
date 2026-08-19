//! Document structure and statistics shared by platform clients.

use std::ops::Range;

use pulldown_cmark::{Event, HeadingLevel, Parser, Tag, TagEnd};
use unicode_segmentation::UnicodeSegmentation;

use crate::render;

#[derive(Debug, Eq, PartialEq)]
pub struct Heading {
    pub level: u8,
    pub title: String,
    pub source_range: Range<usize>,
}

#[derive(Debug, Eq, PartialEq)]
pub struct DocumentAnalysis {
    pub headings: Vec<Heading>,
    pub word_count: u64,
    pub character_count_with_spaces: u64,
    pub character_count_without_spaces: u64,
}

struct ActiveHeading {
    level: u8,
    title: String,
    source_start: usize,
}

pub fn analyze(markdown: &str) -> DocumentAnalysis {
    let mut headings = Vec::new();
    let mut active_heading: Option<ActiveHeading> = None;
    let mut plain_text = String::with_capacity(markdown.len());
    let mut visible_text = String::with_capacity(markdown.len());

    for (event, source_range) in Parser::new_ext(markdown, render::options()).into_offset_iter() {
        match &event {
            Event::Start(Tag::Heading { level, .. }) => {
                active_heading = Some(ActiveHeading {
                    level: heading_level(*level),
                    title: String::new(),
                    source_start: source_range.start,
                });
            }
            Event::End(TagEnd::Heading(_)) => {
                if let Some(active) = active_heading.take() {
                    let source_end = trim_line_ending(markdown, source_range.end);
                    headings.push(Heading {
                        level: active.level,
                        title: active.title.trim().to_owned(),
                        source_range: active.source_start..source_end,
                    });
                }
                plain_text.push(' ');
            }
            Event::Text(text) | Event::Code(text) | Event::Html(text) | Event::InlineHtml(text) => {
                plain_text.push_str(text);
                visible_text.push_str(text);
                if let Some(active) = &mut active_heading {
                    active.title.push_str(text);
                }
            }
            Event::SoftBreak | Event::HardBreak => {
                plain_text.push(' ');
                if let Some(active) = &mut active_heading {
                    active.title.push(' ');
                }
            }
            Event::End(
                TagEnd::Paragraph
                | TagEnd::Item
                | TagEnd::TableCell
                | TagEnd::TableRow
                | TagEnd::CodeBlock,
            ) => plain_text.push(' '),
            _ => {}
        }
    }

    let (character_count_with_spaces, character_count_without_spaces) =
        character_counts(&visible_text);

    DocumentAnalysis {
        headings,
        word_count: word_count(&plain_text),
        character_count_with_spaces,
        character_count_without_spaces,
    }
}

fn trim_line_ending(markdown: &str, mut end: usize) -> usize {
    let bytes = markdown.as_bytes();
    while end > 0 && matches!(bytes[end - 1], b'\n' | b'\r') {
        end -= 1;
    }
    end
}

fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

fn word_count(text: &str) -> u64 {
    let mut count = 0_u64;
    let mut in_non_cjk_word = false;

    for grapheme in text.graphemes(true) {
        if grapheme.chars().any(is_cjk) {
            in_non_cjk_word = false;
            count += 1;
        } else if grapheme.chars().any(char::is_alphanumeric) {
            if !in_non_cjk_word {
                count += 1;
                in_non_cjk_word = true;
            }
        } else {
            in_non_cjk_word = false;
        }
    }

    count
}

fn character_counts(text: &str) -> (u64, u64) {
    let mut with_spaces = 0_u64;
    let mut without_spaces = 0_u64;

    for grapheme in text.graphemes(true) {
        if grapheme == "\n" || grapheme == "\r\n" || grapheme == "\r" {
            continue;
        }

        with_spaces += 1;
        if !grapheme.chars().all(char::is_whitespace) {
            without_spaces += 1;
        }
    }

    (with_spaces, without_spaces)
}

fn is_cjk(character: char) -> bool {
    matches!(
        character as u32,
        0x1100..=0x11FF
            | 0x2E80..=0x2FFF
            | 0x3040..=0x30FF
            | 0x31F0..=0x31FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xAC00..=0xD7AF
            | 0xF900..=0xFAFF
            | 0x20000..=0x2FA1F
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_repeated_unicode_headings_by_source_range() {
        let markdown = "# 概览\n\nText\n\n## Same\n\n## Same\n\n### 🚀 Code\n";
        let result = analyze(markdown);

        assert_eq!(result.headings.len(), 4);
        assert_eq!(result.headings[0].level, 1);
        assert_eq!(result.headings[0].title, "概览");
        assert_eq!(result.headings[1].title, "Same");
        assert_eq!(result.headings[2].title, "Same");
        assert_ne!(
            result.headings[1].source_range.start,
            result.headings[2].source_range.start
        );
        assert_eq!(
            &markdown[result.headings[3].source_range.clone()],
            "### 🚀 Code"
        );
    }

    #[test]
    fn ignores_heading_syntax_inside_code_fences() {
        let result = analyze("# Real\n\n```md\n# Not a heading\n```\n");

        assert_eq!(result.headings.len(), 1);
        assert_eq!(result.headings[0].title, "Real");
    }

    #[test]
    fn supports_setext_headings_closing_hashes_and_crlf_ranges() {
        let markdown = "Setext\r\n======\r\n\r\n## ATX ##\r\n";
        let result = analyze(markdown);

        assert_eq!(result.headings.len(), 2);
        assert_eq!(result.headings[0].level, 1);
        assert_eq!(result.headings[0].title, "Setext");
        assert_eq!(
            &markdown[result.headings[0].source_range.clone()],
            "Setext\r\n======"
        );
        assert_eq!(result.headings[1].title, "ATX");
        assert_eq!(
            &markdown[result.headings[1].source_range.clone()],
            "## ATX ##"
        );
    }

    #[test]
    fn counts_cjk_characters_and_latin_number_runs() {
        let result = analyze("你好 world 123，世界");

        assert_eq!(result.word_count, 6);
    }

    #[test]
    fn counts_user_perceived_characters_and_excludes_newlines() {
        let result = analyze("A👨‍👩‍👧‍👦 中\n");

        assert_eq!(result.character_count_with_spaces, 4);
        assert_eq!(result.character_count_without_spaces, 3);
    }

    #[test]
    fn does_not_count_markdown_link_destination_as_words() {
        let result = analyze("[OpenAI](https://example.com/private/path)");

        assert_eq!(result.word_count, 1);
        assert_eq!(result.character_count_with_spaces, 6);
        assert_eq!(result.character_count_without_spaces, 6);
    }

    #[test]
    fn analyzes_megabyte_document_without_losing_last_heading() {
        let body_line = format!("word 你好 {}\n", "x".repeat(72));
        let body = body_line.repeat(12_000);
        let markdown = format!("# First\n\n{body}\n\n## Last\n");
        assert!(markdown.len() > 1_000_000);
        assert!(markdown.lines().count() > 10_000);

        let result = analyze(&markdown);
        let html = render::html_fragment(&markdown);

        assert_eq!(result.headings.len(), 2);
        assert_eq!(result.headings[1].title, "Last");
        assert_eq!(result.word_count, 48_002);
        assert!(html.ends_with("<h2>Last</h2>\n"));
    }
}
