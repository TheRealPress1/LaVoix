import Foundation

/// Messages stores most message text inside an `attributedBody` blob: an old "typedstream" archive of an
/// NSAttributedString. Decoding it with NSUnarchiver can instantiate arbitrary classes and raise uncatchable
/// exceptions on bad data, so this reads only the plain string out of the bytes.
nonisolated enum TypedStreamText {
    static func extract(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = self.indexOf(Array("NSString".utf8), in: bytes) else { return nil }
        // After the class header comes 0x01 0x2B ("+"), then the length, then the UTF-8 text.
        guard let start = self.indexOf([0x01, 0x2B], in: bytes, from: marker + 8) else { return nil }
        var cursor = start + 2
        guard cursor < bytes.count else { return nil }

        let length: Int
        switch bytes[cursor] {
        case 0x81:
            guard cursor + 2 < bytes.count else { return nil }
            length = Int(bytes[cursor + 1]) | (Int(bytes[cursor + 2]) << 8)
            cursor += 3
        case 0x82:
            guard cursor + 4 < bytes.count else { return nil }
            length = Int(bytes[cursor + 1]) | (Int(bytes[cursor + 2]) << 8) | (Int(bytes[cursor + 3]) << 16) | (Int(bytes[cursor + 4]) << 24)
            cursor += 5
        default:
            length = Int(bytes[cursor])
            cursor += 1
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        return String(data: Data(bytes[cursor ..< cursor + length]), encoding: .utf8)
    }

    private static func indexOf(_ pattern: [UInt8], in bytes: [UInt8], from start: Int = 0) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        for index in start ... (bytes.count - pattern.count) where bytes[index] == pattern[0] {
            if Array(bytes[index ..< index + pattern.count]) == pattern { return index }
        }
        return nil
    }
}
