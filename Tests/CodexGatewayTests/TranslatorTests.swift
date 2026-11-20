import XCTest
@testable import CodexGateway

final class TranslatorTests: CodexGatewayTestCase {
    func testStripThinkRemovesRedactedBlocks() {
        let input = "Hello <think>secret</think> world"
        XCTAssertEqual(Translator.stripThink(input), "Hello  world")
    }

    func testStripThinkRemovesMultilineBlocks() {
        let input = """
        Before
        <think>
        line one
        line two
        </think>
        After
        """
        let output = Translator.stripThink(input)
        XCTAssertTrue(output.contains("Before"))
        XCTAssertTrue(output.contains("After"))
        XCTAssertFalse(output.contains("line one"))
    }

    func testExtractNamespaceMapFromTools() {
        let tools: [[String: Any]] = [
            [
                "type": "namespace",
                "name": "mcp_cursor",
                "functions": [
                    ["name": "read_file"],
                    ["name": "write_file"]
                ]
            ]
        ]

        let map = Translator.extractNamespaceMap(tools: tools)
        XCTAssertEqual(map["read_file"], "mcp_cursor")
        XCTAssertEqual(map["write_file"], "mcp_cursor")
    }

    func testUnflattenToolCallUsesNamespaceMap() {
        let map = ["read_file": "mcp_cursor"]
        let (name, namespace) = Translator.unflattenToolCall(name: "read_file", namespaceMap: map)
        XCTAssertEqual(name, "read_file")
        XCTAssertEqual(namespace, "mcp_cursor")
    }

    func testUnflattenToolCallReturnsOriginalWhenUnknown() {
        let (name, namespace) = Translator.unflattenToolCall(
            name: "mcp_cursor__read_file",
            namespaceMap: ["read_file": "mcp_cursor"]
        )
        XCTAssertEqual(name, "mcp_cursor__read_file")
        XCTAssertNil(namespace)
    }

    func testResponsesToChatMapsInstructionsAndInput() {
        let body: [String: Any] = [
            "instructions": "You are helpful.",
            "input": "Hello",
            "stream": false,
            "max_output_tokens": 512
        ]

        let chat = Translator.responsesToChat(body: body, upstreamModel: "gpt-4o", sessionId: nil)

        XCTAssertEqual(chat["model"] as? String, "gpt-4o")
        XCTAssertEqual(chat["stream"] as? Bool, false)
        XCTAssertEqual(chat["max_tokens"] as? Int, 512)

        let messages = chat["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are helpful.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "Hello")
    }

    func testResponsesToChatMergesConsecutiveSameRoleMessages() {
        let body: [String: Any] = [
            "input": [
                ["type": "message", "role": "user", "content": "First"],
                ["type": "message", "role": "user", "content": "Second"]
            ]
        ]

        let chat = Translator.responsesToChat(body: body, upstreamModel: "gpt-4o", sessionId: nil)
        let messages = chat["messages"] as? [[String: Any]] ?? []

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["content"] as? String, "First\nSecond")
    }

    func testChatCompletionToResponseMapsAssistantText() {
        let payload: [String: Any] = [
            "id": "chatcmpl-1",
            "choices": [
                [
                    "message": [
                        "content": "Hi there"
                    ]
                ]
            ],
            "usage": ["total_tokens": 10]
        ]

        let response = Translator.chatCompletionToResponse(
            payload: payload,
            requestedModel: "custom/slug",
            namespaceMap: [:]
        )

        XCTAssertEqual(response["model"] as? String, "custom/slug")
        XCTAssertEqual(response["object"] as? String, "response")
        XCTAssertEqual(response["status"] as? String, "completed")

        let output = response["output"] as? [[String: Any]] ?? []
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0]["type"] as? String, "message")

        let content = output[0]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.first?["text"] as? String, "Hi there")
    }

    func testChatCompletionToResponseMapsToolCallsWithNamespace() {
        let payload: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "content": "",
                        "tool_calls": [
                            [
                                "id": "call_1",
                                "function": [
                                    "name": "read_file",
                                    "arguments": #"{"path":"a.txt"}"#
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let response = Translator.chatCompletionToResponse(
            payload: payload,
            requestedModel: "custom/slug",
            namespaceMap: ["read_file": "mcp_cursor"]
        )

        let output = response["output"] as? [[String: Any]] ?? []
        let toolCall = output.first { ($0["type"] as? String) == "function_call" }
        XCTAssertEqual(toolCall?["name"] as? String, "read_file")
        XCTAssertEqual(toolCall?["namespace"] as? String, "mcp_cursor")
    }

    func testChatTextJoinsContentPartArrays() {
        XCTAssertEqual(Translator.chatText("hello"), "hello")
        XCTAssertEqual(
            Translator.chatText([["type": "text", "text": "A"], ["type": "text", "text": "B"]]),
            "AB"
        )
        XCTAssertEqual(Translator.chatText(nil), "")
    }

    func testResponsesStreamEmitsFunctionCallsWithoutEmptyMessage() {
        let state = ResponsesStreamState(model: "openrouter/minimax-m2.5", namespaceMap: ["shell": "default"])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.start(write: write)
        state.writeChatDelta([
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call_1",
                        "function": ["name": "shell", "arguments": #"{"cmd":"ls"}"#]
                    ]]
                ]
            ]]
        ], write: write)
        state.finish(write: write)

        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains("response.output_item.added"))
        XCTAssertTrue(types.contains("response.function_call_arguments.delta"))
        XCTAssertTrue(types.contains("response.output_item.done"))
        XCTAssertTrue(types.contains("response.completed"))

        let functionItems = events.compactMap { event -> [String: Any]? in
            guard let item = event["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else { return nil }
            return item
        }
        XCTAssertFalse(functionItems.isEmpty)
        XCTAssertEqual(functionItems.last?["name"] as? String, "shell")
        XCTAssertEqual(functionItems.last?["arguments"] as? String, #"{"cmd":"ls"}"#)
        XCTAssertEqual(functionItems.last?["namespace"] as? String, "default")

        let assistantMessages = events.compactMap { event -> [String: Any]? in
            guard (event["type"] as? String) == "response.output_item.done",
                  let item = event["item"] as? [String: Any],
                  (item["type"] as? String) == "message" else { return nil }
            return item
        }
        XCTAssertTrue(assistantMessages.isEmpty, "tool-only streams must not emit an empty assistant message")
    }

    func testResponsesStreamUsesReasoningWhenContentEmpty() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.start(write: write)
        state.writeChatDelta([
            "choices": [[
                "delta": ["reasoning_content": "The project is a menu-bar gateway."]
            ]]
        ], write: write)
        state.finish(write: write)
        let deltas = events.compactMap { $0["delta"] as? String }
        XCTAssertTrue(deltas.contains("The project is a menu-bar gateway."))
    }

    func testResponsesStreamAcceptsFullMessageChunk() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.start(write: write)
        state.writeChatDelta([
            "choices": [[
                "message": ["content": "pong"]
            ]]
        ], write: write)
        state.finish(write: write)
        let deltas = events.compactMap { $0["delta"] as? String }
        XCTAssertTrue(deltas.contains("pong"))
    }

    func testStreamIngestUpstreamLineParsesDataVariantsAndDone() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(": keepalive", write: write)
        state.ingestUpstreamLine(dataLine(["choices": [["delta": ["content": "Hi"]]]]), write: write)
        state.ingestUpstreamLine(dataLine(["choices": [["delta": ["content": "!"]]]], spaced: false), write: write)
        let deltasBeforeEnd = events.compactMap { $0["delta"] as? String }
        XCTAssertEqual(deltasBeforeEnd, ["Hi", "!"])
        state.ingestUpstreamLine("data: [DONE]\r", write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertTrue(events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testStreamToolCallEmittedOnceAfterFinishReason() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_abc", name: "shell", arguments: #"{"path":"#)), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, arguments: #""a.txt""#)), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, arguments: "}")), write: write)
        XCTAssertTrue(functionCallItems(events).isEmpty, "partial arguments must stay buffered")
        state.ingestUpstreamLine(dataLine(["choices": [["delta": [String: String](), "finish_reason": "tool_calls"]]]), write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))

        let dones = functionCallDones(events)
        XCTAssertEqual(dones.count, 1)
        XCTAssertEqual(dones.first?["call_id"] as? String, "call_abc")
        XCTAssertEqual(dones.first?["arguments"] as? String, #"{"path":"a.txt"}"#)
        let argumentDones = events.filter { ($0["type"] as? String) == "response.function_call_arguments.done" }
        XCTAssertEqual(argumentDones.count, 1)
        XCTAssertEqual(argumentDones.first?["arguments"] as? String, #"{"path":"a.txt"}"#)
    }

    func testStreamParallelToolCallsEmitInIndexOrder() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 1, id: "call_b", name: "shell", arguments: #"{"c":"#)), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_a", name: "read", arguments: #"{"p":"#)), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, arguments: #""a"}"#)), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 1, arguments: "1}")), write: write)
        XCTAssertTrue(functionCallItems(events).isEmpty)
        state.ingestUpstreamLine(dataLine(["choices": [["finish_reason": "tool_calls"]]]), write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))

        let dones = functionCallDones(events)
        XCTAssertEqual(dones.count, 2)
        XCTAssertEqual(dones[0]["output_index"] as? Int, 0)
        XCTAssertEqual(dones[0]["call_id"] as? String, "call_a")
        XCTAssertEqual(dones[0]["arguments"] as? String, #"{"p":"a"}"#)
        XCTAssertEqual(dones[1]["output_index"] as? Int, 1)
        XCTAssertEqual(dones[1]["call_id"] as? String, "call_b")
        XCTAssertEqual(dones[1]["arguments"] as? String, #"{"c":1}"#)
    }

    func testStreamPendingToolCallWithoutTerminatorIsIncomplete() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_abc", name: "shell", arguments: #"{"path":"#)), write: write)
        XCTAssertFalse(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertTrue(functionCallItems(events).isEmpty)
        XCTAssertFalse(events.contains { ($0["type"] as? String) == "response.completed" })

        let nameless = ResponsesStreamState(model: "m", namespaceMap: [:])
        var namelessEvents: [[String: Any]] = []
        nameless.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_x", arguments: #"{"a":"#)), write: { namelessEvents.append($0) })
        XCTAssertTrue(nameless.hasPendingToolCalls)
        XCTAssertFalse(nameless.finishIfComplete(upstreamFailed: false, write: { namelessEvents.append($0) }))
        XCTAssertTrue(functionCallItems(namelessEvents).isEmpty)
    }

    func testStreamTextOnlyWithoutTerminatorStillCompletes() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(["choices": [["delta": ["content": "hello"]]]]), write: write)
        XCTAssertEqual(events.compactMap { $0["delta"] as? String }, ["hello"])
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertTrue(events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testStreamFinishReasonBeforeTransportErrorCompletes() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_abc", name: "shell", arguments: #"{"ok":true}"#, finish: "tool_calls")), write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: true, write: write))
        XCTAssertEqual(functionCallDones(events).first?["call_id"] as? String, "call_abc")
    }

    func testStreamDiscardAttemptDropsPartialToolCalls() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_1", name: "shell", arguments: #"{"a":"#)), write: write)
        state.discardAttempt()
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_2", name: "read", arguments: #"{"p":"b"}"#, finish: "tool_calls")), write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))
        let dones = functionCallDones(events)
        XCTAssertEqual(dones.count, 1)
        XCTAssertEqual(dones.first?["call_id"] as? String, "call_2")
        XCTAssertEqual(dones.first?["arguments"] as? String, #"{"p":"b"}"#)
    }

    func testStreamUpstreamErrorChunkIsIncomplete() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_abc", name: "shell", arguments: #"{"a":1}"#)), write: write)
        state.ingestUpstreamLine(#"data: {"error":{"message":"nope"}}"#, write: write)
        XCTAssertFalse(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertTrue(functionCallItems(events).isEmpty)
        XCTAssertFalse(events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testStreamNonSSEJSONBodyFallback() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        let pretty = """
        {
          "choices": [
            {"message": {"content": "pong"}}
          ]
        }
        """
        for line in pretty.components(separatedBy: "\n") {
            state.ingestUpstreamLine(line, write: write)
        }
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertTrue(events.compactMap { $0["delta"] as? String }.contains("pong"))
        XCTAssertTrue(events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testStreamFailEmitsResponseFailedWithStringCode() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        state.fail(code: "upstream_stream_interrupted", message: "boom", write: { events.append($0) })
        let failed = events.first { ($0["type"] as? String) == "response.failed" }
        let response = failed?["response"] as? [String: Any]
        XCTAssertEqual(response?["status"] as? String, "failed")
        let error = response?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "upstream_stream_interrupted")
        XCTAssertNil(error?["code"] as? Int)
    }

    func testStreamMalformedDataLineIsIncomplete() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        state.ingestUpstreamLine("data: {\"choices\":[", write: { events.append($0) })
        XCTAssertFalse(state.finishIfComplete(upstreamFailed: false, write: { events.append($0) }))
        XCTAssertFalse(events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testStreamErrorAfterFinishReasonStillEmitsToolCall() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_ok", name: "shell", arguments: #"{"a":1}"#, finish: "tool_calls")), write: write)
        state.ingestUpstreamLine(#"data: {"error":{"message":"late"}}"#, write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: true, write: write))
        XCTAssertEqual(functionCallDones(events).first?["call_id"] as? String, "call_ok")
    }

    func testStreamNamelessToolCallWithFinishReasonIsIncomplete() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, id: "call_x", arguments: #"{"a":"#, finish: "tool_calls")), write: write)
        XCTAssertTrue(state.hasPendingToolCalls)
        XCTAssertFalse(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertTrue(functionCallItems(events).isEmpty)
        XCTAssertFalse(events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testStreamTruncatedJSONBodyIsIncomplete() {
        let state = ResponsesStreamState(model: "m", namespaceMap: [:])
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        state.ingestUpstreamLine("{", write: write)
        state.ingestUpstreamLine("\"choices\": [", write: write)
        XCTAssertFalse(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertFalse(events.contains { ($0["type"] as? String) == "response.completed" })
    }

    func testNonStreamedGeminiThoughtSignatureRoundTrips() throws {
        let store = ToolCallExtraContentStore()
        let signature = "sig/with+slash=\"quoted\"\\end-\u{00e9}"
        let payload: [String: Any] = [
            "choices": [[
                "message": [
                    "content": "",
                    "tool_calls": [[
                        "id": "call_gemini",
                        "type": "function",
                        "extra_content": ["google": ["thought_signature": signature]],
                        "function": ["name": "shell", "arguments": "{\"cmd\":\"ls\"}"]
                    ]]
                ]
            ]]
        ]
        let response = Translator.chatCompletionToResponse(
            payload: payload,
            requestedModel: "gemini/gemini-3.8-flash",
            namespaceMap: [:],
            providerID: "gemini",
            extraContentStore: store
        )
        let output = response["output"] as? [[String: Any]] ?? []
        let sentToCodex = output.first { ($0["type"] as? String) == "function_call" }
        XCTAssertEqual(sentToCodex?["call_id"] as? String, "call_gemini")
        XCTAssertNil(sentToCodex?["extra_content"])

        let body = followUpResponsesBody(calls: [
            (id: "call_gemini", name: "shell", arguments: "{\"cmd\":\"ls\"}")
        ])
        let gemini = try encodedChatMessages(Translator.responsesToChat(
            body: body,
            upstreamModel: "gemini-3.8-flash",
            sessionId: nil,
            providerID: "gemini",
            extraContentStore: store
        ))
        let call = try XCTUnwrap(assistantToolCall(gemini, id: "call_gemini"))
        XCTAssertEqual(thoughtSignature(call), signature)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, "{\"cmd\":\"ls\"}")

        let other = try encodedChatMessages(Translator.responsesToChat(
            body: body,
            upstreamModel: "deepseek-chat",
            sessionId: nil,
            providerID: "deepseek",
            extraContentStore: store
        ))
        let otherCall = try XCTUnwrap(assistantToolCall(other, id: "call_gemini"))
        XCTAssertNil(otherCall["extra_content"])

        var echoed = body
        var input = echoed["input"] as? [[String: Any]] ?? []
        input[1]["extra_content"] = ["google": ["thought_signature": "echoed-from-codex"]]
        echoed["input"] = input
        let leaked = try encodedChatMessages(Translator.responsesToChat(
            body: echoed,
            upstreamModel: "openai/gpt-4o",
            sessionId: nil,
            providerID: "openrouter",
            extraContentStore: store
        ))
        XCTAssertNil(try XCTUnwrap(assistantToolCall(leaked, id: "call_gemini"))["extra_content"])
    }

    func testStreamedGeminiThoughtSignatureRoundTrips() throws {
        let store = ToolCallExtraContentStore()
        let signature = "stream-sig/with+slash=\"quoted\"\\end-\u{00e9}"
        let state = ResponsesStreamState(
            model: "gemini/gemini-3.8-flash",
            namespaceMap: [:],
            providerID: "gemini",
            extraContentStore: store
        )
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }

        state.ingestUpstreamLine(dataLine(toolDelta(
            index: 0,
            id: "call_dropped",
            name: "shell",
            arguments: "{}",
            extraContent: ["google": ["thought_signature": "dropped-sig"]]
        )), write: write)
        state.discardAttempt()

        state.ingestUpstreamLine(dataLine(toolDelta(
            index: 0,
            id: "call_kept",
            name: "shell",
            extraContent: ["google": ["thought_signature": signature]]
        )), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, arguments: "{\"cmd\":\"pwd\"}")), write: write)
        state.ingestUpstreamLine("data: [DONE]", write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))

        XCTAssertNil(store.extraContent(providerID: "gemini", callID: "call_dropped"))
        let item = functionCallDones(events).first { ($0["call_id"] as? String) == "call_kept" }
        XCTAssertEqual(item?["arguments"] as? String, "{\"cmd\":\"pwd\"}")
        XCTAssertNil(item?["extra_content"])

        let messages = try encodedChatMessages(Translator.responsesToChat(
            body: followUpResponsesBody(calls: [
                (id: "call_kept", name: "shell", arguments: "{\"cmd\":\"pwd\"}")
            ]),
            upstreamModel: "gemini-3.8-flash",
            sessionId: nil,
            providerID: "gemini",
            extraContentStore: store
        ))
        XCTAssertEqual(thoughtSignature(try XCTUnwrap(assistantToolCall(messages, id: "call_kept"))), signature)
    }

    func testParallelGeminiThoughtSignatureStaysOnFirstCall() throws {
        let signature = "parallel-first-only/sig+=\u{00e9}"
        let store = ToolCallExtraContentStore()
        let payload: [String: Any] = [
            "choices": [[
                "message": [
                    "content": "",
                    "tool_calls": [
                        [
                            "id": "call_first",
                            "type": "function",
                            "extra_content": ["google": ["thought_signature": signature]],
                            "function": ["name": "shell", "arguments": "{\"cmd\":\"ls\"}"]
                        ],
                        [
                            "id": "call_second",
                            "type": "function",
                            "function": ["name": "read_file", "arguments": "{\"path\":\"a.txt\"}"]
                        ]
                    ]
                ]
            ]]
        ]
        _ = Translator.chatCompletionToResponse(
            payload: payload,
            requestedModel: "gemini/gemini-3.8-flash",
            namespaceMap: [:],
            providerID: "gemini",
            extraContentStore: store
        )
        let nonStream = try encodedChatMessages(Translator.responsesToChat(
            body: followUpResponsesBody(calls: [
                (id: "call_first", name: "shell", arguments: "{\"cmd\":\"ls\"}"),
                (id: "call_second", name: "read_file", arguments: "{\"path\":\"a.txt\"}")
            ]),
            upstreamModel: "gemini-3.8-flash",
            sessionId: nil,
            providerID: "gemini",
            extraContentStore: store
        ))
        XCTAssertEqual(thoughtSignature(try XCTUnwrap(assistantToolCall(nonStream, id: "call_first"))), signature)
        XCTAssertNil(try XCTUnwrap(assistantToolCall(nonStream, id: "call_second"))["extra_content"])

        let streamStore = ToolCallExtraContentStore()
        let state = ResponsesStreamState(
            model: "gemini/gemini-3.8-flash",
            namespaceMap: [:],
            providerID: "gemini",
            extraContentStore: streamStore
        )
        var events: [[String: Any]] = []
        let write: ([String: Any]) -> Void = { events.append($0) }
        let firstChunk: [String: Any] = [
            "choices": [[
                "delta": [
                    "tool_calls": [
                        [
                            "index": 0,
                            "id": "call_s0",
                            "extra_content": ["google": ["thought_signature": signature]],
                            "function": ["name": "shell", "arguments": ""]
                        ],
                        [
                            "index": 1,
                            "id": "call_s1",
                            "function": ["name": "read_file", "arguments": ""]
                        ]
                    ]
                ]
            ]]
        ]
        state.ingestUpstreamLine(dataLine(firstChunk), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 0, arguments: "{\"cmd\":\"ls\"}")), write: write)
        state.ingestUpstreamLine(dataLine(toolDelta(index: 1, arguments: "{\"path\":\"a.txt\"}")), write: write)
        state.ingestUpstreamLine(dataLine(["choices": [["finish_reason": "tool_calls", "delta": [:]]]]), write: write)
        XCTAssertTrue(state.finishIfComplete(upstreamFailed: false, write: write))
        XCTAssertEqual(functionCallDones(events).count, 2)
        XCTAssertNil(functionCallDones(events).first { ($0["call_id"] as? String) == "call_s0" }?["extra_content"])

        let streamed = try encodedChatMessages(Translator.responsesToChat(
            body: followUpResponsesBody(calls: [
                (id: "call_s0", name: "shell", arguments: "{\"cmd\":\"ls\"}"),
                (id: "call_s1", name: "read_file", arguments: "{\"path\":\"a.txt\"}")
            ]),
            upstreamModel: "gemini-3.8-flash",
            sessionId: nil,
            providerID: "gemini",
            extraContentStore: streamStore
        ))
        XCTAssertEqual(thoughtSignature(try XCTUnwrap(assistantToolCall(streamed, id: "call_s0"))), signature)
        XCTAssertNil(try XCTUnwrap(assistantToolCall(streamed, id: "call_s1"))["extra_content"])
    }
}

final class ToolCallExtraContentStoreTests: CodexGatewayTestCase {
    private var tempPath: String!
    private var clock: ToolCallExtraContentClock!

    override func setUp() {
        super.setUp()
        tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-call-extra-\(UUID().uuidString).json")
            .path
        clock = ToolCallExtraContentClock(Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDown() {
        if let tempPath {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        tempPath = nil
        clock = nil
        super.tearDown()
    }

    func testCacheLimits() {
        XCTAssertEqual(ToolCallExtraContentStore.maxEntries, 1024)
        XCTAssertEqual(ToolCallExtraContentStore.ttl, 24 * 60 * 60)
        XCTAssertTrue(Paths.toolCallExtraContentCache.hasSuffix("/.codexgateway/tool_call_extra_content.json"))
    }

    func testPersistedSignatureSurvivesReload() {
        let signature = "sig/with+slash=\"quoted\"\\end-\u{00e9}"
        let store = makeStore()
        store.remember(
            providerID: "gemini",
            callID: "call_gemini",
            extraContent: google(signature)
        )

        let reloaded = makeStore()
        XCTAssertEqual(storedSignature(reloaded, "call_gemini"), signature)
        XCTAssertNil(reloaded.extraContent(providerID: "deepseek", callID: "call_gemini"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath))
    }

    func testExpiredEntriesAreNotRestored() {
        let start = clock.now
        let store = makeStore()
        store.remember(providerID: "gemini", callID: "call_old", extraContent: google("old-sig"))
        clock.now = start.addingTimeInterval(ToolCallExtraContentStore.ttl - 1)
        store.remember(providerID: "gemini", callID: "call_young", extraContent: google("young-sig"))

        clock.now = start.addingTimeInterval(ToolCallExtraContentStore.ttl)
        let reloaded = makeStore()
        XCTAssertNil(reloaded.extraContent(providerID: "gemini", callID: "call_old"))
        XCTAssertEqual(storedSignature(reloaded, "call_young"), "young-sig")
    }

    func testExpiredEntryIsDroppedOnAccess() {
        let start = clock.now
        let store = makeStore()
        store.remember(providerID: "gemini", callID: "call_old", extraContent: google("old-sig"))
        clock.now = start.addingTimeInterval(ToolCallExtraContentStore.ttl - 1)
        store.remember(providerID: "gemini", callID: "call_young", extraContent: google("young-sig"))
        clock.now = start.addingTimeInterval(ToolCallExtraContentStore.ttl)
        XCTAssertNil(store.extraContent(providerID: "gemini", callID: "call_old"))
        XCTAssertEqual(storedSignature(store, "call_young"), "young-sig")

        // Rewind so a stale file would still be inside the TTL. The drop has to
        // have been written, and the younger call has to still be there.
        clock.now = start
        let reloaded = makeStore()
        XCTAssertNil(reloaded.extraContent(providerID: "gemini", callID: "call_old"))
        XCTAssertEqual(storedSignature(reloaded, "call_young"), "young-sig")
    }

    func testSizeCapDropsOldestPersistedEntry() {
        let store = makeStore(maxEntries: 2)
        store.remember(providerID: "gemini", callID: "call_1", extraContent: google("sig-1"))
        clock.now = clock.now.addingTimeInterval(1)
        store.remember(providerID: "gemini", callID: "call_2", extraContent: google("sig-2"))
        clock.now = clock.now.addingTimeInterval(1)
        store.remember(providerID: "gemini", callID: "call_3", extraContent: google("sig-3"))

        XCTAssertNil(store.extraContent(providerID: "gemini", callID: "call_1"))
        XCTAssertEqual(storedSignature(store, "call_2"), "sig-2")
        XCTAssertEqual(storedSignature(store, "call_3"), "sig-3")

        let reloaded = makeStore()
        XCTAssertNil(reloaded.extraContent(providerID: "gemini", callID: "call_1"))
        XCTAssertEqual(storedSignature(reloaded, "call_2"), "sig-2")
        XCTAssertEqual(storedSignature(reloaded, "call_3"), "sig-3")
    }

    func testIntegerStoredAtReloads() throws {
        let instant = Int(clock.now.timeIntervalSince1970)
        let json = """
        {"entries":[{"call_id":"call_hand","extra_content":{"google":{"thought_signature":"hand-sig"}},"provider_id":"gemini","stored_at":\(instant)}]}
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: tempPath))
        XCTAssertEqual(storedSignature(makeStore(), "call_hand"), "hand-sig")
    }

    func testMissingCacheFileStartsEmpty() {
        let store = makeStore()
        XCTAssertNil(store.extraContent(providerID: "gemini", callID: "call_gemini"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))
    }

    func testCorruptCacheFileIsTolerated() throws {
        let url = URL(fileURLWithPath: tempPath)
        let fixtures = [
            Data("{not-json".utf8),
            Data("[]".utf8),
            Data(),
            Data(#"{"entries":"nope"}"#.utf8),
            Data(#"{"entries":[null, 1, "x"]}"#.utf8),
        ]
        for bytes in fixtures {
            try bytes.write(to: url)
            let store = makeStore()
            XCTAssertNil(store.extraContent(providerID: "gemini", callID: "call_gemini"))
        }

        let signature = "recovered-sig"
        let store = makeStore()
        store.remember(providerID: "gemini", callID: "call_gemini", extraContent: google(signature))
        XCTAssertEqual(storedSignature(makeStore(), "call_gemini"), signature)
    }

    private func makeStore(maxEntries: Int = ToolCallExtraContentStore.maxEntries) -> ToolCallExtraContentStore {
        let clock = self.clock!
        return ToolCallExtraContentStore(
            filePath: tempPath,
            now: { clock.now },
            maxEntries: maxEntries
        )
    }

    private func google(_ signature: String) -> [String: Any] {
        ["google": ["thought_signature": signature]]
    }

    private func storedSignature(
        _ store: ToolCallExtraContentStore,
        _ callID: String,
        providerID: String = "gemini"
    ) -> String? {
        guard let extra = store.extraContent(providerID: providerID, callID: callID) else { return nil }
        return thoughtSignature(["extra_content": extra])
    }
}

private final class ToolCallExtraContentClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func dataLine(_ object: [String: Any], spaced: Bool = true) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    let json = String(decoding: data, as: UTF8.self)
    return spaced ? "data: \(json)" : "data:\(json)"
}

private func toolDelta(
    index: Int,
    id: String? = nil,
    name: String? = nil,
    arguments: String? = nil,
    finish: String? = nil,
    extraContent: [String: Any]? = nil
) -> [String: Any] {
    var call: [String: Any] = ["index": index]
    if let id { call["id"] = id }
    if let extraContent { call["extra_content"] = extraContent }
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

private func followUpResponsesBody(calls: [(id: String, name: String, arguments: String)]) -> [String: Any] {
    var input: [[String: Any]] = [
        ["type": "message", "role": "user", "content": "run it"]
    ]
    for call in calls {
        input.append([
            "type": "function_call",
            "call_id": call.id,
            "name": call.name,
            "arguments": call.arguments
        ])
        input.append([
            "type": "function_call_output",
            "call_id": call.id,
            "output": "ok"
        ])
    }
    input.append(["type": "message", "role": "user", "content": "next"])
    return ["input": input]
}

private func encodedChatMessages(_ chat: [String: Any]) throws -> [[String: Any]] {
    let data = try JSONSerialization.data(withJSONObject: chat)
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return parsed?["messages"] as? [[String: Any]] ?? []
}

private func assistantToolCall(_ messages: [[String: Any]], id: String) -> [String: Any]? {
    for message in messages {
        guard (message["role"] as? String) == "assistant",
              let calls = message["tool_calls"] as? [[String: Any]] else { continue }
        if let call = calls.first(where: { ($0["id"] as? String) == id }) {
            return call
        }
    }
    return nil
}

private func thoughtSignature(_ call: [String: Any]) -> String? {
    let extra = call["extra_content"] as? [String: Any]
    let google = extra?["google"] as? [String: Any]
    return google?["thought_signature"] as? String
}
