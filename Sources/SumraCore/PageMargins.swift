import Foundation

/// EBookUI.Margin in EngineMupdf.cpp: CSS order, one, two or four point values.
public struct PageMargins: Codable, Hashable, Sendable {
    public let top: Double, right: Double, bottom: Double, left: Double
    private enum CodingKeys: String, CodingKey { case top, right, bottom, left }
    public init?(cssValues values: [Double]) {
        guard [1, 2, 4].contains(values.count), values.allSatisfy({ $0.isFinite && (0...200).contains($0) }) else { return nil }
        top = values[0]; right = values.count == 1 ? values[0] : values[1]
        bottom = values.count == 4 ? values[2] : top
        left = values.count == 4 ? values[3] : right
    }
    public init?(cssValues text: String) {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let values = tokens.compactMap { Double($0) }
        guard values.count == tokens.count else { return nil }
        self.init(cssValues: values)
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try [CodingKeys.top, .right, .bottom, .left].map { try container.decode(Double.self, forKey: $0) }
        guard let margins = Self(cssValues: values) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Margins must be finite values from 0 to 200 points"))
        }
        self = margins
    }
    public var values: [Double] { [top, right, bottom, left] }
    public var css: String { values.map { "\($0)pt" }.joined(separator: " ") }
}
