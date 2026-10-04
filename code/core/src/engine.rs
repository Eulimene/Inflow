//! Stateful editor authority shared by the Rust domain and platform clients.

use std::collections::HashMap;
use std::ops::Range;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

use crate::analysis::DocumentAnalysis;
use crate::document::{self, DecodeError, LineEnding};
use crate::export::ExportError;
use crate::format::{self, FormatError, InlineFormat, ListFormat, MarkdownEdit};
use crate::highlight::HighlightSpan;
use crate::history::{History, HistoryEntry};
use crate::markdown_adapter::CommonMarkAdapter;
use crate::markdown_ir::DocumentIr;
use crate::native_render::NativeRenderPlan;
use crate::ports::MarkdownPort;
use crate::reference::MarkdownReference;
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
    CompileTheme {
        css: String,
    },
    InspectThemeColor {
        value: String,
    },
    LayoutTable {
        measurements: crate::presentation_layout::TableMeasurements,
    },
    ReplaceText {
        base_revision: Revision,
        range: ByteRange,
        inserted: String,
        #[serde(default)]
        selection_before: Option<Selection>,
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
        #[serde(default)]
        defer_mermaid: bool,
        #[serde(default)]
        include_html: bool,
    },
    ResolveMermaid {
        revision: Revision,
        #[serde(default = "default_true")]
        math_enabled: bool,
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
    PrepareHtmlExport {
        revision: Revision,
        #[serde(default = "default_true")]
        math_enabled: bool,
        #[serde(default = "default_true")]
        mermaid_enabled: bool,
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
    OpenDocument {
        base_revision: Revision,
        text: String,
        selection: Selection,
    },
    OpenBytes {
        base_revision: Revision,
        bytes: Vec<u8>,
    },
    EncodeDocument {
        revision: Revision,
        has_utf8_bom: bool,
        line_ending: DocumentLineEnding,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DocumentLineEnding {
    Lf,
    #[serde(rename = "crlf")]
    CrLf,
}

impl From<DocumentLineEnding> for LineEnding {
    fn from(value: DocumentLineEnding) -> Self {
        match value {
            DocumentLineEnding::Lf => Self::Lf,
            DocumentLineEnding::CrLf => Self::CrLf,
        }
    }
}

const fn default_true() -> bool {
    true
}

const fn default_table_dimension() -> usize {
    3
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
    Table {
        #[serde(default = "default_table_dimension")]
        columns: usize,
        #[serde(default = "default_table_dimension")]
        rows: usize,
    },
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

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct StatePatch {
    pub base_revision: Revision,
    pub revision: Revision,
    pub mode: EditorMode,
    pub text: Option<TextPatch>,
    pub selection: Option<Selection>,
    pub derived: Option<DerivedState>,
    pub mermaid: Option<MermaidPatch>,
    pub search: Option<SearchResult>,
    pub format_capabilities: Option<FormatCapabilities>,
    pub effects: Vec<HostEffect>,
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

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HostEffect {
    ThemeCompiled {
        theme: crate::theme::ThemeSnapshot,
    },
    ThemeColor {
        color: Option<String>,
    },
    TableLaidOut {
        layout: crate::presentation_layout::TableLayout,
    },
    WriteDocument {
        save_id: String,
        revision: Revision,
        text: String,
        content_hash: String,
    },
    HtmlExportPrepared {
        revision: Revision,
        html: String,
        warnings: u64,
    },
    DocumentOpened {
        revision: Revision,
        has_utf8_bom: bool,
        line_ending: DocumentLineEnding,
        requires_line_ending_choice: bool,
    },
    DocumentEncoded {
        revision: Revision,
        bytes: Vec<u8>,
    },
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html_fragment: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview_html_fragment: Option<String>,
    pub math_enabled: bool,
    pub mermaid_enabled: bool,
    pub mermaid_deferred: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MermaidPatch {
    pub revision: Revision,
    pub diagrams: Vec<crate::native_render::NativeMermaidDiagram>,
    pub failed_source_ranges: Vec<ByteRange>,
}

#[derive(Debug, PartialEq, Serialize)]
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
    InvalidUtf8,
    MixedLineEndings,
    OutputTooLarge,
    RevisionOverflow,
}

pub struct EditorEngine {
    document_id: String,
    revision: Revision,
    text: String,
    selection: Selection,
    mode: EditorMode,
    derived: Option<DerivedState>,
    parsed: Option<ParsedDocument>,
    mermaid_resolution: Option<MermaidPatch>,
    history: History,
    saved_content_hash: String,
    prepared_saves: HashMap<String, String>,
    markdown: Box<dyn MarkdownPort>,
}

struct ParsedDocument {
    revision: Revision,
    math_enabled: bool,
    document: DocumentIr,
}

impl EditorEngine {
    pub fn create(request: EngineCreateRequest) -> Result<Self, EngineError> {
        Self::create_with_markdown(request, Box::<CommonMarkAdapter>::default())
    }

    fn create_with_markdown(
        request: EngineCreateRequest,
        markdown: Box<dyn MarkdownPort>,
    ) -> Result<Self, EngineError> {
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
            parsed: None,
            mermaid_resolution: None,
            history: History::default(),
            saved_content_hash,
            prepared_saves: HashMap::new(),
            markdown,
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
        let patch = self.dispatch_command(envelope.command)?;
        Ok(DispatchResponse {
            schema_version: ENGINE_SCHEMA_VERSION,
            request_id,
            patch,
        })
    }

    fn dispatch_command(&mut self, command: EditorCommand) -> Result<StatePatch, EngineError> {
        let patch = match command {
            EditorCommand::CompileTheme { css } => {
                self.presentation_effect(HostEffect::ThemeCompiled {
                    theme: crate::theme::compile(&css).as_ref().clone(),
                })
            }
            EditorCommand::InspectThemeColor { value } => {
                self.presentation_effect(HostEffect::ThemeColor {
                    color: crate::theme_values::color(&value),
                })
            }
            EditorCommand::LayoutTable { measurements } => {
                self.presentation_effect(HostEffect::TableLaidOut {
                    layout: crate::presentation_layout::table(&measurements),
                })
            }
            EditorCommand::ReplaceText {
                base_revision,
                range,
                inserted,
                selection_before,
                selection_after,
                group_id,
            } => {
                let selection_before = selection_before.unwrap_or(Selection {
                    start: range.start,
                    end: range.end,
                });
                self.replace_text(
                    base_revision,
                    range,
                    inserted,
                    selection_before,
                    selection_after,
                    group_id,
                )?
            }
            EditorCommand::RefreshDerived {
                revision,
                math_enabled,
                mermaid_enabled,
                defer_mermaid,
                include_html,
            } => self.refresh_derived(
                revision,
                math_enabled,
                mermaid_enabled,
                defer_mermaid,
                include_html,
            )?,
            EditorCommand::ResolveMermaid {
                revision,
                math_enabled,
            } => self.resolve_mermaid(revision, math_enabled)?,
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
            EditorCommand::PrepareHtmlExport {
                revision,
                math_enabled,
                mermaid_enabled,
            } => self.prepare_html_export(revision, math_enabled, mermaid_enabled)?,
            EditorCommand::SaveCompleted { save_id } => self.save_completed(&save_id)?,
            EditorCommand::SaveAborted { save_id } => self.save_aborted(&save_id)?,
            EditorCommand::SetMode { revision, mode } => self.set_mode(revision, mode)?,
            EditorCommand::OpenDocument {
                base_revision,
                text,
                selection,
            } => self.open_document(base_revision, text, selection)?,
            EditorCommand::OpenBytes {
                base_revision,
                bytes,
            } => self.open_bytes(base_revision, &bytes)?,
            EditorCommand::EncodeDocument {
                revision,
                has_utf8_bom,
                line_ending,
            } => self.encode_document(revision, has_utf8_bom, line_ending)?,
        };

        Ok(patch)
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
            can_undo: self.history.can_undo(),
            can_redo: self.history.can_redo(),
            dirty: self.is_dirty(),
        }
    }

    fn replace_text(
        &mut self,
        base_revision: Revision,
        range: ByteRange,
        inserted: String,
        selection_before: Selection,
        selection_after: Selection,
        group_id: Option<String>,
    ) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        self.ensure_editable()?;
        validate_range(&self.text, &range)?;

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
        let entry = HistoryEntry {
            forward,
            inverse,
            selection_before,
            selection_after,
            group_id,
        };
        self.history.record(entry);
        Ok(self.with_history_state(patch))
    }

    // Mirrors the independent rendering flags in the engine command.
    #[allow(clippy::fn_params_excessive_bools)]
    fn refresh_derived(
        &mut self,
        revision: Revision,
        math_enabled: bool,
        mermaid_enabled: bool,
        defer_mermaid: bool,
        include_html: bool,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        let derived = if let Some(derived) = &self.derived
            && derived.math_enabled == math_enabled
            && derived.mermaid_enabled == mermaid_enabled
            && derived.mermaid_deferred == defer_mermaid
            && derived.html_fragment.is_some() == include_html
        {
            derived.clone()
        } else {
            self.ensure_parsed(math_enabled);
            let document = &self
                .parsed
                .as_ref()
                .expect("parsed document must be available")
                .document;
            let derived = self.markdown.derive(
                document,
                revision,
                math_enabled,
                mermaid_enabled,
                defer_mermaid,
                include_html,
            );
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
            mermaid: None,
            search: None,
            format_capabilities: None,
            effects: Vec::new(),
            content_hash: content_hash(&self.text),
            can_undo: self.history.can_undo(),
            can_redo: self.history.can_redo(),
            dirty: self.is_dirty(),
        })
    }

    fn resolve_mermaid(
        &mut self,
        revision: Revision,
        math_enabled: bool,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        let mermaid = if let Some(cached) = &self.mermaid_resolution
            && cached.revision == revision
        {
            cached.clone()
        } else {
            self.ensure_parsed(math_enabled);
            let document = &self
                .parsed
                .as_ref()
                .expect("parsed document must be available")
                .document;
            let resolved = self.markdown.resolve_mermaid(document, revision);
            if let Some(derived) = &mut self.derived
                && derived.revision == revision
                && derived.mermaid_deferred
            {
                let failed = resolved
                    .failed_source_ranges
                    .iter()
                    .map(ByteRange::as_range)
                    .collect::<Vec<_>>();
                derived
                    .native_render
                    .apply_mermaid_resolution(&resolved.diagrams, &failed);
            }
            self.mermaid_resolution = Some(resolved.clone());
            resolved
        };
        let mut patch = self.empty_patch(revision);
        patch.mermaid = Some(mermaid);
        Ok(patch)
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
            mermaid: None,
            search: Some(SearchResult { revision, matches }),
            format_capabilities: None,
            effects: Vec::new(),
            content_hash: content_hash(&self.text),
            can_undo: self.history.can_undo(),
            can_redo: self.history.can_redo(),
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
            mermaid: None,
            search: None,
            format_capabilities: Some(FormatCapabilities {
                revision,
                can_clear,
            }),
            effects: Vec::new(),
            content_hash: content_hash(&self.text),
            can_undo: self.history.can_undo(),
            can_redo: self.history.can_redo(),
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
        patch.effects.push(HostEffect::WriteDocument {
            save_id,
            revision,
            text: self.text.clone(),
            content_hash: hash,
        });
        Ok(patch)
    }

    fn open_bytes(
        &mut self,
        base_revision: Revision,
        bytes: &[u8],
    ) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        let opened = document::decode_for_open(bytes).map_err(|error| match error {
            DecodeError::InvalidUtf8 => EngineError::InvalidUtf8,
            DecodeError::MixedLineEndings => EngineError::MixedLineEndings,
        })?;
        let line_ending = match opened.line_ending {
            LineEnding::Lf => DocumentLineEnding::Lf,
            LineEnding::CrLf => DocumentLineEnding::CrLf,
        };
        let mut patch =
            self.open_document(base_revision, opened.text, Selection { start: 0, end: 0 })?;
        patch.effects.push(HostEffect::DocumentOpened {
            revision: patch.revision,
            has_utf8_bom: opened.has_utf8_bom,
            line_ending,
            requires_line_ending_choice: opened.requires_line_ending_choice,
        });
        Ok(patch)
    }

    fn encode_document(
        &self,
        revision: Revision,
        has_utf8_bom: bool,
        line_ending: DocumentLineEnding,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        let mut patch = self.empty_patch(revision);
        patch.effects.push(HostEffect::DocumentEncoded {
            revision,
            bytes: document::encode(&self.text, has_utf8_bom, line_ending.into()),
        });
        Ok(patch)
    }

    fn prepare_html_export(
        &mut self,
        revision: Revision,
        math_enabled: bool,
        mermaid_enabled: bool,
    ) -> Result<StatePatch, EngineError> {
        if revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        self.ensure_parsed(math_enabled);
        let document = &self
            .parsed
            .as_ref()
            .expect("parsed document must be available")
            .document;
        let prepared = self
            .markdown
            .prepare_html_export(
                document,
                crate::render::RenderConfiguration {
                    math_enabled,
                    mermaid_enabled,
                },
            )
            .map_err(|error| match error {
                ExportError::OutputTooLarge => EngineError::OutputTooLarge,
                ExportError::UnsupportedContent(_) => EngineError::AmbiguousFormat,
            })?;
        let mut patch = self.empty_patch(revision);
        patch.effects.push(HostEffect::HtmlExportPrepared {
            revision,
            html: String::from_utf8(prepared.bytes)
                .expect("the Markdown adapter must emit UTF-8 HTML"),
            warnings: prepared.warnings,
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

    fn open_document(
        &mut self,
        base_revision: Revision,
        text: String,
        selection: Selection,
    ) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        validate_selection(&text, &selection)?;
        let revision = self
            .revision
            .checked_add(1)
            .ok_or(EngineError::RevisionOverflow)?;
        let replaced_end = self.text.len();
        let saved_content_hash = content_hash(&text);
        self.text = text;
        self.selection = selection.clone();
        self.revision = revision;
        self.derived = None;
        self.parsed = None;
        self.mermaid_resolution = None;
        self.history.clear();
        self.saved_content_hash = saved_content_hash;
        self.prepared_saves.clear();
        Ok(StatePatch {
            base_revision,
            revision,
            mode: self.mode,
            text: Some(TextPatch {
                range: ByteRange {
                    start: 0,
                    end: replaced_end,
                },
                inserted: self.text.clone(),
            }),
            selection: Some(selection),
            derived: None,
            mermaid: None,
            search: None,
            format_capabilities: None,
            effects: Vec::new(),
            content_hash: self.saved_content_hash.clone(),
            can_undo: false,
            can_redo: false,
            dirty: false,
        })
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
            FormatOperation::Table { columns, rows } => {
                format::insert_table_with_dimensions(&self.text, range, columns, rows)
            }
            FormatOperation::HorizontalRule => format::insert_horizontal_rule(&self.text, range),
            FormatOperation::Footnote => format::insert_footnote(&self.text, range),
            FormatOperation::Math => format::insert_math(&self.text, range),
            FormatOperation::Mermaid => format::insert_mermaid(&self.text, range),
        }
        .map_err(|error| match error {
            FormatError::InvalidSelection => EngineError::InvalidSelection,
            FormatError::AmbiguousSelection => EngineError::AmbiguousFormat,
        })?;
        self.apply_format_edit(base_revision, edit, selection.clone())
    }

    fn apply_format_edit(
        &mut self,
        base_revision: Revision,
        edit: MarkdownEdit,
        selection_before: Selection,
    ) -> Result<StatePatch, EngineError> {
        self.replace_text(
            base_revision,
            ByteRange {
                start: edit.replace_range.start,
                end: edit.replace_range.end,
            },
            edit.replacement,
            selection_before,
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
        let entry = self.history.take_undo().ok_or(EngineError::NothingToUndo)?;
        let patch = self.apply_patch(
            base_revision,
            entry.inverse.clone(),
            entry.selection_before.clone(),
        )?;
        self.history.complete_undo(entry);
        Ok(self.with_history_state(patch))
    }

    fn redo(&mut self, base_revision: Revision) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        self.ensure_editable()?;
        let entry = self.history.take_redo().ok_or(EngineError::NothingToRedo)?;
        let patch = self.apply_patch(
            base_revision,
            entry.forward.clone(),
            entry.selection_after.clone(),
        )?;
        self.history.complete_redo(entry);
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
        self.parsed = None;
        self.mermaid_resolution = None;
        Ok(StatePatch {
            base_revision,
            revision,
            mode: self.mode,
            text: Some(text),
            selection: Some(selection_after),
            derived: None,
            mermaid: None,
            search: None,
            format_capabilities: None,
            effects: Vec::new(),
            content_hash: content_hash(&self.text),
            can_undo: self.history.can_undo(),
            can_redo: self.history.can_redo(),
            dirty: self.is_dirty(),
        })
    }

    fn presentation_effect(&self, effect: HostEffect) -> StatePatch {
        let mut patch = self.empty_patch(self.revision);
        patch.effects.push(effect);
        patch
    }

    fn empty_patch(&self, base_revision: Revision) -> StatePatch {
        StatePatch {
            base_revision,
            revision: self.revision,
            mode: self.mode,
            text: None,
            selection: None,
            derived: None,
            mermaid: None,
            search: None,
            format_capabilities: None,
            effects: Vec::new(),
            content_hash: content_hash(&self.text),
            can_undo: self.history.can_undo(),
            can_redo: self.history.can_redo(),
            dirty: self.is_dirty(),
        }
    }

    fn is_dirty(&self) -> bool {
        content_hash(&self.text) != self.saved_content_hash
    }

    fn ensure_parsed(&mut self, math_enabled: bool) {
        let needs_parse = self.parsed.as_ref().is_none_or(|parsed| {
            parsed.revision != self.revision || parsed.math_enabled != math_enabled
        });
        if needs_parse {
            self.parsed = Some(ParsedDocument {
                revision: self.revision,
                math_enabled,
                document: self.markdown.parse(&self.text, math_enabled),
            });
        }
    }

    fn ensure_editable(&self) -> Result<(), EngineError> {
        if self.mode == EditorMode::ReadOnly {
            Err(EngineError::ReadOnly)
        } else {
            Ok(())
        }
    }

    fn with_history_state(&self, mut patch: StatePatch) -> StatePatch {
        patch.can_undo = self.history.can_undo();
        patch.can_redo = self.history.can_redo();
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
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn presentation_commands_are_read_only_and_versioned() {
        let mut engine = engine("# 标题 😀");
        let before = engine.snapshot();
        for command in [
            EditorCommand::CompileTheme {
                css: "body {color:#123;}".into(),
            },
            EditorCommand::LayoutTable {
                measurements: crate::presentation_layout::TableMeasurements {
                    columns: vec![12.0, 120.0],
                    available_width: 800.0,
                    horizontal_padding: 24.0,
                },
            },
        ] {
            let response = engine
                .dispatch(CommandEnvelope {
                    schema_version: ENGINE_SCHEMA_VERSION,
                    request_id: "presentation-test".into(),
                    command,
                })
                .unwrap();
            assert_eq!(response.patch.revision, before.revision);
            assert!(response.patch.text.is_none() && response.patch.derived.is_none());
            assert!(!response.patch.dirty && !response.patch.can_undo);
            assert_eq!(response.patch.effects.len(), 1);
        }
        assert_eq!(engine.snapshot(), before);
    }

    struct CountingMarkdownPort {
        parses: Arc<AtomicUsize>,
        derivations: Arc<AtomicUsize>,
        resolutions: Arc<AtomicUsize>,
    }

    impl MarkdownPort for CountingMarkdownPort {
        fn parse(&self, source: &str, math_enabled: bool) -> DocumentIr {
            self.parses.fetch_add(1, Ordering::Relaxed);
            CommonMarkAdapter.parse(source, math_enabled)
        }

        fn derive(
            &self,
            document: &DocumentIr,
            revision: Revision,
            math_enabled: bool,
            mermaid_enabled: bool,
            defer_mermaid: bool,
            include_html: bool,
        ) -> DerivedState {
            self.derivations.fetch_add(1, Ordering::Relaxed);
            CommonMarkAdapter.derive(
                document,
                revision,
                math_enabled,
                mermaid_enabled,
                defer_mermaid,
                include_html,
            )
        }

        fn resolve_mermaid(&self, document: &DocumentIr, revision: Revision) -> MermaidPatch {
            self.resolutions.fetch_add(1, Ordering::Relaxed);
            CommonMarkAdapter.resolve_mermaid(document, revision)
        }

        fn prepare_html_export(
            &self,
            document: &DocumentIr,
            configuration: crate::render::RenderConfiguration,
        ) -> Result<crate::export::PreparedHtml, ExportError> {
            CommonMarkAdapter.prepare_html_export(document, configuration)
        }
    }

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
        grouped_replace(base_revision, range, inserted, selection_after, None)
    }

    fn grouped_replace(
        base_revision: Revision,
        range: Range<usize>,
        inserted: &str,
        selection_after: Selection,
        group_id: Option<&str>,
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
                selection_before: None,
                selection_after,
                group_id: group_id.map(str::to_owned),
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
                defer_mermaid: false,
                include_html: false,
            },
        }
    }

    fn refresh_with_html(revision: Revision) -> CommandEnvelope {
        CommandEnvelope {
            schema_version: ENGINE_SCHEMA_VERSION,
            request_id: format!("refresh-html-{revision}"),
            command: EditorCommand::RefreshDerived {
                revision,
                math_enabled: true,
                mermaid_enabled: true,
                defer_mermaid: false,
                include_html: true,
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
        assert!(derived.html_fragment.is_none());
        assert!(derived.preview_html_fragment.is_none());
        let encoded = serde_json::to_value(&derived).expect("derived state should encode");
        assert!(encoded.get("html_fragment").is_none());
        assert!(encoded.get("preview_html_fragment").is_none());
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
    fn engine_caches_the_markdown_port_result_by_revision_and_configuration() {
        let parse_calls = Arc::new(AtomicUsize::new(0));
        let derive_calls = Arc::new(AtomicUsize::new(0));
        let resolve_calls = Arc::new(AtomicUsize::new(0));
        let mut engine = EditorEngine::create_with_markdown(
            EngineCreateRequest {
                schema_version: ENGINE_SCHEMA_VERSION,
                document_id: "document-with-port".to_owned(),
                text: "# Title\n".to_owned(),
                selection: Selection { start: 0, end: 0 },
                mode: EditorMode::Editable,
            },
            Box::new(CountingMarkdownPort {
                parses: Arc::clone(&parse_calls),
                derivations: Arc::clone(&derive_calls),
                resolutions: Arc::clone(&resolve_calls),
            }),
        )
        .expect("engine with injected port should be valid");

        engine.dispatch(refresh(0)).expect("initial derivation");
        engine.dispatch(refresh(0)).expect("cached derivation");
        assert_eq!(parse_calls.load(Ordering::Relaxed), 1);
        assert_eq!(derive_calls.load(Ordering::Relaxed), 1);

        engine
            .dispatch(command(
                "different-configuration",
                EditorCommand::RefreshDerived {
                    revision: 0,
                    math_enabled: false,
                    mermaid_enabled: true,
                    defer_mermaid: false,
                    include_html: false,
                },
            ))
            .expect("configuration change derives again");
        assert_eq!(parse_calls.load(Ordering::Relaxed), 2);
        assert_eq!(derive_calls.load(Ordering::Relaxed), 2);

        engine
            .dispatch(command(
                "deferred-mermaid",
                EditorCommand::RefreshDerived {
                    revision: 0,
                    math_enabled: false,
                    mermaid_enabled: true,
                    defer_mermaid: true,
                    include_html: false,
                },
            ))
            .expect("deferred Mermaid is a separate cache entry");
        assert_eq!(parse_calls.load(Ordering::Relaxed), 2);
        assert_eq!(derive_calls.load(Ordering::Relaxed), 3);
        let mermaid = engine
            .dispatch(command(
                "resolve-mermaid",
                EditorCommand::ResolveMermaid {
                    revision: 0,
                    math_enabled: false,
                },
            ))
            .expect("Mermaid resolution should reuse the parsed document");
        assert_eq!(mermaid.patch.mermaid.expect("Mermaid patch").revision, 0);
        assert!(mermaid.patch.derived.is_none());
        assert_eq!(parse_calls.load(Ordering::Relaxed), 2);
        assert_eq!(derive_calls.load(Ordering::Relaxed), 3);
        assert_eq!(resolve_calls.load(Ordering::Relaxed), 1);

        engine
            .dispatch(command(
                "resolve-mermaid-again",
                EditorCommand::ResolveMermaid {
                    revision: 0,
                    math_enabled: false,
                },
            ))
            .expect("same revision should reuse the Mermaid resource patch");
        assert_eq!(parse_calls.load(Ordering::Relaxed), 2);
        assert_eq!(derive_calls.load(Ordering::Relaxed), 3);

        engine
            .dispatch(replace(
                0,
                0..0,
                "Intro\n\n",
                Selection { start: 0, end: 0 },
            ))
            .expect("edit invalidates the cache");
        engine
            .dispatch(refresh(1))
            .expect("new revision derives again");
        assert_eq!(parse_calls.load(Ordering::Relaxed), 3);
        assert_eq!(derive_calls.load(Ordering::Relaxed), 4);
        assert_eq!(resolve_calls.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn deferred_mermaid_reuses_the_ast_and_resolved_resource_for_the_revision() {
        let parse_calls = Arc::new(AtomicUsize::new(0));
        let derive_calls = Arc::new(AtomicUsize::new(0));
        let resolve_calls = Arc::new(AtomicUsize::new(0));
        let mut engine = EditorEngine::create_with_markdown(
            EngineCreateRequest {
                schema_version: ENGINE_SCHEMA_VERSION,
                document_id: "deferred-mermaid".to_owned(),
                text: "```mermaid\nflowchart LR\nA --> B\n```\n".to_owned(),
                selection: Selection { start: 0, end: 0 },
                mode: EditorMode::Editable,
            },
            Box::new(CountingMarkdownPort {
                parses: Arc::clone(&parse_calls),
                derivations: Arc::clone(&derive_calls),
                resolutions: Arc::clone(&resolve_calls),
            }),
        )
        .expect("engine with injected port should be valid");
        let deferred = |request_id| {
            command(
                request_id,
                EditorCommand::RefreshDerived {
                    revision: 0,
                    math_enabled: true,
                    mermaid_enabled: true,
                    defer_mermaid: true,
                    include_html: false,
                },
            )
        };

        let placeholder = engine
            .dispatch(deferred("deferred-plan"))
            .expect("placeholder plan")
            .patch
            .derived
            .expect("derived plan");
        assert!(
            placeholder
                .native_render
                .mermaid_diagrams
                .iter()
                .all(|diagram| diagram.is_placeholder)
        );

        for request_id in ["resolve-once", "resolve-cached"] {
            engine
                .dispatch(command(
                    request_id,
                    EditorCommand::ResolveMermaid {
                        revision: 0,
                        math_enabled: true,
                    },
                ))
                .expect("Mermaid resource resolution");
        }

        let completed = engine
            .dispatch(deferred("deferred-plan-cached"))
            .expect("cached completed plan")
            .patch
            .derived
            .expect("derived plan");
        assert!(
            completed
                .native_render
                .mermaid_diagrams
                .iter()
                .all(|diagram| diagram.is_placeholder)
        );
        assert_eq!(parse_calls.load(Ordering::Relaxed), 1);
        assert_eq!(derive_calls.load(Ordering::Relaxed), 1);
        assert_eq!(resolve_calls.load(Ordering::Relaxed), 1);
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
        let [
            HostEffect::WriteDocument {
                save_id,
                revision,
                text,
                ..
            },
        ] = prepared.patch.effects.as_slice()
        else {
            panic!("save preparation must emit exactly one document write");
        };
        assert_eq!(save_id, "save-1");
        assert_eq!(*revision, 1);
        assert_eq!(text, "draft one");
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
        assert!(matches!(
            latest.patch.effects.as_slice(),
            [HostEffect::WriteDocument { revision: 2, .. }]
        ));
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
    fn html_export_is_revision_bound_and_returns_a_host_effect() {
        let mut engine = engine("# Title\n\n[local](note.md)");
        let prepared = engine
            .dispatch(command(
                "prepare-export",
                EditorCommand::PrepareHtmlExport {
                    revision: 0,
                    math_enabled: true,
                    mermaid_enabled: true,
                },
            ))
            .expect("the current revision should prepare export HTML");
        let [
            HostEffect::HtmlExportPrepared {
                revision,
                html,
                warnings,
            },
        ] = prepared.patch.effects.as_slice()
        else {
            panic!("HTML preparation must emit exactly one host effect");
        };
        assert_eq!(*revision, 0);
        assert!(html.starts_with("<!doctype html>"));
        assert!(html.contains("<h1>Title</h1>"));
        assert_eq!(*warnings, crate::export::ISSUE_LOCAL_LINK);
        assert_eq!(engine.snapshot().revision, 0);
        assert_eq!(
            engine.dispatch(command(
                "stale-export",
                EditorCommand::PrepareHtmlExport {
                    revision: 1,
                    math_enabled: true,
                    mermaid_enabled: true,
                },
            )),
            Err(EngineError::RevisionConflict)
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
        assert_eq!(engine.snapshot().selection, Selection { start: 0, end: 5 });
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
    fn adjacent_typing_with_one_group_undoes_and_redoes_as_one_entry() {
        let mut engine = engine("");
        for (revision, offset, inserted) in [(0, 0, "a"), (1, 1, "b"), (2, 2, "c")] {
            engine
                .dispatch(grouped_replace(
                    revision,
                    offset..offset,
                    inserted,
                    Selection {
                        start: offset + 1,
                        end: offset + 1,
                    },
                    Some("typing-1"),
                ))
                .expect("grouped insertion");
        }

        engine
            .dispatch(command(
                "undo-group",
                EditorCommand::Undo { base_revision: 3 },
            ))
            .expect("one undo removes the group");
        assert_eq!(engine.snapshot().text, "");
        assert!(!engine.snapshot().can_undo);

        engine
            .dispatch(command(
                "redo-group",
                EditorCommand::Redo { base_revision: 4 },
            ))
            .expect("one redo restores the group");
        assert_eq!(engine.snapshot().text, "abc");
    }

    #[test]
    fn grouped_backward_and_forward_deletions_restore_original_text() {
        let mut backward = engine("abc");
        for (revision, range, caret) in [(0, 2..3, 2), (1, 1..2, 1), (2, 0..1, 0)] {
            backward
                .dispatch(grouped_replace(
                    revision,
                    range,
                    "",
                    Selection {
                        start: caret,
                        end: caret,
                    },
                    Some("backspace-1"),
                ))
                .expect("grouped backward deletion");
        }
        backward
            .dispatch(command(
                "undo-backward-group",
                EditorCommand::Undo { base_revision: 3 },
            ))
            .expect("undo backward deletion group");
        assert_eq!(backward.snapshot().text, "abc");

        let mut forward = engine("abc");
        for revision in 0..3 {
            forward
                .dispatch(grouped_replace(
                    revision,
                    0..1,
                    "",
                    Selection { start: 0, end: 0 },
                    Some("delete-1"),
                ))
                .expect("grouped forward deletion");
        }
        forward
            .dispatch(command(
                "undo-forward-group",
                EditorCommand::Undo { base_revision: 3 },
            ))
            .expect("undo forward deletion group");
        assert_eq!(forward.snapshot().text, "abc");
    }

    #[test]
    fn different_group_ids_keep_separate_undo_entries() {
        let mut engine = engine("");
        engine
            .dispatch(grouped_replace(
                0,
                0..0,
                "a",
                Selection { start: 1, end: 1 },
                Some("typing-1"),
            ))
            .expect("first group");
        engine
            .dispatch(grouped_replace(
                1,
                1..1,
                "b",
                Selection { start: 2, end: 2 },
                Some("typing-2"),
            ))
            .expect("second group");

        engine
            .dispatch(command(
                "undo-second-group",
                EditorCommand::Undo { base_revision: 2 },
            ))
            .expect("undo only latest group");
        assert_eq!(engine.snapshot().text, "a");
        assert!(engine.snapshot().can_undo);
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
                    defer_mermaid: false,
                    include_html: true,
                },
            ))
            .expect("disabled derive")
            .patch
            .derived
            .expect("derived");
        let disabled_html = disabled.html_fragment.expect("requested HTML");
        assert!(!disabled_html.contains("<math"));
        assert!(!disabled_html.contains("inflow-mermaid"));

        let enabled = engine
            .dispatch(refresh_with_html(0))
            .expect("enabled derive")
            .patch
            .derived
            .expect("derived");
        let enabled_html = enabled.html_fragment.expect("requested HTML");
        assert!(enabled_html.contains("data-inflow-render=\"math\""));
        assert!(enabled_html.contains("mermaid-diagram"));
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

    #[test]
    fn open_document_atomically_replaces_text_and_resets_session_state() {
        let mut engine = engine("draft");
        engine
            .dispatch(replace(0, 5..5, "!", Selection { start: 6, end: 6 }))
            .expect("edit should create history and dirty state");
        engine
            .dispatch(command(
                "prepare-old-save",
                EditorCommand::PrepareSave {
                    revision: 1,
                    save_id: "old-save".to_owned(),
                },
            ))
            .expect("old save should prepare");

        let opened = engine
            .dispatch(command(
                "open-document",
                EditorCommand::OpenDocument {
                    base_revision: 1,
                    text: "# 新文档".to_owned(),
                    selection: Selection { start: 2, end: 2 },
                },
            ))
            .expect("current reload should succeed");

        assert_eq!(opened.patch.base_revision, 1);
        assert_eq!(opened.patch.revision, 2);
        assert_eq!(
            opened.patch.text.unwrap().range,
            ByteRange { start: 0, end: 6 }
        );
        let snapshot = engine.snapshot();
        assert_eq!(snapshot.text, "# 新文档");
        assert_eq!(snapshot.selection, Selection { start: 2, end: 2 });
        assert!(!snapshot.can_undo);
        assert!(!snapshot.can_redo);
        assert!(!snapshot.dirty);
        assert!(snapshot.derived.is_none());
        assert_eq!(
            engine.dispatch(command(
                "complete-old-save",
                EditorCommand::SaveCompleted {
                    save_id: "old-save".to_owned(),
                },
            )),
            Err(EngineError::UnknownSave)
        );
    }

    #[test]
    fn document_bytes_open_and_encode_through_revision_bound_effects() {
        let mut engine = engine("");
        let opened = engine
            .dispatch(command(
                "open-bytes",
                EditorCommand::OpenBytes {
                    base_revision: 0,
                    bytes: b"\xef\xbb\xbfone\r\ntwo\n".to_vec(),
                },
            ))
            .expect("valid UTF-8 bytes should open");
        assert_eq!(opened.patch.revision, 1);
        assert_eq!(engine.snapshot().text, "one\ntwo\n");
        assert!(!engine.snapshot().dirty);
        assert!(matches!(
            opened.patch.effects.as_slice(),
            [HostEffect::DocumentOpened {
                revision: 1,
                has_utf8_bom: true,
                line_ending: DocumentLineEnding::Lf,
                requires_line_ending_choice: true,
            }]
        ));

        let encoded = engine
            .dispatch(command(
                "encode",
                EditorCommand::EncodeDocument {
                    revision: 1,
                    has_utf8_bom: true,
                    line_ending: DocumentLineEnding::CrLf,
                },
            ))
            .expect("the current revision should encode");
        assert!(matches!(
            encoded.patch.effects.as_slice(),
            [HostEffect::DocumentEncoded { revision: 1, bytes }]
                if bytes == b"\xef\xbb\xbfone\r\ntwo\r\n"
        ));
        assert_eq!(engine.snapshot().revision, 1);

        assert_eq!(
            engine.dispatch(command(
                "invalid-utf8",
                EditorCommand::OpenBytes {
                    base_revision: 1,
                    bytes: vec![0xff],
                },
            )),
            Err(EngineError::InvalidUtf8)
        );
    }
}
