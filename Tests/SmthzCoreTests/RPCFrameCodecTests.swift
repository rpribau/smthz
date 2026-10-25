import Foundation
import Testing
@testable import SmthzCore

@Test
func rpcFrameRoundtrip() throws {
    let payload = Data(repeating: 0xAB, count: 256)
    let encoded = try RPCFrameCodec.encode(payload)
    #expect(Array(encoded.prefix(4)) == [0, 0, 1, 0])
    var decoder = RPCFrameDecoder()
    #expect(try decoder.nextFrame() == nil)
    decoder.append(encoded)
    #expect(try decoder.nextFrame() == payload)
    #expect(try decoder.nextFrame() == nil)
}

@Test
func rpcTwoFramesInOneChunk() throws {
    let first = Data("first".utf8)
    let second = Data("second".utf8)
    var chunk = try RPCFrameCodec.encode(first)
    chunk.append(try RPCFrameCodec.encode(second))
    var decoder = RPCFrameDecoder()
    decoder.append(chunk)
    #expect(try decoder.nextFrame() == first)
    #expect(try decoder.nextFrame() == second)
    #expect(try decoder.nextFrame() == nil)
}

@Test
func rpcFrameOneByteAtATime() throws {
    let payload = Data("incremental payload".utf8)
    let encoded = try RPCFrameCodec.encode(payload)
    var decoder = RPCFrameDecoder()
    for (offset, byte) in encoded.enumerated() {
        decoder.append(Data([byte]))
        if offset == encoded.count - 1 {
            #expect(try decoder.nextFrame() == payload)
        } else {
            #expect(try decoder.nextFrame() == nil)
        }
    }
    #expect(try decoder.nextFrame() == nil)
}

@Test
func rpcEncodeRejectsInvalidPayloadSizes() {
    #expect(throws: RPCFrameError.emptyFrame) {
        try RPCFrameCodec.encode(Data())
    }
    let count = RPCFrameCodec.maxFrameSize + 1
    #expect(throws: RPCFrameError.frameTooLarge(count)) {
        try RPCFrameCodec.encode(Data(repeating: 0, count: count))
    }
}

@Test
func rpcDecodeRejectsOversizeWithoutConsumingBytes() throws {
    var decoder = RPCFrameDecoder()
    decoder.append(Data([0, 0x10, 0]))
    #expect(try decoder.nextFrame() == nil)
    decoder.append(Data([1]))
    #expect(throws: RPCFrameError.frameTooLarge(1_048_577)) {
        try decoder.nextFrame()
    }
    decoder.append(try RPCFrameCodec.encode(Data([42])))
    #expect(throws: RPCFrameError.frameTooLarge(1_048_577)) {
        try decoder.nextFrame()
    }
}

@Test
func rpcDecodeRejectsEmptyWithoutConsumingBytes() throws {
    var decoder = RPCFrameDecoder()
    decoder.append(Data([0, 0, 0, 0]))
    #expect(throws: RPCFrameError.emptyFrame) { try decoder.nextFrame() }
    decoder.append(try RPCFrameCodec.encode(Data([42])))
    #expect(throws: RPCFrameError.emptyFrame) { try decoder.nextFrame() }
}

@Test
func rpcEnvelopeJSONRoundtrip() throws {
    let envelope = RPCEnvelope(
        version: 1, requestID: "request-123", method: "echo", payload: Data([0, 1, 255])
    )
    var decoder = RPCFrameDecoder()
    decoder.append(try RPCFrameCodec.encode(envelope))
    let decoded = try decoder.nextFrame()
    let json = try #require(decoded)
    #expect(try JSONDecoder().decode(RPCEnvelope.self, from: json) == envelope)
    #expect(String(decoding: json, as: UTF8.self) ==
        #"{"method":"echo","payload":"AAH\/","requestID":"request-123","version":1}"#)
    #expect(try decoder.nextFrame() == nil)
}

@Test
func rpcMaximumFrameSizeIsAccepted() throws {
    let payload = Data(repeating: 0xFF, count: RPCFrameCodec.maxFrameSize)
    var decoder = RPCFrameDecoder()
    decoder.append(try RPCFrameCodec.encode(payload))
    #expect(try decoder.nextFrame() == payload)
    #expect(try decoder.nextFrame() == nil)
}

@Test
func rpcSlicedDataAndPartialTrailingFrame() throws {
    let payload = Data([3, 4, 5])
    let encoded = try RPCFrameCodec.encode(payload)
    var prefixed = Data([99, 98])
    prefixed.append(encoded)
    var decoder = RPCFrameDecoder()
    decoder.append(prefixed.dropFirst(2))
    decoder.append(encoded.prefix(2))
    #expect(try decoder.nextFrame() == payload)
    #expect(try decoder.nextFrame() == nil)
    decoder.append(encoded.dropFirst(2))
    #expect(try decoder.nextFrame() == payload)
    #expect(try decoder.nextFrame() == nil)
}
