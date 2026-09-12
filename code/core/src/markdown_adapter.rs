//! Default CommonMark/GFM adapter for the editor application's Markdown port.

use crate::analysis::analyze_document;
use crate::engine::{DerivedState, Revision};
use crate::highlight::spans_from_document;
use crate::markdown_ir::{DocumentIr, dialect_options};
use crate::native_render::NativeRenderPlan;
use crate::ports::MarkdownPort;
use crate::reference::references_from_document;
use crate::render::{RenderConfiguration, html_fragment_for_preview_from_document};
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
    ) -> DerivedState {
        let document = DocumentIr::parse(source, dialect_options(math_enabled));
        let configuration = RenderConfiguration {
            math_enabled,
            mermaid_enabled,
        };
        let render = RenderIr::from_document(&document);
        let native_render = NativeRenderPlan::from_document(&document, &render);
        DerivedState {
            revision,
            analysis: analyze_document(&document),
            highlights: spans_from_document(&document),
            references: references_from_document(&document),
            render,
            native_render,
            html_fragment: html_fragment_for_preview_from_document(&document, configuration),
            math_enabled,
            mermaid_enabled,
        }
    }
}
