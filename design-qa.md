# Design QA — Markdown typography and Mermaid rendering

## Evidence

- Reference typography: `/var/folders/fk/7c_mpq791lg24r5gfcg795d00000gn/T/codex-clipboard-66eddcbe-2e87-4ce0-b306-0d958212e4c4.png`
- Reference Mermaid presentation: `/var/folders/fk/7c_mpq791lg24r5gfcg795d00000gn/T/codex-clipboard-c7f12242-a449-4f7e-83a1-f14453bf2a6b.png`
- Final implementation capture: `/private/tmp/inflow-open-source-mermaid-final.png`
- Capture method: off-screen bitmap of the real `MarkdownSourceEditorSession` TextKit render tree; no mock UI or replacement renderer.
- Viewport: 1200 × 768 points, light appearance.

## Comparison history

### Round 1 — typography and structure

- Increased the reserved gap between ordered/unordered markers and content.
- Aligned drawn list markers to the baseline of the first visible full-size glyph.
- Tuned the light palette toward the neutral gray reference and added quiet H1/H2 dividers.
- Preserved compact paragraph rhythm and intrinsic image sizing.

Result: list rhythm, heading hierarchy, and page density match the reference direction without copying browser-only layout rules.

### Round 2 — open-source Mermaid renderer

- Replaced the local Mermaid layout implementation with `mermaid-rs-renderer` behind a renderer-neutral port.
- Initial AppKit verification found that its SVG decoder ignored `tspan dy`, concatenating multiline Chinese labels.
- Fixed that incompatibility inside the adapter by converting upstream simple line spans into positioned SVG text elements while preserving the upstream view box and routing.

Result: the renderer remains swappable and the platform bridge does not reinterpret Mermaid layout.

### Round 3 — final verification

- Multiline labels are readable and node widths adapt to their Chinese content.
- Solid and labelled dashed connectors remain outside node text and terminate at node boundaries.
- The diagram keeps its intrinsic aspect ratio and is only scaled down when the editor viewport is narrower.
- Mermaid source remains editable in the same TextKit surface; while editing, the live diagram is placed below the source, and otherwise the source collapses to the diagram.
- The image overlay does not consume pointer hits, so selection and editing stay owned by the editor.

## Final result

Passed. No open P0, P1, or P2 visual defects were found in the requested list, typography, or Mermaid scope. Native app chrome and the open-source renderer's routing differ intentionally from the browser screenshot; content hierarchy, readable labels, adaptive sizing, and interaction semantics are preserved.
