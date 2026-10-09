#if os(macOS)
import Foundation
import SumraCore

// Translated from pinned Sumatra EngineMupdf.cpp's HeadingNumberPrefixLen,
// IsHeadingTitle, HeadingIsParentOf and GenerateTocFromHeadings (issue #5724).
// MuPDF supplies lines and destinations; the numbered-heading heuristic is
// unchanged. It intentionally does not guess headings from font appearance.
@MainActor
enum ReaderOutline {
    static func generate(_ pages: Pages) async throws -> [ContentsItem] {
        let prepared = try await pages.prepare()
        if !prepared.outline.isEmpty { return prepared.outline }
        guard try await pages.pdfInfo()?.permissions.copy == true else { throw ReadError(L("This PDF does not allow text extraction.")) }
        var result = [ContentsItem](), stack = [String]()
        let count = await pages.count
        for index in 0..<count {
            try Task.checkCancellation()
            if result.count >= 400 { break }
            for line in try await pages.pdfTextLines(index) {
                if result.count >= 400 { break }
                let title = normalize(line.text)
                guard isHeading(title) else { continue }
                // MuPDF's standard URI retains the line's Fitz top coordinate.
                append(title, target: "#page=\(index + 1)&zoom=nan,0,\(line.bounds.minY)", page: index, result: &result, stack: &stack)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func append(_ title: String, target: String, page: Int, result: inout [ContentsItem], stack: inout [String]) {
        var same = false
        while let parent = stack.last {
            let relation = relationship(parent, title)
            same = relation.same
            if relation.parent || same { break }
            stack.removeLast()
        }
        guard !same else { return }
        result.append(.init(title: title, target: target, depth: stack.count, page: page))
        stack.append(title)
    }

    static func normalize(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0 || value == 0xFFFD { continue }
            if value == 32 || (9...13).contains(value) {
                if !result.isEmpty && result.last != " " { result.append(" ") }
            } else if value >= 32 { result.unicodeScalars.append(scalar) }
        }
        if result.last == " " { result.removeLast() }
        return result
    }

    static func isHeading(_ title: String) -> Bool {
        let bytes = Array(title.utf8)
        guard (6...160).contains(bytes.count) else { return false }
        var index = 0, numbered = false
        while index < bytes.count {
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) || [73, 86, 88, 67].contains(byte) { index += 1 }
                else { break }
            }
            if index == start || index >= bytes.count || bytes[index] != 46 { break }
            index += 1
            numbered = true
        }
        guard numbered else { return false }
        while index < bytes.count && bytes[index] == 32 { index += 1 }
        return index < bytes.count && !(97...122).contains(bytes[index])
    }

    static func relationship(_ parent: String, _ child: String) -> (parent: Bool, same: Bool) {
        let first = Array(parent.utf8), second = Array(child.utf8)
        for index in 0..<min(first.count, second.count) {
            if first[index] == 32 { return second[index] == 32 ? (false, true) : (true, false) }
            if first[index] != second[index] { return (false, false) }
        }
        return (true, false)
    }
}
#endif
