//! Application ports consumed by the stateful editor engine.

use crate::engine::{DerivedState, Revision};
use crate::export::{ExportError, PreparedHtml};
use crate::render::RenderConfiguration;

/// Produces every revision-bound Markdown projection from one source snapshot.
///
/// The engine owns scheduling, revision validation and caching. Implementations
/// own parsing and rendering details and must not retain platform state.
pub trait MarkdownPort: Send + Sync {
    fn derive(
        &self,
        source: &str,
        revision: Revision,
        math_enabled: bool,
        mermaid_enabled: bool,
        defer_mermaid: bool,
    ) -> DerivedState;

    fn prepare_html_export(
        &self,
        source: &str,
        configuration: RenderConfiguration,
    ) -> Result<PreparedHtml, ExportError>;
}
