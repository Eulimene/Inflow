import Foundation
import os

enum EditorEngineShadowFeature {
    static var isEnabled: Bool {
        let override = ProcessInfo.processInfo.environment["INFLOW_EDITOR_ENGINE_SHADOW"]
#if DEBUG
        return override != "0"
#else
        return override == "1"
#endif
    }
}

struct EditorEngineShadowTextEdit: Equatable, Sendable {
    let start: Int
    let end: Int
    let inserted: String
}

enum EditorEngineShadowTextDiff {
    static func replacement(from old: String, to new: String) -> EditorEngineShadowTextEdit? {
        guard !old.utf8.elementsEqual(new.utf8) else { return nil }

        var oldPrefix = old.startIndex
        var newPrefix = new.startIndex
        while sameNextGrapheme(old, at: oldPrefix, new, at: newPrefix) {
            old.formIndex(after: &oldPrefix)
            new.formIndex(after: &newPrefix)
        }

        var oldSuffix = old.endIndex
        var newSuffix = new.endIndex
        while oldSuffix > oldPrefix, newSuffix > newPrefix {
            let oldPrevious = old.index(before: oldSuffix)
            let newPrevious = new.index(before: newSuffix)
            guard old[oldPrevious..<oldSuffix].utf8.elementsEqual(
                new[newPrevious..<newSuffix].utf8
            ) else { break }
            oldSuffix = oldPrevious
            newSuffix = newPrevious
        }

        let start = old[..<oldPrefix].utf8.count
        return EditorEngineShadowTextEdit(
            start: start,
            end: start + old[oldPrefix..<oldSuffix].utf8.count,
            inserted: String(new[newPrefix..<newSuffix])
        )
    }

    private static func sameNextGrapheme(
        _ old: String,
        at oldIndex: String.Index,
        _ new: String,
        at newIndex: String.Index
    ) -> Bool {
        guard oldIndex < old.endIndex, newIndex < new.endIndex else { return false }
        let oldNext = old.index(after: oldIndex)
        let newNext = new.index(after: newIndex)
        return old[oldIndex..<oldNext].utf8.elementsEqual(new[newIndex..<newNext].utf8)
    }
}

@MainActor
final class EditorEngineShadowQueue {
    private let client: EditorEngineShadowClient?
    private var lastSubmittedText: String?
    private var pending: Task<Void, Never>?

    init(isEnabled: Bool = EditorEngineShadowFeature.isEnabled) {
        client = isEnabled ? EditorEngineShadowClient() : nil
    }

    func submit(text: String, selectionUTF16: NSRange) {
        guard let client,
              lastSubmittedText.map({ !$0.utf8.elementsEqual(text.utf8) }) ?? true
        else { return }
        lastSubmittedText = text
        let previous = pending
        pending = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await client.synchronize(to: text, selectionUTF16: selectionUTF16)
        }
    }

    deinit {
        pending?.cancel()
    }
}

private final class EditorEngineShadowHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        inflow_engine_free(pointer)
    }
}

private actor EditorEngineShadowClient {
    private static let schemaVersion: UInt32 = 1
    private let logger = Logger(subsystem: "com.inflow.desktop", category: "EditorEngineShadow")
    private var handle: EditorEngineShadowHandle?
    private var projection = ""
    private var revision: UInt64 = 0

    func synchronize(to swiftText: String, selectionUTF16: NSRange) {
        do {
            let selection = try Self.byteSelection(selectionUTF16, in: swiftText)
            guard handle != nil else {
                try create(text: swiftText, selection: selection)
                return
            }
            guard let edit = EditorEngineShadowTextDiff.replacement(
                from: projection,
                to: swiftText
            ) else {
                try compareSnapshot(to: swiftText)
                return
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
                    selectionAfter: selection
                )
            )
            let response: EditorEngineDispatchResponse = try dispatch(command)
            guard response.schemaVersion == Self.schemaVersion,
                  response.requestID == requestID,
                  response.patch.baseRevision == revision,
                  response.patch.revision == revision + 1
            else {
                throw EditorEngineShadowError.invalidResponse
            }

            revision = response.patch.revision
            projection = swiftText
            try compareSnapshot(to: swiftText)
        } catch {
            logger.error(
                "Shadow synchronization failed; command=replace_text revision=\(self.revision, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            handle = nil
            projection = ""
            revision = 0
            do {
                let selection = try Self.byteSelection(selectionUTF16, in: swiftText)
                try create(text: swiftText, selection: selection)
            } catch {
                logger.error(
                    "Shadow resync failed; command=create revision=0 error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func create(text: String, selection: EditorEngineSelection) throws {
        let request = EditorEngineCreateRequest(
            schemaVersion: Self.schemaVersion,
            documentID: UUID().uuidString,
            text: text,
            selection: selection
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
              snapshot.selection == selection
        else {
            inflow_engine_free(pointer)
            throw EditorEngineShadowError.mismatch(revision: snapshot.revision)
        }
        handle = EditorEngineShadowHandle(pointer: pointer)
        projection = text
        revision = snapshot.revision
    }

    private func dispatch<T: Encodable, Response: Decodable>(_ command: T) throws -> Response {
        guard let handle else { throw EditorEngineShadowError.invalidHandle }
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
        guard let handle else { throw EditorEngineShadowError.invalidHandle }
        let result = inflow_engine_snapshot(handle.pointer)
        let payload = try InflowCoreBridge.copyAndFree(result.bytes)
        guard result.status == INFLOW_STATUS_OK else {
            throw Self.bridgeError(status: result.status, payload: payload)
        }
        let snapshot = try JSONDecoder().decode(EditorEngineSnapshot.self, from: payload)
        guard snapshot.schemaVersion == Self.schemaVersion,
              snapshot.revision == revision,
              snapshot.text.utf8.elementsEqual(swiftText.utf8)
        else {
            throw EditorEngineShadowError.mismatch(revision: snapshot.revision)
        }
    }

    private static func byteSelection(
        _ utf16Range: NSRange,
        in text: String
    ) throws -> EditorEngineSelection {
        guard let range = Range(utf16Range, in: text),
              let lower = range.lowerBound.samePosition(in: text.utf8),
              let upper = range.upperBound.samePosition(in: text.utf8)
        else {
            throw EditorEngineShadowError.invalidSelection
        }
        return EditorEngineSelection(
            start: text.utf8.distance(from: text.utf8.startIndex, to: lower),
            end: text.utf8.distance(from: text.utf8.startIndex, to: upper)
        )
    }

    private static func bridgeError(status: InflowStatus, payload: Data) -> Error {
        if let response = try? JSONDecoder().decode(EditorEngineErrorResponse.self, from: payload) {
            return EditorEngineShadowError.core(
                status: status,
                code: response.code,
                revision: response.revision
            )
        }
        return EditorEngineShadowError.core(status: status, code: "unknown", revision: nil)
    }
}

private enum EditorEngineShadowError: Error, CustomStringConvertible {
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

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case documentID = "document_id"
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

private struct EditorEngineReplaceCommand: Encodable {
    let type: String
    let baseRevision: UInt64
    let range: EditorEngineByteRange
    let inserted: String
    let selectionAfter: EditorEngineSelection

    enum CodingKeys: String, CodingKey {
        case type
        case baseRevision = "base_revision"
        case range
        case inserted
        case selectionAfter = "selection_after"
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
    let contentHash: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case documentID = "document_id"
        case revision
        case text
        case selection
        case contentHash = "content_hash"
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

    enum CodingKeys: String, CodingKey {
        case baseRevision = "base_revision"
        case revision
    }
}

private struct EditorEngineErrorResponse: Decodable {
    let code: String
    let revision: UInt64?
}
