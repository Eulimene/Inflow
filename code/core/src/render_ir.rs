//! Platform-neutral render blocks derived from one owned Markdown parse.

use std::collections::HashMap;

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Tag, TagEnd};
use serde::Serialize;

use crate::markdown_ir::DocumentIr;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RenderIr {
    pub blocks: Vec<RenderBlock>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RenderBlock {
    pub block_id: String,
    pub kind: RenderBlockKind,
    pub source_range: RenderSourceRange,
    pub depth: u32,
    pub parent_id: Option<String>,
    pub visible_text: String,
    pub heading_level: Option<u8>,
    pub code_language: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RenderBlockKind {
    Paragraph,
    Heading,
    BlockQuote,
    CodeBlock,
    OrderedList,
    UnorderedList,
    ListItem,
    Table,
    TableHead,
    TableRow,
    TableCell,
    FootnoteDefinition,
    HtmlBlock,
    DefinitionList,
    DefinitionTitle,
    DefinitionDefinition,
    MetadataBlock,
    Rule,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RenderSourceRange {
    pub start: usize,
    pub end: usize,
}

struct BlockDescriptor {
    kind: RenderBlockKind,
    heading_level: Option<u8>,
    code_language: Option<String>,
}

impl RenderIr {
    pub fn from_document(document: &DocumentIr) -> Self {
        let mut blocks: Vec<RenderBlock> = Vec::new();
        let mut active_blocks: Vec<usize> = Vec::new();
        let mut occurrences: HashMap<String, u32> = HashMap::new();

        for located in document.events() {
            match &located.event {
                Event::Start(tag) => {
                    if let Some(descriptor) = block_descriptor(tag) {
                        let parent_id = active_blocks
                            .last()
                            .map(|index| blocks[*index].block_id.clone());
                        let block_id = stable_block_id(
                            descriptor.kind,
                            document
                                .source()
                                .get(located.source_range.clone())
                                .unwrap_or_default(),
                            parent_id.as_deref(),
                            &mut occurrences,
                        );
                        let index = blocks.len();
                        blocks.push(RenderBlock {
                            block_id,
                            kind: descriptor.kind,
                            source_range: RenderSourceRange {
                                start: located.source_range.start,
                                end: located.source_range.end,
                            },
                            depth: u32::try_from(active_blocks.len()).unwrap_or(u32::MAX),
                            parent_id,
                            visible_text: String::new(),
                            heading_level: descriptor.heading_level,
                            code_language: descriptor.code_language,
                        });
                        active_blocks.push(index);
                    }
                }
                Event::End(tag) if is_block_end(*tag) => {
                    active_blocks.pop();
                }
                Event::InlineHtml(text)
                    if crate::render::is_safe_line_break(text)
                        && active_blocks
                            .iter()
                            .any(|index| blocks[*index].kind == RenderBlockKind::TableCell) =>
                {
                    for index in &active_blocks {
                        blocks[*index].visible_text.push('\n');
                    }
                }
                Event::Text(text)
                | Event::Code(text)
                | Event::InlineMath(text)
                | Event::DisplayMath(text)
                | Event::Html(text)
                | Event::InlineHtml(text) => {
                    for index in &active_blocks {
                        blocks[*index].visible_text.push_str(text);
                    }
                }
                Event::SoftBreak | Event::HardBreak => {
                    for index in &active_blocks {
                        blocks[*index].visible_text.push('\n');
                    }
                }
                Event::Rule => {
                    let parent_id = active_blocks
                        .last()
                        .map(|index| blocks[*index].block_id.clone());
                    let block_id = stable_block_id(
                        RenderBlockKind::Rule,
                        document
                            .source()
                            .get(located.source_range.clone())
                            .unwrap_or_default(),
                        parent_id.as_deref(),
                        &mut occurrences,
                    );
                    blocks.push(RenderBlock {
                        block_id,
                        kind: RenderBlockKind::Rule,
                        source_range: RenderSourceRange {
                            start: located.source_range.start,
                            end: located.source_range.end,
                        },
                        depth: u32::try_from(active_blocks.len()).unwrap_or(u32::MAX),
                        parent_id,
                        visible_text: String::new(),
                        heading_level: None,
                        code_language: None,
                    });
                }
                Event::TaskListMarker(_) | Event::FootnoteReference(_) | Event::End(_) => {}
            }
        }

        Self { blocks }
    }
}

fn block_descriptor(tag: &Tag<'_>) -> Option<BlockDescriptor> {
    let descriptor = match tag {
        Tag::Paragraph => BlockDescriptor::plain(RenderBlockKind::Paragraph),
        Tag::Heading { level, .. } => BlockDescriptor {
            kind: RenderBlockKind::Heading,
            heading_level: Some(heading_level(*level)),
            code_language: None,
        },
        Tag::BlockQuote(_) => BlockDescriptor::plain(RenderBlockKind::BlockQuote),
        Tag::CodeBlock(kind) => BlockDescriptor {
            kind: RenderBlockKind::CodeBlock,
            heading_level: None,
            code_language: code_language(kind),
        },
        Tag::List(Some(_)) => BlockDescriptor::plain(RenderBlockKind::OrderedList),
        Tag::List(None) => BlockDescriptor::plain(RenderBlockKind::UnorderedList),
        Tag::Item => BlockDescriptor::plain(RenderBlockKind::ListItem),
        Tag::Table(_) => BlockDescriptor::plain(RenderBlockKind::Table),
        Tag::TableHead => BlockDescriptor::plain(RenderBlockKind::TableHead),
        Tag::TableRow => BlockDescriptor::plain(RenderBlockKind::TableRow),
        Tag::TableCell => BlockDescriptor::plain(RenderBlockKind::TableCell),
        Tag::FootnoteDefinition(_) => BlockDescriptor::plain(RenderBlockKind::FootnoteDefinition),
        Tag::HtmlBlock => BlockDescriptor::plain(RenderBlockKind::HtmlBlock),
        Tag::DefinitionList => BlockDescriptor::plain(RenderBlockKind::DefinitionList),
        Tag::DefinitionListTitle => BlockDescriptor::plain(RenderBlockKind::DefinitionTitle),
        Tag::DefinitionListDefinition => {
            BlockDescriptor::plain(RenderBlockKind::DefinitionDefinition)
        }
        Tag::MetadataBlock(_) => BlockDescriptor::plain(RenderBlockKind::MetadataBlock),
        Tag::Emphasis
        | Tag::Strong
        | Tag::Strikethrough
        | Tag::Link { .. }
        | Tag::Image { .. }
        | Tag::Superscript
        | Tag::Subscript => return None,
    };
    Some(descriptor)
}

impl BlockDescriptor {
    const fn plain(kind: RenderBlockKind) -> Self {
        Self {
            kind,
            heading_level: None,
            code_language: None,
        }
    }
}

fn code_language(kind: &CodeBlockKind<'_>) -> Option<String> {
    match kind {
        CodeBlockKind::Indented => None,
        CodeBlockKind::Fenced(info) => info
            .split_ascii_whitespace()
            .next()
            .filter(|language| !language.is_empty())
            .map(str::to_owned),
    }
}

const fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
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

fn stable_block_id(
    kind: RenderBlockKind,
    source: &str,
    parent_id: Option<&str>,
    occurrences: &mut HashMap<String, u32>,
) -> String {
    let kind_name = format!("{kind:?}");
    let mut hash = fnv1a(kind_name.as_bytes());
    hash = fnv1a_continue(hash, source.as_bytes());
    if let Some(parent_id) = parent_id {
        hash = fnv1a_continue(hash, parent_id.as_bytes());
    }
    let base = format!("{kind:?}-{hash:016x}").to_ascii_lowercase();
    let occurrence = occurrences.entry(base.clone()).or_default();
    let block_id = format!("{base}-{occurrence}");
    *occurrence = occurrence.saturating_add(1);
    block_id
}

fn fnv1a(bytes: &[u8]) -> u64 {
    fnv1a_continue(0xcbf2_9ce4_8422_2325, bytes)
}

fn fnv1a_continue(mut hash: u64, bytes: &[u8]) -> u64 {
    for byte in bytes {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markdown_ir::dialect_options;

    #[test]
    fn builds_unicode_blocks_with_visible_text_and_exact_ranges() {
        let source = "# 标题\n\n> 正文 **加粗**\n\n```rust\nlet 值 = 1;\n```\n";
        let document = DocumentIr::parse(source, dialect_options(true));
        let render = RenderIr::from_document(&document);

        let heading = render
            .blocks
            .iter()
            .find(|block| block.kind == RenderBlockKind::Heading)
            .expect("heading block");
        assert_eq!(heading.heading_level, Some(1));
        assert_eq!(heading.visible_text, "标题");
        assert_eq!(
            &source[heading.source_range.start..heading.source_range.end],
            "# 标题\n"
        );

        let code = render
            .blocks
            .iter()
            .find(|block| block.kind == RenderBlockKind::CodeBlock)
            .expect("code block");
        assert_eq!(code.code_language.as_deref(), Some("rust"));
        assert!(code.visible_text.contains("let 值 = 1;"));
        assert!(render.blocks.iter().all(|block| {
            source
                .get(block.source_range.start..block.source_range.end)
                .is_some()
        }));
    }

    #[test]
    fn unrelated_prefix_insertions_do_not_change_a_top_level_block_id() {
        let original = DocumentIr::parse("Second **bold**\n", dialect_options(true));
        let prefixed = DocumentIr::parse("First\n\nSecond **bold**\n", dialect_options(true));
        let original_render = RenderIr::from_document(&original);
        let prefixed_render = RenderIr::from_document(&prefixed);

        let original_id = &original_render
            .blocks
            .iter()
            .find(|block| block.visible_text == "Second bold")
            .expect("original paragraph")
            .block_id;
        let prefixed_id = &prefixed_render
            .blocks
            .iter()
            .find(|block| block.visible_text == "Second bold")
            .expect("prefixed paragraph")
            .block_id;
        assert_eq!(original_id, prefixed_id);
    }
}
