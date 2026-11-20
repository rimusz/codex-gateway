import Foundation

enum Translator {
  private static let thinkPattern = try! NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: .caseInsensitive)

  static func stripThink(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    return thinkPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
  }

  static func extractNamespaceMap(tools: [[String: Any]]?) -> [String: String] {
    guard let tools else { return [:] }
    var map: [String: String] = [:]
    for tool in tools {
      guard (tool["type"] as? String) == "namespace" else { continue }
      let namespace = tool["name"] as? String ?? ""
      let funcs = (tool["functions"] as? [[String: Any]]) ?? (tool["tools"] as? [[String: Any]]) ?? []
      for fn in funcs {
        if let name = fn["name"] as? String, !name.isEmpty {
          map[name] = namespace
        }
      }
    }
    return map
  }

  static func unflattenToolCall(name: String, namespaceMap: [String: String]) -> (String, String?) {
    if let ns = namespaceMap[name] { return (name, ns) }
    if name.contains("__") {
      let parts = name.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
      if parts.count >= 3 {
        let candidate = parts.dropFirst().joined(separator: "_")
        if namespaceMap[candidate] != nil { return (candidate, namespaceMap[candidate]) }
      }
    }
    return (name, nil)
  }

  static func responsesToChat(
    body: [String: Any],
    upstreamModel: String,
    sessionId: String?,
    providerID: String? = nil,
    extraContentStore: ToolCallExtraContentStore = .shared
  ) -> [String: Any] {
    var messages: [[String: Any]] = []
    let system = contentToText(body["instructions"])
    if !system.isEmpty { messages.append(["role": "system", "content": system]) }

    let inputMessages = responsesInputToMessages(
      body["input"],
      providerID: providerID,
      extraContentStore: extraContentStore
    )
    for var m in inputMessages {
      if m["_reasoning_only"] as? Bool == true { continue }
      m.removeValue(forKey: "_reasoning_only")
      messages.append(m)
    }

    messages = mergeConsecutive(messages)
    if messages.isEmpty { messages = [["role": "user", "content": " "]] }

    var chat: [String: Any] = [
      "model": upstreamModel,
      "messages": messages,
      "stream": body["stream"] as? Bool ?? true
    ]
    if chat["stream"] as? Bool == true {
      chat["stream_options"] = ["include_usage": true]
    }
    if let maxOut = body["max_output_tokens"] { chat["max_tokens"] = maxOut }
    if let tools = responsesToolsToChat(body["tools"] as? [[String: Any]]), !tools.isEmpty {
      chat["tools"] = tools
      if let tc = body["tool_choice"] { chat["tool_choice"] = tc }
    }
    return chat
  }

  static func chatCompletionToResponse(
    payload: [String: Any],
    requestedModel: String,
    namespaceMap: [String: String],
    providerID: String? = nil,
    extraContentStore: ToolCallExtraContentStore = .shared
  ) -> [String: Any] {
    let choices = payload["choices"] as? [[String: Any]] ?? []
    let choice = choices.first ?? [:]
    let message = choice["message"] as? [String: Any] ?? [:]
    var output: [[String: Any]] = []

    if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
      output.append([
        "id": "reasoning_0", "type": "reasoning", "status": "completed",
        "summary": [["type": "summary_text", "text": reasoning]]
      ])
    }

    let text = stripThink(chatText(message["content"]))
    if !text.isEmpty {
      output.append([
        "id": "msg_0", "type": "message", "status": "completed", "role": "assistant",
        "content": [["type": "output_text", "text": text, "annotations": []]]
      ])
    }

    for call in message["tool_calls"] as? [[String: Any]] ?? [] {
      let fn = call["function"] as? [String: Any] ?? [:]
      let name = fn["name"] as? String ?? ""
      let (flatName, namespace) = unflattenToolCall(name: name, namespaceMap: namespaceMap)
      let rawId = call["id"] ?? "call_0"
      var item: [String: Any] = [
        "id": rawId,
        "type": "function_call",
        "status": "completed",
        "call_id": rawId,
        "name": flatName,
        "arguments": fn["arguments"] ?? "{}"
      ]
      if let namespace { item["namespace"] = namespace }
      // Codex's function_call schema drops unknown fields, so the signature stays
      // in the gateway cache and is not written onto the Responses item.
      if let providerID, let callID = rawId as? String, let extra = call["extra_content"] as? [String: Any] {
        extraContentStore.remember(providerID: providerID, callID: callID, extraContent: extra)
      }
      output.append(item)
    }

    if output.isEmpty {
      output.append([
        "id": "msg_0", "type": "message", "status": "completed", "role": "assistant",
        "content": [["type": "output_text", "text": " ", "annotations": []]]
      ])
    }

    return [
      "id": payload["id"] ?? "resp_chat",
      "object": "response",
      "created_at": payload["created"] ?? Int(Date().timeIntervalSince1970),
      "status": "completed",
      "model": requestedModel,
      "output": output,
      "usage": payload["usage"] as Any
    ]
  }

  /// String or OpenAI content-part array (`[{type,text}]`) → joined text.
  static func chatText(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let arr = value as? [[String: Any]] {
      return arr.compactMap { part -> String? in
        if let text = part["text"] as? String { return text }
        return nil
      }.joined()
    }
    return ""
  }

  private static func contentToText(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let arr = value as? [[String: Any]] {
      return arr.compactMap { part -> String? in
        let type = (part["type"] as? String ?? "").lowercased()
        if ["input_text", "output_text", "text"].contains(type) {
          return part["text"] as? String
        }
        return nil
      }.joined(separator: "\n")
    }
    return ""
  }

  private static func callIdentifier(_ item: [String: Any]) -> String {
    if let id = item["call_id"] as? String, !id.isEmpty { return id }
    if let id = item["id"] as? String, !id.isEmpty { return id }
    return "call"
  }

  private static func responsesInputToMessages(
    _ value: Any?,
    providerID: String?,
    extraContentStore: ToolCallExtraContentStore
  ) -> [[String: Any]] {
    if let s = value as? String { return [["role": "user", "content": s]] }
    guard let items = value as? [[String: Any]] else { return [] }
    var messages: [[String: Any]] = []
    var pendingTools: [[String: Any]] = []

    for item in items {
      let type = item["type"] as? String
      if type == "message" || item["role"] != nil {
        if !pendingTools.isEmpty {
          messages.append(["role": "assistant", "content": NSNull(), "tool_calls": pendingTools])
          pendingTools = []
        }
        var role = item["role"] as? String ?? "user"
        if role == "developer" { role = "system" }
        messages.append(["role": role, "content": contentToText(item["content"])])
      } else if type == "function_call" {
        let callID = callIdentifier(item)
        var call: [String: Any] = [
          "id": callID,
          "type": "function",
          "function": [
            "name": item["name"] ?? "",
            "arguments": item["arguments"] ?? "{}"
          ]
        ]
        // Replay only what this provider returned. An extra_content field on the
        // Responses input is ignored: Codex does not send one, and copying it
        // would attach another provider's signature to this request.
        if let providerID,
           let extra = extraContentStore.extraContent(providerID: providerID, callID: callID) {
          call["extra_content"] = extra
        }
        pendingTools.append(call)
      } else if type == "function_call_output" {
        if !pendingTools.isEmpty {
          messages.append(["role": "assistant", "content": NSNull(), "tool_calls": pendingTools])
          pendingTools = []
        }
        messages.append([
          "role": "tool",
          "tool_call_id": item["call_id"] ?? "",
          "content": item["output"] as? String ?? String(describing: item["output"] ?? "")
        ])
      } else if type == "reasoning" {
        messages.append(["_reasoning_only": true, "summary": item["summary"] ?? []])
      }
    }
    if !pendingTools.isEmpty {
      messages.append(["role": "assistant", "content": NSNull(), "tool_calls": pendingTools])
    }
    return messages
  }

  private static func mergeConsecutive(_ messages: [[String: Any]]) -> [[String: Any]] {
    var merged: [[String: Any]] = []
    for m in messages {
      if let last = merged.last,
         (last["role"] as? String) == (m["role"] as? String),
         (m["role"] as? String) != "tool",
         last["tool_calls"] == nil, m["tool_calls"] == nil,
         let a = last["content"] as? String, let b = m["content"] as? String {
        var copy = last
        copy["content"] = a + "\n" + b
        merged[merged.count - 1] = copy
      } else {
        merged.append(m)
      }
    }
    return merged
  }

  private static func responsesToolsToChat(_ tools: [[String: Any]]?) -> [[String: Any]]? {
    guard let tools else { return nil }
    var out: [[String: Any]] = []
    for tool in tools {
      if (tool["type"] as? String) == "function" {
        out.append([
          "type": "function",
          "function": [
            "name": tool["name"] ?? "",
            "description": tool["description"] ?? "",
            "parameters": tool["parameters"] ?? ["type": "object", "properties": [:]]
          ]
        ])
      }
    }
    return out
  }
}

/// In-memory `tool_calls[].extra_content` for providers that require it on the
/// next turn. Codex re-sends `function_call` items from a fixed schema
/// (`call_id`, `name`, `arguments`, `namespace`) and drops unknown fields such
/// as Gemini's `extra_content.google.thought_signature`, so the gateway keeps
/// the object and puts it back only when the follow-up goes to the same provider.
final class ToolCallExtraContentStore: @unchecked Sendable {
  static let shared = ToolCallExtraContentStore()
  /// A Codex thread re-sends every earlier function call. The cap has to cover
  /// a long thread; the oldest call id is dropped first.
  static let maxEntries = 1024

  private let lock = NSLock()
  private var order: [String] = []
  private var entries: [String: [String: Any]] = [:]

  func remember(providerID: String, callID: String, extraContent: [String: Any]) {
    let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    let call = callID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !provider.isEmpty, !call.isEmpty, !extraContent.isEmpty else { return }
    guard let copy = Self.detachedCopy(extraContent) else { return }
    let key = Self.key(providerID: provider, callID: call)
    lock.lock()
    defer { lock.unlock() }
    if entries[key] == nil {
      order.append(key)
    }
    entries[key] = copy
    while order.count > Self.maxEntries {
      let oldest = order.removeFirst()
      entries.removeValue(forKey: oldest)
    }
  }

  func extraContent(providerID: String, callID: String) -> [String: Any]? {
    let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    let call = callID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !provider.isEmpty, !call.isEmpty else { return nil }
    lock.lock()
    let stored = entries[Self.key(providerID: provider, callID: call)]
    lock.unlock()
    guard let stored else { return nil }
    return Self.detachedCopy(stored)
  }

  private static func key(providerID: String, callID: String) -> String {
    providerID + "\u{1f}" + callID
  }

  /// Independent JSON tree so a later mutation of the parse buffer cannot
  /// change the stored signature bytes.
  private static func detachedCopy(_ value: [String: Any]) -> [String: Any]? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return copy
  }
}

final class ResponsesStreamState {
  let responseId = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
  private let messageItemId = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
  private let model: String
  private let namespaceMap: [String: String]
  private let providerID: String?
  private let extraContentStore: ToolCallExtraContentStore
  private var messageText = ""
  private var reasoningText = ""
  private var messageOpened = false
  private var messageClosed = false
  private var sequence = 1
  private var toolCalls: [Int: [String: Any]] = [:]
  var onTextChunk: ((String) -> Void)?
  var onTextDone: ((String) -> Void)?
  private var sawTerminator = false
  private var sawDataLine = false
  private var sawNonSSEBody = false
  private var sawMalformedData = false
  private var sawTruncatedBody = false
  private var finishedBeforeError = false
  private var appliedRawBody = false
  private var rawBody = ""
  private static let rawBodyCap = 8 * 1024 * 1024

  /// Any delta already written to the client, including whitespace. A retry must
  /// not append a second copy of text the client has seen.
  var hasForwardedText: Bool {
    !messageText.isEmpty
  }

  /// Provider error text from an SSE or JSON `error` chunk, when this attempt
  /// did not already finish. Not a drop: the caller must not retry it.
  private(set) var providerErrorMessage: String?

  /// Any buffered slot counts, including a fragment that has not received its
  /// name yet. A clean end would otherwise drop that fragment.
  var hasPendingToolCalls: Bool {
    !toolCalls.isEmpty
  }

  init(
    model: String,
    namespaceMap: [String: String],
    onTextChunk: ((String) -> Void)? = nil,
    onTextDone: ((String) -> Void)? = nil,
    providerID: String? = nil,
    extraContentStore: ToolCallExtraContentStore = .shared
  ) {
    self.model = model
    self.namespaceMap = namespaceMap
    self.onTextChunk = onTextChunk
    self.onTextDone = onTextDone
    self.providerID = providerID
    self.extraContentStore = extraContentStore
  }

  func start(write: ([String: Any]) -> Void) {
    write(wrap(["type": "response.created", "response": response("in_progress")]))
    write(wrap(["type": "response.in_progress", "response": response("in_progress")]))
  }

  func writeChatDelta(_ chunk: [String: Any], write: ([String: Any]) -> Void) {
    let choice = (chunk["choices"] as? [[String: Any]])?.first ?? [:]
    let delta = choice["delta"] as? [String: Any] ?? [:]
    let message = choice["message"] as? [String: Any] ?? [:]
    appendVisible(Translator.chatText(delta["content"]), write: write)
    appendVisible(Translator.chatText(message["content"]), write: write)
    reasoningText += Translator.chatText(delta["reasoning_content"])
    reasoningText += Translator.chatText(message["reasoning_content"])
    ingestToolCalls(delta["tool_calls"] as? [[String: Any]] ?? [])
    ingestToolCalls(message["tool_calls"] as? [[String: Any]] ?? [])
    let choices = chunk["choices"] as? [[String: Any]] ?? []
    for candidate in choices {
      if let reason = candidate["finish_reason"] as? String, !reason.isEmpty {
        sawTerminator = true
        break
      }
    }
  }

  /// One upstream line. `data:` with or without a space, `[DONE]`, and a JSON
  /// error chunk are recognized. Other lines before the first `data:` line are
  /// kept so a non-SSE JSON body can still be translated.
  func ingestUpstreamLine(_ line: String, write: ([String: Any]) -> Void) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard trimmed.hasPrefix("data:") else {
      guard !sawDataLine else { return }
      let addition = (rawBody.isEmpty ? "" : "\n") + trimmed
      guard rawBody.utf8.count + addition.utf8.count <= Self.rawBodyCap else { return }
      rawBody += addition
      return
    }
    sawDataLine = true
    var payload = String(trimmed.dropFirst("data:".count))
    if payload.first == " " { payload.removeFirst() }
    if payload == "[DONE]" {
      sawTerminator = true
      return
    }
    guard let data = payload.data(using: .utf8),
          let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      sawMalformedData = true
      return
    }
    if let error = chunk["error"] {
      noteProviderError(error, fallback: String(payload.prefix(400)))
      return
    }
    writeChatDelta(chunk, write: write)
  }

  /// Emit the assembled response when this attempt is finished.
  /// A pending tool call without `finish_reason`, `[DONE]`, or a full JSON body
  /// stays buffered so the caller can retry or fail without a partial `function_call`.
  @discardableResult
  func finishIfComplete(upstreamFailed: Bool, write: ([String: Any]) -> Void) -> Bool {
    applyRawBodyIfNeeded(write: write)
    // A finish signal wins over a later error chunk: the call was already complete.
    let finished = (sawTerminator || sawNonSSEBody) && !hasNamelessToolCall
    if finished, providerErrorMessage == nil || finishedBeforeError {
      finish(write: write)
      return true
    }
    // Provider errors are terminal. Truncated JSON is a drop the caller may retry.
    if providerErrorMessage != nil || sawMalformedData || sawTruncatedBody { return false }
    guard !upstreamFailed, !hasPendingToolCalls else { return false }
    finish(write: write)
    return true
  }

  /// Drop this attempt's buffered tool calls and flags. Keeps the response id,
  /// sequence, and any text already forwarded so a retry does not restart the turn.
  /// `extra_content` is stored only when a call is emitted, so a discarded
  /// attempt does not publish a signature Codex never saw.
  func discardAttempt() {
    toolCalls = [:]
    reasoningText = ""
    sawTerminator = false
    sawDataLine = false
    sawNonSSEBody = false
    sawMalformedData = false
    sawTruncatedBody = false
    finishedBeforeError = false
    appliedRawBody = false
    rawBody = ""
    providerErrorMessage = nil
  }

  func fail(code: String, message: String, write: ([String: Any]) -> Void) {
    var resp = response("failed")
    resp["error"] = [
      "type": "upstream_error",
      "code": code,
      "message": message
    ] as [String: Any]
    write(wrap(["type": "response.failed", "response": resp]))
  }

  private func applyRawBodyIfNeeded(write: ([String: Any]) -> Void) {
    guard !appliedRawBody, !sawDataLine, !rawBody.isEmpty else { return }
    appliedRawBody = true
    guard let data = rawBody.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      if rawBody.contains("{") || rawBody.contains("[") { sawTruncatedBody = true }
      return
    }
    if let error = payload["error"] {
      noteProviderError(error, fallback: String(rawBody.prefix(400)))
      return
    }
    guard payload["choices"] != nil else {
      if rawBody.contains("{") || rawBody.contains("[") { sawTruncatedBody = true }
      return
    }
    sawNonSSEBody = true
    writeChatDelta(payload, write: write)
  }

  private var hasNamelessToolCall: Bool {
    toolCalls.values.contains { (($0["name"] as? String) ?? "").isEmpty }
  }

  private func noteProviderError(_ error: Any, fallback: String) {
    if sawTerminator || sawNonSSEBody { finishedBeforeError = true }
    let message = Self.providerErrorText(error) ?? fallback
    providerErrorMessage = message
    GatewayLog.error("Upstream chat stream error chunk: \(String(message.prefix(200)))")
  }

  private static func providerErrorText(_ error: Any) -> String? {
    if let text = error as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    guard let object = error as? [String: Any] else { return nil }
    if let message = object["message"] as? String {
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return String(text.prefix(400))
  }

  func finish(write: ([String: Any]) -> Void, usage: [String: Any]? = nil) {
    let visible = Translator.stripThink(messageText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if visible.isEmpty, !reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      appendVisible(Translator.stripThink(reasoningText), write: write)
    }
    let hasTools = toolCalls.values.contains { !((($0["name"] as? String) ?? "").isEmpty) }
    if messageOpened || !hasTools {
      if !messageOpened { openMessage(write: write) }
      if messageOpened && !messageClosed { closeMessage(write: write) }
    }
    emitToolCalls(write: write)
    onTextDone?(Translator.stripThink(messageText))
    let completed = response("completed", usage: usage)
    write(wrap(["type": "response.completed", "response": completed]))
    write(wrap(["type": "response.done", "response": completed]))
  }

  private func appendVisible(_ text: String, write: ([String: Any]) -> Void) {
    guard !text.isEmpty else { return }
    if !messageOpened { openMessage(write: write) }
    messageText += text
    onTextChunk?(text)
    write(wrap([
      "type": "response.output_text.delta",
      "item_id": messageItemId,
      "output_index": 0,
      "content_index": 0,
      "delta": text
    ]))
  }

  private func ingestToolCalls(_ calls: [[String: Any]]) {
    for call in calls {
      let index = call["index"] as? Int ?? toolCalls.count
      var state = toolCalls[index] ?? [
        "id": call["id"] ?? "call_\(index)",
        "name": "",
        "arguments": "",
        "output_index": toolCalls.count
      ]
      if let id = call["id"] as? String, !id.isEmpty { state["id"] = id }
      if let fn = call["function"] as? [String: Any] {
        if let name = fn["name"] as? String { state["name"] = (state["name"] as? String ?? "") + name }
        if let args = fn["arguments"] as? String { state["arguments"] = (state["arguments"] as? String ?? "") + args }
      }
      // Later argument fragments omit the object. Keep the first copy, and
      // replace it only when a later delta for this index sends one.
      if let extra = call["extra_content"] as? [String: Any], !extra.isEmpty {
        state["extra_content"] = extra
      }
      toolCalls[index] = state
    }
  }

  private func emitToolCalls(write: ([String: Any]) -> Void) {
    var outputIndex = messageOpened ? 1 : 0
    for index in toolCalls.keys.sorted() {
      guard let state = toolCalls[index] else { continue }
      let name = state["name"] as? String ?? ""
      guard !name.isEmpty else { continue }
      let rawId = state["id"] as? String ?? "call_\(index)"
      let args = state["arguments"] as? String ?? "{}"
      let (flatName, namespace) = Translator.unflattenToolCall(name: name, namespaceMap: namespaceMap)
      var item: [String: Any] = [
        "id": rawId,
        "type": "function_call",
        "status": "completed",
        "call_id": rawId,
        "name": flatName,
        "arguments": args
      ]
      if let namespace { item["namespace"] = namespace }
      if let providerID, let extra = state["extra_content"] as? [String: Any] {
        extraContentStore.remember(providerID: providerID, callID: rawId, extraContent: extra)
      }
      var added = item
      added["status"] = "in_progress"
      added["arguments"] = ""
      write(wrap([
        "type": "response.output_item.added",
        "output_index": outputIndex,
        "item": added
      ]))
      if !args.isEmpty {
        write(wrap([
          "type": "response.function_call_arguments.delta",
          "item_id": rawId,
          "output_index": outputIndex,
          "delta": args
        ]))
        write(wrap([
          "type": "response.function_call_arguments.done",
          "item_id": rawId,
          "output_index": outputIndex,
          "arguments": args
        ]))
      }
      write(wrap([
        "type": "response.output_item.done",
        "output_index": outputIndex,
        "item": item
      ]))
      outputIndex += 1
    }
  }

  private func openMessage(write: ([String: Any]) -> Void) {
    messageOpened = true
    write(wrap([
      "type": "response.output_item.added",
      "output_index": 0,
      "item": ["id": messageItemId, "type": "message", "status": "in_progress", "role": "assistant", "content": []]
    ]))
  }

  private func closeMessage(write: ([String: Any]) -> Void) {
    messageClosed = true
    write(wrap([
      "type": "response.output_item.done",
      "output_index": 0,
      "item": [
        "id": messageItemId, "type": "message", "status": "completed", "role": "assistant",
        "content": [["type": "output_text", "text": Translator.stripThink(messageText), "annotations": []]]
      ]
    ]))
  }

  private func response(_ status: String, usage: [String: Any]? = nil) -> [String: Any] {
    var resp: [String: Any] = [
      "id": responseId,
      "object": "response",
      "status": status,
      "model": model,
      "output": []
    ]
    if let usage { resp["usage"] = usage }
    return resp
  }

  private func wrap(_ payload: [String: Any]) -> [String: Any] {
    var p = payload
    p["sequence_number"] = sequence
    sequence += 1
    return p
  }
}
