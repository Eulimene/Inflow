import Foundation

/// One session-scoped plan, shared by writing commands and structural layout.
/// The builder is an explicit policy seam; no input command creates its own parser.
@MainActor
final class MarkdownLayoutPlanCache {
    typealias Builder = (String, PreviewAppearanceConfiguration) -> RenderedMarkdownPlan
    private let build: Builder
    private var plan: RenderedMarkdownPlan?
    private var configuration: PreviewAppearanceConfiguration?

    init(build: @escaping Builder = { source, configuration in
        RenderedMarkdownEditor.plan(for: source, configuration: configuration)
    }) { self.build = build }

    func resolve(source: String, configuration: PreviewAppearanceConfiguration) -> RenderedMarkdownPlan {
        if let plan, self.configuration == configuration, plan.exactlyMatches(source) { return plan }
        let result = build(source, configuration)
        install(result, configuration: configuration)
        return result
    }

    func install(_ plan: RenderedMarkdownPlan, configuration: PreviewAppearanceConfiguration) {
        self.plan = plan
        self.configuration = configuration
    }

    func invalidate() { plan = nil; configuration = nil }
}
