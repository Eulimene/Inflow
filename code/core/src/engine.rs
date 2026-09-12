//! Stateful editor authority introduced behind the macOS shadow-mode bridge.

use std::collections::HashMap;
use std::ops::Range;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

use crate::analysis::{DocumentAnalysis, analyze_document};
use crate::format::{self, FormatError, InlineFormat, ListFormat, MarkdownEdit};
use crate::highlight::{HighlightSpan, spans_from_document};
use crate::markdown_ir::{DocumentIr, dialect_options};
use crate::native_render::NativeRenderPlan;
use crate::reference::{MarkdownReference, references_from_document};
use crate::render::{RenderConfiguration, html_fragment_for_preview_from_document};
use crate::render_ir::RenderIr;
use crate::search::find_literal;

pub const ENGINE_SCHEMA_VERSION: u32 = 1;

pub type Revision = u64;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ByteRange {
    pub start: usize,
    pub end: usize,
}

impl ByteRange {
    fn as_range(&self) -> Range<usize> {
        self.start..self.end
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EngineCreateRequest {
    pub schema_version: u32,
    pub document_id: String,
    pub text: String,
    pub selection: Selection,
    #[serde(default)]
    pub mode: EditorMode,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandEnvelope {
    pub schema_version: u32,
    pub request_id: String,
    pub command: EditorCommand,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EditorCommand {
    ReplaceText {
        base_revision: Revision,
        range: ByteRange,
        inserted: String,
        selection_after: Selection,
        #[serde(default)]
        group_id: Option<String>,
    },
    RefreshDerived {
        revision: Revision,
        #[serde(default = "default_true")]
        math_enabled: bool,
        #[serde(default = "default_true")]
        mermaid_enabled: bool,
    },
    Format {
        base_revision: Revision,
        selection: Selection,
        operation: FormatOperation,
    },
    Undo {
        base_revision: Revision,
    },
    Redo {
        base_revision: Revision,
    },
    Search {
        revision: Revision,
        query: String,
        case_sensitive: bool,
    },
    InspectFormat {
        revision: Revision,
        selection: Selection,
    },
    PrepareSave {
        revision: Revision,
        save_id: String,
    },
    SaveCompleted {
        save_id: String,
    },
    SaveAborted {
        save_id: String,
    },
    SetMode {
        revision: Revision,
        mode: EditorMode,
    },
}

const fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FormatOperation {
    Bold,
    Italic,
    Strikethrough,
    InlineCode,
    CodeBlock,
    Clear,
    Heading {
        level: u8,
    },
    BlockQuote,
    List {
        style: ListStyle,
    },
    Link {
        destination: String,
    },
    Image {
        destination: String,
        default_alternative: String,
    },
    Table,
    HorizontalRule,
    Footnote,
    Math,
    Mermaid,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ListStyle {
    Unordered,
    Ordered,
    Task,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EditorMode {
    #[default]
    Editable,
    ReadOnly,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct EngineSnapshot {
    pub schema_version: u32,
    pub document_id: String,
    pub revision: Revision,
    pub text: String,
    pub selection: Selection,
    pub mode: EditorMode,
    pub content_hash: String,
    pub derived: Option<DerivedState>,
    pub can_undo: bool,
    pub can_redo: bool,
    pub dirty: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StatePatch {
    pub base_revision: Revision,
    pub revision: Revision,
    pub mode: EditorMode,
    pub text: Option<TextPatch>,
    pub selection: Option<Selection>,
    pub derived: Option<DerivedState>,
    pub search: Option<SearchResult>,
    pub format_capabilities: Option<FormatCapabilities>,
    pub save_preparation: Option<SavePreparation>,
    pub content_hash: String,
    pub can_undo: bool,
    pub can_redo: bool,
    pub dirty: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SearchResult {
    pub revision: Revision,
    pub matches: Vec<ByteRange>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FormatCapabilities {
    pub revision: Revision,
    pub can_clear: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SavePreparation {
    pub save_id: String,
    pub revision: Revision,
    pub text: String,
    pub content_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct TextPatch {
    pub range: ByteRange,
    pub inserted: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DerivedState {
    pub revision: Revision,
    pub analysis: DocumentAnalysis,
    pub highlights: Vec<HighlightSpan>,
    pub references: Vec<MarkdownReference>,
    pub render: RenderIr,
    pub native_render: NativeRenderPlan,
    pub html_fragment: String,
    pub math_enabled: bool,
    pub mermaid_enabled: bool,
}

#[derive(Debug, Eq, PartialEq, Serialize)]
pub struct DispatchResponse {
    pub schema_version: u32,
    pub request_id: String,
    pub patch: StatePatch,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EngineError {
    UnsupportedSchema,
    EmptyDocumentId,
    EmptyRequestId,
    RevisionConflict,
    InvalidRange,
    InvalidSelection,
    AmbiguousFormat,
    NothingToUndo,
    NothingToRedo,
    EmptySaveId,
    UnknownSave,
    ReadOnly,
    RevisionOverflow,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HistoryEntry {
    forward: TextPatch,
    inverse: TextPatch,
    selection_before: Selection,
    selection_after: Selection,
    group_id: Option<String>,
}

pub struct EditorEngine {
    document_id: String,
    revision: Revision,
    text: String,
    selection: Selection,
    mode: EditorMode,
    derived: Option<DerivedState>,
    undo: Vec<HistoryEntry>,
    redo: Vec<HistoryEntry>,
    saved_content_hash: String,
    prepared_saves: HashMap<String, String>,
}

impl EditorEngine {
    pub fn create(request: EngineCreateRequest) -> Result<Self, EngineError> {
        if request.schema_version != ENGINE_SCHEMA_VERSION {
            return Err(EngineError::UnsupportedSchema);
        }
        if request.document_id.is_empty() {
            return Err(EngineError::EmptyDocumentId);
        }
        validate_selection(&request.text, &request.selection)?;

        let saved_content_hash = content_hash(&request.text);
        Ok(Self {
            document_id: request.document_id,
            revision: 0,
            text: request.text,
            selection: request.selection,
            mode: request.mode,
            derived: None,
            undo: Vec::new(),
            redo: Vec::new(),
            saved_content_hash,
            prepared_saves: HashMap::new(),
        })
    }

    pub fn dispatch(&mut self, envelope: CommandEnvelope) -> Result<DispatchResponse, EngineError> {
        if envelope.schema_version != ENGINE_SCHEMA_VERSION {
            return Err(EngineError::UnsupportedSchema);
        }
        if envelope.request_id.is_empty() {
            return Err(EngineError::EmptyRequestId);
        }

        let request_id = envelope.request_id;
        let patch = match envelope.command {
            EditorCommand::ReplaceText {
                base_revision,
                range,
                inserted,
                selection_after,
                group_id,
            } => self.replace_text(base_revision, range, inserted, selection_after, group_id)?,
            EditorCommand::RefreshDerived {
                revision,
                math_enabled,
                mermaid_enabled,
            } => self.refresh_derived(revision, math_enabled, mermaid_enabled)?,
            EditorCommand::Format {
                base_revision,
                selection,
                operation,
            } => self.format(base_revision, &selection, operation)?,
            EditorCommand::Undo { base_revision } => self.undo(base_revision)?,
            EditorCommand::Redo { base_revision } => self.redo(base_revision)?,
            EditorCommand::Search {
                revision,
                query,
                case_sensitive,
            } => self.search(revision, &query, case_sensitive)?,
            EditorCommand::InspectFormat {
                revision,
                selection,
            } => self.inspect_format(revision, &selection)?,
            EditorCommand::PrepareSave { revision, save_id } => {
                self.prepare_save(revision, save_id)?
            }
            EditorCommand::SaveCompleted { save_id } => self.save_completed(&save_id)?,
            EditorCommand::SaveAborted { save_id } => self.save_aborted(&save_id)?,
            EditorCommand::SetMode { revision, mode } => self.set_mode(revision, mode)?,
        };

        Ok(DispatchResponse {
            schema_version: ENGINE_SCHEMA_VERSION,
            request_id,
            patch,
        })
    }

    pub fn snapshot(&self) -> EngineSnapshot {
        EngineSnapshot {
            schema_version: ENGINE_SCHEMA_VERSION,
            document_id: self.document_id.clone(),
            revision: self.revision,
            text: self.text.clone(),
            selection: self.selection.clone(),
            mode: self.mode,
            content_hash: content_hash(&self.text),
            derived: self.derived.clone(),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.is_dirty(),
        }
    }

    fn replace_text(
        &mut self,
        base_revision: Revision,
        range: ByteRange,
        inserted: String,
        selection_after: Selection,
        group_id: Option<String>,
    ) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        self.ensure_editable()?;
        validate_range(&self.text, &range)?;

        let selection_before = self.selection.clone();
        let deleted = self.text[range.as_range()].to_owned();
        let forward = TextPatch { range, inserted };
        let inverse = TextPatch {
            range: ByteRange {
                start: forward.range.start,
                end: forward.range.start + forward.inserted.len(),
            },
            inserted: deleted,
        };
        let patch = self.apply_patch(base_revision, forward.clone(), selection_after.clone())?;
        self.undo.push(HistoryEntry {
            forward,
            inverse,
            selection_before,
            selection_after,
            group_id,
        });
        self.redo.clear();
        Ok(self.with_history_state(patch))
    }

    fn refresh_derived(
        &mut self,
        revision: Revision,
        math_enabled: bool,
        mermaid_enabled: bool,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        let derived = if let Some(derived) = &self.derived
            && derived.math_enabled == math_enabled
            && derived.mermaid_enabled == mermaid_enabled
        {
            derived.clone()
        } else {
            let document = DocumentIr::parse(&self.text, dialect_options(math_enabled));
            let configuration = RenderConfiguration {
                math_enabled,
                mermaid_enabled,
            };
            let render = RenderIr::from_document(&document);
            let native_render = NativeRenderPlan::from_document(&document, &render);
            let derived = DerivedState {
                revision,
                analysis: analyze_document(&document),
                highlights: spans_from_document(&document),
                references: references_from_document(&document),
                render,
                native_render,
                html_fragment: html_fragment_for_preview_from_document(&document, configuration),
                math_enabled,
                mermaid_enabled,
            };
            self.derived = Some(derived.clone());
            derived
        };

        Ok(StatePatch {
            base_revision: revision,
            revision,
            mode: self.mode,
            text: None,
            selection: None,
            derived: Some(derived),
            search: None,
            format_capabilities: None,
            save_preparation: None,
            content_hash: content_hash(&self.text),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.is_dirty(),
        })
    }

    fn search(
        &self,
        revision: Revision,
        query: &str,
        case_sensitive: bool,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        let matches = find_literal(&self.text, query, case_sensitive)
            .into_iter()
            .map(|found| ByteRange {
                start: found.source_range.start,
                end: found.source_range.end,
            })
            .collect();
        Ok(StatePatch {
            base_revision: revision,
            revision,
            mode: self.mode,
            text: None,
            selection: None,
            derived: None,
            search: Some(SearchResult { revision, matches }),
            format_capabilities: None,
            save_preparation: None,
            content_hash: content_hash(&self.text),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.is_dirty(),
        })
    }

    fn inspect_format(
        &self,
        revision: Revision,
        selection: &Selection,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        validate_selection(&self.text, selection)?;
        let can_clear = format::clear_format(&self.text, selection.start..selection.end).is_ok();
        Ok(StatePatch {
            base_revision: revision,
            revision,
            mode: self.mode,
            text: None,
            selection: None,
            derived: None,
            search: None,
            format_capabilities: Some(FormatCapabilities {
                revision,
                can_clear,
            }),
            save_preparation: None,
            content_hash: content_hash(&self.text),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.is_dirty(),
        })
    }

    fn prepare_save(
        &mut self,
        revision: Revision,
        save_id: String,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        if save_id.is_empty() {
            return Err(EngineError::EmptySaveId);
        }
        let hash = content_hash(&self.text);
        self.prepared_saves.insert(save_id.clone(), hash.clone());
        let mut patch = self.empty_patch(revision);
        patch.save_preparation = Some(SavePreparation {
            save_id,
            revision,
            text: self.text.clone(),
            content_hash: hash,
        });
        Ok(patch)
    }

    fn save_completed(&mut self, save_id: &str) -> Result<StatePatch, EngineError> {
        if save_id.is_empty() {
            return Err(EngineError::EmptySaveId);
        }
        let saved_hash = self
            .prepared_saves
            .remove(save_id)
            .ok_or(EngineError::UnknownSave)?;
        self.saved_content_hash = saved_hash;
        Ok(self.empty_patch(self.revision))
    }

    fn save_aborted(&mut self, save_id: &str) -> Result<StatePatch, EngineError> {
        if save_id.is_empty() {
            return Err(EngineError::EmptySaveId);
        }
        self.prepared_saves
            .remove(save_id)
            .ok_or(EngineError::UnknownSave)?;
        Ok(self.empty_patch(self.revision))
    }

    fn set_mode(
        &mut self,
        revision: Revision,
        mode: EditorMode,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        self.mode = mode;
        Ok(self.empty_patch(revision))
    }

    fn format(
        &mut self,
        base_revision: Revision,
        selection: &Selection,
        operation: FormatOperation,
    ) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        validate_selection(&self.text, selection)?;
        let range = selection.start..selection.end;
        let edit = match operation {
            FormatOperation::Bold => format::format_inline(&self.text, range, InlineFormat::Bold),
            FormatOperation::Italic => {
                format::format_inline(&self.text, range, InlineFormat::Italic)
            }
            FormatOperation::Strikethrough => {
                format::format_inline(&self.text, range, InlineFormat::Strikethrough)
            }
            FormatOperation::InlineCode => format::format_inline_code(&self.text, range),
            FormatOperation::CodeBlock => format::format_code_block(&self.text, range),
            FormatOperation::Clear => format::clear_format(&self.text, range),
            FormatOperation::Heading { level } => format::format_heading(&self.text, range, level),
            FormatOperation::BlockQuote => format::format_block_quote(&self.text, range),
            FormatOperation::List { style } => format::format_list(&self.text, range, style.into()),
            FormatOperation::Link { destination } => {
                format::insert_link(&self.text, range, &destination)
            }
            FormatOperation::Image {
                destination,
                default_alternative,
            } => format::insert_image(&self.text, range, &destination, &default_alternative),
            FormatOperation::Table => format::insert_table(&self.text, range),
            FormatOperation::HorizontalRule => format::insert_horizontal_rule(&self.text, range),
            FormatOperation::Footnote => format::insert_footnote(&self.text, range),
            FormatOperation::Math => format::insert_math(&self.text, range),
            FormatOperation::Mermaid => format::insert_mermaid(&self.text, range),
        }
        .map_err(|error| match error {
            FormatError::InvalidSelection => EngineError::InvalidSelection,
            FormatError::AmbiguousSelection => EngineError::AmbiguousFormat,
        })?;
        self.apply_format_edit(base_revision, edit)
    }

    fn apply_format_edit(
        &mut self,
        base_revision: Revision,
        edit: MarkdownEdit,
    ) -> Result<StatePatch, EngineError> {
        self.replace_text(
            base_revision,
            ByteRange {
                start: edit.replace_range.start,
                end: edit.replace_range.end,
            },
            edit.replacement,
            Selection {
                start: edit.selection_range.start,
                end: edit.selection_range.end,
            },
            Some("format".to_owned()),
        )
    }

    fn undo(&mut self, base_revision: Revision) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        self.ensure_editable()?;
        let entry = self.undo.pop().ok_or(EngineError::NothingToUndo)?;
        let patch = self.apply_patch(
            base_revision,
            entry.inverse.clone(),
            entry.selection_before.clone(),
        )?;
        self.redo.push(entry);
        Ok(self.with_history_state(patch))
    }

    fn redo(&mut self, base_revision: Revision) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        self.ensure_editable()?;
        let entry = self.redo.pop().ok_or(EngineError::NothingToRedo)?;
        let patch = self.apply_patch(
            base_revision,
            entry.forward.clone(),
            entry.selection_after.clone(),
        )?;
        self.undo.push(entry);
        Ok(self.with_history_state(patch))
    }

    fn apply_patch(
        &mut self,
        base_revision: Revision,
        text: TextPatch,
        selection_after: Selection,
    ) -> Result<StatePatch, EngineError> {
        validate_range(&self.text, &text.range)?;
        let mut updated = self.text.clone();
        updated.replace_range(text.range.as_range(), &text.inserted);
        validate_selection(&updated, &selection_after)?;
        let revision = self
            .revision
            .checked_add(1)
            .ok_or(EngineError::RevisionOverflow)?;
        self.text = updated;
        self.selection = selection_after.clone();
        self.revision = revision;
        self.derived = None;
        Ok(StatePatch {
            base_revision,
            revision,
            mode: self.mode,
            text: Some(text),
            selection: Some(selection_after),
            derived: None,
            search: None,
            format_capabilities: None,
            save_preparation: None,
            content_hash: content_hash(&self.text),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.is_dirty(),
        })
    }

    fn empty_patch(&self, base_revision: Revision) -> StatePatch {
        StatePatch {
            base_revision,
            revision: self.revision,
            mode: self.mode,
            text: None,
            selection: None,
            derived: None,
            search: None,
            format_capabilities: None,
            save_preparation: None,
            content_hash: content_hash(&self.text),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.is_dirty(),
        }
    }

    fn is_dirty(&self) -> bool {
        content_hash(&self.text) != self.saved_content_hash
    }

    fn ensure_editable(&self) -> Result<(), EngineError> {
        if self.mode == EditorMode::ReadOnly {
            Err(EngineError::ReadOnly)
        } else {
            Ok(())
        }
    }

    fn with_history_state(&self, mut patch: StatePatch) -> StatePatch {
        patch.can_undo = !self.undo.is_empty();
        patch.can_redo = !self.redo.is_empty();
        patch
    }
}

impl From<ListStyle> for ListFormat {
    fn from(value: ListStyle) -> Self {
        match value {
            ListStyle::Unordered => Self::Unordered,
            ListStyle::Ordered => Self::Ordered,
            ListStyle::Task => Self::Task,
        }
    }
}

fn validate_range(text: &str, range: &ByteRange) -> Result<(), EngineError> {
    if range.start > range.end
        || range.end > text.len()
        || !is_grapheme_boundary(text, range.start)
        || !is_grapheme_boundary(text, range.end)
    {
        return Err(EngineError::InvalidRange);
    }
    Ok(())
}

fn validate_selection(text: &str, selection: &Selection) -> Result<(), EngineError> {
    if selection.start > selection.end
        || selection.end > text.len()
        || !is_grapheme_boundary(text, selection.start)
        || !is_grapheme_boundary(text, selection.end)
    {
        return Err(EngineError::InvalidSelection);
    }
    Ok(())
}

fn is_grapheme_boundary(text: &str, offset: usize) -> bool {
    offset == text.len()
        || text
            .grapheme_indices(true)
            .any(|(index, _)| index == offset)
}

fn content_hash(text: &str) -> String {
    const FNV_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

    let hash = text.as_bytes().iter().fold(FNV_OFFSET_BASIS, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(FNV_PRIME)
    });
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(text: &str) -> EditorEngine {
        EditorEngine::create(EngineCreateRequest {
            schema_version: ENGINE_SCHEMA_VERSION,
            document_id: "document-1".to_owned(),
            text: text.to_owned(),
            selection: Selection { start: 0, end: 0 },
            mode: EditorMode::Editable,
        })
        .expect("test engine should be valid")
    }

    fn replace(
        base_revision: Revision,
        range: Range<usize>,
        inserted: &str,
        selection_after: Selection,
    ) -> CommandEnvelope {
        CommandEnvelope {
            schema_version: ENGINE_SCHEMA_VERSION,
            request_id: format!("request-{base_revision}"),
            command: EditorCommand::ReplaceText {
                base_revision,
                range: ByteRange {
                    start: range.start,
                    end: range.end,
                },
                inserted: inserted.to_owned(),
                selection_after,
                group_id: None,
            },
        }
    }

    fn refresh(revision: Revision) -> CommandEnvelope {
        CommandEnvelope {
            schema_version: ENGINE_SCHEMA_VERSION,
            request_id: format!("refresh-{revision}"),
            command: EditorCommand::RefreshDerived {
                revision,
                math_enabled: true,
                mermaid_enabled: true,
            },
        }
    }

    fn command(request_id: &str, command: EditorCommand) -> CommandEnvelope {
        CommandEnvelope {
            schema_version: ENGINE_SCHEMA_VERSION,
            request_id: request_id.to_owned(),
            command,
        }
    }

    #[test]
    fn replace_text_advances_revision_and_returns_an_incremental_patch() {
        let mut engine = engine("Hello 🌍");
        let response = engine
            .dispatch(replace(0, 6..10, "世界", Selection { start: 12, end: 12 }))
            .expect("valid edit should succeed");

        assert_eq!(response.patch.base_revision, 0);
        assert_eq!(response.patch.revision, 1);
        let text = response.patch.text.expect("replacement patch");
        assert_eq!(text.range, ByteRange { start: 6, end: 10 });
        assert_eq!(text.inserted, "世界");
        assert_eq!(engine.snapshot().text, "Hello 世界");
        assert_eq!(engine.snapshot().revision, 1);
    }

    #[test]
    fn stale_command_is_rejected_without_changing_state() {
        let mut engine = engine("abc");
        engine
            .dispatch(replace(0, 3..3, "d", Selection { start: 4, end: 4 }))
            .expect("first edit should succeed");
        let before = engine.snapshot();

        let error = engine.dispatch(replace(0, 0..1, "A", Selection { start: 1, end: 1 }));

        assert_eq!(error, Err(EngineError::RevisionConflict));
        assert_eq!(engine.snapshot(), before);
    }

    #[test]
    fn edits_and_selections_must_use_extended_grapheme_boundaries() {
        let mut engine = engine("e\u{301}x");

        assert_eq!(
            engine.dispatch(replace(0, 1..3, "e", Selection { start: 1, end: 1 },)),
            Err(EngineError::InvalidRange)
        );
        assert_eq!(
            engine.dispatch(replace(0, 0..3, "e\u{301}", Selection { start: 1, end: 1 },)),
            Err(EngineError::InvalidSelection)
        );
        assert_eq!(engine.snapshot().revision, 0);
        assert_eq!(engine.snapshot().text, "e\u{301}x");
    }

    #[test]
    fn schema_and_document_identity_are_validated_at_creation() {
        let unsupported = EditorEngine::create(EngineCreateRequest {
            schema_version: ENGINE_SCHEMA_VERSION + 1,
            document_id: "document-1".to_owned(),
            text: String::new(),
            selection: Selection { start: 0, end: 0 },
            mode: EditorMode::Editable,
        });
        assert!(matches!(unsupported, Err(EngineError::UnsupportedSchema)));

        let missing_id = EditorEngine::create(EngineCreateRequest {
            schema_version: ENGINE_SCHEMA_VERSION,
            document_id: String::new(),
            text: String::new(),
            selection: Selection { start: 0, end: 0 },
            mode: EditorMode::Editable,
        });
        assert!(matches!(missing_id, Err(EngineError::EmptyDocumentId)));
    }

    #[test]
    fn refresh_derived_uses_one_revision_and_is_invalidated_by_edits() {
        let mut engine = engine("# 标题\n\n正文 **加粗** [链接](note.md)\n");

        let first = engine
            .dispatch(refresh(0))
            .expect("current revision should derive");
        let derived = first.patch.derived.expect("derived state");
        assert_eq!(first.patch.base_revision, 0);
        assert_eq!(first.patch.revision, 0);
        assert!(first.patch.text.is_none());
        assert_eq!(derived.revision, 0);
        assert_eq!(derived.analysis.headings[0].title, "标题");
        assert!(
            derived
                .highlights
                .iter()
                .any(|span| span.kind == crate::highlight::HighlightKind::Strong)
        );
        assert_eq!(derived.references[0].target, "note.md");
        assert!(derived.html_fragment.contains(">标题</h1>"));
        assert!(
            derived
                .html_fragment
                .contains("data-inflow-block-id=\"heading-")
        );
        assert!(
            derived
                .render
                .blocks
                .iter()
                .any(|block| block.visible_text.contains("正文 加粗 链接"))
        );
        assert_eq!(engine.snapshot().revision, 0);
        assert!(engine.snapshot().derived.is_some());

        engine
            .dispatch(replace(0, 0..0, "前缀\n\n", Selection { start: 0, end: 0 }))
            .expect("edit should succeed");
        assert!(engine.snapshot().derived.is_none());
        assert_eq!(
            engine.dispatch(refresh(0)),
            Err(EngineError::RevisionConflict)
        );
        assert!(engine.dispatch(refresh(1)).is_ok());
    }

    #[test]
    fn search_is_revision_bound_and_returns_grapheme_safe_ranges() {
        let mut engine = engine("Straße STRASSE e\u{301}");
        let response = engine
            .dispatch(command(
                "search",
                EditorCommand::Search {
                    revision: 0,
                    query: "strasse".to_owned(),
                    case_sensitive: false,
                },
            ))
            .expect("current revision should be searchable");
        let result = response.patch.search.expect("search result");

        assert_eq!(result.revision, 0);
        assert_eq!(
            result.matches,
            vec![
                ByteRange { start: 0, end: 7 },
                ByteRange { start: 8, end: 15 },
            ]
        );
        assert!(response.patch.text.is_none());
        assert!(response.patch.derived.is_none());

        engine
            .dispatch(replace(0, 15..15, "!", Selection { start: 16, end: 16 }))
            .expect("edit should succeed");
        assert_eq!(
            engine.dispatch(command(
                "stale-search",
                EditorCommand::Search {
                    revision: 0,
                    query: "STRASSE".to_owned(),
                    case_sensitive: true,
                },
            )),
            Err(EngineError::RevisionConflict)
        );
    }

    #[test]
    fn format_inspection_is_revision_bound_and_does_not_mutate_history() {
        let mut engine = engine("# **Title** and plain\n");
        let response = engine
            .dispatch(command(
                "inspect-format",
                EditorCommand::InspectFormat {
                    revision: 0,
                    selection: Selection { start: 0, end: 11 },
                },
            ))
            .expect("complete formatted selection should be inspectable");
        let capabilities = response
            .patch
            .format_capabilities
            .expect("format capabilities");

        assert_eq!(capabilities.revision, 0);
        assert!(capabilities.can_clear);
        assert_eq!(engine.snapshot().revision, 0);
        assert!(!engine.snapshot().can_undo);

        let plain = engine
            .dispatch(command(
                "inspect-plain",
                EditorCommand::InspectFormat {
                    revision: 0,
                    selection: Selection { start: 16, end: 21 },
                },
            ))
            .expect("plain selection should still produce capabilities");
        assert!(!plain.patch.format_capabilities.unwrap().can_clear);
    }

    #[test]
    fn save_receipts_track_the_exact_prepared_content_without_hiding_later_edits() {
        let mut engine = engine("draft");
        assert!(!engine.snapshot().dirty);
        engine
            .dispatch(replace(0, 5..5, " one", Selection { start: 9, end: 9 }))
            .expect("edit should make the document dirty");
        assert!(engine.snapshot().dirty);

        let prepared = engine
            .dispatch(command(
                "prepare-save",
                EditorCommand::PrepareSave {
                    revision: 1,
                    save_id: "save-1".to_owned(),
                },
            ))
            .expect("current revision should freeze");
        let preparation = prepared.patch.save_preparation.expect("save preparation");
        assert_eq!(preparation.revision, 1);
        assert_eq!(preparation.text, "draft one");
        assert!(prepared.patch.dirty);

        engine
            .dispatch(replace(1, 9..9, " two", Selection { start: 13, end: 13 }))
            .expect("editing may continue while the host writes");
        let completed = engine
            .dispatch(command(
                "save-completed",
                EditorCommand::SaveCompleted {
                    save_id: "save-1".to_owned(),
                },
            ))
            .expect("the exact frozen save should complete");
        assert!(completed.patch.dirty);
        assert_eq!(engine.snapshot().text, "draft one two");

        let latest = engine
            .dispatch(command(
                "prepare-latest",
                EditorCommand::PrepareSave {
                    revision: 2,
                    save_id: "save-2".to_owned(),
                },
            ))
            .expect("latest revision should freeze");
        assert_eq!(latest.patch.save_preparation.unwrap().revision, 2);
        let completed = engine
            .dispatch(command(
                "complete-latest",
                EditorCommand::SaveCompleted {
                    save_id: "save-2".to_owned(),
                },
            ))
            .expect("latest save should mark the document clean");
        assert!(!completed.patch.dirty);
        assert!(!engine.snapshot().dirty);
        assert_eq!(
            engine.dispatch(command(
                "repeat-completion",
                EditorCommand::SaveCompleted {
                    save_id: "save-2".to_owned(),
                },
            )),
            Err(EngineError::UnknownSave)
        );
    }

    #[test]
    fn aborted_save_does_not_change_dirty_state() {
        let mut engine = engine("draft");
        engine
            .dispatch(replace(0, 5..5, "!", Selection { start: 6, end: 6 }))
            .expect("edit should succeed");
        engine
            .dispatch(command(
                "prepare-save",
                EditorCommand::PrepareSave {
                    revision: 1,
                    save_id: "save-1".to_owned(),
                },
            ))
            .expect("save should prepare");
        let aborted = engine
            .dispatch(command(
                "abort-save",
                EditorCommand::SaveAborted {
                    save_id: "save-1".to_owned(),
                },
            ))
            .expect("prepared save should abort");
        assert!(aborted.patch.dirty);
        assert!(engine.snapshot().dirty);
    }

    #[test]
    fn format_undo_and_redo_share_one_revisioned_memento_history() {
        let mut engine = engine("hello");
        let formatted = engine
            .dispatch(command(
                "bold",
                EditorCommand::Format {
                    base_revision: 0,
                    selection: Selection { start: 0, end: 5 },
                    operation: FormatOperation::Bold,
                },
            ))
            .expect("format should apply");
        assert_eq!(engine.snapshot().text, "**hello**");
        assert_eq!(formatted.patch.revision, 1);
        assert!(formatted.patch.can_undo);
        assert!(!formatted.patch.can_redo);

        let undone = engine
            .dispatch(command("undo", EditorCommand::Undo { base_revision: 1 }))
            .expect("undo should apply");
        assert_eq!(engine.snapshot().text, "hello");
        assert_eq!(engine.snapshot().selection, Selection { start: 0, end: 0 });
        assert_eq!(undone.patch.revision, 2);
        assert!(!undone.patch.can_undo);
        assert!(undone.patch.can_redo);

        let redone = engine
            .dispatch(command("redo", EditorCommand::Redo { base_revision: 2 }))
            .expect("redo should apply");
        assert_eq!(engine.snapshot().text, "**hello**");
        assert_eq!(engine.snapshot().selection, Selection { start: 2, end: 7 });
        assert_eq!(redone.patch.revision, 3);
        assert!(redone.patch.can_undo);
        assert!(!redone.patch.can_redo);
    }

    #[test]
    fn stale_history_commands_do_not_consume_entries() {
        let mut engine = engine("A");
        engine
            .dispatch(replace(0, 1..1, "B", Selection { start: 2, end: 2 }))
            .expect("edit");
        assert_eq!(
            engine.dispatch(command(
                "stale-undo",
                EditorCommand::Undo { base_revision: 0 }
            )),
            Err(EngineError::RevisionConflict)
        );
        assert_eq!(engine.snapshot().text, "AB");
        assert!(engine.snapshot().can_undo);
        engine
            .dispatch(command(
                "current-undo",
                EditorCommand::Undo { base_revision: 1 },
            ))
            .expect("entry must remain available");
        assert_eq!(engine.snapshot().text, "A");
    }

    #[test]
    fn derived_cache_is_keyed_by_presentation_configuration() {
        let mut engine = engine("$x$\n\n```mermaid\nflowchart LR\nA --> B\n```\n");
        let disabled = engine
            .dispatch(command(
                "derive-disabled",
                EditorCommand::RefreshDerived {
                    revision: 0,
                    math_enabled: false,
                    mermaid_enabled: false,
                },
            ))
            .expect("disabled derive")
            .patch
            .derived
            .expect("derived");
        assert!(!disabled.html_fragment.contains("<math"));
        assert!(!disabled.html_fragment.contains("inflow-mermaid"));

        let enabled = engine
            .dispatch(refresh(0))
            .expect("enabled derive")
            .patch
            .derived
            .expect("derived");
        assert!(enabled.html_fragment.contains("<math"));
        assert!(enabled.html_fragment.contains("mermaid-diagram"));
    }

    #[test]
    fn mode_is_revision_bound_and_blocks_mutations_without_blocking_reads() {
        let mut engine = engine("draft");
        let read_only = engine
            .dispatch(command(
                "read-only",
                EditorCommand::SetMode {
                    revision: 0,
                    mode: EditorMode::ReadOnly,
                },
            ))
            .expect("current mode change should succeed");

        assert_eq!(read_only.patch.mode, EditorMode::ReadOnly);
        assert_eq!(engine.snapshot().mode, EditorMode::ReadOnly);
        assert_eq!(
            engine.dispatch(replace(0, 5..5, "!", Selection { start: 6, end: 6 })),
            Err(EngineError::ReadOnly)
        );
        assert!(engine.dispatch(refresh(0)).is_ok());
        assert_eq!(
            engine.dispatch(command(
                "stale-editable",
                EditorCommand::SetMode {
                    revision: 1,
                    mode: EditorMode::Editable,
                },
            )),
            Err(EngineError::RevisionConflict)
        );

        engine
            .dispatch(command(
                "editable",
                EditorCommand::SetMode {
                    revision: 0,
                    mode: EditorMode::Editable,
                },
            ))
            .expect("current mode change should succeed");
        assert!(
            engine
                .dispatch(replace(0, 5..5, "!", Selection { start: 6, end: 6 }))
                .is_ok()
        );
    }
}
