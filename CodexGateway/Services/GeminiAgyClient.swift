import Foundation

/// Cloud Code (`v1internal`) client for the unofficial agy Google sign-in.
///
/// Default host is `https://daily-cloudcode-pa.googleapis.com` (present in the agy binary and used
/// by unofficial agy-auth quota calls). `CLOUD_CODE_URL` overrides it. Method URLs follow
/// gemini-cli's `{endpoint}/{version}:{method}` (`loadCodeAssist`, `fetchAvailableModels`,
/// `generateContent`, `streamGenerateContent?alt=sse`). No API key and no OAuth client secret.
enum GeminiAgyClient {
  static let defaultHost = "https://daily-cloudcode-pa.googleapis.com"
  static let apiVersion = "v1internal"
  static let defaultRequestTimeout: TimeInterval = 120

  enum ClientError: LocalizedError, Equatable {
    case notSignedIn
    case rateLimited(retryAfter: String?)
    case modelNotFound(String)
    case thoughtSignature
    case upstream(status: Int, detail: String)
    case transport(String)

    var errorDescription: String? {
      switch self {
      case .notSignedIn:
        return GeminiAgySession.signInMessage
      case .rateLimited(let retryAfter):
        if let retryAfter, !retryAfter.isEmpty {
          return "Gemini quota returned HTTP 429. Retry-After: \(retryAfter)."
        }
        return "Gemini quota returned HTTP 429."
      case .modelNotFound(let model):
        let name = model.isEmpty ? "the requested model" : model
        return "Gemini model not found: \(name)."
      case .thoughtSignature:
        return GeminiAgySession.thoughtSignatureMessage
      case .upstream(let status, let detail):
        return "Gemini Cloud Code error (HTTP \(status)): \(detail)"
      case .transport(let message):
        return message
      }
    }
  }

  static func resolvedHost(
    configured: String = "",
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    if let override = environment["CLOUD_CODE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
      return override
    }
    let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.contains("cloudcode-pa") || lower.contains("codeassist") {
      return trimmed
    }
    return defaultHost
  }

  static func methodURL(host: String, method: String, sse: Bool = false) -> URL {
    var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    if !base.lowercased().contains(apiVersion) {
      base += "/\(apiVersion)"
    }
    var string = "\(base):\(method)"
    if sse { string += "?alt=sse" }
    return URL(string: string)!
  }

  static func userAgent(version: String?) -> String {
    let version = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if version.isEmpty { return "antigravity/cli" }
    return "antigravity/cli/\(version)"
  }

  /// Prefer a Gemini 3.8 Flash / Hydrogen id from a fetched catalog. Returns nil when the list is empty.
  static func preferredModelID(from models: [FetchedModel]) -> String? {
    let ids = models.map(\.id).filter { !$0.isEmpty }
    func first(matching predicate: (String) -> Bool) -> String? {
      ids.first(where: predicate)
    }
    let lower: (String) -> String = { $0.lowercased() }
    if let id = first(matching: { lower($0).contains("hydrogen") && lower($0).contains("3.8") && lower($0).contains("flash") }) {
      return id
    }
    if let id = first(matching: { lower($0).contains("3.8") && lower($0).contains("flash") }) {
      return id
    }
    if let id = first(matching: { lower($0).contains("hydrogen") && lower($0).contains("flash") }) {
      return id
    }
    if let id = first(matching: { lower($0).contains("gemini") }) {
      return id
    }
    return ids.first
  }

  static func requestHeaders(accessToken: String, userAgent: String) -> [String: String] {
    [
      "Authorization": "Bearer \(accessToken)",
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": userAgent,
    ]
  }

  static func loadCodeAssistBody() -> [String: Any] {
    ["metadata": ["ideType": "ANTIGRAVITY"]]
  }

  static func fetchAvailableModelsBody(project: String?) -> [String: Any] {
    var body: [String: Any] = loadCodeAssistBody()
    if let project, !project.isEmpty { body["project"] = project }
    return body
  }

  /// OpenAI chat body → Cloud Code `generateContent` JSON. Throws when a replayed function call has no signature.
  static func chatToGenerateContent(
    _ chat: [String: Any],
    project: String?
  ) throws -> [String: Any] {
    var contents: [[String: Any]] = []
    var systemParts: [[String: Any]] = []
    var pendingNameByID: [String: String] = [:]

    for message in chat["messages"] as? [[String: Any]] ?? [] {
      let role = (message["role"] as? String) ?? "user"
      if role == "system" || role == "developer" {
        let text = textContent(message["content"])
        if !text.isEmpty { systemParts.append(["text": text]) }
        continue
      }
      if role == "tool" {
        let callID = message["tool_call_id"] as? String ?? ""
        let name = pendingNameByID[callID] ?? callID
        var responseObject: [String: Any]
        if let object = message["content"] as? [String: Any] {
          responseObject = object
        } else if let text = message["content"] as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          responseObject = object
        } else {
          responseObject = ["output": textContent(message["content"])]
        }
        var functionResponse: [String: Any] = [
          "name": name,
          "response": responseObject,
        ]
        if !callID.isEmpty { functionResponse["id"] = callID }
        contents.append(["role": "user", "parts": [["functionResponse": functionResponse]]])
        continue
      }
      if role == "assistant" {
        var parts: [[String: Any]] = []
        let text = textContent(message["content"])
        if !text.isEmpty { parts.append(["text": text]) }
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
          let fn = call["function"] as? [String: Any] ?? [:]
          let name = fn["name"] as? String ?? ""
          let callID = call["id"] as? String ?? ""
          if !callID.isEmpty { pendingNameByID[callID] = name }
          let args = jsonObject(fn["arguments"]) ?? [:]
          var functionCall: [String: Any] = ["name": name, "args": args]
          if !callID.isEmpty { functionCall["id"] = callID }
          var part: [String: Any] = ["functionCall": functionCall]
          guard let signature = thoughtSignature(in: call["extra_content"]) else {
            throw ClientError.thoughtSignature
          }
          part["thoughtSignature"] = signature
          parts.append(part)
        }
        if !parts.isEmpty {
          contents.append(["role": "model", "parts": parts])
        }
        continue
      }
      let text = textContent(message["content"])
      contents.append(["role": "user", "parts": [["text": text]]])
    }

    var inner: [String: Any] = ["contents": contents]
    if !systemParts.isEmpty {
      inner["systemInstruction"] = ["parts": systemParts]
    }
    if let tools = functionDeclarations(chat["tools"] as? [[String: Any]]), !tools.isEmpty {
      inner["tools"] = [["functionDeclarations": tools]]
    }
    var generation: [String: Any] = [:]
    if let temperature = chat["temperature"] as? Double {
      generation["temperature"] = temperature
    }
    if let maxTokens = chat["max_tokens"] as? Int {
      generation["maxOutputTokens"] = maxTokens
    }
    if !generation.isEmpty { inner["generationConfig"] = generation }

    var model = chat["model"] as? String ?? ""
    if model.lowercased().hasPrefix("models/") {
      model = String(model.dropFirst("models/".count))
    }
    var body: [String: Any] = [
      "model": model,
      "request": inner,
    ]
    if let project, !project.isEmpty { body["project"] = project }
    return body
  }

  static func parseAvailableModels(_ data: Data) -> [FetchedModel]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let payload = (root["response"] as? [String: Any]) ?? root
    guard let models = payload["models"] else { return nil }
    if let map = models as? [String: Any] {
      var fetched: [FetchedModel] = []
      for key in map.keys.sorted() {
        let detail = map[key] as? [String: Any] ?? [:]
        if (detail["disabled"] as? Bool) == true { continue }
        let id = ((detail["id"] as? String) ?? key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { continue }
        let display = (detail["displayName"] as? String) ?? (detail["display_name"] as? String)
        fetched.append(FetchedModel(id: id, ownedBy: display))
      }
      return fetched
    }
    if let list = models as? [[String: Any]] {
      return list.compactMap { entry in
        if (entry["disabled"] as? Bool) == true { return nil }
        guard let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        let display = (entry["displayName"] as? String) ?? (entry["display_name"] as? String)
        return FetchedModel(id: id, ownedBy: display)
      }
    }
    return nil
  }

  /// One Cloud Code JSON body or an SSE stream → OpenAI chat completion.
  static func cloudCodeToChatCompletion(_ data: Data, model: String) -> [String: Any]? {
    let text = String(data: data, encoding: .utf8) ?? ""
    if text.contains("data:") {
      var mergedParts: [[String: Any]] = []
      var usage: [String: Any]?
      var saw = false
      for event in parseSSEJSON(text) {
        saw = true
        let piece = candidateParts(from: event)
        mergedParts.append(contentsOf: piece.parts)
        if let usageMetadata = piece.usage { usage = usageMetadata }
      }
      if saw {
        return chatCompletion(parts: attachParentSignatures(mergedParts), model: model, usage: usage)
      }
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let piece = candidateParts(from: object)
    return chatCompletion(parts: attachParentSignatures(piece.parts), model: model, usage: piece.usage)
  }

  /// Copy a signature that arrived on a sibling or parent part onto each function-call part that lacks one.
  static func attachParentSignatures(_ parts: [[String: Any]]) -> [[String: Any]] {
    var parent: String?
    for part in parts {
      if let signature = signatureString(in: part), part["functionCall"] == nil && part["function_call"] == nil {
        parent = signature
      }
    }
    return parts.map { part in
      var copy = part
      let call = (copy["functionCall"] as? [String: Any]) ?? (copy["function_call"] as? [String: Any])
      guard call != nil, signatureString(in: copy) == nil, let parent else { return copy }
      copy["thoughtSignature"] = parent
      return copy
    }
  }

  static func classify(status: Int, data: Data, headers: [String: String], model: String) -> ClientError? {
    if status == 401 || status == 403 { return .notSignedIn }
    if status == 429 {
      let retry = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value
      return .rateLimited(retryAfter: retry)
    }
    let preview = String(data: data.prefix(800), encoding: .utf8) ?? ""
    let lower = preview.lowercased()
    if lower.contains("thought_signature") || lower.contains("thoughtsignature") || lower.contains("thought signature") {
      return .thoughtSignature
    }
    if status == 404 || lower.contains("model not found") || lower.contains("was not found") || lower.contains("not_found") && lower.contains("model") {
      return .modelNotFound(model)
    }
    if status >= 400 {
      return .upstream(status: status, detail: String(preview.prefix(400)))
    }
    return nil
  }

  static func fetchModels(
    baseURL: String = defaultHost,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    userAgent: String = userAgent(version: nil),
    ensureToken: (_ force: Bool) throws -> String = { force in try GeminiAgySession.ensureFreshAccessToken(force: force) },
    perform: (URLRequest) throws -> (status: Int, headers: [String: String], data: Data)
  ) throws -> [FetchedModel] {
    let token: String
    do {
      token = try ensureToken(false)
    } catch {
      throw ClientError.notSignedIn
    }
    let host = resolvedHost(configured: baseURL, environment: environment)
    var request = URLRequest(url: methodURL(host: host, method: "fetchAvailableModels"))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.httpBody = try JSONSerialization.data(withJSONObject: fetchAvailableModelsBody(project: nil))
    for (key, value) in requestHeaders(accessToken: token, userAgent: userAgent) {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (status, headers, data) = try perform(request)
    if let error = classify(status: status, data: data, headers: headers, model: "") {
      throw error
    }
    guard let models = parseAvailableModels(data), !models.isEmpty else {
      throw ClientError.upstream(status: status, detail: "Could not read fetchAvailableModels.")
    }
    return models
  }

  /// Chat Completions in, Chat Completions JSON or SSE out. Does not call the network when unsigned.
  static func forwardChat(
    chatBody: [String: Any],
    baseURL: String = defaultHost,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    userAgent: String = userAgent(version: nil),
    project: String? = nil,
    ensureToken: (_ force: Bool) throws -> String = { force in try GeminiAgySession.ensureFreshAccessToken(force: force) },
    loadProject: Bool = true,
    perform: (URLRequest) throws -> (status: Int, headers: [String: String], data: Data) = { try performSync($0) }
  ) throws -> (status: Int, data: Data, isStream: Bool) {
    let token: String
    do {
      token = try ensureToken(false)
    } catch {
      throw ClientError.notSignedIn
    }
    let host = resolvedHost(configured: baseURL, environment: environment)
    let model = chatBody["model"] as? String ?? ""
    var projectID = project
    if loadProject && (projectID == nil || projectID?.isEmpty == true) {
      projectID = try loadProjectID(host: host, token: token, userAgent: userAgent, perform: perform)
    }
    let body = try chatToGenerateContent(chatBody, project: projectID)
    let wantsStream = chatBody["stream"] as? Bool ?? true
    let method = wantsStream ? "streamGenerateContent" : "generateContent"
    let bodyData = try JSONSerialization.data(withJSONObject: body)

    func makeRequest(token: String) -> URLRequest {
      var request = URLRequest(url: methodURL(host: host, method: method, sse: wantsStream))
      request.httpMethod = "POST"
      request.timeoutInterval = defaultRequestTimeout
      request.httpBody = bodyData
      for (key, value) in requestHeaders(accessToken: token, userAgent: userAgent) {
        request.setValue(value, forHTTPHeaderField: key)
      }
      if wantsStream {
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      }
      return request
    }

    var (status, headers, data) = try perform(makeRequest(token: token))
    if status == 401 {
      let refreshed: String
      do { refreshed = try ensureToken(true) } catch { throw ClientError.notSignedIn }
      (status, headers, data) = try perform(makeRequest(token: refreshed))
    }
    if let error = classify(status: status, data: data, headers: headers, model: model) {
      throw error
    }
    guard let completion = cloudCodeToChatCompletion(data, model: model) else {
      throw ClientError.upstream(status: status, detail: "Could not read the Cloud Code response.")
    }
    if wantsStream {
      let sse = chatCompletionToSSE(completion, model: model)
      return (200, Data(sse.utf8), true)
    }
    let json = try JSONSerialization.data(withJSONObject: completion)
    return (200, json, false)
  }

  static func performSync(_ request: URLRequest) throws -> (status: Int, headers: [String: String], data: Data) {
    var request = request
    if request.timeoutInterval <= 0 { request.timeoutInterval = defaultRequestTimeout }
    let semaphore = DispatchSemaphore(value: 0)
    var status = 0
    var headers: [String: String] = [:]
    var data = Data()
    var resultError: Error?
    let task = URLSession.shared.dataTask(with: request) { body, response, error in
      defer { semaphore.signal() }
      if let error {
        resultError = error
        return
      }
      let http = response as? HTTPURLResponse
      status = http?.statusCode ?? 0
      http?.allHeaderFields.forEach { key, value in
        if let key = key as? String, let value = value as? String { headers[key] = value }
      }
      data = body ?? Data()
    }
    task.resume()
    let timeout = DispatchTime.now() + request.timeoutInterval + 1
    if semaphore.wait(timeout: timeout) == .timedOut {
      task.cancel()
      throw ClientError.transport("Gemini Cloud Code request timed out.")
    }
    if let resultError { throw ClientError.transport(resultError.localizedDescription) }
    return (status, headers, data)
  }

  // MARK: - Private

  private static func loadProjectID(
    host: String,
    token: String,
    userAgent: String,
    perform: (URLRequest) throws -> (status: Int, headers: [String: String], data: Data)
  ) throws -> String? {
    var request = URLRequest(url: methodURL(host: host, method: "loadCodeAssist"))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.httpBody = try JSONSerialization.data(withJSONObject: loadCodeAssistBody())
    for (key, value) in requestHeaders(accessToken: token, userAgent: userAgent) {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (status, headers, data) = try perform(request)
    if status == 401 || status == 403 {
      throw ClientError.notSignedIn
    }
    if status == 429 {
      throw classify(status: status, data: data, headers: headers, model: "") ?? .rateLimited(retryAfter: nil)
    }
    guard (200..<300).contains(status),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    for key in ["cloudaicompanionProject", "project", "projectId", "project_id"] {
      if let value = object[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  private static func textContent(_ value: Any?) -> String {
    if let string = value as? String { return string }
    if value is NSNull { return "" }
    if let parts = value as? [[String: Any]] {
      return parts.compactMap { $0["text"] as? String }.joined()
    }
    return ""
  }

  private static func jsonObject(_ value: Any?) -> [String: Any]? {
    if let object = value as? [String: Any] { return object }
    guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func thoughtSignature(in extra: Any?) -> String? {
    guard let extra = extra as? [String: Any] else { return nil }
    if let google = extra["google"] as? [String: Any] {
      if let signature = google["thought_signature"] as? String, !signature.isEmpty { return signature }
      if let signature = google["thoughtSignature"] as? String, !signature.isEmpty { return signature }
    }
    if let signature = extra["thought_signature"] as? String, !signature.isEmpty { return signature }
    return nil
  }

  private static func functionDeclarations(_ tools: [[String: Any]]?) -> [[String: Any]]? {
    guard let tools else { return nil }
    let declarations: [[String: Any]] = tools.compactMap { tool in
      guard (tool["type"] as? String) == "function",
            let fn = tool["function"] as? [String: Any],
            let name = fn["name"] as? String, !name.isEmpty else { return nil }
      return [
        "name": name,
        "description": fn["description"] as? String ?? "",
        "parameters": fn["parameters"] ?? ["type": "object", "properties": [:] as [String: Any]],
      ]
    }
    return declarations
  }

  private struct CandidatePiece {
    var parts: [[String: Any]]
    var usage: [String: Any]?
  }

  private static func candidateParts(from object: [String: Any]) -> CandidatePiece {
    let payload = (object["response"] as? [String: Any]) ?? object
    let candidates = payload["candidates"] as? [[String: Any]] ?? []
    var parts: [[String: Any]] = []
    for candidate in candidates {
      let content = candidate["content"] as? [String: Any] ?? [:]
      var contentSignature: String? = signatureString(in: content) ?? signatureString(in: candidate) ?? signatureString(in: object)
      for part in content["parts"] as? [[String: Any]] ?? [] {
        var copy = part
        if signatureString(in: copy) == nil, let parentSignature = contentSignature {
          copy["thoughtSignature"] = parentSignature
          contentSignature = nil
        }
        parts.append(copy)
      }
    }
    var usage: [String: Any]?
    if let metadata = (payload["usageMetadata"] as? [String: Any]) ?? (payload["usage_metadata"] as? [String: Any]) {
      let prompt = metadata["promptTokenCount"] as? Int ?? metadata["prompt_token_count"] as? Int ?? 0
      let output = metadata["candidatesTokenCount"] as? Int ?? metadata["candidates_token_count"] as? Int ?? 0
      usage = [
        "prompt_tokens": prompt,
        "completion_tokens": output,
        "total_tokens": metadata["totalTokenCount"] as? Int ?? metadata["total_token_count"] as? Int ?? (prompt + output),
      ]
    }
    return CandidatePiece(parts: parts, usage: usage)
  }

  private static func signatureString(in object: [String: Any]) -> String? {
    for key in ["thoughtSignature", "thought_signature"] {
      if let value = object[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }

  private static func chatCompletion(parts: [[String: Any]], model: String, usage: [String: Any]?) -> [String: Any] {
    var text = ""
    var toolCalls: [[String: Any]] = []
    for part in parts {
      if (part["thought"] as? Bool) == true {
        continue
      }
      if let piece = part["text"] as? String { text += piece }
      let call = (part["functionCall"] as? [String: Any]) ?? (part["function_call"] as? [String: Any])
      if let call {
        let name = call["name"] as? String ?? ""
        let args = call["args"] as? [String: Any] ?? [:]
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        let callID = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(toolCalls.count)"
        var tool: [String: Any] = [
          "id": callID,
          "type": "function",
          "function": [
            "name": name,
            "arguments": String(data: argsData, encoding: .utf8) ?? "{}",
          ],
        ]
        if let signature = signatureString(in: part) {
          tool["extra_content"] = ["google": ["thought_signature": signature]]
        }
        toolCalls.append(tool)
      }
    }
    var message: [String: Any] = [
      "role": "assistant",
      "content": text.isEmpty ? NSNull() : text,
    ]
    if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
    return [
      "id": "chatcmpl-gemini",
      "object": "chat.completion",
      "created": Int(Date().timeIntervalSince1970),
      "model": model,
      "choices": [[
        "index": 0,
        "message": message,
        "finish_reason": toolCalls.isEmpty ? "stop" : "tool_calls",
      ]],
      "usage": usage ?? ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
    ]
  }

  private static func chatCompletionToSSE(_ completion: [String: Any], model: String) -> String {
    let id = completion["id"] as? String ?? "chatcmpl-gemini"
    let created = completion["created"] as? Int ?? Int(Date().timeIntervalSince1970)
    let message = ((completion["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] ?? [:]
    var out = ""
    func chunk(_ delta: [String: Any], finish: String? = nil) {
      let choice: [String: Any] = [
        "index": 0,
        "delta": delta,
        "finish_reason": finish as Any,
      ]
      let object: [String: Any] = [
        "id": id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [choice],
      ]
      if let data = try? JSONSerialization.data(withJSONObject: object),
         let line = String(data: data, encoding: .utf8) {
        out += "data: \(line)\n\n"
      }
    }
    chunk(["role": "assistant"])
    if let text = message["content"] as? String, !text.isEmpty {
      chunk(["content": text])
    }
    if let calls = message["tool_calls"] as? [[String: Any]] {
      for (index, call) in calls.enumerated() {
        var deltaCall = call
        deltaCall["index"] = index
        chunk(["tool_calls": [deltaCall]])
      }
    }
    let finish = ((completion["choices"] as? [[String: Any]])?.first)?["finish_reason"] as? String ?? "stop"
    chunk([:], finish: finish)
    out += "data: [DONE]\n\n"
    return out
  }

  private static func parseSSEJSON(_ text: String) -> [[String: Any]] {
    var events: [[String: Any]] = []
    var buffer = ""
    func flush() {
      let chunk = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
      buffer = ""
      guard !chunk.isEmpty, chunk != "[DONE]",
            let data = chunk.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
      events.append(object)
    }
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("data:") {
        buffer += line.dropFirst(5).trimmingCharacters(in: .whitespaces) + "\n"
      } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
        flush()
      }
    }
    flush()
    return events
  }
}
