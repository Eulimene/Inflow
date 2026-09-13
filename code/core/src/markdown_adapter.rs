//! Default CommonMark/GFM adapter for the editor application's Markdown port.

use crate::analysis::analyze_document;
use crate::engine::{DerivedState, Revision};
use crate::export::{ExportError, PreparedHtml, prepare_html_document_from_document};
use crate::highlight::spans_from_document;
use crate::markdown_ir::{DocumentIr, dialect_options};
use crate::native_render::NativeRenderPlan;
use crate::ports::MarkdownPort;
use crate::reference::references_from_document;
use crate::render::{
    RenderConfiguration, html_fragment_for_preview_from_document, html_fragment_from_document,
};
use crate::render_ir::RenderIr;

#[derive(Default)]
pub struct CommonMarkAdapter;

impl MarkdownPort for CommonMarkAdapter {
    fn derive(
        &self,
        source: &str,
        revision: Revision,
        math_enabled: bool,
        mermaid_enabled: bool,
        defer_mermaid: bool,
    ) -> DerivedState {
        let document = DocumentIr::parse(source, dialect_options(math_enabled));
        let render = RenderIr::from_document(&document);
        let native_render =
            NativeRenderPlan::from_document(&document, &render, mermaid_enabled, defer_mermaid);
        let immediate_configuration = RenderConfiguration {
            math_enabled,
            mermaid_enabled: mermaid_enabled && !defer_mermaid,
        };
        DerivedState {
            revision,
            analysis: analyze_document(&document),
            highlights: spans_from_document(&document),
            references: references_from_document(&document),
            render,
            native_render,
            html_fragment: html_fragment_from_document(&document, immediate_configuration),
            preview_html_fragment: html_fragment_for_preview_from_document(
                &document,
                immediate_configuration,
            ),
            math_enabled,
            mermaid_enabled,
            mermaid_deferred: defer_mermaid,
        }
    }

    fn prepare_html_export(
        &self,
        source: &str,
        configuration: RenderConfiguration,
    ) -> Result<PreparedHtml, ExportError> {
        let document = DocumentIr::parse(source, dialect_options(configuration.math_enabled));
        prepare_html_document_from_document(&document, configuration)
    }
}
