//! Default CommonMark/GFM adapter for the editor application's Markdown port.

use crate::analysis::analyze_document;
use crate::engine::{ByteRange, DerivedState, MermaidPatch, Revision};
use crate::export::{ExportError, PreparedHtml, prepare_html_document_from_document};
use crate::highlight::spans_from_document;
use crate::markdown_ir::{DocumentIr, dialect_options};
use crate::mermaid::MermaidRenderBatch;
use crate::native_render::{NativeRenderPlan, resolve_mermaid_from_document};
use crate::ports::MarkdownPort;
use crate::reference::references_from_document;
use crate::render::{
    RenderConfiguration, html_fragment_for_preview_from_document_with_mermaid,
    html_fragment_from_document_with_mermaid,
};
use crate::render_ir::RenderIr;

#[derive(Default)]
pub struct CommonMarkAdapter;

impl MarkdownPort for CommonMarkAdapter {
    fn parse(&self, source: &str, math_enabled: bool) -> DocumentIr {
        DocumentIr::parse(source, dialect_options(math_enabled))
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
        let render = RenderIr::from_document(document);
        let immediate_configuration = RenderConfiguration {
            math_enabled,
            mermaid_enabled: mermaid_enabled && !defer_mermaid,
        };
        let mermaid = immediate_configuration
            .mermaid_enabled
            .then(|| MermaidRenderBatch::render(document));
        let native_render = NativeRenderPlan::from_document_with_mermaid(
            document,
            &render,
            mermaid_enabled,
            defer_mermaid,
            mermaid.as_ref(),
        );
        DerivedState {
            revision,
            analysis: analyze_document(document),
            highlights: spans_from_document(document),
            references: references_from_document(document),
            render,
            native_render,
            html_fragment: include_html.then(|| {
                html_fragment_from_document_with_mermaid(
                    document,
                    immediate_configuration,
                    mermaid.as_ref(),
                )
            }),
            preview_html_fragment: include_html.then(|| {
                html_fragment_for_preview_from_document_with_mermaid(
                    document,
                    immediate_configuration,
                    mermaid.as_ref(),
                )
            }),
            math_enabled,
            mermaid_enabled,
            mermaid_deferred: defer_mermaid,
        }
    }

    fn resolve_mermaid(&self, document: &DocumentIr, revision: Revision) -> MermaidPatch {
        let resolution = resolve_mermaid_from_document(document);
        MermaidPatch {
            revision,
            diagrams: resolution.diagrams,
            failed_source_ranges: resolution
                .failed_source_ranges
                .into_iter()
                .map(|range| ByteRange {
                    start: range.start,
                    end: range.end,
                })
                .collect(),
        }
    }

    fn prepare_html_export(
        &self,
        document: &DocumentIr,
        configuration: RenderConfiguration,
    ) -> Result<PreparedHtml, ExportError> {
        prepare_html_document_from_document(document, configuration)
    }
}
