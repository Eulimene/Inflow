//! Stateful editor authority introduced behind the macOS shadow-mode bridge.

use std::ops::Range;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

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
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct EngineSnapshot {
    pub schema_version: u32,
    pub document_id: String,
    pub revision: Revision,
    pub text: String,
    pub selection: Selection,
    pub content_hash: String,
}

#[derive(Debug, Eq, PartialEq, Serialize)]
pub struct StatePatch {
    pub base_revision: Revision,
    pub revision: Revision,
    pub text: TextPatch,
    pub selection: Selection,
    pub content_hash: String,
}

#[derive(Debug, Eq, PartialEq, Serialize)]
pub struct TextPatch {
    pub range: ByteRange,
    pub inserted: String,
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
    RevisionOverflow,
}

pub struct EditorEngine {
    document_id: String,
    revision: Revision,
    text: String,
    selection: Selection,
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

        Ok(Self {
            document_id: request.document_id,
            revision: 0,
            text: request.text,
            selection: request.selection,
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
            } => self.replace_text(base_revision, range, inserted, selection_after)?,
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
            content_hash: content_hash(&self.text),
        }
    }

    fn replace_text(
        &mut self,
        base_revision: Revision,
        range: ByteRange,
        inserted: String,
        selection_after: Selection,
    ) -> Result<StatePatch, EngineError> {
        if base_revision != self.revision {
            return Err(EngineError::RevisionConflict);
        }
        validate_range(&self.text, &range)?;

        let mut updated = self.text.clone();
        updated.replace_range(range.as_range(), &inserted);
        validate_selection(&updated, &selection_after)?;

        let revision = self
            .revision
            .checked_add(1)
            .ok_or(EngineError::RevisionOverflow)?;
        let base_revision = self.revision;
        let text = TextPatch { range, inserted };

        self.text = updated;
        self.selection = selection_after.clone();
        self.revision = revision;

        Ok(StatePatch {
            base_revision,
            revision,
            text,
            selection: selection_after,
            content_hash: content_hash(&self.text),
        })
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
            },
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
        assert_eq!(response.patch.text.range, ByteRange { start: 6, end: 10 });
        assert_eq!(response.patch.text.inserted, "世界");
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
        });
        assert!(matches!(unsupported, Err(EngineError::UnsupportedSchema)));

        let missing_id = EditorEngine::create(EngineCreateRequest {
            schema_version: ENGINE_SCHEMA_VERSION,
            document_id: String::new(),
            text: String::new(),
            selection: Selection { start: 0, end: 0 },
        });
        assert!(matches!(missing_id, Err(EngineError::EmptyDocumentId)));
    }
}
