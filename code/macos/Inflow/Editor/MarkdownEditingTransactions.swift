import AppKit
import Foundation

/// A single source transaction produced by a writing gesture. Offsets are UTF-16.
struct MarkdownWritingEdit: Equatable {
    let range: NSRange
    let text: String
    let selection: NSRange
}

enum MarkdownWritingAction { case newline, backwardDelete, indent, outdent }

/// Interpret a gesture before touching TextKit. The resulting source and selection
/// are committed together, so rendering never decides where an edit should land.
enum MarkdownEditingIntent { case paragraphBreak, lineBreak, mergeBackward }

enum MarkdownEditingTransaction {
    /// Leave a table in an empty paragraph separated from both neighbouring
    /// blocks, even when the table range already includes its trailing newline.
    static func exitTable(source: String, at location: Int) -> MarkdownWritingEdit? {
        let text = source as NSString
        guard location >= 0, location <= text.length else { return nil }
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        let before = text.substring(to: location)
        let after = text.substring(from: location)
        let prefix = before.hasSuffix(newline) ? newline : newline + newline
        let suffix = after.isEmpty || after.hasPrefix(newline + newline)
            ? "" : (after.hasPrefix(newline) ? newline : newline + newline)
        return MarkdownWritingEdit(range: NSRange(location: location, length: 0),
            text: prefix + suffix,
            selection: NSRange(location: location + prefix.utf16.count, length: 0))
    }

    /// Cheap lexical gate before consulting the native render plan. Ordinary
    /// character deletion must not synchronously parse the whole document.
    static func mayHandleBackwardDelete(source: String, selection: NSRange) -> Bool {
        let text = source as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= text.length else { return false }
        if selection.location < text.length {
            let left = text.substring(with: NSRange(location: selection.location - 1, length: 1))
            let right = text.substring(with: NSRange(location: selection.location, length: 1))
            if ["(": ")", "[": "]", "{": "}", "`": "`"][left] == right { return true }
        }
        if MarkdownWritingRules.edit(.backwardDelete, source: source, selection: selection) != nil { return true }
        let line = text.lineRange(for: selection)
        // The planner decides whether this is a paragraph merge or a protected block.
        return selection.location == line.location
    }

    static func plan(_ intent: MarkdownEditingIntent, source: String, selection: NSRange,
                     renderPlan: RenderedMarkdownPlan) -> MarkdownWritingEdit? {
        let text = source as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let raw = text.substring(with: line).trimmingCharacters(in: .newlines)
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        func replace(_ range: NSRange, _ value: String, caret: Int? = nil) -> MarkdownWritingEdit {
            MarkdownWritingEdit(range: range, text: value,
                selection: NSRange(location: caret ?? range.location + value.utf16.count, length: 0))
        }
        func exitEmptyBlock(removing range: NSRange, retaining outerPrefix: String) -> MarkdownWritingEdit {
            guard line.location > 0 else { return replace(range, "") }
            let previous = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
            let previousText = text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
            let outerMarker = outerPrefix.trimmingCharacters(in: .whitespaces)
            // Without a blank separator, the next typed paragraph is a lazy
            // continuation of the list/quote that the user has just exited.
            let separator = previousText.isEmpty || previousText == outerMarker ? "" : newline + outerPrefix
            return replace(range, separator)
        }
        let request = renderPlan.renderRequests.first {
            selection.location >= $0.sourceRange.utf16Range.location
                && selection.location < NSMaxRange($0.sourceRange.utf16Range)
        }
        let protected = renderPlan.localSourceBlocks.contains {
            selection.location >= $0.sourceRange.utf16Range.location
                && selection.location < NSMaxRange($0.sourceRange.utf16Range)
        }
        if intent != .mergeBackward {
            // The visible beginning of an ATX heading follows its hidden marker.
            // Insert before the whole block, never between '#' and its content.
            if selection.length == 0,
               let heading = renderPlan.markers.first(where: {
                   if case .heading = $0.kind { return $0.sourceRange.utf16Range.location == line.location }
                   return false
               }),
               selection.location <= NSMaxRange(heading.sourceRange.utf16Range) {
                return replace(NSRange(location: line.location, length: 0), newline + newline,
                    caret: line.location)
            }
            // Complete a newly typed fence in a single undoable transaction.
            if intent == .paragraphBreak, selection.length == 0, before == raw,
               let match = raw.range(of: #"^(`{3,}|~{3,})[A-Za-z0-9_+.#-]*$"#, options: .regularExpression),
               match == raw.startIndex..<raw.endIndex,
               !renderPlan.renderRequests.contains(where: {
                   $0.sourceRange.utf16Range.location < line.location && NSMaxRange($0.sourceRange.utf16Range) >= line.location
               }),
               request == nil || request?.contentRange.utf16Range.length == 0 {
                let fence = String(raw.prefix { $0 == raw.first! })
                return replace(selection, newline + newline + fence, caret: selection.location + newline.utf16.count)
            }
            if intent == .paragraphBreak, selection.length == 0, raw == "$$", before == raw, request == nil {
                return replace(selection, newline + newline + "$$", caret: selection.location + newline.utf16.count)
            }
            if request != nil || protected {
                return replace(selection, newline + String(before.prefix { $0 == " " || $0 == "\t" }))
            }
            let head = prefix(raw)
            if intent == .lineBreak {
                // A continuation belongs to the same quote/list item. Do not copy
                // its bullet or task marker and accidentally create another item.
                let continuation = head.quote + (head.list.isEmpty ? head.indent : head.indent + String(repeating: " ", count: listContentIndent(head.list)))
                return replace(selection, newline + continuation)
            }
            if !head.list.isEmpty {
                let headLength = (head.quote + head.indent + head.list).utf16.count
                let tail = (raw as NSString).substring(from: headLength)
                if selection.length == 0, tail.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !head.indent.isEmpty {
                        return replace(NSRange(location: line.location + head.quote.utf16.count,
                            length: min(2, head.indent.utf16.count)), "", caret: max(line.location, selection.location - min(2, head.indent.utf16.count)))
                    }
                    return exitEmptyBlock(removing: NSRange(location: line.location + head.quote.utf16.count,
                        length: head.list.utf16.count), retaining: head.quote)
                }
                return replace(selection, newline + head.quote + head.indent + nextListMarker(head.list))
            }
            if let continuation = listContinuation(at: line.location, source: source, plan: renderPlan),
               head.quote == continuation.quote, head.indent.utf16.count >= continuation.width {
                return replace(selection, newline + continuation.quote + continuation.indent + nextListMarker(continuation.list))
            }
            if selection.length == 0,
               let structural = MarkdownWritingRules.edit(.newline, source: source, selection: selection) {
                if !head.list.isEmpty || raw.trimmingCharacters(in: .whitespaces) == head.quote.trimmingCharacters(in: .whitespaces) {
                    if structural.text.isEmpty {
                        let outer = text.substring(with: NSRange(location: line.location,
                            length: structural.range.location - line.location))
                        return exitEmptyBlock(removing: structural.range, retaining: outer)
                    }
                    return structural
                }
            }
            if !head.quote.isEmpty {
                return replace(selection, newline + head.quote.trimmingCharacters(in: .whitespaces) + newline + head.quote + head.indent)
            }
            return replace(selection, raw.trimmingCharacters(in: .whitespaces).isEmpty ? newline : newline + newline)
        }
        guard selection.length == 0, request == nil, !protected else { return nil }
        let head = prefix(raw)
        if !head.list.isEmpty, selection.location == line.location + (head.quote + head.indent + head.list).utf16.count {
            if !head.indent.isEmpty {
                let count = min(2, head.indent.utf16.count)
                return replace(NSRange(location: line.location + head.quote.utf16.count, length: count), "", caret: selection.location - count)
            }
            return replace(NSRange(location: line.location + head.quote.utf16.count, length: head.list.utf16.count), "")
        }
        if let structural = MarkdownWritingRules.edit(.backwardDelete, source: source, selection: selection) { return structural }
        if selection.location == line.location, selection.location >= newline.utf16.count * 2 {
            let range = NSRange(location: selection.location - newline.utf16.count * 2, length: newline.utf16.count * 2)
            if text.substring(with: range) == newline + newline {
                return replace(range, "")
            }
        }
        return nil
    }

    private static func listContentIndent(_ marker: String) -> Int {
        marker.firstIndex(of: "[").map { marker[..<$0].utf16.count } ?? marker.utf16.count
    }

    private static func nextListMarker(_ marker: String) -> String {
        var result = marker.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        if let range = result.range(of: #"^\d{1,9}"#, options: .regularExpression), let value = Int(result[range]) {
            result.replaceSubrange(range, with: String(value + 1))
        }
        return result
    }

    private static func listContinuation(at location: Int, source: String, plan: RenderedMarkdownPlan)
        -> (quote: String, indent: String, list: String, width: Int)? {
        let text = source as NSString
        guard let marker = plan.markers.last(where: {
            ($0.kind == .unorderedList || $0.kind == .orderedList) && $0.sourceRange.utf16Range.location < location
        }) else { return nil }
        let firstLine = text.lineRange(for: NSRange(location: marker.sourceRange.utf16Range.location, length: 0))
        guard firstLine.location < location else { return nil }
        let head = prefix(text.substring(with: firstLine))
        guard !head.list.isEmpty else { return nil }
        let width = head.indent.utf16.count + listContentIndent(head.list)
        var offset = NSMaxRange(firstLine)
        while offset < location {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let value = text.substring(with: line)
            let next = prefix(value)
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               next.quote != head.quote || next.indent.utf16.count < width || !next.list.isEmpty { return nil }
            offset = NSMaxRange(line)
        }
        return (head.quote, head.indent, head.list, width)
    }

    static func indentList(source: String, selection: NSRange, backwards: Bool) -> MarkdownWritingEdit? {
        let text = source as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let first = text.lineRange(for: selection)
        let head = prefix(text.substring(with: first))
        guard !head.list.isEmpty, !backwards || !head.indent.isEmpty else { return nil }
        let count = backwards ? min(2, head.indent.utf16.count) : 2
        var end = NSMaxRange(first)
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            let value = text.substring(with: next)
            let nested = prefix(value)
            guard nested.quote == head.quote, nested.indent.count > head.indent.count else { break }
            end = NSMaxRange(next)
        }
        let range = NSRange(location: first.location, length: end - first.location)
        let result = NSMutableString(string: text.substring(with: range))
        var positions: [Int] = []
        var offset = 0
        while offset < result.length {
            let line = result.lineRange(for: NSRange(location: offset, length: 0))
            positions.append(offset + prefix(result.substring(with: line)).quote.utf16.count)
            offset = NSMaxRange(line)
        }
        for position in positions.reversed() {
            result.replaceCharacters(in: NSRange(location: position, length: backwards ? count : 0), with: backwards ? "" : "  ")
        }
        return MarkdownWritingEdit(range: range, text: result as String,
            selection: NSRange(location: max(first.location, selection.location + (backwards ? -count : count)), length: 0))
    }

    private static func prefix(_ line: String) -> (quote: String, indent: String, list: String) {
        let expression = try! NSRegularExpression(pattern: #"^((?: *> ?)*)( *)(?:(?:[-+*]|\d{1,9}[.)]) +(?:\[[ xX]\] +)?)?"#)
        let text = line as NSString
        guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return ("", "", "") }
        let quote = text.substring(with: match.range(at: 1))
        let indent = text.substring(with: match.range(at: 2))
        let listStart = NSMaxRange(match.range(at: 2))
        return (quote, indent, text.substring(with: NSRange(location: listStart, length: NSMaxRange(match.range) - listStart)))
    }
}

/// Lexical editing rules, not a Markdown renderer. The caller excludes code,
/// formulas and unsupported blocks using the authoritative render plan.
enum MarkdownWritingRules {
    private static let prefix = try! NSRegularExpression(
        pattern: #"^( *)((?:> ?)*)(?:([-+*]|\d{1,9}[.)]|#{1,6}) +(\[[ xX]\] +)?)?"#
    )

    static func edit(_ action: MarkdownWritingAction, source: String, selection: NSRange) -> MarkdownWritingEdit? {
        let source = source as NSString
        guard NSMaxRange(selection) <= source.length else { return nil }
        if selection.length > 0 {
            guard action == .indent || action == .outdent else { return nil }
            // Exclude a following line when a selection ends exactly at its start.
            let range = source.lineRange(for: NSRange(location: selection.location, length: selection.length - 1))
            let original = source.substring(with: range) as NSString
            var edits: [MarkdownWritingEdit] = []
            var offset = 0
            while offset < original.length {
                let line = original.lineRange(for: NSRange(location: offset, length: 0))
                if let change = edit(action, source: original.substring(with: line), selection: NSRange(location: 0, length: 0)) {
                    edits.append(MarkdownWritingEdit(range: NSRange(location: offset + change.range.location, length: change.range.length),
                        text: change.text, selection: change.selection))
                }
                offset = NSMaxRange(line)
            }
            guard !edits.isEmpty else { return nil }
            let changed = NSMutableString(string: original)
            for change in edits.reversed() { changed.replaceCharacters(in: change.range, with: change.text) }
            return MarkdownWritingEdit(range: range, text: changed as String,
                selection: NSRange(location: range.location, length: changed.length))
        }
        let line = source.lineRange(for: selection)
        let raw = source.substring(with: line) as NSString
        let body = (raw as String).trimmingCharacters(in: .newlines)
        let offset = selection.location - line.location
        guard let match = prefix.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) else { return nil }
        guard match.range.length > 0, match.range(at: 2).length > 0 || match.range(at: 3).location != NSNotFound else { return nil }
        let head = raw.substring(with: match.range)
        let indent = raw.substring(with: match.range(at: 1))
        let tail = (body as NSString).substring(from: match.range.length)
        func replacing(_ range: NSRange, _ text: String, caret: Int? = nil) -> MarkdownWritingEdit {
            MarkdownWritingEdit(range: range, text: text, selection: NSRange(location: caret ?? (range.location + text.utf16.count), length: 0))
        }
        switch action {
        case .newline:
            if match.range(at: 3).location != NSNotFound,
               raw.substring(with: match.range(at: 3)).hasPrefix("#") { return nil }
            guard offset >= match.range.length else { return nil }
            if tail.trimmingCharacters(in: .whitespaces).isEmpty {
                // Remove one nesting level at a time, preserving outer quotes.
                if match.range(at: 3).location != NSNotFound {
                    let start = match.range(at: 3).location
                    return replacing(NSRange(location: line.location + start, length: match.range.length - start), "")
                }
                if let last = head.lastIndex(of: ">") {
                    return replacing(NSRange(location: line.location + head[..<last].utf16.count, length: head[last...].utf16.count), "")
                }
                return replacing(NSRange(location: line.location, length: match.range.length), "")
            }
            var next = head
            if match.range(at: 3).location != NSNotFound {
                let marker = raw.substring(with: match.range(at: 3))
                if let number = Int(marker.dropLast()), let suffix = marker.last {
                    let replacement = String(number + 1) + String(suffix)
                    next = (next as NSString).replacingCharacters(in: match.range(at: 3), with: replacement)
                }
                next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            }
            let newline = (raw as String).hasSuffix("\r\n") ? "\r\n" : "\n"
            return replacing(selection, newline + next)
        case .backwardDelete:
            guard offset == match.range.length else { return nil }
            if !indent.isEmpty {
                let count = min(2, indent.utf16.count)
                return replacing(NSRange(location: line.location, length: count), "", caret: selection.location - count)
            }
            if match.range(at: 3).location != NSNotFound {
                let start = match.range(at: 3).location
                return replacing(NSRange(location: line.location + start, length: match.range.length - start), "")
            }
            if let last = head.lastIndex(of: ">") {
                let start = line.location + head[..<last].utf16.count
                return replacing(NSRange(location: start, length: head[last...].utf16.count), "")
            }
            return replacing(NSRange(location: line.location, length: match.range.length), "")
        case .indent:
            guard match.range(at: 3).location != NSNotFound,
                  !raw.substring(with: match.range(at: 3)).hasPrefix("#") else { return nil }
            return replacing(NSRange(location: line.location, length: 0), "  ", caret: selection.location + 2)
        case .outdent:
            guard match.range(at: 3).location != NSNotFound, !indent.isEmpty,
                  !raw.substring(with: match.range(at: 3)).hasPrefix("#") else { return nil }
            let count = min(2, indent.utf16.count)
            return replacing(NSRange(location: line.location, length: count), "", caret: selection.location - min(offset, count))
        }
    }

    static func pair(_ input: String, source: String, selection: NSRange) -> MarkdownWritingEdit? {
        let text = source as NSString
        guard NSMaxRange(selection) <= text.length,
              let closing = ["(": ")", "[": "]", "{": "}", "`": "`", "*": "*", "_": "_", "~": "~"][input]
        else { return nil }
        if selection.location > 0, text.substring(with: NSRange(location: selection.location - 1, length: 1)) == "\\" { return nil }
        let selected = text.substring(with: selection)
        if selection.length == 0 {
            if ["*", "_", "~"].contains(input) { return nil }
            // Avoid changing words, list markers and existing closing delimiters.
            let before = selection.location == 0 ? "" : text.substring(to: selection.location)
            if input == "`", before.split(separator: "\n", omittingEmptySubsequences: false).last?.trimmingCharacters(in: .whitespaces) == "``" { return nil }
            if ["*", "_", "~"].contains(input), before.last?.isLetter == true { return nil }
            if selection.location < text.length {
                let next = text.substring(from: selection.location).first
                if next?.isLetter == true || next?.isNumber == true { return nil }
            }
        }
        let opening = input == "~" ? "~~" : input
        let ending = input == "~" ? "~~" : closing
        return MarkdownWritingEdit(range: selection, text: opening + selected + ending,
            selection: NSRange(location: selection.location + opening.utf16.count, length: selection.length))
    }

    static func revealedMarkers(plan: RenderedMarkdownPlan, selection: NSRange) -> [NSRange] {
        func touches(_ range: NSRange) -> Bool {
            selection.length == 0
                ? selection.location >= range.location && selection.location <= NSMaxRange(range)
                : NSIntersectionRange(selection, range).length > 0
        }
        var result: [NSRange] = []
        for style in plan.contentStyles {
            let kind: RenderedMarkdownMarkerKind
            switch style.kind {
            case .strong: kind = .strong
            case .emphasis: kind = .emphasis
            case .strikethrough: kind = .strikethrough
            case .inlineCode: kind = .inlineCode
            default: continue
            }
            let content = style.sourceRange.utf16Range
            let adjacent = plan.markers.filter {
                $0.kind == kind && (NSMaxRange($0.sourceRange.utf16Range) == content.location
                    || $0.sourceRange.utf16Range.location == NSMaxRange(content))
            }.map(\.sourceRange.utf16Range)
            let full = adjacent.reduce(content) { NSUnionRange($0, $1) }
            if touches(full) { result += adjacent }
        }
        for link in plan.links where touches(link.sourceRange.utf16Range) {
            result += plan.markers.filter {
                ($0.kind == .linkDelimiter || $0.kind == .linkDestination)
                    && NSIntersectionRange($0.sourceRange.utf16Range, link.sourceRange.utf16Range).length > 0
            }.map(\.sourceRange.utf16Range)
        }
        return result
    }
}
