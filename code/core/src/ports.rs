//! Application ports consumed by the stateful editor engine.

use crate::engine::{DerivedState, Revision};

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
    ) -> DerivedState;
}
