import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let inflowMarkdown = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}

struct MarkdownDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.inflowMarkdown]
    static let writableContentTypes: [UTType] = [.inflowMarkdown]

    var text: String
    var properties: MarkdownFileProperties
    var restorationState: MarkdownRestorationState?

    init(
        text: String = "",
        properties: MarkdownFileProperties = .newDocument,
        restorationState: MarkdownRestorationState? = nil
    ) {
        self.text = text
        self.properties = properties
        self.restorationState = restorationState
    }

    init(fileData: Data) throws {
        let decoded = try MarkdownCodec.decode(fileData)
        text = decoded.text
        properties = decoded.properties
        restorationState = nil
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(fileData: data)
    }

    func encodedFileData() throws -> Data {
        try MarkdownCodec.encode(text, properties: properties)
    }

    mutating func chooseLineEnding(_ lineEnding: MarkdownLineEnding) {
        properties.lineEnding = lineEnding
        properties.requiresLineEndingChoice = false
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(regularFileWithContents: encodedFileData())
    }
}
