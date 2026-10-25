import Foundation

public enum RPCFrameError: Error, Equatable {
    case frameTooLarge(Int)
    case emptyFrame
}

public enum RPCFrameCodec {
    public static let maxFrameSize = 1_048_576

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw RPCFrameError.emptyFrame }
        guard payload.count <= maxFrameSize else {
            throw RPCFrameError.frameTooLarge(payload.count)
        }

        let length = UInt32(payload.count)
        var frame = Data([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length)
        ])
        frame.append(payload)
        return frame
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encode(encoder.encode(value))
    }
}

public struct RPCFrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns a complete payload, or nil while the prefix or payload is incomplete.
    /// Invalid lengths leave all buffered bytes intact. Close the connection on
    /// these errors: this framing format has no marker for reliable resynchronization.
    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length != 0 else { throw RPCFrameError.emptyFrame }
        guard length <= RPCFrameCodec.maxFrameSize else {
            throw RPCFrameError.frameTooLarge(length)
        }
        guard buffer.count >= 4 + length else { return nil }

        let payload = Data(buffer.dropFirst(4).prefix(length))
        buffer.removeFirst(4 + length)
        return payload
    }
}

public struct RPCEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var requestID: String
    public var method: String
    public var payload: Data
    /// A bearer credential issued by handshake, never written to the journal.
    public var authorization: String?
    /// Includes queue time; capped at 30 seconds by the host.
    public var timeoutMilliseconds: Int?

    public init(version: Int, requestID: String, method: String, payload: Data,
                authorization: String? = nil, timeoutMilliseconds: Int? = nil) {
        self.version = version
        self.requestID = requestID
        self.method = method
        self.payload = payload
        self.authorization = authorization
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}
