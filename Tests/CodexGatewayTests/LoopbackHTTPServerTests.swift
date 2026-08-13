import XCTest
import zlib
@testable import CodexGateway

final class LoopbackHTTPServerTests: XCTestCase {
    func testDecodeChunkedBody() throws {
        let data = Data("7\r\n{\"a\":1}\r\n0\r\n\r\n".utf8)

        let body = try XCTUnwrap(HTTPBodyDecoder.decodeChunked(data))
        XCTAssertEqual(String(data: body, encoding: .utf8), "{\"a\":1}")
    }

    func testDecodeChunkedBodyWithExtensions() throws {
        let data = Data("4;foo=bar\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n".utf8)

        let body = try XCTUnwrap(HTTPBodyDecoder.decodeChunked(data))
        XCTAssertEqual(String(data: body, encoding: .utf8), "{\"a\":1}")
    }

    func testIncompleteChunkedBodyReturnsNil() {
        let data = Data("7\r\n{\"a\":1}\r\n0\r\n".utf8)

        XCTAssertNil(HTTPBodyDecoder.decodeChunked(data))
    }

    func testExtractBodyWaitsForContentLength() {
        let headers = ["content-length": "13"]
        let partial = Data("{\"model\":\"".utf8)

        XCTAssertEqual(
            HTTPRequestParser.extractBody(method: "POST", headers: headers, rawBody: partial, isComplete: false),
            .needMoreData
        )

        let complete = Data("{\"model\":\"x\"}".utf8)
        if case .ready(let body) = HTTPRequestParser.extractBody(
            method: "POST", headers: headers, rawBody: complete, isComplete: false
        ) {
            XCTAssertEqual(String(data: body, encoding: .utf8), "{\"model\":\"x\"}")
        } else {
            XCTFail("expected ready body")
        }
    }

    func testExtractBodyWaitsForPostWithoutLength() {
        let headers: [String: String] = [:]

        XCTAssertEqual(
            HTTPRequestParser.extractBody(method: "POST", headers: headers, rawBody: Data(), isComplete: false),
            .needMoreData
        )

        let body = Data("{\"input\":\"hi\"}".utf8)
        if case .ready(let extracted) = HTTPRequestParser.extractBody(
            method: "POST", headers: headers, rawBody: body, isComplete: false
        ) {
            XCTAssertEqual(String(data: extracted, encoding: .utf8), "{\"input\":\"hi\"}")
        } else {
            XCTFail("expected ready body")
        }
    }

    func testExtractBodyAllowsEmptyGetBody() {
        if case .ready(let body) = HTTPRequestParser.extractBody(
            method: "GET", headers: [:], rawBody: Data(), isComplete: false
        ) {
            XCTAssertTrue(body.isEmpty)
        } else {
            XCTFail("expected empty GET body")
        }
    }

    func testGunzipDecodesGzipJSON() throws {
        let json = "{\"model\":\"gpt-5.5\",\"input\":\"hi\"}"
        let gzipped = try XCTUnwrap(gzipData(json))

        let decoded = try XCTUnwrap(HTTPBodyDecoder.gunzip(gzipped))
        XCTAssertEqual(String(data: decoded, encoding: .utf8), json)
    }

    func testDecodeContentEncodingGunzip() throws {
        let json = "{\"stream\":true}"
        let gzipped = try XCTUnwrap(gzipData(json))
        let headers = ["content-encoding": "gzip"]

        let decoded = HTTPBodyDecoder.decodeContentEncoding(gzipped, headers: headers)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), json)
    }

    func testZstdDecodeWhenLibraryAvailable() throws {
        let json = "{\"stream\":true}"
        let zstdPath = "/opt/homebrew/bin/zstd"
        guard FileManager.default.fileExists(atPath: zstdPath) else {
            throw XCTSkip("zstd CLI unavailable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdPath)
        process.arguments = ["-q", "-c"]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(Data(json.utf8))
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let compressed = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let decoded = HTTPBodyDecoder.decodeContentEncoding(compressed, headers: ["content-encoding": "zstd"])
        XCTAssertEqual(String(data: decoded, encoding: .utf8), json)
    }

    private func gzipData(_ string: String) -> Data? {
        guard let raw = string.data(using: .utf8) else { return nil }
        var stream = z_stream()
        guard deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 4096
        var status: Int32 = Z_OK

        raw.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(raw.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                buffer.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                }
                status = deflate(&stream, Z_FINISH)
                if status == Z_OK || status == Z_STREAM_END {
                    output.append(buffer, count: chunkSize - Int(stream.avail_out))
                }
            } while status == Z_OK
        }

        return status == Z_STREAM_END ? output : nil
    }

    func testForwardHeadersStripsEncodingAndHopByHopHeaders() {
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/responses",
            query: "",
            headers: [
                "host": "127.0.0.1:8765",
                "connection": "keep-alive",
                "content-length": "53458",
                "content-encoding": "zstd",
                "transfer-encoding": "chunked",
                "authorization": "Bearer token",
                "chatgpt-account-id": "acct-123"
            ],
            body: Data()
        )

        let forwarded = request.forwardHeaders
        XCTAssertNil(forwarded["host"])
        XCTAssertNil(forwarded["content-encoding"])
        XCTAssertNil(forwarded["content-length"])
        XCTAssertEqual(forwarded["authorization"], "Bearer token")
        XCTAssertEqual(forwarded["chatgpt-account-id"], "acct-123")
    }

    func testCursorBridgeWaitsOffHTTPQueueWhenNotRunning() {
        XCTAssertTrue(GatewayServer.shouldWaitOffHTTPQueueForCursorBridge(isRunning: false))
        XCTAssertFalse(GatewayServer.shouldWaitOffHTTPQueueForCursorBridge(isRunning: true))
    }

    func testUpstreamErrorPayloadSurfacesStatusAndBody() {
        let payload = GatewayServer.upstreamErrorPayload(
            status: 404,
            bodyPreview: "Route POST:/v1/chat/completions not found"
        )
        let error = payload["error"] as? [String: Any]
        XCTAssertEqual(error?["type"] as? String, "upstream_error")
        XCTAssertEqual(error?["code"] as? Int, 404)
        let message = error?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("404"))
        XCTAssertTrue(message.contains("not found"))
    }
}
