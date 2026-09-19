//! Application ports consumed by the stateful editor engine.

use crate::engine::{DerivedState, MermaidPatch, Revision};
use crate::export::{ExportError, PreparedHtml};
use crate::markdown_ir::DocumentIr;
use crate::render::RenderConfiguration;

/// Produces every revision-bound Markdown projection from one source snapshot.
///
/// The engine owns scheduling, revision validation and caching. Implementations
/// own parsing and rendering details and must not retain platform state.
pub trait MarkdownPort: Send + Sync {
    fn parse(&self, source: &str, math_enabled: bool) -> DocumentIr;

    // These independent flags mirror the engine command and rendering policy.
    #[allow(clippy::fn_params_excessive_bools)]
    fn derive(
        &self,
        document: &DocumentIr,
        revision: Revision,
        math_enabled: bool,
        mermaid_enabled: bool,
        defer_mermaid: bool,
        include_html: bool,
    ) -> DerivedState;

    fn resolve_mermaid(&self, document: &DocumentIr, revision: Revision) -> MermaidPatch;

    fn prepare_html_export(
        &self,
        document: &DocumentIr,
        configuration: RenderConfiguration,
    ) -> Result<PreparedHtml, ExportError>;
}
