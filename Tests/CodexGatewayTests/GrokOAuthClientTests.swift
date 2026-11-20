import XCTest
@testable import CodexGateway

final class GrokOAuthClientTests: CodexGatewayTestCase {
  func testChatToResponsesMapsMessagesAndTools() {
    let chat: [String: Any] = [
      "model": "grok-4",
      "messages": [
        ["role": "system", "content": "Be brief"],
        ["role": "user", "content": "Hello"],
        [
          "role": "assistant",
          "content": "",
          "tool_calls": [[
            "id": "call_1",
            "type": "function",
            "function": ["name": "lookup", "arguments": #"{"q":"x"}"#]
          ]]
        ],
        ["role": "tool", "tool_call_id": "call_1", "content": "result"]
      ],
      "tools": [[
        "type": "function",
        "function": [
          "name": "lookup",
          "description": "Look up",
          "parameters": ["type": "object", "properties": [:] as [String: Any]]
        ]
      ]]
    ]

    let req = GrokOAuthClient.chatToResponsesRequest(chat, stream: true)
    XCTAssertEqual(req["model"] as? String, "grok-4")
    XCTAssertEqual(req["stream"] as? Bool, true)
    XCTAssertEqual(req["store"] as? Bool, false)
    XCTAssertEqual(req["instructions"] as? String, "Be brief")
    let input = req["input"] as? [[String: Any]] ?? []
    XCTAssertEqual(input.count, 3)
    XCTAssertEqual(input[0]["type"] as? String, "message")
    XCTAssertEqual(input[1]["type"] as? String, "function_call")
    XCTAssertEqual(input[2]["type"] as? String, "function_call_output")
    let tools = req["tools"] as? [[String: Any]] ?? []
    XCTAssertEqual(tools.count, 1)
    XCTAssertEqual(tools[0]["name"] as? String, "lookup")
  }

  func testResponsesSSEToChatCompletionCollectsText() {
    let sse = """
    data: {"type":"response.output_text.delta","delta":"Hi"}

    data: {"type":"response.output_text.delta","delta":" there"}

    data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":2}}}

    """
    let completion = GrokOAuthClient.responsesSSEToChatCompletion(sse, model: "grok-4")
    let choices = completion["choices"] as? [[String: Any]] ?? []
    let message = choices.first?["message"] as? [String: Any]
    XCTAssertEqual(message?["content"] as? String, "Hi there")
    XCTAssertEqual(choices.first?["finish_reason"] as? String, "stop")
    let usage = completion["usage"] as? [String: Any]
    XCTAssertEqual(usage?["prompt_tokens"] as? Int, 3)
    XCTAssertEqual(usage?["completion_tokens"] as? Int, 2)
  }

  func testResponsesSSEToChatSSEEmitsDeltas() {
    let sse = """
    data: {"type":"response.output_text.delta","delta":"A"}

    data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}

    """
    let chatSSE = GrokOAuthClient.responsesSSEToChatSSE(sse, model: "grok-4")
    XCTAssertTrue(chatSSE.contains(#""content":"A""#))
    XCTAssertTrue(chatSSE.contains("data: [DONE]"))
  }

  func testForwardChatRetriesOnceOn401() throws {
    var tokenCalls: [Bool] = []
    var statuses = [401, 200]
    let okSSE = """
    data: {"type":"response.output_text.delta","delta":"ok"}

    data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}

    """
    let result = try GrokOAuthClient.forwardChat(
      chatBody: [
        "model": "grok-4",
        "messages": [["role": "user", "content": "hi"]],
        "stream": false
      ],
      baseURL: "https://cli-chat-proxy.grok.com/v1",
      ensureToken: { force in
        tokenCalls.append(force)
        return force ? "new-token" : "old-token"
      },
      perform: { _ in
        let status = statuses.removeFirst()
        if status == 401 {
          return (401, Data("unauthorized".utf8))
        }
        return (200, Data(okSSE.utf8))
      }
    )
    XCTAssertEqual(result.status, 200)
    XCTAssertFalse(result.isStream)
    XCTAssertEqual(tokenCalls, [false, true])
    let payload = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
    let content = ((payload?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
    XCTAssertEqual(content, "ok")
  }

  func testUpstreamHeadersIncludeGrokCLIMarkers() {
    let headers = GrokOAuthClient.upstreamHeaders(
      accessToken: "tok",
      model: "grok-4",
      clientVersion: "1.2.3"
    )
    XCTAssertEqual(headers["Authorization"], "Bearer tok")
    XCTAssertEqual(headers["X-XAI-Token-Auth"], "xai-grok-cli")
    XCTAssertEqual(headers["x-grok-client-identifier"], "grok-shell")
    XCTAssertEqual(headers["x-grok-model-override"], "grok-4")
    XCTAssertEqual(headers["x-grok-client-version"], "1.2.3")
    XCTAssertTrue(headers["User-Agent"]?.contains("grok-shell/1.2.3") == true)
  }

  func testWaitTimeoutSecondsUsesRequestTimeoutPlusGrace() {
    var request = URLRequest(url: URL(string: "https://example.com")!)
    request.timeoutInterval = 30
    XCTAssertEqual(GrokOAuthClient.waitTimeoutSeconds(for: request), 31)

    var unset = URLRequest(url: URL(string: "https://example.com")!)
    unset.timeoutInterval = 0
    XCTAssertEqual(
      GrokOAuthClient.waitTimeoutSeconds(for: unset),
      GrokOAuthClient.defaultRequestTimeout + 1
    )
  }
}
