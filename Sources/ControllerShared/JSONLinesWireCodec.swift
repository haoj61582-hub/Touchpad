import Foundation

public enum JSONLinesWireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: line)
    }

    public static func drain<T: Decodable>(_ type: T.Type, from buffer: inout Data) throws -> [T] {
        var messages: [T] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newlineIndex])
            let removeEnd = buffer.index(after: newlineIndex)
            buffer.removeSubrange(buffer.startIndex..<removeEnd)

            if line.last == 0x0D {
                line.removeLast()
            }

            if line.isEmpty {
                continue
            }

            messages.append(try decode(type, from: line))
        }

        return messages
    }
}

