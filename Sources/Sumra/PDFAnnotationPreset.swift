#if os(macOS)
import Foundation
import SumraCore

// Consumed CmdCreateAnnot arguments from SumatraPDF.cpp. Colors are RGB;
// UInt32.max represents its "no color" value without a second color parser.
struct PDFAnnotationPreset: Codable, Equatable, Sendable {
    var color: UInt32?
    var bgColor: UInt32?
    var interiorColor: UInt32?
    var opacity: Int?
    var textSize: Int?
    var borderWidth: Int?
    var alignment: String?
    var openEdit: Bool?
    var copyToClipboard: Bool?
    var setContent: Bool?

    func validate() throws {
        guard [color, bgColor, interiorColor].compactMap({ $0 }).allSatisfy({ $0 <= 0xffffff || $0 == .max }) else {
            throw ReadError("Annotation colors must be RGB values or 4294967295 for no color")
        }
        if let alignment, !["left", "center", "right"].contains(alignment.lowercased()) {
            throw ReadError("Annotation alignment must be left, center or right")
        }
        // Upstream clamps nonnegative sizes and percentages at application.
        if textSize.map({ $0 < 0 }) == true || borderWidth.map({ $0 < 0 }) == true {
            throw ReadError("Annotation text size and border width cannot be negative")
        }
    }
}
#endif
