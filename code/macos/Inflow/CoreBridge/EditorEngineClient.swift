import Foundation
import os

private func withTemporaryEditorEngine<Result>(
    source: String,
    selection: EditorEngineSelection = EditorEngineSelection(start: 0, end: 0),
    _ body: (OpaquePointer) throws -> Result
) throws -> Result {
    guard InflowCoreBridge.isCompatible else {
        throw EditorEngineBridgeError.invalidHandle
    }
    let request = EditorEngineCreateRequest(
        schemaVersion: 1,
        documentID: UUID().uuidString,
        text: source,
        selection: selection,
        mode: .editable
    )
    let data = try JSONEncoder().encode(request)
    let created: InflowEngineCreateResult = data.withUnsafeBytes { bytes in
        inflow_engine_create(
            bytes.bindMemory(to: UInt8.self).baseAddress,
            UInt(bytes.count)
        )
    }
    let payload = try InflowCoreBridge.copyAndFree(created.payload)
    guard created.status == INFLOW_STATUS_OK, let handle = created.engine else {
        throw decodeEditorEngineBridgeError(status: created.status, payload: payload)
    }
    defer { inflow_engine_free(handle) }
    return try body(handle)
}

private func dispatchTemporaryEditorEngine<Envelope: Encodable>(
    _ envelope: Envelope,
    to handle: OpaquePointer
) throws -> EditorEngineDispatchResponse {
    let encoded = try JSONEncoder().encode(envelope)
    let result: InflowBytesResult = encoded.withUnsafeBytes { bytes in
        inflow_engine_dispatch(
            handle,
            bytes.bindMemory(to: UInt8.self).baseAddress,
            UInt(bytes.count)
        )
    }
    let payload = try InflowCoreBridge.copyAndFree(result.bytes)
    guard result.status == INFLOW_STATUS_OK else {
        throw decodeEditorEngineBridgeError(status: result.status, payload: payload)
    }
    return try JSONDecoder().decode(EditorEngineDispatchResponse.self, from: payload)
}

private func decodeEditorEngineBridgeError(
    status: InflowStatus,
    payload: Data
) -> EditorEngineBridgeError {
    let response = try? JSONDecoder().decode(EditorEngineErrorResponse.self, from: payload)
    return .core(
        status: status,
        code: response?.code ?? "unknown",
        revision: response?.revision
    )
}

extension EditorEngineDerivedContent {
    static func deriveSynchronously(
        source: String,
        configuration: PreviewAppearanceConfiguration = .default
    ) -> Self? {
        try? withTemporaryEditorEngine(source: source) { handle in
            let requestID = UUID().uuidString
            let envelope = EditorEngineRefreshEnvelope(
                schemaVersion: 1,
                requestID: requestID,
                command: EditorEngineRefreshCommand(
                    type: "refresh_derived",
                    revision: 0,
                    mathEnabled: configuration.mathRenderingEnabled,
                    mermaidEnabled: configuration.mermaidRenderingEnabled
                )
            )
            let response = try dispatchTemporaryEditorEngine(envelope, to: handle)
            guard response.requestID == requestID,
                  let derived = response.patch.derived
            else { return nil }
            return try? derived.validated(source: source)
        }
    }

}

extension DocumentSearchResult {
    static func searchSynchronously(
        source: String,
        query: String,
        caseSensitive: Bool
    ) -> Self? {
        try? withTemporaryEditorEngine(source: source) { handle in
            let requestID = UUID().uuidString
            let envelope = EditorEngineSearchEnvelope(
                schemaVersion: 1,
                requestID: requestID,
                command: EditorEngineSearchCommand(
                    type: "search",
                    revision: 0,
                    query: query,
                    caseSensitive: caseSensitive
                )
            )
            let response = try dispatchTemporaryEditorEngine(envelope, to: handle)
            guard response.requestID == requestID,
                  response.patch.baseRevision == 0,
                  response.patch.revision == 0,
                  let search = response.patch.search,
                  search.revision == 0
            else { return nil }
            return try search.validated(source: source)
        }
    }
}

enum EditorEngineSynchronousCommandError: Error {
    case invalidSelection
    case ambiguousFormat
    case invalidResponse
    case coreFailure
}

enum EditorEngineSynchronousCommands {
    static func format(
        source: String,
        selectedUTF16Range: NSRange,
        operation: EditorEngineFormatOperation
    ) throws -> EditorEngineMutation {
        guard let range = MarkdownSourceRange.utf8Range(
            forUTF16Range: selectedUTF16Range,
            in: source
        ) else {
            throw EditorEngineSynchronousCommandError.invalidSelection
        }
        do {
            return try withTemporaryEditorEngine(
                source: source,
                selection: EditorEngineSelection(start: range.lowerBound, end: range.upperBound)
            ) { handle in
                let requestID = UUID().uuidString
                let envelope = EditorEngineFormatEnvelope(
                    schemaVersion: 1,
                    requestID: requestID,
                    command: EditorEngineFormatCommand(
                        type: "format",
                        baseRevision: 0,
                        selection: EditorEngineSelection(
                            start: range.lowerBound,
                            end: range.upperBound
                        ),
                        operation: operation
                    )
                )
                let response = try dispatchTemporaryEditorEngine(envelope, to: handle)
                guard response.requestID == requestID,
                      response.patch.baseRevision == 0,
                      response.patch.revision == 1
                else { throw EditorEngineSynchronousCommandError.invalidResponse }
                return try response.patch.validatedMutation(source: source)
            }
        } catch let error as EditorEngineSynchronousCommandError {
            throw error
        } catch EditorEngineBridgeError.invalidSelection {
            throw EditorEngineSynchronousCommandError.invalidSelection
        } catch EditorEngineBridgeError.core(_, let code, _) {
            switch code {
            case "invalid_selection", "invalid_range":
                throw EditorEngineSynchronousCommandError.invalidSelection
            case "ambiguous_format":
                throw EditorEngineSynchronousCommandError.ambiguousFormat
            default:
                throw EditorEngineSynchronousCommandError.coreFailure
            }
        } catch is DecodingError {
            throw EditorEngineSynchronousCommandError.invalidResponse
        } catch {
            throw EditorEngineSynchronousCommandError.coreFailure
        }
    }

    static func canClearFormat(
        source: String,
        selectedUTF16Range: NSRange
    ) -> Bool {
        guard selectedUTF16Range.length > 0,
              let range = MarkdownSourceRange.utf8Range(
                  forUTF16Range: selectedUTF16Range,
                  in: source
              )
        else { return false }
        return (try? withTemporaryEditorEngine(
            source: source,
            selection: EditorEngineSelection(start: range.lowerBound, end: range.upperBound)
        ) { handle in
            let requestID = UUID().uuidString
            let envelope = EditorEngineInspectFormatEnvelope(
                schemaVersion: 1,
                requestID: requestID,
                command: EditorEngineInspectFormatCommand(
                    type: "inspect_format",
                    revision: 0,
                    selection: EditorEngineSelection(
                        start: range.lowerBound,
                        end: range.upperBound
                    )
                )
            )
            let response = try dispatchTemporaryEditorEngine(envelope, to: handle)
            guard response.requestID == requestID,
                  response.patch.baseRevision == 0,
                  response.patch.revision == 0,
                  let capabilities = response.patch.formatCapabilities,
                  capabilities.revision == 0
            else { throw EditorEngineSynchronousCommandError.invalidResponse }
            return capabilities.canClear
        }) ?? false
    }
}

@MainActor
final class EditorEngineClient {
    private let client = EditorEngineTransport()
    private var lastSubmittedText: String?
    private var pending: Task<Void, Never>?
    var onHistoryStateChange: ((Bool, Bool) -> Void)?
    var onAuthoritativeSnapshot: ((EditorEngineDocumentSnapshot) -> Void)?

    func submit(
        text: String,
        selectionUTF16: NSRange,
        groupID: String? = nil
    ) {
        guard lastSubmittedText.map({ !$0.utf8.elementsEqual(text.utf8) }) ?? true
        else { return }
        lastSubmittedText = text
        let previous = pending
        pending = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            guard let snapshot = await client.synchronize(
                to: text,
                selectionUTF16: selectionUTF16,
                groupID: groupID
            ) else { return }
            guard !Task.isCancelled,
                  lastSubmittedText?.utf8.elementsEqual(text.utf8) == true
            else { return }
            lastSubmittedText = snapshot.text
            onHistoryStateChange?(snapshot.canUndo, snapshot.canRedo)
            onAuthoritativeSnapshot?(snapshot)
        }
    }

    func derive(
        text: String,
        selectionUTF16: NSRange,
        configuration: PreviewAppearanceConfiguration
    ) async -> EditorEngineDerivedContent? {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled else { return nil }
        return await client.derive(
            expectedText: text,
            mathEnabled: configuration.mathRenderingEnabled,
            mermaidEnabled: configuration.mermaidRenderingEnabled
        )
    }

    func format(
        text: String,
        selectionUTF16: NSRange,
        operation: EditorEngineFormatOperation
    ) async -> EditorEngineMutation? {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled,
              let mutation = await client.format(
                  expectedText: text,
                  selectionUTF16: selectionUTF16,
                  operation: operation
              )
        else { return nil }
        if lastSubmittedText?.utf8.elementsEqual(text.utf8) == true {
            lastSubmittedText = mutation.resultingSource
        }
        onHistoryStateChange?(mutation.canUndo, mutation.canRedo)
        return mutation
    }

    func replace(
        text: String,
        range: Range<Int>,
        replacement: String,
        selectionBeforeUTF16: NSRange,
        selectionAfterUTF8: Range<Int>,
        groupID: String
    ) async -> EditorEngineMutation? {
        submit(text: text, selectionUTF16: selectionBeforeUTF16)
        await pending?.value
        guard !Task.isCancelled,
              let mutation = await client.replace(
                  expectedText: text,
                  range: range,
                  replacement: replacement,
                  selectionBeforeUTF16: selectionBeforeUTF16,
                  selectionAfterUTF8: selectionAfterUTF8,
                  groupID: groupID
              )
        else { return nil }
        lastSubmittedText = mutation.resultingSource
        onHistoryStateChange?(mutation.canUndo, mutation.canRedo)
        return mutation
    }

    func search(
        text: String,
        selectionUTF16: NSRange,
        query: String,
        caseSensitive: Bool
    ) async -> DocumentSearchResult? {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled else { return nil }
        return await client.search(
            expectedText: text,
            query: query,
            caseSensitive: caseSensitive
        )
    }

    func canClearFormat(
        text: String,
        selectionUTF16: NSRange
    ) async -> Bool {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled else { return false }
        return await client.canClearFormat(
            expectedText: text,
            selectionUTF16: selectionUTF16
        )
    }

    func undo(text: String, selectionUTF16: NSRange) async -> EditorEngineMutation? {
        await historyMutation(
            direction: .undo,
            text: text,
            selectionUTF16: selectionUTF16
        )
    }

    func redo(text: String, selectionUTF16: NSRange) async -> EditorEngineMutation? {
        await historyMutation(
            direction: .redo,
            text: text,
            selectionUTF16: selectionUTF16
        )
    }

    func authoritativeSnapshot(
        matching text: String,
        selectionUTF16: NSRange
    ) async -> EditorEngineDocumentSnapshot? {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled else { return nil }
        return await client.snapshot(expectedText: text)
    }

    func prepareSave(
        text: String,
        selectionUTF16: NSRange
    ) async -> EditorEngineSavePreparation? {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled else { return nil }
        return await client.prepareSave(expectedText: text)
    }

    func saveCompleted(_ preparation: EditorEngineSavePreparation) async -> Bool {
        await pending?.value
        guard !Task.isCancelled else { return false }
        return await client.finishSave(saveID: preparation.saveID, completed: true)
    }

    func saveAborted(_ preparation: EditorEngineSavePreparation) async {
        await pending?.value
        guard !Task.isCancelled else { return }
        _ = await client.finishSave(saveID: preparation.saveID, completed: false)
    }

    func setMode(
        _ mode: EditorEngineMode,
        text: String,
        selectionUTF16: NSRange
    ) async -> Bool {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled else { return false }
        return await client.setMode(mode, expectedText: text)
    }

    func reset(text: String, selectionUTF16: NSRange) {
        lastSubmittedText = text
        let previous = pending
        pending = Task {
            await previous?.value
            guard !Task.isCancelled,
                  let snapshot = await client.reset(
                      text: text,
                      selectionUTF16: selectionUTF16
                  )
            else { return }
            onHistoryStateChange?(snapshot.canUndo, snapshot.canRedo)
            onAuthoritativeSnapshot?(snapshot)
        }
    }

    deinit {
        pending?.cancel()
    }

    private func historyMutation(
        direction: EditorEngineHistoryDirection,
        text: String,
        selectionUTF16: NSRange
    ) async -> EditorEngineMutation? {
        submit(text: text, selectionUTF16: selectionUTF16)
        await pending?.value
        guard !Task.isCancelled,
              let mutation = await client.historyMutation(
                  direction: direction,
                  expectedText: text
              )
        else { return nil }
        lastSubmittedText = mutation.resultingSource
        onHistoryStateChange?(mutation.canUndo, mutation.canRedo)
        return mutation
    }
}

private enum EditorEngineHistoryDirection: String, Sendable {
    case undo
    case redo
}

private final class EditorEngineHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        inflow_engine_free(pointer)
    }
}

private actor EditorEngineTransport {
    private static let schemaVersion: UInt32 = 1
    private let logger = Logger(subsystem: "com.inflow.desktop", category: "EditorEngine")
    private var handle: EditorEngineHandle?
    private var projection = ""
    private var revision: UInt64 = 0
    private var mode: EditorEngineMode = .editable

    func synchronize(
        to swiftText: String,
        selectionUTF16: NSRange,
        groupID: String?
    ) -> EditorEngineDocumentSnapshot? {
        do {
            let selection = try Self.byteSelection(selectionUTF16, in: swiftText)
            guard handle != nil else {
                try create(text: swiftText, selection: selection)
                return try authoritativeSnapshot()
            }
            guard let edit = EditorEngineTextDiff.replacement(
                from: projection,
                to: swiftText
            ) else {
                try compareSnapshot(to: swiftText)
                return try authoritativeSnapshot()
            }

            let requestID = UUID().uuidString
            let command = EditorEngineCommandEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineReplaceCommand(
                    type: "replace_text",
                    baseRevision: revision,
                    range: EditorEngineByteRange(start: edit.start, end: edit.end),
                    inserted: edit.inserted,
                    selectionBefore: nil,
                    selectionAfter: selection,
                    groupID: groupID
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(command)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision + 1
            else {
                throw EditorEngineBridgeError.invalidResponse
            }

            revision = response.patch.revision
            projection = swiftText
            try compareSnapshot(to: swiftText)
            return try authoritativeSnapshot()
        } catch {
            logger.error(
                "Engine synchronization failed; command=replace_text revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            do {
                return try authoritativeSnapshot()
            } catch {
                logger.error(
                    "Engine snapshot recovery failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
    }

    func reset(
        text: String,
        selectionUTF16: NSRange
    ) -> EditorEngineDocumentSnapshot? {
        do {
            let selection = try Self.byteSelection(selectionUTF16, in: text)
            if handle == nil {
                try create(text: text, selection: selection)
            } else {
                try openDocument(text: text, selection: selection)
            }
            return snapshot(expectedText: text)
        } catch {
            logger.error(
                "Engine reset failed; revision=0 error=\(String(describing: error), privacy: .public)"
            )
            handle = nil
            projection = ""
            revision = 0
            return nil
        }
    }

    func derive(
        expectedText: String,
        mathEnabled: Bool,
        mermaidEnabled: Bool
    ) -> EditorEngineDerivedContent? {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let requestID = UUID().uuidString
            let envelope = EditorEngineRefreshEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineRefreshCommand(
                    type: "refresh_derived",
                    revision: revision,
                    mathEnabled: mathEnabled,
                    mermaidEnabled: mermaidEnabled
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.revision == revision,
                  let raw = response.patch.derived,
                  raw.revision == revision,
                  raw.mathEnabled == mathEnabled,
                  raw.mermaidEnabled == mermaidEnabled
            else {
                throw EditorEngineBridgeError.invalidResponse
            }
            return try raw.validated(source: expectedText)
        } catch {
            logger.error(
                "Unified derivation failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func format(
        expectedText: String,
        selectionUTF16: NSRange,
        operation: EditorEngineFormatOperation
    ) -> EditorEngineMutation? {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let selection = try Self.byteSelection(selectionUTF16, in: expectedText)
            let requestID = UUID().uuidString
            let envelope = EditorEngineFormatEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineFormatCommand(
                    type: "format",
                    baseRevision: revision,
                    selection: selection,
                    operation: operation
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision + 1
            else { throw EditorEngineBridgeError.invalidResponse }
            let mutation = try response.patch.validatedMutation(source: expectedText)
            revision = mutation.revision
            projection = mutation.resultingSource
            try compareSnapshot(to: mutation.resultingSource)
            return mutation
        } catch {
            logger.error(
                "Engine format failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func replace(
        expectedText: String,
        range: Range<Int>,
        replacement: String,
        selectionBeforeUTF16: NSRange,
        selectionAfterUTF8: Range<Int>,
        groupID: String
    ) -> EditorEngineMutation? {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8),
                  range.lowerBound >= 0,
                  range.lowerBound <= range.upperBound,
                  range.upperBound <= expectedText.utf8.count
            else { throw EditorEngineBridgeError.invalidSelection }
            let resultingLength = expectedText.utf8.count - range.count + replacement.utf8.count
            guard
                  selectionAfterUTF8.lowerBound >= 0,
                  selectionAfterUTF8.lowerBound <= selectionAfterUTF8.upperBound,
                  selectionAfterUTF8.upperBound <= resultingLength
            else { throw EditorEngineBridgeError.invalidSelection }
            let selectionBefore = try Self.byteSelection(selectionBeforeUTF16, in: expectedText)
            let requestID = UUID().uuidString
            let envelope = EditorEngineCommandEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineReplaceCommand(
                    type: "replace_text",
                    baseRevision: revision,
                    range: EditorEngineByteRange(start: range.lowerBound, end: range.upperBound),
                    inserted: replacement,
                    selectionBefore: selectionBefore,
                    selectionAfter: EditorEngineSelection(
                        start: selectionAfterUTF8.lowerBound,
                        end: selectionAfterUTF8.upperBound
                    ),
                    groupID: groupID
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision + 1
            else { throw EditorEngineBridgeError.invalidResponse }
            let mutation = try response.patch.validatedMutation(source: expectedText)
            revision = mutation.revision
            projection = mutation.resultingSource
            try compareSnapshot(to: mutation.resultingSource)
            return mutation
        } catch {
            logger.error(
                "Engine replacement failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func search(
        expectedText: String,
        query: String,
        caseSensitive: Bool
    ) -> DocumentSearchResult? {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let requestID = UUID().uuidString
            let envelope = EditorEngineSearchEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineSearchCommand(
                    type: "search",
                    revision: revision,
                    query: query,
                    caseSensitive: caseSensitive
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision,
                  let search = response.patch.search,
                  search.revision == revision
            else { throw EditorEngineBridgeError.invalidResponse }
            return try search.validated(source: expectedText)
        } catch {
            logger.error(
                "Engine search failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func canClearFormat(
        expectedText: String,
        selectionUTF16: NSRange
    ) -> Bool {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let selection = try Self.byteSelection(selectionUTF16, in: expectedText)
            let requestID = UUID().uuidString
            let envelope = EditorEngineInspectFormatEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineInspectFormatCommand(
                    type: "inspect_format",
                    revision: revision,
                    selection: selection
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision,
                  let capabilities = response.patch.formatCapabilities,
                  capabilities.revision == revision
            else { throw EditorEngineBridgeError.invalidResponse }
            return capabilities.canClear
        } catch {
            logger.error(
                "Engine format inspection failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    func prepareSave(expectedText: String) -> EditorEngineSavePreparation? {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let saveID = UUID().uuidString
            let requestID = UUID().uuidString
            let envelope = EditorEnginePrepareSaveEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEnginePrepareSaveCommand(
                    type: "prepare_save",
                    revision: revision,
                    saveID: saveID
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision,
                  response.patch.effects.count == 1,
                  let raw = response.patch.effects.first,
                  raw.type == "write_document",
                  let rawSaveID = raw.saveID,
                  let rawRevision = raw.revision,
                  let rawText = raw.text,
                  let rawContentHash = raw.contentHash,
                  rawSaveID == saveID,
                  rawRevision == revision,
                  rawText.utf8.elementsEqual(expectedText.utf8)
            else { throw EditorEngineBridgeError.invalidResponse }
            return EditorEngineSavePreparation(
                saveID: rawSaveID,
                revision: rawRevision,
                text: rawText,
                contentHash: rawContentHash
            )
        } catch {
            logger.error(
                "Engine save preparation failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func finishSave(saveID: String, completed: Bool) -> Bool {
        do {
            let requestID = UUID().uuidString
            let envelope = EditorEngineFinishSaveEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineFinishSaveCommand(
                    type: completed ? "save_completed" : "save_aborted",
                    saveID: saveID
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.revision == revision,
                  response.patch.text == nil
            else { throw EditorEngineBridgeError.invalidResponse }
            return true
        } catch {
            logger.error(
                "Engine save completion failed; revision=\(self.revision, privacy: .public) completed=\(completed, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    func setMode(_ requestedMode: EditorEngineMode, expectedText: String) -> Bool {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let requestID = UUID().uuidString
            let envelope = EditorEngineSetModeEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineSetModeCommand(
                    type: "set_mode",
                    revision: revision,
                    mode: requestedMode
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision,
                  response.patch.mode == requestedMode,
                  response.patch.text == nil
            else { throw EditorEngineBridgeError.invalidResponse }
            mode = requestedMode
            return true
        } catch {
            logger.error(
                "Engine mode change failed; revision=\(self.revision, privacy: .public) mode=\(requestedMode.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    func historyMutation(
        direction: EditorEngineHistoryDirection,
        expectedText: String
    ) -> EditorEngineMutation? {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let requestID = UUID().uuidString
            let envelope = EditorEngineHistoryEnvelope(
                schemaVersion: Self.schemaVersion,
                requestID: requestID,
                command: EditorEngineHistoryCommand(
                    type: direction.rawValue,
                    baseRevision: revision
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(envelope)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision + 1
            else { throw EditorEngineBridgeError.invalidResponse }
            let mutation = try response.patch.validatedMutation(source: expectedText)
            revision = mutation.revision
            projection = mutation.resultingSource
            try compareSnapshot(to: mutation.resultingSource)
            return mutation
        } catch {
            logger.error(
                "Engine \(direction.rawValue, privacy: .public) failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func snapshot(expectedText: String) -> EditorEngineDocumentSnapshot? {
        do {
            guard projection.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: revision)
            }
            let snapshot = try authoritativeSnapshot()
            guard snapshot.text.utf8.elementsEqual(expectedText.utf8) else {
                throw EditorEngineBridgeError.mismatch(revision: snapshot.revision)
            }
            return snapshot
        } catch {
            logger.error(
                "Engine snapshot failed; revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private func create(text: String, selection: EditorEngineSelection) throws {
        let request = EditorEngineCreateRequest(
            schemaVersion: Self.schemaVersion,
            documentID: UUID().uuidString,
            text: text,
            selection: selection,
            mode: mode
        )
        let encoded = try JSONEncoder().encode(request)
        let result: InflowEngineCreateResult = encoded.withUnsafeBytes { buffer in
            inflow_engine_create(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        let payload = try InflowCoreBridge.copyAndFree(result.payload)
        guard result.status == INFLOW_STATUS_OK, let pointer = result.engine else {
            throw Self.bridgeError(status: result.status, payload: payload)
        }

        let snapshot = try JSONDecoder().decode(EditorEngineSnapshot.self, from: payload)
        guard snapshot.schemaVersion == Self.schemaVersion,
              snapshot.revision == 0,
              snapshot.text == text,
              snapshot.selection == selection,
              snapshot.mode == mode
        else {
            inflow_engine_free(pointer)
            throw EditorEngineBridgeError.mismatch(revision: snapshot.revision)
        }
        handle = EditorEngineHandle(pointer: pointer)
        projection = text
        revision = snapshot.revision
    }

    private func openDocument(text: String, selection: EditorEngineSelection) throws {
        let requestID = UUID().uuidString
        let envelope = EditorEngineOpenDocumentEnvelope(
            schemaVersion: Self.schemaVersion,
            requestID: requestID,
            command: EditorEngineOpenDocumentCommand(
                type: "open_document",
                baseRevision: revision,
                text: text,
                selection: selection
            )
        )
        let response: EditorEngineDispatchResponse = try dispatch(envelope)
        guard response.schemaVersion == Self.schemaVersion,
              response.requestID == requestID,
              response.patch.baseRevision == revision,
              response.patch.revision == revision + 1,
              response.patch.mode == mode,
              !response.patch.canUndo,
              !response.patch.canRedo,
              !response.patch.dirty
        else { throw EditorEngineBridgeError.invalidResponse }
        let mutation = try response.patch.validatedMutation(source: projection)
        guard mutation.resultingSource.utf8.elementsEqual(text.utf8) else {
            throw EditorEngineBridgeError.invalidResponse
        }
        revision = mutation.revision
        projection = mutation.resultingSource
        try compareSnapshot(to: text)
    }

    private func dispatch<T: Encodable, Response: Decodable>(_ command: T) throws -> Response {
        guard let handle else { throw EditorEngineBridgeError.invalidHandle }
        let encoded = try JSONEncoder().encode(command)
        let result: InflowBytesResult = encoded.withUnsafeBytes { buffer in
            inflow_engine_dispatch(
                handle.pointer,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        let payload = try InflowCoreBridge.copyAndFree(result.bytes)
        guard result.status == INFLOW_STATUS_OK else {
            throw Self.bridgeError(status: result.status, payload: payload)
        }
        return try JSONDecoder().decode(Response.self, from: payload)
    }

    private func compareSnapshot(to swiftText: String) throws {
        let snapshot = try readSnapshot()
        guard snapshot.schemaVersion == Self.schemaVersion,
              snapshot.revision == revision,
              snapshot.text.utf8.elementsEqual(swiftText.utf8),
              snapshot.mode == mode
        else {
            throw EditorEngineBridgeError.mismatch(revision: snapshot.revision)
        }
    }

    private func authoritativeSnapshot() throws -> EditorEngineDocumentSnapshot {
        let snapshot = try readSnapshot()
        guard snapshot.schemaVersion == Self.schemaVersion,
              let selection = snapshot.selection.validated(
                  in: snapshot.text,
                  permitsEmpty: true
              )
        else { throw EditorEngineBridgeError.invalidResponse }
        revision = snapshot.revision
        projection = snapshot.text
        mode = snapshot.mode
        return EditorEngineDocumentSnapshot(
            revision: snapshot.revision,
            text: snapshot.text,
            selectionUTF8Range: selection,
            mode: snapshot.mode,
            contentHash: snapshot.contentHash,
            canUndo: snapshot.canUndo,
            canRedo: snapshot.canRedo,
            dirty: snapshot.dirty
        )
    }

    private func readSnapshot() throws -> EditorEngineSnapshot {
        guard let handle else { throw EditorEngineBridgeError.invalidHandle }
        let result = inflow_engine_snapshot(handle.pointer)
        let payload = try InflowCoreBridge.copyAndFree(result.bytes)
        guard result.status == INFLOW_STATUS_OK else {
            throw Self.bridgeError(status: result.status, payload: payload)
        }
        return try JSONDecoder().decode(EditorEngineSnapshot.self, from: payload)
    }

    private static func byteSelection(
        _ utf16Range: NSRange,
        in text: String
    ) throws -> EditorEngineSelection {
        guard let range = Range(utf16Range, in: text),
              let lower = range.lowerBound.samePosition(in: text.utf8),
              let upper = range.upperBound.samePosition(in: text.utf8)
        else {
            throw EditorEngineBridgeError.invalidSelection
        }
        return EditorEngineSelection(
            start: text.utf8.distance(from: text.utf8.startIndex, to: lower),
            end: text.utf8.distance(from: text.utf8.startIndex, to: upper)
        )
    }

    private static func bridgeError(status: InflowStatus, payload: Data) -> Error {
        if let response = try? JSONDecoder().decode(EditorEngineErrorResponse.self, from: payload) {
            return EditorEngineBridgeError.core(
                status: status,
                code: response.code,
                revision: response.revision
            )
        }
        return EditorEngineBridgeError.core(status: status, code: "unknown", revision: nil)
    }
}

private enum EditorEngineBridgeError: Error, CustomStringConvertible {
    case invalidHandle
    case invalidResponse
    case invalidSelection
    case mismatch(revision: UInt64)
    case core(status: InflowStatus, code: String, revision: UInt64?)

    var description: String {
        switch self {
        case .invalidHandle: "invalid_handle"
        case .invalidResponse: "invalid_response"
        case .invalidSelection: "invalid_selection"
        case let .mismatch(revision): "projection_mismatch@\(revision)"
        case let .core(status, code, revision):
            "core_\(status)_\(code)@\(revision.map(String.init) ?? "unknown")"
        }
    }
}

private struct EditorEngineCreateRequest: Encodable {
    let schemaVersion: UInt32
    let documentID: String
    let text: String
    let selection: EditorEngineSelection
    let mode: EditorEngineMode

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case documentID = "document_id"
        case text
        case selection
        case mode
    }
}

private struct EditorEngineSetModeEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineSetModeCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineSetModeCommand: Encodable {
    let type: String
    let revision: UInt64
    let mode: EditorEngineMode
}

private struct EditorEngineOpenDocumentEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineOpenDocumentCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineOpenDocumentCommand: Encodable {
    let type: String
    let baseRevision: UInt64
    let text: String
    let selection: EditorEngineSelection

    enum CodingKeys: String, CodingKey {
        case type
        case baseRevision = "base_revision"
        case text
        case selection
    }
}

private struct EditorEngineCommandEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineReplaceCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineRefreshEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineRefreshCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineFormatEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineFormatCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineSearchEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineSearchCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineInspectFormatEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineInspectFormatCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEnginePrepareSaveEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEnginePrepareSaveCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineFinishSaveEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineFinishSaveCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineHistoryEnvelope: Encodable {
    let schemaVersion: UInt32
    let requestID: String
    let command: EditorEngineHistoryCommand

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case command
    }
}

private struct EditorEngineHistoryCommand: Encodable {
    let type: String
    let baseRevision: UInt64

    enum CodingKeys: String, CodingKey {
        case type
        case baseRevision = "base_revision"
    }
}

private struct EditorEngineSearchCommand: Encodable {
    let type: String
    let revision: UInt64
    let query: String
    let caseSensitive: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case revision
        case query
        case caseSensitive = "case_sensitive"
    }
}

private struct EditorEngineInspectFormatCommand: Encodable {
    let type: String
    let revision: UInt64
    let selection: EditorEngineSelection
}

private struct EditorEnginePrepareSaveCommand: Encodable {
    let type: String
    let revision: UInt64
    let saveID: String

    enum CodingKeys: String, CodingKey {
        case type
        case revision
        case saveID = "save_id"
    }
}

private struct EditorEngineFinishSaveCommand: Encodable {
    let type: String
    let saveID: String

    enum CodingKeys: String, CodingKey {
        case type
        case saveID = "save_id"
    }
}

private struct EditorEngineFormatCommand: Encodable {
    let type: String
    let baseRevision: UInt64
    let selection: EditorEngineSelection
    let operation: EditorEngineFormatOperation

    enum CodingKeys: String, CodingKey {
        case type
        case baseRevision = "base_revision"
        case selection
        case operation
    }
}

extension EditorEngineFormatOperation: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case level
        case style
        case destination
        case defaultAlternative = "default_alternative"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bold: try container.encode("bold", forKey: .kind)
        case .italic: try container.encode("italic", forKey: .kind)
        case .strikethrough: try container.encode("strikethrough", forKey: .kind)
        case .inlineCode: try container.encode("inline_code", forKey: .kind)
        case .codeBlock: try container.encode("code_block", forKey: .kind)
        case .clear: try container.encode("clear", forKey: .kind)
        case let .heading(level):
            try container.encode("heading", forKey: .kind)
            try container.encode(level, forKey: .level)
        case .blockQuote: try container.encode("block_quote", forKey: .kind)
        case let .list(style):
            try container.encode("list", forKey: .kind)
            try container.encode(style, forKey: .style)
        case let .link(destination):
            try container.encode("link", forKey: .kind)
            try container.encode(destination, forKey: .destination)
        case let .image(destination, defaultAlternative):
            try container.encode("image", forKey: .kind)
            try container.encode(destination, forKey: .destination)
            try container.encode(defaultAlternative, forKey: .defaultAlternative)
        case .table: try container.encode("table", forKey: .kind)
        case .horizontalRule: try container.encode("horizontal_rule", forKey: .kind)
        case .footnote: try container.encode("footnote", forKey: .kind)
        case .math: try container.encode("math", forKey: .kind)
        case .mermaid: try container.encode("mermaid", forKey: .kind)
        }
    }
}

private struct EditorEngineRefreshCommand: Encodable {
    let type: String
    let revision: UInt64
    let mathEnabled: Bool
    let mermaidEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case revision
        case mathEnabled = "math_enabled"
        case mermaidEnabled = "mermaid_enabled"
    }
}

private struct EditorEngineReplaceCommand: Encodable {
    let type: String
    let baseRevision: UInt64
    let range: EditorEngineByteRange
    let inserted: String
    let selectionBefore: EditorEngineSelection?
    let selectionAfter: EditorEngineSelection
    let groupID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case baseRevision = "base_revision"
        case range
        case inserted
        case selectionBefore = "selection_before"
        case selectionAfter = "selection_after"
        case groupID = "group_id"
    }
}

private struct EditorEngineByteRange: Codable, Equatable {
    let start: Int
    let end: Int
}

private struct EditorEngineSelection: Codable, Equatable {
    let start: Int
    let end: Int
}

private struct EditorEngineSnapshot: Decodable {
    let schemaVersion: UInt32
    let documentID: String
    let revision: UInt64
    let text: String
    let selection: EditorEngineSelection
    let mode: EditorEngineMode
    let contentHash: String
    let canUndo: Bool
    let canRedo: Bool
    let dirty: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case documentID = "document_id"
        case revision
        case text
        case selection
        case mode
        case contentHash = "content_hash"
        case canUndo = "can_undo"
        case canRedo = "can_redo"
        case dirty
    }
}

private struct EditorEngineDispatchResponse: Decodable {
    let schemaVersion: UInt32
    let requestID: String
    let patch: EditorEngineStatePatch

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case patch
    }
}

private struct EditorEngineStatePatch: Decodable {
    let baseRevision: UInt64
    let revision: UInt64
    let mode: EditorEngineMode
    let text: EditorEngineTextPatch?
    let selection: EditorEngineSelection?
    let derived: EditorEngineDerivedState?
    let search: EditorEngineRawSearchResult?
    let formatCapabilities: EditorEngineRawFormatCapabilities?
    let effects: [EditorEngineRawHostEffect]
    let canUndo: Bool
    let canRedo: Bool
    let dirty: Bool

    enum CodingKeys: String, CodingKey {
        case baseRevision = "base_revision"
        case revision
        case mode
        case text
        case selection
        case derived
        case search
        case formatCapabilities = "format_capabilities"
        case effects
        case canUndo = "can_undo"
        case canRedo = "can_redo"
        case dirty
    }


    func validatedMutation(source: String) throws -> EditorEngineMutation {
        guard let text,
              let selection,
              let replaceRange = text.range.validated(in: source, permitsEmpty: true)
        else { throw EditorEngineBridgeError.invalidResponse }
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(replaceRange, with: text.inserted.utf8)
        let resultingSource = String(decoding: bytes, as: UTF8.self)
        guard Array(resultingSource.utf8) == bytes,
              let selectionRange = selection.validated(
                  in: resultingSource,
                  permitsEmpty: true
              )
        else { throw EditorEngineBridgeError.invalidResponse }
        return EditorEngineMutation(
            baseRevision: baseRevision,
            revision: revision,
            sourceSnapshot: source,
            replaceUTF8Range: replaceRange,
            replacement: text.inserted,
            resultingSource: resultingSource,
            selectionUTF8Range: selectionRange,
            canUndo: canUndo,
            canRedo: canRedo
        )
    }
}

private struct EditorEngineRawHostEffect: Decodable {
    let type: String
    let saveID: String?
    let revision: UInt64?
    let text: String?
    let contentHash: String?

    enum CodingKeys: String, CodingKey {
        case type
        case saveID = "save_id"
        case revision
        case text
        case contentHash = "content_hash"
    }
}

private struct EditorEngineRawFormatCapabilities: Decodable {
    let revision: UInt64
    let canClear: Bool

    enum CodingKeys: String, CodingKey {
        case revision
        case canClear = "can_clear"
    }
}

private struct EditorEngineRawSearchResult: Decodable {
    let revision: UInt64
    let matches: [EditorEngineByteRange]

    func validated(source: String) throws -> DocumentSearchResult {
        let sourceUTF8 = Data(source.utf8)
        var validatedMatches: [DocumentSearchMatch] = []
        validatedMatches.reserveCapacity(matches.count)
        var matchedTextCounts: [Data: Int] = [:]
        var previousEnd = 0

        for match in matches {
            guard let range = match.validated(in: source, permitsEmpty: false),
                  range.lowerBound >= previousEnd
            else { throw EditorEngineBridgeError.invalidResponse }
            let matchedUTF8 = sourceUTF8.subdata(in: range)
            validatedMatches.append(
                DocumentSearchMatch(utf8Range: range, matchedUTF8: matchedUTF8)
            )
            matchedTextCounts[matchedUTF8, default: 0] += 1
            previousEnd = range.upperBound
        }
        return DocumentSearchResult(
            matches: validatedMatches,
            matchedTextCounts: matchedTextCounts
        )
    }
}

private struct EditorEngineTextPatch: Decodable {
    let range: EditorEngineByteRange
    let inserted: String
}

private struct EditorEngineDerivedState: Decodable {
    let revision: UInt64
    let analysis: EditorEngineAnalysis
    let highlights: [EditorEngineHighlight]
    let references: [EditorEngineReference]
    let render: EditorEngineRender
    let nativeRender: EditorEngineRawNativeRenderPlan
    let htmlFragment: String
    let mathEnabled: Bool
    let mermaidEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case revision
        case analysis
        case highlights
        case references
        case render
        case nativeRender = "native_render"
        case htmlFragment = "html_fragment"
        case mathEnabled = "math_enabled"
        case mermaidEnabled = "mermaid_enabled"
    }

    func validated(source: String) throws -> EditorEngineDerivedContent {
        let headings = try analysis.headings.map { heading in
            guard (1...6).contains(heading.level),
                  let range = heading.sourceRange.validated(in: source, permitsEmpty: false)
            else { throw EditorEngineBridgeError.invalidResponse }
            return DocumentHeading(level: heading.level, title: heading.title, sourceUTF8Range: range)
        }
        guard let wordCount = Int(exactly: analysis.wordCount),
              let withSpaces = Int(exactly: analysis.characterCountWithSpaces),
              let withoutSpaces = Int(exactly: analysis.characterCountWithoutSpaces)
        else { throw EditorEngineBridgeError.invalidResponse }

        let highlightRanges = try highlights.map { highlight in
            guard let kind = highlight.kind.syntaxKind,
                  let range = highlight.sourceRange.validated(in: source, permitsEmpty: false)
            else { throw EditorEngineBridgeError.invalidResponse }
            return (kind, range)
        }
        guard let utf16Ranges = MarkdownSyntaxRange.utf16Ranges(
            for: highlightRanges.map(\.1),
            in: source
        ) else { throw EditorEngineBridgeError.invalidResponse }
        let syntax = zip(highlightRanges, utf16Ranges).map { value, utf16Range in
            MarkdownSyntaxSpan(kind: value.0, utf8Range: value.1, utf16Range: utf16Range)
        }

        let validatedReferences = try references.map { reference in
            guard let kind = MarkdownReferenceKind(rawValue: reference.kind),
                  let range = reference.sourceRange.validated(in: source, permitsEmpty: false)
            else { throw EditorEngineBridgeError.invalidResponse }
            return MarkdownReference(kind: kind, target: reference.target, sourceUTF8Range: range)
        }
        let blocks = try render.blocks.map { block in
            guard let range = block.sourceRange.validated(in: source, permitsEmpty: false),
                  let depth = Int(exactly: block.depth)
            else { throw EditorEngineBridgeError.invalidResponse }
            return EditorEngineRenderBlock(
                id: block.blockID,
                kind: block.kind,
                sourceUTF8Range: range,
                depth: depth,
                parentID: block.parentID,
                visibleText: block.visibleText
            )
        }
        let nativeRenderPlan = try nativeRender.validated(source: source)

        return EditorEngineDerivedContent(
            revision: revision,
            sourceSnapshot: source,
            htmlFragment: htmlFragment,
            analysis: DocumentAnalysis(
                headings: headings,
                wordCount: wordCount,
                characterCountIncludingSpaces: withSpaces,
                characterCountExcludingSpaces: withoutSpaces
            ),
            syntaxHighlighting: syntax,
            references: validatedReferences,
            renderBlocks: blocks,
            nativeRenderPlan: nativeRenderPlan
        )
    }
}

private struct EditorEngineAnalysis: Decodable {
    let headings: [EditorEngineHeading]
    let wordCount: UInt64
    let characterCountWithSpaces: UInt64
    let characterCountWithoutSpaces: UInt64

    enum CodingKeys: String, CodingKey {
        case headings
        case wordCount = "word_count"
        case characterCountWithSpaces = "character_count_with_spaces"
        case characterCountWithoutSpaces = "character_count_without_spaces"
    }
}

private struct EditorEngineHeading: Decodable {
    let level: Int
    let title: String
    let sourceRange: EditorEngineByteRange

    enum CodingKeys: String, CodingKey {
        case level
        case title
        case sourceRange = "source_range"
    }
}

private struct EditorEngineHighlight: Decodable {
    let kind: String
    let sourceRange: EditorEngineByteRange

    enum CodingKeys: String, CodingKey {
        case kind
        case sourceRange = "source_range"
    }
}

private struct EditorEngineReference: Decodable {
    let kind: String
    let target: String
    let sourceRange: EditorEngineByteRange

    enum CodingKeys: String, CodingKey {
        case kind
        case target
        case sourceRange = "source_range"
    }
}

private struct EditorEngineRender: Decodable {
    let blocks: [EditorEngineRawRenderBlock]
}

private struct EditorEngineRawRenderBlock: Decodable {
    let blockID: String
    let kind: String
    let sourceRange: EditorEngineByteRange
    let depth: UInt64
    let parentID: String?
    let visibleText: String

    enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case kind
        case sourceRange = "source_range"
        case depth
        case parentID = "parent_id"
        case visibleText = "visible_text"
    }
}

private struct EditorEngineRawNativeRenderPlan: Decodable {
    let markers: [Marker]
    let contentStyles: [ContentStyle]
    let localSourceBlocks: [LocalBlock]
    let links: [Link]
    let images: [Image]
    let tables: [Table]
    let mermaidDiagrams: [Diagram]

    struct Marker: Decodable {
        let kind: String
        let sourceRange: EditorEngineByteRange
        let headingLevel: Int?
        enum CodingKeys: String, CodingKey {
            case kind
            case sourceRange = "source_range"
            case headingLevel = "heading_level"
        }
    }

    struct ContentStyle: Decodable {
        let kind: String
        let sourceRange: EditorEngineByteRange
        let headingLevel: Int?
        let isChecked: Bool?
        let alternating: Bool?
        enum CodingKeys: String, CodingKey {
            case kind
            case sourceRange = "source_range"
            case headingLevel = "heading_level"
            case isChecked = "is_checked"
            case alternating
        }
    }

    struct LocalBlock: Decodable {
        let sourceRange: EditorEngineByteRange
        let reasons: [String]
        enum CodingKeys: String, CodingKey {
            case sourceRange = "source_range"
            case reasons
        }
    }

    struct Link: Decodable {
        let sourceRange: EditorEngineByteRange
        let textRange: EditorEngineByteRange
        let targetRange: EditorEngineByteRange
        let target: String
        enum CodingKeys: String, CodingKey {
            case sourceRange = "source_range"
            case textRange = "text_range"
            case targetRange = "target_range"
            case target
        }
    }

    struct Image: Decodable {
        let sourceRange: EditorEngineByteRange
        let alternativeRange: EditorEngineByteRange
        let targetRange: EditorEngineByteRange
        let alternative: String
        let target: String
        enum CodingKeys: String, CodingKey {
            case sourceRange = "source_range"
            case alternativeRange = "alternative_range"
            case targetRange = "target_range"
            case alternative
            case target
        }
    }

    struct Table: Decodable {
        let sourceRange: EditorEngineByteRange
        let alignments: [String]
        let rows: [[Cell]]
        enum CodingKeys: String, CodingKey {
            case sourceRange = "source_range"
            case alignments
            case rows
        }
    }

    struct Cell: Decodable {
        let sourceRange: EditorEngineByteRange
        let markdown: String
        let text: String
        let links: [CellLink]
        enum CodingKeys: String, CodingKey {
            case sourceRange = "source_range"
            case markdown
            case text
            case links
        }
    }

    struct CellLink: Decodable {
        let visibleSourceRange: EditorEngineByteRange
        let target: String
        enum CodingKeys: String, CodingKey {
            case visibleSourceRange = "visible_source_range"
            case target
        }
    }

    struct Diagram: Decodable {
        let sourceRange: EditorEngineByteRange
        let svg: String
        enum CodingKeys: String, CodingKey {
            case sourceRange = "source_range"
            case svg
        }
    }

    enum CodingKeys: String, CodingKey {
        case markers
        case contentStyles = "content_styles"
        case localSourceBlocks = "local_source_blocks"
        case links
        case images
        case tables
        case mermaidDiagrams = "mermaid_diagrams"
    }

    func validated(source: String) throws -> RenderedMarkdownPlan {
        func mapped(_ raw: EditorEngineByteRange, permitsEmpty: Bool = false) throws
            -> RenderedMarkdownSourceRange
        {
            guard let utf8 = raw.validated(in: source, permitsEmpty: permitsEmpty),
                  let target = MarkdownSourceRange.navigationTarget(
                      forUTF8Range: utf8,
                      in: source
                  )
            else { throw EditorEngineBridgeError.invalidResponse }
            return RenderedMarkdownSourceRange(
                utf8Range: utf8,
                utf16Range: target.revealRange
            )
        }

        let mappedMarkers = try markers.map { item in
            let kind: RenderedMarkdownMarkerKind = switch item.kind {
            case "heading": .heading(level: try requiredLevel(item.headingLevel))
            case "emphasis": .emphasis
            case "strong": .strong
            case "strikethrough": .strikethrough
            case "inline_code": .inlineCode
            case "block_quote": .blockQuote
            case "unordered_list": .unorderedList
            case "ordered_list": .orderedList
            case "task_list": .taskList
            case "table_boundary": .tableBoundary
            case "table_separator": .tableSeparator
            case "table_delimiter_row": .tableDelimiterRow
            case "reference_definition": .referenceDefinition
            case "link_delimiter": .linkDelimiter
            case "link_destination": .linkDestination
            default: throw EditorEngineBridgeError.invalidResponse
            }
            return RenderedMarkdownMarker(kind: kind, sourceRange: try mapped(item.sourceRange))
        }
        let mappedStyles = try contentStyles.map { item in
            let kind: RenderedMarkdownContentStyleKind = switch item.kind {
            case "paragraph": .paragraph
            case "heading": .heading(level: try requiredLevel(item.headingLevel))
            case "emphasis": .emphasis
            case "strong": .strong
            case "strikethrough": .strikethrough
            case "inline_code": .inlineCode
            case "block_quote": .blockQuote
            case "unordered_list_item": .unorderedListItem
            case "ordered_list_item": .orderedListItem
            case "task_list_item": .taskListItem(isChecked: item.isChecked ?? false)
            case "table_header": .tableHeader
            case "table_body": .tableBody(alternating: item.alternating ?? false)
            case "link": .link
            default: throw EditorEngineBridgeError.invalidResponse
            }
            return RenderedMarkdownContentStyle(kind: kind, sourceRange: try mapped(item.sourceRange))
        }
        let mappedLocals = try localSourceBlocks.map { item in
            let reasons = try item.reasons.map { reason -> RenderedMarkdownLocalSourceReason in
                switch reason {
                case "mermaid": .mermaid
                case "fenced_code": .fencedCode
                case "raw_html": .rawHTML
                case "unsupported_syntax": .unsupportedSyntax
                case "complex_or_ambiguous": .complexOrAmbiguous
                default: throw EditorEngineBridgeError.invalidResponse
                }
            }
            return RenderedMarkdownLocalSourceBlock(
                sourceRange: try mapped(item.sourceRange),
                reasons: reasons
            )
        }
        let mappedLinks = try links.map { item in
            RenderedMarkdownLink(
                sourceRange: try mapped(item.sourceRange),
                textRange: try mapped(item.textRange),
                targetRange: try mapped(item.targetRange, permitsEmpty: true),
                target: item.target
            )
        }
        let mappedImages = try images.map { item in
            RenderedMarkdownImage(
                sourceRange: try mapped(item.sourceRange),
                alternativeRange: try mapped(item.alternativeRange, permitsEmpty: true),
                targetRange: try mapped(item.targetRange, permitsEmpty: true),
                alternative: item.alternative,
                target: item.target
            )
        }
        let mappedTables = try tables.map { table in
            RenderedMarkdownTable(
                sourceRange: try mapped(table.sourceRange),
                alignments: try table.alignments.map { value in
                    switch value {
                    case "leading": .leading
                    case "center": .center
                    case "trailing": .trailing
                    default: throw EditorEngineBridgeError.invalidResponse
                    }
                },
                rows: try table.rows.map { row in
                    try row.map { cell in
                        let cellRange = try mapped(cell.sourceRange, permitsEmpty: true)
                        return RenderedMarkdownTableCell(
                            sourceRange: cellRange,
                            markdown: cell.markdown,
                            text: cell.text,
                            links: try cell.links.map { link in
                                let visible = try mapped(link.visibleSourceRange)
                                let visibleText = (source as NSString).substring(
                                    with: visible.utf16Range
                                )
                                let localRange = (cell.text as NSString).range(of: visibleText)
                                guard localRange.location != NSNotFound else {
                                    throw EditorEngineBridgeError.invalidResponse
                                }
                                return RenderedMarkdownTableCellLink(
                                    visibleRange: localRange,
                                    target: link.target
                                )
                            }
                        )
                    }
                }
            )
        }
        let mappedDiagrams = try mermaidDiagrams.map { item in
            RenderedMarkdownMermaidDiagram(
                sourceRange: try mapped(item.sourceRange),
                svg: item.svg
            )
        }
        return RenderedMarkdownPlan(
            sourceSnapshot: source,
            sourceUTF8: Data(source.utf8),
            markers: mappedMarkers,
            contentStyles: mappedStyles,
            localSourceBlocks: mappedLocals,
            links: mappedLinks,
            images: mappedImages,
            tables: mappedTables,
            mermaidDiagrams: mappedDiagrams
        )
    }

    private func requiredLevel(_ level: Int?) throws -> Int {
        guard let level, (1...6).contains(level) else {
            throw EditorEngineBridgeError.invalidResponse
        }
        return level
    }
}

private extension EditorEngineByteRange {
    func validated(in source: String, permitsEmpty: Bool) -> Range<Int>? {
        guard start >= 0, start <= end, permitsEmpty || start < end,
              end <= source.utf8.count,
              MarkdownSourceRange.navigationTarget(forUTF8Range: start..<end, in: source) != nil
        else { return nil }
        return start..<end
    }
}

private extension EditorEngineSelection {
    func validated(in source: String, permitsEmpty: Bool) -> Range<Int>? {
        EditorEngineByteRange(start: start, end: end).validated(
            in: source,
            permitsEmpty: permitsEmpty
        )
    }
}

private extension String {
    var syntaxKind: MarkdownSyntaxKind? {
        switch self {
        case "heading": .heading
        case "emphasis": .emphasis
        case "strong": .strong
        case "strikethrough": .strikethrough
        case "code": .code
        case "link": .link
        case "image": .image
        case "block_quote": .blockQuote
        case "list": .list
        case "table": .table
        case "footnote": .footnote
        case "math": .math
        case "raw": .raw
        case "rule": .rule
        default: nil
        }
    }
}

private struct EditorEngineErrorResponse: Decodable {
    let code: String
    let revision: UInt64?
}
