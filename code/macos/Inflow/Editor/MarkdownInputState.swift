import Foundation

/// Owns the native-input/Engine acknowledgement boundary. Rendering and SwiftUI
/// cannot independently clear pending input or release an IME acknowledgement.
@MainActor
final class MarkdownInputState {
    enum BindingDecision { case deferred, unchanged, replace }

    struct CompositionResult {
        let shouldSubmit: Bool
        let acknowledgement: EditorEngineDocumentSnapshot?
    }

    private struct Composition {
        let pendingText: String?
        var acknowledgement: EditorEngineDocumentSnapshot?
    }

    private enum Phase {
        case synchronized
        case awaitingAcknowledgement(String)
        case composing(Composition)
    }

    private var phase = Phase.synchronized
    private var mutationDepth = 0
    var isApplyingEngineMutation: Bool { mutationDepth > 0 }

    func withEngineMutation<T>(_ body: () throws -> T) rethrows -> T {
        mutationDepth += 1
        defer { mutationDepth -= 1 }
        return try body()
    }

    func beginComposition() {
        guard !isApplyingEngineMutation else { return }
        switch phase {
        case .composing: break
        case .synchronized: phase = .composing(Composition(pendingText: nil))
        case let .awaitingAcknowledgement(text): phase = .composing(Composition(pendingText: text))
        }
    }

    /// Returns whether this committed edit must be submitted to the Engine.
    func recordNativeEdit(_ text: String, isComposing: Bool) -> Bool {
        guard !isApplyingEngineMutation else { return false }
        if isComposing { beginComposition(); return false }
        phase = .awaitingAcknowledgement(text)
        return true
    }

    func finishComposition(text: String, changed: Bool) -> CompositionResult {
        guard case let .composing(composition) = phase else {
            return CompositionResult(shouldSubmit: false, acknowledgement: nil)
        }
        let shouldSubmit = changed || composition.pendingText != nil
        phase = shouldSubmit ? .awaitingAcknowledgement(text) : .synchronized
        let matching = composition.acknowledgement.flatMap {
            UTF8Text.isExactlyEqual($0.text, text) ? $0 : nil
        }
        return CompositionResult(shouldSubmit: shouldSubmit, acknowledgement: matching)
    }

    /// Nil defers/ignores delivery; Bool says whether the acknowledgement commits
    /// the pending local edit. A rejected edit may legitimately restore Engine text.
    func acknowledge(_ snapshot: EditorEngineDocumentSnapshot, isComposing: Bool) -> Bool? {
        guard !isApplyingEngineMutation else { return nil }
        if isComposing { beginComposition() }
        switch phase {
        case var .composing(composition):
            composition.acknowledgement = snapshot
            phase = .composing(composition)
            return nil
        case let .awaitingAcknowledgement(text):
            phase = .synchronized
            return UTF8Text.isExactlyEqual(text, snapshot.text)
        case .synchronized:
            return false
        }
    }

    func bindingDecision(bound: String, native: String, isComposing: Bool) -> BindingDecision {
        guard !isComposing, !isApplyingEngineMutation else { return .deferred }
        if case .composing = phase { return .deferred }
        if UTF8Text.isExactlyEqual(bound, native) { return .unchanged }
        if case let .awaitingAcknowledgement(text) = phase,
           UTF8Text.isExactlyEqual(text, native) { return .unchanged }
        return .replace
    }

    func reset() { phase = .synchronized }
}
