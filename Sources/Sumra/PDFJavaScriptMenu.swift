import Foundation

// Sumatra Altium menu strings. This reads menu text; it never executes JavaScript.
enum PDFJavaScriptMenu {
    static func items(in script: String) -> [String] {
        guard let start = script.range(of: "popUpMenu") else { return [] }
        var tail = script[start.upperBound...]
        if tail.hasPrefix("Ex") { tail = tail.dropFirst(2) }
        let input = Array(tail.unicodeScalars)
        var index = 0, items = [String]()
        let escapes: [Unicode.Scalar: Unicode.Scalar] = ["n": "\n", "r": "\r", "t": "\t", "b": "\u{8}", "f": "\u{c}", "v": "\u{b}", "0": "\0"]
        func whitespace() { while index < input.count, CharacterSet.whitespacesAndNewlines.contains(input[index]) { index += 1 } }
        func quoted() -> String? {
            let quote = input[index]; index += 1
            var output = String.UnicodeScalarView()
            while index < input.count {
                var character = input[index]; index += 1
                if character == quote { return String(output) }
                if character == "\\", index < input.count {
                    character = input[index]; index += 1
                    if let escaped = escapes[character] { character = escaped }
                    else if character == "x" || character == "u" {
                        let count = character == "x" ? 2 : 4
                        if index + count <= input.count, let code = UInt32(String(String.UnicodeScalarView(input[index..<index+count])), radix: 16) {
                            index += count
                            if let scalar = Unicode.Scalar(code) { character = scalar }
                            else if (0xd800...0xdbff).contains(code), index + 6 <= input.count, input[index] == "\\", input[index+1] == "u",
                                    let low = UInt32(String(String.UnicodeScalarView(input[index+2..<index+6])), radix: 16), (0xdc00...0xdfff).contains(low),
                                    let scalar = Unicode.Scalar(0x10000 + (code-0xd800)*1024 + low-0xdc00) { character = scalar; index += 6 }
                            else { character = "\u{fffd}" }
                        }
                    }
                }
                output.append(character)
            }
            return nil
        }
        whitespace()
        guard index < input.count, input[index] == "(" else { return [] }
        index += 1
        while index < input.count {
            whitespace(); guard index < input.count, input[index] != ")" else { break }
            if input[index] == "\"" || input[index] == "'" {
                guard let item = quoted() else { break }; items.append(item)
            } else if input[index] == "[" {
                var depth = 1; index += 1
                while index < input.count, depth > 0 {
                    if input[index] == "\"" || input[index] == "'" { if quoted() == nil { return items } }
                    else { if input[index] == "[" { depth += 1 }; if input[index] == "]" { depth -= 1 }; index += 1 }
                }
            } else { index += 1 }
        }
        return items
    }

    static func calledFunction(in script: String) -> String? {
        let reserved: Set<String> = ["function", "if", "for", "while", "switch", "catch", "with", "return", "typeof", "void", "delete", "new", "throw", "else", "do", "try"]
        let expression = try? NSRegularExpression(pattern: #"([A-Za-z_$][A-Za-z0-9_$]*)\s*\("#)
        let string = script as NSString
        return expression?.matches(in: script, range: NSRange(location: 0, length: string.length)).lazy
            .map { string.substring(with: $0.range(at: 1)) }.first { !reserved.contains($0) }
    }
}
