import Darwin
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

    func testPlaceholderAuthorizationDetectsDummyAndMissing() {
        XCTAssertTrue(GatewayServer.isPlaceholderAuthorization(nil))
        XCTAssertTrue(GatewayServer.isPlaceholderAuthorization(""))
        XCTAssertTrue(GatewayServer.isPlaceholderAuthorization("Bearer"))
        XCTAssertTrue(GatewayServer.isPlaceholderAuthorization("Bearer dummy"))
        XCTAssertTrue(GatewayServer.isPlaceholderAuthorization("dummy"))
        XCTAssertTrue(GatewayServer.isPlaceholderAuthorization("Bearer not-used"))
        XCTAssertTrue(GatewayServer.isPlaceholderAuthorization("NOT-NEEDED"))
        XCTAssertFalse(GatewayServer.isPlaceholderAuthorization("Bearer sk-live"))
        XCTAssertFalse(GatewayServer.isPlaceholderAuthorization("sk-live"))
    }

    func testPassthroughAuthorizationReplacesDummyWithChatGPTToken() {
        XCTAssertEqual(
            GatewayServer.passthroughAuthorization(existing: "Bearer dummy", chatgptToken: "sk-chatgpt"),
            "Bearer sk-chatgpt"
        )
        XCTAssertEqual(
            GatewayServer.passthroughAuthorization(existing: nil, chatgptToken: "sk-chatgpt"),
            "Bearer sk-chatgpt"
        )
        XCTAssertEqual(
            GatewayServer.passthroughAuthorization(existing: "Bearer sk-client", chatgptToken: "sk-chatgpt"),
            "Bearer sk-client"
        )
        XCTAssertNil(GatewayServer.passthroughAuthorization(existing: "Bearer dummy", chatgptToken: nil))
        XCTAssertNil(GatewayServer.passthroughAuthorization(existing: "dummy", chatgptToken: "  "))
        XCTAssertNil(GatewayServer.passthroughAuthorization(existing: nil, chatgptToken: nil))
        XCTAssertNil(GatewayServer.passthroughAuthorization(existing: nil, chatgptToken: "  "))
    }

    func testPassthroughBackendPrefersChatGPTAccount() {
        XCTAssertEqual(
            GatewayServer.passthroughBackend(
                headerAccountID: "hdr",
                authAccountID: "auth",
                authMode: "chatgpt"
            ),
            .chatGPT(accountID: "hdr")
        )
        XCTAssertEqual(
            GatewayServer.passthroughBackend(
                headerAccountID: nil,
                authAccountID: "auth-id",
                authMode: "chatgpt"
            ),
            .chatGPT(accountID: "auth-id")
        )
        XCTAssertEqual(
            GatewayServer.passthroughBackend(
                headerAccountID: nil,
                authAccountID: "auth-id",
                authMode: "apikey"
            ),
            .openAI
        )
        XCTAssertEqual(
            GatewayServer.passthroughBackend(
                headerAccountID: "  ",
                authAccountID: nil,
                authMode: "chatgpt"
            ),
            .openAI
        )
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

    func testChatStreamRetryDelaysAreBounded() {
        XCTAssertEqual(GatewayServer.chatStreamRetryDelaysMs, [250, 750])
    }

    func testChunkFrameRoundTripsThroughDecoder() throws {
        var data = Data()
        data.append(HTTPResponse.chunkFrame(Data("hello".utf8)))
        data.append(HTTPResponse.chunkFrame(Data(" world".utf8)))
        data.append(Data("0\r\n\r\n".utf8))
        let body = try XCTUnwrap(HTTPBodyDecoder.decodeChunked(data))
        XCTAssertEqual(String(data: body, encoding: .utf8), "hello world")
    }

    func testRelayForwardsTextDeltaBeforeUpstreamEnds() async {
        let (stream, continuation) = ChatUpstreamStream.makeStream()
        let sink = RecordingSink()
        let delta = expectation(description: "text delta")
        sink.setOnEvent { event in
            if (event["type"] as? String) == "response.output_text.delta" {
                delta.fulfill()
            }
        }
        let task = Task {
            await GatewayServer.relayChatStream(
                requestedModel: "gemini",
                namespaceMap: [:],
                sink: sink,
                retryDelaysMs: [0, 0]
            ) { _ in stream }
        }
        continuation.yield(.status(200))
        continuation.yield(.line(chatDataLine(["choices": [["delta": ["content": "Hi"]]]])))
        await fulfillment(of: [delta], timeout: 5)
        let mid = sink.events
        XCTAssertEqual(mid.compactMap { $0["delta"] as? String }, ["Hi"])
        XCTAssertFalse(mid.contains { ($0["type"] as? String) == "response.completed" })
        XCTAssertFalse(sink.didClose)
        continuation.finish()
        await task.value
        XCTAssertTrue(sink.didClose)
        XCTAssertEqual(sink.closeCount, 1)
        XCTAssertTrue(sink.events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testRelayRetriesDroppedToolCallAndEmitsOnce() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_old", name: "shell", arguments: #"{"a":"#)))
            ], failure: .interrupted("connection lost")),
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_new", name: "shell", arguments: #"{"a":1}"#, finish: "tool_calls"))),
                .line("data: [DONE]")
            ])
        ])
        XCTAssertEqual(upstream.opens, 2)
        XCTAssertEqual(sink.events.filter { ($0["type"] as? String) == "response.created" }.count, 1)
        let dones = functionCallDones(sink.events)
        XCTAssertEqual(dones.count, 1)
        XCTAssertEqual(dones.first?["call_id"] as? String, "call_new")
        XCTAssertEqual(dones.first?["arguments"] as? String, #"{"a":1}"#)
        XCTAssertEqual(sink.events.filter { ($0["type"] as? String) == "response.completed" }.count, 1)
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.failed" })
        assertStrictlyIncreasingSequences(sink.events)
        XCTAssertEqual(sink.closeCount, 1)
        XCTAssertTrue(sink.jsonErrors.isEmpty)
    }

    func testRelayRetriesTruncatedStreamWithoutDone() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_old", name: "shell", arguments: #"{"a":"#)))
            ]),
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_new", name: "read", arguments: #"{"p":"z"}"#, finish: "tool_calls")))
            ])
        ])
        XCTAssertEqual(upstream.opens, 2)
        let dones = functionCallDones(sink.events)
        XCTAssertEqual(dones.count, 1)
        XCTAssertEqual(dones.first?["call_id"] as? String, "call_new")
        XCTAssertEqual(dones.first?["arguments"] as? String, #"{"p":"z"}"#)
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.failed" })
    }

    func testRelayParallelToolCallsSurviveRetry() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_a1", name: "read", arguments: #"{"p":"a"}"#))),
                .line(chatDataLine(toolDelta(index: 1, id: "call_b1", name: "shell", arguments: #"{"c":"#)))
            ], failure: .interrupted("reset")),
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 1, id: "call_b2", name: "shell", arguments: #"{"c":1}"#))),
                .line(chatDataLine(toolDelta(index: 0, id: "call_a2", name: "read", arguments: #"{"p":"b"}"#, finish: "tool_calls")))
            ])
        ])
        XCTAssertEqual(upstream.opens, 2)
        let dones = functionCallDones(sink.events)
        XCTAssertEqual(dones.map { $0["call_id"] as? String }, ["call_a2", "call_b2"])
        XCTAssertEqual(dones.map { $0["arguments"] as? String }, [#"{"p":"b"}"#, #"{"c":1}"#])
        XCTAssertEqual(dones.map { $0["output_index"] as? Int }, [0, 1])
    }

    func testRelayFailsCleanlyAfterRetriesExhausted() async {
        let dropped = ScriptedChatUpstream.Attempt(events: [
            .status(200),
            .line(chatDataLine(toolDelta(index: 0, id: "call_x", name: "shell", arguments: #"{"a":"#)))
        ], failure: .interrupted("reset"))
        let (sink, upstream) = await runRelay(attempts: [dropped, dropped, dropped])
        XCTAssertEqual(upstream.opens, 3)
        let failed = failedError(sink.events)
        XCTAssertEqual(failed?["code"] as? String, "upstream_stream_interrupted")
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.completed" })
        XCTAssertTrue(functionCallItems(sink.events).isEmpty)
        XCTAssertTrue(sink.jsonErrors.isEmpty)
        XCTAssertEqual(sink.closeCount, 1)
    }

    func testRelayDoesNotRetryAfterTextForwarded() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(chatDataLine(["choices": [["delta": ["content": "Hello"]]]])),
                .line(chatDataLine(toolDelta(index: 0, id: "call_x", name: "shell", arguments: #"{"a":"#)))
            ], failure: .interrupted("reset")),
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_y", name: "shell", arguments: #"{"a":1}"#, finish: "tool_calls")))
            ])
        ])
        XCTAssertEqual(upstream.opens, 1)
        XCTAssertEqual(sink.events.compactMap { $0["delta"] as? String }, ["Hello"])
        XCTAssertEqual(failedError(sink.events)?["code"] as? String, "upstream_stream_interrupted")
        XCTAssertTrue(functionCallItems(sink.events).isEmpty)
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testRelayHTTPErrorBeforeStreamReturnsJSONError() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(429),
                .line("slow down")
            ])
        ])
        XCTAssertEqual(upstream.opens, 1)
        XCTAssertFalse(sink.didOpen)
        XCTAssertEqual(sink.jsonErrors.count, 1)
        XCTAssertEqual(sink.jsonErrors.first?.status, 429)
        let error = sink.jsonErrors.first?.payload["error"] as? [String: Any]
        XCTAssertEqual(error?["type"] as? String, "upstream_error")
        XCTAssertEqual(error?["code"] as? Int, 429)
        XCTAssertTrue(sink.events.isEmpty)
        XCTAssertFalse(sink.didClose)
    }

    func testRelayConnectFailureBeforeStatusReturns502() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [], failure: .interrupted("cannot connect"))
        ])
        XCTAssertEqual(upstream.opens, 1)
        XCTAssertFalse(sink.didOpen)
        XCTAssertEqual(sink.jsonErrors.first?.status, 502)
        let payload = sink.jsonErrors.first?.payload ?? [:]
        XCTAssertEqual(payload["error"] as? String, "cannot connect")
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testRelayHTTPErrorOnRetryFailsStream() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_x", name: "shell", arguments: #"{"a":"#)))
            ], failure: .interrupted("reset")),
            .init(events: [
                .status(503),
                .line("unavailable")
            ])
        ])
        XCTAssertEqual(upstream.opens, 2)
        XCTAssertTrue(sink.didOpen)
        XCTAssertEqual(failedError(sink.events)?["code"] as? String, "upstream_error")
        XCTAssertTrue(functionCallItems(sink.events).isEmpty)
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.completed" })
        XCTAssertEqual(sink.closeCount, 1)
    }

    func testRelayDoesNotRetryProviderErrorChunk() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(#"data: {"error":{"message":"INVALID_ARGUMENT","code":400}}"#)
            ]),
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_new", name: "shell", arguments: #"{"a":1}"#, finish: "tool_calls")))
            ])
        ])
        XCTAssertEqual(upstream.opens, 1)
        XCTAssertEqual(failedError(sink.events)?["code"] as? String, "upstream_error")
        XCTAssertTrue((failedError(sink.events)?["message"] as? String ?? "").contains("INVALID_ARGUMENT"))
        XCTAssertTrue(functionCallItems(sink.events).isEmpty)
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testRelayCompletesWhenErrorChunkFollowsFinishReason() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_ok", name: "shell", arguments: #"{"a":1}"#, finish: "tool_calls"))),
                .line(#"data: {"error":{"message":"late"}}"#)
            ], failure: .interrupted("reset after done"))
        ])
        XCTAssertEqual(upstream.opens, 1)
        XCTAssertEqual(functionCallDones(sink.events).first?["call_id"] as? String, "call_ok")
        XCTAssertTrue(sink.events.contains { ($0["type"] as? String) == "response.completed" })
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.failed" })
    }

    func testRelayRetriesMalformedDataLine() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line("data: {\"choices\":[")
            ]),
            .init(events: [
                .status(200),
                .line(chatDataLine(toolDelta(index: 0, id: "call_new", name: "read", arguments: #"{"p":"z"}"#, finish: "tool_calls")))
            ])
        ])
        XCTAssertEqual(upstream.opens, 2)
        XCTAssertEqual(functionCallDones(sink.events).first?["call_id"] as? String, "call_new")
        XCTAssertFalse(sink.events.contains { ($0["type"] as? String) == "response.failed" })
    }

    func testRelayDoesNotRetryAfterWhitespaceForwarded() async {
        let (sink, upstream) = await runRelay(attempts: [
            .init(events: [
                .status(200),
                .line(chatDataLine(["choices": [["delta": ["content": "\n\n"]]]]))
            ], failure: .interrupted("reset")),
            .init(events: [
                .status(200),
                .line(chatDataLine(["choices": [["delta": ["content": "again"]]]])),
                .line("data: [DONE]")
            ])
        ])
        XCTAssertEqual(upstream.opens, 1)
        XCTAssertEqual(sink.events.compactMap { $0["delta"] as? String }, ["\n\n"])
        XCTAssertEqual(failedError(sink.events)?["code"] as? String, "upstream_stream_interrupted")
    }

    /// A handler that queues several SSE frames and returns must still deliver every
    /// frame, including the last ones, and the chunked terminator. RecordingSink never
    /// constructs HTTPResponse, so it cannot see a response that deinits mid-flush.
    func testChunkedSSEBurstArrivesAfterHandlerReturns() throws {
        let events = [
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"alpha\"}\n\n",
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_keep\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}\n\n",
            "data: {\"type\":\"response.completed\"}\n\n",
            "data: {\"type\":\"response.done\"}\n\n"
        ]
        let raw = try rawLoopbackResponse(timeout: 4) { response in
            response.startStream(status: 200, headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache"
            ])
            for event in events {
                response.writeChunk(Data(event.utf8))
            }
            response.endStream()
        }

        let text = String(decoding: raw.data, as: UTF8.self)
        XCTAssertTrue(raw.sawEOF, "connection stayed open; body was \(text)")
        XCTAssertTrue(text.contains("Transfer-Encoding: chunked"), text)
        for marker in ["alpha", "call_keep", "a.txt", "response.completed", "response.done"] {
            XCTAssertTrue(text.contains(marker), "missing \(marker) in \(text)")
        }
        XCTAssertTrue(text.hasSuffix("0\r\n\r\n"), text)
    }

    func testSingleBufferSendClosesAfterBody() throws {
        let raw = try rawLoopbackResponse(timeout: 4) { response in
            let body = Data("{\"ok\":true}".utf8)
            response.send(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }
        let text = String(decoding: raw.data, as: UTF8.self)
        XCTAssertTrue(raw.sawEOF, "single-buffer response did not close; body was \(text)")
        XCTAssertTrue(text.contains("{\"ok\":true}"), text)
        XCTAssertTrue(text.contains("Content-Length: 11"), text)
    }

    /// Grok's Chat SSE is already finished, so this path must not use the default
    /// 250/750 ms retries. A truncated tool call would otherwise report `retried 2×`.
    func testGrokOAuthEmitChatSSEAsResponsesDoesNotRetry() async {
        let sink = RecordingSink()
        let chatSSE = chatDataLine(toolDelta(
            index: 0,
            id: "call_grok",
            name: "lookup",
            arguments: #"{"q":"#
        ))
        GatewayServer.shared.emitChatSSEAsResponses(
            chatSSE: chatSSE,
            requestedModel: "grok-oauth",
            namespaceMap: [:],
            response: sink
        )

        let closed = await waitUntil(timeout: 3) { sink.didClose }
        XCTAssertTrue(closed, "Grok stream did not finish")
        XCTAssertEqual(sink.closeCount, 1)
        XCTAssertTrue(functionCallDones(sink.events).isEmpty)
        XCTAssertEqual(failedError(sink.events)?["code"] as? String, "upstream_stream_interrupted")
        let message = failedError(sink.events)?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("retried 0×"), message)
    }
}

private final class RecordingSink: ResponsesEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [[String: Any]] = []
    private var _jsonErrors: [(status: Int, payload: [String: Any])] = []
    private var _openCount = 0
    private var _closeCount = 0
    private var onEvent: (([String: Any]) -> Void)?

    func setOnEvent(_ handler: (([String: Any]) -> Void)?) {
        lock.lock()
        onEvent = handler
        lock.unlock()
    }

    var events: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    var jsonErrors: [(status: Int, payload: [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return _jsonErrors
    }

    var didOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _openCount > 0
    }

    var didClose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _closeCount > 0
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _closeCount
    }

    func sendJSONError(status: Int, body: Data) {
        let payload = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        lock.lock()
        _jsonErrors.append((status, payload))
        lock.unlock()
    }

    func openEventStream() {
        lock.lock()
        _openCount += 1
        lock.unlock()
    }

    func sendEvent(_ sseFrame: Data) {
        guard let event = parseSSEFrame(sseFrame) else { return }
        lock.lock()
        _events.append(event)
        let callback = onEvent
        lock.unlock()
        callback?(event)
    }

    func closeEventStream() {
        lock.lock()
        _closeCount += 1
        lock.unlock()
    }
}

private final class ScriptedChatUpstream: @unchecked Sendable {
    struct Attempt: Sendable {
        var events: [ChatUpstreamEvent]
        var failure: ChatUpstreamFailure? = nil
    }

    private let lock = NSLock()
    private let attempts: [Attempt]
    private var _opens = 0

    init(_ attempts: [Attempt]) {
        self.attempts = attempts
    }

    var opens: Int {
        lock.lock()
        defer { lock.unlock() }
        return _opens
    }

    func open(_ attempt: Int) -> ChatUpstreamStream {
        lock.lock()
        _opens += 1
        lock.unlock()
        let script = attempt < attempts.count
            ? attempts[attempt]
            : Attempt(events: [], failure: .interrupted("missing attempt"))
        let events = script.events
        let failure = script.failure
        return ChatUpstreamStream { (continuation: ChatUpstreamStream.Continuation) in
            let task = Task {
                for event in events {
                    if Task.isCancelled { return }
                    continuation.yield(event)
                }
                if Task.isCancelled { return }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { (_: ChatUpstreamStream.Continuation.Termination) in
                task.cancel()
            }
        }
    }
}

private func runRelay(
    delays: [UInt64] = [0, 0],
    attempts: [ScriptedChatUpstream.Attempt]
) async -> (RecordingSink, ScriptedChatUpstream) {
    let sink = RecordingSink()
    let upstream = ScriptedChatUpstream(attempts)
    await GatewayServer.relayChatStream(
        requestedModel: "gemini",
        namespaceMap: [:],
        sink: sink,
        retryDelaysMs: delays,
        open: { upstream.open($0) }
    )
    return (sink, upstream)
}

private func chatDataLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return "data: " + String(decoding: data, as: UTF8.self)
}

private func toolDelta(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil, finish: String? = nil) -> [String: Any] {
    var call: [String: Any] = ["index": index]
    if let id { call["id"] = id }
    var function: [String: Any] = [:]
    if let name { function["name"] = name }
    if let arguments { function["arguments"] = arguments }
    if !function.isEmpty { call["function"] = function }
    var choice: [String: Any] = ["delta": ["tool_calls": [call]]]
    if let finish { choice["finish_reason"] = finish }
    return ["choices": [choice]]
}

private func functionCallItems(_ events: [[String: Any]]) -> [[String: Any]] {
    events.compactMap { event in
        guard let item = event["item"] as? [String: Any],
              (item["type"] as? String) == "function_call" else { return nil }
        return item
    }
}

private func functionCallDones(_ events: [[String: Any]]) -> [[String: Any]] {
    events.compactMap { event in
        guard (event["type"] as? String) == "response.output_item.done",
              let item = event["item"] as? [String: Any],
              (item["type"] as? String) == "function_call" else { return nil }
        var copy = item
        if let outputIndex = event["output_index"] { copy["output_index"] = outputIndex }
        return copy
    }
}

private func parseSSEFrame(_ frame: Data) -> [String: Any]? {
    guard var text = String(data: frame, encoding: .utf8) else { return nil }
    if text.hasPrefix("data:") {
        text.removeFirst("data:".count)
        if text.first == " " { text.removeFirst() }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func failedError(_ events: [[String: Any]]) -> [String: Any]? {
    guard let event = events.first(where: { ($0["type"] as? String) == "response.failed" }),
          let response = event["response"] as? [String: Any] else { return nil }
    return response["error"] as? [String: Any]
}

private func assertStrictlyIncreasingSequences(_ events: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
    let numbers = events.compactMap { $0["sequence_number"] as? Int }
    for pair in zip(numbers, numbers.dropFirst()) {
        XCTAssertLessThan(pair.0, pair.1, file: file, line: line)
    }
    XCTAssertEqual(numbers.count, events.count, file: file, line: line)
}

private struct RawHTTPRead {
    var data: Data
    var sawEOF: Bool
}

/// Serves one response on a fresh loopback port and reads the raw bytes, including
/// chunk framing, until the connection closes or `timeout` elapses.
private func rawLoopbackResponse(
    timeout: TimeInterval,
    handler: @escaping (HTTPResponse) -> Void
) throws -> RawHTTPRead {
    let server = LoopbackHTTPServer()
    let port = try reserveLoopbackPort()
    server.handler = { _, response in
        handler(response)
    }
    try server.start(host: "127.0.0.1", port: port)
    defer { server.stop() }
    return readRawResponse(port: port, timeout: timeout)
}

private func reserveLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(posixCode(errno)) }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw POSIXError(posixCode(errno)) }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            getsockname(fd, pointer, &length)
        }
    }
    guard nameResult == 0 else { throw POSIXError(posixCode(errno)) }
    return UInt16(bigEndian: bound.sin_port)
}

private func readRawResponse(port: UInt16, timeout: TimeInterval) -> RawHTTPRead {
    let deadline = Date().addingTimeInterval(timeout)
    var fd: Int32 = -1
    while Date() < deadline {
        let attempt = socket(AF_INET, SOCK_STREAM, 0)
        if attempt < 0 { break }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.connect(attempt, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 {
            fd = attempt
            break
        }
        close(attempt)
        usleep(20_000)
    }
    guard fd >= 0 else { return RawHTTPRead(data: Data(), sawEOF: false) }
    defer { close(fd) }

    let request = Data("GET /burst HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
    let sent = request.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return -1 }
        return Darwin.send(fd, base, buffer.count, Int32(0))
    }
    guard sent == request.count else { return RawHTTPRead(data: Data(), sawEOF: false) }

    let flags = fcntl(fd, F_GETFL, Int32(0))
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    var sawEOF = false
    while Date() < deadline {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(fd, base, raw.count)
        }
        if count > 0 {
            received.append(buffer, count: count)
            continue
        }
        if count == 0 {
            sawEOF = true
            break
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            usleep(10_000)
            continue
        }
        break
    }
    return RawHTTPRead(data: received, sawEOF: sawEOF)
}

private func posixCode(_ code: Int32) -> POSIXErrorCode {
    POSIXErrorCode(rawValue: code) ?? .EIO
}

private func waitUntil(timeout: TimeInterval, _ predicate: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return predicate()
}
