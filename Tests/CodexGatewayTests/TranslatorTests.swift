import XCTest
@testable import CodexGateway

final class TranslatorTests: XCTestCase {
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
}

private func dataLine(_ object: [String: Any], spaced: Bool = true) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    let json = String(decoding: data, as: UTF8.self)
    return spaced ? "data: \(json)" : "data:\(json)"
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
