import Foundation

enum ChatUpstreamEvent: Sendable {
  case status(Int)
  case line(String)
}

enum ChatUpstreamFailure: LocalizedError, Sendable {
  case interrupted(String)

  var errorDescription: String? {
    switch self {
    case .interrupted(let message): return message
    }
  }
}

typealias ChatUpstreamStream = AsyncThrowingStream<ChatUpstreamEvent, Error>

protocol ResponsesEventSink: AnyObject, Sendable {
  func sendJSONError(status: Int, body: Data)
  func openEventStream()
  func sendEvent(_ sseFrame: Data)
  func closeEventStream()
}

final class GatewayServer {
  static let shared = GatewayServer()

  private let http = LoopbackHTTPServer()

  private init() {}

  func start() {
    Paths.ensureConfigDir()
    if !FileManager.default.fileExists(atPath: Paths.providersConfig) {
      try? ModelCatalog.shared.saveProviders(ProvidersFile(providers: []))
    }
    // Only keep Codex in sync if CodexGateway was already applied to it. Never silently
    // inject into a fresh/native Codex (e.g. after the user reinstalled Codex or
    // deleted ~/.codex) — Settings' "Update Gateway Config" is the opt-in.
    if CodexConfig.hasManagedBlock() {
      ModelCatalog.shared.normalizeDisplayNames()
      try? ModelCatalog.shared.syncCodexCatalogExport()
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

    let requestedModel = ModelCatalog.requestedModelID(from: body)
    let sessionId = request.headers["x-session-id"] ?? body["client_metadata"] as? String

    if ModelCatalog.shared.isCustomModel(requestedModel),
       let resolved = ModelCatalog.shared.resolveUpstream(slug: requestedModel) {
      handleThirdPartyResponses(body: body, requestedModel: requestedModel, provider: resolved.provider, upstreamModel: resolved.upstreamModel, sessionId: sessionId, response: response)
      return
    }

    if requestedModel.contains("/") {
      GatewayLog.error("Unknown custom-looking model \(requestedModel); passing through")
    }
    passthroughResponses(request: request, body: body, response: response)
  }

  private func handleThirdPartyResponses(body: [String: Any], requestedModel: String, provider: ProviderConfig, upstreamModel: String, sessionId: String?, response: HTTPResponse) {
    let namespaceMap = Translator.extractNamespaceMap(tools: body["tools"] as? [[String: Any]])
    let chatBody = Translator.responsesToChat(
      body: body,
      upstreamModel: upstreamModel,
      sessionId: sessionId,
      providerID: provider.name
    )
    let stream = chatBody["stream"] as? Bool ?? true

    if provider.usesGeminiAgyOAuth {
      handleGeminiAgyResponses(
        chatBody: chatBody,
        requestedModel: requestedModel,
        provider: provider,
        namespaceMap: namespaceMap,
        stream: stream,
        response: response
      )
      return
    }

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
      guard provider.applyUpstreamAuth(to: &urlRequest) else {
        self.json(response, [
          "error": [
            "message": ClaudeCodeSession.missingSessionMessage(),
            "type": "authentication_error",
            "code": 401
          ] as [String: Any]
        ], status: 401)
        return
      }
      urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: chatBody)

      if stream {
        self.streamThirdParty(
          urlRequest: urlRequest,
          requestedModel: requestedModel,
          namespaceMap: namespaceMap,
          providerID: provider.name,
          response: response
        )
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
          let translated = Translator.chatCompletionToResponse(
            payload: payload,
            requestedModel: requestedModel,
            namespaceMap: namespaceMap,
            providerID: provider.name
          )
          self.json(response, translated)
        }.resume()
      }
    }
  }

  private func handleGeminiAgyResponses(
    chatBody: [String: Any],
    requestedModel: String,
    provider: ProviderConfig,
    namespaceMap: [String: String],
    stream: Bool,
    response: HTTPResponse
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let result = try GeminiAgyClient.forwardChat(
          chatBody: chatBody,
          baseURL: provider.base_url.isEmpty ? GeminiAgyClient.defaultHost : provider.base_url
        )
        if result.isStream || stream {
          self.emitChatSSEAsResponses(
            chatSSE: String(data: result.data, encoding: .utf8) ?? "",
            requestedModel: requestedModel,
            namespaceMap: namespaceMap,
            providerID: provider.name,
            response: response
          )
        } else {
          guard let payload = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            self.json(response, GatewayServer.upstreamErrorPayload(status: 502, bodyPreview: "Invalid Gemini JSON"), status: 502)
            return
          }
          let translated = Translator.chatCompletionToResponse(
            payload: payload,
            requestedModel: requestedModel,
            namespaceMap: namespaceMap,
            providerID: provider.name
          )
          self.json(response, translated)
        }
      } catch let error as GeminiAgyClient.ClientError {
        self.sendGeminiAgyError(error, requestedModel: requestedModel, response: response)
      } catch {
        GatewayLog.error("Gemini agy failed for \(requestedModel): \(error.localizedDescription)")
        self.json(response, ["error": error.localizedDescription], status: 502)
      }
    }
  }

  private func sendGeminiAgyError(_ error: GeminiAgyClient.ClientError, requestedModel: String, response: HTTPResponse) {
    switch error {
    case .notSignedIn:
      GatewayLog.error("Gemini agy is not signed in for \(requestedModel)")
      json(response, [
        "error": [
          "message": error.localizedDescription,
          "type": "authentication_error",
          "code": 401
        ] as [String: Any]
      ], status: 401)
    case .rateLimited:
      json(response, GatewayServer.upstreamErrorPayload(status: 429, bodyPreview: error.localizedDescription), status: 429)
    case .modelNotFound:
      json(response, GatewayServer.upstreamErrorPayload(status: 404, bodyPreview: error.localizedDescription), status: 404)
    case .thoughtSignature:
      json(response, GatewayServer.upstreamErrorPayload(status: 400, bodyPreview: error.localizedDescription), status: 400)
    case .upstream(let status, let detail):
      GatewayLog.error("Gemini agy upstream \(requestedModel) status=\(status)")
      json(response, GatewayServer.upstreamErrorPayload(status: status, bodyPreview: detail), status: status >= 400 ? status : 502)
    case .transport(let message):
      json(response, ["error": message], status: 504)
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
            providerID: provider.name,
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
            namespaceMap: namespaceMap,
            providerID: provider.name
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
  /// Grok's converter already synthesizes `finish_reason` and `[DONE]`, so a dropped
  /// socket is not visible here and retries would only repeat a finished buffer.
  func emitChatSSEAsResponses(
    chatSSE: String,
    requestedModel: String,
    namespaceMap: [String: String],
    providerID: String? = nil,
    response: ResponsesEventSink
  ) {
    let lines = chatSSE.components(separatedBy: "\n")
    Task.detached(priority: .userInitiated) {
      await GatewayServer.relayChatStream(
        requestedModel: requestedModel,
        namespaceMap: namespaceMap,
        sink: response,
        retryDelaysMs: [],
        providerID: providerID
      ) { _ in
        GatewayServer.bufferedChatStream(status: 200, lines: lines)
      }
    }
  }

  private func streamThirdParty(
    urlRequest: URLRequest,
    requestedModel: String,
    namespaceMap: [String: String],
    providerID: String?,
    response: HTTPResponse
  ) {
    let req = urlRequest
    Task.detached(priority: .userInitiated) {
      await GatewayServer.relayChatStream(
        requestedModel: requestedModel,
        namespaceMap: namespaceMap,
        sink: response,
        providerID: providerID
      ) { _ in
        GatewayServer.urlSessionChatStream(req)
      }
    }
  }

  private func passthroughResponses(request: HTTPRequest, body: [String: Any], response: HTTPResponse) {
    let headerAccount = request.headers.first { $0.key.lowercased() == "chatgpt-account-id" }?.value
    let backend = Self.passthroughBackend(
      headerAccountID: headerAccount,
      authAccountID: CodexConfig.loadChatGPTAccountID(),
      authMode: CodexConfig.loadAuthMode()
    )
    let subPath = request.path.hasPrefix("/v1/") ? String(request.path.dropFirst(4)) : request.path
    let target: URL
    switch backend {
    case .chatGPT:
      target = URL(string: "https://chatgpt.com/backend-api/codex/\(subPath)")!
    case .openAI:
      target = URL(string: "https://api.openai.com\(request.path)")!
    }

    var urlRequest = URLRequest(url: target)
    urlRequest.httpMethod = request.method
    for (k, v) in request.forwardHeaders {
      urlRequest.setValue(v, forHTTPHeaderField: k)
    }
    if case .chatGPT(let accountID) = backend,
       urlRequest.value(forHTTPHeaderField: "chatgpt-account-id") == nil {
      urlRequest.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
    }
    // Codex writes experimental_bearer_token = "dummy" so it will call the local
    // gateway. Replace that placeholder (or a missing header) with the ChatGPT
    // token from ~/.codex/auth.json. Never forward dummy/not-used — setValue(nil)
    // removes the header. URLSession uses the macOS trust store — works with a
    // Zscaler root in Keychain and with public CAs when Zscaler is not installed.
    urlRequest.setValue(
      Self.passthroughAuthorization(
        existing: urlRequest.value(forHTTPHeaderField: "Authorization"),
        chatgptToken: CodexConfig.loadAuthToken()
      ),
      forHTTPHeaderField: "Authorization"
    )
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
        let model = ModelCatalog.requestedModelID(from: body)
        GatewayLog.error(
          "Pass-through \(request.method) \(request.path) model=\(model.isEmpty ? "<missing>" : model) " +
          "-> \(target.absoluteString) status=\(status) ce=\(request.headers["content-encoding"] ?? "-") preview=\(preview)"
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
    let model = ModelCatalog.requestedModelID(from: body)
    if let resolved = ModelCatalog.shared.resolveUpstream(slug: model) {
      var chat = body
      chat["model"] = resolved.upstreamModel

      if resolved.provider.usesGeminiAgyOAuth {
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let result = try GeminiAgyClient.forwardChat(
              chatBody: chat,
              baseURL: resolved.provider.base_url
            )
            let contentType = result.isStream ? "text/event-stream" : "application/json"
            response.send(status: result.status, headers: ["Content-Type": contentType], body: result.data)
          } catch let error as GeminiAgyClient.ClientError {
            self.sendGeminiAgyError(error, requestedModel: model, response: response)
          } catch {
            self.json(response, ["error": error.localizedDescription], status: 502)
          }
        }
        return
      }

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
        guard resolved.provider.applyUpstreamAuth(to: &urlRequest) else {
          self.json(response, [
            "error": [
              "message": ClaudeCodeSession.missingSessionMessage(),
              "type": "authentication_error",
              "code": 401
            ] as [String: Any]
          ], status: 401)
          return
        }
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

  /// Native GPT goes to ChatGPT's Codex backend when the desktop app (or auth.json)
  /// has a ChatGPT account id. A ChatGPT OAuth token against api.openai.com returns
  /// 401 `api.responses.write` and Codex stores an empty assistant turn.
  enum PassthroughBackend: Equatable {
    case chatGPT(accountID: String)
    case openAI
  }

  static func passthroughBackend(
    headerAccountID: String?,
    authAccountID: String?,
    authMode: String?
  ) -> PassthroughBackend {
    let header = headerAccountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !header.isEmpty { return .chatGPT(accountID: header) }
    let auth = authAccountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if (authMode ?? "").lowercased() == "chatgpt", !auth.isEmpty {
      return .chatGPT(accountID: auth)
    }
    return .openAI
  }

  /// Placeholder tokens Codex (or other clients) send so the local gateway accepts
  /// the request. Native pass-through must not forward these to OpenAI.
  static let placeholderBearerTokens: Set<String> = [
    "dummy", "not-used", "not-needed", "none", "placeholder"
  ]

  static func isPlaceholderAuthorization(_ value: String?) -> Bool {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return true
    }
    let lowered = raw.lowercased()
    let token: String
    if lowered == "bearer" {
      token = ""
    } else if lowered.hasPrefix("bearer ") {
      token = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      token = raw
    }
    if token.isEmpty { return true }
    return placeholderBearerTokens.contains(token.lowercased())
  }

  /// Prefer a real ChatGPT token from `auth.json` when the client sent a dummy
  /// (or omitted) Authorization. Placeholders without a replacement are dropped
  /// (`nil`) so they are never forwarded upstream. Leave a real header untouched.
  static func passthroughAuthorization(existing: String?, chatgptToken: String?) -> String? {
    let chatgpt = chatgptToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if isPlaceholderAuthorization(existing) {
      return chatgpt.isEmpty ? nil : "Bearer \(chatgpt)"
    }
    return existing
  }

  /// Builds an OpenAI-style error payload so upstream provider failures (4xx/5xx)
  /// surface back to Codex instead of being translated into an empty completion.
  static func upstreamErrorMessage(status: Int, bodyPreview: String) -> String {
    "Upstream provider returned HTTP \(status): \(bodyPreview)"
  }

  static func upstreamErrorPayload(status: Int, bodyPreview: String) -> [String: Any] {
    [
      "error": [
        "message": upstreamErrorMessage(status: status, bodyPreview: bodyPreview),
        "type": "upstream_error",
        "code": status
      ] as [String: Any]
    ]
  }

  /// Two retries after the first attempt. Short enough that Codex's idle timeout
  /// does not fire, long enough for a reset Gemini stream to accept a new POST.
  static let chatStreamRetryDelaysMs: [UInt64] = [250, 750]

  /// Relay one Chat Completions body to a Responses SSE sink.
  ///
  /// Tool-call arguments stay inside `ResponsesStreamState` until the attempt
  /// finishes. A drop before that, with no text forwarded yet, runs the request
  /// again. Text is not deduped across attempts: sampling is not deterministic, so
  /// once a delta has been sent the turn fails with `response.failed` instead of
  /// splicing a second sample onto the first.
  static func relayChatStream(
    requestedModel: String,
    namespaceMap: [String: String],
    sink: ResponsesEventSink,
    retryDelaysMs: [UInt64] = chatStreamRetryDelaysMs,
    providerID: String? = nil,
    extraContentStore: ToolCallExtraContentStore = .shared,
    open: @Sendable (_ attempt: Int) -> ChatUpstreamStream
  ) async {
    let state = ResponsesStreamState(
      model: requestedModel,
      namespaceMap: namespaceMap,
      providerID: providerID,
      extraContentStore: extraContentStore
    )
    var opened = false
    let write: ([String: Any]) -> Void = { payload in
      guard let frame = GatewayServer.sseFrame(payload) else { return }
      sink.sendEvent(frame)
    }
    let attempts = retryDelaysMs.count + 1

    for attempt in 0..<attempts {
      var statusCode: Int?
      var failure: String?
      var errorPreview = ""

      let stream = open(attempt)
      do {
        ingest: for try await event in stream {
          switch event {
          case .status(let code):
            statusCode = code
            if (200..<300).contains(code), !opened {
              sink.openEventStream()
              state.start(write: write)
              opened = true
            }
          case .line(let line):
            guard let code = statusCode else { continue }
            if !(200..<300).contains(code) {
              appendErrorPreview(&errorPreview, line, limit: 400)
              if errorPreview.count >= 400 { break ingest }
            } else {
              state.ingestUpstreamLine(line, write: write)
            }
          }
        }
      } catch {
        failure = error.localizedDescription
      }

      if let code = statusCode, !(200..<300).contains(code) {
        if !opened {
          GatewayLog.error("Third-party stream \(requestedModel) status=\(code) preview=\(errorPreview)")
          let payload = upstreamErrorPayload(status: code, bodyPreview: errorPreview)
          sink.sendJSONError(status: code >= 400 ? code : 502, body: jsonData(payload))
          return
        }
        state.fail(
          code: "upstream_error",
          message: upstreamErrorMessage(status: code, bodyPreview: errorPreview),
          write: write
        )
        sink.closeEventStream()
        return
      }

      if statusCode == nil, !opened {
        sink.sendJSONError(status: 502, body: jsonData(["error": failure ?? "stream failed"]))
        return
      }

      let dropped = failure != nil || statusCode == nil
      if state.finishIfComplete(upstreamFailed: dropped, write: write) {
        sink.closeEventStream()
        return
      }

      if let detail = state.providerErrorMessage {
        GatewayLog.error("Third-party stream \(requestedModel) provider error: \(detail)")
        if opened {
          state.fail(code: "upstream_error", message: detail, write: write)
          sink.closeEventStream()
        } else {
          sink.sendJSONError(status: 502, body: jsonData(["error": detail]))
        }
        return
      }

      if attempt < retryDelaysMs.count, !state.hasForwardedText {
        GatewayLog.error("Third-party stream \(requestedModel) ended before the tool call finished; retrying (\(attempt + 1)/\(retryDelaysMs.count))")
        state.discardAttempt()
        try? await Task.sleep(nanoseconds: retryDelaysMs[attempt] * 1_000_000)
        continue
      }

      let reason = failure ?? (state.hasForwardedText ? "text already streamed" : "truncated stream")
      GatewayLog.error("Third-party stream \(requestedModel) failed after \(attempt) retries: \(reason)")
      state.fail(
        code: "upstream_stream_interrupted",
        message: "Upstream provider stream ended before the response finished (\(reason)); CodexGateway retried \(attempt)×.",
        write: write
      )
      sink.closeEventStream()
      return
    }
  }

  static func urlSessionChatStream(_ request: URLRequest) -> ChatUpstreamStream {
    ChatUpstreamStream { (continuation: ChatUpstreamStream.Continuation) in
      let task = Task {
        do {
          let (bytes, urlResponse) = try await URLSession.shared.bytes(for: request)
          let code = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
          continuation.yield(.status(code))
          for try await line in bytes.lines {
            if Task.isCancelled {
              continuation.finish()
              return
            }
            continuation.yield(.line(line))
          }
          if Task.isCancelled {
            continuation.finish()
            return
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: ChatUpstreamFailure.interrupted(error.localizedDescription))
        }
      }
      continuation.onTermination = { (_: ChatUpstreamStream.Continuation.Termination) in
        task.cancel()
      }
    }
  }

  static func bufferedChatStream(
    status: Int,
    lines: [String],
    thenThrow error: ChatUpstreamFailure? = nil
  ) -> ChatUpstreamStream {
    ChatUpstreamStream { (continuation: ChatUpstreamStream.Continuation) in
      let task = Task {
        continuation.yield(.status(status))
        for line in lines {
          if Task.isCancelled {
            continuation.finish()
            return
          }
          continuation.yield(.line(line))
        }
        if Task.isCancelled {
          continuation.finish()
          return
        }
        if let error {
          continuation.finish(throwing: error)
        } else {
          continuation.finish()
        }
      }
      continuation.onTermination = { (_: ChatUpstreamStream.Continuation.Termination) in
        task.cancel()
      }
    }
  }

  private static func sseFrame(_ payload: [String: Any]) -> Data? {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    var frame = Data("data: ".utf8)
    frame.append(data)
    frame.append(Data("\n\n".utf8))
    return frame
  }

  private static func jsonData(_ payload: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  }

  private static func appendErrorPreview(_ preview: inout String, _ line: String, limit: Int) {
    let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !piece.isEmpty, preview.count < limit else { return }
    if !preview.isEmpty { preview += "\n" }
    let room = limit - preview.count
    guard room > 0 else { return }
    preview += String(piece.prefix(room))
  }

  private func json(_ response: HTTPResponse, _ object: [String: Any], status: Int = 200) {
    if let data = try? JSONSerialization.data(withJSONObject: object) {
      response.send(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
  }
}

extension HTTPResponse: ResponsesEventSink {
  func sendJSONError(status: Int, body: Data) {
    send(status: status, headers: ["Content-Type": "application/json"], body: body)
  }

  func openEventStream() {
    startStream(status: 200, headers: [
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache"
    ])
  }

  func sendEvent(_ sseFrame: Data) {
    writeChunk(sseFrame)
  }

  func closeEventStream() {
    endStream()
  }
}
