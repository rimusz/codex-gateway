import Foundation

final class GatewayServer {
  static let shared = GatewayServer()

  private let http = LoopbackHTTPServer()

  private init() {}

  func start() {
    Paths.ensureConfigDir()
    if !FileManager.default.fileExists(atPath: Paths.providersConfig) {
      try? ModelCatalog.shared.saveProviders(ModelCatalog.shared.loadProviders())
    }
    // Only keep Codex in sync if CodexGateway was already applied to it. Never silently
    // inject into a fresh/native Codex (e.g. after the user reinstalled Codex or
    // deleted ~/.codex) — Settings' "Update Gateway Config" is the opt-in.
    if CodexConfig.hasManagedBlock() {
      ModelCatalog.shared.normalizeDisplayNames()
      ModelCatalog.shared.syncCodexCatalogExport()
      CodexConfig.patchCodexConfig()
    }

    http.handler = { [weak self] request, response in
      self?.route(request, response)
    }
    do {
      try http.start()
    } catch {
      GatewayLog.error("Failed to start gateway: \(error.localizedDescription)")
    }
  }

  func stop() {
    http.stop()
  }

  private func route(_ request: HTTPRequest, _ response: HTTPResponse) {
    let path = request.path

    if request.isWebSocketUpgrade {
      json(response, ["error": "WebSocket not supported"], status: 404)
      return
    }

    if request.method == "GET" && path == "/health" {
      json(response, ["status": "ok", "version": AppVersion.short, "gateway": true])
      return
    }

    if request.method == "POST" && path == "/api/restart-codex" {
      CodexAppServer.shared.restartCodexDesktop()
      json(response, ["status": "success"])
      return
    }

    if request.method == "GET" && (path == "/v1/models" || path == "/v1/models/") {
      handleV1Models(response)
      return
    }

    if request.method == "POST" && path == "/v1/responses" {
      handleResponses(request, response)
      return
    }

    if request.method == "POST" && path == "/v1/chat/completions" {
      handleChatCompletions(request, response)
      return
    }

    json(response, ["error": "Endpoint not found"], status: 404)
  }

  private func handleV1Models(_ response: HTTPResponse) {
    let catalog = ModelCatalog.shared.loadCatalog()
    let data = ModelCatalog.codexPickerModels(from: catalog)
      .filter { $0.visibility == "list" }
      .map { m in
        [
          "id": m.slug,
          "object": "model",
          "created": Int(Date().timeIntervalSince1970),
          "owned_by": m.priority >= 100 ? "codexgateway" : "openai"
        ] as [String: Any]
      }
    json(response, ["object": "list", "data": data])
  }

  private func handleResponses(_ request: HTTPRequest, _ response: HTTPResponse) {
    guard let body = parseJSON(request.body) else {
      let preview = String(data: request.body.prefix(160), encoding: .utf8) ?? "<binary>"
      GatewayLog.error(
        "Invalid JSON on \(request.path): bytes=\(request.body.count) " +
        "cl=\(request.headers["content-length"] ?? "-") " +
        "te=\(request.headers["transfer-encoding"] ?? "-") " +
        "ce=\(request.headers["content-encoding"] ?? "-") preview=\(preview)"
      )
      json(response, ["error": "Invalid JSON body"], status: 400)
      return
    }

    let requestedModel = body["model"] as? String ?? ""
    let sessionId = request.headers["x-session-id"] ?? body["client_metadata"] as? String

    if ModelCatalog.shared.isCustomModel(requestedModel),
       let resolved = ModelCatalog.shared.resolveUpstream(slug: requestedModel) {
      handleThirdPartyResponses(body: body, requestedModel: requestedModel, provider: resolved.provider, upstreamModel: resolved.upstreamModel, sessionId: sessionId, response: response)
      return
    }

    passthroughResponses(request: request, body: body, response: response)
  }

  private func handleThirdPartyResponses(body: [String: Any], requestedModel: String, provider: ProviderConfig, upstreamModel: String, sessionId: String?, response: HTTPResponse) {
    let namespaceMap = Translator.extractNamespaceMap(tools: body["tools"] as? [[String: Any]])
    let chatBody = Translator.responsesToChat(body: body, upstreamModel: upstreamModel, sessionId: sessionId)
    let stream = chatBody["stream"] as? Bool ?? true

    if provider.usesGrokOAuth {
      handleGrokOAuthResponses(
        chatBody: chatBody,
        requestedModel: requestedModel,
        provider: provider,
        namespaceMap: namespaceMap,
        stream: stream,
        response: response
      )
      return
    }

    whenCursorBridgeReady(for: provider) {
      let url = URL(string: "\(provider.base_url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions")!

      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("Bearer \(provider.api_key)", forHTTPHeaderField: "Authorization")
      urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: chatBody)

      if stream {
        self.streamThirdParty(urlRequest: urlRequest, requestedModel: requestedModel, namespaceMap: namespaceMap, response: response)
      } else {
        URLSession.shared.dataTask(with: urlRequest) { data, urlResponse, error in
          let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
          guard let data, error == nil else {
            self.json(response, ["error": error?.localizedDescription ?? "Upstream failed"], status: 502)
            return
          }
          if status >= 400 {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            GatewayLog.error("Third-party \(requestedModel) -> \(url.absoluteString) status=\(status) preview=\(preview)")
            self.json(response, GatewayServer.upstreamErrorPayload(status: status, bodyPreview: preview), status: status)
            return
          }
          guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.json(response, GatewayServer.upstreamErrorPayload(status: 502, bodyPreview: "Invalid upstream JSON"), status: 502)
            return
          }
          let translated = Translator.chatCompletionToResponse(payload: payload, requestedModel: requestedModel, namespaceMap: namespaceMap)
          self.json(response, translated)
        }.resume()
      }
    }
  }

  private func handleGrokOAuthResponses(
    chatBody: [String: Any],
    requestedModel: String,
    provider: ProviderConfig,
    namespaceMap: [String: String],
    stream: Bool,
    response: HTTPResponse
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let result = try GrokOAuthClient.forwardChat(
          chatBody: chatBody,
          baseURL: provider.base_url.isEmpty ? GrokOAuthClient.defaultBaseURL : provider.base_url
        )
        if result.isStream || stream {
          self.emitChatSSEAsResponses(
            chatSSE: String(data: result.data, encoding: .utf8) ?? "",
            requestedModel: requestedModel,
            namespaceMap: namespaceMap,
            response: response
          )
        } else {
          guard let payload = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            self.json(response, GatewayServer.upstreamErrorPayload(status: 502, bodyPreview: "Invalid Grok OAuth JSON"), status: 502)
            return
          }
          let translated = Translator.chatCompletionToResponse(
            payload: payload,
            requestedModel: requestedModel,
            namespaceMap: namespaceMap
          )
          self.json(response, translated)
        }
      } catch let error as GrokOAuthClient.ClientError {
        switch error {
        case .auth(let message):
          GatewayLog.error("Grok OAuth auth failed for \(requestedModel): \(message)")
          self.json(response, [
            "error": [
              "message": message,
              "type": "authentication_error",
              "code": 401
            ] as [String: Any]
          ], status: 401)
        case .upstream(let status, let detail):
          GatewayLog.error("Grok OAuth upstream \(requestedModel) status=\(status) preview=\(detail)")
          self.json(response, GatewayServer.upstreamErrorPayload(status: status, bodyPreview: detail), status: status >= 400 ? status : 502)
        case .transport(let message):
          GatewayLog.error("Grok OAuth transport failed for \(requestedModel): \(message)")
          self.json(response, ["error": message], status: 504)
        }
      } catch {
        GatewayLog.error("Grok OAuth failed for \(requestedModel): \(error.localizedDescription)")
        self.json(response, ["error": error.localizedDescription], status: 502)
      }
    }
  }

  /// Feed OpenAI Chat Completions SSE through `ResponsesStreamState` (same as third-party stream).
  private func emitChatSSEAsResponses(
    chatSSE: String,
    requestedModel: String,
    namespaceMap: [String: String],
    response: HTTPResponse
  ) {
    let state = ResponsesStreamState(model: requestedModel, namespaceMap: namespaceMap)
    var events: [Data] = []
    let write: ([String: Any]) -> Void = { payload in
      if let d = try? JSONSerialization.data(withJSONObject: payload) {
        events.append("data: ".data(using: .utf8)! + d + "\n\n".data(using: .utf8)!)
      }
    }
    state.start(write: write)
    for line in chatSSE.components(separatedBy: "\n") {
      guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
      let jsonStr = String(line.dropFirst(6))
      guard let d = jsonStr.data(using: .utf8),
            let chunk = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
      state.writeChatDelta(chunk, write: write)
    }
    state.finish(write: write)
    let body = events.reduce(into: Data()) { $0.append($1) }
    response.send(status: 200, headers: [
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive"
    ], body: body)
  }

  private func streamThirdParty(urlRequest: URLRequest, requestedModel: String, namespaceMap: [String: String], response: HTTPResponse) {
    let req = urlRequest
    let state = ResponsesStreamState(model: requestedModel, namespaceMap: namespaceMap)

    URLSession.shared.dataTask(with: req) { data, urlResponse, error in
      let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
      guard let data, error == nil else {
        self.json(response, ["error": error?.localizedDescription ?? "stream failed"], status: 502)
        return
      }
      if status >= 400 {
        let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
        GatewayLog.error("Third-party stream \(requestedModel) -> \(req.url?.absoluteString ?? "?") status=\(status) preview=\(preview)")
        self.json(response, GatewayServer.upstreamErrorPayload(status: status, bodyPreview: preview), status: status)
        return
      }
      let text = String(data: data, encoding: .utf8) ?? ""
      var events: [Data] = []
      let write: ([String: Any]) -> Void = { payload in
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
          events.append("data: ".data(using: .utf8)! + d + "\n\n".data(using: .utf8)!)
        }
      }
      state.start(write: write)
      for line in text.components(separatedBy: "\n") {
        guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
        let jsonStr = String(line.dropFirst(6))
        guard let d = jsonStr.data(using: .utf8),
              let chunk = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        state.writeChatDelta(chunk, write: write)
      }
      state.finish(write: write)
      let body = events.reduce(into: Data()) { $0.append($1) }
      response.send(status: 200, headers: [
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive"
      ], body: body)
    }.resume()
  }

  private func passthroughResponses(request: HTTPRequest, body: [String: Any], response: HTTPResponse) {
    let isChatGPT = request.headers.keys.contains(where: { $0.lowercased() == "chatgpt-account-id" })
    let subPath = request.path.hasPrefix("/v1/") ? String(request.path.dropFirst(4)) : request.path
    let target: URL
    if isChatGPT {
      target = URL(string: "https://chatgpt.com/backend-api/codex/\(subPath)")!
    } else {
      target = URL(string: "https://api.openai.com\(request.path)")!
    }

    var urlRequest = URLRequest(url: target)
    urlRequest.httpMethod = request.method
    for (k, v) in request.forwardHeaders {
      urlRequest.setValue(v, forHTTPHeaderField: k)
    }
    if let token = CodexConfig.loadAuthToken(), urlRequest.value(forHTTPHeaderField: "Authorization") == nil {
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = request.body

    URLSession.shared.dataTask(with: urlRequest) { data, urlResponse, error in
      guard let data else {
        self.json(response, ["error": error?.localizedDescription ?? "pass-through failed"], status: 502)
        return
      }
      let http = urlResponse as? HTTPURLResponse
      let status = http?.statusCode ?? 200
      if status >= 400 {
        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        GatewayLog.error(
          "Pass-through \(request.method) \(request.path) -> \(target.absoluteString) " +
          "status=\(status) ce=\(request.headers["content-encoding"] ?? "-") preview=\(preview)"
        )
      }
      var headers: [String: String] = [:]
      http?.allHeaderFields.forEach { k, v in
        if let key = k as? String, let val = v as? String, key.lowercased() != "transfer-encoding" {
          headers[key] = val
        }
      }
      response.send(status: status, headers: headers, body: data)
    }.resume()
  }

  private func handleChatCompletions(_ request: HTTPRequest, _ response: HTTPResponse) {
    guard let body = parseJSON(request.body) else {
      json(response, ["error": "Invalid JSON"], status: 400)
      return
    }
    let model = body["model"] as? String ?? ""
    if let resolved = ModelCatalog.shared.resolveUpstream(slug: model) {
      var chat = body
      chat["model"] = resolved.upstreamModel

      if resolved.provider.usesGrokOAuth {
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let result = try GrokOAuthClient.forwardChat(
              chatBody: chat,
              baseURL: resolved.provider.base_url.isEmpty
                ? GrokOAuthClient.defaultBaseURL
                : resolved.provider.base_url
            )
            let contentType = result.isStream ? "text/event-stream" : "application/json"
            response.send(status: result.status, headers: ["Content-Type": contentType], body: result.data)
          } catch let error as GrokOAuthClient.ClientError {
            switch error {
            case .auth(let message):
              self.json(response, [
                "error": [
                  "message": message,
                  "type": "authentication_error",
                  "code": 401
                ] as [String: Any]
              ], status: 401)
            case .upstream(let status, let detail):
              self.json(response, GatewayServer.upstreamErrorPayload(status: status, bodyPreview: detail), status: status >= 400 ? status : 502)
            case .transport(let message):
              self.json(response, ["error": message], status: 504)
            }
          } catch {
            self.json(response, ["error": error.localizedDescription], status: 502)
          }
        }
        return
      }

      whenCursorBridgeReady(for: resolved.provider) {
        var urlRequest = URLRequest(url: URL(string: "\(resolved.provider.base_url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(resolved.provider.api_key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: chat)
        URLSession.shared.dataTask(with: urlRequest) { data, urlResponse, error in
          guard let data else {
            self.json(response, ["error": error?.localizedDescription ?? "failed"], status: 502)
            return
          }
          let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 200
          response.send(status: status, headers: ["Content-Type": "application/json"], body: data)
        }.resume()
      }
      return
    }
    passthroughResponses(request: request, body: body, response: response)
  }

  /// True when Cursor proxy work must hop off `LoopbackHTTPServer`'s serial queue so `/health` stays responsive.
  static func shouldWaitOffHTTPQueueForCursorBridge(isRunning: Bool) -> Bool {
    !isRunning
  }

  /// Starts the managed sidecar without blocking the HTTP server queue, then runs `perform`.
  private func whenCursorBridgeReady(for provider: ProviderConfig, perform: @escaping () -> Void) {
    guard provider.usesCursorBridge else {
      perform()
      return
    }
    if !GatewayServer.shouldWaitOffHTTPQueueForCursorBridge(isRunning: CursorBridgeRuntime.isRunning) {
      perform()
      return
    }
    Task {
      _ = await CursorBridgeRuntime.startIfNeeded()
      perform()
    }
  }

  private func parseJSON(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty else { return nil }
    var bytes = data
    if bytes.starts(with: Data([0xEF, 0xBB, 0xBF])) {
      bytes = Data(bytes.dropFirst(3))
    }
    guard let object = try? JSONSerialization.jsonObject(with: bytes) else { return nil }
    return object as? [String: Any]
  }

  /// Builds an OpenAI-style error payload so upstream provider failures (4xx/5xx)
  /// surface back to Codex instead of being translated into an empty completion.
  static func upstreamErrorPayload(status: Int, bodyPreview: String) -> [String: Any] {
    [
      "error": [
        "message": "Upstream provider returned HTTP \(status): \(bodyPreview)",
        "type": "upstream_error",
        "code": status
      ] as [String: Any]
    ]
  }

  private func json(_ response: HTTPResponse, _ object: [String: Any], status: Int = 200) {
    if let data = try? JSONSerialization.data(withJSONObject: object) {
      response.send(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
  }
}
